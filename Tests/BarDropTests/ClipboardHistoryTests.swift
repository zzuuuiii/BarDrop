import AppKit
import XCTest
@testable import BarDrop

/// Verlauf der Zwischenablage, mit eigener Zwischenablage und eigenem Ordner
final class ClipboardHistoryTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistory!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Verlauf-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("BarDropTest-\(UUID().uuidString)"))
        history = ClipboardHistory(folder: folder, pasteboard: pasteboard)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        history.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        history.check()
    }

    /// Text wird ein Eintrag, benannt nach der ersten Zeile; dasselbe noch einmal ergibt keinen zweiten
    func testTextBecomesEntryOnce() throws {
        copy("Hallo Welt\nzweite Zeile")
        copy("Hallo Welt\nzweite Zeile")
        let entries = history.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.lastPathComponent, "Hallo Welt.txt")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(entries.first), encoding: .utf8), "Hallo Welt\nzweite Zeile")
    }

    /// Passwörter und nur kurz Kopiertes (nspasteboard.org) bleiben draußen
    func testConcealedIsSkipped() {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString("geheim", forType: .string)
        history.check()
        XCTAssertTrue(history.entries().isEmpty)
    }

    /// Ein Link wird ein Link, kein Text
    func testLinkBecomesWebloc() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/seite")! as NSURL])
        pasteboard.setString("https://example.com/seite", forType: .string)
        history.check()
        XCTAssertEqual(history.entries().first?.pathExtension, "webloc")
    }

    /// Kopierte Dateien werden übernommen, das Original bleibt, wo es ist
    func testFilesAreKept() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Quelle-\(UUID().uuidString).txt")
        try "Inhalt".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])
        history.check()
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertEqual(entry.lastPathComponent, source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// Nur die neuesten Einträge bleiben
    func testKeepsOnlyLimit() {
        for i in 0..<(ClipboardHistory.limit + 3) { copy("Eintrag \(i)") }
        let names = history.entries().map(\.lastPathComponent)
        XCTAssertEqual(names.count, ClipboardHistory.limit)
        XCTAssertFalse(names.contains("Eintrag 0.txt"))
        XCTAssertTrue(names.contains("Eintrag \(ClipboardHistory.limit + 2).txt"))
    }

    /// Zurückkopieren legt den Text wieder ab, ohne neuen Eintrag
    func testCopyBackRestoresTextWithoutNewEntry() throws {
        copy("erstes")
        copy("zweites")
        let first = try XCTUnwrap(history.entries().first { $0.lastPathComponent == "erstes.txt" })
        history.copyBack(first)
        history.check()
        XCTAssertEqual(pasteboard.string(forType: .string), "erstes")
        XCTAssertEqual(history.entries().count, 2)
    }
}
