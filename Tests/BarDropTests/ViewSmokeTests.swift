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
    private let keys = ["language", "twoActionRows", "pinFromShelf", "excludedApps", "openMode", "showTitle"]

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
        s.twoActionRows = saved["twoActionRows"] as? Bool ?? false
        s.pinFromShelf = saved["pinFromShelf"] as? Bool ?? false
        s.excludedApps = saved["excludedApps"] as? [String] ?? []
        s.openMode = (saved["openMode"] as? String).flatMap(OpenMode.init(rawValue:)) ?? .automatic
        s.showTitle = saved["showTitle"] as? Bool ?? true
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    /// Ansicht in einem Fenster auslegen und in ein Bild zeichnen
    private func render<V: View>(_ view: V, size: CGSize, _ name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("\(name): kein Bild", file: file, line: line)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0, name, file: file, line: line)
    }

    func testSettingsPagesRender() {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let size = CGSize(width: 520, height: 900)
        for language in [AppLanguage.english, .german] {
            settings.language = language
            for variant in [false, true] {
                settings.twoActionRows = variant
                settings.pinFromShelf = variant
                settings.showTitle = !variant
                settings.openMode = variant ? .click : .automatic
                settings.excludedApps = variant ? ["com.apple.finder", "example.missing.app"] : []
                let tag = "\(language.rawValue) \(variant)"
                render(GeneralSettings(settings: settings), size: size, "Allgemein \(tag)")
                render(OpeningSettings(settings: settings), size: size, "Öffnen \(tag)")
                render(AppearanceSettings(settings: settings), size: size, "Aussehen \(tag)")
                render(ItemSettings(settings: settings, store: store), size: size, "Objekte \(tag)")
                render(ActionSettings(settings: settings), size: size, "Aktionen \(tag)")
                render(KeyboardSettings(settings: settings), size: size, "Tastatur \(tag)")
                render(AboutSettings(settings: settings, showOnboarding: {}), size: size, "Über \(tag)")
            }
        }
    }

    func testIntroductionPagesRender() {
        let model = OnboardingModel(settings: AppSettings.shared, sampleURL: nil)
        model.onFinish = { _ in }
        for step in OnboardingModel.Step.allCases {
            model.go(to: step)
            render(OnboardingView(model: model, openSettings: {}),
                   size: OnboardingController.size, "Einführung \(step)")
        }
        XCTAssertEqual(model.step, .features)
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
        for variant in [false, true] {
            settings.twoActionRows = variant
            settings.showTitle = variant
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Ablage \(variant)")
        }
        // Geöffneter Stapel
        if let stack = store.entries.first(where: \.isStack) {
            ui.openStack = stack.id
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Stapel")
        }
    }
}
