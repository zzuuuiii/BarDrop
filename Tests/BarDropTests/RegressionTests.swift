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
}
