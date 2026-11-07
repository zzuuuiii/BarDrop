import XCTest
import SwiftUI
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
            for width in stride(from: 140.0, through: 680, by: 7) {
                XCTAssertTrue(choices.contains(ShelfResize.settledWidth(width, iconSize: icon)), "\(icon) \(width)")
            }
        }
        XCTAssertEqual(ShelfResize.settledWidth(300, iconSize: 64), 322, "näher an 3 Spalten als an 2")
    }

    /// Losgelassen liegt die Höhe auf einer ganzen Reihenzahl, die auf den Bildschirm passt
    func testSettledRowsFitTheScreen() {
        let icon = 64.0, bar = ShelfRows.barHeight
        let three = ShelfRows.height(rows: 3, iconSize: icon, barHeight: bar)
        XCTAssertEqual(ShelfResize.settledRows(three + 20, iconSize: icon, maxHeight: 5000), 3)
        XCTAssertEqual(ShelfResize.settledRows(three + 100, iconSize: icon, maxHeight: 5000), 4)
        XCTAssertEqual(ShelfResize.settledRows(5000, iconSize: icon, maxHeight: 5000), ShelfRows.range.upperBound)
        XCTAssertEqual(ShelfResize.settledRows(5000, iconSize: icon, maxHeight: three + 10), 3)
        XCTAssertEqual(ShelfResize.settledRows(0, iconSize: icon, maxHeight: 5000), 2)
    }

    func testCrossingARow() {
        let three = ShelfRows.height(rows: 3, iconSize: 64)
        XCTAssertTrue(ShelfResize.crossesRow(from: three - 5, to: three + 5, iconSize: 64))
        XCTAssertTrue(ShelfResize.crossesRow(from: three + 5, to: three - 5, iconSize: 64))
        XCTAssertFalse(ShelfResize.crossesRow(from: three + 5, to: three + 50, iconSize: 64))
    }

    /// Höhe und Reihen rechnen sich genau ineinander um
    func testRowsAndHeightMatch() {
        for icon in ShelfSizes.items.map(\.0) {
            for rows in ShelfRows.range {
                let h = ShelfRows.height(rows: rows, iconSize: icon)
                XCTAssertEqual(ShelfRows.rows(forHeight: h, iconSize: icon), Double(rows), accuracy: 0.02)
            }
        }
    }

    /// Die Formel für eine Kachelreihe stimmt mit der gezeichneten Kachel überein (zweizeiliger Name)
    func testTileHeightMatchesTheTile() {
        for icon in ShelfSizes.items.map(\.0) {
            let tile = NSHostingView(rootView: TileLabel(title: "Ein langer Dateiname, der in zwei Zeilen umbricht.pdf",
                                                         isSelected: false, isKey: false, iconSize: CGFloat(icon)) { Color.clear }
                .frame(width: CGFloat(icon + 30)))
            XCTAssertEqual(Double(tile.fittingSize.height), ShelfRows.tileHeight(icon), accuracy: 1, "\(icon)")
        }
    }

    /// Die Objektgröße ändert nur die Kacheln, nicht die Größe der Ablage (wie im Finder)
    func testItemSizeKeepsShelfSize() {
        let settings = AppSettings.shared
        let saved = (settings.shelfWidth, settings.shelfHeight, settings.tileIconSize)
        defer { settings.shelfWidth = saved.0; settings.shelfHeight = saved.1; settings.tileIconSize = saved.2 }
        settings.shelfWidth = 300; settings.shelfHeight = 420; settings.tileIconSize = 64
        settings.tileIconSize = 88
        XCTAssertEqual(settings.shelfWidth, 300)
        XCTAssertEqual(settings.shelfHeight, 420)
        settings.resetSize()
        XCTAssertTrue(settings.sizeIsDefault)
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
