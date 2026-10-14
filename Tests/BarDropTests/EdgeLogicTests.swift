import XCTest
@testable import BarDrop

/// Erkennung am Rand, ohne Fenster und Bildschirm geprüft.
final class EdgeLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func sample(dx: CGFloat, dy: CGFloat = 0, at seconds: TimeInterval = 0,
                        dragging: Bool = false, own: Bool = false, over: Bool = false,
                        level: ShelfUIModel.Level = .hidden) -> EdgeLogic.Sample {
        let m: (CGFloat, CGFloat, CGFloat) = {
            switch level {
            case .hidden: return (0, 64, 6)
            case .peek: return (16, 84, 6.4)
            case .hint: return (30, 128, 10)
            case .expanded: return (300, 420, 16)
            }
        }()
        return EdgeLogic.Sample(now: t0.addingTimeInterval(seconds), dx: dx, dy: dy,
                                onScreen: true, overExpanded: over, dragging: dragging,
                                ownDrag: own, locked: false, preview: nil,
                                width: m.0, height: m.1, fillet: m.2)
    }

    private func state(_ level: ShelfUIModel.Level, since seconds: TimeInterval = 0) -> EdgeLogic.State {
        var s = EdgeLogic.State()
        s.level = level
        s.levelSince = t0.addingTimeInterval(seconds)
        return s
    }

    // MARK: Zeiger am Rand

    func testTouchingEdgeShowsStripWithOneHapticPulse() {
        var s = state(.hidden)
        let r = EdgeLogic.decide(&s, sample(dx: 1), .init())
        XCTAssertEqual(r.target, .peek)
        XCTAssertTrue(r.haptic, "Genau ein Impuls beim ersten Streifen")
    }

    func testStagesNeedTimeToGrow() {
        var s = state(.peek, since: 0)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 1, at: 0.05, level: .peek), .init()).target, .peek,
                       "Noch zu früh für die nächste Stufe")
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 1, at: 0.15, level: .peek), .init()).target, .hint)

        var h = state(.hint, since: 0)
        XCTAssertEqual(EdgeLogic.decide(&h, sample(dx: 1, at: 0.2, level: .hint), .init()).target, .hint)
        XCTAssertEqual(EdgeLogic.decide(&h, sample(dx: 1, at: 0.4, level: .hint), .init()).target, .expanded)
    }

    func testClickModeStopsAtHint() {
        var h = state(.hint, since: 0)
        let config = EdgeLogic.Config(openMode: .click)
        XCTAssertEqual(EdgeLogic.decide(&h, sample(dx: 1, at: 2, level: .hint), config).target, .hint)
    }

    func testOutsideRevealZoneNoStripAppears() {
        var s = state(.hidden)
        var outside = sample(dx: 1)
        outside.inRevealZone = false
        let r = EdgeLogic.decide(&s, outside, .init())
        XCTAssertEqual(r.target, .hidden, "Außerhalb des mittleren Drittels erscheint nichts")
        XCTAssertFalse(r.haptic)
    }

    func testVisibleStripKeepsGrowingAtZoneBorder() {
        // Einmal im Bereich ausgelöst, wächst der Streifen weiter, auch wenn der Zeiger
        // knapp über die Grenze rutscht (sonst würde er am Rand des Bereichs flackern)
        var s = state(.peek, since: 0)
        var p = sample(dx: 1, at: 0.15, level: .peek)
        p.inRevealZone = false
        XCTAssertEqual(EdgeLogic.decide(&s, p, .init()).target, .hint)
    }

    func testDragIgnoresRevealZone() {
        var s = state(.hidden)
        var d = sample(dx: 50, dy: 20, dragging: true)
        d.inRevealZone = false
        XCTAssertEqual(EdgeLogic.decide(&s, d, .init()).target, .expanded, "Beim Ziehen öffnet die Ablage wie bisher")
    }

    func testDraggingAcrossToNeighbourScreenDoesNotOpen() {
        var s = state(.hidden)
        var d = sample(dx: 10, dy: 0, dragging: true)
        d.innerEdge = true
        XCTAssertEqual(EdgeLogic.decide(&s, d, .init()).target, .hidden)
    }

    func testOpenShelfOnInnerEdgeStillAcceptsDrags() {
        var s = state(.expanded)
        s.manualOpen = true
        var d = sample(dx: 100, dy: 0, dragging: true, over: true, level: .expanded)
        d.innerEdge = true
        XCTAssertEqual(EdgeLogic.decide(&s, d, .init()).target, .expanded)
    }

    func testInnerEdgeDetection() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let monitor = CGRect(x: 1512, y: -200, width: 2560, height: 1440)   // rechts daneben, höher
        let screens = [laptop, monitor]
        XCTAssertTrue(EdgeLogic.edgeContinues(laptop, edge: .right, at: 500, into: screens))
        XCTAssertFalse(EdgeLogic.edgeContinues(laptop, edge: .left, at: 500, into: screens))
        XCTAssertFalse(EdgeLogic.edgeContinues(monitor, edge: .right, at: 500, into: screens), "Äußerer Rand")
        XCTAssertTrue(EdgeLogic.edgeContinues(monitor, edge: .left, at: 500, into: screens))
        // Monitor endet unterhalb: dort ist der linke Rand wieder ein echter Rand
        XCTAssertFalse(EdgeLogic.edgeContinues(monitor, edge: .left, at: 1100, into: screens))
        XCTAssertFalse(EdgeLogic.edgeContinues(laptop, edge: .right, at: 500, into: [laptop]), "Ein Bildschirm")
    }

    func testHoverDisabledDoesNothing() {
        var s = state(.hidden)
        let config = EdgeLogic.Config(revealOnHover: false)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 0), config).target, .hidden)
    }

    func testLeavingStripHidesIt() {
        var s = state(.peek, since: 0)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 200, at: 0.2, level: .peek), .init()).target, .hidden)
    }

    // MARK: Ziehen

    func testDragStagesByDistance() {
        var s = state(.hidden)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 800, dragging: true), .init()).target, .peek,
                       "„Sofort andeuten“: Streifen schon weit vom Rand")
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 200, dragging: true), .init()).target, .hint)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 40, dragging: true), .init()).target, .expanded)
    }

    func testDraggedFileReachingShelfGivesOnePulse() {
        var s = state(.hint)
        let first = EdgeLogic.decide(&s, sample(dx: 40, dragging: true, level: .hint), .init())
        XCTAssertEqual(first.target, .expanded)
        XCTAssertTrue(first.haptic, "Impuls, sobald die Datei die Ablage erreicht")
        s.level = .expanded
        let again = EdgeLogic.decide(&s, sample(dx: 30, dragging: true, level: .expanded), .init())
        XCTAssertFalse(again.haptic, "Nicht bei jeder weiteren Bewegung")
    }

    func testDragNearEdgeModeStaysHiddenFarAway() {
        var s = state(.hidden)
        let config = EdgeLogic.Config(dragReveal: .nearEdge)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 800, dragging: true), config).target, .hidden)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 200, dragging: true), config).target, .hint)
    }

    func testOwnDragKeepsShelfOnlyWhilePointerIsOverIt() {
        var s = state(.expanded)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 100, dragging: true, own: true, over: true, level: .expanded),
                                        .init()).target, .expanded)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 600, dragging: true, own: true, over: false, level: .expanded),
                                        .init()).target, .hidden, "Beim Herausziehen weicht die Ablage")
    }

    func testDragOnOtherScreenHides() {
        var s = state(.hint)
        var smp = sample(dx: 10, dragging: true, level: .hint)
        smp.onScreen = false
        XCTAssertEqual(EdgeLogic.decide(&s, smp, .init()).target, .hidden)
    }

    // MARK: Offene Ablage

    func testOpenShelfClosesShortlyAfterLeaving() {
        var s = state(.expanded)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 500, at: 0, level: .expanded), .init()).target, .expanded)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 500, at: 0.2, level: .expanded), .init()).target, .expanded)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 500, at: 0.4, level: .expanded), .init()).target, .hidden)
    }

    func testReturningInTimeKeepsShelfOpen() {
        var s = state(.expanded)
        _ = EdgeLogic.decide(&s, sample(dx: 500, at: 0, level: .expanded), .init())
        _ = EdgeLogic.decide(&s, sample(dx: 100, at: 0.2, over: true, level: .expanded), .init())
        XCTAssertNil(s.outsideSince)
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 500, at: 0.4, level: .expanded), .init()).target, .expanded)
    }

    func testLockedStaysOpen() {
        var s = state(.expanded)
        var smp = sample(dx: 900, at: 5, level: .expanded)
        smp.locked = true
        XCTAssertEqual(EdgeLogic.decide(&s, smp, .init()).target, .expanded)
    }

    func testManualOpenClosesAfterPointerVisitedAndLeft() {
        var s = state(.expanded)
        s.manualOpen = true
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 900, level: .expanded), .init()).target, .expanded,
                       "Per Kurzbefehl geöffnet: bleibt offen, bis der Zeiger einmal drüber war")
        _ = EdgeLogic.decide(&s, sample(dx: 100, over: true, level: .expanded), .init())
        XCTAssertEqual(EdgeLogic.decide(&s, sample(dx: 900, level: .expanded), .init()).target, .hidden)
    }

    func testManualOpenClosesWhenPointerMovesToOtherScreen() {
        var s = state(.expanded)
        s.manualOpen = true
        var smp = sample(dx: 900, level: .expanded)
        smp.onScreen = false
        smp.onOtherScreen = true
        XCTAssertEqual(EdgeLogic.decide(&s, smp, .init()).target, .hidden)
    }

    // MARK: Ruhezustand

    func testCalmOnlyWhenHiddenAndFarAway() {
        XCTAssertTrue(EdgeLogic.isCalm(fullyHidden: true, mouseDown: false, manualOpen: false,
                                       previewActive: false, locked: false, onScreen: true, dx: 500))
        XCTAssertFalse(EdgeLogic.isCalm(fullyHidden: true, mouseDown: false, manualOpen: false,
                                        previewActive: false, locked: false, onScreen: true, dx: 50))
        XCTAssertFalse(EdgeLogic.isCalm(fullyHidden: true, mouseDown: true, manualOpen: false,
                                        previewActive: false, locked: false, onScreen: true, dx: 500))
        XCTAssertFalse(EdgeLogic.isCalm(fullyHidden: false, mouseDown: false, manualOpen: false,
                                        previewActive: false, locked: false, onScreen: true, dx: 500))
    }

    // MARK: Vorschau beim Verstellen der Größe

    func testExpandedPreviewOpensAndStaysOpenWhilePointerIsAway() {
        var away = sample(dx: 600, at: 1)
        away.preview = .expanded
        var s = state(.hidden)
        XCTAssertEqual(EdgeLogic.decide(&s, away, .init()).target, .expanded)

        var open = state(.expanded)
        var later = sample(dx: 600, at: 5, level: .expanded)
        later.preview = .expanded
        XCTAssertEqual(EdgeLogic.decide(&open, later, .init()).target, .expanded,
                       "Solange die Vorschau läuft, bleibt die Ablage offen")

        // Vorschau vorbei: nach kurzer Zeit schließen
        var after = sample(dx: 600, at: 6, level: .expanded)
        after.preview = nil
        _ = EdgeLogic.decide(&open, after, .init())
        var end = sample(dx: 600, at: 6.5, level: .expanded)
        end.preview = nil
        XCTAssertEqual(EdgeLogic.decide(&open, end, .init()).target, .hidden)
    }
}
