import XCTest
import AppKit
@testable import BarDrop

/// Stapel: öffnen, Dateien auswählen, lösen, entfernen, zusammenfassen.
final class StackTests: XCTestCase {
    private var base: URL!
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var actions: ShelfActions!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropStack-\(UUID().uuidString)")
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
        AppSettings.shared.keepAfterAction = false
        store = ShelfStore(baseDirectory: base)
        ui = ShelfUIModel()
        actions = ShelfActions(store: store, ui: ui, settings: AppSettings.shared)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    /// Legt `count` Textdateien als einen Stapel ab.
    private func makeStack(_ count: Int) -> ShelfEntry {
        let folder = base.appendingPathComponent("src-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (1...count).map { i -> URL in
            let u = folder.appendingPathComponent("datei\(i).txt")
            try? Data("\(i)".utf8).write(to: u)
            return u
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropStack-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        let done = expectation(description: "Ingest")
        store.ingest(from: pb) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        return store.entries[0]
    }

    /// Wie das Aufräumen der Einführung: Nur die genannte Datei verlässt den Stapel,
    /// die übrigen bleiben samt Eintrag erhalten.
    func testForgettingOneFileKeepsRestOfStack() {
        let stack = makeStack(3)
        let first = stack.files[0].url
        store.forgetFiles(at: [first])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, stack.id)
        XCTAssertEqual(store.entries[0].files.map(\.url), Array(stack.files.dropFirst()).map(\.url))
    }

    /// Alles entfernen, während ein Stapel offen ist: keine unsichtbare Auswahl bleibt zurück.
    func testRemovingOpenStackLeavesNoSelection() {
        let stack = makeStack(3)
        actions.openStack(stack)
        actions.remove(store.entries)
        XCTAssertNil(ui.openStack)
        XCTAssertTrue(ui.selection.isEmpty)
        XCTAssertFalse(actions.hasCurrentSelection, "Escape schließt danach gleich die Ablage")
    }

    /// Pfeiltasten springen um so viele Kacheln, wie eine Reihe tatsächlich hat.
    func testColumnCountFollowsIconSizeAndWidth() {
        let settings = AppSettings.shared
        let (width, icon) = (settings.shelfWidth, settings.tileIconSize)
        defer { settings.shelfWidth = width; settings.tileIconSize = icon }
        settings.shelfWidth = 240; settings.tileIconSize = 64
        XCTAssertEqual(actions.columnCount, 2, "Standard wie bisher")
        settings.tileIconSize = 40
        XCTAssertEqual(actions.columnCount, 3)
        settings.shelfWidth = 360; settings.tileIconSize = 64
        XCTAssertEqual(actions.columnCount, 3)
    }

    func testSelectAllAndRemoveInsideStack() {
        let stack = makeStack(4)
        actions.openStack(stack)
        XCTAssertTrue(actions.isInStack)

        actions.selectAllCurrent()
        XCTAssertEqual(ui.memberSelection.count, 4)
        XCTAssertEqual(actions.currentSelectionURLs.count, 4)

        // Zwei abwählen, Rest entfernen
        let files = actions.stackFiles
        actions.selectMember(files[0], modifiers: .command)
        actions.selectMember(files[1], modifiers: .command)
        XCTAssertEqual(ui.memberSelection.count, 2)
        actions.removeCurrentSelection()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.count, 2)
    }

    func testShiftSelectionAndDetach() {
        let stack = makeStack(5)
        actions.openStack(stack)
        let files = actions.stackFiles

        actions.selectMember(files[1], modifiers: [])
        actions.selectMember(files[3], modifiers: .shift)
        XCTAssertEqual(ui.memberSelection, Set(files[1...3].map(\.id)))

        actions.detachMembers(actions.selectedMembers)
        XCTAssertEqual(store.entries.count, 4, "1 Stapel mit 2 Dateien + 3 gelöste Einträge")
        XCTAssertEqual(store.entries[0].files.count, 2)
    }

    func testArrowKeysMoveSelectionInStack() {
        let stack = makeStack(3)
        actions.openStack(stack)
        actions.moveCurrentSelection(by: 1, extend: false)
        XCTAssertEqual(actions.selectedMembers.first?.id, actions.stackFiles[0].id)
        actions.moveCurrentSelection(by: 1, extend: true)
        XCTAssertEqual(ui.memberSelection.count, 2)
    }

    func testClosingStackKeepsShelfAndClearsMemberSelection() {
        let stack = makeStack(3)
        actions.openStack(stack)
        actions.selectAllCurrent()
        actions.closeStack()
        XCTAssertFalse(actions.isInStack)
        XCTAssertTrue(ui.memberSelection.isEmpty)
        XCTAssertEqual(ui.selection, [stack.id], "Der verlassene Stapel ist danach ausgewählt")
    }

    func testMergingSelectionBuildsOneStack() {
        AppSettings.shared.stackThreshold = 10   // einzeln ablegen
        _ = makeStack(3)
        XCTAssertEqual(store.entries.count, 3)

        actions.mergeSelection(store.entries)    // „Als Stapel zusammenfassen“

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.count, 3)
        XCTAssertTrue(ui.selection.isEmpty)
    }

    func testRemovingFilesAfterActionKeepsOthers() {
        let stack = makeStack(3)
        let url = stack.files[0].url
        store.removeFiles(at: [url], deleteOwnedAfter: 0)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.count, 2)
        XCTAssertFalse(store.entries[0].files.contains { $0.url == url })
    }

    /// „Neuer Ordner mit Auswahl“: Kopien im Ordner, der an die Stelle der Objekte tritt;
    /// die Dateien im Finder bleiben, ⌘Z holt die Objekte zurück
    func testNewFolderWithSelection() throws {
        let stack = makeStack(2)
        let originals = stack.files.map(\.url)
        actions.makeFolder(with: [stack])
        XCTAssertEqual(store.entries.count, 1)
        let folder = try XCTUnwrap(store.entries.first?.files.first)
        XCTAssertTrue(folder.owned)
        let inside = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        XCTAssertEqual(inside, originals.map(\.lastPathComponent).sorted())
        XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(ui.selection, [store.entries[0].id])
        actions.undo()
        XCTAssertTrue(store.entries.contains { $0.id == stack.id })
    }

    /// Leerer neuer Ordner kommt ganz nach vorn
    func testEmptyNewFolder() throws {
        _ = makeStack(2)
        actions.makeFolder(with: [])
        let folder = try XCTUnwrap(store.entries.first?.files.first)
        XCTAssertEqual(folder.url.lastPathComponent, L("New Folder", "Neuer Ordner"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), [])
        XCTAssertEqual(store.entries.count, 2)
    }

    /// Ergebnisse eines Laufs auf einen ganzen Stapel (Umwandeln, Plugin): als eigener Stapel
    /// links daneben, alle Ergebnisse des Laufs zusammen; der Stapel selbst bleibt unverändert
    func testResultsOfWholeStackFormOwnStack() throws {
        let stack = makeStack(3)
        let group = try XCTUnwrap(actions.resultGroup())
        func result(_ name: String) -> [ShelfFile] {
            let url = base.appendingPathComponent("out-\(UUID().uuidString)-\(name)")
            FileManager.default.createFile(atPath: url.path, contents: Data(name.utf8))
            return store.adoptResults([url])
        }
        store.insertResults(result("a"), nextTo: stack.files[0].id, replacing: false, group: group)
        store.insertResults(result("b"), nextTo: stack.files[1].id, replacing: false, group: group)
        store.insertResults(result("c"), nextTo: stack.files[2].id, replacing: false, group: group)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].files.count, 3, "Ergebnisse als eigener Stapel")
        XCTAssertEqual(store.entries[1].id, stack.id)
        XCTAssertEqual(store.entries[1].files.map(\.id), stack.files.map(\.id), "Stapel unverändert")
        // Ein neuer Lauf bekommt einen neuen Stapel
        store.insertResults(result("d"), nextTo: stack.files[0].id, replacing: false, group: UUID())
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries[1].files.count, 1)
    }

    /// Im geöffneten Stapel bleiben Ergebnisse im Stapel, neben dem Original
    func testResultsInsideOpenStackStayInStack() {
        let stack = makeStack(2)
        ui.openStack = stack.id
        XCTAssertNil(actions.resultGroup())
        let url = base.appendingPathComponent("out-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        store.insertResults(store.adoptResults([url]), nextTo: stack.files[1].id, replacing: false,
                            group: actions.resultGroup())
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.count, 3)
        XCTAssertEqual(store.entries[0].files[2].id, stack.files[1].id)
    }

    /// Zusammengeschoben: Der Stapel ist danach nicht ausgewählt, wie ein hineingezogener
    func testDraggedOntoTileLeavesStackUnselected() {
        let folder = base.appendingPathComponent("einzeln")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (1...2).map { i -> ShelfFile in
            let url = folder.appendingPathComponent("e\(i).txt")
            try? Data("\(i)".utf8).write(to: url)
            return ShelfFile(url: url, owned: false)
        }
        AppSettings.shared.stackMultiple = false
        store.add([files[0]])
        store.add([files[1]])
        let target = store.entries[0], dragged = store.entries[1]
        ui.selection = [dragged.id]
        ui.draggedEntryIDs = [dragged.id]
        actions.stackDragged(onto: target)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.entries[0].isStack)
        XCTAssertTrue(ui.selection.isEmpty)
    }

    /// Stapel benennen: Name bleibt, auch wenn etwas dazukommt; leer heißt wieder „n Objekte“
    func testRenameStack() {
        let stack = makeStack(2)
        XCTAssertTrue(actions.canRename(stack))
        store.renameStack(stack.id, to: "  Urlaub ")
        XCTAssertEqual(store.entries[0].title, "Urlaub")
        let single = base.appendingPathComponent("dazu.txt")
        try? Data("x".utf8).write(to: single)
        AppSettings.shared.stackMultiple = false
        store.add([ShelfFile(url: single, owned: false)])
        let added = store.entries[0].id
        store.merge([added], into: stack.id)
        XCTAssertEqual(store.entries.first { $0.id == stack.id }?.title, "Urlaub")
        store.renameStack(stack.id, to: "")
        XCTAssertNil(store.entries.first { $0.id == stack.id }?.name)
    }

    /// Ordner umbenennen: auf der Platte, die Kachel zeigt den neuen Ort; vergebene Namen nicht
    func testRenameFolder() throws {
        actions.makeFolder(with: [])
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(actions.canRename(entry))
        let old = entry.files[0].url
        try store.renameFile(entry.files[0].id, to: "Projekt", keepOriginal: false)
        let renamed = try XCTUnwrap(store.entries.first?.files.first)
        XCTAssertEqual(renamed.url.lastPathComponent, "Projekt")
        XCTAssertEqual(renamed.id, entry.files[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try FileManager.default.createDirectory(at: renamed.url.deletingLastPathComponent().appendingPathComponent("Belegt"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.renameFile(entry.files[0].id, to: "Belegt", keepOriginal: false))
        XCTAssertThrowsError(try store.renameFile(entry.files[0].id, to: "a/b", keepOriginal: false))
    }

    /// Datei umbenennen: ohne Kopie-Einstellung die Datei selbst, mit ihr nur eine Kopie
    func testRenameFileOrCopy() throws {
        let folder = base.appendingPathComponent("finder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Foto.jpg")
        try Data("bild".utf8).write(to: original)
        AppSettings.shared.stackMultiple = false
        store.add([ShelfFile(url: original, owned: false)])
        let file = store.entries[0].files[0]
        XCTAssertTrue(actions.canRename(store.entries[0]))

        // Mit Kopien arbeiten: Das Original bleibt, die Ablage zeigt eine Kopie mit neuem Namen
        try store.renameFile(file.id, to: "Urlaub.jpg", keepOriginal: true)
        let copy = store.entries[0].files[0]
        XCTAssertEqual(copy.id, file.id)
        XCTAssertTrue(copy.owned)
        XCTAssertEqual(copy.url.lastPathComponent, "Urlaub.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Original unverändert")
        XCTAssertEqual(try Data(contentsOf: copy.url), Data("bild".utf8))

        // Die eigene Kopie wird einfach umbenannt, auch mit der Einstellung
        try store.renameFile(file.id, to: "Strand.jpg", keepOriginal: true)
        let again = store.entries[0].files[0]
        XCTAssertEqual(again.url.deletingLastPathComponent(), copy.url.deletingLastPathComponent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))

        // Ohne Einstellung: die Datei des Nutzers selbst, wie im Finder
        let other = folder.appendingPathComponent("Notiz.txt")
        try Data("x".utf8).write(to: other)
        store.add([ShelfFile(url: other, owned: false)])
        try store.renameFile(store.entries[0].files[0].id, to: "Liste.txt", keepOriginal: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Liste.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }
}
