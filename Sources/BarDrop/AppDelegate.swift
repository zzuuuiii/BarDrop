import AppKit
import SwiftUI
import Carbon
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var controller: EdgeController!
    private var diagnosticCommands: DiagnosticCommands?
    private var hotKeyObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private var onboarding: OnboardingController?
    private var screenshots: ScreenshotWatcher?
    private var airDrop: AirDropWatcher?
    /// Geöffnete .bdrop-Dateien, solange BarDrop noch startet
    private var pendingPluginFiles: [URL] = []
    /// Gibt den Einstellungen den Fokus zurück, wenn ein Menü der Menüleiste ihn kurz hatte
    private var focusReturn: SettingsFocusReturn?
    /// Diagnoseprotokoll: Fokuswechsel
    private var focusDiagnostics: FocusDiagnostics?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nach einem Update erst starten, wenn die alte Fassung beendet ist
        Updater.waitForPreviousVersion { [weak self] in self?.launch() }
    }

    private func launch() {
        endOtherInstances()
        Updater.cleanUpAfterUpdate()
        // Geschützte Ordner einmal vorab: sonst kam die Abfrage für den Schreibtisch doppelt
        FolderAccess.askOnceAtLaunch(store: ShelfStore.defaultDatabaseURL, settings: settings)
        store = ShelfStore()
        ui = ShelfUIModel()
        controller = EdgeController(store: store, ui: ui, settings: settings)
        controller.actions.openSettings = { [weak self] in self?.showSettings() }
        diagnosticCommands = DiagnosticCommands(controller: controller)
        NotificationCenter.default.addObserver(forName: DiagnosticCommands.showIntro, object: nil, queue: .main) { [weak self] _ in
            self?.showOnboarding()
        }
        controller.keepAppActive = { [weak self] in
            self?.settingsWindow?.isVisible == true || self?.onboarding?.isVisible == true
        }
        // Herausziehen fehlgeschlagen: Objekt zurück in die Ablage
        DragExporter.shared.onFailed = { [weak self] url in self?.store.restore(url) }
        // Neue Bildschirmfotos: kurz den Streifen zeigen, damit man sieht, wo sie liegen
        screenshots = ScreenshotWatcher(store: store) { [weak self] in
            guard let self, self.ui.level == .hidden else { return }
            self.controller.greet()
        }
        // Mit AirDrop empfangen: ebenso
        airDrop = AirDropWatcher(store: store) { [weak self] in
            guard let self, self.ui.level == .hidden else { return }
            self.controller.greet()
        }

        // Kein Symbol in der Menüleiste: Einstellungen und Beenden erreicht man über
        // einen Rechtsklick in die Ablage oder durch erneutes Öffnen von BarDrop.

        // Unsichtbares Hauptmenü, damit ⌘, ⌘W und ⌘Q in Einstellungen und Einführung
        // funktionieren (eine App ohne Dock-Symbol zeigt es nie an)
        languageObserver = settings.$language
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.installMainMenu() } }

        // Kurzbefehl, neu registriert, sobald er in den Einstellungen geändert wird
        hotKeyObserver = settings.$hotKeyCode.combineLatest(settings.$hotKeyModifiers)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] code, modifiers in self?.registerHotKey(code: code, modifiers: modifiers) }

        // Stille Updates nur, wenn BarDrop 15 Minuten unbenutzt war und kein Fenster offen ist
        Updater.shared.isIdle = { [weak self] in
            guard let self else { return false }
            return self.controller.isIdle(for: 15 * 60)
                && self.settingsWindow?.isVisible != true && self.onboarding == nil
        }
        focusReturn = SettingsFocusReturn { [weak self] in self?.settingsWindow }
        focusDiagnostics = FocusDiagnostics { [weak self] in self?.settingsWindow }
        Updater.shared.start()
        PluginManager.shared.start()
        // Links, für die ein Plugin zuständig ist, als Link übernehmen (nicht als Vorschaubild)
        PasteboardSnapshot.linkWanted = { url in
            AppSettings.shared.pluginsEnabled && PluginManager.shared.wantsLink(url)
        }
        // .bdrop-Dateien, die vor dem Start geöffnet wurden
        let early = pendingPluginFiles
        pendingPluginFiles = []
        if !early.isEmpty { DispatchQueue.main.async { [weak self] in self?.importPlugins(early) } }
        Diagnostics.shared.installCrashHandler()
        Diagnostics.shared.record("app", "launch \(Updater.shared.currentVersion) firstLaunch=\(!settings.didLaunchBefore) afterUpdate=\(Updater.launchedAfterUpdate)")

        // Erster Start: Einführung. Als erledigt gilt sie erst, wenn sie geschlossen
        // wurde; geht vorher etwas schief, erscheint sie beim nächsten Start wieder.
        // Sonst zeigt sich kurz der Streifen am Rand: Ohne Dock- und Menüleistensymbol
        // sähe man sonst gar nicht, dass BarDrop läuft.
        if !settings.didLaunchBefore {
            // „Beim Anmelden öffnen“ ist Standard: gleich beim ersten Start anmelden
            // (in der Einführung und in den Einstellungen lässt es sich ausschalten)
            if SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register() } catch {
                    Diagnostics.shared.failure("login", "Anmelden beim ersten Start nicht möglich", error)
                }
            }
            Diagnostics.shared.record("login", "first launch status=\(SMAppService.mainApp.status.rawValue)")
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        } else if !Updater.launchedAfterUpdate {
            // Nach einem stillen Update nicht zeigen: Davon soll man nichts merken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.controller.greet() }
        }
    }

    private func registerHotKey(code: Int, modifiers: Int) {
        hotKey = nil
        let key = HotKey(keyCode: UInt32(code), modifiers: UInt32(modifiers)) { [weak self] in
            self?.controller.toggle()
            self?.onboarding?.hotKeyPressed()
        }
        hotKey = key
        HotKeyStatus.shared.available = key.registered
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Widerrufen ist nach dem Beenden nicht mehr möglich: aufgehobene Dateien löschen
        store?.discardUndoHistory()
        controller?.actions.plugins.cancelAll()
    }

    // MARK: Plugins öffnen

    /// Doppelklick auf eine .bdrop-Datei: Import mit Prüfung und Rückfrage, nie still
    func application(_ application: NSApplication, open urls: [URL]) {
        let plugins = urls.filter { $0.pathExtension.lowercased() == PluginPackage.fileExtension }
        guard !plugins.isEmpty else { return }
        guard store != nil else {
            pendingPluginFiles += plugins
            return
        }
        importPlugins(plugins)
    }

    private func importPlugins(_ urls: [URL]) {
        for url in urls {
            guard PluginImporter.importFile(url, parent: nil) != nil else { continue }
            // Danach den Reiter zeigen, damit man das Plugin gleich einschalten kann
            showSettings(pane: .plugins)
        }
    }

    // MARK: Hauptmenü

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "BarDrop")
        appMenu.addItem(ClosureMenuItem(L("Settings", "Einstellungen"), key: ",") { [weak self] in
            self?.showSettings()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(L("Quit BarDrop", "BarDrop beenden"), key: "q") {
            NSApp.terminate(nil)
        })
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Bearbeiten mit den Befehlen des Systems: Ohne dieses Menü ging ⌘C in den Einstellungen
        // nicht, etwa beim markierten Commit unter „Über BarDrop“ (Nutzer, 24.10.2026), und auch
        // nicht ⌘V in Textfeldern von Plugins. Die Ablage behandelt ihre Kürzel vorher selbst
        // (ShelfPanel.performKeyEquivalent)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit", "Bearbeiten"))
        editMenu.addItem(withTitle: L("Cut", "Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy", "Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All", "Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window", "Fenster"))
        windowMenu.addItem(ClosureMenuItem(L("Close", "Schließen"), key: "w") {
            // Nur echte Fenster schließen, nie die Ablage selbst
            guard let window = NSApp.keyWindow, !(window is ShelfPanel) else { return }
            // Die Einführung ist randlos und hat keinen Schließknopf: `performClose` gäbe
            // dort nur einen Warnton. Schließen wie mit ihrem eigenen ×
            if window is IntroWindow {
                window.close()
            } else {
                window.performClose(nil)
            }
        })
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Einführung

    func showOnboarding() {
        if onboarding == nil {
            let onboarding = OnboardingController(store: store, ui: ui, settings: settings)
            onboarding.onClose = { [weak self] in
                self?.onboarding = nil
                self?.ui.forcesOutline = false
                ShelfMenu.disabled = false
                IntroGate.active = false
                IntroGate.step = nil
            }
            onboarding.wakeShelf = { [weak self] in self?.controller.wake() }
            onboarding.showGuide = { [weak self] level in self?.controller.showGuide(level) }
            onboarding.shelfScreen = { [weak self] in self?.controller.shelfScreen }
            onboarding.openSettings = { [weak self] in
                DispatchQueue.main.async { self?.showSettings() }
            }
            self.onboarding = onboarding
        }
        // Auf dem abgedunkelten Bildschirm mit hellem Rahmen, damit man die Ablage sieht
        ui.forcesOutline = true
        ShelfMenu.disabled = true
        IntroGate.active = true
        onboarding?.show()
    }

    /// Läuft BarDrop schon (z. B. eine ältere Version aus dem DMG), wird diese beendet.
    /// Zwei Ablagen am selben Rand würden sich gegenseitig stören (nach perch).
    private func endOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != me {
            Log.app.info("Andere BarDrop-Instanz wird beendet")
            app.terminate()
        }
    }

    // MARK: Einstellungen

    func showSettings(pane: SettingsPane? = nil) {
        guard store != nil else { return }   // noch nicht gestartet (wartet nach Update)
        // Aus dem Rechtsklick-Menü gewählt: Die Einstellungen sollen den Fokus behalten
        ShelfMenu.openedWindow = true
        if let pane { SettingsNavigation.shared.pane = pane }
        if settingsWindow == nil {
            let window = SettingsWindowFactory.make(settings: settings, store: store) { [weak self] in
                DispatchQueue.main.async { self?.showOnboarding() }
            }
            window.delegate = self
            settingsWindow = window
        }
        // Auf dem Bildschirm der Ablage öffnen, mittig in dessen sichtbarem Bereich
        // Liegt das Fenster nicht mehr ganz auf einem Bildschirm (z. B. Monitor abgesteckt),
        // wird es ebenfalls neu mittig gesetzt
        let fullyVisible = settingsWindow.map { w in NSScreen.screens.contains { $0.visibleFrame.contains(w.frame) } } ?? false
        if let window = settingsWindow, let target = controller.currentScreen ?? NSScreen.main,
           !window.isVisible || !fullyVisible || window.screen?.frame != target.frame {
            let area = target.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                          y: (area.midY - size.height / 2).rounded()))
        }
        // Solange die Einstellungen offen sind, ist BarDrop eine normale App (Dock-Symbol,
        // ⌘⇥). Ohne Dock-Symbol behandelt macOS das Fenster nicht wie ein normales: Nach dem
        // Kontrollzentrum oder einem Menü der Menüleiste bekam die App davor den Fokus, und
        // die Einstellungen rutschten hinter andere Fenster oder waren nicht mehr aktiv
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            Diagnostics.shared.record("focus", "Einstellungen offen: normale App mit Dock-Symbol")
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Neue Version? Dann zeigt „Über BarDrop“ einen dezenten Hinweis, ohne eigenes Fenster
        Updater.shared.checkQuietly()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            DispatchQueue.main.async {
                // Wieder ohne Dock-Symbol, wie sonst
                if NSApp.activationPolicy() != .accessory {
                    NSApp.setActivationPolicy(.accessory)
                    Diagnostics.shared.record("focus", "Einstellungen zu: wieder ohne Dock-Symbol")
                }
                NSApp.deactivate()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}
