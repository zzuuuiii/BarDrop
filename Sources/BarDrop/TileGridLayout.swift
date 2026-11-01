import SwiftUI

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
    }

    private func columns(for width: CGFloat) -> Columns {
        // Int(.infinity) stürzt ab: SwiftUI fragt Layouts manchmal mit unendlicher Breite an
        let ratio = (width + spacing) / max(1, minimum + spacing)
        let count = ratio.isFinite ? max(1, min(10_000, Int(ratio))) : 1
        let cell = max(0, min(maximum, (width - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let used = cell * CGFloat(count) + spacing * CGFloat(count - 1)
        return Columns(count: count, width: cell, inset: max(0, (width - used) / 2))
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
                let x = bounds.minX + c.inset + CGFloat(index - start) * (c.width + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: c.width, height: height))
            }
            y += height + rowSpacing
        }
    }
}
