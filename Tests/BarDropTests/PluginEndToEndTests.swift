import XCTest
import AppKit
import Combine
@testable import BarDrop

/// Ganzer Weg eigener Test-Plugins (Tests/Fixtures/Plugins): als .bdrop packen, prüfen,
/// installieren, einschalten, über Ablegen, Rechtsklick und Aktionsleiste starten und das
/// Ergebnis neben dem Original wiederfinden.
final class PluginEndToEndTests: XCTestCase {
    private var base: URL!
    private var manager: PluginManager!
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var actions: ShelfActions!
    private var runner: PluginRunner!
    private var savedEnabled = false
    private var savedStack = true

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Plugins", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropPluginE2E-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        savedEnabled = settings.pluginsEnabled
        savedStack = settings.stackMultiple
        settings.pluginsEnabled = true
        settings.stackMultiple = false
        manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0-beta.3")
        store = ShelfStore(baseDirectory: base.appendingPathComponent("shelf"))
        ui = ShelfUIModel()
        actions = ShelfActions(store: store, ui: ui, settings: settings)
        runner = PluginRunner(manager: manager, actions: actions)
        runner.showsErrorDialogs = false
        actions.plugins = runner
    }

    override func tearDown() {
        runner.cancelAll()
        let settings = AppSettings.shared
        settings.pluginsEnabled = savedEnabled
        settings.stackMultiple = savedStack
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: Hilfen

    /// Packt ein Test-Plugin als .bdrop, prüft und installiert es wie der Import
    @discardableResult
    private func install(_ name: String, enable: Bool = true) throws -> InstalledPlugin {
        let file = base.appendingPathComponent("\(name).bdrop")
        try PluginPackage.pack(Self.fixtures.appendingPathComponent(name), to: file)
        let plugin = try manager.install(try manager.inspect(file), standard: false)
        if enable { manager.update(plugin.id) { $0.enabled = true } }
        return plugin
    }

    private func makeFile(_ name: String, _ text: String) -> URL {
        let url = base.appendingPathComponent("files-\(UUID().uuidString)/\(name)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeLink(_ address: String, title: String) -> URL {
        let url = base.appendingPathComponent("links-\(UUID().uuidString)/\(title).webloc")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": address], format: .binary, options: 0)
        try? data?.write(to: url)
        return url
    }

    /// Wie Hineinziehen aus dem Finder
    private func drop(_ urls: [URL]) {
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropE2E-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        let done = expectation(description: "Ablegen")
        store.ingest(from: pb, byUser: true) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// Wartet, bis die Bedingung gilt (die Ergebnisse kommen asynchron)
    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), "Zeitüberschreitung", file: file, line: line)
    }

    private var names: [String] { actions.orderedEntries.map { $0.title } }

    // MARK: Abläufe

    /// Automatisch beim Ablegen: Ergebnis steht direkt neben dem Original und ist ausgewählt
    func testAutomaticPluginPutsResultNextToOriginal() throws {
        let plugin = try install("upper-text")
        XCTAssertTrue(manager.isAutomatic(plugin), "automaticByDefault ohne heikle Rechte")
        drop([makeFile("older.pdf", "x")])
        drop([makeFile("note.txt", "hello world")])

        waitUntil { self.names.contains("note UPPER.txt") }
        XCTAssertEqual(names, ["note UPPER.txt", "note.txt", "older.pdf"])
        let result = try XCTUnwrap(store.entries.flatMap(\.files).first { $0.url.lastPathComponent == "note UPPER.txt" })
        XCTAssertTrue(result.owned)
        XCTAssertEqual(try String(contentsOf: result.url, encoding: .utf8), "HELLO WORLD")
        XCTAssertEqual(ui.selection, Set(store.entries.filter { $0.files.contains(result) }.map(\.id)))
        XCTAssertTrue(runner.jobs.isEmpty)
    }

    /// Ergebnisse lösen kein weiteres automatisches Plugin aus (keine Schleife)
    func testResultsDontTriggerAutomaticPluginsAgain() throws {
        try install("upper-text")
        drop([makeFile("loop.txt", "x")])
        waitUntil { self.names.contains("loop UPPER.txt") }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(names.filter { $0.contains("UPPER") }, ["loop UPPER.txt"])
    }

    /// Ausgeschaltete Plugins und „Plugins verwenden“ aus: nichts passiert
    func testNothingRunsWhenTurnedOff() throws {
        let plugin = try install("upper-text")
        manager.update(plugin.id) { $0.enabled = false }
        drop([makeFile("off.txt", "x")])
        AppSettings.shared.pluginsEnabled = false
        manager.update(plugin.id) { $0.enabled = true }
        drop([makeFile("off2.txt", "x")])
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(runner.jobs.isEmpty)
        XCTAssertFalse(names.contains { $0.contains("UPPER") })
    }

    /// Rechtsklick: Plugins stehen unter den normalen Einträgen nach einer Trennlinie;
    /// ab vier passenden in einem Untermenü „Plugins“
    func testRightClickMenuPlacement() throws {
        try install("upper-text")
        try install("broken-line")
        drop([makeFile("menu.txt", "x")])
        waitUntil { self.names.contains("menu UPPER.txt") }
        let entry = try XCTUnwrap(store.entries.first { $0.title == "menu.txt" })
        ui.selection = []
        let titles = actions.menu(for: entry, anchor: NSView()).items.map { $0.isSeparatorItem ? "—" : $0.title }
        let trash = try XCTUnwrap(titles.firstIndex(of: L("Move to Trash", "In den Papierkorb legen")))
        XCTAssertEqual(titles[trash + 1], "—")
        // Von hinten gezählt: Ist auf dem Mac ein Cloud-Dienst eingerichtet (etwa iCloud Drive),
        // steht dessen „Teilen“ zwischen Papierkorb und Plugins
        XCTAssertEqual(Array(titles.suffix(2)), ["Upper Case", "Broken Line"].map { title in
            title == "Upper Case" ? L("Upper Case", "Großbuchstaben") : title
        })
        XCTAssertEqual(titles[titles.count - 3], "—")

        // Vier passende Plugins: gesammelt im Untermenü
        for n in 1...2 {
            let folder = base.appendingPathComponent("extra\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"id": "io.github.zzuuuiii.test.extra\#(n)", "name": "Extra \#(n)", "version": "1", "minAppVersion": "1.31.0", "match": {"extensions": ["txt"]}, "triggers": ["menu"]}"#
                .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try "function run(item) {}".write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            let file = base.appendingPathComponent("extra\(n).bdrop")
            try PluginPackage.pack(folder, to: file)
            let plugin = try manager.install(try manager.inspect(file), standard: false)
            manager.update(plugin.id) { $0.enabled = true }
        }
        let menu = actions.menu(for: entry, anchor: NSView())
        let last = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(last.title, "Plugins")
        XCTAssertEqual(last.submenu?.items.count, 4)
        XCTAssertTrue(menu.items[menu.items.count - 2].isSeparatorItem)
    }

    /// Fehler im Skript: mit Datei und Zeile, kein Ergebnis, Platzhalter weg, letzter Fehler gemerkt
    func testScriptErrorReportsLine() throws {
        let plugin = try install("broken-line")
        drop([makeFile("err.txt", "x")])
        let file = try XCTUnwrap(store.entries.flatMap(\.files).first { $0.url.lastPathComponent == "err.txt" })
        runner.run(plugin.id, on: [file])
        waitUntil { self.manager.lastErrors[plugin.id] != nil }
        let message = try XCTUnwrap(manager.lastErrors[plugin.id])
        XCTAssertTrue(message.contains("main.js:4"), message)
        XCTAssertTrue(message.contains("TypeError"), message)
        XCTAssertTrue(runner.jobs.isEmpty)
        XCTAssertEqual(store.entries.count, 1)
    }

    /// Aktionsleiste und Links: Notiz und bereinigter Link neben dem Link, „Original ersetzen“
    func testActionWithLinkAndReplaceOriginal() throws {
        let plugin = try install("link-note")
        manager.update(plugin.id) { $0.replaceOriginal = true }
        drop([makeLink("https://www.example.com/page?utm_source=x", title: "Page")])
        let link = try XCTUnwrap(store.entries.first?.files.first)
        XCTAssertEqual(PluginItem(url: link.url).kind, .link)
        XCTAssertTrue(runner.jobs.isEmpty, "kein automatisches Plugin")

        // Über die Aktionsleiste, wie ein Klick auf die Aktion mit ausgewähltem Link
        actions.perform(QuickAction(kind: .plugin, path: plugin.id), urls: [link.url], anchor: NSView())
        // Solange es läuft: Platzhalter an der Stelle des Links, nicht daneben
        // (Zu sehen ist der Platzhalter erst nach PluginRunner.showDelay; dieser Lauf kann vorher fertig sein)
        XCTAssertEqual(runner.jobs.first?.replacesOriginal, true)
        XCTAssertTrue(runner.jobs(nextTo: [link.id]).isEmpty)
        waitUntil { self.names.contains("Page.txt") }
        XCTAssertEqual(names, ["Page clean", "Page.txt"])
        let clean = try XCTUnwrap(store.entries.flatMap(\.files).first { $0.url.lastPathComponent == "Page clean.webloc" })
        XCTAssertEqual(PluginItem.readWebloc(clean.url)?.absoluteString, "https://www.example.com/page")
        // Original aus der Ablage genommen, ⌘Z holt es zurück
        XCTAssertFalse(store.entries.flatMap(\.files).contains { $0.id == link.id })
        _ = store.undoLast()
        XCTAssertTrue(store.entries.flatMap(\.files).contains { $0.id == link.id })
    }

    /// Muster in links.patterns, nicht passende Links
    func testLinkPatterns() throws {
        try install("link-note")
        let docs = PluginItem(url: makeLink("https://DOCS.example.org/guide", title: "Docs"))
        let other = PluginItem(url: makeLink("https://example.net/", title: "Other"))
        let match = try XCTUnwrap(manager.plugin("io.github.zzuuuiii.test.link-note")).manifest.match
        XCTAssertTrue(PluginMatcher.matches(match, docs))
        XCTAssertFalse(PluginMatcher.matches(match, other))
        XCTAssertTrue(manager.wantsLink(URL(string: "https://sub.example.com/x")!))
        XCTAssertFalse(manager.wantsLink(URL(string: "https://example.net/")!))
    }

    /// Programme: stdout und stderr getrennt in Zeilen (auch an \r), Fortschritt, Code ungleich 0
    func testProgramOutputLinesAndProgress() throws {
        let plugin = try install("shell-steps")
        manager.grant(.run, for: plugin)
        drop([makeFile("job.steps", "x")])
        let file = try XCTUnwrap(store.entries.first?.files.first)
        var progress: [Double] = []
        runner.run(plugin.id, on: [file])
        let job = try XCTUnwrap(runner.jobs.first)
        let observer = job.$progress.sink { if let p = $0 { progress.append(p) } }
        waitUntil { self.names.contains("lines.txt") }
        observer.cancel()
        let result = try XCTUnwrap(store.entries.flatMap(\.files).first { $0.url.lastPathComponent == "lines.txt" })
        XCTAssertEqual(try String(contentsOf: result.url, encoding: .utf8), "P 100|P 25|P 50|P 75|warning\n20\nwarning")
        XCTAssertFalse(progress.isEmpty)
    }

    /// Dasselbe Plugin für dieselbe Datei läuft nicht doppelt
    func testNoDuplicateJobs() throws {
        let plugin = try install("shell-steps")
        manager.grant(.run, for: plugin)
        drop([makeFile("twice.steps", "x")])
        let file = try XCTUnwrap(store.entries.first?.files.first)
        runner.run(plugin.id, on: [file])
        runner.run(plugin.id, on: [file])
        XCTAssertEqual(runner.jobs.count, 1)
        waitUntil { self.runner.jobs.isEmpty }
    }

    /// Abbrechen beendet auch Programme, die das Programm selbst gestartet hat
    func testCancelStopsWholeProcessTree() throws {
        let folder = base.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"id": "io.github.zzuuuiii.test.tree", "name": "Tree", "version": "1", "minAppVersion": "1.31.0",
         "match": {"extensions": ["tree"]}, "permissions": ["run"]}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        async function run(item) {
          await bardrop.run("/bin/sh", ["-c", "/bin/sleep 60 & echo $! > child.pid; wait"]);
        }
        """.write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let file = base.appendingPathComponent("tree.bdrop")
        try PluginPackage.pack(folder, to: file)
        let plugin = try manager.install(try manager.inspect(file), standard: false)
        manager.update(plugin.id) { $0.enabled = true }
        manager.grant(.run, for: plugin)
        drop([makeFile("x.tree", "x")])
        let item = try XCTUnwrap(store.entries.first?.files.first)
        runner.run(plugin.id, on: [item])
        let pidFile = manager.scratchDirectory.appendingPathComponent(try XCTUnwrap(runner.jobs.first).id.uuidString)
            .appendingPathComponent("Output/child.pid")
        waitUntil { FileManager.default.fileExists(atPath: pidFile.path) && ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").count > 1 }
        let pid = pid_t(try XCTUnwrap(Int32((String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))))
        XCTAssertEqual(kill(pid, 0), 0, "Enkelprozess läuft")
        runner.jobs.first?.pause()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(runner.jobs.first?.paused == true)
        runner.jobs.first?.cancel()
        waitUntil { self.runner.jobs.isEmpty }
        waitUntil(5) { kill(pid, 0) != 0 }
        XCTAssertEqual(store.entries.count, 1, "abgebrochen: kein Ergebnis")
    }
}
