import AppKit
import SwiftUI

/// Sichtbarer Zustand der Ablage am Bildschirmrand.
final class ShelfUIModel: ObservableObject {
    enum Level: Int, Comparable {
        case hidden, peek, hint, expanded
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    @Published var level: Level = .hidden
    @Published var isDropTargeted = false
    @Published var selection: Set<UUID> = []
    /// Geöffneter Stapel (eigene Ansicht mit Zurück-Knopf), sonst nil.
    @Published var openStack: UUID?
    /// Das Ablagefenster hat den Tastaturfokus (Auswahl in Akzentfarbe statt Grau).
    @Published var isKey = false
    /// Vertikaler Versatz der kleinen Stufen gegenüber der Fenstermitte (adaptive Höhe).
    @Published var anchorOffset: CGFloat = 0
    /// Ausgangspunkt für ⇧-Klick-Bereichsauswahl
    var selectionAnchor: UUID?
    /// Auswahl der Dateien im geöffneten Stapel (IDs der Dateien)
    @Published var memberSelection: Set<UUID> = []
    var memberAnchor: UUID?
    /// Ausgewählte Platzhalter laufender Plugins (IDs der Aufträge); ⌫ bricht sie ab
    @Published var jobSelection: Set<UUID> = []

    /// Bitte an die Ablage, eine Kachel ganz sichtbar zu machen (Pfeiltasten). Die laufende
    /// Nummer macht jede Bitte neu, auch für dieselbe Kachel.
    struct ScrollRequest: Equatable {
        let id: UUID
        let serial: Int
    }
    @Published private(set) var scrollRequest: ScrollRequest?

    func requestScroll(to id: UUID) {
        scrollRequest = ScrollRequest(id: id, serial: (scrollRequest?.serial ?? 0) + 1)
    }

    /// Scrollstand beim letzten Schließen („An letzter Stelle öffnen“): oberste sichtbare
    /// Kachel und ihr Abstand zur Oberkante des sichtbaren Bereichs
    var savedScroll: (id: UUID, top: CGFloat, height: CGFloat)?

    /// Ein Kontextmenü oder eine Rückfrage der Ablage ist geöffnet (siehe keepOpen).
    var menuOpen = false

    /// Hält die Ablage offen, solange `body` läuft (Menü, Rückfrage). Stellt danach den
    /// vorigen Stand her: Eine Rückfrage aus einem offenen Menü gab die Ablage sonst frei,
    /// obwohl das Menü noch offen war. Ohne Ablage (`ui` nil) läuft nur `body`
    @discardableResult
    static func keepOpen<T>(_ ui: ShelfUIModel?, _ body: () -> T) -> T {
        let before = ui?.menuOpen ?? false
        ui?.menuOpen = true
        defer { ui?.menuOpen = before }
        return body()
    }
    /// Ein Teilen-Fenster (Picker) ist geöffnet.
    var sharingOpen = false
    /// Gerade wird ein Objekt aus der Ablage herausgezogen.
    var ownDragActive = false
    /// Ein Auswahlrahmen (Lasso) wird gerade gezogen: Die Ablage bleibt offen, auch wenn
    /// der Zeiger sie dabei verlässt.
    var bandActive = false
    /// Einträge, die gerade aus der Ablage gezogen werden (für Ablegen auf Stapel).
    var draggedEntryIDs: Set<UUID> = []
    /// Gespeicherte Orte der Dateien, die gerade aus der Ablage gezogen werden.
    /// Für Aktionen in der Leiste: Das Drag-Pasteboard enthält nur frische Kopien.
    var draggedFileURLs: [URL] = []
    /// Der letzte eigene Drag endete innerhalb der Ablage (Aktion oder Stapel).
    var lastDropWasInternal = false
    /// Klick auf die mittlere Stufe: Ablage ganz öffnen (Modus „Per Klick“).
    var expandRequested = false
    /// Einführung offen: heller Rahmen immer zeigen, damit die Ablage auf dem abgedunkelten
    /// Bildschirm gut zu sehen ist (unabhängig von Aussehen → Heller Rahmen)
    @Published var forcesOutline = false
    /// Beim Verstellen der Symbolgröße: Beispieldatei in der Ablage zeigen
    @Published var showSampleTile = false
    /// Nur für die Produktbilder: diese Aktion so zeigen, als läge eine Datei darüber
    @Published var previewTargetedAction: UUID?
    /// Lage der offenen Ablage (schwarze Form) auf dem Bildschirm, ohne Schattenrand
    var expandedBody: CGRect = .zero

    /// Die Ablage wird an der Kopfzeile vom Rand gezogen (siehe EdgeTear): Form wie zwei
    /// Tropfen, die sich trennen. nil: Sie sitzt wie immer am Rand.
    struct Tear: Equatable {
        /// Abstand zwischen Ablage und Bildschirmrand auf der Seite `side`
        var gap: CGFloat = 0
        /// Verbindung zum Rand: 1 ganz angedockt, 0 gelöst
        var attach: CGFloat = 1
        /// Rand, mit dem die Ablage gerade verbunden ist oder dem sie sich nähert
        var side: ScreenEdge
        /// Überblendung zur angedockten Form (0 verschmelzende Form, 1 genau die Ablage am
        /// Rand): am Ende des Andockens und am Anfang des Dehnens, damit die Form nicht springt
        var dock: CGFloat = 0
    }
    /// Form und Glas beim Ziehen ändern sich in jedem Bild. Sie liegen in einem eigenen Modell,
    /// das nur die Randform und ihre Nachbarn beobachten: Als Teil dieses Modells werteten sie
    /// bei jedem Bild die ganze Ablage samt Kacheln und Aktionsleiste neu aus (gemessen gut
    /// 11 ms je Bild bei 40 Objekten, mehr als ein Bild bei 120 Hz dauert)
    let tearState = TearState()
    var tear: Tear? {
        get { tearState.tear }
        set {
            tearState.tear = newValue
            if isTorn != (newValue != nil) { isTorn = newValue != nil }
        }
    }
    /// Die Ablage ist vom Rand gezogen (`tear` gesetzt): ändert sich nur beim Lösen und Andocken
    @Published private(set) var isTorn = false
    /// Der Zeiger ist in der Kopfzeile: Der Griff oben erscheint
    @Published var grabberHover = false
    /// Die Ablage wird gerade am Griff gezogen: Er ist hell und etwas länger
    @Published var grabbing = false
    /// Rahmen der Ablage am Rand: nach dem Andocken kurz ausgeblendet, dann weich eingeblendet
    @Published var dockOutline: Double = 1
    /// Losgelöste Ablage aus Glas (0 schwarz, 1 Glas), weich übergeblendet
    var tearGlass: Double {
        get { tearState.glass }
        set {
            tearState.glass = newValue
            if tearGlassMostly != (newValue > 0.5) { tearGlassMostly = newValue > 0.5 }
        }
    }
    /// Mehr Glas als Schwarz (`tearGlass` über 0,5): bestimmt hell oder dunkel der Schrift
    @Published private(set) var tearGlassMostly = false
    /// Helles Erscheinungsbild des Systems (folgt Änderungen während der Nutzung)
    /// (gesetzt vom Rand-Controller; hier ohne NSApp, das gibt es in den Tests nicht)
    @Published var systemLight = false

    /// Ordner oder App, die gerade über die Ablage gezogen wird und sich anheften ließe.
    /// Solange gesetzt, zeigt die Aktionsleiste einen freien Platz zum Anheften.
    @Published private(set) var pinCandidate: URL?
    private var pinClear: DispatchWorkItem?

    func setPinCandidate(_ url: URL?, animated: Bool = true) {
        holdPinCandidate()
        guard pinCandidate != url else { return }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pinCandidate = url }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pinCandidate = url }
        }
    }

    /// Der Zeiger ist noch über der Ablage (ein Ziel darin hat den Drag übernommen)
    func holdPinCandidate() {
        pinClear?.cancel()
        pinClear = nil
    }

    /// Der Zeiger hat ein Ziel verlassen: kurz warten, ob ein anderes Ziel der Ablage
    /// übernimmt, sonst den Platz wieder ausblenden
    func releasePinCandidate(after delay: TimeInterval = 0.25) {
        holdPinCandidate()
        guard pinCandidate != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.setPinCandidate(nil) }
        pinClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Kurze Rückmeldung oben in der Ablage („Entfernt“, „Kopiert“).
    struct Notice: Equatable {
        var id = UUID()
        var text: String
        /// Lässt sich mit ⌘Z widerrufen: dann bleibt der Hinweis etwas länger stehen
        var canUndo = false
    }
    @Published var notice: Notice?

    /// Eine Aktion wird gerade mit ⌘ in der Leiste verschoben: Die Ablage bleibt offen
    var actionMoving = false
    /// Diese Aktion hängt nach dem Herausziehen am Zeiger (ihr Platz in der Leiste bleibt leer)
    @Published var detachedAction: UUID?

    var isLocked: Bool { menuOpen || sharingOpen || bandActive || actionMoving }
}

/// Form und Glas der vom Rand gezogenen Ablage (siehe ShelfUIModel.tearState)
final class TearState: ObservableObject {
    @Published var tear: ShelfUIModel.Tear?
    @Published var glass: Double = 0
}

/// Maße der schwarzen Form je Zustand.
struct ShelfMetrics {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var fillet: CGFloat
    /// Länge des Übergangs zum Rand (siehe EdgeBlobShape)
    var filletStretch: CGFloat = 1.25
    /// Länge der inneren Rundung in Randrichtung (siehe EdgeBlobShape)
    var cornerStretch: CGFloat = 1

    /// Der erste Streifen: flach und dicht am Rand, mit lang auslaufenden
    /// Übergängen, wie ein Stück Bildschirmrand, das sich herauswölbt.
    private static func peek(_ settings: AppSettings) -> ShelfMetrics {
        // Aufbau wie die offene Ablage, nur flach: gerade Front, kleine runde Ecken,
        // ein kurzer Bogen in den Rand. „Übergang“ 0…1 bestimmt nur, wie lang dieser
        // Bogen ausläuft; Ecke und Bogen treffen sich immer ohne Knick.
        //
        // Die äußeren Ecken (weg vom Bildschirmrand) sind in Randrichtung immer gleich lang
        // gerundet: Ein dünner Streifen bekommt dieselbe weiche Ecke wie ein dicker,
        // nur flacher. Die Übergänge direkt am Bildschirmrand bleiben, wie sie sind.
        let t = CGFloat(settings.peekThickness)
        let soft = CGFloat(PeekDefaults.roundness)
        let corner = t * 0.5
        let stretch = 1 + soft
        let cornerLength: CGFloat = 8                        // Eckenlänge des dicken Streifens (16 pt)
        return ShelfMetrics(width: t, height: CGFloat(settings.peekLength),
                            cornerRadius: corner,
                            fillet: (t - corner) * stretch + 1,
                            filletStretch: stretch,
                            cornerStretch: max(1, cornerLength / max(corner, 0.5)))
    }

    static func `for`(_ level: ShelfUIModel.Level, settings: AppSettings) -> ShelfMetrics {
        switch level {
        case .hidden:
            // Im Rand versunken und kürzer: Beim Erscheinen wächst der Streifen gleichzeitig
            // heraus und in die Länge, wie die Lautstärkeanzeige am iPhone.
            var m = peek(settings)
            m.width = 0
            m.height *= 0.55
            return m
        case .peek:
            return peek(settings)
        case .hint:
            // Der Streifen bleibt, wie er unter Aussehen → Streifen am Rand eingestellt ist,
            // bis die Ablage aufgeht, auch beim Öffnen per Klick (der Klick zählt am Rand
            // und mit größerem Trefferbereich auch knapp daneben)
            return peek(settings)
        case .expanded:
            return ShelfMetrics(width: CGFloat(settings.shelfWidth),
                                height: CGFloat(settings.shelfHeight),
                                cornerRadius: 28, fillet: 16)
        }
    }

    static let maxFillet: CGFloat = 22
    /// Platz für den Schatten im Fenster: groß genug, dass er ganz ausläuft
    /// und nicht am Fensterrand abgeschnitten wird
    static let panelMargin: CGFloat = 60
}
