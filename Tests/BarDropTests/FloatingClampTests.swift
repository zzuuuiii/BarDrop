import XCTest
@testable import BarDrop

/// Grenzen der schwebenden Ablage auf mehreren Bildschirmen (Nutzer, 22.11.2026: an der Grenze
/// zweier Bildschirme flackerte sie und ließ sich halb ins Leere ziehen).
final class FloatingClampTests: XCTestCase {
    /// MacBook links (1470 × 956), daneben ein höherer Monitor (2560 × 1440), unten bündig
    private let laptop = (frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
                          visible: NSRect(x: 0, y: 0, width: 1470, height: 923))
    private let monitor = (frame: NSRect(x: 1470, y: 0, width: 2560, height: 1440),
                           visible: NSRect(x: 1470, y: 0, width: 2560, height: 1415))
    private let size = NSSize(width: 210, height: 352)

    private func clamp(_ origin: NSPoint) -> NSRect {
        EdgeController.clampFloating(NSRect(origin: origin, size: size), areas: [laptop, monitor])
    }

    func testFreeSpotStaysUnchanged() {
        let target = NSRect(origin: NSPoint(x: 300, y: 200), size: size)
        XCTAssertEqual(EdgeController.clampFloating(target, areas: [laptop, monitor]), target)
    }

    func testCrossingInSharedBandSlidesOver() {
        // Unten liegen beide Bildschirme nebeneinander: Die Ablage darf über die Grenze
        let target = NSRect(origin: NSPoint(x: 1400, y: 100), size: size)
        XCTAssertEqual(EdgeController.clampFloating(target, areas: [laptop, monitor]), target)
    }

    func testNeverHangsIntoNothing() {
        // Oben ragt nur der Monitor hinaus: Über der Grenze und über dem MacBook ist nichts
        let result = clamp(NSPoint(x: 1400, y: 1000))
        let rects = [laptop, monitor].map { NSRect(x: $0.frame.minX, y: $0.visible.minY,
                                                   width: $0.frame.width, height: $0.visible.height) }
        for corner in [NSPoint(x: result.minX + 1, y: result.minY + 1), NSPoint(x: result.maxX - 1, y: result.maxY - 1),
                       NSPoint(x: result.minX + 1, y: result.maxY - 1), NSPoint(x: result.maxX - 1, y: result.minY + 1)] {
            XCTAssertTrue(rects.contains { $0.contains(corner) }, "\(result)")
        }
    }

    func testStableWhileMovingAcrossTheBorder() {
        // Schritt für Schritt über die Grenze: Die Lage ändert sich gleichmäßig, ohne Sprung zurück
        var last: NSRect?
        for x in stride(from: CGFloat(1200), through: 1600, by: 2) {
            let result = clamp(NSPoint(x: x, y: 800))
            if let last { XCTAssertGreaterThanOrEqual(result.minX, last.minX - 0.5, "x=\(x)") }
            XCTAssertEqual(result, clamp(NSPoint(x: x, y: 800)), "gleiches Ziel, gleiches Ergebnis")
            last = result
        }
    }
}
