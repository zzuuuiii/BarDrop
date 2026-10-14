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
            SettingsSection("Start",
                            info: "BarDrop hat kein Symbol in der Menüleiste. Rechtsklick auf eine leere Stelle der Ablage öffnet Einstellungen und Beenden, BarDrop erneut öffnen zeigt ebenfalls die Einstellungen.",
                            note: loginError, noteColor: .red) {
                ToggleRow("Beim Anmelden öffnen", isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = "Nicht möglich. Liegt BarDrop im Ordner „Programme“?"
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            SettingsSection("Öffnen", info: "Fährt der Zeiger an den Rand, wölbt sich zuerst ein flacher Streifen heraus. Bleibt er dort für die eingestellte Zeit, öffnet sich die Ablage. „Per Klick“ zeigt stattdessen einen etwas größeren Griff, ein Klick darauf öffnet. Beim Ziehen einer Datei öffnet sie sich immer von selbst.") {
                PickerRow("Ablage ganz öffnen", selection: $settings.openMode,
                          options: OpenMode.allCases.map { ($0, $0.title) })
                PickerRow("Verzögerung", selection: $settings.openDelay,
                          options: OpenDelay.choices.map { ($0, OpenDelay.title($0)) })
                    .disabled(settings.openMode != .automatic)
                if settings.openMode == .automatic
                    && settings.openDelay >= AppSettings.clickToOpenMinDelay - 0.01 {
                    ToggleRow("Klick auf den Streifen öffnet sofort",
                              info: "Bei einer Verzögerung ab einer Sekunde musst du nicht warten: Ein Klick auf den schwarzen Streifen öffnet die Ablage sofort. Ohne Klick öffnet sie wie gewohnt nach der eingestellten Zeit.",
                              isOn: $settings.clickToOpenEarly)
                }
                PickerRow("Beim Ziehen von Objekten", selection: $settings.dragReveal,
                          options: DragReveal.allCases.map { ($0, $0.title) })
            }

            SettingsSection("Rückmeldung") {
                ToggleRow("Haptisches Feedback",
                          info: "Ein dezenter Impuls auf dem Trackpad beim ersten Streifen, beim Ablegen und über Aktionen.",
                          isOn: $settings.hapticsEnabled)
            }

            SettingsSection("Werkseinstellungen") {
                SettingsRow("Alle Einstellungen",
                            info: "Setzt alle Einstellungen in allen Bereichen auf den Auslieferungszustand, auch Kurzbefehl, Aktionsleiste und „Beim Anmelden öffnen“. Objekte in der Ablage bleiben erhalten.") {
                    Button("Zurücksetzen") { confirmReset() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Alle Einstellungen zurücksetzen?"
        alert.informativeText = "Alle Einstellungen, auch Kurzbefehl und Aktionsleiste, werden auf den Auslieferungszustand gesetzt. Objekte in der Ablage bleiben erhalten. Das lässt sich nicht widerrufen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Zurücksetzen")
        alert.addButton(withTitle: "Abbrechen")
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
            SettingsSection("Ablage ein- oder ausblenden",
                            info: "Sondertasten antippen, um sie an- oder abzuschalten. Auf die Taste rechts klicken und eine neue drücken.",
                            note: hotKeyStatus.available ? nil : "Dieser Kurzbefehl ist schon von einer anderen App belegt. Wähl eine andere Kombination.",
                            noteColor: .red) {
                HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill", help: "Standard wiederherstellen",
                                 disabled: settings.hotKeyIsDefault) { settings.resetHotKey() }
            } content: {
                HotKeyEditor(settings: settings)
                    .padding(8)
            }

            SettingsSection("In der offenen Ablage") {
                ShortcutRow("Übersicht", "Leertaste oder ⌘Y")
                ShortcutRow("Öffnen", "↩ oder ⌘O")
                ShortcutRow("Im Finder zeigen", "⌘R")
                ShortcutRow("Auswahl bewegen", "← → ↑ ↓")
                ShortcutRow("Auswahl erweitern", "⇧ + Pfeiltaste")
                ShortcutRow("Alle auswählen", "⌘A")
                ShortcutRow("Kopieren", "⌘C")
                ShortcutRow("Pfad kopieren", "⌥⌘C")
                ShortcutRow("Aus Zwischenablage einfügen", "⌘V")
                ShortcutRow("Auswahl entfernen", "⌫ oder ⌘⌫")
                ShortcutRow("Widerrufen", "⌘Z")
                ShortcutRow("Wiederholen", "⇧⌘Z")
                ShortcutRow("Auswahl aufheben, dann schließen", "esc")
            }

            SettingsSection("Stapel", info: "Die Befehle stehen auch im Kontextmenü der Objekte.") {
                ShortcutRow("Stapel öffnen", "Klick")
                ShortcutRow("Zurück zur Ablage", "esc oder ⌘↑")
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

/// Wie die Höhe am Rand bestimmt wird (fasst „adaptiv“ und „mittleres Drittel“ zusammen)
private enum HeightMode: String, CaseIterable, Identifiable {
    case fixed, adaptive, middleHalf, middleThird
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return "Fest"
        case .adaptive: return "Am Zeiger"
        case .middleHalf: return "Am Zeiger, mittlere Hälfte"
        case .middleThird: return "Am Zeiger, mittleres Drittel"
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

            SettingsSection("Position") {
                PickerRow("Bildschirmrand", selection: $settings.edge,
                          options: ScreenEdge.allCases.map { ($0, $0.title) })
                PickerRow("Bildschirme", selection: $settings.displayMode,
                          options: DisplayMode.allCases.map { ($0, $0.title) })
                PickerRow("Höhe", selection: heightMode,
                          options: HeightMode.allCases.map { ($0, $0.title) })
                if !settings.adaptivePosition {
                    SliderRow("Lage", value: $settings.verticalPosition, range: 0...1,
                              format: SliderRow.percent)
                }
            }

            SettingsSection("Größe", info: "Beim Verändern zeigt sich die offene Ablage am Rand, so siehst du die neue Größe sofort.") {
                SliderRow("Breite", value: $settings.shelfWidth, range: 240...400, step: 10,
                          format: SliderRow.points)
                SliderRow("Länge", value: $settings.shelfHeight, range: 280...680, step: 10,
                          format: SliderRow.points)
            }

            SettingsSection("Streifen und Griff",
                            info: "Der Streifen wölbt sich flach aus dem Rand, wie ein Stück Bildschirm. „Übergang“ bestimmt, wie weich der kleine Bogen in den Rand ausläuft. Beim Verändern zeigt sich der Streifen am Rand.") {
                HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill",
                                 help: "Lage, Größe und Streifen auf den Standard setzen") {
                    settings.resetShelfLayout()
                }
            } content: {
                SliderRow("Dicke", value: $settings.peekThickness, range: 3...20, step: 1,
                          format: SliderRow.points)
                SliderRow("Länge", value: $settings.peekLength, range: 60...200, step: 4,
                          format: SliderRow.points)
                SliderRow("Übergang", value: $settings.peekRoundness, range: 0...1,
                          format: SliderRow.percent)
            }

            SettingsSection("Aussehen") {
                ToggleRow("Heller Rahmen",
                          info: "Eine feine helle Linie um den schwarzen Streifen und die offene Ablage. Auf dunklem Hintergrund macht sie die Form sichtbar, auf hellem fällt sie kaum auf. Ausgeschaltet ist die Form rein schwarz.",
                          isOn: $settings.showOutline)
                PickerRow("Animation",
                          info: AnimationStyle.reduceMotion
                              ? "„Bewegung reduzieren“ ist in den Bedienungshilfen aktiv: BarDrop blendet nur weich über."
                              : "Bestimmt, wie lebhaft Streifen und Ablage auf- und zuklappen.",
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
        case .keep: return "In der Ablage behalten"
        case .afterActions: return "Nach Aktionen entfernen"
        case .always: return "Immer entfernen"
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
        let move = " Ohne „nur kopieren“ dürfen Ziele wie der Finder Dateien auch verschieben; die Ablage findet sie danach wieder."
        switch afterUse.wrappedValue {
        case .keep: return "Objekte bleiben in der Ablage, bis du sie entfernst." + move
        case .afterActions: return "Objekte verschwinden nach AirDrop, Mail, Ordnern und anderen Aktionen, bleiben aber nach dem Herausziehen erhalten." + move
        case .always: return "Objekte verschwinden nach dem Herausziehen und nach Aktionen. Mit ⌘Z holst du sie zurück." + move
        }
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Anordnung") {
                PickerRow("Reihenfolge", selection: $settings.sortOrder,
                          options: SortOrder.allCases.map { ($0, $0.title) })
                PickerRow("Stapel bilden",
                          info: "Werden gleichzeitig so viele Objekte abgelegt, entsteht ein Stapel. Mehrere Objekte auswählen und per Rechtsklick „Als Stapel zusammenfassen“. Ein Klick öffnet einen Stapel.",
                          selection: stackFrom,
                          options: [(0, "Nie")] + (2...10).map { ($0, "Ab \($0) Objekten") })
            }

            SettingsSection("Verwenden", info: afterUseNote) {
                PickerRow("Nach dem Verwenden", selection: afterUse,
                          options: AfterUse.allCases.map { ($0, $0.title) })
                ToggleRow("Beim Herausziehen nur kopieren", isOn: $settings.dragOutCopyOnly)
            }

            SettingsSection("Speichern", info: "Ohne Kopie werden Dateien aus dem Finder nur verknüpft und auch nach dem Verschieben oder Umbenennen wiedergefunden. Bilder aus dem Web werden immer gespeichert, WebP, AVIF und HEIC auf Wunsch als PNG oder JPEG.") {
                ToggleRow("Immer eine Kopie anlegen", isOn: $settings.copyAllFiles)
                ToggleRow("Bilder aus dem Web kompatibel speichern", isOn: $settings.convertWebImages)
            }

            SettingsSection("Aufräumen", info: "Dateien aus dem Finder bleiben beim Entfernen erhalten. Bilder, Links und Texte, die nur in BarDrop liegen, werden gelöscht, sobald sich das Entfernen nicht mehr mit ⌘Z widerrufen lässt.") {
                PickerRow("Automatisch entfernen", selection: autoRemove,
                          options: AutoRemoveOption.allCases.map { ($0, $0.title) })
                SettingsRow("Alle Objekte entfernen") {
                    Button("Entfernen") {
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
    /// Aktion, die gerade zum Anordnen gezogen wird
    @State private var dragging: QuickAction.ID?

    var body: some View {
        SettingsPage {
            SettingsSection("Aktionsleiste",
                            info: "Objekte auf eine Aktion unten in der Ablage ziehen oder auswählen und die Aktion anklicken. Zum Anordnen Einträge ziehen oder per Rechtsklick verschieben. Höchstens \(QuickAction.maxCount) Aktionen.") {
                HStack(spacing: 8) {
                    addMenu
                    HeaderIconButton(symbol: "minus.circle.fill", help: "Ausgewählte Aktion entfernen",
                                     disabled: selection == nil) {
                        if let action = settings.quickActions.first(where: { $0.id == selection }) { remove(action) }
                    }
                    HeaderIconButton(symbol: "arrow.counterclockwise.circle.fill", help: "Standard wiederherstellen") {
                        settings.quickActions = QuickAction.defaults
                        selection = nil
                    }
                }
            } content: {
                ForEach(settings.quickActions) { action in
                    row(action)
                }
                if settings.quickActions.isEmpty {
                    SettingsRow("Keine Aktionen") { EmptyView() }
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Abgelegt neben den Zeilen: Ziehen beenden, damit nichts hängen bleibt
        .onDrop(of: [.text], isTargeted: nil) { _ in
            dragging = nil
            return false
        }
    }

    private func row(_ action: QuickAction) -> some View {
        let selected = selection == action.id
        return HStack(spacing: 10) {
            QuickActionIcon(action: action, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(action.help)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                .help("Zum Anordnen ziehen")
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
        .background(selected ? Color(nsColor: .controlAccentColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = selection == action.id ? nil : action.id }
        // Anordnen per Ziehen auf eine andere Zeile
        .onDrag {
            dragging = action.id
            return NSItemProvider(object: action.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDropDelegate(target: action.id,
                                                           items: $settings.quickActions,
                                                           dragging: $dragging))
        .contextMenu {
            Button("Nach oben") { move(action, by: -1) }
                .disabled(settings.quickActions.first?.id == action.id)
            Button("Nach unten") { move(action, by: 1) }
                .disabled(settings.quickActions.last?.id == action.id)
            Divider()
            Button("Entfernen") { remove(action) }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach([QuickAction.Kind.airdrop, .mail, .messages, .share], id: \.self) { kind in
                Button(QuickAction(kind: kind).title) { add(QuickAction(kind: kind)) }
                    .disabled(settings.quickActions.contains { $0.kind == kind })
            }
            Divider()
            Button("Ordner") { chooseFolder() }
            Button("App") { chooseApp() }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(settings.quickActions.count >= QuickAction.maxCount)
        .help("Aktion hinzufügen")
    }

    private func remove(_ action: QuickAction) {
        if dragging == action.id { dragging = nil }
        settings.quickActions.removeAll { $0.id == action.id }
        if selection == action.id { selection = nil }
    }

    private func move(_ action: QuickAction, by offset: Int) {
        guard let i = settings.quickActions.firstIndex(of: action) else { return }
        let j = i + offset
        guard settings.quickActions.indices.contains(j) else { return }
        settings.quickActions.swapAt(i, j)
    }

    private func add(_ action: QuickAction) {
        guard settings.quickActions.count < QuickAction.maxCount else { return }
        settings.quickActions.append(action)
        selection = action.id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Hinzufügen"
        panel.message = "Ordner, in den Objekte verschoben werden"
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
        panel.prompt = "Hinzufügen"
        panel.message = "App, mit der Objekte geöffnet werden"
        if panel.runModal() == .OK, let url = panel.url {
            add(QuickAction(kind: .app, path: url.path))
        }
    }
}

/// Ordnet die Aktionen um, sobald eine gezogene Zeile über eine andere kommt.
private struct ReorderDropDelegate: DropDelegate {
    let target: QuickAction.ID
    @Binding var items: [QuickAction]
    @Binding var dragging: QuickAction.ID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
