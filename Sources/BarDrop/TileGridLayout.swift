import SwiftUI

/// Maße des Rasters der Ablage an einer Stelle: Ablage, Pfeiltasten, Einführung und
/// Einstellungen rechnen alle damit (vorher stand die Formel viermal da)
enum ShelfGrid {
    /// Rand links und rechts in der Ablage, Abstand zwischen den Spalten
    static let sidePadding: CGFloat = 12
    static let spacing: CGFloat = 8

    /// Spalten mindestens Symbol + 22 pt (Platz für den Namen), höchstens + 40 pt
    static func minimum(_ iconSize: CGFloat) -> CGFloat { iconSize + 22 }
    static func maximum(_ iconSize: CGFloat) -> CGFloat { iconSize + 40 }

    /// So viele Spalten, wie bei dieser Breite der Ablage hineinpassen
    static func columns(shelfWidth: Double, iconSize: Double) -> Int {
        columns(gridWidth: CGFloat(shelfWidth) - 2 * sidePadding, minimum: minimum(CGFloat(iconSize)), spacing: spacing)
    }

    static func columns(gridWidth: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        // Int(.infinity) stürzt ab: SwiftUI fragt Layouts manchmal mit unendlicher Breite an
        let ratio = (gridWidth + spacing) / max(1, minimum + spacing)
        // Erst begrenzen, dann umwandeln: Int(x) stürzt auch bei endlichen Riesenwerten ab
        return ratio.isFinite ? max(1, Int(min(10_000, ratio))) : 1
    }

    /// Breiten der Ablage, bei denen es genau `count` Spalten sind
    static func widths(columns count: Int, iconSize: Double) -> ClosedRange<Double> {
        let step = Double(minimum(CGFloat(iconSize)) + spacing)
        let lower = Double(2 * sidePadding) - Double(spacing) + Double(count) * step
        return lower...(lower + step - 1)
    }

    /// Lage der Spalten: Breite jeder Spalte, Abstand vom Rand zur ersten und von Spalte zu
    /// Spalte. Ist die Spalte schon so breit wie erlaubt, verteilt sich der Rest gleichmäßig
    /// auf die Abstände (wie im Finder). Vorher blieb er als leerer Rand links und rechts
    /// stehen, bis zu 45 pt, bis plötzlich eine Spalte dazukam
    static func layout(gridWidth: CGFloat, minimum: CGFloat, maximum: CGFloat, spacing: CGFloat)
        -> (count: Int, width: CGFloat, inset: CGFloat, step: CGFloat) {
        let count = columns(gridWidth: gridWidth, minimum: minimum, spacing: spacing)
        let cell = max(0, min(maximum, (gridWidth - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let rest = max(0, gridWidth - cell * CGFloat(count) - spacing * CGFloat(count - 1))
        guard rest > 0.5, count > 1 else { return (count, cell, rest / 2, cell + spacing) }
        let gap = (gridWidth - cell * CGFloat(count)) / CGFloat(count)
        return (count, cell, gap / 2, cell + gap)
    }
}

/// Raster der Kacheln in der Ablage, im Stapel und im Ordner.
///
/// Anders als `LazyVGrid` legt es alle Kacheln wirklich an. `LazyVGrid` schätzt die Höhe
/// der Kacheln, die es noch nicht angelegt hat, und korrigiert die Schätzung beim schnellen
/// Scrollen mit Schwung sprunghaft: Die Ablage übersprang dabei Kacheln und landete in
/// beiden Richtungen sofort am Ende. Hier steht die Höhe des Inhalts immer genau fest.
///
/// Aufteilung wie bisher (und wie `DemoLayout.tileCenter` in der Einführung): so viele
/// Spalten, wie mit `minimum` hineinpassen, alle gleich breit, höchstens `maximum`, und der
/// Block mittig. Jede Reihe ist so hoch wie ihre höchste Kachel.
struct TileGridLayout: Layout {
    var minimum: CGFloat
    var maximum: CGFloat
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    private struct Columns {
        let count: Int
        let width: CGFloat
        let inset: CGFloat
        /// Von Spalte zu Spalte (Breite plus Abstand)
        let step: CGFloat
    }

    private func columns(for width: CGFloat) -> Columns {
        let c = ShelfGrid.layout(gridWidth: width, minimum: minimum, maximum: maximum, spacing: spacing)
        return Columns(count: c.count, width: c.width, inset: c.inset, step: c.step)
    }

    /// Höhe jeder Reihe bei dieser Spaltenbreite
    private func rowHeights(_ subviews: Subviews, _ c: Columns) -> [CGFloat] {
        let proposal = ProposedViewSize(width: c.width, height: nil)
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let end = min(index + c.count, subviews.count)
            heights.append((index..<end).map { subviews[$0].sizeThatFits(proposal).height }.max() ?? 0)
            index = end
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (maximum * 2 + spacing)
        let heights = rowHeights(subviews, columns(for: width))
        let height = heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = columns(for: bounds.width)
        let heights = rowHeights(subviews, c)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            let start = row * c.count
            for index in start..<min(start + c.count, subviews.count) {
                let x = bounds.minX + c.inset + CGFloat(index - start) * c.step
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: c.width, height: height))
            }
            y += height + rowSpacing
        }
    }
}
