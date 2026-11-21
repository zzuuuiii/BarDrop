import AppKit
import CryptoKit
import Network
import Security

/// Ein Dienst, in den BarDrop hochlädt. Jeder Dienst kümmert sich selbst um Anmeldung,
/// Ordner und Link; `CloudManager` macht daraus Läufe mit Platzhalter in der Ablage.
protocol CloudProvider: AnyObject {
    var service: CloudService { get }
    /// Die Kennung der App beim Anbieter ist eingetragen (sonst lässt sich nicht verbinden)
    var isConfigured: Bool { get }
    var isConnected: Bool { get }
    /// Name oder E-Mail des Kontos, wenn bekannt
    var account: String? { get }
    func connect() async throws
    func disconnect()
    /// Lädt eine Datei in den Ordner „BarDrop Share“ und gibt den Link zum Teilen zurück.
    /// `progress`: 0…1 oder nil, solange der Dienst nichts meldet; `label` für den Platzhalter
    func upload(_ file: URL, name: String, progress: @escaping (Double?, String?) -> Void) async throws -> URL
    /// Der Ordner „BarDrop Share“ im Browser oder im Finder (Doppelklick auf die Aktion)
    func openFolder()
    /// Was in „BarDrop Share“ liegt (nur Dateien), für die Kopie auf dem Mac (`CloudMirror`)
    func listFolder() async throws -> [CloudRemoteFile]
    /// Eine Datei aus „BarDrop Share“ laden; `destination` gibt es danach
    func download(_ file: CloudRemoteFile, to destination: URL) async throws
    /// Eine Datei aus „BarDrop Share“ löschen (in den Papierkorb des Dienstes)
    func delete(_ file: CloudRemoteFile) async throws
}

/// Eine Datei im Ordner „BarDrop Share“ eines Dienstes. `version` ändert sich, sobald sich
/// die Datei ändert (Dropbox: rev, Google: Prüfsumme, OneDrive: eTag)
struct CloudRemoteFile: Codable, Hashable {
    var id: String
    var name: String
    var size: UInt64
    var version: String
}

extension CloudProvider {
    func listFolder() async throws -> [CloudRemoteFile] { [] }
    func download(_ file: CloudRemoteFile, to destination: URL) async throws {
        throw CloudError(message: L("\(service.title) can’t load files.", "\(service.title) kann keine Dateien laden."))
    }
    func delete(_ file: CloudRemoteFile) async throws {
        throw CloudError(message: L("\(service.title) can’t delete files.", "\(service.title) kann keine Dateien löschen."))
    }
}

/// Fehler mit verständlichem Text und Tipp, wie bei Plugins (`throw { message, hint }`)
struct CloudError: LocalizedError {
    let message: String
    var hint: String?
    /// Kurzfassung für oben rechts in der Ablage (höchstens 24 Zeichen, wie „Nicht umgewandelt“);
    /// ohne eigene steht dort „Nicht hochgeladen“. Die ganze Meldung bleibt im Protokoll
    var short: String?
    var errorDescription: String? { message }

    /// Datei ist beim Hochladen kürzer geworden: sonst liefe die Schleife ewig (leeres Stück)
    /// oder `last - 1` liefe bei Google und OneDrive unter null
    static var fileChanged: CloudError { CloudError(message: L("The file changed while uploading.", "Die Datei hat sich beim Hochladen geändert.")) }

    static func http(_ status: Int, _ body: Data, service: CloudService) -> CloudError {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
        if status == 401 {
            return CloudError(message: L("\(service.title): Sign-in expired.", "\(service.title): Anmeldung abgelaufen."),
                              hint: L("Connect again in Settings → Cloud.", "In Einstellungen → Cloud neu verbinden."),
                              short: L("Sign-in expired", "Anmeldung abgelaufen"))
        }
        if status == 507 || text.contains("insufficient_space") || text.contains("storageQuotaExceeded") {
            return CloudError(message: L("\(service.title) is full.", "\(service.title) ist voll."),
                              short: L("\(service.title) is full", "\(service.title) ist voll"))
        }
        return CloudError(message: L("\(service.title) answered with error \(status).", "\(service.title) meldet Fehler \(status)."),
                          hint: text.isEmpty ? nil : text)
    }
}

// MARK: Anmeldedaten

/// Zugangsdaten eines Dienstes, im Schlüsselbund (nie in den Einstellungen oder im Protokoll)
struct CloudToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expires: Date?
    var account: String?

    var isExpired: Bool { expires.map { $0.timeIntervalSinceNow < 60 } ?? false }
}

enum CloudKeychain {
    private static let serviceName = "BarDrop Cloud"
    /// In den Tests nie an den echten Schlüsselbund: Auf einem Mac mit verbundenem Dienst
    /// fragte macOS sonst nach dem Passwort für „BarDrop Cloud“ (Nutzer, 02.11.2026), und
    /// ein Test hätte echte Zugänge ändern oder löschen können
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    static func load(_ service: CloudService) -> CloudToken? {
        guard !isTesting else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: service.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CloudToken.self, from: data)
    }

    /// Nur ob ein Eintrag da ist (seine Merkmale, nicht der Inhalt): Dafür fragt macOS nicht
    /// nach dem Passwort, auch wenn der Eintrag von einer anderen Version von BarDrop stammt
    static func exists(_ service: CloudService) -> Bool {
        guard !isTesting else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: service.rawValue,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Kontoname zur Anzeige (kein Geheimnis), damit die Einstellungen ihn ohne den
    /// Schlüsselbund zeigen
    private static func accountKey(_ service: CloudService) -> String { "cloudAccount.\(service.rawValue)" }

    static func accountName(_ service: CloudService) -> String? {
        UserDefaults.standard.string(forKey: accountKey(service))
    }

    static func setAccountName(_ name: String?, for service: CloudService) {
        guard !isTesting else { return }
        UserDefaults.standard.set(name, forKey: accountKey(service))
    }

    static func save(_ token: CloudToken, for service: CloudService) {
        guard !isTesting else { return }
        guard let data = try? JSONEncoder().encode(token) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: serviceName,
                                   kSecAttrAccount as String: service.rawValue]
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // Sonst wäre die Anmeldung nach dem nächsten Start ohne jeden Hinweis weg
        if status != errSecSuccess {
            Diagnostics.shared.failure("cloud", "Schlüsselbund \(service.rawValue) status=\(status)")
        }
    }

    static func delete(_ service: CloudService) {
        guard !isTesting else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: service.rawValue]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: Kennungen der App bei den Anbietern

/// Kennungen der App bei Dropbox, Google und Microsoft. Sie sind nicht geheim (jede
/// Desktop-App liefert sie mit) und stehen in der Info.plist (`BarDropCloud…`). Zum Testen
/// lassen sie sich mit `defaults write com.zzuuuiii.bardrop BarDropCloudDropboxKey …`
/// überschreiben. Fehlt eine, ist der Dienst ausgegraut („Derzeit noch nicht verfügbar“).
/// Anleitung: docs/CLOUD.de.md
enum CloudKeys {
    static func value(_ key: String) -> String? {
        let own = UserDefaults.standard.string(forKey: key)
        let bundled = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let value = (own?.isEmpty == false ? own : bundled)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }
}

// MARK: Anmeldung im Browser

/// Anmeldung nach OAuth 2 mit PKCE, wie es Dropbox, Google und Microsoft für Apps ohne
/// eigenen Server vorsehen: Der Browser öffnet die Anmeldeseite, der Dienst leitet danach auf
/// `http://127.0.0.1:53682/` bzw. `http://localhost:53682/` um, wo BarDrop kurz lauscht und
/// den Code entgegennimmt. Fester Port, weil Dropbox die Adresse genau so eingetragen haben will.
enum CloudOAuth {
    static let port: UInt16 = 53682

    struct Request {
        var authorizeURL: URL
        var tokenURL: URL
        var clientID: String
        var clientSecret: String?
        var redirectURI: String
        var scopes: [String]
        /// Zusätzliche Angaben für die Anmeldeseite (etwa `token_access_type=offline`)
        var extra: [String: String] = [:]
    }

    /// Öffnet die Anmeldung und tauscht den Code gegen Zugangsdaten
    static func signIn(_ request: Request) async throws -> CloudToken {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        var components = URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "client_id", value: request.clientID),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: request.redirectURI),
                     URLQueryItem(name: "code_challenge", value: challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "state", value: state)]
        if !request.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: request.scopes.joined(separator: " "))) }
        items += request.extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        let receiver = LoopbackReceiver(port: port, state: state)
        try receiver.start()
        defer { receiver.stop() }
        guard let url = components.url else { throw CloudError(message: L("Sign-in address is invalid.", "Anmeldeadresse ist ungültig.")) }
        NSWorkspace.shared.open(url)
        // Höchstens 5 Minuten auf die Anmeldung warten
        let query = try await receiver.waitForQuery(timeout: 300)
        if let error = query["error"] {
            // Ohne passendes state könnte jede Webseite den Text bestimmen: dann nur allgemein melden
            guard query["state"] == state else { throw CloudError(message: L("Sign-in failed.", "Anmeldung fehlgeschlagen.")) }
            // Selbst abgebrochen: kein Fehler, den man noch lesen müsste (siehe CloudManager.connect)
            if error == "access_denied" { throw CancellationError() }
            throw CloudError(message: L("Sign-in failed: \(error)", "Anmeldung fehlgeschlagen: \(error)"))
        }
        guard query["state"] == state, let code = query["code"] else {
            throw CloudError(message: L("Sign-in failed.", "Anmeldung fehlgeschlagen."))
        }
        var form = ["grant_type": "authorization_code", "code": code, "client_id": request.clientID,
                    "redirect_uri": request.redirectURI, "code_verifier": verifier]
        if let secret = request.clientSecret { form["client_secret"] = secret }
        return try await token(request.tokenURL, form: form, previous: nil)
    }

    /// Neue Zugangsdaten mit dem Refresh-Token
    static func refresh(_ token: CloudToken, _ request: Request) async throws -> CloudToken {
        guard let refresh = token.refreshToken else { throw CloudError(message: L("Sign-in expired.", "Anmeldung abgelaufen.")) }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": request.clientID]
        if let secret = request.clientSecret { form["client_secret"] = secret }
        // Microsoft möchte beim Erneuern dieselben Bereiche
        if !request.scopes.isEmpty { form["scope"] = request.scopes.joined(separator: " ") }
        return try await self.token(request.tokenURL, form: form, previous: token)
    }

    private static func token(_ url: URL, form: [String: String], previous: CloudToken?) async throws -> CloudToken {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Refresh-Token abgelehnt (widerrufen oder abgelaufen, bei Google im Testbetrieb nach
        // 7 Tagen): Hilft nur neu verbinden, das soll die Meldung sagen statt „Fehler 400“
        if previous != nil, status == 401 || (status == 400 && String(decoding: data, as: UTF8.self).contains("invalid_grant")) {
            throw CloudError(message: L("Sign-in expired.", "Anmeldung abgelaufen."),
                             hint: L("Connect again in Settings → Cloud.", "In Einstellungen → Cloud neu verbinden."),
                             short: L("Sign-in expired", "Anmeldung abgelaufen"))
        }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw CloudError(message: L("Sign-in failed (\(status)).", "Anmeldung fehlgeschlagen (\(status))."),
                             hint: String(decoding: data.prefix(300), as: UTF8.self))
        }
        let expires = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return CloudToken(accessToken: access,
                          refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken,
                          expires: expires, account: previous?.account)
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }
}

/// Lauscht kurz auf dem lokalen Port, bis der Browser nach der Anmeldung zurückkommt.
/// Nur auf 127.0.0.1 (nicht im Netzwerk erreichbar). Antwortet mit einer kurzen Seite.
/// Alle Zustände nur auf `queue` geändert, darum ohne Sperren sicher
private final class LoopbackReceiver: @unchecked Sendable {
    private let port: UInt16
    /// Nur eine Antwort mit genau diesem state beendet das Warten. Sonst könnte jede Webseite
    /// mit einem Aufruf von 127.0.0.1:53682/?error=x die laufende Anmeldung abbrechen
    private let state: String
    private var listeners: [NWListener] = []
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// Kam der Browser schneller zurück, als gewartet wurde: hier aufheben
    private var early: Result<[String: String], Error>?
    private let queue = DispatchQueue(label: "bardrop.cloud.oauth")

    init(port: UInt16, state: String) {
        self.port = port
        self.state = state
    }

    func start() throws {
        // IPv4 und IPv6: „localhost“ landet je nach Browser auf dem einen oder anderen
        for host in ["127.0.0.1", "::1"] {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters) else { continue }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
            listeners.append(listener)
        }
        guard !listeners.isEmpty else {
            throw CloudError(message: L("Port \(port) is in use.", "Port \(port) ist belegt."),
                             hint: L("Close other apps that are signing in and try again.",
                                     "Andere Apps schließen, die gerade eine Anmeldung offen haben, und noch einmal versuchen."))
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    func waitForQuery(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.early { return continuation.resume(with: early) }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(CloudError(message: L("Sign-in took too long.", "Anmeldung hat zu lange gedauert."))))
                }
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else {
            if early == nil { early = result }
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // „GET /?code=…&state=… HTTP/1.1“
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
            let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
            let done = (query["code"] != nil || query["error"] != nil) && query["state"] == self.state
            let text = done ? L("Done. You can close this tab and go back to BarDrop.",
                                "Fertig. Du kannst diesen Tab schließen und zu BarDrop zurückgehen.")
                            : "BarDrop"
            let page = "<!doctype html><meta charset=utf-8><title>BarDrop</title><body style=\"font:15px -apple-system;margin:60px;text-align:center\">\(text)</body>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            // Favicon und andere Abrufe des Browsers zählen nicht
            if done { self.finish(.success(query)) }
        }
    }
}

// MARK: Hilfen

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    /// Für Formulare (application/x-www-form-urlencoded)
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// Gemeinsame Hilfen für Dienste mit Anmeldung (Dropbox, Google, Microsoft)
class OAuthCloudProvider {
    let service: CloudService
    /// Uploads, Abgleich und Anmeldung laufen nebeneinander: Zugang nur unter der Sperre lesen
    /// und schreiben
    private let lock = NSLock()
    private var storedToken: CloudToken?
    /// Zugang erst lesen, wenn er gebraucht wird (Hochladen, Abgleich), nicht schon beim
    /// Öffnen von Einstellungen → Cloud oder des Rechtsklicks: Nach jedem Update fragte macOS
    /// dort nach dem Schlüsselbund-Passwort (Nutzer, 17.11.2026)
    private var tokenLoaded = false
    /// Ob ein Zugang im Schlüsselbund liegt; gelesen ohne den Zugang selbst, also ohne Abfrage
    private var storedExists: Bool?
    private(set) var token: CloudToken? {
        get {
            lock.withLock {
                if !tokenLoaded {
                    storedToken = CloudKeychain.load(service)
                    tokenLoaded = true
                    // Ältere Versionen merkten sich den Kontonamen noch nicht
                    if let name = storedToken?.account, CloudKeychain.accountName(service) == nil {
                        CloudKeychain.setAccountName(name, for: service)
                    }
                }
                return storedToken
            }
        }
        set { lock.withLock { storedToken = newValue; tokenLoaded = true } }
    }
    /// Laufende Erneuerung: Wer gleichzeitig einen neuen Zugang braucht, wartet auf diese.
    /// Zwei Erneuerungen mit demselben Refresh-Token meldeten bei Microsoft (das ihn dabei
    /// austauscht) die zweite als ungültig und damit ab
    private var refreshing: Task<CloudToken, Error>?

    init(service: CloudService) {
        self.service = service
    }

    /// Von den Unterklassen: Kennungen und Adressen des Dienstes; nil, wenn nicht eingerichtet
    var oauthRequest: CloudOAuth.Request? { nil }

    var isConfigured: Bool { oauthRequest != nil }
    var isConnected: Bool {
        lock.withLock {
            if tokenLoaded { return storedToken != nil }
            if storedExists == nil { storedExists = CloudKeychain.exists(service) }
            return storedExists ?? false
        }
    }

    /// Konto für die Anzeige, ohne den Zugang aus dem Schlüsselbund zu lesen
    var account: String? {
        lock.withLock { tokenLoaded ? storedToken?.account : nil } ?? CloudKeychain.accountName(service)
    }

    func store(_ new: CloudToken) {
        token = new
        CloudKeychain.save(new, for: service)
        CloudKeychain.setAccountName(new.account, for: service)
        DispatchQueue.main.async { CloudManager.shared.objectWillChange.send() }
    }

    func disconnect() {
        token = nil
        CloudKeychain.delete(service)
        CloudKeychain.setAccountName(nil, for: service)
        if Thread.isMainThread {
            CloudManager.shared.objectWillChange.send()
        } else {
            DispatchQueue.main.async { CloudManager.shared.objectWillChange.send() }
        }
    }

    /// Zugang erneuern, gleichzeitige Anfragen teilen sich eine Erneuerung
    private func refresh(_ current: CloudToken, _ request: CloudOAuth.Request) async throws -> CloudToken {
        // Hat eine andere Anfrage den Zugang gerade erneuert, ihn nehmen: Ein zweites Erneuern
        // mit dem alten Refresh-Token scheitert bei Diensten, die ihn dabei austauschen.
        // (Vor der Sperre lesen: `token` nimmt sie selbst.)
        if let latest = token, latest.accessToken != current.accessToken, !latest.isExpired {
            return latest
        }
        let task: Task<CloudToken, Error> = lock.withLock {
            if let running = refreshing { return running }
            let task = Task { () throws -> CloudToken in
                defer { self.lock.withLock { self.refreshing = nil } }
                let fresh = try await CloudOAuth.refresh(current, request)
                // Während der Erneuerung getrennt: nicht wieder verbinden
                guard self.token != nil else { throw CancellationError() }
                self.store(fresh)
                return fresh
            }
            refreshing = task
            return task
        }
        return try await task.value
    }

    func signIn() async throws -> CloudToken {
        guard let request = oauthRequest else {
            throw CloudError(message: L("\(service.title) isn’t set up in this version of BarDrop.",
                                        "\(service.title) ist in dieser Version von BarDrop nicht eingerichtet."))
        }
        let new = try await CloudOAuth.signIn(request)
        store(new)
        return new
    }

    /// Gültiger Zugang, bei Bedarf erneuert
    func accessToken() async throws -> String {
        guard let current = token, let request = oauthRequest else {
            throw CloudError(message: L("\(service.title) isn’t connected.", "\(service.title) ist nicht verbunden."),
                             hint: L("Connect it in Settings → Cloud.", "In Einstellungen → Cloud verbinden."),
                             short: L("Not connected", "Nicht verbunden"))
        }
        guard current.isExpired else { return current.accessToken }
        return try await refresh(current, request).accessToken
    }

    // MARK: Neuer Versuch beim Hochladen

    /// So oft hintereinander wird ein Stück neu versucht, bevor das Hochladen aufgibt
    static let maxRetries = 4
    /// Wartezeit vor dem 1., 2., 3. … neuen Versuch (zusammen rund eine halbe Minute)
    private static let retryDelays: [Double] = [1, 3, 8, 20]

    /// Netz kurz weg, Zeitüberschreitung, WLAN gewechselt: später wieder versuchen
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .dataNotAllowed].contains(error.code)
    }

    /// Zu viele Anfragen (429) oder Fehler beim Dienst (5xx, außer „voll“)
    static func isTransient(status: Int) -> Bool {
        status == 429 || ((500...599).contains(status) && status != 507)
    }

    /// Vor einem neuen Versuch warten; nennt der Dienst eine Wartezeit (Retry-After), gilt sie
    static func waitBeforeRetry(_ attempt: Int, response: HTTPURLResponse? = nil) async throws {
        var delay = retryDelays[min(max(attempt, 1), retryDelays.count) - 1]
        if let value = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) {
            delay = min(max(seconds, delay), 120)
        }
        Diagnostics.shared.record("cloud", "neuer Versuch \(attempt) in \(Int(delay)) s")
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Nach einem Fehler warten und fragen, wie weit der Dienst ist (`ask`). Scheitert auch das
    /// am Netz, wird es weiter versucht, bis `maxRetries` erreicht ist. Zählt `failures` hoch.
    func recover<T>(_ failures: inout Int, response: HTTPURLResponse? = nil,
                    _ ask: () async throws -> T) async throws -> T {
        var response = response
        while true {
            failures += 1
            try await Self.waitBeforeRetry(failures, response: response)
            do {
                return try await ask()
            } catch where Self.isTransient(error) && failures < Self.maxRetries {
                response = nil
            }
        }
    }

    /// Anfrage mit Zugang; bei 401 einmal mit erneuertem Zugang wiederholen
    func send(_ make: (String) -> URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = make(try await accessToken())
        if let body { request.httpBody = body }
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, let current = token, let oauth = oauthRequest {
            let fresh = try await refresh(current, oauth)
            request = make(fresh.accessToken)
            if let body { request.httpBody = body }
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError(message: L("No answer.", "Keine Antwort.")) }
        return (data, http)
    }

    /// JSON-Antwort, sonst ein verständlicher Fehler
    func json(_ make: (String) -> URLRequest, body: Data? = nil, accept: Set<Int> = [200, 201]) async throws -> [String: Any] {
        let (data, response) = try await send(make, body: body)
        guard accept.contains(response.statusCode) else { throw CloudError.http(response.statusCode, data, service: service) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func request(_ url: URL, method: String = "GET", token: String, json: Bool = true) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if json { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static func body(_ object: Any) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    /// Datei herunterladen, direkt auf die Platte statt in den Speicher; bei 401 einmal mit
    /// erneuertem Zugang wiederholen (wie `send`)
    func download(_ make: (String) -> URLRequest, to destination: URL) async throws {
        var (temporary, response) = try await URLSession.shared.download(for: make(try await accessToken()))
        if (response as? HTTPURLResponse)?.statusCode == 401, let current = token, let oauth = oauthRequest {
            // Über die gemeinsame Erneuerung, nie zwei mit demselben Refresh-Token (siehe `refreshing`)
            let fresh = try await refresh(current, oauth)
            try? FileManager.default.removeItem(at: temporary)
            (temporary, response) = try await URLSession.shared.download(for: make(fresh.accessToken))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = (try? Data(contentsOf: temporary)) ?? Data()
            try? FileManager.default.removeItem(at: temporary)
            throw CloudError.http(status, body, service: service)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temporary, to: destination)
    }

    /// Teil einer Datei lesen (Hochladen in Stücken, ohne die ganze Datei im Speicher)
    static func chunk(of file: URL, offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    static func size(of file: URL) -> UInt64 {
        UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func sizeLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
