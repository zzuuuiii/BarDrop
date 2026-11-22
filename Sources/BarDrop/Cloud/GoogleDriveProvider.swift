import AppKit

/// Google Drive über die Drive-Schnittstelle v3. Nur der Bereich `drive.file`: BarDrop sieht
/// ausschließlich Dateien, die es selbst angelegt hat. Mehr bräuchte jedes Jahr eine
/// Sicherheitsprüfung durch Google (daran ist Drive bei anderen Apps schon gescheitert).
final class GoogleDriveProvider: OAuthCloudProvider, CloudProvider {
    static let shared = GoogleDriveProvider()
    private init() { super.init(service: .googleDrive) }

    /// Kennung des Ordners „BarDrop Share“, einmal gesucht oder angelegt
    private var folderID: String? {
        get { UserDefaults.standard.string(forKey: "cloudGoogleFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "cloudGoogleFolder") }
    }
    /// Gemerkter Ordner in diesem Lauf schon einmal geprüft (gelöscht oder im Papierkorb?)
    private var folderVerified = false
    /// Stücke beim Hochladen: Vielfache von 256 KB verlangt Google
    private static let chunkSize = 32 * 256 * 1024

    override var oauthRequest: CloudOAuth.Request? {
        // Bei Desktop-Apps ist das „Geheimnis“ nicht geheim; Google verlangt es trotzdem. Ohne
        // es scheitert die Anmeldung: dann wie OneDrive „Derzeit noch nicht verfügbar“ (die
        // veröffentlichte Info.plist hat es nicht, bis die Anmeldung ohne Secret auskommt)
        guard let id = CloudKeys.value("BarDropCloudGoogleClientID"),
              let secret = CloudKeys.value("BarDropCloudGoogleClientSecret") else { return nil }
        return CloudOAuth.Request(authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                  tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                                  clientID: id, clientSecret: secret,
                                  redirectURI: "http://127.0.0.1:\(CloudOAuth.port)/",
                                  scopes: ["https://www.googleapis.com/auth/drive.file", "email"],
                                  // Refresh-Token auch, wenn man schon einmal verbunden war
                                  extra: ["access_type": "offline", "prompt": "consent"])
    }

    func connect() async throws {
        var new = try await signIn()
        folderID = nil
        folderVerified = false
        if let info = try? await json({ Self.request(URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!, token: $0, json: false) }),
           let email = info["email"] as? String {
            new.account = email
            store(new)
        }
    }

    override func disconnect() {
        folderID = nil
        folderVerified = false
        super.disconnect()
    }

    func upload(_ file: URL, name: String, progress: @escaping (Double?, String?) -> Void) async throws -> URL {
        let folder = try await shareFolder()
        let size = Self.size(of: file)
        let label = L("Uploading", "Lädt hoch") + " · " + Self.sizeLabel(size)
        progress(0, label)
        // Hochladen mit Wiederaufnahme: erst die Sitzung, dann die Datei in Stücken
        let start = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!
        let (data, response) = try await send({ token in
            var r = Self.request(start, method: "POST", token: token)
            r.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            return r
        }, body: Self.body(["name": name, "parents": [folder]]))
        guard response.statusCode == 200, let location = response.value(forHTTPHeaderField: "Location"),
              let session = URL(string: location) else { throw CloudError.http(response.statusCode, data, service: service) }
        var offset: UInt64 = 0
        var result: [String: Any] = [:]
        var failures = 0
        uploading: repeat {
            try Task.checkCancellation()
            let piece = try Self.chunk(of: file, offset: offset, length: Self.chunkSize)
            guard size == 0 || !piece.isEmpty else { throw CloudError.fileChanged }
            let last = offset + UInt64(piece.count)
            let answer: Data, status: HTTPURLResponse
            do {
                (answer, status) = try await send({ token in
                    var r = Self.request(session, method: "PUT", token: token, json: false)
                    r.setValue(size == 0 ? "bytes */0" : "bytes \(offset)-\(last - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                    return r
                }, body: piece)
            } catch where Self.isTransient(error) && failures < Self.maxRetries {
                // Netz weg: Google fragen, was angekommen ist, und dort weitermachen
                switch try await recover(&failures, { try await resumeState(session, size: size) }) {
                case .done(let object): result = object; break uploading
                case .at(let received): offset = received; continue uploading
                }
            }
            if status.statusCode == 200 || status.statusCode == 201 {
                result = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any]) ?? [:]
                break
            }
            if Self.isTransient(status: status.statusCode), failures < Self.maxRetries {
                switch try await recover(&failures, response: status, { try await resumeState(session, size: size) }) {
                case .done(let object): result = object; break uploading
                case .at(let received): offset = received; continue uploading
                }
            }
            // 308: Stück angekommen, weiter (so weit, wie Google es bestätigt)
            guard status.statusCode == 308 else { throw CloudError.http(status.statusCode, answer, service: service) }
            offset = Self.receivedBytes(status) ?? last
            failures = 0
            progress(Double(offset) / Double(max(size, 1)), label)
        } while offset < size || size == 0
        guard let id = result["id"] as? String else { throw CloudError(message: L("Google Drive didn’t save the file.", "Google Drive hat die Datei nicht gespeichert.")) }
        progress(1, label)
        // Jeder mit dem Link darf ansehen. Klappt das nicht, die Datei wieder entfernen: Sonst
        // läge sie ohne funktionierenden Link in Drive, und ein neuer Versuch legte sie doppelt an
        do {
            _ = try await json({ Self.request(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/permissions")!, method: "POST", token: $0) },
                               body: Self.body(["type": "anyone", "role": "reader"]))
        } catch {
            _ = try? await send({ Self.request(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!, method: "DELETE", token: $0, json: false) })
            throw error
        }
        if let link = result["webViewLink"] as? String, let url = URL(string: link) { return url }
        return URL(string: "https://drive.google.com/file/d/\(id)/view")!
    }

    private enum ResumeState {
        case done([String: Any])
        case at(UInt64)
    }

    /// Stand einer unterbrochenen Sitzung erfragen (leeres Stück mit „bytes */Größe“)
    private func resumeState(_ session: URL, size: UInt64) async throws -> ResumeState {
        let (data, response) = try await send({ token in
            var r = Self.request(session, method: "PUT", token: token, json: false)
            r.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
            return r
        }, body: Data())
        switch response.statusCode {
        case 200, 201:
            return .done((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        case 308:
            // Ohne Range-Kopf ist noch nichts angekommen
            return .at(Self.receivedBytes(response) ?? 0)
        default:
            throw CloudError.http(response.statusCode, data, service: service)
        }
    }

    /// Angekommene Bytes aus „Range: bytes=0-N“
    private static func receivedBytes(_ response: HTTPURLResponse) -> UInt64? {
        guard let range = response.value(forHTTPHeaderField: "Range"),
              let end = range.split(separator: "-").last.flatMap({ UInt64($0) }) else { return nil }
        return end + 1
    }

    /// „BarDrop Share“ suchen (nur unter den eigenen Dateien sichtbar) oder anlegen
    private func shareFolder() async throws -> String {
        if let cached = folderID {
            if folderVerified { return cached }
            // Einmal je Lauf prüfen: Hat man „BarDrop Share“ in Drive gelöscht oder in den
            // Papierkorb gelegt, ging sonst jedes Hochladen dorthin bzw. scheiterte mit 404
            let check = URL(string: "https://www.googleapis.com/drive/v3/files/\(cached)?fields=trashed")!
            let (data, response) = try await send({ Self.request(check, token: $0, json: false) })
            let info = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if response.statusCode == 200, info["trashed"] as? Bool != true {
                folderVerified = true
                return cached
            }
            guard response.statusCode == 200 || response.statusCode == 404 else {
                throw CloudError.http(response.statusCode, data, service: service)
            }
            folderID = nil
        }
        folderVerified = true
        var search = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        search.queryItems = [URLQueryItem(name: "q", value: "name = '\(CloudService.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
                             URLQueryItem(name: "fields", value: "files(id)")]
        let found = try await json({ Self.request(search.url!, token: $0, json: false) })
        if let files = found["files"] as? [[String: Any]], let id = files.first?["id"] as? String {
            folderID = id
            return id
        }
        let created = try await json({ Self.request(URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!, method: "POST", token: $0) },
                                     body: Self.body(["name": CloudService.folderName, "mimeType": "application/vnd.google-apps.folder"]))
        guard let id = created["id"] as? String else { throw CloudError(message: L("Couldn’t create the folder in Google Drive.", "Ordner in Google Drive ließ sich nicht anlegen.")) }
        folderID = id
        return id
    }

    func listFolder() async throws -> [CloudRemoteFile] {
        let folder = try await shareFolder()
        var result: [CloudRemoteFile] = []
        var pageToken: String?
        repeat {
            var list = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            list.queryItems = [URLQueryItem(name: "q", value: "'\(folder)' in parents and trashed = false"),
                               URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,size,md5Checksum,modifiedTime,mimeType)"),
                               URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { list.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await json({ Self.request(list.url!, token: $0, json: false) })
            for file in page["files"] as? [[String: Any]] ?? [] {
                // Google-Dokumente und Ordner haben keinen Inhalt zum Laden
                guard let id = file["id"] as? String, let name = file["name"] as? String,
                      (file["mimeType"] as? String)?.hasPrefix("application/vnd.google-apps") != true else { continue }
                result.append(CloudRemoteFile(id: id, name: name, size: UInt64(file["size"] as? String ?? "") ?? 0,
                                              version: file["md5Checksum"] as? String ?? file["modifiedTime"] as? String ?? ""))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    func download(_ file: CloudRemoteFile, to destination: URL) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")!
        try await download({ Self.request(url, token: $0, json: false) }, to: destination)
    }

    /// In den Papierkorb von Google Drive (30 Tage wiederherstellbar)
    func delete(_ file: CloudRemoteFile) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)")!
        let (data, response) = try await send({ Self.request(url, method: "PATCH", token: $0) },
                                              body: Self.body(["trashed": true]))
        guard response.statusCode == 200 || response.statusCode == 404 else { throw CloudError.http(response.statusCode, data, service: service) }
    }

    func openFolder() {
        let url = folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
            ?? URL(string: "https://drive.google.com/drive/my-drive")!
        NSWorkspace.shared.open(url)
    }
}
