import XCTest
@testable import BarDrop

/// Größe mit ⌘ an Ecke oder Kante: frei ziehen, beim Loslassen auf die Stufen der Einstellungen
final class ShelfResizeTests: XCTestCase {
    /// Innerhalb der Grenzen unverändert, darüber hinaus zäh und nie weiter als `rubberReach`
    func testRubberBandGivesWayOnlyALittle() {
        let range = 210.0...400.0
        XCTAssertEqual(ShelfResize.rubber(300, in: range), 300)
        let over = ShelfResize.rubber(450, in: range)
        XCTAssertGreaterThan(over, 400)
        XCTAssertLessThan(over, 400 + ShelfResize.rubberReach)
        XCTAssertLessThan(ShelfResize.rubber(5000, in: range), 400 + ShelfResize.rubberReach)
        XCTAssertLessThan(ShelfResize.rubber(150, in: range), 210)
        XCTAssertGreaterThan(ShelfResize.rubber(-5000, in: range), 210 - ShelfResize.rubberReach)
    }

    /// Losgelassen liegt die Breite immer auf einer ganzen Spaltenzahl, wie im Regler
    func testSettledWidthFitsColumnsExactly() {
        for icon in ShelfSizes.items.map(\.0) {
            let choices = ShelfGrid.columnChoices(iconSize: icon, range: ShelfResize.widthRange)
                .compactMap { ShelfGrid.width(columns: $0, iconSize: icon, range: ShelfResize.widthRange) }
            for width in stride(from: 180.0, through: 430, by: 7) {
                XCTAssertTrue(choices.contains(ShelfResize.settledWidth(width, iconSize: icon)), "\(icon) \(width)")
            }
        }
        XCTAssertEqual(ShelfResize.settledWidth(300, iconSize: 64), 322, "näher an 3 Spalten als an 2")
    }

    /// Losgelassen liegt die Höhe auf einer Stufe, die auf den Bildschirm passt
    func testSettledHeightUsesStepsThatFit() {
        XCTAssertEqual(ShelfResize.settledHeight(395, maxHeight: 2000), 410)
        XCTAssertEqual(ShelfResize.settledHeight(700, maxHeight: 2000), 680)
        XCTAssertEqual(ShelfResize.settledHeight(700, maxHeight: 600), 580)
        XCTAssertEqual(ShelfResize.heightRange, 280...680)
    }

    func testCrossingAHeightStep() {
        XCTAssertTrue(ShelfResize.crossesStep(from: 400, to: 415))
        XCTAssertTrue(ShelfResize.crossesStep(from: 415, to: 400))
        XCTAssertFalse(ShelfResize.crossesStep(from: 412, to: 480))
    }

    /// Ohne ⌥ bleibt die gegenüberliegende Kante stehen, mit ⌥ (0) die Mitte
    func testOppositeEdgeStaysPut() {
        // Unten gezogen (−1): Oberkante 500 + 200 = 700 bleibt
        let down = ShelfResize.anchoredCenter(start: 500, startLength: 400, length: 600, handle: -1)
        XCTAssertEqual(down + 300, 700)
        // Oben gezogen (1): Unterkante 300 bleibt
        let up = ShelfResize.anchoredCenter(start: 500, startLength: 400, length: 600, handle: 1)
        XCTAssertEqual(up - 300, 300)
        XCTAssertEqual(ShelfResize.anchoredCenter(start: 500, startLength: 400, length: 600, handle: 0), 500)
    }
}
