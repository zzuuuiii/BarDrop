import XCTest
@testable import BarDrop

/// Form der eigenen Kacheln
final class AppIconShapeTests: XCTestCase {
    /// Kachelform wie die App-Symbole von macOS 26 (824 von 1024, Ecken 26 %)
    func testAppIconShapeMatchesSystem() {
        XCTAssertEqual(AppIconShape.bodyFraction, 0.8047, accuracy: 0.001)
        XCTAssertEqual(AppIconShape.cornerFraction, 0.26)
    }
}
