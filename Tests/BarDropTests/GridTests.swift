import XCTest
import AppKit
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

/// Höchstgeschwindigkeit beim Scrollen in der Ablage
final class ScrollSpeedTests: XCTestCase {
    private func scroll(_ dy: Int32, precise: Bool) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                         wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    /// Ein schneller Schwung wird auf die Höchstgeschwindigkeit gedrosselt, die Richtung bleibt
    func testFastSwipeIsLimited() throws {
        for dy: Int32 in [400, -400] {
            let limited = try XCTUnwrap(ScrollSpeed.limited(scroll(dy, precise: true)))
            XCTAssertLessThanOrEqual(abs(limited.scrollingDeltaY), ScrollSpeed.limit(elapsed: 1) + 0.5)
            XCTAssertGreaterThan(limited.scrollingDeltaY * CGFloat(dy), 0, "Richtung")
        }
    }

    /// Langsames Scrollen und das Mausrad bleiben unverändert
    func testSlowScrollAndWheelUnchanged() {
        XCTAssertNil(ScrollSpeed.limited(scroll(5, precise: true)))
        XCTAssertNil(ScrollSpeed.limited(scroll(3, precise: false)))
    }
}
