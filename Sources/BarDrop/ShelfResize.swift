import Foundation

/// Größe der offenen Ablage mit ⌘ an Ecke oder Kante ändern: die Rechnung dazu (Ablauf im
/// EdgeController, Abschnitt „Größe mit ⌘ an einer Ecke“).
///
/// Ein System für Einstellungen und Ziehen (Nutzer, 07.11.2026: fühlte sich komisch an): Beim
/// Ziehen folgt die Ablage frei und flüssig, ohne Einrasten mittendrin (springende Größen wie in
/// Stage Manager auf dem iPad 16 oder in Terminal-Fenstern wirkten unruhig). Beim Loslassen
/// gleitet sie auf die nächste ganze Spaltenzahl und die nächste Höhenstufe, also genau auf
/// die Werte der Regler in Einstellungen → Aussehen. Breiten zwischen zwei Spalten ergaben
/// nur größere Lücken. Über die Grenzen hinaus gibt sie wie ein Gummiband etwas nach und
/// federt zurück.
enum ShelfResize {
    /// Breite: von 2 Spalten (die Aktionsleiste braucht den Platz) bis 4 Spalten bei mittlerer Größe
    static let widthRange = 210.0...400.0
    /// Höhe: genau die Stufen der Einstellungen (ShelfSizes.heights)
    static var heightRange: ClosedRange<Double> {
        let steps = ShelfSizes.heights.map(\.0)
        return (steps.min() ?? 280)...(steps.max() ?? 680)
    }
    /// So weit (pt) gibt die Ablage über eine Grenze hinaus höchstens nach
    static let rubberReach = 24.0
    /// Dauer des Gleitens auf die Stufe nach dem Loslassen (s)
    static let settleDuration = 0.22

    /// Gummiband an den Grenzen: innerhalb unverändert, darüber hinaus immer zäher, höchstens
    /// `reach` (Formel wie beim Überziehen einer Liste in iOS)
    static func rubber(_ value: Double, in range: ClosedRange<Double>, reach: Double = rubberReach) -> Double {
        func give(_ over: Double) -> Double { reach * (1 - 1 / (over * 0.55 / reach + 1)) }
        if value > range.upperBound { return range.upperBound + give(value - range.upperBound) }
        if value < range.lowerBound { return range.lowerBound - give(range.lowerBound - value) }
        return value
    }

    /// Breite beim Loslassen: die nächste, bei der die Spalten genau passen
    static func settledWidth(_ width: Double, iconSize: Double, range: ClosedRange<Double> = widthRange) -> Double {
        let widths = ShelfGrid.columnChoices(iconSize: iconSize, range: range)
            .compactMap { ShelfGrid.width(columns: $0, iconSize: iconSize, range: range) }
        return widths.min { abs($0 - width) < abs($1 - width) } ?? min(max(width, range.lowerBound), range.upperBound)
    }

    /// Höhe beim Loslassen: die nächste Stufe, die auf den Bildschirm passt
    static func settledHeight(_ height: Double, maxHeight: Double) -> Double {
        let steps = ShelfSizes.heights.map(\.0).filter { $0 <= maxHeight }
        return steps.min { abs($0 - height) < abs($1 - height) } ?? max(heightRange.lowerBound, (maxHeight / 10).rounded(.down) * 10)
    }

    /// Zwischen zwei Höhen liegt eine Stufe (für den Impuls beim Ziehen)
    static func crossesStep(from old: Double, to new: Double) -> Bool {
        let low = min(old, new), high = max(old, new)
        return ShelfSizes.heights.contains { $0.0 > low && $0.0 <= high }
    }

    /// Neue Mitte einer Seite: Ohne ⌥ bleibt die gegenüberliegende Kante stehen (wie bei
    /// Fenstern in macOS), mit ⌥ (`handle` 0) bleibt die Mitte. `handle` 1: die obere bzw.
    /// rechte Kante wird gezogen
    static func anchoredCenter(start center: Double, startLength: Double, length: Double, handle: Int) -> Double {
        switch handle {
        case 1: return center - startLength / 2 + length / 2
        case -1: return center + startLength / 2 - length / 2
        default: return center
        }
    }
}
