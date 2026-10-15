import AppKit
import Carbon
import SwiftUI
import Combine

/// Bildschirmrand, an dem die Ablage sitzt.
enum ScreenEdge: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? L("Left", "Links") : L("Right", "Rechts") }
}

/// Wählbare Zeiträume für das automatische Entfernen (in Stunden).
enum AutoRemoveOption: Double, CaseIterable, Identifiable {
    case never = 0
    case h1 = 3_600
    case h2 = 7_200
    case h5 = 18_000
    case h10 = 36_000
    case h24 = 86_400

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .never: return L("Never", "Nie")
        case .h1: return L("After 1 hour", "Nach 1 Stunde")
        default: return L("After \(Int(rawValue / 3_600)) hours", "Nach \(Int(rawValue / 3_600)) Stunden")
        }
    }
}

/// Stärke der Animationen beim Auf- und Zuklappen.
enum AnimationStyle: String, CaseIterable, Identifiable {
    case subtle, standard, lively
    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtle: return L("Subtle", "Dezent")
        case .standard: return L("Standard", "Standard")
        case .lively: return L("Lively", "Lebhaft")
        }
    }

    /// Bedienungshilfen „Bewegung reduzieren“ (nach perch): dann ohne Federn,
    /// Unschärfe und Skalierung, nur kurzes Überblenden.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Der Streifen wölbt sich elastisch aus dem Rand, mit einem kleinen Nachgeben
    /// (wie die Lautstärkeanzeige am iPhone), und sinkt ohne Nachschwingen zurück.
    var peekIn: Animation {
        if Self.reduceMotion { return .easeOut(duration: 0.15) }
        switch self {
        case .subtle: return .spring(response: 0.34, dampingFraction: 0.85)
        case .standard: return .spring(response: 0.38, dampingFraction: 0.72)
        case .lively: return .spring(response: 0.42, dampingFraction: 0.6)
        }
    }

    var peekOut: Animation {
        if Self.reduceMotion { return .easeIn(duration: 0.12) }
        return .spring(response: 0.28, dampingFraction: 1)
    }

    /// Feder beim Öffnen: je lebhafter, desto mehr Nachschwingen.
    var open: Animation {
        if Self.reduceMotion { return .easeOut(duration: 0.18) }
        switch self {
        case .subtle: return .spring(response: 0.34, dampingFraction: 0.95)
        case .standard: return .spring(response: 0.4, dampingFraction: 0.7)
        case .lively: return .spring(response: 0.46, dampingFraction: 0.55)
        }
    }

    var close: Animation {
        if Self.reduceMotion { return .easeIn(duration: 0.14) }
        switch self {
        case .subtle: return .spring(response: 0.26, dampingFraction: 1)
        case .standard: return .spring(response: 0.32, dampingFraction: 0.9)
        case .lively: return .spring(response: 0.36, dampingFraction: 0.82)
        }
    }

    /// Unschärfe beim Einblenden des Inhalts.
    var blur: CGFloat {
        if Self.reduceMotion { return 0 }
        switch self {
        case .subtle: return 6
        case .standard: return 14
        case .lively: return 18
        }
    }
}

/// Wie sich die Ablage öffnet, wenn man mit dem Zeiger an den Rand fährt.
enum OpenMode: String, CaseIterable, Identifiable {
    case automatic, click
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L("Automatically", "Automatisch")
        case .click: return L("On click", "Per Klick")
        }
    }
}

/// Verzögerung, bis die Ablage nach dem ersten Streifen ganz aufgeht.
enum OpenDelay {
    static let instant = 0.3
    static let choices: [Double] = [instant, 1, 2, 3, 4, 5]

    static func title(_ value: Double) -> String {
        if value <= instant { return L("None", "Keine") }
        let s = Int(value.rounded())
        return s == 1 ? L("1 second", "1 Sekunde") : L("\(s) seconds", "\(s) Sekunden")
    }
}

/// Wann die Ablage beim Ziehen von Objekten erscheint.
enum DragReveal: String, CaseIterable, Identifiable {
    case immediately, nearEdge, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: return L("Show strip right away", "Streifen sofort zeigen")
        case .nearEdge: return L("Only near the edge", "Erst in Randnähe")
        case .off: return L("Never", "Nie")
        }
    }
}

/// Reihenfolge der Objekte in der Ablage.
enum SortOrder: String, CaseIterable, Identifiable {
    case newestFirst, oldestFirst
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return L("Newest first", "Neueste zuerst")
        case .oldestFirst: return L("Oldest first", "Älteste zuerst")
        }
    }
}

/// Auf welchen Bildschirmen BarDrop verfügbar ist.
enum DisplayMode: String, CaseIterable, Identifiable {
    case all, builtIn, external
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("All displays", "Alle Bildschirme")
        case .builtIn: return L("Built-in display only", "Nur integrierter Bildschirm")
        case .external: return L("External displays only", "Nur externe Bildschirme")
        }
    }

    func allows(_ screen: NSScreen) -> Bool {
        switch self {
        case .all: return true
        case .builtIn: return screen.isBuiltIn
        case .external: return !screen.isBuiltIn
        }
    }
}

extension NSScreen {
    /// Feste Kennung des Bildschirms (bleibt gleich, auch wenn macOS das Objekt neu anlegt)
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}

/// Form des ersten Streifens: flach, lang und dicht am Rand.
enum PeekDefaults {
    static let thickness = 8.0
    static let length = 64.0
    static let roundness = 0.4
}

/// Standardwerte für Lage und Größe der Ablage.
enum ShelfDefaults {
    static let edge = ScreenEdge.right
    static let verticalPosition = 0.5
    static let adaptivePosition = true
    static let adaptiveMiddleThird = true
    static let adaptiveZoneHalf = true
    static let displayMode = DisplayMode.all
    static let width = 240.0
    static let height = 430.0
}

/// Persistente Einstellungen der App (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let edge = "edge"
        static let verticalPosition = "verticalPosition"
        static let adaptivePosition = "adaptivePosition"
        static let adaptiveMiddleThird = "adaptiveMiddleThird"
        static let displayMode = "displayMode"
        static let shelfWidth = "shelfWidth"
        static let shelfHeight = "shelfHeight"
        static let showOnDrag = "showOnDrag"
        static let dragReveal = "dragReveal"
        static let peekThickness = "peekThickness"
        static let peekLength = "peekLength"
        static let peekRoundness = "peekRoundness"
        static let removeAfterDragOut = "removeAfterDragOut"
        static let stackMultiple = "stackMultiple"
        static let stackThreshold = "stackThreshold"
        static let adaptiveZoneHalf = "adaptiveZoneHalf"
        static let keepAfterAction = "keepAfterAction"
        static let animationStyle = "animationStyle"
        static let openMode = "openMode"
        static let autoRemoveAfter = "autoRemoveAfter"
        static let convertWebImages = "convertWebImages"
        static let copyAllFiles = "copyAllFiles"
        static let dragOutCopyOnly = "dragOutCopyOnly"
        static let hapticsEnabled = "hapticsEnabled"
        static let quickActions = "quickActions"
        static let sortOrder = "sortOrder"
        static let showOutline = "showOutline"
        static let openDelay = "openDelay"
        static let clickToOpenEarly = "clickToOpenEarly"
        static let language = "language"
        static let generousHitArea = "generousHitArea"
        static let twoActionRows = "twoActionRows"
        static let actionRowSplit = "actionRowSplit"
        static let autoUpdateCheck = "autoUpdateCheck"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let didLaunchBefore = "didLaunchBefore"
    }

    // Lage und Größe
    @Published var edge: ScreenEdge { didSet { defaults.set(edge.rawValue, forKey: Key.edge) } }
    /// 0 = unten, 1 = oben
    @Published var verticalPosition: Double { didSet { defaults.set(verticalPosition, forKey: Key.verticalPosition) } }
    /// Ablage erscheint dort, wo der Zeiger den Rand erreicht, statt an fester Höhe.
    @Published var adaptivePosition: Bool { didSet { defaults.set(adaptivePosition, forKey: Key.adaptivePosition) } }
    /// Adaptive Höhe nur im mittleren Drittel des Bildschirmrands.
    @Published var adaptiveMiddleThird: Bool { didSet { defaults.set(adaptiveMiddleThird, forKey: Key.adaptiveMiddleThird) } }
    /// Eingeschränkter Bereich: mittlere Hälfte statt mittleres Drittel.
    @Published var adaptiveZoneHalf: Bool { didSet { defaults.set(adaptiveZoneHalf, forKey: Key.adaptiveZoneHalf) } }

    /// Anteil der Randhöhe, in dem die adaptive Ablage reagiert (mittig); nil = ganzer Rand.
    var adaptiveZoneFraction: CGFloat? {
        guard adaptivePosition, adaptiveMiddleThird else { return nil }
        return adaptiveZoneHalf ? 0.5 : 1.0 / 3.0
    }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) } }
    @Published var shelfWidth: Double { didSet { defaults.set(shelfWidth, forKey: Key.shelfWidth) } }
    @Published var shelfHeight: Double { didSet { defaults.set(shelfHeight, forKey: Key.shelfHeight) } }

    // Verhalten
    /// Beim Ziehen: sofort einen Streifen zeigen, erst in Randnähe oder gar nicht.
    @Published var dragReveal: DragReveal { didSet { defaults.set(dragReveal.rawValue, forKey: Key.dragReveal) } }
    /// Form des ersten Streifens am Rand
    @Published var peekThickness: Double { didSet { defaults.set(peekThickness, forKey: Key.peekThickness) } }
    @Published var peekLength: Double { didSet { defaults.set(peekLength, forKey: Key.peekLength) } }
    /// 0 = eckig, 1 = ganz rund
    @Published var peekRoundness: Double { didSet { defaults.set(peekRoundness, forKey: Key.peekRoundness) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) } }
    /// Automatisch ganz öffnen oder erst nach einem Klick auf die mittlere Stufe.
    @Published var openMode: OpenMode { didSet { defaults.set(openMode.rawValue, forKey: Key.openMode) } }

    // Objekte
    @Published var removeAfterDragOut: Bool { didSet { defaults.set(removeAfterDragOut, forKey: Key.removeAfterDragOut) } }
    /// Mehrere gleichzeitig abgelegte Objekte zu einem Stapel zusammenfassen.
    @Published var stackMultiple: Bool { didSet { defaults.set(stackMultiple, forKey: Key.stackMultiple) } }
    /// Ab so vielen gleichzeitig abgelegten Objekten entsteht ein Stapel.
    @Published var stackThreshold: Int { didSet { defaults.set(stackThreshold, forKey: Key.stackThreshold) } }
    /// Objekte nach einer Schnellaktion (AirDrop, Mail, Ordner …) in der Ablage behalten.
    @Published var keepAfterAction: Bool { didSet { defaults.set(keepAfterAction, forKey: Key.keepAfterAction) } }
    /// Objekte nach dieser Zeit (Sekunden) automatisch entfernen; 0 = nie.
    @Published var autoRemoveAfter: Double { didSet { defaults.set(autoRemoveAfter, forKey: Key.autoRemoveAfter) } }
    /// Auch eigene Dateien als Kopie ablegen, unabhängig vom Original.
    @Published var copyAllFiles: Bool { didSet { defaults.set(copyAllFiles, forKey: Key.copyAllFiles) } }
    /// Bilder aus dem Web (WebP, AVIF, HEIC …) in PNG/JPEG umwandeln.
    @Published var convertWebImages: Bool { didSet { defaults.set(convertWebImages, forKey: Key.convertWebImages) } }
    /// Beim Herausziehen nur Kopieren anbieten (sonst dürfen Ziele wie der Finder auch verschieben).
    @Published var dragOutCopyOnly: Bool { didSet { defaults.set(dragOutCopyOnly, forKey: Key.dragOutCopyOnly) } }
    /// Globaler Kurzbefehl (virtueller Tastencode und Carbon-Sondertasten).
    @Published var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: Key.hotKeyCode) } }
    @Published var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: Key.hotKeyModifiers) } }
    @Published var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: Key.hotKeyLabel) } }

    static let defaultHotKey = (code: kVK_ANSI_B, modifiers: controlKey | optionKey, label: "B")

    var hotKeyIsDefault: Bool {
        hotKeyCode == Self.defaultHotKey.code && hotKeyModifiers == Self.defaultHotKey.modifiers
    }

    func resetHotKey() {
        hotKeyCode = Self.defaultHotKey.code
        hotKeyModifiers = Self.defaultHotKey.modifiers
        hotKeyLabel = Self.defaultHotKey.label
    }

    /// Kurzbefehl als Text, z. B. „⌃⌥B“.
    var hotKeyDescription: String {
        var s = ""
        if hotKeyModifiers & controlKey != 0 { s += "⌃" }
        if hotKeyModifiers & optionKey != 0 { s += "⌥" }
        if hotKeyModifiers & shiftKey != 0 { s += "⇧" }
        if hotKeyModifiers & cmdKey != 0 { s += "⌘" }
        return s + hotKeyLabel
    }

    /// Regelmäßig auf GitHub nach neuen Versionen suchen.
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: Key.autoUpdateCheck) } }
    /// Version, die der Nutzer beim automatischen Hinweis übersprungen hat.
    var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Key.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }
    /// Feiner heller Rahmen um die schwarze Form (sichtbar auf dunklem Hintergrund).
    @Published var showOutline: Bool { didSet { defaults.set(showOutline, forKey: Key.showOutline) } }
    /// So lange (Sekunden) muss der Zeiger am Streifen bleiben, bis die Ablage aufgeht.
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: Key.openDelay) } }
    /// Bei langer Verzögerung (ab 1 Sekunde) öffnet ein Klick auf den Streifen die Ablage sofort.
    @Published var clickToOpenEarly: Bool { didSet { defaults.set(clickToOpenEarly, forKey: Key.clickToOpenEarly) } }

    /// Sprache der Oberfläche
    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    /// Etwas größerer Bereich um Streifen und Griff, in dem der Zeiger noch zählt
    @Published var generousHitArea: Bool { didSet { defaults.set(generousHitArea, forKey: Key.generousHitArea) } }
    /// Aktionsleiste in zwei Reihen mit je bis zu fünf Aktionen
    @Published var twoActionRows: Bool { didSet { defaults.set(twoActionRows, forKey: Key.twoActionRows) } }
    /// Zwei Reihen: so viele Aktionen (vorne in `quickActions`) stehen in der oberen Reihe
    @Published var actionRowSplit: Int { didSet { defaults.set(actionRowSplit, forKey: Key.actionRowSplit) } }

    /// Grenze zwischen oberer und unterer Reihe, so begrenzt, dass keine Reihe mehr als
    /// fünf Aktionen hat.
    var effectiveActionSplit: Int {
        Self.clampSplit(actionRowSplit, count: quickActions.count)
    }

    static func clampSplit(_ split: Int, count: Int) -> Int {
        let per = QuickAction.perRow
        return min(max(split, max(0, count - per)), min(per, count))
    }

    /// Ab dieser Verzögerung lässt sich das Öffnen per Klick abkürzen.
    static let clickToOpenMinDelay = 1.0

    /// Nimmt der Streifen bzw. Griff gerade einen Klick zum Öffnen an?
    var hintAcceptsClick: Bool {
        openMode == .click
            || (clickToOpenEarly && openDelay >= Self.clickToOpenMinDelay - 0.01)
    }
    /// Reihenfolge der Objekte in der Ablage.
    @Published var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) } }

    /// Aktionen in der Leiste unten, in der gewünschten Reihenfolge.
    @Published var quickActions: [QuickAction] {
        didSet {
            if let data = try? JSONEncoder().encode(quickActions) {
                defaults.set(data, forKey: Key.quickActions)
            }
        }
    }

    var didLaunchBefore: Bool {
        get { defaults.bool(forKey: Key.didLaunchBefore) }
        set { defaults.set(newValue, forKey: Key.didLaunchBefore) }
    }

    private init() {
        defaults.register(defaults: [
            Key.edge: ShelfDefaults.edge.rawValue,
            Key.verticalPosition: ShelfDefaults.verticalPosition,
            Key.adaptivePosition: ShelfDefaults.adaptivePosition,
            Key.adaptiveMiddleThird: ShelfDefaults.adaptiveMiddleThird,
            Key.adaptiveZoneHalf: ShelfDefaults.adaptiveZoneHalf,
            Key.displayMode: ShelfDefaults.displayMode.rawValue,
            Key.shelfWidth: ShelfDefaults.width,
            Key.shelfHeight: ShelfDefaults.height,
            Key.showOnDrag: true,
            Key.peekThickness: PeekDefaults.thickness,
            Key.peekLength: PeekDefaults.length,
            Key.peekRoundness: PeekDefaults.roundness,
            Key.hapticsEnabled: true,
            Key.removeAfterDragOut: true,
            Key.stackMultiple: true,
            Key.stackThreshold: 2,
            Key.keepAfterAction: false,
            Key.animationStyle: AnimationStyle.standard.rawValue,
            Key.openMode: OpenMode.automatic.rawValue,
            Key.autoRemoveAfter: AutoRemoveOption.h2.rawValue,
            Key.convertWebImages: true,
            Key.copyAllFiles: false,
            Key.dragOutCopyOnly: false,
            Key.sortOrder: SortOrder.newestFirst.rawValue,
            Key.showOutline: true,
            Key.openDelay: OpenDelay.instant,
            Key.clickToOpenEarly: true,
            Key.language: AppLanguage.english.rawValue,
            Key.generousHitArea: false,
            Key.twoActionRows: false,
            Key.actionRowSplit: QuickAction.perRow,
            Key.autoUpdateCheck: true,
            Key.hotKeyCode: Self.defaultHotKey.code,
            Key.hotKeyModifiers: Self.defaultHotKey.modifiers,
            Key.hotKeyLabel: Self.defaultHotKey.label
        ])
        edge = ScreenEdge(rawValue: defaults.string(forKey: Key.edge) ?? "") ?? ShelfDefaults.edge
        verticalPosition = defaults.double(forKey: Key.verticalPosition)
        adaptivePosition = defaults.bool(forKey: Key.adaptivePosition)
        adaptiveMiddleThird = defaults.bool(forKey: Key.adaptiveMiddleThird)
        adaptiveZoneHalf = defaults.bool(forKey: Key.adaptiveZoneHalf)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? ShelfDefaults.displayMode
        shelfWidth = defaults.double(forKey: Key.shelfWidth)
        shelfHeight = defaults.double(forKey: Key.shelfHeight)
        // Ältere Versionen hatten nur „Beim Ziehen einblenden“ an/aus
        dragReveal = DragReveal(rawValue: defaults.string(forKey: Key.dragReveal) ?? "")
            ?? (defaults.bool(forKey: Key.showOnDrag) ? .immediately : .off)
        // Ab 1.8 ist der Streifen flacher: alte Standardwerte (16 / 84 / 0,62) einmalig übernehmen,
        // selbst gewählte Werte bleiben
        if defaults.object(forKey: Key.peekThickness) as? Double == 16,
           defaults.object(forKey: Key.peekLength) as? Double ?? 84 == 84 {
            defaults.removeObject(forKey: Key.peekThickness)
            defaults.removeObject(forKey: Key.peekLength)
            defaults.removeObject(forKey: Key.peekRoundness)
        }
        // 1.9: „Übergang“ ersetzt „Enden“ mit anderer Bedeutung; einmalig auf Standard
        if !defaults.bool(forKey: "peekShapeV19") {
            defaults.removeObject(forKey: Key.peekRoundness)
            defaults.set(true, forKey: "peekShapeV19")
        }
        peekThickness = defaults.double(forKey: Key.peekThickness)
        peekLength = defaults.double(forKey: Key.peekLength)
        peekRoundness = defaults.double(forKey: Key.peekRoundness)
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        removeAfterDragOut = defaults.bool(forKey: Key.removeAfterDragOut)
        stackMultiple = defaults.bool(forKey: Key.stackMultiple)
        stackThreshold = min(max(defaults.integer(forKey: Key.stackThreshold), 2), 10)
        keepAfterAction = defaults.bool(forKey: Key.keepAfterAction)
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: Key.animationStyle) ?? "") ?? .standard
        openMode = OpenMode(rawValue: defaults.string(forKey: Key.openMode) ?? "") ?? .automatic
        convertWebImages = defaults.bool(forKey: Key.convertWebImages)
        copyAllFiles = defaults.bool(forKey: Key.copyAllFiles)
        dragOutCopyOnly = defaults.bool(forKey: Key.dragOutCopyOnly)
        showOutline = defaults.bool(forKey: Key.showOutline)
        openDelay = max(0.1, defaults.double(forKey: Key.openDelay))
        clickToOpenEarly = defaults.bool(forKey: Key.clickToOpenEarly)
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        generousHitArea = defaults.bool(forKey: Key.generousHitArea)
        twoActionRows = defaults.bool(forKey: Key.twoActionRows)
        actionRowSplit = defaults.integer(forKey: Key.actionRowSplit)
        autoUpdateCheck = defaults.bool(forKey: Key.autoUpdateCheck)
        hotKeyCode = defaults.integer(forKey: Key.hotKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        hotKeyLabel = defaults.string(forKey: Key.hotKeyLabel) ?? Self.defaultHotKey.label
        sortOrder = SortOrder(rawValue: defaults.string(forKey: Key.sortOrder) ?? "") ?? .newestFirst

        // Werte aus älteren Versionen (Woche, 30 Tage) gibt es nicht mehr
        let stored = defaults.double(forKey: Key.autoRemoveAfter)
        autoRemoveAfter = AutoRemoveOption(rawValue: stored)?.rawValue ?? AutoRemoveOption.never.rawValue

        // Nicht mehr einstellbar: Der Rand öffnet die Ablage immer, ein Symbol in der
        // Menüleiste gibt es nicht mehr. Alte Werte aufräumen.
        defaults.removeObject(forKey: "revealOnHover")
        defaults.removeObject(forKey: "showMenuBarIcon")

        if let data = defaults.data(forKey: Key.quickActions),
           let decoded = try? JSONDecoder().decode([QuickAction].self, from: data) {
            quickActions = decoded
        } else {
            quickActions = QuickAction.defaults
        }
    }

    /// Alles im Tab „Ablage“ auf den Standard setzen.
    func resetShelfLayout() {
        edge = ShelfDefaults.edge
        verticalPosition = ShelfDefaults.verticalPosition
        adaptivePosition = ShelfDefaults.adaptivePosition
        adaptiveMiddleThird = ShelfDefaults.adaptiveMiddleThird
        adaptiveZoneHalf = ShelfDefaults.adaptiveZoneHalf
        displayMode = ShelfDefaults.displayMode
        shelfWidth = ShelfDefaults.width
        shelfHeight = ShelfDefaults.height
        peekThickness = PeekDefaults.thickness
        peekLength = PeekDefaults.length
        peekRoundness = PeekDefaults.roundness
    }

    /// Alle Einstellungen auf den Auslieferungszustand. Inhalt der Ablage,
    /// Einführung und interne Umstellungen bleiben unberührt.
    func resetAll() {
        resetShelfLayout()
        dragReveal = .immediately
        hapticsEnabled = true
        animationStyle = .standard
        openMode = .automatic
        openDelay = OpenDelay.instant
        clickToOpenEarly = true
        generousHitArea = false
        twoActionRows = false
        actionRowSplit = QuickAction.perRow
        showOutline = true
        removeAfterDragOut = true
        stackMultiple = true
        stackThreshold = 2
        keepAfterAction = false
        autoRemoveAfter = AutoRemoveOption.h2.rawValue
        convertWebImages = true
        copyAllFiles = false
        dragOutCopyOnly = false
        sortOrder = .newestFirst
        quickActions = QuickAction.defaults
        autoUpdateCheck = true
        skippedUpdateVersion = nil
        resetHotKey()
    }

    /// Form des ersten Streifens
    var peekSignature: String { "\(peekThickness)|\(peekLength)|\(peekRoundness)" }

    /// Größe der offenen Ablage
    var sizeSignature: String { "\(shelfWidth)|\(shelfHeight)" }

    /// Alles, was Lage oder Größe der Ablage beeinflusst.
    var layoutSignature: String {
        "\(edge.rawValue)|\(verticalPosition)|\(adaptivePosition)|\(adaptiveMiddleThird)|\(adaptiveZoneHalf)|\(displayMode.rawValue)|\(shelfWidth)|\(shelfHeight)"
    }
}
