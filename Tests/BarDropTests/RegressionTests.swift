import AppKit
import XCTest
@testable import BarDrop

/// Fehler aus der Tiefenprüfung (01.11.2026): Jeder Test hält einen behobenen Fehler fest
final class RegressionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Regression-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Für den Rechte-Test wieder lesbar machen, sonst bliebe der Ordner liegen
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("gesperrt").path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Neu schreiben ersetzt in einem Schritt: Inhalt bleibt, keine Zwischendatei bleibt liegen
    func testRecreateKeepsContentAndLeavesNoTemporaryFile() throws {
        let file = dir.appendingPathComponent("bild.png")
        try Data("inhalt".utf8).write(to: file)
        FileSanitizer.recreate(file)
        XCTAssertEqual(try Data(contentsOf: file), Data("inhalt".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["bild.png"])
    }

    /// Eine fremde Datei am Ziel bleibt, wenn die saubere Kopie wegen „gibt es schon“ scheitert
    func testCleanCopyLeavesExistingTargetAlone() throws {
        let source = dir.appendingPathComponent("quelle.txt")
        let target = dir.appendingPathComponent("ziel.txt")
        try Data("neu".utf8).write(to: source)
        try Data("fremd".utf8).write(to: target)
        XCTAssertFalse(FileSanitizer.cleanCopy(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("fremd".utf8))
    }

    /// Fehlende Erlaubnis ist nicht dasselbe wie „gelöscht“: Die Ablage behält solche Dateien
    func testAccessDeniedIsNotMissing() throws {
        let locked = dir.appendingPathComponent("gesperrt", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("datei.txt")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertTrue(ShelfStore.accessDenied(file))
        XCTAssertFalse(ShelfStore.accessDenied(dir.appendingPathComponent("gibt-es-nicht.txt")))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        XCTAssertFalse(ShelfStore.accessDenied(file))
    }

    /// Lässt sich ein Eintrag nicht lesen, bleibt die Zwischenablage, wie sie war
    func testCopyBackKeepsClipboardWhenEntryIsUnreadable() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BarDropTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(folder: dir, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("vorher", forType: .string)
        history.copyBack(dir.appendingPathComponent("fehlt.txt"))
        XCTAssertEqual(pasteboard.string(forType: .string), "vorher")
    }

    /// Sehr große Zahl als Voreinstellung eines Plugins: als Text statt Absturz (Int-Überlauf)
    func testHugePluginNumberDoesNotCrash() {
        XCTAssertEqual(PluginValue.number(42).string, "42")
        XCTAssertEqual(PluginValue.number(1.5).string, "1.5")
        XCTAssertFalse(PluginValue.number(1e30).string.isEmpty)
        XCTAssertFalse(PluginValue.number(.infinity).string.isEmpty)
    }

    /// Namen aus Emoji passen unter die Grenze des Dateisystems (255 Bytes), die Endung bleibt
    func testLongEmojiNameFitsFileSystem() {
        let family = "👨‍👩‍👧‍👦"
        let name = ContentImporter.shortened(String(repeating: family, count: 30) + ".txt", to: ContentImporter.maxNameLength)
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
        XCTAssertTrue(name.hasSuffix(".txt"))
        // Gewöhnliche Namen bleiben unverändert
        XCTAssertEqual(ContentImporter.shortened("Bericht.pdf", to: ContentImporter.maxNameLength), "Bericht.pdf")
        let file = dir.appendingPathComponent(name)
        XCTAssertNoThrow(try Data("x".utf8).write(to: file))
    }

    /// „/Volumes/Macintosh HD“ ist ein Verweis auf das Startvolume, nicht ein getrenntes Laufwerk
    func testBootVolumeAliasIsOnline() throws {
        let alias = URL(fileURLWithPath: "/Volumes/Macintosh HD", isDirectory: true)
        try XCTSkipUnless((try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) == "/")
        XCTAssertNil(ShelfFile.offlineVolumeName(of: alias.appendingPathComponent("Users/x.txt")))
        XCTAssertEqual(ShelfFile.offlineVolumeName(of: URL(fileURLWithPath: "/Volumes/GibtEsNicht-\(UUID().uuidString)/a.txt")).map { $0.hasPrefix("GibtEsNicht") }, true)
    }

    /// Meldungen oben rechts in der Ablage passen in die 24 Zeichen, statt mit „…“ zu enden
    func testHeaderNoticesFitTheirSpace() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BarDrop")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"(?:announce|short:)\(?\s*L\("([^"\\]*)", "([^"\\]*)"\)"#)
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for group in 1...2 {
                    guard let range = Range(match.range(at: group), in: text) else { continue }
                    // Platzhalter wie \(service.title) zählen mit ihrem längsten Wert
                    let value = text[range].replacingOccurrences(of: #"\(service.title)"#, with: "Google Drive")
                    XCTAssertLessThanOrEqual(value.count, ShelfContent.statusLimit, "\(file.lastPathComponent): \(value)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }
}

