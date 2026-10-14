import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: Allgemein

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsPage {
            SettingsSection(L("Startup", "Start"),
                            info: L("BarDrop has no menu bar icon. Right-click an empty spot in the shelf for Settings and Quit, or open BarDrop again to show Settings.",
                                    "BarDrop hat kein Symbol in der Menüleiste. Ein Rechtsklick auf eine leere Stelle der Ablage öffnet Einstellungen und Beenden, BarDrop erneut öffnen zeigt ebenfalls die Einstellungen."),
                            note: loginError, noteColor: .red) {
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $launchAtLogin)
                PickerRow(L("Language", "Sprache"), selection: $settings.language,
                          options: AppLanguage.allCases.map { ($0, $0.title) })
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = L("Not possible. Is BarDrop in the Applications folder?",
                                   "Nicht möglich. Liegt BarDrop im Ordner „Programme“?")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            SettingsSection(L("Opening", "Öffnen"),
                            info: L("Move the pointer to the edge and a thin strip appears. Keep it there for the delay and the shelf opens. With “On click” a slightly larger handle appears instead, and a click opens the shelf. When you drag a file to the edge, the shelf always opens by itself.",
                                    "Fährt der Zeiger an den Rand, erscheint zuerst ein schmaler Streifen. Bleibt er dort für die eingestellte Wartezeit, öffnet sich die Ablage. Bei „Per Klick“ erscheint stattdessen ein etwas größerer Griff, ein Klick darauf öffnet die Ablage. Ziehst du eine Datei an den Rand, öffnet sie sich immer von selbst.")) {
                PickerRow(L("Open shelf", "Ablage öffnen"), selection: $settings.openMode,
                          options: OpenMode.allCases.map { ($0, $0.title) })
                PickerRow(L("Delay", "Wartezeit"), selection: $settings.openDelay,
                          options: OpenDelay.choices.map { ($0, OpenDelay.title($0)) })
                    .disabled(settings.openMode != .automatic)
                if settings.openMode == .automatic
                    && settings.openDelay >= AppSettings.clickToOpenMinDelay - 0.01 {
                    ToggleRow(L("Click strip to open right away", "Klick auf den Streifen öffnet sofort"),
                              info: L("With a delay of one second or more you don’t have to wait: clicking the black strip opens the shelf immediately. Without a click it opens after the delay as usual.",
                                      "Bei einer Wartezeit ab einer Sekunde musst du nicht warten: Ein Klick auf den schwarzen Streifen öffnet die Ablage sofort. Ohne Klick öffnet sie wie gewohnt nach der Wartezeit."),
                              isOn: $settings.clickToOpenEarly)
                }
                ToggleRow(L("Larger hit area", "Größerer Trefferbereich"),
                          info: L("The strip and handle also respond when the pointer is slightly next to them. Helpful if you often just miss the strip.",
                                  "Streifen und Griff reagieren auch, wenn der Zeiger knapp daneben ist. Hilfreich, wenn du den Streifen oft knapp verfehlst."),
                          isOn: $settings.generousHitArea)
                PickerRow(L("While dragging files", "Beim Ziehen von Dateien"), selection: $settings.dragReveal,
                          options: DragReveal.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("Feedback", "Rückmeldung")) {
                ToggleRow(L("Haptic feedback", "Haptisches Feedback"),
                          info: L("A subtle tap on the trackpad when the strip appears, when you drop something, over actions and when a slider snaps.",
                                  "Ein dezenter Impuls auf dem Trackpad, wenn der Streifen erscheint, beim Ablegen, über Aktionen und wenn ein Regler einrastet."),
                          isOn: $settings.hapticsEnabled)
            }

            SettingsSection(L("Reset", "Zurücksetzen")) {
                SettingsRow(L("All settings", "Alle Einstellungen"),
                            info: L("Resets every setting to how BarDrop shipped, including the shortcut, the action bar and “Open at login”. The language and the items in the shelf stay as they are.",
                                    "Setzt alle Einstellungen auf den Auslieferungszustand, auch Kurzbefehl, Aktionsleiste und „Beim Anmelden öffnen“. Sprache und Objekte in der Ablage bleiben, wie sie sind.")) {
                    Button(L("Reset", "Zurücksetzen")) { confirmReset() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?", "Alle Einstellungen zurücksetzen?")
        alert.informativeText = L("All settings, including the shortcut and the action bar, go back to how BarDrop shipped. The items in the shelf are kept. This can’t be undone.",
                                  "Alle Einstellungen, auch Kurzbefehl und Aktionsleiste, werden auf den Auslieferungszustand gesetzt. Die Objekte in der Ablage bleiben erhalten. Das lässt sich nicht widerrufen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset", "Zurücksetzen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.icon = NSApp.applicationIconImage
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetAll()
        if launchAtLogin { launchAtLogin = false }   // meldet BarDrop über onChange ab
    }
}

// MARK: Tastatur

struct KeyboardSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var hotKeyStatus = HotKeyStatus.shared

    var body: some View {
        SettingsPage {
            SettingsSection(L("Show or hide the shelf", "Ablage ein- oder ausblenden"),
                            info: L("Click a modifier key to turn it on or off. Click the key on the right, then press a new one.",
                                    "Sondertasten anklicken, um sie an- oder abzuschalten. Auf die Taste rechts klicken und eine neue drücken."),
                            note: hotKeyStatus.available ? nil : L("Another app already uses this shortcut. Choose a different combination.",
                                                                   "Dieser Kurzbefehl ist schon von einer anderen App belegt. Wähl eine andere Kombination."),
                            noteColor: .red) {
                HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill", help: L("Restore default", "Standard wiederherstellen"),
                                 disabled: settings.hotKeyIsDefault) { settings.resetHotKey() }
            } content: {
                HotKeyEditor(settings: settings)
                    .padding(8)
            }

            SettingsSection(L("In the open shelf", "In der offenen Ablage")) {
                ShortcutRow(L("Quick Look", "Übersicht"), L("Space or ⌘Y", "Leertaste oder ⌘Y"))
                ShortcutRow(L("Open", "Öffnen"), L("↩ or ⌘O", "↩ oder ⌘O"))
                ShortcutRow(L("Show in Finder", "Im Finder zeigen"), "⌘R")
                ShortcutRow(L("Move selection", "Auswahl bewegen"), "← → ↑ ↓")
                ShortcutRow(L("Extend selection", "Auswahl erweitern"), L("⇧ + arrow key", "⇧ + Pfeiltaste"))
                ShortcutRow(L("Select all", "Alle auswählen"), "⌘A")
                ShortcutRow(L("Copy", "Kopieren"), "⌘C")
                ShortcutRow(L("Copy path", "Pfad kopieren"), "⌥⌘C")
                ShortcutRow(L("Paste from clipboard", "Aus der Zwischenablage einfügen"), "⌘V")
                ShortcutRow(L("Remove selection", "Auswahl entfernen"), L("⌫ or ⌘⌫", "⌫ oder ⌘⌫"))
                ShortcutRow(L("Undo", "Widerrufen"), "⌘Z")
                ShortcutRow(L("Redo", "Wiederholen"), "⇧⌘Z")
                ShortcutRow(L("Settings", "Einstellungen"), "⌘,")
                ShortcutRow(L("Quit BarDrop", "BarDrop beenden"), "⌘Q")
                ShortcutRow(L("Clear selection, then close", "Auswahl aufheben, dann schließen"), "esc")
            }

            SettingsSection(L("Stacks", "Stapel"),
                            info: L("These commands are also in the context menu of the items.",
                                    "Die Befehle stehen auch im Kontextmenü der Objekte.")) {
                ShortcutRow(L("Open stack", "Stapel öffnen"), L("Click", "Klick"))
                ShortcutRow(L("Back to the shelf", "Zurück zur Ablage"), L("esc or ⌘↑", "esc oder ⌘↑"))
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: String
    init(_ title: String, _ keys: String) {
        self.title = title
        self.keys = keys
    }
    var body: some View {
        SettingsRow(title) {
            Text(keys)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Ablage

/// Wo am Rand die Ablage erscheint (fasst „adaptiv“ und „mittleres Drittel“ zusammen)
private enum HeightMode: String, CaseIterable, Identifiable {
    case fixed, adaptive, middleHalf, middleThird
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return L("Fixed", "Fest")
        case .adaptive: return L("Follows pointer", "Am Zeiger")
        case .middleHalf: return L("Follows pointer, middle half", "Am Zeiger, nur mittlere Hälfte")
        case .middleThird: return L("Follows pointer, middle third", "Am Zeiger, nur mittleres Drittel")
        }
    }
}

struct ShelfSettings: View {
    @ObservedObject var settings: AppSettings

    private var heightMode: Binding<HeightMode> {
        Binding(
            get: {
                guard settings.adaptivePosition else { return .fixed }
                guard settings.adaptiveMiddleThird else { return .adaptive }
                return settings.adaptiveZoneHalf ? .middleHalf : .middleThird
            },
            set: { mode in
                settings.adaptivePosition = mode != .fixed
                settings.adaptiveMiddleThird = mode == .middleHalf || mode == .middleThird
                if mode == .middleHalf || mode == .middleThird { settings.adaptiveZoneHalf = mode == .middleHalf }
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsCard {
                ScreenPreview(settings: settings)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            SettingsSection(L("Position", "Position"),
                            info: L("“Follows pointer” makes the shelf appear wherever the pointer reaches the edge. Limited to the middle, the rest of the edge stays free, for example for hot corners.",
                                    "„Am Zeiger“ lässt die Ablage dort erscheinen, wo der Zeiger den Rand erreicht. Auf die Mitte beschränkt, bleibt der übrige Rand frei, etwa für aktive Ecken.")) {
                PickerRow(L("Screen edge", "Bildschirmrand"), selection: $settings.edge,
                          options: ScreenEdge.allCases.map { ($0, $0.title) })
                PickerRow(L("Displays", "Bildschirme"), selection: $settings.displayMode,
                          options: DisplayMode.allCases.map { ($0, $0.title) })
                PickerRow(L("Position along the edge", "Position am Rand"), selection: heightMode,
                          options: HeightMode.allCases.map { ($0, $0.title) })
                if !settings.adaptivePosition {
                    SliderRow(L("Height on screen", "Höhe am Rand"), value: $settings.verticalPosition, range: 0...1, step: 0.05,
                              format: SliderRow.percent)
                }
            }

            SettingsSection(L("Size", "Größe"),
                            info: L("While you adjust it, the open shelf appears at the edge so you can see the new size right away.",
                                    "Beim Verändern zeigt sich die offene Ablage am Rand, so siehst du die neue Größe sofort.")) {
                SliderRow(L("Width", "Breite"), value: $settings.shelfWidth, range: 240...400, step: 10,
                          format: SliderRow.points)
                SliderRow(L("Height", "Höhe"), value: $settings.shelfHeight, range: 280...680, step: 10,
                          format: SliderRow.points)
            }

            SettingsSection(L("Strip at the edge", "Streifen am Rand"),
                            info: L("The strip curves out of the screen edge before the shelf opens. “Edge curve” sets how softly it blends into the edge. While you adjust it, the strip appears at the edge.",
                                    "Der Streifen wölbt sich aus dem Bildschirmrand, bevor die Ablage aufgeht. „Rundung zum Rand“ bestimmt, wie weich er in den Rand übergeht. Beim Verändern zeigt sich der Streifen am Rand.")) {
                HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill",
                                 help: L("Reset position, size and strip", "Position, Größe und Streifen zurücksetzen")) {
                    settings.resetShelfLayout()
                }
            } content: {
                SliderRow(L("Thickness", "Dicke"), value: $settings.peekThickness, range: 3...20, step: 1,
                          format: SliderRow.points)
                SliderRow(L("Length", "Länge"), value: $settings.peekLength, range: 60...200, step: 4,
                          format: SliderRow.points)
                SliderRow(L("Edge curve", "Rundung zum Rand"), value: $settings.peekRoundness, range: 0...1, step: 0.05,
                          format: SliderRow.percent)
            }

            SettingsSection(L("Appearance", "Aussehen")) {
                ToggleRow(L("Light outline", "Heller Rahmen"),
                          info: L("A thin light line around the black strip and the open shelf. It makes the shape visible on dark backgrounds and is barely noticeable on light ones. When off, the shape is pure black.",
                                  "Eine feine helle Linie um den schwarzen Streifen und die offene Ablage. Auf dunklem Hintergrund macht sie die Form sichtbar, auf hellem fällt sie kaum auf. Ausgeschaltet ist die Form rein schwarz."),
                          isOn: $settings.showOutline)
                PickerRow(L("Animation", "Animation"),
                          info: AnimationStyle.reduceMotion
                              ? L("“Reduce motion” is on in Accessibility: BarDrop only fades.",
                                  "„Bewegung reduzieren“ ist in den Bedienungshilfen aktiv: BarDrop blendet nur weich über.")
                              : L("How lively the strip and the shelf open and close.",
                                  "Wie lebhaft Streifen und Ablage auf- und zuklappen."),
                          selection: $settings.animationStyle,
                          options: AnimationStyle.allCases.map { ($0, $0.title) })
                    .disabled(AnimationStyle.reduceMotion)
            }
        }
    }
}

/// Kleine Bildschirmvorschau mit der Ablage an der gewählten Stelle.
private struct ScreenPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let w: CGFloat = 220, h: CGFloat = 132
        let nubH: CGFloat = 34, nubW: CGFloat = 4
        let usable = h - 12 - nubH - 8
        let y = 12 + 4 + usable * (1 - CGFloat(settings.verticalPosition))

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.55),
                                              Color(nsColor: .controlAccentColor).opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: w, height: 8)
            if settings.adaptivePosition {
                // Bereich, in dem die adaptive Ablage reagiert
                let zone = settings.adaptiveZoneFraction ?? 1
                let top: CGFloat = 8 + (h - 8) * (1 - zone) / 2
                let len: CGFloat = (h - 8) * zone
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 4, height: len)
                    .offset(x: settings.edge == .right ? w - 4 : 0, y: top)
            }
            EdgeBlobShape(edge: settings.edge, cornerRadius: 2, fillet: 4, filletStretch: 1.4)
                .fill(Color.black)
                .opacity(settings.adaptivePosition ? 0 : 1)
                .frame(width: nubW, height: nubH)
                .offset(x: settings.edge == .right ? w - nubW : 0, y: y)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.edge)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.verticalPosition)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

// MARK: Objekte

/// Was nach dem Verwenden eines Objekts passiert (fasst zwei Schalter zusammen)
private enum AfterUse: String, CaseIterable, Identifiable {
    case keep, afterActions, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return L("Keep in the shelf", "In der Ablage behalten")
        case .afterActions: return L("Remove after actions", "Nach Aktionen entfernen")
        case .always: return L("Always remove", "Immer entfernen")
        }
    }
}

struct ItemSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ShelfStore

    private var autoRemove: Binding<AutoRemoveOption> {
        Binding(get: { AutoRemoveOption(rawValue: settings.autoRemoveAfter) ?? .never },
                set: { settings.autoRemoveAfter = $0.rawValue })
    }

    /// 0 = keine Stapel, sonst Anzahl
    private var stackFrom: Binding<Int> {
        Binding(get: { settings.stackMultiple ? settings.stackThreshold : 0 },
                set: { value in
                    settings.stackMultiple = value > 0
                    if value > 0 { settings.stackThreshold = value }
                })
    }

    private var afterUse: Binding<AfterUse> {
        Binding(
            get: {
                if settings.removeAfterDragOut { return .always }
                return settings.keepAfterAction ? .keep : .afterActions
            },
            set: { value in
                settings.removeAfterDragOut = value == .always
                settings.keepAfterAction = value == .keep
            }
        )
    }

    /// Erklärung passend zur gewählten Option
    private var afterUseNote: String {
        let move = L(" Without “Only copy”, destinations like the Finder may also move files; the shelf finds them again afterwards.",
                     " Ohne „Nur kopieren“ dürfen Ziele wie der Finder Dateien auch verschieben; die Ablage findet sie danach wieder.")
        switch afterUse.wrappedValue {
        case .keep:
            return L("Items stay in the shelf until you remove them.",
                     "Objekte bleiben in der Ablage, bis du sie entfernst.") + move
        case .afterActions:
            return L("Items disappear after AirDrop, Mail, folders and other actions, but stay when you drag them out.",
                     "Objekte verschwinden nach AirDrop, Mail, Ordnern und anderen Aktionen, bleiben aber nach dem Herausziehen erhalten.") + move
        case .always:
            return L("Items disappear after you drag them out and after actions. Press ⌘Z to bring them back.",
                     "Objekte verschwinden nach dem Herausziehen und nach Aktionen. Mit ⌘Z holst du sie zurück.") + move
        }
    }

    var body: some View {
        SettingsPage {
            SettingsSection(L("Order", "Anordnung")) {
                PickerRow(L("Sort order", "Reihenfolge"), selection: $settings.sortOrder,
                          options: SortOrder.allCases.map { ($0, $0.title) })
                PickerRow(L("Group into a stack", "Stapel bilden"),
                          info: L("When this many items are dropped at once, they become a stack. You can also select several items and right-click “Group as Stack”. Click a stack to open it.",
                                  "Werden so viele Objekte auf einmal abgelegt, entsteht ein Stapel. Du kannst auch mehrere Objekte auswählen und per Rechtsklick „Als Stapel zusammenfassen“. Ein Klick öffnet einen Stapel."),
                          selection: stackFrom,
                          options: [(0, L("Never", "Nie"))] + (2...10).map { ($0, L("From \($0) items", "Ab \($0) Objekten")) })
            }

            SettingsSection(L("Using items", "Verwenden"), info: afterUseNote) {
                PickerRow(L("After use", "Nach dem Verwenden"), selection: afterUse,
                          options: AfterUse.allCases.map { ($0, $0.title) })
                ToggleRow(L("Only copy when dragging out", "Beim Herausziehen nur kopieren"), isOn: $settings.dragOutCopyOnly)
            }

            SettingsSection(L("Storage", "Speichern"),
                            info: L("Without a copy, files from the Finder are only linked and are found again even after you move or rename them. Images from the web are always stored; WebP, AVIF and HEIC can be saved as PNG or JPEG.",
                                    "Ohne Kopie werden Dateien aus dem Finder nur verknüpft und auch nach dem Verschieben oder Umbenennen wiedergefunden. Bilder aus dem Web werden immer gespeichert, WebP, AVIF und HEIC auf Wunsch als PNG oder JPEG.")) {
                ToggleRow(L("Always store a copy", "Immer eine Kopie anlegen"), isOn: $settings.copyAllFiles)
                ToggleRow(L("Save web images as PNG or JPEG", "Bilder aus dem Web als PNG oder JPEG speichern"), isOn: $settings.convertWebImages)
            }

            SettingsSection(L("Cleanup", "Aufräumen"),
                            info: L("Files from the Finder are never deleted when you remove them. Images, links and text that only exist in BarDrop are deleted once removing them can no longer be undone with ⌘Z.",
                                    "Dateien aus dem Finder bleiben beim Entfernen erhalten. Bilder, Links und Texte, die nur in BarDrop liegen, werden gelöscht, sobald sich das Entfernen nicht mehr mit ⌘Z widerrufen lässt.")) {
                PickerRow(L("Remove automatically", "Automatisch entfernen"), selection: autoRemove,
                          options: AutoRemoveOption.allCases.map { ($0, $0.title) })
                SettingsRow(L("Remove all items", "Alle Objekte entfernen")) {
                    Button(L("Remove", "Entfernen")) {
                        let count = store.entries.reduce(0) { $0 + $1.files.count }
                        if ShelfActions.confirmRemovingAll(count) { store.removeAll() }
                    }
                    .buttonStyle(KlackButtonStyle(destructive: true))
                    .disabled(store.entries.isEmpty)
                }
            }
        }
    }
}

// MARK: Aktionen

struct ActionSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: QuickAction.ID?
    @State private var addButtonFrame: CGRect = .zero

    // Anordnen per Ziehen: Die gezogene Zeile folgt dem Zeiger, die anderen rücken
    // Platz für Platz nach, jeder neue Platz rastet mit einem leichten Impuls ein.
    @State private var dragging: QuickAction.ID?
    @State private var dragStartIndex = 0
    @State private var dragTranslation: CGFloat = 0

    /// Zeilenhöhe plus Trennlinie: so weit ist ein Platz vom nächsten entfernt
    private static let rowHeight: CGFloat = 52
    private static let pitch: CGFloat = rowHeight + 1

    private var limit: Int { QuickAction.limit(twoRows: settings.twoActionRows) }

    var body: some View {
        SettingsPage {
            SettingsSection(L("Action bar", "Aktionsleiste"),
                            info: L("Drag items onto an action at the bottom of the shelf, or select them and click the action. Drag a row to reorder, or right-click it. Up to \(limit) actions.",
                                    "Objekte auf eine Aktion unten in der Ablage ziehen oder auswählen und die Aktion anklicken. Zum Anordnen eine Zeile ziehen oder per Rechtsklick verschieben. Höchstens \(limit) Aktionen.")) {
                HStack(spacing: 8) {
                    addMenu
                    HeaderIconButton(symbol: "minus.circle.fill", help: L("Remove selected action", "Ausgewählte Aktion entfernen"),
                                     disabled: selection == nil) {
                        if let action = settings.quickActions.first(where: { $0.id == selection }) { remove(action) }
                    }
                    HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill", help: L("Restore defaults", "Standard wiederherstellen")) {
                        settings.quickActions = QuickAction.defaults
                        selection = nil
                    }
                }
            } content: {
                ForEach(Array(settings.quickActions.enumerated()), id: \.element.id) { index, action in
                    row(action, index: index)
                }
                if settings.quickActions.isEmpty {
                    SettingsRow(L("No actions", "Keine Aktionen")) { EmptyView() }
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(L("Layout", "Darstellung")) {
                ToggleRow(L("Two rows", "Zwei Reihen"),
                          info: L("Shows the action bar in two rows of up to five actions each, so up to ten actions fit. With one row there is room for six.",
                                  "Zeigt die Aktionsleiste in zwei Reihen mit je bis zu fünf Aktionen, so passen bis zu zehn hinein. Mit einer Reihe ist Platz für sechs."),
                          isOn: $settings.twoActionRows)
            }
        }
    }

    private func row(_ action: QuickAction, index: Int) -> some View {
        let selected = selection == action.id
        let isDragged = dragging == action.id
        let hidden = index >= limit
        return HStack(spacing: 10) {
            QuickActionIcon(action: action, size: 26)
                .opacity(hidden ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(hidden ? L("Not shown, the bar is full", "Nicht sichtbar, die Leiste ist voll") : action.help)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(isDragged ? 1 : 0.6))
                .frame(width: 28, height: Self.rowHeight)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "Zum Anordnen ziehen"))
        }
        .padding(.leading, SettingsTheme.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Self.rowHeight)
        .background(selected ? Color(nsColor: .controlAccentColor) : SettingsTheme.card)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(isDragged ? 0.35 : 0), radius: 8, y: 3)
        .scaleEffect(isDragged ? 1.015 : 1)
        .offset(y: isDragged ? dragOffset(for: index) : 0)
        .zIndex(isDragged ? 1 : 0)
        .onTapGesture { selection = selection == action.id ? nil : action.id }
        .gesture(
            // Global gemessen: Die Zeile bewegt sich selbst mit, ihr eigenes Koordinatensystem auch
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { g in dragChanged(action, index: index, translation: g.translation.height) }
                .onEnded { _ in dragEnded() }
        )
        .contextMenu {
            Button(L("Move Up", "Nach oben")) { move(action, by: -1) }
                .disabled(settings.quickActions.first?.id == action.id)
            Button(L("Move Down", "Nach unten")) { move(action, by: 1) }
                .disabled(settings.quickActions.last?.id == action.id)
            Divider()
            Button(L("Remove", "Entfernen")) { remove(action) }
        }
    }

    /// Versatz der gezogenen Zeile: Zeigerweg minus die Plätze, um die sie schon gewandert ist
    private func dragOffset(for index: Int) -> CGFloat {
        dragTranslation - CGFloat(index - dragStartIndex) * Self.pitch
    }

    private func dragChanged(_ action: QuickAction, index: Int, translation: CGFloat) {
        if dragging != action.id {
            dragging = action.id
            dragStartIndex = index
            selection = action.id
        }
        dragTranslation = translation
        let count = settings.quickActions.count
        let target = min(max(dragStartIndex + Int((translation / Self.pitch).rounded()), 0), count - 1)
        guard let current = settings.quickActions.firstIndex(where: { $0.id == action.id }),
              target != current else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            settings.quickActions.move(fromOffsets: IndexSet(integer: current),
                                       toOffset: target > current ? target + 1 : target)
        }
        Haptics.tap()   // eingerastet
    }

    private func dragEnded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragging = nil
            dragTranslation = 0
        }
    }

    private var addMenu: some View {
        HeaderIconButton(symbol: "plus.circle.fill", help: L("Add action", "Aktion hinzufügen"),
                         disabled: settings.quickActions.count >= limit) {
            showAddMenu()
        }
        .readFrame($addButtonFrame)
    }

    private func showAddMenu() {
        let menu = NSMenu()
        for kind in [QuickAction.Kind.airdrop, .mail, .messages, .share] {
            let item = ClosureMenuItem(QuickAction(kind: kind).title) { add(QuickAction(kind: kind)) }
            if settings.quickActions.contains(where: { $0.kind == kind }) {
                item.action = nil   // schon vorhanden: ausgegraut
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Folder", "Ordner")) { chooseFolder() })
        menu.addItem(ClosureMenuItem("App") { chooseApp() })
        MenuPresenter.show(menu, below: addButtonFrame)
    }

    private func remove(_ action: QuickAction) {
        settings.quickActions.removeAll { $0.id == action.id }
        if selection == action.id { selection = nil }
    }

    private func move(_ action: QuickAction, by offset: Int) {
        guard let i = settings.quickActions.firstIndex(of: action) else { return }
        let j = i + offset
        guard settings.quickActions.indices.contains(j) else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            settings.quickActions.swapAt(i, j)
        }
    }

    private func add(_ action: QuickAction) {
        guard settings.quickActions.count < limit else { return }
        settings.quickActions.append(action)
        selection = action.id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Folder that items are moved to", "Ordner, in den Objekte verschoben werden")
        if panel.runModal() == .OK, let url = panel.url {
            add(QuickAction(kind: .folder, path: url.path))
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("App that opens the items", "App, mit der Objekte geöffnet werden")
        if panel.runModal() == .OK, let url = panel.url {
            add(QuickAction(kind: .app, path: url.path))
        }
    }
}
