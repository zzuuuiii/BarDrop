import XCTest
@testable import BarDrop

/// Glas der losgelösten Ablage: System, Manuell, Aus (Einstellungen → Aussehen)
final class GlassModeTests: XCTestCase {
    /// Wer schon „Glas, wenn losgelöst“ eingestellt hatte, behält es: an wird System, aus bleibt aus
    func testStoredModeFollowsFormerToggle() {
        XCTAssertEqual(GlassMode.stored(nil, detachedGlass: true), .system)
        XCTAssertEqual(GlassMode.stored(nil, detachedGlass: false), .off)
        XCTAssertEqual(GlassMode.stored("manual", detachedGlass: false), .manual)
        XCTAssertEqual(GlassMode.stored("unbekannt", detachedGlass: true), .system)
    }

    /// Drei kurze Möglichkeiten: als Umschalter in der Zeile wie bei der Sprache
    func testTitlesAreShortForSegmentedControl() {
        for mode in GlassMode.allCases {
            XCTAssertLessThanOrEqual(mode.title.count, PickerRow<GlassMode>.shortLength, mode.title)
        }
    }

    /// Symbole: Hell und Dunkel gelten fest, Automatisch folgt dem Erscheinungsbild von macOS
    func testIconStyleResolves() {
        XCTAssertFalse(IconAppearance.resolve(.light))
        XCTAssertTrue(IconAppearance.resolve(.dark))
        XCTAssertEqual(IconAppearance.resolve(.automatic), IconAppearance.systemIsDark)
    }

    /// Kachelform wie die App-Symbole von macOS 26 (824 von 1024, Ecken 26 %)
    func testAppIconShapeMatchesSystem() {
        XCTAssertEqual(AppIconShape.bodyFraction, 0.8047, accuracy: 0.001)
        XCTAssertEqual(AppIconShape.cornerFraction, 0.26)
    }
}
