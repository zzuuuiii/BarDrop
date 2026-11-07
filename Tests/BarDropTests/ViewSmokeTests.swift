import XCTest
import SwiftUI
import AppKit
@testable import BarDrop

/// Baut und zeichnet jede Einstellungsseite und die offene Ablage einmal, in beiden
/// Sprachen und mit den Einstellungen, die den Aufbau verändern. Findet Abstürze und
/// Laufzeitfehler in den Ansichten, ohne dass jemand die App öffnen muss.
@MainActor
final class ViewSmokeTests: XCTestCase {
    private var base: URL!
    private var saved: [String: Any] = [:]
    private let keys = ["language", "addDownloads", "excludedApps", "openMode", "pluginsEnabled"]

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropViews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
        }
    }

    override func tearDown() async throws {
        let s = AppSettings.shared
        s.language = (saved["language"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .english
        s.addDownloads = saved["addDownloads"] as? Bool ?? false
        s.excludedApps = saved["excludedApps"] as? [String] ?? []
        s.openMode = (saved["openMode"] as? String).flatMap(OpenMode.init(rawValue:)) ?? .automatic
        s.pluginsEnabled = saved["pluginsEnabled"] as? Bool ?? false
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    /// Ansicht in einem Fenster auslegen und in ein Bild zeichnen
    /// Ist BARDROP_PREVIEW_DIR gesetzt (CI), wird jedes Bild dort als PNG abgelegt,
    /// damit man die Ansichten ansehen kann, ohne die App zu starten.
    private func render<V: View>(_ view: V, size: CGSize, _ name: String, appearance: NSAppearance.Name? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: view)
        if let appearance { host.appearance = NSAppearance(named: appearance) }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("\(name): kein Bild", file: file, line: line)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0, name, file: file, line: line)
        if let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty,
           let png = rep.representation(using: .png, properties: [:]) {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(safe).png"))
        }
    }

    /// Einstellungsseite auf der Fläche des Fensters wie in der App
    private func page<V: View>(_ view: V) -> some View {
        view.background(SettingsTheme.contentBackdrop)
    }

    func testSettingsPagesRender() {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let size = CGSize(width: 520, height: 900)
        for language in [AppLanguage.english, .german] {
            settings.language = language
            for variant in [false, true] {
                settings.addDownloads = variant
                settings.openMode = variant ? .click : .automatic
                settings.excludedApps = variant ? ["com.apple.finder", "example.missing.app"] : []
                settings.pluginsEnabled = variant
                // Hell und dunkel, auf der Fläche des Fensters wie in der App
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let tag = "\(language.rawValue) \(variant) \(appearance == .aqua ? "hell" : "dunkel")"
                    render(page(GeneralSettings(settings: settings)), size: size, "Allgemein \(tag)", appearance: appearance)
                    render(page(OpeningSettings(settings: settings)), size: size, "Öffnen \(tag)", appearance: appearance)
                    render(page(AppearanceSettings(settings: settings)), size: size, "Aussehen \(tag)", appearance: appearance)
                    render(page(ItemSettings(settings: settings, store: store)), size: size, "Objekte \(tag)", appearance: appearance)
                    render(page(ActionSettings(settings: settings)), size: size, "Aktionen \(tag)", appearance: appearance)
                    render(page(PluginSettings(settings: settings)), size: size, "Plugins \(tag)", appearance: appearance)
                    render(page(AboutSettings(settings: settings, showOnboarding: {})), size: size, "Über \(tag)", appearance: appearance)
                }
            }
        }
    }

    /// Plugin-Reiter mit einem aufgeklappten Plugin und der Platzhalter eines laufenden Plugins
    func testPluginViewsRender() throws {
        let settings = AppSettings.shared
        settings.pluginsEnabled = true
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let folder = base.appendingPathComponent("plugin-src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        {"id": "io.github.test.preview", "name": {"en": "Make Thumbnail", "de": "Miniatur erstellen"},
         "description": {"en": "Smaller copy of an image", "de": "Kleinere Kopie eines Bildes"},
         "version": "1.2.0", "author": "zzuuuiii", "icon": {"symbol": "photo.on.rectangle", "color": "#FF9500"},
         "match": {"types": ["public.image"], "links": {"hosts": ["example.com"]}},
         "permissions": ["run"], "canReplaceOriginal": true, "triggers": ["menu", "action", "automatic"],
         "settings": [{"key": "size", "type": "choice", "title": {"en": "Size", "de": "Größe"}, "default": "m",
                       "options": [{"value": "s", "title": "S"}, {"value": "m", "title": "M"}, {"value": "l", "title": "L"}]},
                      {"key": "keep", "type": "toggle", "title": {"en": "Keep metadata", "de": "Metadaten behalten"}}]}
        """
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "function run(item) {}".write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let file = base.appendingPathComponent("preview.bdrop")
        try PluginPackage.pack(folder, to: file)
        let plugin = try manager.install(try manager.inspect(file), standard: false)
        manager.update(plugin.id) { $0.enabled = true }

        manager.update(plugin.id) { $0.automatic = true }
        manager.lastErrors[plugin.id] = "Programm nicht gefunden: mytool"
        // Galerie: ein Eintrag mit Internet, einer mit Programm, einer offline, einer installiert
        let catalog = try JSONDecoder().decode(PluginCatalog.self, from: Data(#"""
        {"schema": 1, "plugins": [
          {"id": "a.text", "version": "1.0.0", "name": {"en": "Text from Image", "de": "Text aus Bild"},
           "description": {"en": "Reads text from screenshots", "de": "Liest Text aus Bildschirmfotos"},
           "icon": {"symbol": "text.viewfinder", "color": "#30B0A0"}, "url": "https://x/a.bdrop", "sha256": "00",
           "size": 14200, "permissions": []},
          {"id": "b.audio", "version": "1.0.0", "name": {"en": "Video to Audio", "de": "Video zu Audio"},
           "description": {"en": "Keeps only the sound", "de": "Speichert nur die Tonspur"},
           "icon": {"symbol": "music.note", "color": "#AF52DE"}, "url": "https://x/b.bdrop", "sha256": "00",
           "size": 8100, "toolsSize": 61200000, "permissions": ["run"], "tools": ["My Tool"]},
          {"id": "c.link", "version": "1.0.0", "name": {"en": "Link Preview", "de": "Link-Vorschau"},
           "description": {"en": "Title and image for a link", "de": "Holt Titel und Bild zum Link"},
           "icon": {"symbol": "link", "color": "#0A84FF"}, "url": "https://x/c.bdrop", "sha256": "00",
           "size": 11000, "permissions": ["network"]},
          {"id": "io.github.test.preview", "version": "1.2.0", "name": {"en": "Make Thumbnail", "de": "Miniatur erstellen"},
           "description": {"en": "Smaller copy of an image", "de": "Kleinere Kopie eines Bildes"},
           "icon": {"symbol": "photo.on.rectangle", "color": "#FF9500"}, "url": "https://x/d.bdrop", "sha256": "00",
           "size": 4000, "permissions": ["run"]}
        ]}
        """#.utf8))
        manager.applyCatalogForPreview(catalog)
        XCTAssertEqual(manager.catalogEntries.count, 4)

        for language in [AppLanguage.english, .german] {
            settings.language = language
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let tag = "\(language.rawValue) \(appearance == .aqua ? "hell" : "dunkel")"
                let size = CGSize(width: 436, height: 900)
                let pages: [(PluginPage, String)] = [(.list, "Liste"), (.plugin(plugin.id), "Plugin"),
                                                     (.permissions(plugin.id), "Rechte"), (.gallery, "Galerie"),
                                                     (.order, "Reihenfolge")]
                for (subpage, name) in pages {
                    let navigation = SettingsNavigation()
                    navigation.pane = .plugins
                    navigation.pluginPage = subpage
                    // Mit der Titelzeile, wie im Fenster (Unterseiten mit Zurück-Knopf)
                    render(page(VStack(alignment: .leading, spacing: 0) {
                               if subpage != .list {
                                   PluginPageHeader(navigation: navigation, manager: manager)
                                       .padding(.leading, 18)
                                       .frame(height: 52, alignment: .leading)
                               }
                               PluginSettings(settings: settings, manager: manager, navigation: navigation)
                           }
                           .frame(maxWidth: .infinity, alignment: .leading)),
                           size: size, "Plugins \(name) \(tag)", appearance: appearance)
                }
            }
        }
        manager.lastErrors[plugin.id] = nil

        // Zurück führt dorthin, woher man kam; ein anderer Bereich beginnt wieder bei der Liste
        let navigation = SettingsNavigation()
        navigation.pane = .plugins
        navigation.openPluginPage(.gallery)
        navigation.openPluginPage(.plugin(plugin.id))
        navigation.openPluginPage(.permissions(plugin.id))
        navigation.pluginBack()
        XCTAssertEqual(navigation.pluginPage, .plugin(plugin.id))
        navigation.pluginBack()
        XCTAssertEqual(navigation.pluginPage, .gallery)
        navigation.pluginBack()
        XCTAssertEqual(navigation.pluginPage, .list)
        navigation.openPluginPage(.order)
        navigation.pane = .general
        XCTAssertEqual(navigation.pluginPage, .list)

        let store = ShelfStore(baseDirectory: base.appendingPathComponent("shelf"))
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: settings)
        let job = PluginJob(plugin: plugin, item: PluginItem(url: file), anchorFileID: UUID(), automatic: false)
        // Ein Laufzeitobjekt macht den Auftrag zu einem laufenden (ohne ihn zu starten)
        let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work"),
                                    tools: PluginTools(directory: base.appendingPathComponent("tools")), prompter: nil,
                                    settingsValues: [:], granted: [], onGrant: { _ in }, onNotify: { _ in })
        job.report(0.4, label: nil, force: true)
        let waiting = PluginJob(plugin: plugin, item: PluginItem(url: file), anchorFileID: UUID(), automatic: false)
        render(HStack { PluginJobTile(job: job, ui: ui, actions: actions); PluginJobTile(job: waiting, ui: ui, actions: actions) }
                .frame(width: 220).padding().background(Color.black),
               size: CGSize(width: 260, height: 160), "Plugin Platzhalter", appearance: .darkAqua)
        let menu = actions.menu(for: job)
        XCTAssertTrue(menu.items.first?.title.contains("40") == true)
        withExtendedLifetime(runtime) {}

        // Alle Zustände des Platzhalters nebeneinander, in beiden Sprachen
        for language in [AppLanguage.german, .english] {
            settings.language = language
            func running(_ setup: (PluginJob, PluginRuntime) -> Void) -> (PluginJob, PluginRuntime) {
                let job = PluginJob(plugin: plugin, item: PluginItem(url: file), anchorFileID: UUID(), automatic: false)
                let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work-\(UUID().uuidString)"),
                                            tools: PluginTools(directory: base.appendingPathComponent("tools")), prompter: nil,
                                            settingsValues: [:], granted: [], onGrant: { _ in }, onNotify: { _ in })
                setup(job, runtime)
                return (job, runtime)
            }
            let spinning = running { _, _ in }
            let progress = running { job, _ in job.report(0.4, label: nil, force: true) }
            let labeled = running { job, _ in job.report(0.6, label: L("Page 3 of 5", "Seite 3 von 5"), force: true) }
            let tool = running { job, _ in job.report(nil, label: L("Loading mytool", "Lädt mytool"), force: true) }
            let paused = running { job, runtime in
                job.report(0.7, label: nil, force: true)
                runtime.setPaused(true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let waitingJob = PluginJob(plugin: plugin, item: PluginItem(url: file), anchorFileID: UUID(), automatic: false)
            let states: [(PluginJob, String)] = [
                (spinning.0, L("Running, no progress", "Läuft, ohne Fortschritt")),
                (progress.0, L("Running, 40 %", "Läuft, 40 %")),
                (labeled.0, L("Own label", "Eigene Beschriftung")),
                (tool.0, L("Loading a program", "Programm wird geladen")),
                (paused.0, L("Paused", "Angehalten")),
                (waitingJob, L("Waiting", "Wartet"))
            ]
            let sheet = HStack(alignment: .top, spacing: 18) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    VStack(spacing: 6) {
                        PluginJobTile(job: state.0, ui: ui, actions: actions, iconSize: 64)
                            .frame(width: 100)
                        Text(state.1)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .frame(width: 100)
                    }
                }
            }
            .padding(20)
            .background(Color.black)
            render(sheet, size: CGSize(width: 760, height: 190),
                   "Plugin Platzhalter alle \(language.rawValue)", appearance: .darkAqua)
            withExtendedLifetime([spinning.1, progress.1, labeled.1, tool.1, paused.1]) {}
        }
    }

    func testIntroductionPagesRender() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let sample = OnboardingController.makeSample()
        defer { if let sample { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) } }
        for (language, appearance) in [(AppLanguage.german, NSAppearance.Name.darkAqua),
                                       (.english, .darkAqua), (.german, .aqua), (.english, .aqua)] {
            settings.language = language
            let model = OnboardingModel(settings: settings, sampleURL: sample)
            model.onFinish = { _ in }
            for step in OnboardingModel.Step.allCases {
                model.go(to: step)
                render(OnboardingView(model: model, openSettings: {}),
                       size: OnboardingController.size,
                       "Einführung \(language.rawValue) \(appearance == .aqua ? "hell" : "dunkel") \(step.rawValue) \(step)",
                       appearance: appearance)
            }
            XCTAssertEqual(model.step, .features)
        }
    }

    /// Das Fenster der Einführung hat eine feste Größe. Keine Seite darf mehr Platz
    /// verlangen, sonst wächst das Fenster (NSHostingView übernimmt Mindestgröße und
    /// gewünschte Größe der Ansicht).
    func testIntroductionFitsWindow() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let sample = OnboardingController.makeSample()
        defer { if let sample { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) } }
        let model = OnboardingModel(settings: settings, sampleURL: sample)
        model.onFinish = { _ in }
        for edge in ScreenEdge.allCases {
            settings.edge = edge
            for step in OnboardingModel.Step.allCases {
                model.go(to: step)
                let host = NSHostingView(rootView: OnboardingView(model: model, openSettings: {}))
                let fitting = host.fittingSize
                let intrinsic = host.intrinsicContentSize
                let size = OnboardingController.size
                XCTAssertLessThanOrEqual(fitting.height, size.height, "\(step) \(edge): fitting \(fitting), intrinsic \(intrinsic)")
                XCTAssertLessThanOrEqual(fitting.width, size.width, "\(step) \(edge): fitting \(fitting), intrinsic \(intrinsic)")
                if intrinsic.height != NSView.noIntrinsicMetric {
                    XCTAssertLessThanOrEqual(intrinsic.height, size.height, "\(step) \(edge): intrinsic \(intrinsic)")
                }
            }
        }
        settings.edge = .right
    }

    /// Das echte Fenster der Einführung (Titelleiste, Werkzeugleiste, volle Inhaltsfläche):
    /// Es behält seine Größe, und die Ansicht füllt es ganz, auch unter der Titelleiste.
    func testIntroductionWindow() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let controller = OnboardingController(store: ShelfStore(baseDirectory: base),
                                              ui: ShelfUIModel(), settings: settings)
        let window = controller.makeWindow()
        defer { window.orderOut(nil) }
        for step in OnboardingModel.Step.allCases {
            controller.model.go(to: step)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(window.contentLayoutRect.width, OnboardingController.size.width, accuracy: 1, "\(step)")
            XCTAssertEqual(window.frame.height, window.frameRect(forContentRect: NSRect(origin: .zero, size: OnboardingController.size)).height,
                           accuracy: 1, "\(step): Fenster ist gewachsen")
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("kein Bild") }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty,
               let png = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Fenster_\(step.rawValue)_\(step).png"))
            }
        }
    }

    func testOpenShelfRenders() throws {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: settings)

        // Ein paar Dateien des Nutzers, zwei davon als Stapel
        let files = try (1...5).map { i -> ShelfFile in
            let url = base.appendingPathComponent("Datei \(i).txt")
            try Data("\(i)".utf8).write(to: url)
            return ShelfFile(url: url, owned: false)
        }
        store.add(Array(files.prefix(3)))
        store.add(Array(files.suffix(2)))

        ui.level = .expanded
        render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
               size: CGSize(width: 420, height: 720), "Ablage")
        // Hinweis mit „Rückgängig“ und Griff
        ui.notice = ShelfUIModel.Notice(text: L("Removed", "Entfernt"), canUndo: true)
        ui.grabberHover = true
        render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
               size: CGSize(width: 420, height: 720), "Ablage Hinweis")
        ui.notice = ShelfUIModel.Notice(text: L("Stack added", "Stapel abgelegt"))
        render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
               size: CGSize(width: 420, height: 720), "Ablage Stapel-Hinweis")
        ui.notice = nil
        ui.grabberHover = false
        // Geöffneter Stapel
        if let stack = store.entries.first(where: \.isStack) {
            ui.openStack = stack.id
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Stapel")
        }
    }

    /// Bilder für die Produktseite auf GitHub: die echte Ablage mit echten Dateien und
    /// Vorschaubildern, die echten Einstellungen und die Einführung, in doppelter Auflösung
    /// mit durchsichtigem Hintergrund. Nur mit BARDROP_PREVIEW_DIR.
    func testProductShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("Nur in CI")
        }
        let settings = AppSettings.shared
        let saved = (settings.tileIconSize, settings.shelfHeight, settings.shelfWidth, settings.language,
                     settings.showOutline, settings.edge)
        defer {
            settings.tileIconSize = saved.0; settings.shelfHeight = saved.1; settings.shelfWidth = saved.2
            settings.language = saved.3; settings.showOutline = saved.4; settings.edge = saved.5
        }
        settings.tileIconSize = 64
        settings.showOutline = true
        settings.edge = .right

        for language in [AppLanguage.english, .german] {
            settings.language = language
            let lang = language.rawValue
            let files = base.appendingPathComponent("Produkt-\(lang)")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let examples = Self.productFiles(in: files)

            let store = ShelfStore(baseDirectory: base.appendingPathComponent("Store-\(lang)"))
            let ui = ShelfUIModel()
            let actions = ShelfActions(store: store, ui: ui, settings: settings)
            settings.stackMultiple = false
            store.add(examples.singles.reversed().map { ShelfFile(url: $0, owned: false) })
            // Vorschaubilder vorab laden: Die Kacheln zeigen sie dann sofort
            for url in examples.singles + examples.stack {
                _ = await Thumbnails.load(url, size: 64)
                Thumbnails.shownOnce.insert(url.path)
            }
            ui.level = .expanded
            ui.isKey = true

            // 1. Ablage mit sechs Objekten, eines ausgewählt
            settings.shelfWidth = 300
            settings.shelfHeight = 400
            ui.expandedBody = CGRect(x: 0, y: 0, width: 300, height: 400)
            ui.selection = Set(store.entries.dropFirst(1).prefix(1).map(\.id))
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Ablage \(lang)", dir: dir)

            // Aktion im Einsatz: eine Datei liegt über der Ordner-Aktion
            ui.selection = []
            ui.previewTargetedAction = settings.quickActions.first { $0.kind == .folder }?.id
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Aktion \(lang)", dir: dir)
            ui.previewTargetedAction = nil
            ui.selection = Set(store.entries.dropFirst(1).prefix(1).map(\.id))

            // Vorschau-GIF (docs/preview.gif): zwei Bilder aus dem Browser ablegen, auf eine Folie ziehen,
            // ein Archiv in den Papierkorb und alles zurück. Platzhalter wie bei der Symbolgröße.
            if language == .english {
                let g3 = base.appendingPathComponent("GIF3", isDirectory: true)
                try FileManager.default.createDirectory(at: g3, withIntermediateDirectories: true)
                func empty(_ name: String) -> URL {
                    let url = g3.appendingPathComponent(name)
                    FileManager.default.createFile(atPath: url.path, contents: Data())
                    return url
                }
                let photo = empty("Photo.jpg"), document = empty("Document.pdf")
                let notes = empty("Notes.txt"), video = empty("Video.mov"), archive = empty("Archive.zip")
                let project = g3.appendingPathComponent("Project", isDirectory: true)
                try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                // Bilder aus der Bildersuche: auch als PNG für den Browser im GIF
                func landscape(_ name: String, _ top: NSColor, _ bottom: NSColor, sun: NSColor, far: NSColor, near: NSColor) -> URL {
                    let image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
                        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
                        sun.setFill(); NSBezierPath(ovalIn: NSRect(x: 520, y: 360, width: 110, height: 110)).fill()
                        far.setFill()
                        let m = NSBezierPath(); m.move(to: NSPoint(x: 0, y: 200)); m.line(to: NSPoint(x: 220, y: 420))
                        m.line(to: NSPoint(x: 380, y: 300)); m.line(to: NSPoint(x: 560, y: 460)); m.line(to: NSPoint(x: 800, y: 240))
                        m.line(to: NSPoint(x: 800, y: 0)); m.line(to: .zero); m.close(); m.fill()
                        near.setFill()
                        let w = NSBezierPath(); w.move(to: .zero); w.curve(to: NSPoint(x: 800, y: 120), controlPoint1: NSPoint(x: 260, y: 220),
                                                                         controlPoint2: NSPoint(x: 520, y: 40))
                        w.line(to: NSPoint(x: 800, y: 0)); w.close(); w.fill()
                        return true
                    }
                    let url = g3.appendingPathComponent(name)
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: url)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir)
                            .appendingPathComponent("GIF3_" + url.deletingPathExtension().lastPathComponent + ".png"))
                    }
                    return url
                }
                let lake = landscape("mountain-lake.jpg", NSColor(red: 0.42, green: 0.66, blue: 0.95, alpha: 1),
                                     NSColor(red: 0.86, green: 0.93, blue: 1, alpha: 1), sun: NSColor(red: 1, green: 0.96, blue: 0.75, alpha: 1),
                                     far: NSColor(red: 0.45, green: 0.52, blue: 0.66, alpha: 1), near: NSColor(red: 0.16, green: 0.42, blue: 0.62, alpha: 1))
                let dusk = landscape("alpine-dusk.jpg", NSColor(red: 0.98, green: 0.6, blue: 0.42, alpha: 1),
                                     NSColor(red: 1, green: 0.86, blue: 0.62, alpha: 1), sun: NSColor(red: 1, green: 0.97, blue: 0.85, alpha: 1),
                                     far: NSColor(red: 0.55, green: 0.36, blue: 0.48, alpha: 1), near: NSColor(red: 0.28, green: 0.2, blue: 0.36, alpha: 1))
                // Weitere Suchergebnisse, nur für den Browser
                for (i, c) in [(0.3, 0.55, 0.45), (0.55, 0.45, 0.8), (0.2, 0.35, 0.55), (0.75, 0.5, 0.35), (0.35, 0.6, 0.7), (0.6, 0.3, 0.4)].enumerated() {
                    _ = landscape("result-\(i).jpg", NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1),
                                  NSColor(red: min(1, c.0 + 0.4), green: min(1, c.1 + 0.4), blue: min(1, c.2 + 0.35), alpha: 1),
                                  sun: NSColor(white: 1, alpha: 0.85), far: NSColor(red: c.0 * 0.6, green: c.1 * 0.6, blue: c.2 * 0.7, alpha: 1),
                                  near: NSColor(red: c.0 * 0.35, green: c.1 * 0.4, blue: c.2 * 0.45, alpha: 1))
                }
                let all = [photo, document, notes, video, archive, project, lake, dusk]
                for url in all {
                    _ = await Thumbnails.load(url, size: 64)
                    Thumbnails.shownOnce.insert(url.path)
                }
                let s3 = ShelfStore(baseDirectory: base.appendingPathComponent("GIF3Store"))
                let a3 = ShelfActions(store: s3, ui: ui, settings: settings)
                ui.selection = []; ui.openStack = nil; ui.memberSelection = []
                TrashState.shared.isFull = false
                // Ältestes zuerst: Archiv, Video, Notiz, dann die Gruppe (oben). Mit den zwei Bildern
                // sind es sechs Kacheln, die ohne Rollen in die Ablage passen
                settings.stackMultiple = false
                s3.add([archive, video, notes].map { ShelfFile(url: $0, owned: false) })
                settings.stackMultiple = true
                settings.stackThreshold = 2
                s3.add([photo, document].map { ShelfFile(url: $0, owned: false) })
                settings.stackMultiple = false
                func g(_ name: String, _ store: ShelfStore? = nil) {
                    let st = store ?? s3
                    shot(ShelfRootView(ui: ui, store: st, settings: settings,
                                       actions: store == nil ? a3 : ShelfActions(store: st, ui: ui, settings: settings)),
                         size: CGSize(width: 440, height: 600), "GIF3 \(name)", dir: dir)
                }
                func pick(_ name: String, in st: ShelfStore) -> Set<UUID> {
                    Set(st.entries.filter { $0.urls.first?.lastPathComponent == name && !$0.isStack }.map(\.id))
                }
                g("0")
                ui.isDropTargeted = true; g("0 drop"); ui.isDropTargeted = false
                s3.add([ShelfFile(url: lake, owned: false)])
                g("1")
                ui.isDropTargeted = true; g("1 drop"); ui.isDropTargeted = false
                s3.add([ShelfFile(url: dusk, owned: false)])
                g("2")
                // Ziehen auf die Folie: erst der See, dann die Dämmerung
                ui.selection = pick("mountain-lake.jpg", in: s3); g("2 lake")
                ui.selection = []
                s3.forgetFiles(at: [lake])
                g("3")
                ui.selection = pick("alpine-dusk.jpg", in: s3); g("3 dusk")
                ui.selection = []
                s3.forgetFiles(at: [dusk])
                g("4")
                ui.selection = pick("Archive.zip", in: s3); g("4 archive")
                ui.previewTargetedAction = settings.quickActions.first { $0.kind == .trash }?.id
                g("4 trash")
                ui.previewTargetedAction = nil
                ui.selection = []
                let without = ShelfStore(baseDirectory: base.appendingPathComponent("GIF3b"))
                for entry in s3.entries.reversed() where entry.urls.first?.lastPathComponent != "Archive.zip" {
                    settings.stackMultiple = entry.isStack
                    without.add(entry.files)
                }
                settings.stackMultiple = false
                TrashState.shared.isFull = true
                g("5", without)
                TrashState.shared.isFull = false
            }

            // 2. Mit Stapel
            settings.stackMultiple = true
            settings.stackThreshold = 2
            store.add(examples.stack.map { ShelfFile(url: $0, owned: false) })
            ui.selection = Set(store.entries.prefix(1).map(\.id))
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Stapel \(lang)", dir: dir)
            if let stack = store.entries.first(where: \.isStack) {
                ui.selection = []
                ui.openStack = stack.id
                ui.memberSelection = Set(stack.files.prefix(1).map(\.id))
                shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                     size: CGSize(width: 440, height: 600), "Produkt Stapel offen \(lang)", dir: dir)
                ui.openStack = nil
                ui.memberSelection = []
            }

            // 3. Einstellungen (Standardgröße der Ablage)
            settings.shelfWidth = ShelfDefaults.width
            settings.shelfHeight = ShelfDefaults.height
            let panes: [(AnyView, String)] = [
                (AnyView(GeneralSettings(settings: settings)), "Allgemein"),
                (AnyView(OpeningSettings(settings: settings)), "Oeffnen"),
                (AnyView(AppearanceSettings(settings: settings)), "Aussehen"),
                (AnyView(ItemSettings(settings: settings, store: store)), "Objekte"),
                (AnyView(ActionSettings(settings: settings)), "Aktionen")
            ]
            for (pane, name) in panes {
                for (appearance, look) in [(NSAppearance.Name.darkAqua, "dunkel"), (.aqua, "hell")] {
                    shot(pane.background(SettingsTheme.contentBackdrop), size: CGSize(width: 436, height: 640),
                         "Produkt \(name) \(lang) \(look)", dir: dir, appearance: appearance)
                }
            }

            // Ganzes Einstellungsfenster im Dunkelmodus (Seitenleiste und Inhalt)
            for (pane, name) in [(SettingsPane.general, "Allgemein"), (.actions, "Aktionen"), (.items, "Objekte")] {
                shot(SettingsRoot(settings: settings, store: store, showOnboarding: {}, pane: pane)
                        .background(Color(nsColor: NSColor(white: 0.17, alpha: 1))),
                     size: CGSize(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height),
                     "Produkt Fenster \(name) \(lang)", dir: dir, appearance: .darkAqua)
                shot(SettingsRoot(settings: settings, store: store, showOnboarding: {}, pane: pane)
                        .background(Color(nsColor: NSColor(white: 0.93, alpha: 1))),
                     size: CGSize(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height),
                     "Produkt Fenster \(name) \(lang) hell", dir: dir, appearance: .aqua)
            }

            // 4. Einführung
            let controller = OnboardingController(store: ShelfStore(baseDirectory: base.appendingPathComponent("Intro-\(lang)")),
                                                  ui: ShelfUIModel(), settings: settings)
            controller.model.onFinish = { _ in }
            for step in [OnboardingModel.Step.allCases.first, OnboardingModel.Step.allCases.dropFirst().first].compactMap({ $0 }) {
                controller.model.go(to: step)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                shot(OnboardingView(model: controller.model, openSettings: {}).background(SettingsTheme.contentBackdrop),
                     size: OnboardingController.size, "Produkt Einfuehrung \(step.rawValue) \(lang)", dir: dir,
                     appearance: .darkAqua)
            }
        }
    }

    /// Beispieldateien für die Produktbilder: die der Einführung und ein paar weitere
    private static func productFiles(in dir: URL) -> (singles: [URL], stack: [URL]) {
        var singles = DemoShelf.makeExamples(in: dir)
        func photo(_ name: String, _ top: NSColor, _ bottom: NSColor, sun: NSColor, hill: NSColor) -> URL {
            let url = dir.appendingPathComponent(name)
            let image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
                NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
                sun.setFill()
                NSBezierPath(ovalIn: NSRect(x: 520, y: 330, width: 130, height: 130)).fill()
                hill.setFill()
                let path = NSBezierPath()
                path.move(to: .zero)
                path.curve(to: NSPoint(x: 800, y: 160), controlPoint1: NSPoint(x: 260, y: 330),
                           controlPoint2: NSPoint(x: 520, y: 40))
                path.line(to: NSPoint(x: 800, y: 0))
                path.close()
                path.fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                try? jpg.write(to: url)
            }
            return url
        }
        singles.append(photo(L("Lake.jpg", "See.jpg"), NSColor(red: 0.45, green: 0.72, blue: 1, alpha: 1),
                             NSColor(red: 0.85, green: 0.93, blue: 1, alpha: 1),
                             sun: NSColor(red: 1, green: 0.95, blue: 0.7, alpha: 1),
                             hill: NSColor(red: 0.2, green: 0.5, blue: 0.35, alpha: 1)))
        let notes = dir.appendingPathComponent(L("Notes.txt", "Notizen.txt"))
        try? Data(L("Shopping list\n- Coffee\n- Bread\n", "Einkaufsliste\n- Kaffee\n- Brot\n").utf8).write(to: notes)
        singles.append(notes)
        let folder = dir.appendingPathComponent(L("Project", "Projekt"), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        singles.append(folder)
        let stack = [
            photo(L("Sunset 1.jpg", "Sonnenuntergang 1.jpg"), NSColor(red: 1, green: 0.55, blue: 0.4, alpha: 1),
                  NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 1), sun: .white,
                  hill: NSColor(red: 0.55, green: 0.25, blue: 0.3, alpha: 1)),
            photo(L("Sunset 2.jpg", "Sonnenuntergang 2.jpg"), NSColor(red: 0.6, green: 0.35, blue: 0.85, alpha: 1),
                  NSColor(red: 1, green: 0.7, blue: 0.6, alpha: 1), sun: NSColor(red: 1, green: 0.9, blue: 0.6, alpha: 1),
                  hill: NSColor(red: 0.3, green: 0.2, blue: 0.4, alpha: 1)),
            photo(L("Sunset 3.jpg", "Sonnenuntergang 3.jpg"), NSColor(red: 0.95, green: 0.4, blue: 0.5, alpha: 1),
                  NSColor(red: 1, green: 0.8, blue: 0.5, alpha: 1), sun: NSColor(red: 1, green: 1, blue: 0.85, alpha: 1),
                  hill: NSColor(red: 0.35, green: 0.15, blue: 0.25, alpha: 1))
        ]
        return (singles, stack)
    }

    /// Wie `render`, aber in doppelter Auflösung
    private func shot<V: View>(_ view: V, size: CGSize, _ name: String, dir: String,
                               appearance: NSAppearance.Name? = nil) {
        // Doppelte Auflösung ohne Bildschirm mit Retina: die Ansicht in normaler Größe
        // auslegen und beim Zeichnen auf das Doppelte vergrößern. Text und Symbole sind
        // Vektoren bzw. haben Bilder in doppelter Auflösung und bleiben dabei scharf.
        let scaled = view
            .frame(width: size.width, height: size.height)
            .scaleEffect(2, anchor: .topLeading)
            .frame(width: size.width * 2, height: size.height * 2, alignment: .topLeading)
        let host = NSHostingView(rootView: scaled)
        if let appearance { host.appearance = NSAppearance(named: appearance) }
        host.frame = CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail(name) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail(name) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".png"))
    }

    /// Beim Verstellen der Symbolgröße: Beispieldateien in der neuen Größe, auch in einer
    /// leeren Ablage
    func testSizeGuidesRender() {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: settings)
        ui.level = .expanded
        ui.showSampleTile = true
        ui.expandedBody = CGRect(x: 0, y: 0, width: settings.shelfWidth, height: settings.shelfHeight)
        let before = settings.tileIconSize
        defer { settings.tileIconSize = before }
        for size in [40.0, 64.0, 96.0] {
            settings.tileIconSize = size
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Symbolgroesse \(Int(size))")
        }
    }

    /// ↑ und ↓ in den Einstellungen: Bereiche in der Reihenfolge der Seitenleiste, an den Enden bleibt es stehen
    func testSettingsArrowKeysMoveThroughPanes() {
        let navigation = SettingsNavigation()
        navigation.pane = .general
        navigation.move(by: -1)
        XCTAssertEqual(navigation.pane, .general)
        navigation.move(by: 1)
        XCTAssertEqual(navigation.pane, .opening)
        for _ in 0..<20 { navigation.move(by: 1) }
        XCTAssertEqual(navigation.pane, .about)
        navigation.move(by: -1)
        XCTAssertEqual(navigation.pane, .cloud)
    }
}
