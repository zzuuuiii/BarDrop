import XCTest
import AppKit
@testable import BarDrop

/// Herausziehen: Datei-Versprechen, frische Kopien, Text und Links, verzögertes Löschen.
final class ExportTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropExport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func file(_ name: String, _ content: String) -> URL {
        let url = base.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
        return url
    }

    func testOwnFileIsOfferedAsFreshCopyLikeTheFinder() throws {
        let url = file("Bild.png", "x")
        let writer = DragExport.writer(for: ShelfFile(url: url, owned: true))
        let fresh = try XCTUnwrap((writer as? NSURL).map { $0 as URL }, "Eigene Dateien gehen wie im Finder als Adresse")
        XCTAssertNotEqual(fresh.standardizedFileURL, url.standardizedFileURL, "Frische Kopie statt gespeicherter Datei")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent())
    }

    func testPromiseOffersPromisePlusFileURL() throws {
        let url = file("Bild.png", "x")
        let provider = DragExport.promiseWriter(for: ShelfFile(url: url, owned: true))
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropExport-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let types = provider.writableTypes(for: pb)
        XCTAssertTrue(types.contains(.fileURL), "Programme ohne Versprechen brauchen die Adresse")
        XCTAssertTrue(types.contains { $0.rawValue.contains("promise") }, "Versprechen fehlt: \(types)")
        XCTAssertFalse(types.contains(.string), "Bilder bekommen keinen Text")
        if let fresh = provider.fileURL { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
    }

    func testUserFileIsOfferedAsPlainURL() {
        let url = file("Notiz.txt", "Hallo")
        let writer = DragExport.writer(for: ShelfFile(url: url, owned: false))
        XCTAssertTrue(writer is NSURL, "Dateien des Nutzers gehen wie im Finder als Adresse")
    }

    func testTextAndLinksTravelNatively() throws {
        let text = file("Notiz.txt", "Ein kleiner Text")
        let textProvider = try XCTUnwrap(DragExport.writer(for: ShelfFile(url: text, owned: true)) as? ExportPromiseProvider)
        XCTAssertEqual(textProvider.nativeString, "Ein kleiner Text")
        XCTAssertEqual(textProvider.pasteboardPropertyList(forType: .string) as? String, "Ein kleiner Text")

        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/a"], format: .xml, options: 0)
        let webloc = base.appendingPathComponent("Seite.webloc")
        try plist.write(to: webloc)
        let linkProvider = try XCTUnwrap(DragExport.writer(for: ShelfFile(url: webloc, owned: true)) as? ExportPromiseProvider)
        XCTAssertEqual(linkProvider.nativeURL?.absoluteString, "https://example.com/a")
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropExport-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        XCTAssertTrue(linkProvider.writableTypes(for: pb).contains(.URL))
    }

    func testPromiseIsFulfilledByCopying() throws {
        let source = file("Foto.png", "Bilddaten")
        let provider = DragExport.promiseWriter(for: ShelfFile(url: source, owned: true))
        let destination = base.appendingPathComponent("Ziel").appendingPathComponent("Foto.png")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let done = expectation(description: "Versprechen")
        var reported: Error?
        DragExporter.shared.filePromiseProvider(provider, writePromiseTo: destination) { error in
            reported = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(reported)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Bilddaten")
        XCTAssertFalse(DragExporter.shared.isBusy(source))
    }

    func testFailedPromiseIsReported() throws {
        let source = file("Weg.png", "x")
        let provider = DragExport.promiseWriter(for: ShelfFile(url: source, owned: true))
        try FileManager.default.removeItem(at: source)
        let done = expectation(description: "Fehler")
        DragExporter.shared.filePromiseProvider(provider, writePromiseTo: base.appendingPathComponent("x.png")) { error in
            XCTAssertNotNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(DragExporter.shared.failedRecently(source))
    }

    func testDeletionWaitsUntilCopyIsDone() {
        let url = file("gross.bin", "x")
        var ran = false
        // Keine Kopie aktiv: sofort
        DragExporter.shared.whenIdle(url) { ran = true }
        XCTAssertTrue(ran)
    }
}

/// Lesezeichen, beschädigte Listen, Zurückholen.
final class PersistenceTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropPersist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func userFile(_ name: String) -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("BarDropTestFiles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? Data("Inhalt".utf8).write(to: url)
        return url
    }

    func testMovedUserFileIsFoundAgain() throws {
        let original = userFile("Vertrag.pdf")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let store = ShelfStore(baseDirectory: base)
        store.add([ShelfFile(url: original, owned: false)])
        XCTAssertNotNil(store.entries.first?.files.first?.bookmark, "Dateien des Nutzers bekommen ein Lesezeichen")

        let moved = original.deletingLastPathComponent().appendingPathComponent("Vertrag umbenannt.pdf")
        try FileManager.default.moveItem(at: original, to: moved)
        store.pruneMissingFiles()

        XCTAssertEqual(store.entries.count, 1, "Verschobene Datei bleibt in der Ablage")
        XCTAssertEqual(store.entries.first?.files.first?.url.lastPathComponent, "Vertrag umbenannt.pdf")
    }

    func testCorruptEntryIsSkippedOthersSurvive() throws {
        let store = ShelfStore(baseDirectory: base)
        let keep = userFile("bleibt.txt")
        defer { try? FileManager.default.removeItem(at: keep.deletingLastPathComponent()) }
        store.add([ShelfFile(url: keep, owned: false)])

        // Einen kaputten Eintrag dazuschreiben
        let db = base.appendingPathComponent("shelf.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: db)) as? [Any])
        json.append(["kaputt": true])
        try JSONSerialization.data(withJSONObject: json).write(to: db)

        let reloaded = ShelfStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.count, 1)
    }

    func testUnreadableListIsKeptAsBackup() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: base.appendingPathComponent("shelf.json"))
        let items = base.appendingPathComponent("Items/abc")
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: items.appendingPathComponent("Bild.png"))

        let store = ShelfStore(baseDirectory: base)
        XCTAssertTrue(store.entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("shelf-unlesbar-") }, "Unlesbare Liste wird gesichert: \(names)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: items.appendingPathComponent("Bild.png").path),
                      "Gespeicherte Dateien dürfen dann nicht aufgeräumt werden")
    }

    func testRemovedOwnFileCanBeRestored() {
        let store = ShelfStore(baseDirectory: base)
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropPersist-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("Text zum Zurückholen", forType: .string)
        let done = expectation(description: "Ingest")
        store.ingest(from: pb) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        let url = store.entries[0].files[0].url

        store.removeFiles(at: [url], deleteOwnedAfter: 60)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Datei wird erst später gelöscht")

        store.restore(url)
        XCTAssertEqual(store.entries.count, 1, "Nach einem Fehler kommt das Objekt zurück")
    }
}
