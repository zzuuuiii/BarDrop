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
                            note: loginError, noteColor: .red) {
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $launchAtLogin)
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

            SettingsSection {
                PickerRow(L("Language", "Sprache"), selection: $settings.language,
                          options: AppLanguage.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("Feedback", "Rückmeldung")) {
                ToggleRow(L("Haptic feedback", "Haptisches Feedback"),
                          isOn: $settings.hapticsEnabled)
            }

            SettingsSection(L("Reset", "Zurücksetzen")) {
                SettingsRow(L("All settings", "Alle Einstellungen")) {
                    Button(L("Reset", "Zurücksetzen")) { confirmReset() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?", "Alle Einstellungen zurücksetzen?")
        alert.informativeText = L("All settings, including the shortcut and the action bar, go back to their defaults. The language and the items in the shelf are kept. This can’t be undone.",
                                  "Alle Einstellungen, auch Kurzbefehl und Aktionsleiste, werden auf den Standard zurückgesetzt. Sprache und Objekte in der Ablage bleiben erhalten. Das lässt sich nicht widerrufen.")
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
    @State private var showAll = false

    var body: some View {
        SettingsPage {
            SettingsSection(L("Show or hide the shelf", "Ablage ein- oder ausblenden"),
                            info: L("Click a modifier key to turn it on or off. Click the key on the right, then press a new one.",
                                    "Klick auf eine Sondertaste, um sie an- oder auszuschalten. Klick auf die Taste rechts und drück eine neue."),
                            note: hotKeyStatus.available ? nil : L("Another app already uses this shortcut. Choose a different combination.",
                                                                   "Dieser Kurzbefehl ist schon von einer anderen App belegt. Wähl eine andere Kombination."),
                            noteColor: .red) {
                HotKeyEditor(settings: settings)
                    .padding(8)
            }

            // Nur das Wichtigste offen, alles Weitere eingeklappt
            SettingsSection(L("In the open shelf", "In der offenen Ablage")) {
                ShortcutRow(L("Quick Look", "Übersicht"), L("Space", "Leertaste"))
                ShortcutRow(L("Remove selection", "Auswahl entfernen"), "⌫")
                ShortcutRow(L("Undo", "Widerrufen"), "⌘Z")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                } label: {
                    SettingsRow(showAll ? L("Fewer shortcuts", "Weniger Kurzbefehle") : L("All shortcuts", "Alle Kurzbefehle")) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAll ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showAll {
                    ShortcutRow(L("Open", "Öffnen"), L("↩ or ⌘O", "↩ oder ⌘O"))
                    ShortcutRow(L("Show in Finder", "Im Finder zeigen"), "⌘R")
                    ShortcutRow(L("Move or extend selection", "Auswahl bewegen oder erweitern"), L("Arrow keys, ⇧", "Pfeiltasten, ⇧"))
                    ShortcutRow(L("Select all", "Alle auswählen"), "⌘A")
                    ShortcutRow(L("Cut, copy, copy path", "Ausschneiden, kopieren, Pfad kopieren"), "⌘X  ⌘C  ⌥⌘C")
                    ShortcutRow(L("Paste from clipboard", "Aus der Zwischenablage einfügen"), "⌘V")
                    ShortcutRow(L("Redo", "Wiederholen"), "⇧⌘Z")
                    ShortcutRow(L("Back from a stack", "Zurück aus einem Stapel"), "esc  ⌘↑")
                    ShortcutRow(L("Clear selection, then close", "Auswahl aufheben, dann schließen"), "esc")
                    ShortcutRow(L("Settings, quit", "Einstellungen, beenden"), "⌘,  ⌘Q")
                }
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

// MARK: Öffnen

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

/// Öffnen: wo die Ablage am Rand sitzt und wann sie aufgeht.
struct OpeningSettings: View {
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

            SettingsSection(L("Where", "Wo")) {
                PickerRow(L("Screen edge", "Bildschirmrand"), selection: $settings.edge,
                          options: ScreenEdge.allCases.map { ($0, $0.title) })
                PickerRow(L("Position along the edge", "Position am Rand"), selection: heightMode,
                          options: HeightMode.allCases.map { ($0, $0.title) })
                if !settings.adaptivePosition {
                    SliderRow(L("Spot along the edge", "Stelle am Rand"), value: $settings.verticalPosition, range: 0...1, step: 0.05,
                              format: SliderRow.percent)
                }
                PickerRow(L("Displays", "Bildschirme"), selection: $settings.displayMode,
                          options: DisplayMode.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("When", "Wann")) {
                PickerRow(L("Open shelf", "Ablage öffnen"),
                          info: L("With a wait, clicking the strip opens the shelf right away.",
                                  "Mit Wartezeit öffnet ein Klick auf den Streifen die Ablage sofort."),
                          selection: $settings.openChoice,
                          options: OpenChoice.all.map { ($0, $0.title) })
                ToggleRow(L("Larger hit area", "Größerer Trefferbereich"),
                          isOn: $settings.generousHitArea)
                PickerRow(L("While dragging files", "Beim Ziehen von Dateien"), selection: $settings.dragReveal,
                          options: DragReveal.allCases.map { ($0, $0.title) })
                ToggleRow(L("Open in full screen", "Im Vollbild öffnen"),
                          isOn: $settings.openInFullScreen)
            }

            // Wie die Aktionsliste: Liste in einer Karte, „Hinzufügen“ als eigene Karte darunter
            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(L("Not in these apps", "Nicht in diesen Apps")) {
                    if settings.excludedApps.isEmpty {
                        Text(L("No apps", "Keine Apps"))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, SettingsTheme.rowPadding)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    ForEach(settings.excludedApps, id: \.self) { id in
                        ExcludedAppRow(bundleID: id) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                                settings.excludedApps.removeAll { $0 == id }
                            }
                        }
                    }
                }
                AddExcludedAppRow(settings: settings)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: Aussehen

struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsSection(L("Size", "Größe")) {
                SliderRow(L("Width", "Breite"), value: $settings.shelfWidth, range: 240...400, step: 10,
                          format: SliderRow.points)
                SliderRow(L("Height", "Höhe"), value: $settings.shelfHeight, range: 280...680, step: 10,
                          format: SliderRow.points)
                SliderRow(L("Icon size", "Symbolgröße"), value: $settings.tileIconSize, range: 40...96, step: 4,
                          format: SliderRow.points)
            }

            SettingsSection(L("Strip at the edge", "Streifen am Rand")) {
                SliderRow(L("Thickness", "Dicke"), value: $settings.peekThickness, range: 3...20, step: 1,
                          format: SliderRow.points)
                SliderRow(L("Length", "Länge"), value: $settings.peekLength, range: 60...200, step: 4,
                          format: SliderRow.points)
                SliderRow(L("Edge curve", "Rundung zum Rand"), value: $settings.peekRoundness, range: 0...1, step: 0.05,
                          format: SliderRow.percent)
            }

            SettingsSection(L("Style", "Stil")) {
                ToggleRow(L("Light outline", "Heller Rahmen"),
                          isOn: $settings.showOutline)
                PickerRow(L("Title", "Titel"), selection: $settings.showTitle,
                          options: [(true, "BarDrop"), (false, L("Shelf", "Ablage"))])
                PickerRow(L("Animation", "Animation"),
                          // Nur wenn die Auswahl gesperrt ist, braucht es eine Erklärung
                          info: AnimationStyle.reduceMotion
                              ? L("“Reduce motion” is on in Accessibility: BarDrop only fades.",
                                  "„Bewegung reduzieren“ ist in den Bedienungshilfen aktiv: BarDrop blendet nur weich über.")
                              : nil,
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
        let move = L(" Without “Only copy when dragging out”, destinations like the Finder may also move files; the shelf finds them again afterwards.",
                     " Ohne „Beim Herausziehen nur kopieren“ dürfen Ziele wie der Finder Dateien auch verschieben; die Ablage findet sie danach wieder.")
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
                                  "Werden so viele Objekte auf einmal abgelegt, entsteht ein Stapel. Du kannst auch mehrere Objekte auswählen und per Rechtsklick „Als Stapel zusammenfassen“ wählen. Ein Klick öffnet einen Stapel."),
                          selection: stackFrom,
                          options: [(0, L("Never", "Nie"))] + (2...10).map { ($0, L("From \($0) items", "Ab \($0) Objekten")) })
            }

            SettingsSection(L("Using items", "Verwenden"), info: afterUseNote) {
                PickerRow(L("After use", "Nach dem Verwenden"), selection: afterUse,
                          options: AfterUse.allCases.map { ($0, $0.title) })
                ToggleRow(L("Only copy when dragging out", "Beim Herausziehen nur kopieren"), isOn: $settings.dragOutCopyOnly)
            }

            SettingsSection(L("Add automatically", "Automatisch hinzufügen")) {
                ToggleRow(L("New screenshots", "Neue Bildschirmfotos"),
                          isOn: $settings.addScreenshots)
            }

            SettingsSection(L("Storage", "Speichern"),
                            info: L("Without a copy, files from the Finder are only linked and are found again even after you move or rename them. Images from the web are always stored; WebP, AVIF and HEIC can be saved as PNG or JPEG.",
                                    "Ohne Kopie werden Dateien aus dem Finder nur verknüpft und auch nach dem Verschieben oder Umbenennen wiedergefunden. Bilder aus dem Web werden immer gespeichert, WebP, AVIF und HEIC auf Wunsch als PNG oder JPEG.")) {
                ToggleRow(L("Always store a copy", "Immer eine Kopie anlegen"), isOn: $settings.copyAllFiles)
                ToggleRow(L("Save web images as PNG or JPEG", "Bilder aus dem Web als PNG oder JPEG speichern"), isOn: $settings.convertWebImages)
            }

            SettingsSection(L("Cleanup", "Aufräumen"),
                            info: L("Files from the Finder are never deleted when you remove them. Copies, images, links and text that only exist in BarDrop are deleted once removing them can no longer be undone with ⌘Z.",
                                    "Dateien aus dem Finder bleiben beim Entfernen erhalten. Kopien, Bilder, Links und Texte, die nur in BarDrop liegen, werden gelöscht, sobald sich das Entfernen nicht mehr mit ⌘Z widerrufen lässt.")) {
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

    private var limit: Int { QuickAction.limit(twoRows: settings.twoActionRows) }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 8) {
                SettingsHeader(L("Action bar", "Aktionsleiste"))
                .padding(.horizontal, 8)

                ActionListEditor(settings: settings, selection: $selection,
                                 onRemove: remove, onMove: move)
                    .zIndex(1)   // gezogene Zeile liegt über allem darunter

                AddActionRow(count: settings.quickActions.count, limit: limit, frame: $addButtonFrame) {
                    showAddMenu()
                }
                .padding(.top, 4)
            }
            .zIndex(1)

            SettingsSection(L("Layout", "Darstellung")) {
                ToggleRow(L("Two rows", "Zwei Reihen"),
                          isOn: $settings.twoActionRows.animation(.spring(response: 0.3, dampingFraction: 0.88)))
                ToggleRow(L("Show names", "Namen anzeigen"), isOn: $settings.showActionLabels)
            }

            SettingsSection(L("In the shelf", "In der Ablage")) {
                ToggleRow(L("Pin by dragging", "Per Ziehen anheften"),
                          info: L("Drag a folder or app over the open shelf and drop it on “Pin” at the end of the action bar. Drag an action out of the shelf to remove it.",
                                  "Zieh einen Ordner oder eine App über die offene Ablage und lass sie auf „Anheften“ am Ende der Aktionsleiste los. Zieh eine Aktion aus der Ablage heraus, um sie zu entfernen."),
                          isOn: $settings.pinFromShelf)
            }
        }
    }

    private func showAddMenu() {
        let menu = NSMenu()
        for kind in [QuickAction.Kind.airdrop, .mail, .messages, .share, .trash] {
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
        guard let index = settings.quickActions.firstIndex(where: { $0.id == action.id }) else { return }
        let split = settings.effectiveActionSplit
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions.remove(at: index)
            // Aus der oberen Reihe entfernt: die Grenze rückt mit, die untere Reihe bleibt, wie sie ist
            if index < split { settings.actionRowSplit = split - 1 }
        }
        if selection == action.id { selection = nil }
    }

    /// Nach oben oder unten um einen Platz; über die Grenze der Reihen hinweg wechselt die Reihe.
    private func move(_ action: QuickAction, by offset: Int) {
        guard let i = settings.quickActions.firstIndex(of: action) else { return }
        var order = settings.quickActions
        var split = settings.effectiveActionSplit
        if settings.twoActionRows {
            // Erst die Reihe wechseln, wenn die Aktion am Rand ihrer Reihe steht
            if offset < 0 && i == split, split < QuickAction.perRow { split += 1 }
            else if offset > 0 && i == split - 1, order.count - split < QuickAction.perRow { split -= 1 }
            else {
                let j = i + offset
                guard order.indices.contains(j) else { return }
                order.swapAt(i, j)
            }
        } else {
            let j = i + offset
            guard order.indices.contains(j) else { return }
            order.swapAt(i, j)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions = order
            settings.actionRowSplit = AppSettings.clampSplit(split, count: order.count)
        }
        Haptics.tap()
    }

    private func add(_ action: QuickAction) {
        guard settings.quickActions.count < limit else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions.append(action)
        }
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

// MARK: Aktionen anordnen

/// Liste der Aktionen zum Anordnen per Ziehen, bei zwei Reihen in zwei Karten.
///
/// Während des Ziehens bleibt die gespeicherte Reihenfolge unverändert. Aus der
/// Zeigerposition wird nur ein Vorschlag berechnet, und jede Zeile bekommt ihre Lage
/// aus diesem Vorschlag. Die gezogene Zeile folgt dem Zeiger, die anderen gleiten an
/// ihren neuen Platz, jeder neue Platz rastet mit einem leichten Impuls ein. Erst beim
/// Loslassen wird gespeichert. So springt nichts, und die Trennlinien bleiben stehen.
private struct ActionListEditor: View {
    @ObservedObject var settings: AppSettings
    @Binding var selection: QuickAction.ID?
    let onRemove: (QuickAction) -> Void
    let onMove: (QuickAction, Int) -> Void

    /// Reihenfolge und Grenze zwischen den Reihen
    struct Arrangement: Equatable {
        var order: [QuickAction.ID]
        var split: Int
    }

    @State private var dragging: QuickAction.ID?
    @State private var dragStartY: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var proposal: Arrangement?

    private static let rowHeight: CGFloat = 52
    private static let pitch: CGFloat = rowHeight + 1      // Zeile plus Trennlinie
    private static let labelHeight: CGFloat = 26           // „Obere Reihe“ über der Karte
    private static let rowGap: CGFloat = 14                // Abstand zwischen den Karten
    private static let space = "actionList"

    private var twoRows: Bool { settings.twoActionRows }

    private var committed: Arrangement {
        Arrangement(order: settings.quickActions.map(\.id), split: settings.effectiveActionSplit)
    }

    /// Was gerade gezeigt wird: der Vorschlag beim Ziehen, sonst das Gespeicherte
    private var shown: Arrangement { proposal ?? committed }

    // MARK: Geometrie

    private func counts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        twoRows ? (a.split, a.order.count - a.split) : (a.order.count, 0)
    }

    /// Gezeigte Zeilen je Karte. Während des Ziehens behält die obere Karte ihre Höhe,
    /// auch wenn die Aktion nach unten wandert: So bleibt die untere Reihe stehen,
    /// statt unter dem Zeiger nach oben zu springen, und man trifft ihre Plätze.
    private func displayCounts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        let c = counts(a)
        guard twoRows, dragging != nil else { return c }
        return (max(c.top, counts(committed).top), c.bottom)
    }

    private func cardHeight(_ n: Int) -> CGFloat { CGFloat(max(1, n)) * Self.pitch - 1 }

    /// Oberkante der Karte einer Reihe
    private func rowTop(_ row: Int, _ a: Arrangement) -> CGFloat {
        guard twoRows else { return 0 }
        if row == 0 { return Self.labelHeight }
        return Self.labelHeight + cardHeight(displayCounts(a).top) + Self.rowGap + Self.labelHeight
    }

    private func totalHeight(_ a: Arrangement) -> CGFloat {
        let c = displayCounts(a)
        return twoRows ? rowTop(1, a) + cardHeight(c.bottom) : cardHeight(c.top)
    }

    /// Reihe und Platz einer Aktion
    private func slot(of id: QuickAction.ID, in a: Arrangement) -> (row: Int, index: Int)? {
        guard let i = a.order.firstIndex(of: id) else { return nil }
        if twoRows && i >= a.split { return (1, i - a.split) }
        return (0, i)
    }

    private func y(of id: QuickAction.ID, in a: Arrangement) -> CGFloat {
        guard let s = slot(of: id, in: a) else { return 0 }
        return rowTop(s.row, a) + CGFloat(s.index) * Self.pitch
    }

    // MARK: Vorschlag aus der Zeigerposition

    /// Wohin die gezogene Aktion käme, wenn ihre Oberkante bei `top` liegt.
    private func propose(for id: QuickAction.ID, top: CGFloat) -> Arrangement {
        let base = committed
        var rest = base.order
        guard let from = rest.firstIndex(of: id) else { return base }
        rest.remove(at: from)
        let center = top + Self.rowHeight / 2

        guard twoRows else {
            let index = min(max(Int(((center - Self.rowHeight / 2) / Self.pitch).rounded()), 0), rest.count)
            rest.insert(id, at: index)
            return Arrangement(order: rest, split: base.split)
        }

        // Zwei Reihen: Anzahlen ohne die gezogene Aktion
        let topCount = from < base.split ? base.split - 1 : base.split
        let bottomCount = rest.count - topCount
        // Grenze: Mitte zwischen der oberen Karte, wie sie gerade zu sehen ist, und der
        // unteren. Sie wandert nur, wenn die obere Karte wächst; das wirkt zugleich als
        // Puffer, damit die Reihe an der Grenze nicht hin und her springt.
        let shownTop = displayCounts(shown).top
        let boundary = Self.labelHeight + cardHeight(shownTop) + (Self.rowGap + Self.labelHeight) / 2
        let toBottomRow = center > boundary

        var split = topCount
        let insertAt: Int
        if toBottomRow {
            // Die obere Karte behält beim Ziehen mindestens ihre ursprüngliche Höhe
            let rowStart = Self.labelHeight + cardHeight(max(topCount, base.split)) + Self.rowGap + Self.labelHeight
            let index = min(max(Int(((center - rowStart - Self.rowHeight / 2) / Self.pitch).rounded()), 0), bottomCount)
            insertAt = topCount + index
        } else {
            let index = min(max(Int(((center - Self.labelHeight - Self.rowHeight / 2) / Self.pitch).rounded()), 0), topCount)
            insertAt = index
            split += 1
        }
        rest.insert(id, at: insertAt)
        // Ist die Zielreihe voll, rückt ihre letzte bzw. erste Aktion in die andere Reihe
        return Arrangement(order: rest, split: AppSettings.clampSplit(split, count: rest.count))
    }

    // MARK: Ansicht

    var body: some View {
        let a = shown
        let c = counts(a)
        let actions = Dictionary(uniqueKeysWithValues: settings.quickActions.map { ($0.id, $0) })
        let hiddenFrom = QuickAction.limit(twoRows: twoRows)

        ZStack(alignment: .topLeading) {
            // Karten, Überschriften und Trennlinien: stehen fest, nur die Höhe passt sich an
            if twoRows {
                rowLabel(L("Top row", "Obere Reihe"), y: 0)
                rowLabel(L("Bottom row", "Untere Reihe"), y: rowTop(1, a) - Self.labelHeight)
                let d = displayCounts(a)
                card(count: d.top, top: rowTop(0, a), emptyHint: c.top == 0)
                card(count: d.bottom, top: rowTop(1, a), emptyHint: c.bottom == 0)
            } else {
                card(count: c.top, top: 0, emptyHint: false)
                if a.order.isEmpty {
                    Text(L("No actions", "Keine Aktionen"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, SettingsTheme.rowPadding)
                        .frame(height: Self.rowHeight)
                }
            }

            // Zeilen: liegen frei über den Karten
            ForEach(settings.quickActions) { action in
                let isDragged = dragging == action.id
                let index = a.order.firstIndex(of: action.id) ?? 0
                ActionRow(action: action,
                          selected: selection == action.id,
                          lifted: isDragged,
                          hidden: !twoRows && index >= hiddenFrom,
                          dragging: dragging != nil,
                          onRemove: { onRemove(action) })
                    .frame(height: Self.rowHeight)
                    .offset(y: isDragged ? dragStartY + dragTranslation : y(of: action.id, in: a))
                    .zIndex(isDragged ? 2 : 1)
                    .onTapGesture { selection = selection == action.id ? nil : action.id }
                    .gesture(dragGesture(for: action))
                    .contextMenu { menu(for: action) }
            }
            .animation(nil, value: dragTranslation)
        }
        .frame(height: totalHeight(a), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onChange(of: actions.count) { _, _ in
            if let id = dragging, actions[id] == nil { endDrag(commit: false) }
        }
    }

    private func rowLabel(_ text: String, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .frame(height: Self.labelHeight, alignment: .center)
            .offset(y: y)
    }

    /// Karte mit Trennlinien für `count` Zeilen; leer mit Hinweis zum Hineinziehen.
    private func card(count: Int, top: CGFloat, emptyHint: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .fill(SettingsTheme.card)
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            ForEach(1..<max(count, 1), id: \.self) { i in
                Rectangle()
                    .fill(SettingsTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, SettingsTheme.rowPadding + 36)
                    .offset(y: CGFloat(i) * Self.pitch - 1)
            }
            if emptyHint {
                Text(L("Drag actions here", "Aktionen hierher ziehen"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
            }
        }
        .frame(height: cardHeight(count))
        .offset(y: top)
    }

    @ViewBuilder
    private func menu(for action: QuickAction) -> some View {
        let order = settings.quickActions
        Button(L("Move Up", "Nach oben")) { onMove(action, -1) }
            .disabled(order.first?.id == action.id)
        Button(L("Move Down", "Nach unten")) { onMove(action, 1) }
            .disabled(order.last?.id == action.id)
        Divider()
        Button(L("Remove", "Entfernen")) { onRemove(action) }
    }

    // MARK: Ziehen

    private func dragGesture(for action: QuickAction) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if dragging != action.id {
                    dragging = action.id
                    dragStartY = y(of: action.id, in: committed)
                }
                // Nur innerhalb der Liste: von der ersten bis zur letzten Zeile
                // (mit zwei Reihen bis zum letzten Platz der unteren Reihe)
                let minTop = twoRows ? Self.labelHeight : 0
                let maxTop = max(minTop, totalHeight(shown) - Self.rowHeight)
                let top = min(max(dragStartY + g.translation.height, minTop), maxTop)
                dragTranslation = top - dragStartY
                let next = propose(for: action.id, top: top)
                if next != shown {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { proposal = next }
                    Haptics.tap()   // eingerastet
                }
            }
            .onEnded { _ in endDrag(commit: true) }
    }

    private func endDrag(commit: Bool) {
        if commit, let proposal {
            // Ohne Animation speichern: Die Zeilen stehen schon an diesem Platz
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                let byID = Dictionary(uniqueKeysWithValues: settings.quickActions.map { ($0.id, $0) })
                let order = proposal.order.compactMap { byID[$0] }
                if order.count == settings.quickActions.count {
                    settings.quickActions = order
                    settings.actionRowSplit = proposal.split
                }
            }
        }
        // Die gezogene Zeile gleitet auf ihren Platz
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            dragging = nil
            dragTranslation = 0
            proposal = nil
        }
    }
}

/// Eine Zeile der Aktionsliste.
private struct ActionRow: View {
    let action: QuickAction
    let selected: Bool
    let lifted: Bool
    let hidden: Bool
    /// Irgendeine Zeile wird gerade gezogen: dann keine Knöpfe einblenden
    let dragging: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            QuickActionIcon(action: action, size: 26)
                .opacity(hidden ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(hidden ? L("Not shown, the bar is full", "Nicht sichtbar, die Leiste ist voll") : action.help)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Entfernen direkt an der Zeile, sichtbar beim Darüberfahren
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 26, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Remove", "Entfernen"))
            .opacity(hovering && !dragging ? 1 : 0)
            .allowsHitTesting(hovering && !dragging)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(lifted ? 1 : 0.6))
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "Zum Anordnen ziehen"))
        }
        .padding(.leading, SettingsTheme.rowPadding)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: lifted ? SettingsTheme.cardRadius : 8, style: .continuous)
                .fill(selected ? Color(nsColor: .controlAccentColor) : (lifted ? SettingsTheme.card : Color.clear))
                .padding(lifted ? 0 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: lifted ? 1 : 0)
        )
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 10, y: 4)
        .scaleEffect(lifted ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Letzte Zeile unter der Aktionsliste: neue Aktion hinzufügen, wie in den Listen
/// der Systemeinstellungen. Ist die Leiste voll, steht das dort.
private struct AddActionRow: View {
    let count: Int
    let limit: Int
    @Binding var frame: CGRect
    let action: () -> Void

    var body: some View {
        let full = count >= limit
        AddListRow(title: full ? L("The bar is full (\(count) of \(limit))", "Die Leiste ist voll (\(count) von \(limit))")
                               : L("Add Action", "Aktion hinzufügen"),
                   enabled: !full, frame: $frame, action: action)
    }
}

/// Eigene Karte unter einer Liste: Eintrag hinzufügen (Aktionen, ausgenommene Apps).
struct AddListRow: View {
    let title: String
    var enabled = true
    @Binding var frame: CGRect
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(enabled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(enabled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                Spacer()
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .fill(SettingsTheme.card.opacity(hovering && enabled ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .readFrame($frame)
    }
}

// MARK: Ausgenommene Apps

/// Eine ausgenommene App: Symbol, Name, Entfernen beim Darüberfahren.
private struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void
    @State private var hovering = false

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    private var name: String {
        guard let url = appURL else { return bundleID }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            Text(name)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Remove", "Entfernen"))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button(L("Remove", "Entfernen"), action: onRemove)
        }
    }
}

/// Letzte Zeile der Liste: App hinzufügen, aus den laufenden Apps oder per Auswahl.
private struct AddExcludedAppRow: View {
    @ObservedObject var settings: AppSettings
    @State private var frame: CGRect = .zero

    var body: some View {
        AddListRow(title: L("Add App", "App hinzufügen"), frame: $frame, action: showMenu)
    }

    private func showMenu() {
        let menu = NSMenu()
        let own = Bundle.main.bundleIdentifier
        // Nur die zuletzt gestarteten Apps vorschlagen, sonst wird das Menü zu lang;
        // alle anderen über „Andere App wählen“
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> (id: String, name: String, icon: NSImage?)? in
                guard let id = app.bundleIdentifier, id != own, !settings.excludedApps.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .prefix(8)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for app in running {
            let item = ClosureMenuItem(app.name) { add(app.id) }
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(L("Choose Another App", "Andere App wählen")) { choose() })
        MenuPresenter.show(menu, below: frame)
    }

    private func add(_ id: String) {
        guard !settings.excludedApps.contains(id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.excludedApps.append(id)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Apps in which the edge doesn’t open the shelf",
                          "Apps, in denen der Rand die Ablage nicht öffnet")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}
