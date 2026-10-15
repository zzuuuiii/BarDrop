import AppKit
import SwiftUI
import Carbon
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var controller: EdgeController!
    private var hotKeyObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private var onboarding: OnboardingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        endOtherInstances()
        store = ShelfStore()
        ui = ShelfUIModel()
        controller = EdgeController(store: store, ui: ui, settings: settings)
        controller.actions.openSettings = { [weak self] in self?.showSettings() }
        controller.keepAppActive = { [weak self] in
            self?.settingsWindow?.isVisible == true || self?.onboarding?.isVisible == true
        }
        // Herausziehen fehlgeschlagen: Objekt zurück in die Ablage
        DragExporter.shared.onFailed = { [weak self] url in self?.store.restore(url) }

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

        Updater.shared.start()

        // Erster Start: Einführung. Als erledigt gilt sie erst, wenn sie geschlossen
        // wurde; geht vorher etwas schief, erscheint sie beim nächsten Start wieder.
        // Sonst zeigt sich kurz der Streifen am Rand: Ohne Dock- und Menüleistensymbol
        // sähe man sonst gar nicht, dass BarDrop läuft.
        if !settings.didLaunchBefore {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        } else {
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

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window", "Fenster"))
        windowMenu.addItem(ClosureMenuItem(L("Close", "Schließen"), key: "w") {
            // Nur echte Fenster schließen, nie die Ablage selbst
            guard let window = NSApp.keyWindow, !(window is ShelfPanel) else { return }
            window.performClose(nil)
        })
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Einführung

    func showOnboarding() {
        if onboarding == nil {
            let onboarding = OnboardingController(store: store, ui: ui, settings: settings)
            onboarding.onClose = { [weak self] in self?.onboarding = nil }
            onboarding.wakeShelf = { [weak self] in self?.controller.wake() }
            onboarding.openSettings = { [weak self] in
                DispatchQueue.main.async { self?.showSettings() }
            }
            self.onboarding = onboarding
        }
        onboarding?.show()
    }

    /// Läuft BarDrop schon (z. B. eine ältere Version aus dem DMG), wird diese beendet.
    /// Zwei Ablagen am selben Rand würden sich gegenseitig stören (nach perch).
    private func endOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != me {
            Log.edge.info("Andere BarDrop-Instanz wird beendet")
            app.terminate()
        }
    }

    // MARK: Einstellungen

    func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowFactory.make(settings: settings, store: store) { [weak self] in
                DispatchQueue.main.async { self?.showOnboarding() }
            }
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            DispatchQueue.main.async { NSApp.deactivate() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}
