import AppKit

/// Größe der offenen Ablage mit ⌘ an Ecke oder Kante ändern: die Rechnung dazu (Ablauf im
/// EdgeController, Abschnitt „Größe mit ⌘ an einer Ecke“).
///
/// Ein System für Einstellungen und Ziehen (Nutzer, 07.11.2026: fühlte sich komisch an): Beim
/// Ziehen folgt die Ablage frei und flüssig, ohne Einrasten mittendrin (springende Größen wie in
/// Stage Manager auf dem iPad 16 oder in Terminal-Fenstern wirkten unruhig). Beim Loslassen
/// gleitet sie auf die nächste ganze Spalten- und Reihenzahl, also genau auf
/// die Werte der Regler in Einstellungen → Aussehen. Breiten zwischen zwei Spalten ergaben
/// nur größere Lücken. Über die Grenzen hinaus gibt sie wie ein Gummiband etwas nach und
/// federt zurück.
enum ShelfResize {
    /// Breite: schmaler als 210 pt wird die Aktionsleiste unlesbar (Nutzertest 07.11.2026),
    /// 650 pt fassen 5 sehr große Spalten
    static let widthRange = 210.0...650.0
    /// Höhe: von der kleinsten bis zur größten Reihenzahl bei der eingestellten Objektgröße
    static var heightRange: ClosedRange<Double> {
        let icon = AppSettings.shared.tileIconSize
        return ShelfRows.height(rows: ShelfRows.range.lowerBound, iconSize: icon)
            ... ShelfRows.height(rows: ShelfRows.range.upperBound, iconSize: icon)
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

    /// Höhe beim Loslassen: die nächste ganze Reihenzahl, die auf den Bildschirm passt
    static func settledRows(_ height: Double, iconSize: Double, maxHeight: Double) -> Int {
        let fitting = ShelfRows.choices(iconSize: iconSize, maxHeight: maxHeight)
        let exact = ShelfRows.rows(forHeight: height, iconSize: iconSize)
        return fitting.min { abs(Double($0) - exact) < abs(Double($1) - exact) } ?? ShelfRows.range.lowerBound
    }

    /// Zwischen zwei Höhen kommt eine Reihe dazu oder fällt weg (für den Impuls beim Ziehen)
    static func crossesRow(from old: Double, to new: Double, iconSize: Double) -> Bool {
        let low = min(old, new), high = max(old, new)
        return ShelfRows.range.contains { rows in
            let h = ShelfRows.height(rows: rows, iconSize: iconSize)
            return h > low && h <= high
        }
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

/// Höhe der Ablage in ganzen Reihen: Beim Loslassen nach dem Ziehen gleitet sie auf eine Höhe,
/// in die die Reihen genau passen (Kopfzeile, Raster, Aktionsleiste). Auch der Standard.
enum ShelfRows {
    static let range = 2...12
    static let defaultRows = 3

    /// Kopfzeile: 12 pt oben, 30 pt Zeile, 4 pt darunter (ShelfContent)
    static let headerHeight = 46.0
    /// Rand des Rasters oben und unten (je 6 pt) und Abstand zwischen den Reihen
    static let gridPadding = 12.0
    static let rowSpacing = 4.0

    /// Eine Kachel mit zweizeiligem Namen: Symbolfläche + 40 pt (in den Tests nachgemessen)
    static func tileHeight(_ iconSize: Double) -> Double {
        Double(TileMetrics.box(CGFloat(iconSize))) + 40
    }

    /// Höhe der Aktionsleiste samt Rändern, in der Ablage gemessen (hängt von Zahl, Größe und
    /// Namen der Aktionen ab). Gemerkt, damit das Einrasten schon vor dem ersten Öffnen stimmt
    private static let barKey = "shelfActionBarHeight"
    static var barHeight: Double {
        let stored = UserDefaults.standard.double(forKey: barKey)
        return stored > 0 ? stored : 62
    }

    /// Neue Höhe der Aktionsleiste gemessen
    static func barMeasured(_ height: Double) {
        guard height > 10, abs(height - barHeight) > 0.5 else { return }
        UserDefaults.standard.set(height, forKey: barKey)
    }

    static func height(rows: Int, iconSize: Double, barHeight: Double = barHeight) -> Double {
        let n = Double(rows)
        return (headerHeight + gridPadding + n * tileHeight(iconSize) + (n - 1) * rowSpacing + barHeight).rounded()
    }

    /// Reihen bei dieser Höhe, mit Bruchteil
    static func rows(forHeight height: Double, iconSize: Double, barHeight: Double = barHeight) -> Double {
        (height - headerHeight - gridPadding - barHeight + rowSpacing) / (tileHeight(iconSize) + rowSpacing)
    }

    /// Höchste Höhe, die auf jeden Bildschirm passt (angedockt samt Bögen zum Rand)
    static var screenMaxHeight: Double {
        let heights = NSScreen.screens.map { Double($0.visibleFrame.height) }
        return (heights.min() ?? 900) - 2 * Double(ShelfMetrics.maxFillet + 8)
    }

    /// Reihenzahlen, die bei dieser Objektgröße auf den Bildschirm passen (mindestens die kleinste)
    static func choices(iconSize: Double, maxHeight: Double = screenMaxHeight) -> [Int] {
        let fitting = range.filter { height(rows: $0, iconSize: iconSize) <= maxHeight }
        return fitting.isEmpty ? [range.lowerBound] : fitting
    }
}
