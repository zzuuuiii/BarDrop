import SwiftUI
import AppKit
import Carbon

// MARK: Fenster

/// Einstellungsfenster im Stil von Klack: ein einheitliches Grau, links die
/// Bereiche mit farbigen Symbolen, rechts Titel und Karten.
enum SettingsWindowFactory {
    static let size = NSSize(width: 680, height: 700)

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
        // Leicht durchscheinend wie bei Klack: Fenster selbst ohne Farbe,
        // die Flächen zeichnet SettingsRoot über einer Unschärfe.
        window.isOpaque = false
        window.backgroundColor = .clear
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
                .frame(width: 244)
                .frame(maxHeight: .infinity)
                .background(SettingsTheme.sidebar.opacity(SettingsTheme.backdropOpacity))
            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsTheme.content.opacity(SettingsTheme.backdropOpacity))
        }
        // Füllt das ganze Fenster, auch den Bereich unter der Titelleiste. Eine feste
        // Höhe würde nach oben verschoben und ließe unten einen leeren Streifen frei.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        ZStack(alignment: .top) {
            Color.clear
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 13)
            .padding(.top, 56)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.top, 21)
            .padding(.bottom, 7)
    }

    private func row(_ item: SettingsPane) -> some View {
        SidebarRow(item: item, selected: pane == item) { pane = item }
    }

    // MARK: Inhalt

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PaneIcon(pane: pane, size: 24)
                Text(pane.title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.leading, 18)
            .frame(height: 52)
            .padding(.bottom, 4)

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
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsTheme.selectedRow : Color.primary.opacity(hovering ? 0.04 : 0))
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

    @State private var showInspirations = false

    var body: some View {
        SettingsPage {
            SettingsSection(note: updateNote) {
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
                    updateControl
                }
                .padding(.horizontal, SettingsTheme.rowPadding)
                .padding(.vertical, 12)
                ToggleRow("Automatisch nach Updates suchen", isOn: $settings.autoUpdateCheck)
            }

            SettingsSection("Dank und Quellen") {
                // Eingeklappt: nur die Namen. Ein Klick klappt die Einträge mit Links auf.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showInspirations.toggle() }
                } label: {
                    SettingsRow("Inspiriert von", subtitle: "Alcove, Klack, boring.notch und perch") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showInspirations ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showInspirations {
                    LinkRow(title: "Alcove", detail: "Vorbild für Form und Bewegung der Ablage",
                            url: "https://tryalcove.com")
                    LinkRow(title: "Klack", detail: "Vorbild für Aufbau und Gestaltung der Einstellungen",
                            url: "https://tryklack.com")
                    LinkRow(title: "boring.notch", detail: "Code für Bilder aus dem Web und Vorschaubilder",
                            url: "https://github.com/TheBoredTeam/boring.notch")
                    LinkRow(title: "perch", detail: "Code für Herausziehen und iCloud-Dateien",
                            url: "https://github.com/hausfold/perch")
                }
                LinkRow(title: "Quellcode", detail: "github.com/zzuuuiii/BarDrop",
                        url: "https://github.com/zzuuuiii/BarDrop")
            }

            SettingsSection {
                SettingsRow("Einführung", subtitle: "Die drei Schritte vom ersten Start noch einmal") {
                    Button("Einführung zeigen", action: showOnboarding)
                        .buttonStyle(KlackButtonStyle())
                }
            }
        }
    }

    /// Knopf oben rechts: suchen, Fortschritt oder installieren
    @ViewBuilder
    private var updateControl: some View {
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
                .buttonStyle(KlackButtonStyle(prominent: true))
        default:
            Button("Nach Updates suchen") { updater.check(interactive: true) }
                .buttonStyle(KlackButtonStyle())
        }
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String

    var body: some View {
        SettingsRow(title, subtitle: detail) {
            Link(destination: URL(string: url)!) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .help(url)
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
        HStack(spacing: 8) {
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

/// Taste wie bei Klack: dunkel eingelassen, Symbol oben, Name unten.
/// Aktive Tasten sind dunkler und hell beschriftet, inaktive blass.
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
            VStack(alignment: .leading, spacing: 0) {
                if wide && name.isEmpty {
                    Text(symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(symbol).font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: wide ? 62 : .infinity, alignment: .leading)
            .frame(width: wide ? 62 : nil, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.3)
                          : Color.black.opacity(active ? 0.42 : hovering ? 0.2 : 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.06 : 0.04), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}
