import SwiftUI
import AppKit
import Carbon

// MARK: Fenster

/// Einstellungsfenster im Stil von Klack: ein einheitlicher, durchscheinender
/// Hintergrund, links die Bereiche mit farbigen Symbolen, rechts Titel und Karten.
enum SettingsWindowFactory {
    static let size = NSSize(width: 700, height: 600)

    static func make(settings: AppSettings, store: ShelfStore, showOnboarding: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Leere Symbolleiste: hohe Titelleiste, die Ampel sitzt auf Höhe der Überschrift
        window.toolbar = NSToolbar(identifier: "BarDropSettings")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.title = "BarDrop Einstellungen"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: SettingsRoot(settings: settings, store: store,
                                                                  showOnboarding: showOnboarding))
        window.setContentSize(size)
        window.center()
        return window
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shelf, items, actions, keyboard, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .shelf: return "Ablage"
        case .items: return "Objekte"
        case .actions: return "Aktionen"
        case .keyboard: return "Tastatur"
        case .about: return "Über BarDrop"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shelf: return "sidebar.right"
        case .items: return "tray.full.fill"
        case .actions: return "square.grid.2x2.fill"
        case .keyboard: return "command"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .shelf: return Color(red: 0.2, green: 0.47, blue: 1)
        case .items: return Color(red: 1, green: 0.58, blue: 0.1)
        case .actions: return Color(red: 0.2, green: 0.78, blue: 0.4)
        case .keyboard: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .about: return Color(white: 0.55)
        }
    }
}

/// Farbiges Quadrat mit Symbol, wie in den Systemeinstellungen.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [pane.tint.opacity(0.85), pane.tint],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    let store: ShelfStore
    let showOnboarding: () -> Void
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsWindowMaterial())
        .frame(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height)
        .ignoresSafeArea()
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        ZStack(alignment: .top) {
            Color.clear
            VStack(alignment: .leading, spacing: 2) {
                row(.general)
                header("Einstellungen")
                row(.shelf)
                row(.items)
                row(.actions)
                row(.keyboard)
                header("BarDrop")
                row(.about)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 52)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func row(_ item: SettingsPane) -> some View {
        SidebarRow(item: item, selected: pane == item) { pane = item }
    }

    // MARK: Inhalt

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                PaneIcon(pane: pane, size: 24)
                Text(pane.title)
                    .font(.system(size: 15, weight: .bold))
            }
            .padding(.leading, 20)
            .frame(height: 52)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralSettings(settings: settings)
        case .shelf: ShelfSettings(settings: settings)
        case .items: ItemSettings(settings: settings, store: store)
        case .actions: ActionSettings(settings: settings)
        case .keyboard: KeyboardSettings(settings: settings)
        case .about: AboutSettings(settings: settings, showOnboarding: showOnboarding)
        }
    }
}

/// Eintrag der Seitenleiste: hell hinterlegt, wenn gewählt, dezent beim Darüberfahren.
private struct SidebarRow: View {
    let item: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PaneIcon(pane: item)
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: Über BarDrop

struct AboutSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updater = Updater.shared
    let showOnboarding: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var updateNote: String {
        switch updater.state {
        case .upToDate: return "BarDrop ist aktuell."
        case .available(let v): return "Version \(v) ist verfügbar. BarDrop wird ersetzt und startet neu, die Ablage bleibt erhalten."
        case .failed(let message): return message
        default: return "Neue Versionen kommen von GitHub und werden vor der Installation geprüft."
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BarDrop")
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 5) {
                            Text("Version \(version)")
                                .foregroundStyle(.secondary)
                            ReleaseNotesButton()
                        }
                    }
                    Spacer()
                    Button("Einführung zeigen", action: showOnboarding)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Automatisch nach Updates suchen", isOn: $settings.autoUpdateCheck)
                LabeledContent("Updates") {
                    switch updater.state {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .installing:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Wird installiert").foregroundStyle(.secondary)
                        }
                    case .available(let v):
                        Button("Auf \(v) aktualisieren") { updater.install() }
                    default:
                        Button("Jetzt suchen") { updater.check(interactive: true) }
                    }
                }
            } footer: {
                SectionNote(updateNote)
            }

            Section {
                LinkRow(title: "Alcove", detail: "Vorbild für Form und Bewegung",
                        url: "https://tryalcove.com")
                LinkRow(title: "Klack", detail: "Vorbild für die Einstellungen",
                        url: "https://tryklack.com")
                LinkRow(title: "Quellcode", detail: "github.com/zzuuuiii/BarDrop",
                        url: "https://github.com/zzuuuiii/BarDrop")
            } header: {
                SettingsHeader("Inspiriert von")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String

    var body: some View {
        LabeledContent {
            Link(destination: URL(string: url)!) {
                Image(systemName: "arrow.up.right.square")
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Kurzbefehl

/// Meldet, ob der globale Kurzbefehl registriert werden konnte.
final class HotKeyStatus: ObservableObject {
    static let shared = HotKeyStatus()
    @Published var available = true
}

/// Tasten wie auf der Tastatur: Sondertasten antippen schaltet sie an oder ab,
/// ein Klick auf die letzte Taste wartet auf eine neue.
struct HotKeyEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    private struct Modifier {
        let flag: Int
        let symbol: String
        let name: String
    }

    private let modifiers: [Modifier] = [
        Modifier(flag: shiftKey, symbol: "⇧", name: "shift"),
        Modifier(flag: controlKey, symbol: "⌃", name: "ctrl"),
        Modifier(flag: optionKey, symbol: "⌥", name: "opt"),
        Modifier(flag: cmdKey, symbol: "⌘", name: "cmd")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modifiers, id: \.flag) { mod in
                let on = settings.hotKeyModifiers & mod.flag != 0
                SettingsKeyCap(symbol: mod.symbol, name: mod.name, active: on, wide: false) {
                    toggle(mod.flag)
                }
            }
            SettingsKeyCap(symbol: recording ? "…" : settings.hotKeyLabel, name: recording ? "Taste" : "",
                           active: true, wide: true, highlighted: recording) {
                recording ? stopRecording() : startRecording()
            }
        }
        .padding(.vertical, 4)
        .onDisappear { stopRecording() }
    }

    private func toggle(_ flag: Int) {
        let new = settings.hotKeyModifiers ^ flag
        // Mindestens eine Sondertaste, sonst würde eine einfache Taste überall abgefangen
        guard new & (controlKey | optionKey | cmdKey | shiftKey) != 0, new != shiftKey else {
            NSSound.beep()
            return
        }
        settings.hotKeyModifiers = new
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {               // esc: abbrechen
                stopRecording()
                return nil
            }
            settings.hotKeyCode = Int(event.keyCode)
            settings.hotKeyLabel = Self.label(for: event)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "␣"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            return chars.isEmpty ? "?" : chars
        }
    }
}

private struct SettingsKeyCap: View {
    let symbol: String
    let name: String
    let active: Bool
    let wide: Bool
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: wide ? .center : .leading, spacing: 2) {
                if wide && name.isEmpty {
                    Spacer(minLength: 0)
                    Text(symbol).font(.system(size: 18, weight: .medium))
                    Spacer(minLength: 0)
                } else {
                    Text(symbol).font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: wide ? 64 : 74, height: 58, alignment: wide ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.25)
                          : Color.primary.opacity(active ? 0.13 : hovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0.12 : 0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(active ? 0.25 : 0), radius: 1.5, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}
