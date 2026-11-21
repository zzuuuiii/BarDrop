import XCTest
@testable import BarDrop

final class CloudTests: XCTestCase {
    /// Eine Cloud-Aktion kennt ihren Dienst; unbekannte Dienste (neuere Fassung) ergeben keinen
    func testCloudActionKnowsItsService() throws {
        let action = QuickAction(kind: .cloud, path: CloudService.dropbox.rawValue)
        XCTAssertEqual(action.cloudService, .dropbox)
        XCTAssertEqual(action.title, "Dropbox")
        XCTAssertNil(QuickAction(kind: .cloud, path: "unbekannt").cloudService)
        XCTAssertNil(QuickAction(kind: .folder, path: "dropbox").cloudService)
        // Bleibt beim Speichern der Aktionsleiste erhalten
        let data = try JSONEncoder().encode([action, QuickAction(kind: .clipboard)])
        let decoded = try JSONDecoder().decode([QuickAction].self, from: data)
        XCTAssertEqual(decoded.map(\.kind), [.cloud, .clipboard])
        XCTAssertEqual(decoded.first?.cloudService, .dropbox)
    }

    /// Ohne eingetragene Kennung ist ein Dienst „nicht eingerichtet“, Leerzeichen zählen nicht
    func testMissingKeysMeanNotConfigured() {
        let key = "BarDropCloudTestKey"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertNil(CloudKeys.value(key))
        UserDefaults.standard.set("  ", forKey: key)
        XCTAssertNil(CloudKeys.value(key))
        UserDefaults.standard.set(" abc ", forKey: key)
        XCTAssertEqual(CloudKeys.value(key), "abc")
    }

    /// PKCE: Prüfwert in Base64URL ohne Füllzeichen, Formularwerte richtig maskiert
    func testOAuthEncoding() {
        XCTAssertEqual(Data([0xfb, 0xff, 0xfe]).base64URL, "-__-")
        XCTAssertEqual("a b&c=d/ü".formEncoded, "a%20b%26c%3Dd%2F%C3%BC")
        let verifier = CloudOAuth.randomString(64)
        XCTAssertEqual(verifier.count, 64)
        XCTAssertNotEqual(verifier, CloudOAuth.randomString(64))
    }

    /// Jeder Dienst hat ein gültiges Symbol in Plugin-Form (für Platzhalter und Menüs)
    func testServiceIcons() {
        for service in CloudService.allCases {
            XCTAssertNotNil(PluginManifest.Icon.parse(service.icon.color ?? ""), service.rawValue)
            XCTAssertFalse(service.title.isEmpty)
        }
    }

    /// Neuer Versuch beim Hochladen: nur bei vorübergehenden Fehlern
    func testTransientUploadErrors() {
        XCTAssertTrue(OAuthCloudProvider.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(OAuthCloudProvider.isTransient(URLError(.timedOut)))
        XCTAssertFalse(OAuthCloudProvider.isTransient(URLError(.cancelled)))
        XCTAssertFalse(OAuthCloudProvider.isTransient(CancellationError()))
        XCTAssertTrue(OAuthCloudProvider.isTransient(status: 429))
        XCTAssertTrue(OAuthCloudProvider.isTransient(status: 503))
        XCTAssertFalse(OAuthCloudProvider.isTransient(status: 507))   // voll
        XCTAssertFalse(OAuthCloudProvider.isTransient(status: 401))
        XCTAssertFalse(OAuthCloudProvider.isTransient(status: 404))
    }

    /// Dropbox: Stück war schon angekommen, weiter beim genannten Stand
    func testDropboxCorrectOffset() {
        let body = Data(#"{"error_summary":"incorrect_offset/..","error":{".tag":"incorrect_offset","correct_offset":8388608}}"#.utf8)
        XCTAssertEqual(DropboxProvider.correctOffset(body), 8_388_608)
        XCTAssertNil(DropboxProvider.correctOffset(Data(#"{"error":{".tag":"not_found"}}"#.utf8)))
        XCTAssertNil(DropboxProvider.correctOffset(Data("kaputt".utf8)))
    }
}
