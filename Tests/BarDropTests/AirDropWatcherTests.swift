import XCTest
@testable import BarDrop

final class AirDropWatcherTests: XCTestCase {
    /// Absender aus der Quarantäne: AirDrop ja, Browser nein
    func testQuarantineAgent() throws {
        XCTAssertEqual(AirDropWatcher.agent(fromQuarantine: "0083;65f1a2b3;sharingd;"), "sharingd")
        XCTAssertEqual(AirDropWatcher.agent(fromQuarantine: "0081;65f1a2b3;Safari;4C1B-UUID"), "Safari")
        XCTAssertNil(AirDropWatcher.agent(fromQuarantine: "0083;65f1a2b3"))
        XCTAssertTrue(AirDropWatcher.isAirDrop(agent: "sharingd"))
        XCTAssertFalse(AirDropWatcher.isAirDrop(agent: "Safari"))

        // Aus einer echten Datei gelesen
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("airdrop-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(AirDropWatcher.quarantineAgent(file))
        let value = "0083;65f1a2b3;sharingd;"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        XCTAssertEqual(AirDropWatcher.quarantineAgent(file), "sharingd")
    }

    /// Ein empfangener Ordner gilt erst als fertig, wenn sein Inhalt nicht mehr wächst: Dafür
    /// zählt die Größe aller Dateien darin, nicht die des Ordners selbst
    func testFolderSizeGrowsWithContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 100).write(to: folder.appendingPathComponent("a.bin"))
        XCTAssertEqual(AirDropWatcher.folderSize(folder), 100)
        try Data(count: 50).write(to: folder.appendingPathComponent("sub/b.bin"))
        XCTAssertEqual(AirDropWatcher.folderSize(folder), 150)
    }
}
