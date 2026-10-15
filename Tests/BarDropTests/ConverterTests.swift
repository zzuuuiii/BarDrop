import XCTest
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
@testable import BarDrop

/// Umwandeln mit den Bordmitteln von macOS: Jede Art einmal echt ausführen.
final class ConverterTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropConvertTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func convert(_ urls: [URL], _ target: Converter.Target) -> [URL] {
        let done = expectation(description: "umgewandelt")
        var result: [URL] = []
        Converter.convert(urls, to: target) { urls in
            result = urls
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return result
    }

    /// PNG mit Transparenz, 300 × 200
    private func makePNG(_ name: String = "Bild.png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 150, height: 200).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testOffersMatchTheFileType() throws {
        let png = try makePNG()
        let image = Converter.targets(for: [png]).flatMap { $0 }
        XCTAssertTrue(image.contains(.image(.jpeg)))
        XCTAssertFalse(image.contains(.image(.png)), "Nicht ins eigene Format")
        XCTAssertTrue(image.contains(.imagesToPDF))
        let text = dir.appendingPathComponent("a.txt")
        XCTAssertTrue(Converter.targets(for: [png, text]).isEmpty, "Gemischte Arten: nichts anbieten")
    }

    func testImageToJPEGAndResize() throws {
        let png = try makePNG()
        let jpeg = try XCTUnwrap(convert([png], .image(.jpeg)).first)
        XCTAssertEqual(jpeg.pathExtension, "jpeg")
        XCTAssertNotNil(NSImage(contentsOf: jpeg))

        let small = try XCTUnwrap(convert([png], .resize(100)).first)
        let rep = try XCTUnwrap(NSImageRep(contentsOf: small))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 100)
    }

    func testImagesToPDFAndBack() throws {
        let a = try makePNG("A.png"), b = try makePNG("B.png")
        let pdf = try XCTUnwrap(convert([a, b], .imagesToPDF).first)
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
        let pages = convert([pdf], .pdfToImages(.png))
        XCTAssertEqual(pages.count, 2)
    }

    func testTextDocument() throws {
        let txt = dir.appendingPathComponent("Notiz.txt")
        try "Hallo".write(to: txt, atomically: true, encoding: .utf8)
        let html = try XCTUnwrap(convert([txt], .text("html")).first)
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("Hallo"))
    }

    func testAudio() throws {
        // Eine Viertelsekunde Ton als WAV, dann nach M4A
        let wav = dir.appendingPathComponent("Ton.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11_025))
        buffer.frameLength = 11_025
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.06) * 0.3 }
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            try file.write(from: buffer)
        }
        let m4a = try XCTUnwrap(convert([wav], .audio("aac")).first)
        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertGreaterThan((try? m4a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)
    }
}
