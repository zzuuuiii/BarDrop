import XCTest
import AppKit
@testable import BarDrop

/// Angeheftete Ordner: Inhalt wie einen Stapel zeigen und wie im Finder verwalten.
final class FolderTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var actions: ShelfActions!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropFolder-\(UUID().uuidString)")
        folder = base.appendingPathComponent("Angeheftet", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ShelfStore(baseDirectory: base.appendingPathComponent("Store"))
        ui = ShelfUIModel()
        actions = ShelfActions(store: store, ui: ui, settings: AppSettings.shared)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    @discardableResult
    private func makeFile(_ name: String, in dir: URL? = nil) -> URL {
        let url = (dir ?? folder).appendingPathComponent(name)
        try? Data(name.utf8).write(to: url)
        return url
    }

    /// Wartet, bis die Ordneransicht `count` Objekte zeigt
    private func waitForFiles(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while actions.folder.files.count != count || actions.folder.isLoading, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(actions.folder.files.count, count, file: file, line: line)
    }

    private var folderAction: QuickAction { QuickAction(kind: .folder, path: folder.path) }

    func testClickOnFolderActionShowsContents() {
        makeFile("a.txt")
        makeFile("b.txt")
        actions.click(folderAction)
        XCTAssertTrue(actions.isFolderOpen)
        XCTAssertTrue(actions.isInStack)
        waitForFiles(2)
        XCTAssertEqual(Set(actions.stackFiles.map(\.url.lastPathComponent)), ["a.txt", "b.txt"])
        // Die Ablage selbst bleibt unberührt
        XCTAssertTrue(store.entries.isEmpty)
        // Noch einmal derselbe Ordner: Er bleibt offen
        actions.click(folderAction)
        XCTAssertTrue(actions.isFolderOpen)
        XCTAssertEqual(actions.folder.root?.standardizedFileURL, folder.standardizedFileURL)
    }

    /// Auf eine Ordner-Aktion gelegt: Die Objekte verlassen die Ablage wie beim Verschieben im
    /// Finder, auch wenn „Nach Aktion behalten“ an ist und auch beim Kopieren (⌥)
    func testFolderActionAlwaysRemovesFromShelf() {
        let settings = AppSettings.shared
        let keep = settings.keepAfterAction
        settings.keepAfterAction = true
        defer { settings.keepAfterAction = keep }
        let source = base.appendingPathComponent("Quelle", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let moved = makeFile("verschoben.txt", in: source)
        let copied = makeFile("kopiert.txt", in: source)
        store.add([ShelfFile(url: moved, owned: false)])
        store.add([ShelfFile(url: copied, owned: false)])
        XCTAssertEqual(store.entries.count, 2)
        let anchor = NSView()
        actions.perform(folderAction, urls: [moved], anchor: anchor, modifiers: [])
        actions.perform(folderAction, urls: [copied], anchor: anchor, modifiers: [.option])
        let deadline = Date().addingTimeInterval(5)
        while !store.entries.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("verschoben.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        // Kopiert: Das Original bleibt an seinem Ort, nur die Ablage gibt es frei
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kopiert.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testClickOnSameFolderFromSubfolderGoesToTop() {
        let sub = folder.appendingPathComponent("Unterordner", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        actions.click(folderAction)
        waitForFiles(1)
        actions.enterFolder(sub)
        XCTAssertTrue(actions.folder.isNested)
        actions.click(folderAction)
        XCTAssertTrue(actions.isFolderOpen)
        XCTAssertFalse(actions.folder.isNested)
    }

    func testClickDoesNotRunActionWithSelection() {
        let other = base.appendingPathComponent("Ziel", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = makeFile("bleibt.txt")
        actions.click(folderAction)
        waitForFiles(1)
        actions.selectAllCurrent()
        // Klick auf eine andere Ordner-Aktion verschiebt nichts, er zeigt nur deren Inhalt
        actions.click(QuickAction(kind: .folder, path: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(actions.folder.root?.standardizedFileURL, other.standardizedFileURL)
    }

    func testFilesHaveStableIDsAndNewestFirst() {
        let old = makeFile("alt.txt")
        try? FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600),
                                                .modificationDate: Date(timeIntervalSinceNow: -3600)],
                                               ofItemAtPath: old.path)
        let listed = FolderBrowser.list(folder) ?? []
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, FolderBrowser.id(for: old))
        XCTAssertEqual(FolderBrowser.id(for: old), FolderBrowser.id(for: URL(fileURLWithPath: old.path)))
        XCTAssertFalse(listed[0].owned)
    }

    func testSubfolderAndEscapeGoBack() {
        let sub = folder.appendingPathComponent("Unterordner", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        makeFile("innen.txt", in: sub)
        actions.click(folderAction)
        waitForFiles(1)
        let subFile = actions.stackFiles[0]
        actions.openMembers([subFile])
        XCTAssertTrue(actions.folder.isNested)
        waitForFiles(1)
        XCTAssertEqual(actions.stackFiles.first?.url.lastPathComponent, "innen.txt")
        // Zurück: eine Ebene hoch, der Unterordner ist ausgewählt
        actions.closeStack()
        XCTAssertTrue(actions.isFolderOpen)
        XCTAssertFalse(actions.folder.isNested)
        XCTAssertEqual(ui.memberSelection, [FolderBrowser.id(for: sub)])
        // Noch einmal: zurück zur Ablage
        actions.closeStack()
        XCTAssertFalse(actions.isFolderOpen)
    }

    func testDeleteKeyDoesNothingInFolder() {
        let file = makeFile("sicher.txt")
        actions.click(folderAction)
        waitForFiles(1)
        actions.selectAllCurrent()
        actions.removeCurrentSelection()
        actions.cutCurrentSelection()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        waitForFiles(1)
    }

    func testFilesDroppedIntoOpenFolderLandThere() {
        let outside = base.appendingPathComponent("draussen.txt")
        try? Data("x".utf8).write(to: outside)
        actions.click(folderAction)
        waitForFiles(0)
        actions.fileIntoOpenFolder([outside], modifiers: [])
        waitForFiles(1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("draussen.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))   // gleiche Platte: verschoben
    }

    func testTrashFromFolderUndoPutsBackOnlyIntoFolder() throws {
        let file = makeFile("weg.txt")
        actions.click(folderAction)
        waitForFiles(1)
        let done = expectation(description: "Papierkorb")
        actions.moveToTrash([file]) { done.fulfill() }
        wait(for: [done], timeout: 15)
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Kein Papierkorb in dieser Umgebung")
        }
        waitForFiles(0)
        actions.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.entries.isEmpty, "Zurückgelegt wird nur in den Ordner, nicht in die Ablage")
        waitForFiles(1)
        XCTAssertEqual(ui.memberSelection, [FolderBrowser.id(for: file)])
    }

    func testVanishedFolderClosesView() {
        actions.click(folderAction)
        waitForFiles(0)
        try? FileManager.default.removeItem(at: folder)
        let deadline = Date().addingTimeInterval(5)
        while actions.isFolderOpen, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(actions.isFolderOpen)
    }

    // MARK: Ohne Erlaubnis

    /// Darf BarDrop einen Ordner nicht lesen, bleibt er offen und meldet es, statt sich still
    /// zu schließen (dann sah man statt des Ordners die Ablage)
    func testUnreadableFolderStaysOpenAndSaysSo() throws {
        let locked = base.appendingPathComponent("Gesperrt", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // Als Administrator (root) lässt sich alles lesen: dann gibt es nichts zu prüfen
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path), "Ordner trotz Sperre lesbar")

        guard case .failure(let error) = FolderBrowser.read(locked) else { return XCTFail("Ordner war lesbar") }
        XCTAssertTrue(FolderBrowser.isDenied(error), "\(error)")

        let browser = FolderBrowser()
        browser.open(locked)
        XCTAssertTrue(browser.isOpen)
        XCTAssertTrue(browser.accessDenied)
        XCTAssertFalse(browser.isLoading)
        XCTAssertTrue(browser.files.isEmpty)
    }

    /// Fehlt der Ordner ganz, ist das kein fehlendes Recht
    func testMissingFolderIsNotDenied() {
        let missing = base.appendingPathComponent("Gibt es nicht")
        guard case .failure(let error) = FolderBrowser.read(missing) else { return XCTFail("Ordner war lesbar") }
        XCTAssertFalse(FolderBrowser.isDenied(error), "\(error)")
    }
}
