import XCTest
@testable import BarDrop

/// Aktionen mit ⌘ in der Leiste verschieben, auch zwischen den beiden Reihen.
final class ActionOrderTests: XCTestCase {
    private var savedActions: [QuickAction] = []
    private var savedSplit = 0
    private var ids: [String: QuickAction.ID] = [:]

    override func setUp() {
        super.setUp()
        let settings = AppSettings.shared
        savedActions = settings.quickActions
        savedSplit = settings.actionRowSplit
        // Oben A bis E, unten F und G
        let actions = ["A", "B", "C", "D", "E", "F", "G"].map { name -> QuickAction in
            var action = QuickAction(kind: .folder)
            action.path = "/tmp/BarDropOrder-\(name)"
            ids[name] = action.id
            return action
        }
        settings.quickActions = actions
        settings.actionRowSplit = 5
    }

    override func tearDown() {
        AppSettings.shared.quickActions = savedActions
        AppSettings.shared.actionRowSplit = savedSplit
        super.tearDown()
    }

    private var order: [String] {
        AppSettings.shared.quickActions.map { action in ids.first { $0.value == action.id }!.key }
    }

    private var rows: (top: [String], bottom: [String]) {
        let split = AppSettings.shared.effectiveActionSplit
        return (Array(order.prefix(split)), Array(order.dropFirst(split)))
    }

    private func move(_ from: String, to target: String) {
        AppSettings.shared.moveQuickAction(ids[from]!, to: ids[target]!)
    }

    func testMoveRightInSameRowTakesTargetsPlace() {
        move("A", to: "C")
        XCTAssertEqual(rows.top, ["B", "C", "A", "D", "E"])
        XCTAssertEqual(rows.bottom, ["F", "G"])
    }

    func testMoveLeftInSameRowTakesTargetsPlace() {
        move("D", to: "B")
        XCTAssertEqual(rows.top, ["A", "D", "B", "C", "E"])
    }

    func testMoveIntoBottomRowLandsBeforeTarget() {
        move("B", to: "F")
        XCTAssertEqual(rows.top, ["A", "C", "D", "E"])
        XCTAssertEqual(rows.bottom, ["B", "F", "G"])
    }

    /// Die obere Reihe ist voll: ihre letzte Aktion rückt nach unten
    func testMoveIntoFullTopRowPushesLastDown() {
        move("G", to: "A")
        XCTAssertEqual(rows.top, ["G", "A", "B", "C", "D"])
        XCTAssertEqual(rows.bottom, ["E", "F"])
    }

    func testMoveOntoItselfChangesNothing() {
        move("C", to: "C")
        XCTAssertEqual(order, ["A", "B", "C", "D", "E", "F", "G"])
        XCTAssertEqual(AppSettings.shared.actionRowSplit, 5)
    }

    /// Neue Aktionen kommen ans Ende der oberen Reihe, solange dort Platz ist
    func testNewActionGoesToTopRow() {
        let settings = AppSettings.shared
        settings.removeQuickAction(ids["B"]!)
        var action = QuickAction(kind: .folder)
        action.path = "/tmp/BarDropOrder-H"
        ids["H"] = action.id
        settings.addQuickAction(action)
        XCTAssertEqual(rows.top, ["A", "C", "D", "E", "H"])
        XCTAssertEqual(rows.bottom, ["F", "G"])
    }
}
