import XCTest
@testable import BarDrop

/// Raster der Ablage (ShelfGrid): Spalten, Breiten je Spaltenzahl, Verteilung des Rests
final class GridTests: XCTestCase {
    /// Für jede Breite liegt die Spaltenzahl in genau dem Bereich, den `widths` dafür nennt
    func testWidthsMatchColumns() {
        for icon in stride(from: 40.0, through: 96.0, by: 4) {
            for width in stride(from: 150.0, through: 600.0, by: 1) {
                let count = ShelfGrid.columns(shelfWidth: width, iconSize: icon)
                guard count > 1 else { continue }
                XCTAssertTrue(ShelfGrid.widths(columns: count, iconSize: icon).contains(width),
                              "Breite \(width), Symbol \(icon): \(count) Spalten")
            }
        }
    }

    /// Standard (240 pt, Symbol 64 pt): zwei Spalten wie bisher
    func testDefaultIsTwoColumns() {
        XCTAssertEqual(ShelfGrid.columns(shelfWidth: 240, iconSize: 64), 2)
        XCTAssertEqual(ShelfGrid.columns(shelfWidth: 300, iconSize: 64), 3)
    }

    /// Kein leerer Rand mehr: Ist die Spalte schon so breit wie erlaubt, verteilt sich der
    /// Rest gleichmäßig, der Rand ist dann halb so breit wie der Abstand zwischen Spalten
    func testRestIsSpreadEvenly() {
        let icon: CGFloat = 64
        let grid = ShelfGrid.layout(gridWidth: 290 - 24, minimum: ShelfGrid.minimum(icon),
                                    maximum: ShelfGrid.maximum(icon), spacing: ShelfGrid.spacing)
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.width, ShelfGrid.maximum(icon))
        let gap = grid.step - grid.width
        XCTAssertEqual(grid.inset * 2, gap, accuracy: 0.001)
        // Erste Spalte beginnt beim Rand, die letzte endet genauso weit vor dem Ende
        let end = grid.inset + CGFloat(grid.count - 1) * grid.step + grid.width
        XCTAssertEqual(266 - end, grid.inset, accuracy: 0.001)
    }

    /// Passt alles genau, bleibt es wie bisher: fester Abstand, kein Rand
    func testExactFitKeepsSpacing() {
        let icon: CGFloat = 64
        let grid = ShelfGrid.layout(gridWidth: 240 - 24, minimum: ShelfGrid.minimum(icon),
                                    maximum: ShelfGrid.maximum(icon), spacing: ShelfGrid.spacing)
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.inset, 0, accuracy: 0.001)
        XCTAssertEqual(grid.step, grid.width + ShelfGrid.spacing, accuracy: 0.001)
    }
}
