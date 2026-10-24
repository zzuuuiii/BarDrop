import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import BarDrop

/// Plugins: Manifest, Erkennung, .bdrop-Pakete, Verwaltung, Ausführung und Ergebnisse.
final class PluginTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropPlugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: Hilfen

    private func manifestJSON(id: String = "io.github.test.sample", version: String = "1.0.0",
                              permissions: [String] = [], extra: String = "") -> String {
        """
        {
          "id": "\(id)",
          "name": {"en": "Sample", "de": "Beispiel"},
          "version": "\(version)",
          "icon": {"symbol": "wand.and.stars", "color": "#FF9500"},
          "match": {"extensions": ["txt"], "types": ["public.image"], "links": {"hosts": ["example.com"]}},
          "permissions": [\(permissions.map { "\"\($0)\"" }.joined(separator: ", "))]\(extra)
        }
        """
    }

    /// Plugin-Ordner mit Manifest und Skript
    private func makePluginFolder(id: String = "io.github.test.sample", version: String = "1.0.0",
                                  permissions: [String] = [], script: String, extra: String = "") -> URL {
        let dir = base.appendingPathComponent("src-\(UUID().uuidString)/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? manifestJSON(id: id, version: version, permissions: permissions, extra: extra)
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeFile(_ name: String, _ text: String = "hello") -> URL {
        let url = base.appendingPathComponent("in-\(UUID().uuidString)").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Manifest

    func testManifestDecodesLocalizedTextAndValidates() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["network"]).utf8))
        XCTAssertEqual(manifest.name.text(for: .english), "Sample")
        XCTAssertEqual(manifest.name.text(for: .german), "Beispiel")
        XCTAssertEqual(manifest.allPermissions, [.network])
        XCTAssertNoThrow(try manifest.validate(appVersion: "1.31.0"))
        XCTAssertTrue(manifest.needsSensitivePermissions)
        // Einfacher Text gilt für beide Sprachen
        let single = try JSONDecoder().decode(LocalizedText.self, from: Data("\"Only\"".utf8))
        XCTAssertEqual(single.text(for: .german), "Only")
    }

    func testManifestRejectsUnknownPermissionAndNewerApp() throws {
        let unknown = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["camera"]).utf8))
        XCTAssertThrowsError(try unknown.validate(appVersion: "1.31.0")) { error in
            XCTAssertEqual(error as? PluginManifest.ValidationError, .unknownPermission("camera"))
        }
        let newer = try JSONDecoder().decode(PluginManifest.self,
                                             from: Data(manifestJSON(extra: ", \"minAppVersion\": \"9.0.0\"").utf8))
        XCTAssertThrowsError(try newer.validate(appVersion: "1.31.0-beta.1"))
        let badID = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(id: "../evil").utf8))
        XCTAssertThrowsError(try badID.validate(appVersion: "1.31.0"))
    }

    func testAutomaticDefaultNeedsHarmlessPlugin() throws {
        let harmless = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(manifestJSON(extra: ", \"automaticByDefault\": true").utf8))
        XCTAssertTrue(harmless.automaticDefault)
        let network = try JSONDecoder().decode(PluginManifest.self,
                                               from: Data(manifestJSON(permissions: ["network"], extra: ", \"automaticByDefault\": true").utf8))
        XCTAssertFalse(network.automaticDefault)
    }

    // MARK: Erkennung

    func testMatcherUsesExtensionTypeAndLinks() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON().utf8))
        XCTAssertTrue(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("note.TXT"))))
        // PNG ist ein public.image
        XCTAssertTrue(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("photo.png"))))
        XCTAssertFalse(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("doc.pdf"))))

        let webloc = makeFile("Link.webloc")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://www.example.com/a"], format: .xml, options: 0)
        try plist.write(to: webloc)
        let link = PluginItem(url: webloc)
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.link?.host, "www.example.com")
        XCTAssertTrue(PluginMatcher.matches(manifest.match, link))

        let other = makeFile("Other.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://notexample.com"], format: .xml, options: 0).write(to: other)
        XCTAssertFalse(PluginMatcher.matches(manifest.match, PluginItem(url: other)))
        XCTAssertTrue(PluginMatcher.matchesPattern(URL(string: "https://a.org/watch?v=1")!, [#"/watch\?v="#]))
    }

    // MARK: Pakete

    func testPackAndUnpackBdrop() throws {
        let folder = makePluginFolder(script: "function run(item) {}")
        let file = base.appendingPathComponent("Sample.bdrop")
        try PluginPackage.pack(folder, to: file)
        let unpacked = try PluginPackage.unpack(file, into: base.appendingPathComponent("scratch"), appVersion: "1.31.0")
        XCTAssertEqual(unpacked.manifest.id, "io.github.test.sample")
        XCTAssertEqual(unpacked.script, "function run(item) {}")
    }

    func testUnpackRejectsArchiveWithoutManifest() throws {
        let dir = base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let file = base.appendingPathComponent("Broken.bdrop")
        try PluginPackage.pack(dir, to: file)
        XCTAssertThrowsError(try PluginPackage.unpack(file, into: base.appendingPathComponent("scratch"), appVersion: "1.31.0")) {
            XCTAssertEqual($0 as? PluginPackage.PackageError, .missingManifest)
        }
    }

    func testChecksumListParsing() {
        let list = """
        \(String(repeating: "a", count: 64))  tool_linux
        \(String(repeating: "b", count: 64)) *tool_macos
        """
        XCTAssertEqual(PluginTools.checksum(in: list, for: "tool_macos"), String(repeating: "b", count: 64))
        XCTAssertNil(PluginTools.checksum(in: list, for: "tool_windows"))
    }

    // MARK: Verwaltung

    private func installed(_ manager: PluginManager, permissions: [String] = [], script: String) throws -> InstalledPlugin {
        let file = base.appendingPathComponent("p-\(UUID().uuidString).bdrop")
        try PluginPackage.pack(makePluginFolder(permissions: permissions, script: script), to: file)
        return try manager.install(try manager.inspect(file), standard: false)
    }

    func testInstallRemoveAndPermissionsResetAfterEdit() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["network"], script: "function run(item) {}")
        XCTAssertEqual(manager.plugins.map(\.id), [plugin.id])
        manager.grant(.network, for: plugin)
        XCTAssertTrue(manager.isGranted(.network, for: plugin))

        // Skript geändert: Rechte gelten nicht mehr
        try "function run(item) { bardrop.log('x') }".write(to: plugin.scriptURL, atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(manager.refreshed(plugin.id))
        XCTAssertNotEqual(edited.fingerprint, plugin.fingerprint)
        XCTAssertFalse(manager.isGranted(.network, for: edited))

        // Neu geöffnet: Zustand bleibt erhalten
        manager.update(plugin.id) { $0.enabled = true }
        let reopened = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        XCTAssertTrue(reopened.state(plugin.id).enabled)

        manager.remove(plugin.id)
        XCTAssertTrue(manager.plugins.isEmpty)
    }

    /// Ein Erlauben gilt für alles, was das Plugin angibt; die Zwischenablage fragt nie
    func testGrantAllAuthorizesEverythingAndClipboardNeedsNoQuestion() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["network", "run", "clipboard"], script: "function run(item) {}")
        XCTAssertTrue(manager.isGranted(.clipboard, for: plugin))
        XCTAssertFalse(manager.isGranted(.network, for: plugin))
        XCTAssertFalse(manager.isFullyAuthorized(plugin))
        manager.grantAll(plugin)
        XCTAssertTrue(manager.isGranted(.network, for: plugin))
        XCTAssertTrue(manager.isGranted(.run, for: plugin))
        XCTAssertTrue(manager.isFullyAuthorized(plugin))
        // Selbst geändert: Danach fehlt die Erlaubnis wieder (Zwischenablage weiter ohne Frage)
        try "function run(item) { bardrop.log('x') }".write(to: plugin.scriptURL, atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(manager.refreshed(plugin.id))
        XCTAssertFalse(manager.isFullyAuthorized(edited))
        XCTAssertTrue(manager.isGranted(.clipboard, for: edited))
    }

    /// Nach Installieren und Erlauben: an und mit den Voreinstellungen des Plugins
    func testActivateWithDefaultsAfterInstall() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let file = base.appendingPathComponent("d.bdrop")
        let extra = #", "canReplaceOriginal": true, "defaults": {"actionBar": true, "automatic": true, "replaceOriginal": true}"#
        try PluginPackage.pack(makePluginFolder(permissions: ["network"], script: "function run(item) {}", extra: extra), to: file)
        let plugin = try manager.install(try manager.inspect(file), standard: false)
        XCTAssertEqual(plugin.manifest.defaults?.automatic, true)
        // Vorher aus, und mit Internet gilt der alte Standard nicht
        XCTAssertFalse(manager.state(plugin.id).enabled)
        XCTAssertFalse(manager.isAutomatic(plugin))

        let settings = AppSettings.shared
        let saved = settings.quickActions
        defer { settings.quickActions = saved }
        settings.quickActions = []
        manager.activateWithDefaults(plugin)
        XCTAssertTrue(manager.state(plugin.id).enabled)
        XCTAssertTrue(manager.isAutomatic(plugin))
        XCTAssertTrue(manager.state(plugin.id).replaceOriginal)
        XCTAssertTrue(settings.quickActions.contains { $0.kind == .plugin && $0.path == plugin.id })
        // Zweimal: keine doppelte Aktion
        manager.activateWithDefaults(plugin)
        XCTAssertEqual(settings.quickActions.filter { $0.path == plugin.id }.count, 1)
    }

    /// Galerie: neue Felder im Katalog und die Angabe offline/Internet
    func testCatalogGalleryFieldsAndConnectivity() throws {
        let json = #"""
        {"schema": 1, "plugins": [
          {"id": "a.b.c", "version": "1.0.0", "name": {"en": "A"}, "url": "https://x/a.bdrop", "sha256": "00",
           "size": 4812, "category": "links", "author": "Johann", "permissions": ["network"],
           "tools": ["mytool"], "updated": "2026-10-22", "future": "unbekannt"},
          {"id": "d.e.f", "version": "1.0.0", "name": {"en": "D"}, "url": "https://x/d.bdrop", "sha256": "00"}
        ]}
        """#
        let catalog = try JSONDecoder().decode(PluginCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.plugins[0].size, 4812)
        XCTAssertEqual(catalog.plugins[0].category, "links")
        XCTAssertEqual(catalog.plugins[0].tools, ["mytool"])
        XCTAssertNil(catalog.plugins[1].permissions, "ältere Einträge ohne Felder bleiben lesbar")

        XCTAssertTrue(PluginConnectivity(permissions: [.network], tools: []).usesNetwork)
        XCTAssertEqual(PluginConnectivity(permissions: [.clipboard], tools: []).symbol, "wifi.slash")
        XCTAssertEqual(PluginConnectivity(permissions: [.run], tools: ["mytool"]).symbol, "arrow.down.circle")
        XCTAssertEqual(PluginConnectivity(permissions: [], tools: []).short, PluginConnectivity(permissions: [.clipboard], tools: []).short)
        var entry = catalog.plugins[0]
        entry.toolsSize = 61 * 1_000_000
        XCTAssertTrue(PluginSize.catalogText(entry)?.contains("61") == true, "Programme getrennt mit Größe")
        XCTAssertNil(PluginSize.catalogText(catalog.plugins[1]), "ohne Größe nichts behaupten")
        XCTAssertNotNil(PluginCategory.title("media"))
        XCTAssertNil(PluginCategory.title("unbekannt"))
    }

    // MARK: Ausführung

    private final class Prompter: PluginPrompter {
        var answer = true
        var asked: [PluginPermission] = []
        func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
            asked.append(permission)
            return answer
        }
        func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool { answer }
    }

    /// Ein Lauf für mehrere Objekte (wie bei `batch`)
    private func run(_ plugin: InstalledPlugin, onAll inputs: [URL]) -> Result<[URL], PluginRunError> {
        let job = PluginJob(plugin: plugin, items: inputs.map { (PluginItem(url: $0), UUID()) }, automatic: false)
        let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work-\(UUID().uuidString)"),
                                    tools: PluginTools(directory: base.appendingPathComponent("tools")),
                                    prompter: nil, settingsValues: [:], granted: [],
                                    onGrant: { _ in }, onNotify: { _ in })
        let done = expectation(description: "Plugin")
        var result: Result<[URL], PluginRunError> = .failure(.cancelled)
        runtime.start { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        return result
    }

    /// Ergebnis eines Laufs, das als JSON in out.json geschrieben wurde
    private func outputJSON(_ result: Result<[URL], PluginRunError>, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let urls = try result.get()
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == "out.json" }, file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], file: file, line: line)
    }

    /// URL, URLSearchParams, setTimeout, TextEncoder/TextDecoder, atob/btoa (PluginPrelude)
    func testPreludeProvidesWebBasics() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: #"""
        async function run(item) {
          const u = new URL('../b/c?x=1&y=a+b#frag', 'https://User@Example.COM:443/a/z');
          u.searchParams.append('ä', 'ö & ü');
          u.searchParams.delete('x');
          const order = [];
          await new Promise(function (done) {
            setTimeout(function (v) { order.push(v); done(); }, 20, 'late');
            queueMicrotask(function () { order.push('micro'); });
            const cancelled = setTimeout(function () { order.push('never'); }, 5);
            clearTimeout(cancelled);
          });
          const bytes = new TextEncoder().encode('äö🎉');
          bardrop.writeFile('out.json', JSON.stringify({
            href: u.href, host: u.host, hostname: u.hostname, port: u.port, origin: u.origin,
            pathname: u.pathname, search: u.search, hash: u.hash, y: u.searchParams.get('y'),
            params: new URLSearchParams({ q: 'a b', r: "x!'()~" }).toString(),
            relative: new URL('/p?q', 'https://example.com/x/y').href,
            mailto: new URL('mailto:hi@example.com').href,
            invalid: URL.canParse('nicht gültig'),
            order: order,
            bytes: Array.from(bytes),
            text: new TextDecoder().decode(bytes),
            broken: new TextDecoder().decode(new Uint8Array([0x61, 0xff, 0x62])),
            b64: btoa('hi!'), back: atob('aGkh')
          }));
        }
        """#)
        let out = try outputJSON(run(plugin, on: makeFile("a.txt")))
        XCTAssertEqual(out["href"] as? String, "https://User@example.com/b/c?y=a+b&%C3%A4=%C3%B6+%26+%C3%BC#frag")
        XCTAssertEqual(out["host"] as? String, "example.com")
        XCTAssertEqual(out["port"] as? String, "")
        XCTAssertEqual(out["origin"] as? String, "https://example.com")
        XCTAssertEqual(out["pathname"] as? String, "/b/c")
        XCTAssertEqual(out["hash"] as? String, "#frag")
        XCTAssertEqual(out["y"] as? String, "a b")
        XCTAssertEqual(out["params"] as? String, "q=a+b&r=x%21%27%28%29%7E")
        XCTAssertEqual(out["relative"] as? String, "https://example.com/p?q")
        XCTAssertEqual(out["mailto"] as? String, "mailto:hi@example.com")
        XCTAssertEqual(out["invalid"] as? Bool, false)
        XCTAssertEqual(out["order"] as? [String], ["micro", "late"])
        XCTAssertEqual(out["bytes"] as? [Int], Array("äö🎉".utf8).map(Int.init))
        XCTAssertEqual(out["text"] as? String, "äö🎉")
        XCTAssertEqual(out["broken"] as? String, "a\u{FFFD}b")
        XCTAssertEqual(out["b64"] as? String, "aGkh")
        XCTAssertEqual(out["back"] as? String, "hi!")
    }

    /// Binärdaten: readData liefert Bytes, writeData schreibt sie unverändert
    func testReadAndWriteBinaryData() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: #"""
        function run(item) {
          const input = bardrop.readData(item.path);
          const all = new Uint8Array(256);
          for (let i = 0; i < 256; i++) all[i] = i;
          bardrop.writeData('all.bin', all);
          bardrop.writeData('copy.bin', input.buffer);
          bardrop.writeData('list.bin', [0, 255, 7]);
          bardrop.writeData('b64.bin', 'AP8H');
          let failed = false;
          try { bardrop.writeData('x.bin', {}); } catch (e) { failed = true; }
          bardrop.writeFile('out.json', JSON.stringify({ size: input.length, first: input[0], failed: failed }));
        }
        """#)
        let input = makeFile("in.txt", "äbc")
        let result = run(plugin, on: input)
        let urls = try result.get()
        func data(_ name: String) throws -> Data { try Data(contentsOf: XCTUnwrap(urls.first { $0.lastPathComponent == name })) }
        XCTAssertEqual(try data("all.bin"), Data((0...255).map(UInt8.init)))
        XCTAssertEqual(try data("copy.bin"), try Data(contentsOf: input))
        XCTAssertEqual(try data("list.bin"), Data([0, 255, 7]))
        XCTAssertEqual(try data("b64.bin"), Data([0, 255, 7]))
        let out = try outputJSON(result)
        XCTAssertEqual(out["size"] as? Int, 4)
        XCTAssertEqual(out["first"] as? Int, 0xC3)
        XCTAssertEqual(out["failed"] as? Bool, true)
    }

    /// `batch`: ein Lauf mit allen Objekten; alle dürfen gelesen werden
    func testBatchRunGetsAllItems() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: #"""
        function run(item, items) {
          bardrop.writeFile('out.json', JSON.stringify({
            first: item.name, names: items.map(function (i) { return i.name; }),
            texts: items.map(function (i) { return bardrop.readFile(i.path); })
          }));
        }
        """#)
        let out = try outputJSON(run(plugin, onAll: [makeFile("a.txt", "A"), makeFile("b.txt", "B")]))
        XCTAssertEqual(out["first"] as? String, "a.txt")
        XCTAssertEqual(out["names"] as? [String], ["a.txt", "b.txt"])
        XCTAssertEqual(out["texts"] as? [String], ["A", "B"])
        // Ohne batch: items enthält nur das eine Objekt
        let single = try outputJSON(run(plugin, on: makeFile("c.txt", "C")))
        XCTAssertEqual(single["names"] as? [String], ["c.txt"])
        // Manifest-Schlüssel
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(extra: #", "batch": true"#).utf8))
        XCTAssertEqual(manifest.batch, true)
    }

    private func run(_ plugin: InstalledPlugin, on input: URL, automatic: Bool = false,
                     granted: Set<PluginPermission> = [], prompter: Prompter? = nil,
                     timeout: TimeInterval = 15, while running: ((PluginJob) -> Void)? = nil) -> Result<[URL], PluginRunError> {
        let job = PluginJob(plugin: plugin, item: PluginItem(url: input), anchorFileID: UUID(), automatic: automatic)
        let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work-\(UUID().uuidString)"),
                                    tools: PluginTools(directory: base.appendingPathComponent("tools")),
                                    prompter: prompter, settingsValues: ["greeting": "Hi"], granted: granted,
                                    onGrant: { _ in }, onNotify: { _ in })
        let done = expectation(description: "Plugin")
        var result: Result<[URL], PluginRunError> = .failure(.cancelled)
        runtime.start { r in
            result = r
            done.fulfill()
        }
        running?(job)
        wait(for: [done], timeout: timeout)
        return result
    }

    func testScriptWritesResultFile() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: """
        function run(item) {
          var text = bardrop.readFile(item.path);
          bardrop.progress(0.5, "Halb");
          bardrop.writeFile(item.name.replace('.txt', '') + ' upper.txt', bardrop.settings.greeting + ' ' + text.toUpperCase());
        }
        """)
        let result = run(plugin, on: makeFile("note.txt", "hello"))
        let urls = try result.get()
        XCTAssertEqual(urls.map(\.lastPathComponent), ["note upper.txt"])
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "Hi HELLO")
    }

    func testAsyncScriptAndErrors() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let failing = try installed(manager, script: "async function run(item) { await Promise.resolve(); throw new Error('nope'); }")
        guard case .failure(.script(let message, _)) = run(failing, on: makeFile("a.txt")) else { return XCTFail("muss scheitern") }
        XCTAssertTrue(message.contains("nope"))
        XCTAssertFalse(message.contains("main.js"), "eigene Meldungen ohne Ort")

        let noRun = try installed(manager, script: "var x = 1;")
        guard case .failure(.script) = run(noRun, on: makeFile("a.txt")) else { return XCTFail("ohne run") }
    }

    func testReadingOtherFilesIsNotAllowed() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { bardrop.readFile('/etc/hosts'); }")
        guard case .failure = run(plugin, on: makeFile("a.txt")) else { return XCTFail("darf nicht lesen") }
    }

    func testPermissionAskedOnFirstUseAndNeverWhenAutomatic() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["run"], script: """
        async function run(item) {
          var r = await bardrop.run('/bin/echo', ['done']);
          bardrop.writeFile('out.txt', r.stdout.trim() + ' ' + r.code);
        }
        """)
        let prompter = Prompter()
        let urls = try run(plugin, on: makeFile("a.txt"), prompter: prompter).get()
        XCTAssertEqual(prompter.asked, [.run])
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "done 0")

        // Automatisch: keine Frage, ohne Erlaubnis scheitert es
        let silent = Prompter()
        guard case .failure = run(plugin, on: makeFile("a.txt"), automatic: true, prompter: silent) else {
            return XCTFail("ohne Erlaubnis")
        }
        XCTAssertTrue(silent.asked.isEmpty)

        // Undeklariertes Recht: scheitert ohne Frage
        let undeclared = try installed(manager, script: "async function run(item) { await bardrop.fetch('https://example.com'); }")
        let other = Prompter()
        guard case .failure = run(undeclared, on: makeFile("a.txt"), prompter: other) else { return XCTFail("undeklariert") }
        XCTAssertTrue(other.asked.isEmpty)
    }

    func testCancelStopsRunningProgram() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["run"], script: """
        async function run(item) { await bardrop.run('/bin/sleep', ['30']); bardrop.writeFile('late.txt', 'x'); }
        """)
        let started = Date()
        let result = run(plugin, on: makeFile("a.txt"), granted: [.run], timeout: 10) { job in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                job.pause()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    XCTAssertTrue(job.paused)
                    job.resume()
                    job.cancel()
                }
            }
        }
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    // MARK: Ergebnisse in der Ablage

    func testResultsLandNextToOriginal() throws {
        let store = ShelfStore(baseDirectory: base.appendingPathComponent("shelf"))
        let files = (1...3).map { ShelfFile(url: makeFile("f\($0).txt"), owned: false) }
        AppSettings.shared.stackMultiple = false
        store.add(files)          // gespeichert: f1, f2, f3
        let order = store.entries.map { $0.files[0].url.lastPathComponent }
        let middle = store.entries[1].files[0]

        let added = store.adoptResults([makeFile("result.txt")])
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added[0].owned)
        store.insertResults(added, nextTo: middle.id, replacing: false)
        XCTAssertEqual(store.entries.map { $0.files[0].url.lastPathComponent },
                       [order[0], order[1], "result.txt", order[2]])

        // Ersetzen nimmt das Original aus der Ablage
        store.insertResults(store.adoptResults([makeFile("third.txt")]), nextTo: middle.id, replacing: true)
        XCTAssertFalse(store.entries.flatMap(\.files).contains { $0.id == middle.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.url.path))
        AppSettings.shared.stackMultiple = true
    }

    // MARK: Fehlerfälle aus 1.31.0 Beta 1

    /// Gespeicherter Zustand einer älteren Fassung (ohne neue Schlüssel) bleibt lesbar
    func testOlderPluginStateStillDecodes() throws {
        let old = #"{"enabled": true, "replaceOriginal": false, "values": {}, "granted": ["run"], "consented": true, "isStandard": false}"#
        let state = try JSONDecoder().decode(PluginState.self, from: Data(old.utf8))
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.granted, [.run])
        XCTAssertTrue(state.approvedTools.isEmpty)
    }

    /// Link aus dem Browser mit Vorschaubild: Ist ein Plugin für den Link zuständig, wird
    /// der Link übernommen, nicht das Bild
    func testLinkWantedByPluginBeatsThumbnail() throws {
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        func importDrag() -> [ShelfFile] {
            let pb = NSPasteboard(name: NSPasteboard.Name("BarDropPlugin-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString("https://www.example.com/watch?v=abc", forType: .URL)
            item.setString("Beispiel", forType: NSPasteboard.PasteboardType("public.url-name"))
            item.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
            pb.writeObjects([item])
            let importer = ContentImporter(storage: base.appendingPathComponent("items"), convertImages: true)
            let done = expectation(description: "Import")
            var result: [ShelfFile] = []
            importer.importContent(of: pb) { files in
                result = files
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return result
        }
        defer { PasteboardSnapshot.linkWanted = nil }
        PasteboardSnapshot.linkWanted = { $0.host == "www.example.com" }
        let wanted = importDrag()
        XCTAssertEqual(wanted.first?.url.pathExtension, "webloc")
        XCTAssertEqual(PluginItem.readWebloc(try XCTUnwrap(wanted.first?.url))?.absoluteString, "https://www.example.com/watch?v=abc")

        PasteboardSnapshot.linkWanted = { _ in false }
        XCTAssertEqual(importDrag().first?.url.pathExtension, "png")

        // Bild aus dem Web (Google-Bildersuche): Die Seite steht nur als Text dabei. Dann das
        // Bild nehmen, auch wenn ein Plugin für die Adresse zuständig wäre
        PasteboardSnapshot.linkWanted = { _ in true }
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropPlugin-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://www.example.com/imgres?id=1", forType: .string)
        item.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
        pb.writeObjects([item])
        let importer = ContentImporter(storage: base.appendingPathComponent("items-text"), convertImages: true)
        let done = expectation(description: "Import Text")
        var result: [ShelfFile] = []
        importer.importContent(of: pb) { files in
            result = files
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result.first?.url.pathExtension, "png")
    }

    /// Plugins, die jede Adresse annehmen, verwandeln Bilder aus dem Web nicht in Links;
    /// gezielte Regeln (bestimmte Seiten) schon
    func testCatchAllLinkRulesDoNotClaimDraggedImages() throws {
        func match(_ json: String) throws -> PluginMatch {
            try JSONDecoder().decode(PluginMatch.self, from: Data(json.utf8))
        }
        let video = URL(string: "https://www.example.com/watch?v=abc")!
        let search = URL(string: "https://www.google.com/imgres?imgurl=x")!
        let anyHost = try match(#"{"links": {"hosts": ["*"]}}"#)
        let anyPattern = try match(#"{"links": {"patterns": ["^https?://"]}}"#)
        let specific = try match(#"{"links": {"hosts": ["example.com"], "patterns": ["watch\\?v="]}}"#)
        XCTAssertTrue(PluginMatcher.matchesLink(anyHost, search))
        XCTAssertFalse(PluginMatcher.specificallyMatchesLink(anyHost, search))
        XCTAssertFalse(PluginMatcher.specificallyMatchesLink(anyPattern, search))
        XCTAssertTrue(PluginMatcher.specificallyMatchesLink(specific, video))
        XCTAssertFalse(PluginMatcher.specificallyMatchesLink(specific, search))
    }

    /// Abbrechen beendet auch ein Skript in einer Endlosschleife (ScriptWatchdog)
    func testCancelStopsEndlessLoop() throws {
        try XCTSkipUnless(ScriptWatchdog.isAvailable, "Wächter von JavaScriptCore fehlt auf diesem System")
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { var n = 0; while (true) { n++; } }")
        let before = PluginRuntime.busyScripts
        let job = PluginJob(plugin: plugin, item: PluginItem(url: makeFile("a.txt")), anchorFileID: UUID(), automatic: false)
        let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work-\(UUID().uuidString)"),
                                    tools: PluginTools(directory: base.appendingPathComponent("tools")),
                                    prompter: nil, settingsValues: [:], granted: [],
                                    onGrant: { _ in }, onNotify: { _ in })
        let done = expectation(description: "Ende")
        var result: Result<[URL], PluginRunError>?
        runtime.start { r in
            result = r
            done.fulfill()
        }
        // Rechnet
        let deadline = Date().addingTimeInterval(5)
        while PluginRuntime.busyScripts <= before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(PluginRuntime.busyScripts, before + 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(PluginRuntime.busyScripts, before + 1, "Ein gewollter Lauf darf lange rechnen")
        let askedWhileRunning = ScriptWatchdog.counts.asked
        XCTAssertGreaterThan(askedWhileRunning, 0, "Wächter fragt während des Laufs nie nach")
        runtime.cancel()
        wait(for: [done], timeout: 5)
        if case .failure(.cancelled) = result {} else { XCTFail("Abbrechen erwartet, nicht \(String(describing: result))") }
        // Und hört wirklich auf
        let stop = Date().addingTimeInterval(3)
        while PluginRuntime.busyScripts > before, Date() < stop { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(PluginRuntime.busyScripts, before,
                       "Das Skript rechnet nach dem Abbrechen weiter; Wächter gefragt \(ScriptWatchdog.counts.asked)×, beenden \(ScriptWatchdog.counts.stopped)×")
    }

    /// Art der Datei, die gerade entsteht: halb geladene Endungen zählen nicht, und die
    /// größte Datei gibt den Ausschlag (kleine Nebendateien lassen das Symbol nicht springen)
    func testTypeInProgressIgnoresPartialExtensions() throws {
        let dir = base.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(PluginRunner.typeInProgress(in: dir))
        try Data(repeating: 1, count: 1000).write(to: dir.appendingPathComponent("film.mp4.part"))
        XCTAssertEqual(PluginRunner.typeInProgress(in: dir), .mpeg4Movie)
        try Data([1]).write(to: dir.appendingPathComponent("ton.m4a.part"))
        XCTAssertEqual(PluginRunner.typeInProgress(in: dir), .mpeg4Movie)
        try Data(repeating: 1, count: 5000).write(to: dir.appendingPathComponent("bild.png"))
        XCTAssertEqual(PluginRunner.typeInProgress(in: dir), .png)
    }

    /// findProgram sucht wie run, lädt nichts; Fehler mit hint: Tipp getrennt von der Meldung
    func testFindProgramAndErrorHint() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: #"""
        function run(item) {
          bardrop.writeFile('out.json', JSON.stringify({
            sh: bardrop.findProgram('sh'), none: bardrop.findProgram('gibt-es-nicht-xyz'),
            abs: bardrop.findProgram('/bin/sh'), bad: bardrop.findProgram('../sh')
          }));
        }
        """#)
        let out = try outputJSON(run(plugin, on: makeFile("a.txt")))
        XCTAssertTrue((out["sh"] as? String)?.hasSuffix("/sh") == true, "\(String(describing: out["sh"]))")
        XCTAssertTrue(out["none"] is NSNull)
        XCTAssertEqual(out["abs"] as? String, "/bin/sh")
        XCTAssertTrue(out["bad"] is NSNull)

        let failing = try installed(manager, script: #"function run(item) { throw { message: 'Geht nicht', hint: 'Erst X installieren.' }; }"#)
        guard case .failure(let error) = run(failing, on: makeFile("b.txt")) else { return XCTFail("muss scheitern") }
        XCTAssertEqual(error.message, "Geht nicht")
        XCTAssertEqual(error.hint, "Erst X installieren.")
        let plain = try installed(manager, script: #"function run(item) { throw new Error('Nur Meldung'); }"#)
        guard case .failure(let other) = run(plain, on: makeFile("c.txt")) else { return XCTFail("muss scheitern") }
        XCTAssertEqual(other.message, "Nur Meldung")
        XCTAssertNil(other.hint)
    }

    /// Dasselbe Programm (gleiche Adresse und Prüfsumme) unter anderem Namen: mitbenutzen, nichts laden
    func testToolIsSharedBetweenPluginsWithSameAddress() throws {
        let dir = base.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        let tools = PluginTools(directory: dir)
        // Ein anderes Plugin hat es als „runtime“ geladen
        let body = Data("#!/bin/sh\necho hi\n".utf8)
        let file = base.appendingPathComponent("bin-\(UUID().uuidString)")
        try body.write(to: file)
        let sum = try XCTUnwrap(PluginPackage.sha256(of: file)).lowercased()
        func tool(_ id: String) throws -> PluginTool {
            try JSONDecoder().decode(PluginTool.self, from: Data(#"{"id": "\#(id)", "name": "Tool", "url": "https://example.invalid/tool", "sha256": "\#(sum)"}"#.utf8))
        }
        let other = dir.appendingPathComponent("runtime-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try body.write(to: other.appendingPathComponent("runtime"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.appendingPathComponent("runtime").path)
        try #"{"url": "https://example.invalid/tool", "sha256": "\#(sum)", "fetched": 0}"#
            .write(to: other.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        // Unter dem Namen „mine“: keine Adresse erreichbar, also nur über das Mitbenutzen
        var asked = 0
        let url = try tools.ensure(tool("mine"), ask: { asked += 1; return true }, cancelled: { false })
        XCTAssertEqual(asked, 1, "Für dieses Plugin wird trotzdem gefragt")
        XCTAssertEqual(try Data(contentsOf: url), body)
        XCTAssertNotNil(tools.installed(try tool("mine")))
        XCTAssertTrue(tools.sharedFolders().contains { $0.hasSuffix("/runtime-abc") })
        // Aktualisieren: gilt als veraltet, wird neu geladen (hier nicht erreichbar, also Fehler)
        tools.markOutdated([try tool("mine")])
        XCTAssertNil(tools.installed(try tool("mine")))
        XCTAssertThrowsError(try tools.ensure(tool("mine"), ask: { true }, cancelled: { false }))
    }

    func testConsoleLogDoesNotFail() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { console.log('hi', {a: 1}); bardrop.writeFile('ok.txt', 'ok'); }")
        XCTAssertEqual(try run(plugin, on: makeFile("a.txt")).get().map(\.lastPathComponent), ["ok.txt"])
    }

    // MARK: Programme im Archiv, Plugin-Protokoll

    func testToolArchiveAndArchitectureRules() throws {
        let ok = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "tool", "name": "Tool", "url": "https://example.com/tool-{arch}.zip",
                     "checksums": "https://example.com/tool-{arch}.zip.sha256", "archive": "zip", "executable": "tool"}]
        """#).utf8))
        XCTAssertNoThrow(try ok.validate(appVersion: "1.31.0"))
        let tool = try XCTUnwrap(ok.tools?.first)
        XCTAssertFalse(tool.resolvedURL.contains("{arch}"))
        XCTAssertTrue(tool.resolvedURL.contains(PluginTool.architecture))
        XCTAssertTrue(["aarch64", "x86_64"].contains(PluginTool.architecture))

        let noExecutable = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "tool", "name": "Tool", "url": "https://example.com/tool.zip", "sha256": "\#(String(repeating: "a", count: 64))", "archive": "zip"}]
        """#).utf8))
        XCTAssertThrowsError(try noExecutable.validate(appVersion: "1.31.0"))
        let escape = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "x", "name": "X", "url": "https://example.com/x.zip", "sha256": "\#(String(repeating: "a", count: 64))", "archive": "zip", "executable": "../evil"}]
        """#).utf8))
        XCTAssertThrowsError(try escape.validate(appVersion: "1.31.0"))
    }

    func testPluginLogOnlyWritesWhenEnabled() throws {
        let log = PluginLog(directory: base.appendingPathComponent("logs"))
        log.record("io.github.test.a", "start", "off")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logURL.path))
        log.isEnabled = true
        log.record("io.github.test.a", "fehler", "line one\nline two")
        log.flush()
        let text = try String(contentsOf: log.logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("io.github.test.a  [fehler]  line one ⏎ line two"))
        XCTAssertFalse(text.contains("off"))
        log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logURL.path))
    }

    // MARK: Korrekturen aus der Prüfung der Schnittstelle (Oktober 2026)

    /// `const run` und `let run` liegen nicht auf dem globalen Objekt, sind aber gültig
    func testConstAndLetRunWork() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let viaConst = try installed(manager, script: "const run = (item) => { bardrop.writeFile('const.txt', 'ok'); };")
        XCTAssertEqual(try run(viaConst, on: makeFile("a.txt")).get().map(\.lastPathComponent), ["const.txt"])
        let viaLet = try installed(manager, script: "let run = async function (item) { bardrop.writeFile('let.txt', 'ok'); };")
        XCTAssertEqual(try run(viaLet, on: makeFile("a.txt")).get().map(\.lastPathComponent), ["let.txt"])
    }

    /// Abbrechen wartet nicht auf ein Skript, das seine Warteschlange blockiert
    func testCancelEndsBusyScriptAtOnce() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        // Rechnet 4 s ohne Pause (begrenzt, damit der Test keinen Kern dauerhaft belegt)
        let plugin = try installed(manager, script: "function run(item) { var end = Date.now() + 4000; while (Date.now() < end) {} }")
        let started = Date()
        let result = run(plugin, on: makeFile("a.txt"), timeout: 10) { job in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { job.cancel() }
        }
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "Abbrechen darf nicht auf das Skript warten")
    }

    /// Ein Programm, das SIGTERM übergeht, wird nach 3 s hart beendet
    func testCancelKillsProgramIgnoringTerm() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["run"], script: """
        async function run(item) { await bardrop.run('/bin/sh', ['-c', 'trap "" TERM; sleep 31.7']); }
        """)
        _ = run(plugin, on: makeFile("a.txt"), granted: [.run], timeout: 10) { job in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { job.cancel() }
        }
        // Der Prozess der Shell muss spätestens nach gut 3 s weg sein
        let deadline = Date().addingTimeInterval(6)
        var alive = true
        while Date() < deadline {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            // Shell und sleep übergehen beide SIGTERM (ignorierte Signale werden vererbt)
            task.arguments = ["-f", #"sleep 31\.7"#]
            task.standardOutput = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            alive = task.terminationStatus == 0
            if !alive { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(alive, "Programm läuft nach dem Abbrechen weiter")
    }

    func testTriggersWithoutKnownValueAreRejected() throws {
        for triggers in [#"[]"#, #"["menue"]"#] {
            let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                    from: Data(manifestJSON(extra: ", \"triggers\": \(triggers)").utf8))
            XCTAssertThrowsError(try manifest.validate(appVersion: "1.31.0")) {
                XCTAssertEqual($0 as? PluginManifest.ValidationError, .noTrigger)
            }
        }
        let mixed = try JSONDecoder().decode(PluginManifest.self,
                                             from: Data(manifestJSON(extra: #", "triggers": ["menu", "later"]"#).utf8))
        XCTAssertNoThrow(try mixed.validate(appVersion: "1.31.0"))
        XCTAssertEqual(mixed.allTriggers, [.menu])
    }

    func testHostRuleWithLeadingWildcard() {
        let link = URL(string: "https://de.wikipedia.org/wiki/Mac")!
        XCTAssertTrue(PluginMatcher.matchesHost(link, ["*.wikipedia.org"]))
        XCTAssertTrue(PluginMatcher.matchesHost(URL(string: "https://wikipedia.org")!, ["*.wikipedia.org"]))
        XCTAssertFalse(PluginMatcher.matchesHost(link, ["wiki*.org"]))
        XCTAssertFalse(PluginMatcher.matchesHost(URL(string: "https://notwikipedia.org")!, ["*.wikipedia.org"]))
    }

    /// Rechte gelten für alle Dateien des Plugins, nicht nur für Manifest und Skript
    func testFingerprintCoversAllFiles() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["network"], script: "function run(item) {}")
        manager.grant(.network, for: plugin)
        // .DS_Store vom Finder zählt nicht
        try Data([0]).write(to: plugin.directory.appendingPathComponent(".DS_Store"))
        XCTAssertTrue(manager.isGranted(.network, for: try XCTUnwrap(manager.refreshed(plugin.id))))
        try "eval('x')".write(to: plugin.directory.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(manager.refreshed(plugin.id))
        XCTAssertNotEqual(edited.fingerprint, plugin.fingerprint)
        XCTAssertFalse(manager.isGranted(.network, for: edited))
    }

    func testPluginReadsOwnFilesViaPluginDirectory() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: """
        function run(item) { bardrop.writeFile('out.txt', bardrop.readFile(bardrop.pluginDirectory + '/vorlage.txt')); }
        """)
        try "Vorlage".write(to: plugin.directory.appendingPathComponent("vorlage.txt"), atomically: true, encoding: .utf8)
        let current = try XCTUnwrap(manager.refreshed(plugin.id))
        let urls = try run(current, on: makeFile("a.txt")).get()
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "Vorlage")
    }

    func testCreateLinkOnlyForWebAddresses() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { bardrop.createLink('file:///System/Applications/Calculator.app', 'x'); }")
        guard case .failure = run(plugin, on: makeFile("a.txt")) else { return XCTFail("file:-Link darf nicht entstehen") }
    }

    /// createLink: nur der letzte Teil des Titels zählt, „.webloc“ bleibt auch bei langen Titeln (Issue #58)
    func testCreateLinkKeepsLastPartAndExtension() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: """
        function run(item) {
          bardrop.createLink('https://example.com/', 'Ordner/Titel');
          bardrop.createLink('https://example.com/', 'x'.repeat(100));
        }
        """)
        let names = try run(plugin, on: makeFile("a.txt")).get().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("Titel.webloc"), "\(names)")
        let long = try XCTUnwrap(names.first { $0.hasPrefix("xxx") })
        XCTAssertTrue(long.hasSuffix(".webloc"), long)
        XCTAssertLessThanOrEqual(long.count, 80)
        XCTAssertEqual(long, String(repeating: "x", count: 80 - ".webloc".count) + ".webloc")
    }

    /// Lange Namen werden auf 80 Zeichen gekürzt, die Endung bleibt
    func testWriteFileShortensLongNameButKeepsExtension() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { bardrop.writeFile('L'.repeat(200) + '.txt', 'ok'); }")
        let urls = try run(plugin, on: makeFile("a.txt")).get()
        let name = try XCTUnwrap(urls.first?.lastPathComponent)
        XCTAssertEqual(name, String(repeating: "L", count: 76) + ".txt")
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "ok")
    }

    func testSanitizeKeepsExtensionWhenShortening() {
        XCTAssertEqual(ContentImporter.sanitize("kurz.txt"), "kurz.txt")
        XCTAssertEqual(ContentImporter.sanitize(String(repeating: "a", count: 100) + ".pdf"), String(repeating: "a", count: 76) + ".pdf")
        // Ohne echte Endung wird einfach abgeschnitten
        let plain = "Mr. " + String(repeating: "b", count: 100)
        XCTAssertEqual(ContentImporter.sanitize(plain), String(plain.prefix(80)))
    }

    /// Eine kleine ZIP-Datei, die ausgepackt riesig wäre, wird gar nicht erst entpackt
    func testUnpackRejectsHugeArchiveWithoutLeftovers() throws {
        let folder = makePluginFolder(script: "function run(item) {}")
        try Data(count: 25 * 1024 * 1024).write(to: folder.appendingPathComponent("fill.txt"))
        let file = base.appendingPathComponent("Huge.bdrop")
        try PluginPackage.pack(folder, to: file)
        let scratch = base.appendingPathComponent("scratch-huge")
        XCTAssertThrowsError(try PluginPackage.unpack(file, into: scratch, appVersion: "1.31.0")) {
            XCTAssertEqual($0 as? PluginPackage.PackageError, .tooLarge)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertTrue(left.isEmpty, "nichts Entpacktes liegen lassen")
        XCTAssertEqual(PluginPackage.parseUnpackedSize("3 files, 1234 bytes uncompressed, 567 bytes compressed:  54.0%"), 1234)
    }

    /// Freigaben für Programme gelten für genau eine Adresse; Zustimmungen für genau einen Hinweis
    func testApprovalsBoundToAddressAndConsentText() throws {
        let a = try JSONDecoder().decode(PluginTool.self, from: Data(#"{"id": "tool", "name": "T", "url": "https://a.example/tool", "sha256": "x"}"#.utf8))
        let b = try JSONDecoder().decode(PluginTool.self, from: Data(#"{"id": "tool", "name": "T", "url": "https://b.example/tool", "sha256": "x"}"#.utf8))
        XCTAssertNotEqual(a.approvalKey, b.approvalKey)

        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        func plugin(_ consent: String) throws -> InstalledPlugin {
            let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                    from: Data(manifestJSON(extra: ", \"consent\": \"\(consent)\"").utf8))
            return InstalledPlugin(manifest: manifest, directory: base, script: "", fingerprint: "f", isStandard: false)
        }
        let first = try plugin("Alter Hinweis")
        XCTAssertFalse(manager.hasConsented(first))
        manager.recordConsent(first)
        XCTAssertTrue(manager.hasConsented(first))
        XCTAssertFalse(manager.hasConsented(try plugin("Neuer Hinweis")))
        // Zustimmung aus einer älteren Fassung (ohne gespeicherten Text) gilt weiter
        manager.update(first.id) { $0.consentedText = nil }
        XCTAssertTrue(manager.hasConsented(try plugin("Neuer Hinweis")))
    }
}
