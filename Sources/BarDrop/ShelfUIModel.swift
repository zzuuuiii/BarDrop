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

    /// Ein Kontextmenü der Ablage ist geöffnet.
    var menuOpen = false
    /// Ein Teilen-Fenster (Picker) ist geöffnet.
    var sharingOpen = false
    /// Gerade wird ein Objekt aus der Ablage herausgezogen.
    var ownDragActive = false
    /// Einträge, die gerade aus der Ablage gezogen werden (für Ablegen auf Stapel).
    var draggedEntryIDs: Set<UUID> = []
    /// Gespeicherte Orte der Dateien, die gerade aus der Ablage gezogen werden.
    /// Für Aktionen in der Leiste: Das Drag-Pasteboard enthält nur frische Kopien.
    var draggedFileURLs: [URL] = []
    /// Der letzte eigene Drag endete innerhalb der Ablage (Aktion oder Stapel).
    var lastDropWasInternal = false
    /// Klick auf die mittlere Stufe: Ablage ganz öffnen (Modus „Per Klick“).
    var expandRequested = false
    /// Beim Verstellen der Symbolgröße: Beispieldatei in der Ablage zeigen
    @Published var showSampleTile = false
    /// Lage der offenen Ablage (schwarze Form) auf dem Bildschirm, ohne Schattenrand
    var expandedBody: CGRect = .zero

    /// Ordner oder App, die gerade über die Ablage gezogen wird und sich anheften ließe.
    /// Solange gesetzt, zeigt die Aktionsleiste einen freien Platz zum Anheften.
    @Published private(set) var pinCandidate: URL?
    private var pinClear: DispatchWorkItem?

    func setPinCandidate(_ url: URL?) {
        holdPinCandidate()
        guard pinCandidate != url else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pinCandidate = url }
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

    /// Kurze Rückmeldung oben in der Ablage („2 Objekte entfernt · Widerrufen“).
    struct Notice: Equatable {
        var id = UUID()
        var text: String
        var canUndo = false
    }
    @Published var notice: Notice?

    var isLocked: Bool { menuOpen || sharingOpen }
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
        let soft = CGFloat(settings.peekRoundness)
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
            // Automatisch: der Streifen bleibt, wie er ist, bis die Ablage aufgeht.
            // „Per Klick“: ein etwas größerer Griff, den man treffen kann.
            guard settings.openMode == .click else { return peek(settings) }
            let t = CGFloat(settings.peekThickness)
            let w = max(24, t + 14)
            return ShelfMetrics(width: w, height: max(110, CGFloat(settings.peekLength) + 16),
                                cornerRadius: w * 0.6, fillet: 14, filletStretch: 2.2, cornerStretch: 1.8)
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
