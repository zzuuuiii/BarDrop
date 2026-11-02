import Foundation
import CoreGraphics

/// Entscheidet, welche Stufe die Ablage zeigen soll. Reine Logik ohne Fenster und
/// Bildschirm (nach perch, ShelfHoverRegion/ShelfHoverGate), damit sie sich
/// automatisch testen lässt. `EdgeController` liefert die Messwerte und setzt das
/// Ergebnis um.
enum EdgeLogic {
    /// Was über mehrere Takte hinweg gemerkt wird.
    struct State {
        var level: ShelfUIModel.Level = .hidden
        var levelSince = Date.distantPast
        /// Seit wann der Zeiger die offene Ablage verlassen hat
        var outsideSince: Date?
        /// Per Kurzbefehl oder Menü geöffnet
        var manualOpen = false
        /// Nach manuellem Öffnen war der Zeiger schon einmal über der Ablage
        var manualHovered = false
        /// Seit die Ablage zuletzt ganz verborgen war, gab es schon einen Impuls
        var hapticGiven = false
    }

    /// Messwerte eines Takts.
    struct Sample {
        var now = Date()
        /// Abstand des Zeigers zum Bildschirmrand
        var dx: CGFloat
        /// Abstand des Zeigers zur Mitte der schwarzen Form
        var dy: CGFloat
        /// Zeiger auf dem Bildschirm, an dem die Ablage gerade sitzt
        var onScreen = true
        /// Zeiger auf einem anderen Bildschirm, auf dem BarDrop ebenfalls verfügbar ist
        var onOtherScreen = false
        /// Zeiger in dem Bereich des Rands, in dem die Ablage erscheinen darf
        /// („nur mittleres Drittel“). Außerhalb erscheint kein neuer Streifen.
        var inRevealZone = true
        /// Der Rand geht an dieser Stelle in einen anderen Bildschirm über (Monitor
        /// daneben). Dort ist kein echter Rand: Der Zeiger wandert einfach weiter.
        var innerEdge = false
        /// Zeiger über der offenen Ablage (mit etwas Spielraum)
        var overExpanded = false
        /// Es wird gerade etwas Ablegbares gezogen
        var dragging = false
        /// Der Drag kommt aus der Ablage selbst
        var ownDrag = false
        /// Kontextmenü, Teilen oder Übersicht offen: Ablage bleibt stehen
        var locked = false
        /// Vorschau nach dem Ändern einer Einstellung
        var preview: ShelfUIModel.Level?
        /// Maße der aktuell sichtbaren Form
        var width: CGFloat = 0
        var height: CGFloat = 64
        var fillet: CGFloat = 6
    }

    struct Config {
        var dragReveal: DragReveal = .immediately
        var revealOnHover = true
        var openMode: OpenMode = .automatic
        /// So lange muss der Zeiger am Streifen bleiben, bis die Ablage aufgeht
        var openDelay: TimeInterval = 0.3
        /// Etwas größerer Bereich um Streifen und Griff, in dem der Zeiger noch zählt
        var generousHitArea = false

        /// Zusätzlicher Spielraum quer zum Rand und entlang des Rands
        var hitSlack: (x: CGFloat, y: CGFloat) { generousHitArea ? (8, 24) : (0, 0) }
        /// Beim Ziehen einer Datei: ab hier öffnet die Ablage ganz. Mit größerem
        /// Trefferbereich etwas weiter vom Rand und höher, nicht übertrieben.
        var dragExpand: (distance: CGFloat, span: CGFloat) {
            generousHitArea ? (EdgeLogic.dragExpandDistance + 30, EdgeLogic.dragExpandSpan + 40)
                            : (EdgeLogic.dragExpandDistance, EdgeLogic.dragExpandSpan)
        }
    }

    struct Result: Equatable {
        var target: ShelfUIModel.Level
        /// Ein dezenter Impuls: der erste Streifen erscheint, oder eine gezogene
        /// Datei hat die Ablage erreicht
        var haptic = false
    }

    // Abstände (Punkte), ab denen die Stufen beim Ziehen erscheinen
    static let dragExpandDistance: CGFloat = 90
    static let dragExpandSpan: CGFloat = 170
    static let dragHintDistance: CGFloat = 300
    static let dragHintSpan: CGFloat = 320
    /// So lange darf der Zeiger die offene Ablage verlassen, bevor sie schließt
    static let leaveDelay: TimeInterval = 0.3

    static func decide(_ state: inout State, _ s: Sample, _ c: Config) -> Result {
        var result = Result(target: state.level)
        if state.level == .hidden { state.hapticGiven = false }
        defer { if result.haptic { state.hapticGiven = true } }

        let expand = c.dragExpand

        if s.locked {
            result.target = .expanded
        } else if s.dragging && s.preview == .expanded && s.onScreen {
            // Einführung: Die Ablage steht offen und bleibt es, während etwas gezogen wird
            result.target = .expanded
        } else if s.dragging {
            if s.ownDrag {
                // Objekt aus der Ablage: Sie schließt, sobald es sie verlässt, öffnet sich
                // aber wieder, wenn man damit an den Rand zurückkommt (zum Zurücklegen)
                let backAtEdge = s.onScreen && !s.innerEdge && s.dx < expand.distance && s.dy < expand.span
                result.target = s.overExpanded || state.manualOpen || backAtEdge ? .expanded : .hidden
                // Zurück am Rand: derselbe leichte Impuls wie beim ersten Hineinziehen
                if result.target == .expanded && state.level != .expanded { result.haptic = true }
            } else if !s.onScreen || (s.innerEdge && !s.overExpanded && !state.manualOpen) {
                // Drag auf anderem Bildschirm, oder auf dem Weg hinüber zum Bildschirm daneben
                result.target = .hidden
            } else if s.overExpanded || (s.dx < expand.distance && s.dy < expand.span) {
                result.target = .expanded
                // Die Datei hat die Ablage erreicht: ein leichter Impuls, sofort
                if state.level != .expanded { result.haptic = true }
            } else if s.dx < dragHintDistance && s.dy < dragHintSpan {
                result.target = .hint
            } else {
                // „Streifen sofort zeigen“: schmaler Streifen schon beim Start des Ziehens.
                // Zeigt gerade eine Vorschau den Streifen (Einführung), bleibt er stehen.
                result.target = c.dragReveal == .immediately || s.preview == .peek ? .peek : .hidden
            }
        } else if state.manualOpen {
            if s.overExpanded { state.manualHovered = true }
            // Zeiger auf einem anderen Bildschirm: dort wird die Ablage nicht gebraucht
            result.target = ((state.manualHovered && !s.overExpanded) || s.onOtherScreen) ? .hidden : .expanded
        } else if state.level == .expanded {
            // Vorschau der offenen Ablage (Größe wird verstellt): offen halten
            if s.overExpanded || (s.preview == .expanded && s.onScreen) {
                state.outsideSince = nil
            } else {
                let since = state.outsideSince ?? s.now
                state.outsideSince = since
                if s.now.timeIntervalSince(since) > leaveDelay { result.target = .hidden }
            }
        } else {
            let slack = c.hitSlack
            let touchesEdge = c.revealOnHover && s.onScreen
                && s.dx <= max(3, s.width + 4) + slack.x
                && s.dy < max(50, s.height / 2 + s.fillet + 6) + slack.y
            let elapsed = s.now.timeIntervalSince(state.levelSince)
            if touchesEdge {
                // Stand der Streifen schon, ohne dass der Zeiger ihn erreicht hatte (Vorschau
                // beim Start, nach dem Verstellen oder in der Einführung): Der Impuls kommt,
                // sobald der Zeiger ihn erreicht. Sonst bliebe dieses Öffnen ohne Impuls.
                if state.level != .hidden && !state.hapticGiven { result.haptic = true }
                // „Sofort“: ohne Streifen und Wartezeit gleich ganz öffnen
                let immediate = c.openMode == .automatic && c.openDelay <= 0.01
                switch state.level {
                case .hidden where s.inRevealZone:
                    // Nur im erlaubten Bereich: Dort sitzt der Streifen genau mittig am Zeiger
                    result.target = immediate ? .expanded : .peek
                    result.haptic = true
                case .peek where immediate, .hint where immediate:
                    result.target = .expanded
                case .peek where elapsed > 0.1:
                    result.target = .hint
                case .hint where elapsed > c.openDelay && c.openMode == .automatic:
                    result.target = .expanded
                default:
                    break
                }
            } else if let preview = s.preview, s.onScreen {
                // Zeiger hat den stehenden Streifen verlassen: beim nächsten Erreichen wieder ein Impuls
                state.hapticGiven = false
                result.target = preview
            } else if state.level != .hidden && !(s.onScreen && s.dx < 26 + slack.x && s.dy < 110 + slack.y) {
                result.target = .hidden
            } else if state.level != .hidden && elapsed > 1.5 {
                result.target = .hidden
            }
        }
        return result
    }

    /// Geht der Rand eines Bildschirms auf Höhe `y` in einen anderen Bildschirm über?
    static func edgeContinues(_ frame: CGRect, edge: ScreenEdge, at y: CGFloat, into others: [CGRect]) -> Bool {
        others.contains { other in
            guard other != frame, y >= other.minY, y < other.maxY else { return false }
            return edge == .right ? abs(other.minX - frame.maxX) < 2 : abs(other.maxX - frame.minX) < 2
        }
    }

    /// Ist nichts zu tun, sodass der Takt ruhen kann? Die Ablage wird dann nur noch
    /// über Ereignisse des Systems (Zeiger bewegt, Ziehen begonnen) geweckt.
    static func isCalm(fullyHidden: Bool, mouseDown: Bool, manualOpen: Bool, previewActive: Bool,
                       locked: Bool, onScreen: Bool, dx: CGFloat) -> Bool {
        fullyHidden && !mouseDown && !manualOpen && !previewActive && !locked
            && (!onScreen || dx > wakeDistance)
    }

    /// Ab diesem Abstand zum Rand weckt eine Zeigerbewegung den Takt.
    static let wakeDistance: CGFloat = 160
}
