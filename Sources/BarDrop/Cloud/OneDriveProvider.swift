import AppKit

/// OneDrive über Microsoft Graph, für private Konten und Konten von Firma oder Schule
/// (Anmeldung über „common“). Bereiche: `Files.ReadWrite`, `User.Read`, `offline_access`.
final class OneDriveProvider: OAuthCloudProvider, CloudProvider {
    static let shared = OneDriveProvider()
    private init() { super.init(service: .oneDrive) }

    /// Bis 4 MB in einem Stück, sonst Sitzung mit Stücken (Vielfache von 320 KB, laut
    /// Microsoft 5 bis 10 MB empfohlen)
    private static let singleLimit: UInt64 = 4 * 1024 * 1024
    private static let chunkSize = 32 * 320 * 1024
    private static let graph = "https://graph.microsoft.com/v1.0"

    override var oauthRequest: CloudOAuth.Request? {
        guard let id = CloudKeys.value("BarDropCloudMicrosoftClientID") else { return nil }
        // Bei Microsoft „http://localhost“ eintragen: Der Port zählt dort nicht mit
        return CloudOAuth.Request(authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                                  tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                                  clientID: id, clientSecret: nil,
                                  redirectURI: "http://localhost:\(CloudOAuth.port)/",
                                  scopes: ["Files.ReadWrite", "User.Read", "offline_access"])
    }

    func connect() async throws {
        var new = try await signIn()
        if let me = try? await json({ Self.request(URL(string: "\(Self.graph)/me")!, token: $0, json: false) }),
           let name = (me["mail"] as? String) ?? (me["userPrincipalName"] as? String) {
            new.account = name
            store(new)
        }
    }

    func upload(_ file: URL, name: String, progress: @escaping (Double?, String?) -> Void) async throws -> URL {
        let size = Self.size(of: file)
        let label = L("Uploading", "Lädt hoch") + " · " + Self.sizeLabel(size)
        progress(0, label)
        // „:“ trennt bei Microsoft Pfad und Befehl (root:/Pfad:/content): im Namen mitkodieren
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":")
        let path = "\(CloudService.folderName)/\(name)".addingPercentEncoding(withAllowedCharacters: allowed)
            ?? "\(CloudService.folderName)/upload"
        // Gleicher Name: Microsoft hängt eine Nummer an statt zu überschreiben
        let item: [String: Any]
        if size <= Self.singleLimit {
            let url = URL(string: "\(Self.graph)/me/drive/root:/\(path):/content?@microsoft.graph.conflictBehavior=rename")!
            item = try await json({ Self.request(url, method: "PUT", token: $0, json: false) }, body: try Data(contentsOf: file))
        } else {
            let start = URL(string: "\(Self.graph)/me/drive/root:/\(path):/createUploadSession")!
            let session = try await json({ Self.request(start, method: "POST", token: $0) },
                                         body: Self.body(["item": ["@microsoft.graph.conflictBehavior": "rename"]]))
            guard let target = (session["uploadUrl"] as? String).flatMap(URL.init(string:)) else {
                throw CloudError(message: L("OneDrive didn’t start the upload.", "OneDrive hat das Hochladen nicht begonnen."))
            }
            var offset: UInt64 = 0
            var last: [String: Any] = [:]
            var failures = 0
            while offset < size {
                try Task.checkCancellation()
                let piece = try Self.chunk(of: file, offset: offset, length: Self.chunkSize)
                guard !piece.isEmpty else { throw CloudError.fileChanged }
                // Die Adresse der Sitzung ist schon berechtigt: ohne Authorization-Kopf senden
                var request = URLRequest(url: target)
                request.httpMethod = "PUT"
                request.setValue("bytes \(offset)-\(offset + UInt64(piece.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                let data: Data, status: Int, http: HTTPURLResponse?
                do {
                    let (answer, response) = try await URLSession.shared.upload(for: request, from: piece)
                    data = answer
                    http = response as? HTTPURLResponse
                    status = http?.statusCode ?? 0
                } catch where Self.isTransient(error) && failures < Self.maxRetries {
                    // Netz weg: nachfragen, was angekommen ist, und dort weitermachen
                    offset = try await recover(&failures) { try await nextOffset(target, size: size) }
                    continue
                }
                if [200, 201, 202].contains(status) {
                    last = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    offset += UInt64(piece.count)
                    failures = 0
                    progress(Double(offset) / Double(max(size, 1)), label)
                } else if (Self.isTransient(status: status) || status == 416), failures < Self.maxRetries {
                    // 416: Dieses Stück hat Microsoft schon. Sonst kurz überlastet
                    offset = try await recover(&failures, response: http) { try await nextOffset(target, size: size) }
                } else {
                    throw CloudError.http(status, data, service: service)
                }
            }
            item = last
        }
        guard let id = item["id"] as? String else { throw CloudError(message: L("OneDrive didn’t save the file.", "OneDrive hat die Datei nicht gespeichert.")) }
        progress(1, label)
        return try await link(for: id)
    }

    /// Wie weit die Sitzung ist: der Anfang des ersten noch fehlenden Bereichs
    private func nextOffset(_ session: URL, size: UInt64) async throws -> UInt64 {
        let (data, response) = try await URLSession.shared.data(from: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let range = (object["nextExpectedRanges"] as? [String])?.first,
              let start = range.split(separator: "-").first.flatMap({ UInt64($0) }),
              start < size else { throw CloudError.http(status, data, service: service) }
        return start
    }

    /// Link für alle; schaltet die Firma das ab, ein Link für die eigene Organisation
    private func link(for id: String) async throws -> URL {
        let url = URL(string: "\(Self.graph)/me/drive/items/\(id)/createLink")!
        for scope in ["anonymous", "organization"] {
            let (data, response) = try await send({ Self.request(url, method: "POST", token: $0) },
                                                  body: Self.body(["type": "view", "scope": scope]))
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if [200, 201].contains(response.statusCode),
               let link = (object["link"] as? [String: Any])?["webUrl"] as? String, let result = URL(string: link) {
                return result
            }
            // Nur bei „nicht erlaubt“ die zweite Art versuchen
            guard response.statusCode == 403 || response.statusCode == 400 else { throw CloudError.http(response.statusCode, data, service: service) }
        }
        throw CloudError(message: L("OneDrive doesn’t allow sharing links for this account.", "OneDrive erlaubt für dieses Konto keine Links."),
                         hint: L("Your organization may have turned off sharing.", "Deine Organisation hat das Teilen vielleicht abgeschaltet."))
    }

    func listFolder() async throws -> [CloudRemoteFile] {
        let folder = CloudService.folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var next: URL? = URL(string: "\(Self.graph)/me/drive/root:/\(folder):/children?$select=id,name,size,eTag,file")
        var result: [CloudRemoteFile] = []
        while let url = next {
            let (data, response) = try await send({ Self.request(url, token: $0, json: false) })
            // Noch nichts hochgeladen: Den Ordner gibt es nicht
            if response.statusCode == 404 { return [] }
            guard response.statusCode == 200 else { throw CloudError.http(response.statusCode, data, service: service) }
            let page = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            for item in page["value"] as? [[String: Any]] ?? [] where item["file"] != nil {
                guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                result.append(CloudRemoteFile(id: id, name: name, size: (item["size"] as? NSNumber)?.uint64Value ?? 0,
                                              version: item["eTag"] as? String ?? ""))
            }
            next = (page["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return result
    }

    func download(_ file: CloudRemoteFile, to destination: URL) async throws {
        let url = URL(string: "\(Self.graph)/me/drive/items/\(file.id)/content")!
        try await download({ Self.request(url, token: $0, json: false) }, to: destination)
    }

    /// Landet im Papierkorb von OneDrive
    func delete(_ file: CloudRemoteFile) async throws {
        let url = URL(string: "\(Self.graph)/me/drive/items/\(file.id)")!
        let (data, response) = try await send({ Self.request(url, method: "DELETE", token: $0, json: false) })
        guard [204, 200, 404].contains(response.statusCode) else { throw CloudError.http(response.statusCode, data, service: service) }
    }

    func openFolder() {
        NSWorkspace.shared.open(URL(string: "https://onedrive.live.com/")!)
    }
}
