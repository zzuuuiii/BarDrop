import XCTest
@testable import BarDrop

/// Links von der Website (Plus bei einem Plugin): nur `bardrop://plugin/install?id=…` mit einer
/// gültigen ID wird angenommen, alles andere still ignoriert.
final class PluginLinkTests: XCTestCase {
    private func id(_ text: String) -> String? {
        URL(string: text).flatMap(PluginLink.installID(from:))
    }

    func testValidLink() {
        XCTAssertEqual(id("bardrop://plugin/install?id=io.github.zzuuuiii.stems"), "io.github.zzuuuiii.stems")
        XCTAssertEqual(id("bardrop://plugin/install?id=io.github.richard2007-21.api-test"), "io.github.richard2007-21.api-test")
        XCTAssertEqual(id("BARDROP://Plugin/install?id=a_b"), "a_b")
        XCTAssertEqual(id("bardrop://plugin/install/?id=x&other=1"), "x")
    }

    func testRejected() {
        XCTAssertNil(id("bardrop://plugin/install"))                         // ohne ID
        XCTAssertNil(id("bardrop://plugin/install?id="))                     // leere ID
        XCTAssertNil(id("bardrop://plugin/install?id=a%2Fb"))                // Schrägstrich
        XCTAssertNil(id("bardrop://plugin/install?id=..%2F..%2Fetc"))
        XCTAssertNil(id("bardrop://plugin/install?id=%C3%A4bc"))             // kein ASCII
        XCTAssertNil(id("bardrop://plugin/install?id=a%20b"))                // Leerzeichen
        XCTAssertNil(id("bardrop://plugin/install?id=" + String(repeating: "a", count: 201)))
        XCTAssertNil(id("bardrop://plugin/remove?id=x"))                     // andere Aktion
        XCTAssertNil(id("bardrop://settings/install?id=x"))
        XCTAssertNil(id("https://plugin/install?id=x"))                      // anderes Schema
        XCTAssertNil(id("file:///tmp/x.bdrop"))
    }
}
