import AppKit

/// Dropbox über die HTTP-Schnittstelle (api.dropboxapi.com). Rechte der App bei Dropbox:
/// `files.content.write`, `files.content.read` (Kopie auf dem Mac, `CloudMirror`),
/// `sharing.write`, `sharing.read`, `account_info.read`.
final class DropboxProvider: OAuthCloudProvider, CloudProvider {
    static let shared = DropboxProvider()
    private init() { super.init(service: .dropbox) }

    /// Bis zu dieser Größe in einem Stück (Dropbox erlaubt 150 MB), sonst in Stücken
    private static let singleLimit: UInt64 = 140 * 1024 * 1024
    private static let chunkSize = 8 * 1024 * 1024

    override var oauthRequest: CloudOAuth.Request? {
        guard let key = CloudKeys.value("BarDropCloudDropboxKey") else { return nil }
        return CloudOAuth.Request(authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                                  tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                                  clientID: key, clientSecret: nil,
                                  // Genau so bei Dropbox eintragen (der Port zählt mit)
                                  redirectURI: "http://127.0.0.1:\(CloudOAuth.port)/",
                                  scopes: [],
                                  // Refresh-Token, damit man nicht alle vier Stunden neu verbinden muss
                                  extra: ["token_access_type": "offline"])
    }

    func connect() async throws {
        var new = try await signIn()
        // Name des Kontos für die Einstellungen
        if let info = try? await json({ Self.request(URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!,
                                                     method: "POST", token: $0, json: false) }),
           let email = info["email"] as? String {
            new.account = email
            store(new)
        }
    }

    func upload(_ file: URL, name: String, progress: @escaping (Double?, String?) -> Void) async throws -> URL {
        let path = "/\(CloudService.folderName)/\(name)"
        let size = Self.size(of: file)
        let label = L("Uploading", "Wird hochgeladen") + " · " + Self.sizeLabel(size)
        progress(0, label)
        let uploaded: String
        if size <= Self.singleLimit {
            let data = try Data(contentsOf: file)
            let arg = Self.apiArg(["path": path, "mode": "add", "autorename": true, "mute": true])
            let meta = try await json({ token in
                var r = Self.request(URL(string: "https://content.dropboxapi.com/2/files/upload")!, method: "POST", token: token, json: false)
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                r.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
                return r
            }, body: data)
            uploaded = meta["path_lower"] as? String ?? path
        } else {
            uploaded = try await uploadSession(file, path: path, size: size, label: label, progress: progress)
        }
        progress(1, label)
        return try await sharedLink(uploaded)
    }

    private func uploadSession(_ file: URL, path: String, size: UInt64, label: String,
                               progress: @escaping (Double?, String?) -> Void) async throws -> String {
        let start = try await json({ token in
            var r = Self.request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!, method: "POST", token: token, json: false)
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.setValue(Self.apiArg(["close": false]), forHTTPHeaderField: "Dropbox-API-Arg")
            return r
        }, body: Data())
        guard let session = start["session_id"] as? String else { throw CloudError(message: L("Dropbox didn’t start the upload.", "Dropbox hat das Hochladen nicht begonnen.")) }
        var offset: UInt64 = 0
        while offset < size {
            try Task.checkCancellation()
            let piece = try Self.chunk(of: file, offset: offset, length: Self.chunkSize)
            guard !piece.isEmpty else { throw CloudError.fileChanged }
            let arg = Self.apiArg(["cursor": ["session_id": session, "offset": offset], "close": false])
            _ = try await json({ token in
                var r = Self.request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!, method: "POST", token: token, json: false)
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                r.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
                return r
            }, body: piece)
            offset += UInt64(piece.count)
            progress(Double(offset) / Double(max(size, 1)), label)
        }
        let finish = Self.apiArg(["cursor": ["session_id": session, "offset": offset],
                                  "commit": ["path": path, "mode": "add", "autorename": true, "mute": true]])
        let meta = try await json({ token in
            var r = Self.request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!, method: "POST", token: token, json: false)
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.setValue(finish, forHTTPHeaderField: "Dropbox-API-Arg")
            return r
        }, body: Data())
        return meta["path_lower"] as? String ?? path
    }

    /// Öffentlicher Link; gibt es schon einen, wird er genommen
    private func sharedLink(_ path: String) async throws -> URL {
        let (data, response) = try await send({ Self.request(URL(string: "https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings")!,
                                                             method: "POST", token: $0) },
                                              body: Self.body(["path": path]))
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if response.statusCode == 200, let link = object["url"] as? String, let url = URL(string: link) { return url }
        if String(decoding: data, as: UTF8.self).contains("shared_link_already_exists") {
            let list = try await json({ Self.request(URL(string: "https://api.dropboxapi.com/2/sharing/list_shared_links")!,
                                                     method: "POST", token: $0) },
                                      body: Self.body(["path": path, "direct_only": true]))
            if let links = list["links"] as? [[String: Any]], let link = links.first?["url"] as? String, let url = URL(string: link) {
                return url
            }
        }
        throw CloudError.http(response.statusCode, data, service: service)
    }

    func openFolder() {
        let folder = CloudService.folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "https://www.dropbox.com/home/\(folder)") { NSWorkspace.shared.open(url) }
    }

    func listFolder() async throws -> [CloudRemoteFile] {
        var result: [CloudRemoteFile] = []
        var page = try await listPage(URL(string: "https://api.dropboxapi.com/2/files/list_folder")!,
                                      ["path": "/\(CloudService.folderName)"])
        while true {
            for entry in page["entries"] as? [[String: Any]] ?? [] where entry[".tag"] as? String == "file" {
                guard let id = entry["id"] as? String, let name = entry["name"] as? String else { continue }
                result.append(CloudRemoteFile(id: id, name: name, size: (entry["size"] as? NSNumber)?.uint64Value ?? 0,
                                              version: entry["rev"] as? String ?? ""))
            }
            guard page["has_more"] as? Bool == true, let cursor = page["cursor"] as? String else { break }
            page = try await listPage(URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!, ["cursor": cursor])
        }
        return result
    }

    /// Eine Seite der Liste; gibt es den Ordner noch nicht (nichts hochgeladen), ist sie leer
    private func listPage(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await send({ Self.request(url, method: "POST", token: $0) }, body: Self.body(body))
        if response.statusCode == 409, String(decoding: data, as: UTF8.self).contains("not_found") { return [:] }
        guard response.statusCode == 200 else { throw CloudError.http(response.statusCode, data, service: service) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func download(_ file: CloudRemoteFile, to destination: URL) async throws {
        let arg = Self.apiArg(["path": file.id])
        try await download({ token in
            var r = Self.request(URL(string: "https://content.dropboxapi.com/2/files/download")!, method: "POST", token: token, json: false)
            r.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
            return r
        }, to: destination)
    }

    func delete(_ file: CloudRemoteFile) async throws {
        let (data, response) = try await send({ Self.request(URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!,
                                                             method: "POST", token: $0) },
                                              body: Self.body(["path": file.id]))
        // Schon weg ist auch gut
        if response.statusCode == 409, String(decoding: data, as: UTF8.self).contains("not_found") { return }
        guard response.statusCode == 200 else { throw CloudError.http(response.statusCode, data, service: service) }
    }

    /// Dropbox-API-Arg muss reines ASCII sein: Umlaute als \u-Folgen
    private static func apiArg(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        // Als UTF-16, damit Zeichen außerhalb der Grundebene (Emoji) zwei Folgen ergeben
        return String(decoding: data, as: UTF8.self).utf16.map { unit in
            unit < 0x80 ? String(UnicodeScalar(UInt8(unit))) : String(format: "\\u%04x", unit)
        }.joined()
    }
}
