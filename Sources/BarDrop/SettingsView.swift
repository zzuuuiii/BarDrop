import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: Allgemein

/// „Beim Anmelden öffnen“: Auch eine Anmeldung, die macOS erst noch bestätigt haben will,
/// gilt als eingeschaltet. Sonst stand der Schalter aus, obwohl BarDrop angemeldet war.
enum LoginItem {
    static var isOn: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var loginError: String?
    @ObservedObject private var hotKeyStatus = HotKeyStatus.shared

    var body: some View {
        SettingsPage {
            // Start, Sprache, Impuls und Töne in einer Karte: je eine Zeile, eigene Abschnitte lohnen nicht
            SettingsSection(L("App", "App"), note: loginError, noteColor: .red) {
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $launchAtLogin)
                if launchAtLogin && needsApproval {
                    SettingsRow(L("Allow in System Settings", "In den Systemeinstellungen erlauben")) {
                        Button(L("Open", "Öffnen")) { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
                PickerRow(L("Language", "Sprache"), selection: $settings.language,
                          options: AppLanguage.allCases.map { ($0, $0.title) })
                ToggleRow(L("Trackpad haptics", "Haptik am Trackpad"),
                          isOn: $settings.hapticsEnabled)
                ToggleRow(L("Sounds", "Töne"),
                          info: L("Sounds when removing items, moving them to the Trash or into a folder. Also follows “Play user interface sound effects” in System Settings → Sound.",
                                  "Klänge beim Entfernen, beim Legen in den Papierkorb oder in einen Ordner. Folgt außerdem „Toneffekte der Benutzeroberfläche“ in Systemeinstellungen → Ton."),
                          isOn: $settings.soundsEnabled)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = L("Couldn’t turn this on. Move BarDrop to the Applications folder and try again.",
                                   "Das hat nicht geklappt. Leg BarDrop in den Ordner „Programme“ und versuch es erneut.")
                    Diagnostics.shared.failure("login", "Beim Anmelden öffnen nicht umgestellt", error)
                    launchAtLogin = LoginItem.isOn
                }
                needsApproval = LoginItem.needsApproval
            }

            // Eigener Bereich „Tastatur“ entfernt (Nutzer, 07.11.2026): Der Kurzbefehl steht hier,
            // statt der langen Liste der Kürzel in der Ablage nur der Hinweis auf den Finder
            SettingsSection(L("Show or hide shelf", "Ablage ein- und ausblenden"),
                            info: L("Click ⌃, ⌥, ⇧ or ⌘ to add or remove a modifier key. To change the key, click it on the right and press a new one.",
                                    "Klick auf ⌃, ⌥, ⇧ oder ⌘, um eine Sondertaste hinzuzufügen oder wegzunehmen. Für eine andere Taste klick rechts auf die Taste und drück die neue."),
                            note: hotKeyStatus.available
                                ? L("In the open shelf, the keyboard shortcuts are the same as in the Finder.",
                                    "In der offenen Ablage gelten dieselben Tastenkürzel wie im Finder.")
                                : L("Another app already uses this keyboard shortcut. Choose a different combination.",
                                    "Dieser Tastaturkurzbefehl ist schon von einer anderen App belegt. Wähl eine andere Kombination."),
                            noteColor: hotKeyStatus.available ? .secondary : .red) {
                HotKeyEditor(settings: settings)
                    .padding(8)
            }

            // Ohne Überschrift: Zeile und Knopf sagen schon, worum es geht
            SettingsSection {
                SettingsRow(L("Reset all settings", "Alle Einstellungen zurücksetzen")) {
                    Button(L("Reset", "Zurücksetzen")) { confirmReset() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?", "Alle Einstellungen zurücksetzen?")
        alert.informativeText = L("All settings go back to their defaults, including the language, the keyboard shortcut, the action bar, updates and beta versions. Plugins stay installed but are turned off and lose their permissions. Only the items in the shelf are kept. This can’t be undone.",
                                  "Alle Einstellungen werden auf die Standardwerte zurückgesetzt, auch Sprache, Tastaturkurzbefehl, Aktionsleiste, Updates und Beta-Versionen. Plugins bleiben installiert, sind aber aus und ohne Berechtigungen. Nur die Objekte in der Ablage bleiben. Das lässt sich nicht rückgängig machen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset", "Zurücksetzen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.icon = NSApp.applicationIconImage
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetAll()
        if !launchAtLogin { launchAtLogin = true }   // Standard: angemeldet (über onChange)
    }
}

// MARK: Öffnen

/// Wo am Rand die Ablage erscheint: fest an einer Stelle oder am Zeiger (dann in einem
/// einstellbaren Bereich des Rands)
private enum HeightMode: String, CaseIterable, Identifiable {
    case fixed, adaptive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return L("Fixed", "Fest")
        case .adaptive: return L("At pointer", "Am Zeiger")
        }
    }
}

/// Öffnen: wo die Ablage am Rand sitzt und wann sie aufgeht.
struct OpeningSettings: View {
    @ObservedObject var settings: AppSettings

    private var heightMode: Binding<HeightMode> {
        Binding(
            get: { settings.adaptivePosition ? .adaptive : .fixed },
            set: { mode in settings.adaptivePosition = mode == .adaptive }
        )
    }

    var body: some View {
        SettingsPage {
            ScreenPreview(settings: settings)

            SettingsSection(L("Where", "Wo")) {
                PickerRow(L("Screen edge", "Bildschirmrand"), selection: $settings.edge,
                          options: ScreenEdge.allCases.map { ($0, $0.title) })
                PickerRow(L("Displays", "Bildschirme"), selection: $settings.displayMode,
                          options: DisplayMode.allCases.map { ($0, $0.title) })
            }

            // Wo der Streifen am Rand sitzt. Dicke und Länge sind fest (Nutzer, 07.11.2026)
            SettingsSection(L("Strip at the edge", "Streifen am Rand")) {
                PickerRow(L("Position along the edge", "Position am Rand"), selection: heightMode,
                          options: HeightMode.allCases.map { ($0, $0.title) })
                if settings.adaptivePosition {
                    // Wie viel vom Rand reagiert, mittig: ein kleines Stück bis der ganze Rand
                    SliderRow(L("Area along the edge", "Bereich am Rand"),
                              info: L("In this part of the edge, the shelf opens at the pointer.",
                                      "In diesem Teil des Rands öffnet sich die Ablage am Zeiger."),
                              value: $settings.adaptiveZone,
                              range: AppSettings.adaptiveZoneRange, step: AppSettings.adaptiveZoneStep,
                              format: SliderRow.percent)
                } else {
                    // Unten, Mitte und Oben benannt: „0 %“ sagte nicht, wo das ist
                    SliderRow(L("Vertical position", "Höhe am Rand"), value: $settings.verticalPosition, range: 0...1, step: 0.05,
                              format: { v in
                                  v < 0.01 ? L("Bottom", "Unten") : v > 0.99 ? L("Top", "Oben")
                                      : abs(v - 0.5) < 0.01 ? L("Middle", "Mitte") : SliderRow.percent(v)
                              })
                }
            }

            SettingsSection(L("When", "Wann")) {
                // „Wartezeit“ statt „Ablage öffnen“: danach suchten die Testpersonen (07.11.2026)
                PickerRow(L("Delay", "Wartezeit"),
                          info: L("From a 1 second delay on, clicking the strip still opens the shelf right away.",
                                  "Ab 1 Sekunde Wartezeit öffnet ein Klick auf den Streifen die Ablage trotzdem sofort."),
                          selection: $settings.openChoice,
                          options: OpenChoice.all.map { ($0, $0.title) })
                ToggleRow(L("Reopen where you left off", "Dort öffnen, wo du warst"),
                          info: L("The shelf opens where you were last: at the same place in the list, in the same stack or folder.",
                                  "Die Ablage öffnet sich dort, wo du zuletzt warst: an derselben Stelle in der Liste, im selben Stapel oder Ordner."),
                          isOn: $settings.reopenWhereLeft)
                // Vorher unter „Ausnahmen“, wo „an“ aber hieß: öffnet doch (Nutzer, 07.11.2026)
                ToggleRow(L("Also open in full screen", "Auch im Vollbild öffnen"),
                          isOn: $settings.openInFullScreen)
            }

            // Wie die Aktionsliste: Liste in einer Karte, „Hinzufügen“ als eigene Karte darunter
            VStack(alignment: .leading, spacing: 8) {
                // Ausnahmen: Vollbild und einzelne Apps, in denen der Rand die Ablage nicht öffnet
                SettingsSection(L("Exceptions", "Ausnahmen")) {
                    if settings.excludedApps.isEmpty {
                        Text(L("No apps excluded", "Keine Apps ausgenommen"))
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

    private var widthRange: ClosedRange<Double> { EdgeController.widthRange }

    private var labelMode: Binding<ActionLabelMode> {
        Binding(
            get: {
                guard settings.showActionLabels else { return .none }
                return settings.labelsOnlyFolders ? .folders : .all
            },
            set: { mode in
                settings.showActionLabels = mode != .none
                settings.labelsOnlyFolders = mode == .folders
            }
        )
    }

    /// Nur die Bilder; die Ablage behält ihre Größe (wie die Symbolgröße im Finder)
    private var itemSize: Binding<Double> {
        Binding(get: { ShelfSizes.nearest(settings.tileIconSize, in: ShelfSizes.items) },
                set: { settings.tileIconSize = $0 })
    }

    private var columnChoices: [Int] {
        ShelfGrid.columnChoices(iconSize: settings.tileIconSize, range: widthRange)
    }

    /// Spalten: die Breite der Ablage, in der genau so viele Symbole nebeneinander passen
    private var columns: Binding<Int> {
        Binding(get: { ShelfGrid.columns(shelfWidth: settings.shelfWidth, iconSize: settings.tileIconSize) },
                set: { count in
                    guard let width = ShelfGrid.width(columns: count, iconSize: settings.tileIconSize, range: widthRange) else { return }
                    settings.shelfWidth = width
                })
    }

    /// Spalten mit Bruchteil: Liegt die Breite zwischen zwei Spaltenzahlen (gezogen, ältere
    /// Version), gehen − und + auf die nächste ganze darunter bzw. darüber
    private var exactColumns: Double {
        let icon = settings.tileIconSize
        let count = ShelfGrid.columns(shelfWidth: settings.shelfWidth, iconSize: icon)
        guard let base = ShelfGrid.width(columns: count, iconSize: icon, range: widthRange) else { return Double(count) }
        return Double(count) + (settings.shelfWidth - base) / (icon + 30 + Double(ShelfGrid.spacing))
    }

    private var rowChoices: [Int] { ShelfRows.choices(iconSize: settings.tileIconSize) }

    /// Reihen: die Höhe der Ablage, in die genau so viele Reihen passen
    private var rows: Binding<Int> {
        Binding(get: { max(1, Int(ShelfRows.rows(forHeight: settings.shelfHeight, iconSize: settings.tileIconSize).rounded())) },
                set: { settings.shelfHeight = ShelfRows.height(rows: $0, iconSize: settings.tileIconSize) })
    }

    var body: some View {
        SettingsPage {
            // Nach drei Nutzertests (07.11.2026): Vorschau auf der Seite statt Aufklappen am Rand,
            // „Symbolgröße“ wie im Finder statt „Objektgröße“, Spalten und Reihen zum Einstellen
            // statt nur einer Anzeige, „Größe zurücksetzen“ statt „Standard“. Ziehen an der Ablage
            // geht weiter, die Zahlen laufen mit. Vorschau ohne Karte drumherum (Nutzer, 08.11.2026)
            ShelfSizePreview(settings: settings)

            SettingsSection(L("Size", "Größe"),
                            note: L("You can also drag an edge or corner of the shelf directly.",
                                    "Du kannst die Ablage auch direkt an einer Kante oder Ecke ziehen.")) {
                SliderRow(L("Icon size", "Symbolgröße"),
                          value: stepIndex(itemSize, in: ShelfSizes.items.map(\.0)),
                          range: 0...Double(ShelfSizes.items.count - 1), step: 1,
                          format: { ShelfSizes.items[min(max(Int($0.rounded()), 0), ShelfSizes.items.count - 1)].1 })
                SettingsRow(L("Columns", "Spalten")) {
                    CountStepper(value: columns, exact: exactColumns, choices: columnChoices)
                }
                SettingsRow(L("Rows", "Reihen")) {
                    CountStepper(value: rows, exact: ShelfRows.rows(forHeight: settings.shelfHeight, iconSize: settings.tileIconSize),
                                 choices: rowChoices)
                }
                SettingsRow(L("Reset size", "Größe zurücksetzen")) {
                    Button(L("Reset", "Zurücksetzen")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { settings.resetSize() }
                    }
                    .buttonStyle(KlackButtonStyle())
                    .disabled(settings.sizeIsDefault)
                }
            }

            // Aussehen der Aktionsleiste, vorher unter Aktionen → Darstellung (Nutzer, 08.11.2026)
            SettingsSection(L("Action bar", "Aktionsleiste")) {
                SliderRow(L("Icon size", "Symbolgröße"),
                          value: stepIndex($settings.actionIconSize, in: ShelfSizes.actions.map(\.0)),
                          range: 0...Double(ShelfSizes.actions.count - 1), step: 1,
                          format: { ShelfSizes.actions[min(max(Int($0.rounded()), 0), ShelfSizes.actions.count - 1)].1 })
                PickerRow(L("Show names", "Namen anzeigen"), selection: labelMode,
                          options: ActionLabelMode.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("Style", "Stil")) {
                ToggleRow(L("Light outline", "Heller Rahmen"),
                          isOn: $settings.showOutline)
                // Glas mit in „Stil“: Ohne „Manuell“ und Animation blieben sonst zwei Karten mit je
                // einer Zeile (Nutzer, 07.11.2026)
                // Ein Schalter statt „System / Aus“ (Nutzer, 07.11.2026): an folgt Liquid Glass von macOS
                ToggleRow(L("Glass when pulled off", "Glas beim Abziehen"),
                          info: L("Pulled off the edge, the shelf turns translucent like glass, as set for Liquid Glass in System Settings → Appearance. Off keeps it black.",
                                  "Vom Rand abgezogen wird die Ablage durchscheinend wie Glas, so wie Liquid Glass in Systemeinstellungen → Erscheinungsbild eingestellt ist. Aus lässt sie schwarz."),
                          isOn: $settings.detachedGlass)
            }
        }
    }
}


// MARK: Objekte

/// Dateien aus dem Finder: auf das Original zeigen oder eine eigene Kopie behalten
private enum FinderFiles: String, CaseIterable, Identifiable {
    case original, copy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return L("Original", "Original")
        case .copy: return L("Copy", "Kopie")
        }
    }
}

/// Neue Dateien in „Downloads“ (fasst zwei Schalter zusammen, Nutzer 07.11.2026): Nur AirDrop
/// verschiebt empfangene Dateien in die Ablage, Alle übernimmt jede neue Datei (auch AirDrop)
/// und lässt sie im Ordner
private enum DownloadsMode: String, CaseIterable, Identifiable {
    case off, airDrop, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return L("Off", "Aus")
        case .airDrop: return L("AirDrop only", "Nur AirDrop")
        case .all: return L("All", "Alle")
        }
    }
}

/// Was nach dem Verwenden mit einem Objekt geschieht (fasst zwei Schalter zusammen). Standard: nach dem Herausziehen
/// entfernen, nach Aktionen (AirDrop, Mail, Ordner …) behalten.
private enum AfterUse: String, CaseIterable, Identifiable {
    case keep, afterDragOut, always
    var id: String { rawValue }
    var title: String {
        switch self {
        // Kurz, damit der Wert in einer Zeile bleibt; „entfernen“ steht schon über der Karte
        // (Nutzer, 07.11.2026: „Nach Herausziehen entfernen“ brach um und sah unsauber aus)
        case .keep: return L("Never", "Nie")
        case .afterDragOut: return L("When dragged out", "Beim Herausziehen")
        case .always: return L("Always", "Immer")
        }
    }
}

struct ItemSettings: View {
    @ObservedObject var settings: AppSettings
    /// Nicht beobachtet: Die Seite liest nichts daraus, zeichnete sich sonst aber bei jeder
    /// Änderung der Ablage (Ablegen, Vorschaubilder, Kopien) neu
    let store: ShelfStore
    @ObservedObject private var folderAccess = FolderAccess.shared

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

    private var downloads: Binding<DownloadsMode> {
        Binding(get: { settings.addDownloads ? .all : settings.addAirDrop ? .airDrop : .off },
                set: { mode in
                    settings.addAirDrop = mode == .airDrop
                    settings.addDownloads = mode == .all
                })
    }

    private var finderFiles: Binding<FinderFiles> {
        Binding(get: { settings.copyAllFiles ? .copy : .original },
                set: { settings.copyAllFiles = $0 == .copy })
    }

    private var afterUse: Binding<AfterUse> {
        Binding(
            get: {
                guard settings.removeAfterDragOut else { return .keep }
                return settings.keepAfterAction ? .afterDragOut : .always
            },
            set: { value in
                settings.removeAfterDragOut = value != .keep
                settings.keepAfterAction = value != .always
            }
        )
    }

    /// Erklärung passend zur gewählten Option
    private var afterUseNote: String {
        // Kurz: was mit dem Objekt geschieht, und nur bei Bedarf, wie man es zurückholt
        switch afterUse.wrappedValue {
        case .keep:
            return L("Items stay until you remove them or file them in a folder.", "Objekte bleiben, bis du sie entfernst oder in einen Ordner legst.")
        case .afterDragOut:
            return L("Items dragged out or filed in a folder leave the shelf; after other actions they stay. ⌘Z brings them back.",
                     "Herausgezogene und in Ordner gelegte Objekte verschwinden, nach anderen Aktionen bleiben sie. ⌘Z holt sie zurück.")
        case .always:
            return L("Items leave the shelf after dragging out and after actions. ⌘Z brings them back.",
                     "Objekte verschwinden nach dem Herausziehen und nach Aktionen. ⌘Z holt sie zurück.")
        }
    }

    /// Wahlen für „Stapel bilden“; ein selbst gewählter anderer Wert bleibt in der Liste
    private var stackThresholds: [Int] {
        var values = [2, 3, 5, 10]
        if settings.stackMultiple, !values.contains(settings.stackThreshold) {
            values.append(settings.stackThreshold)
            values.sort()
        }
        return values
    }

    var body: some View {
        SettingsPage {
            SettingsSection(L("Stacks", "Stapel")) {
                PickerRow(L("Group into a stack", "Stapel bilden"),
                          info: L("Items dropped together become a stack. Or drag one item onto another and hold it there for a moment.",
                                  "Zusammen abgelegte Objekte werden zum Stapel. Oder ein Objekt kurz auf ein anderes ziehen."),
                          selection: stackFrom,
                          options: [(0, L("Never", "Nie"))] + stackThresholds.map { ($0, L("\($0) or more items", "Ab \($0) Objekten")) })
            }

            // Alles, was Objekte aus der Ablage nimmt, an einer Stelle: nach dem Verwenden
            // und nach Zeit (vorher zwei Abschnitte mit ähnlichen Namen)
            SettingsSection(L("Removing", "Entfernen")) {
                PickerRow(L("After use", "Nach dem Verwenden"), info: afterUseNote, selection: afterUse,
                          options: AfterUse.allCases.map { ($0, $0.title) })
                PickerRow(L("Remove automatically", "Automatisch entfernen"),
                          info: L("Removes items from the shelf after this time. Files in the Finder stay; what exists only in BarDrop is deleted.",
                                  "Entfernt Objekte nach dieser Zeit aus der Ablage. Dateien im Finder bleiben, was nur in BarDrop liegt, wird gelöscht."),
                          selection: autoRemove,
                          options: AutoRemoveOption.allCases.map { ($0, $0.title) })
            }

            // Original oder Kopie und das Kopieren beim Herausziehen an einer Stelle (Nutzer,
            // 07.11.2026); die automatischen Quellen in einer eigenen Karte darunter
            SettingsSection(L("Files", "Dateien")) {
                PickerRow(L("Files from the Finder", "Dateien aus dem Finder"),
                          info: L("Original: The shelf uses the file where it is, always in its latest version. Copy: The shelf keeps its own copy, which doesn’t change. Images from the web, text and links are always stored in BarDrop.",
                                  "Original: Die Ablage nutzt die Datei an ihrem Ort, immer in der aktuellen Version. Kopie: Die Ablage behält eine eigene Kopie, die sich nicht ändert. Bilder aus dem Web, Texte und Links liegen immer in BarDrop."),
                          selection: finderFiles,
                          options: FinderFiles.allCases.map { ($0, $0.title) })
                ToggleRow(L("Web images as PNG or JPEG", "Bilder aus dem Web als PNG/JPEG"),
                          info: L("WebP, AVIF and HEIC become PNG or JPEG, so any app can open them.",
                                  "WebP, AVIF und HEIC werden zu PNG oder JPEG, damit jede App sie öffnen kann."),
                          isOn: $settings.convertWebImages)
            }

            SettingsSection(L("Add automatically", "Automatisch hinzufügen")) {
                ToggleRow(L("New screenshots", "Neue Bildschirmfotos"),
                          isOn: $settings.addScreenshots)
                PickerRow(L("Downloads", "Downloads"),
                          info: L("AirDrop only: Received files go straight into the shelf instead of Downloads. All: Every new file in Downloads also appears in the shelf and stays in the folder.",
                                  "Nur AirDrop: Empfangene Dateien kommen direkt in die Ablage statt in „Downloads“. Alle: Jede neue Datei in „Downloads“ erscheint auch in der Ablage und bleibt im Ordner."),
                          selection: downloads,
                          options: DownloadsMode.allCases.map { ($0, $0.title) })
                // macOS lässt BarDrop den Ordner nicht lesen: sagen, welcher, und wohin
                ForEach(deniedFolders, id: \.self) { folder in
                    SettingsRow(L("No access to “\(FolderAccess.displayName(folder))”", "Kein Zugriff auf „\(FolderAccess.displayName(folder))“"),
                                info: L("Allow access in System Settings → Privacy & Security → Files & Folders.",
                                        "Erlaub den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner.")) {
                        Button(L("Open", "Öffnen")) { FolderAccess.openPrivacySettings() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
            }
        }
    }
}

extension ItemSettings {
    /// Nur Ordner, die gerade beobachtet werden (Bildschirmfotos bzw. AirDrop an)
    fileprivate var deniedFolders: [URL] {
        var folders: [URL] = []
        if settings.addScreenshots { folders.append(ScreenshotWatcher.screenshotFolder()) }
        if settings.addAirDrop || settings.addDownloads { folders.append(AirDropWatcher.downloadsFolder) }
        return Array(Set(folders.map(\.standardizedFileURL))).filter { folderAccess.isDenied($0) }
            .sorted { $0.path < $1.path }
    }
}

// MARK: Aktionen

/// Namen unter den Aktionen: alle, nur Ordner oder keine
private enum ActionLabelMode: String, CaseIterable, Identifiable {
    case all, folders, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L("All", "Alle")
        case .folders: return L("Folders only", "Nur Ordner")
        case .none: return L("None", "Keine")
        }
    }
}

struct ActionSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: QuickAction.ID?
    @State private var addButtonFrame: CGRect = .zero

    private var limit: Int { QuickAction.limit }


    var body: some View {
        SettingsPage {
            // Vorschau wie unter Öffnen und Aussehen: die Aktionsleiste so, wie sie in der Ablage steht
            ActionBarPreview(settings: settings)

            VStack(alignment: .leading, spacing: 8) {
                // Nur eine Überschriftenebene wie auf den anderen Seiten: „Obere Reihe“ und
                // „Untere Reihe“ stehen selbst als Überschrift über ihrer Karte
                ActionListEditor(settings: settings, selection: $selection,
                                 onRemove: remove, onMove: move)
                    .zIndex(1)   // gezogene Zeile liegt über allem darunter

                AddActionRow(count: settings.quickActions.count, limit: limit, frame: $addButtonFrame) {
                    showAddMenu()
                }
                .padding(.top, 4)
            }
            .zIndex(1)


        }
    }

    /// Menü des Systems wie alle anderen Auswahlen der Einstellungen, aber mit Symbolen und
    /// Gruppen-Überschriften. Ein eigenes breites Auswahlfeld (Popover) wirkte fremd (Nutzer,
    /// 24.10.2026). Schon vorhandene Aktionen sind nur ausgegraut, ohne Haken: Ein Haken sah
    /// aus wie eine Auswahl, die man wieder abwählen kann (Nutzer, 30.10.2026)
    private func showAddMenu() {
        let present = settings.quickActions
        func has(_ kind: QuickAction.Kind, _ path: String? = nil) -> Bool {
            present.contains { $0.kind == kind && (path == nil || $0.path == path) }
        }
        func item(_ action: QuickAction, added: Bool) -> NSMenuItem {
            let entry = ClosureMenuItem(action.title) { add(action) }
            entry.image = MenuIcon.of(action)
            if added { entry.action = nil }
            return entry
        }
        let menu = NSMenu()
        // „Senden“ statt „Teilen“: Eine Gruppe „Teilen“ mit dem Eintrag „Teilen“ wirkte doppelt
        menu.addItem(.sectionHeader(title: L("Send", "Senden")))
        for kind in [QuickAction.Kind.airdrop, .mail, .messages, .share] {
            menu.addItem(item(QuickAction(kind: kind), added: has(kind)))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("Move or open", "Verschieben oder öffnen")))
        menu.addItem(item(QuickAction(kind: .trash), added: has(.trash)))
        menu.addItem(item(QuickAction(kind: .clipboard), added: has(.clipboard)))
        let folder = ClosureMenuItem(L("Folder", "Ordner")) { chooseFolder() }
        folder.image = MenuIcon.file(NSWorkspace.shared.icon(for: .folder))
        menu.addItem(folder)
        let app = ClosureMenuItem("App") { chooseApp() }
        // Symbol einer App, nicht der Ordner „Programme“: gewählt wird eine App
        app.image = MenuIcon.file(NSWorkspace.shared.icon(for: .application))
        menu.addItem(app)
        // Kurzbefehle aus der App Kurzbefehle als Untermenü (können viele sein); beim Öffnen
        // gelesen (etwa 30 ms)
        let shortcuts = NSMenu()
        let names = ShortcutRunner.list()
        if names.isEmpty {
            shortcuts.addItem(NSMenuItem(title: L("No shortcuts found", "Keine Kurzbefehle gefunden"), action: nil, keyEquivalent: ""))
        }
        for name in names {
            shortcuts.addItem(item(QuickAction(kind: .shortcut, path: name), added: has(.shortcut, name)))
        }
        let shortcutItem = NSMenuItem(title: L("Shortcut", "Kurzbefehl"), action: nil, keyEquivalent: "")
        shortcutItem.image = MenuIcon.of(QuickAction(kind: .shortcut, path: names.first))
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)
        // Verbundene Cloud-Dienste: je Dienst eine Aktion
        let clouds = CloudManager.shared.connected
        if !clouds.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Cloud"))
            for service in clouds {
                menu.addItem(item(QuickAction(kind: .cloud, path: service.rawValue), added: has(.cloud, service.rawValue)))
            }
        }
        // Eingeschaltete Plugins, die in der Aktionsleiste laufen können
        let plugins = PluginManager.shared.activePlugins.filter { $0.manifest.allTriggers.contains(.action) }
        if !plugins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: L("Plugins", "Plugins")))
            for plugin in plugins {
                menu.addItem(item(QuickAction(kind: .plugin, path: plugin.id), added: has(.plugin, plugin.id)))
            }
        }
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
        // Erst die Reihe wechseln, wenn die Aktion am Rand ihrer Reihe steht
        if offset < 0 && i == split, split < QuickAction.perRow { split += 1 }
        else if offset > 0 && i == split - 1, order.count - split < QuickAction.perRow { split -= 1 }
        else {
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
            settings.addQuickAction(action)
        }
        selection = action.id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Choose a folder to move items to.", "Wähl einen Ordner, in den Objekte verschoben werden.")
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
        panel.message = L("Choose an app to open items with.", "Wähl eine App, mit der Objekte geöffnet werden.")
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
    private static let labelHeight: CGFloat = 25           // „Obere Reihe“ über der Karte (wie SettingsHeader + 8 pt)
    private static let rowGap: CGFloat = 14                // Abstand zwischen den Karten
    private static let space = "actionList"

    private var committed: Arrangement {
        Arrangement(order: settings.quickActions.map(\.id), split: settings.effectiveActionSplit)
    }

    /// Was gerade gezeigt wird: der Vorschlag beim Ziehen, sonst das Gespeicherte
    private var shown: Arrangement { proposal ?? committed }

    // MARK: Geometrie

    private func counts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        (a.split, a.order.count - a.split)
    }

    /// Gezeigte Zeilen je Karte. Während des Ziehens behält die obere Karte ihre Höhe,
    /// auch wenn die Aktion nach unten wandert: So bleibt die untere Reihe stehen,
    /// statt unter dem Zeiger nach oben zu springen, und man trifft ihre Plätze.
    private func displayCounts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        let c = counts(a)
        guard dragging != nil else { return c }
        return (max(c.top, counts(committed).top), c.bottom)
    }

    private func cardHeight(_ n: Int) -> CGFloat { CGFloat(max(1, n)) * Self.pitch - 1 }

    /// Oberkante der Karte einer Reihe
    private func rowTop(_ row: Int, _ a: Arrangement) -> CGFloat {
        if row == 0 { return Self.labelHeight }
        return Self.labelHeight + cardHeight(displayCounts(a).top) + Self.rowGap + Self.labelHeight
    }

    private func totalHeight(_ a: Arrangement) -> CGFloat {
        let c = displayCounts(a)
        return rowTop(1, a) + cardHeight(c.bottom)
    }

    /// Reihe und Platz einer Aktion
    private func slot(of id: QuickAction.ID, in a: Arrangement) -> (row: Int, index: Int)? {
        guard let i = a.order.firstIndex(of: id) else { return nil }
        if i >= a.split { return (1, i - a.split) }
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
        let actions = Dictionary(settings.quickActions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        ZStack(alignment: .topLeading) {
            // Karten, Überschriften und Trennlinien: stehen fest, nur die Höhe passt sich an
            rowLabel(L("Top row", "Obere Reihe"), y: 0)
            rowLabel(L("Bottom row", "Untere Reihe"), y: rowTop(1, a) - Self.labelHeight)
            let d = displayCounts(a)
            card(count: d.top, top: rowTop(0, a), emptyHint: c.top == 0)
            card(count: d.bottom, top: rowTop(1, a), emptyHint: c.bottom == 0)

            // Zeilen: liegen frei über den Karten
            ForEach(settings.quickActions) { action in
                let isDragged = dragging == action.id
                ActionRow(action: action,
                          selected: selection == action.id,
                          lifted: isDragged,
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
        // Wie SettingsHeader: gleiche Schrift und Einrückung wie die Überschriften anderer Seiten
        Text(text)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .frame(height: Self.labelHeight - 8, alignment: .center)
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
                let minTop = Self.labelHeight
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
                let byID = Dictionary(settings.quickActions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    /// Irgendeine Zeile wird gerade gezogen: dann keine Knöpfe einblenden
    let dragging: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            QuickActionIcon(action: action, size: 26)
            // Nur der Name; was die Aktion tut, steht beim Darüberfahren (weniger kleine Texte)
            Text(action.title)
                .font(.system(size: 13.5))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .help(action.help)
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
            .accessibilityLabel(L("Remove", "Entfernen"))
            .opacity(hovering && !dragging ? 1 : 0)
            .allowsHitTesting(hovering && !dragging)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(lifted ? 1 : 0.6))
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "Zum Verschieben ziehen"))
        }
        .padding(.leading, SettingsTheme.rowPadding)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: lifted ? SettingsTheme.cardRadius : 8, style: .continuous)
                .fill(selected ? Color(nsColor: .controlAccentColor) : (lifted ? SettingsTheme.cardSolid : Color.clear))
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
        AddListRow(title: full ? L("Action bar full (\(count) of \(limit))", "Aktionsleiste voll (\(count) von \(limit))")
                               : L("Add Action", "Aktion hinzufügen"),
                   enabled: !full, frame: $frame, action: action)
    }
}

/// Unter einer Liste: kleiner Knopf „+ ⌄“, der das Menü zum Hinzufügen öffnet (Aktionen,
/// ausgenommene Apps). Vorher eine ganze Karte mit „Aktion hinzufügen“; der Nutzer wollte
/// den schlichten Knopf wie unter Listen von macOS (27.10.2026). Was er tut, steht beim
/// Darüberfahren
struct AddListRow: View {
    let title: String
    var enabled = true
    @Binding var frame: CGRect
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.8)
                }
                .foregroundStyle(enabled ? Color.primary.opacity(0.9) : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SettingsTheme.card)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(hovering && enabled ? 0.06 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hovering = $0 }
            .help(title)
            .accessibilityLabel(title)
            .readFrame($frame)
            Spacer()
        }
        .padding(.leading, 2)
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
            .accessibilityLabel(L("Remove", "Entfernen"))
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

    /// Menü des Systems: die zuletzt gestarteten Apps mit Symbol (sonst wird es zu lang), dazu
    /// jede andere per Auswahl
    private func showMenu() {
        let own = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> (id: String, name: String, icon: NSImage?)? in
                guard let id = app.bundleIdentifier, id != own, !settings.excludedApps.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .prefix(8)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let menu = NSMenu()
        if !running.isEmpty {
            menu.addItem(.sectionHeader(title: L("Open apps", "Geöffnete Apps")))
            for app in running {
                let item = ClosureMenuItem(app.name) { add(app.id) }
                if let icon = app.icon { item.image = MenuIcon.file(icon) }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let other = ClosureMenuItem(L("Choose Another App", "Andere App wählen")) { choose() }
        other.image = MenuIcon.file(NSWorkspace.shared.icon(forFile: "/Applications"))
        menu.addItem(other)
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
        panel.message = L("Choose apps in which the shelf doesn’t open at the edge.",
                          "Wähl Apps, in denen sich die Ablage am Rand nicht öffnet.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}

// MARK: Symbole in Menüs

/// Symbole für Menüeinträge, so groß wie App-Symbole in macOS-Menüs (16 pt)
enum MenuIcon {
    static let size: CGFloat = 16

    /// Datei- oder App-Symbol verkleinert (Kopie, das Original bleibt für andere Stellen)
    static func file(_ icon: NSImage) -> NSImage {
        let copy = (icon.copy() as? NSImage) ?? icon
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    /// Dasselbe Symbol wie in der Aktionsleiste; Plugins farbig wie überall in den Einstellungen
    @MainActor
    static func of(_ action: QuickAction) -> NSImage? {
        let renderer = ImageRenderer(content: QuickActionIcon(action: action, size: size).environment(\.colorfulIcons, true))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? action.icon.map(file)
    }
}

/// Regler über feste Stufen: Der Regler zählt die Stufe (0, 1, 2 …), gespeichert wird ihr Wert.
/// Liegt der gespeicherte Wert zwischen zwei Stufen (ältere Version, Ziehen an der Ecke), steht
/// der Regler auf der nächsten
func stepIndex(_ binding: Binding<Double>, in steps: [Double]) -> Binding<Double> {
    Binding(get: {
        let value = binding.wrappedValue
        return Double(steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0)
    }, set: { index in
        guard !steps.isEmpty else { return }
        let value = steps[min(max(Int(index.rounded()), 0), steps.count - 1)]
        if value != binding.wrappedValue { binding.wrappedValue = value }
    })
}

/// Stufen-Regler für ganze Zahlen (Spalten)
func stepIndex(_ binding: Binding<Int>, in steps: [Double]) -> Binding<Double> {
    stepIndex(Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0) }), in: steps)
}


/// Zahl mit − und + daneben (Spalten, Reihen). Die Knöpfe wie der Pfeil der Menüs.
struct CountStepper: View {
    @Binding var value: Int
    /// Genauer Wert mit Bruchteil (z. B. 2,5 Reihen): − und + gehen auf die nächste ganze Zahl
    /// darunter bzw. darüber. Vorher war bei 2,5 Reihen „−“ aus, weil 2 angezeigt wurde
    var exact: Double? = nil
    /// Mögliche Zahlen; − und + springen zur nächsten davon
    let choices: [Int]

    private var current: Double { exact ?? Double(value) }
    private var lower: Int? { choices.filter { Double($0) < current - 0.01 }.max() }
    private var higher: Int? { choices.filter { Double($0) > current + 0.01 }.min() }

    var body: some View {
        HStack(spacing: 10) {
            button("minus", target: lower)
            Text("\(value)")
                .font(.system(size: 13.5, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 18)
                .contentTransition(.numericText())
            button("plus", target: higher)
        }
    }

    private func button(_ symbol: String, target: Int?) -> some View {
        Button {
            guard let target else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { value = target }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(SettingsTheme.separator, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1)
    }
}
