import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Wandelt Dateien in andere Formate um, nur mit dem, was macOS mitbringt:
/// ImageIO für Bilder, PDFKit für PDF, `textutil` für Texte, `afconvert` für Audio
/// und AVFoundation für Videos. Welche Bildformate sich schreiben lassen, fragt
/// BarDrop macOS selbst; was das System nicht kann, wird gar nicht erst angeboten.
enum Converter {

    /// Eine Umwandlung, wie sie im Menü steht
    enum Target: Hashable {
        case image(UTType)
        case resize(Int)
        case imagesToPDF
        case pdfToImages(UTType)
        case text(String)
        case audio(String)
        case video(String)
        case audioFromVideo

        var title: String {
            switch self {
            case .image(let type): return type.preferredFilenameExtension?.uppercased() ?? type.identifier
            case .resize(let size): return L("Resize to \(size) px", "Verkleinern auf \(size) px")
            case .imagesToPDF: return L("Combine into PDF", "Zu einem PDF zusammenfassen")
            case .pdfToImages(let type):
                return L("Pages as \(type.preferredFilenameExtension?.uppercased() ?? "")",
                         "Seiten als \(type.preferredFilenameExtension?.uppercased() ?? "")")
            case .text(let format): return Converter.textFormats.first { $0.format == format }?.title ?? format
            case .audio(let id): return Converter.audioFormats.first { $0.id == id }?.title ?? id
            case .video(let id): return Converter.videoFormats.first { $0.id == id }?.title ?? id
            case .audioFromVideo: return L("Audio only (M4A)", "Nur Ton (M4A)")
            }
        }
    }

    enum Kind { case image, pdf, text, audio, video }

    // MARK: Was angeboten wird

    /// Bildformate, die infrage kommen; angeboten wird nur, was macOS schreiben kann
    private static let imageCandidates: [UTType] = [
        .png, .jpeg, .heic, .tiff, .gif, .bmp,
        UTType("public.avif"), UTType("org.webmproject.webp")
    ].compactMap { $0 }

    static var writableImageTypes: [UTType] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return imageCandidates.filter { writable.contains($0.identifier) }
    }

    /// Formate von `textutil`
    static let textFormats: [(format: String, ext: String, title: String)] = [
        ("txt", "txt", L("Plain text (TXT)", "Reiner Text (TXT)")),
        ("rtf", "rtf", "RTF"),
        ("html", "html", "HTML"),
        ("docx", "docx", L("Word (DOCX)", "Word (DOCX)")),
        ("doc", "doc", L("Word 97 (DOC)", "Word 97 (DOC)")),
        ("odt", "odt", "OpenDocument (ODT)")
    ]
    private static let textInputExtensions: Set<String> = ["txt", "text", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "webarchive", "md"]

    /// Formate von `afconvert`: Dateityp, Datenformat, Endung
    static let audioFormats: [(id: String, file: String, data: String, ext: String, title: String)] = [
        ("aac", "m4af", "aac", "m4a", "M4A (AAC)"),
        ("alac", "m4af", "alac", "m4a", L("M4A (Apple Lossless)", "M4A (Apple Lossless)")),
        ("wav", "WAVE", "LEI16", "wav", "WAV"),
        ("aiff", "AIFF", "BEI16", "aiff", "AIFF"),
        ("caf", "caff", "LEI16", "caf", "CAF")
    ]

    /// Voreinstellungen von AVFoundation: Voreinstellung, Dateityp, Endung
    static let videoFormats: [(id: String, preset: String, type: AVFileType, ext: String, title: String)] = [
        ("mp4", AVAssetExportPresetHighestQuality, .mp4, "mp4", "MP4"),
        ("mov", AVAssetExportPresetHighestQuality, .mov, "mov", "MOV"),
        ("hevc", AVAssetExportPresetHEVCHighestQuality, .mp4, "mp4", L("MP4 (HEVC, smaller)", "MP4 (HEVC, kleiner)")),
        ("1080", AVAssetExportPreset1920x1080, .mp4, "mp4", "MP4 1080p"),
        ("720", AVAssetExportPreset1280x720, .mp4, "mp4", "MP4 720p")
    ]

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if textInputExtensions.contains(url.pathExtension.lowercased()) { return .text }
        return nil
    }

    /// Angebote für die Dateien; leer, wenn sie nicht zusammenpassen oder nichts geht.
    /// Das eigene Format wird nur bei einer einzigen Art ausgelassen.
    static func targets(for urls: [URL]) -> [[Target]] {
        let kinds = Set(urls.map(kind(of:)))
        guard kinds.count == 1, let kind = kinds.first ?? nil else { return [] }
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        func isSame(_ ext: String) -> Bool { exts.count == 1 && exts.contains(ext) }
        switch kind {
        case .image:
            let formats = writableImageTypes
                .filter { type in !(type.tags[.filenameExtension] ?? []).contains(where: isSame) }
                .map(Target.image)
            return [formats, [.resize(2048), .resize(1024), .resize(512)], [.imagesToPDF]]
        case .pdf:
            return [[.pdfToImages(.png), .pdfToImages(.jpeg)]]
        case .text:
            return [textFormats.filter { !isSame($0.ext) }.map { Target.text($0.format) }]
        case .audio:
            return [audioFormats.filter { !(isSame($0.ext) && $0.id != "alac" && $0.id != "aac") }.map { Target.audio($0.id) }]
        case .video:
            return [videoFormats.map { Target.video($0.id) }, [.audioFromVideo]]
        }
    }

    // MARK: Umwandeln

    /// Wandelt im Hintergrund um und liefert die neuen Dateien (in einem eigenen
    /// Zwischenordner) auf dem Hauptthread; leer, wenn nichts gelang.
    static func convert(_ urls: [URL], to target: Target, completion: @escaping ([URL]) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarDropConvert-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finish: ([URL]) -> Void = { results in DispatchQueue.main.async { completion(results) } }

        switch target {
        case .video(let id):
            guard let format = videoFormats.first(where: { $0.id == id }) else { return finish([]) }
            exportVideos(urls, preset: format.preset, type: format.type, ext: format.ext, in: dir, completion: finish)
        case .audioFromVideo:
            exportVideos(urls, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a", in: dir, completion: finish)
        default:
            DispatchQueue.global(qos: .userInitiated).async {
                finish(convertSync(urls, to: target, in: dir))
            }
        }
    }

    private static func convertSync(_ urls: [URL], to target: Target, in dir: URL) -> [URL] {
        switch target {
        case .image(let type):
            return urls.compactMap { writeImage($0, as: type, maxPixels: nil, in: dir) }
        case .resize(let size):
            return urls.compactMap { url in
                let source = UTType(filenameExtension: url.pathExtension.lowercased())
                let type = source.flatMap { s in writableImageTypes.first { s.conforms(to: $0) } } ?? .png
                return writeImage(url, as: type, maxPixels: size, in: dir)
            }
        case .imagesToPDF:
            return imagesToPDF(urls, in: dir).map { [$0] } ?? []
        case .pdfToImages(let type):
            return urls.flatMap { pdfToImages($0, as: type, in: dir) }
        case .text(let format):
            guard let ext = textFormats.first(where: { $0.format == format })?.ext else { return [] }
            return urls.compactMap { url in
                let out = output(for: url, ext: ext, in: dir)
                return run("/usr/bin/textutil", ["-convert", format, "-output", out.path, url.path]) ? out : nil
            }
        case .audio(let id):
            guard let f = audioFormats.first(where: { $0.id == id }) else { return [] }
            return urls.compactMap { url in
                let out = output(for: url, ext: f.ext, in: dir)
                return run("/usr/bin/afconvert", ["-f", f.file, "-d", f.data, url.path, out.path]) ? out : nil
            }
        case .video, .audioFromVideo:
            return []
        }
    }

    // MARK: Bilder

    private static func writeImage(_ url: URL, as type: UTType, maxPixels: Int?, in dir: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let ext = type.preferredFilenameExtension ?? "png"
        let suffix = maxPixels.map { " (\($0) px)" } ?? ""
        let out = output(for: url, ext: ext, in: dir, suffix: suffix)
        // Animierte Bilder bleiben animiert, wenn das Ziel es kann (GIF)
        let frames = (type == .gif && maxPixels == nil) ? max(1, CGImageSourceGetCount(source)) : 1
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, frames, nil) else { return nil }
        let opaque = type == .jpeg || type == .bmp
        var options: [CFString: Any] = [:]
        if type == .jpeg || type == .heic { options[kCGImageDestinationLossyCompressionQuality] = 0.9 }

        for index in 0..<frames {
            var image: CGImage?
            if let maxPixels {
                image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels
                ] as CFDictionary)
            } else {
                image = CGImageSourceCreateImageAtIndex(source, index, nil)
            }
            guard var cg = image else { return nil }
            // JPEG und BMP kennen keine Transparenz: auf Weiß statt auf Schwarz
            if opaque, cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst,
               let flat = flatten(cg) {
                cg = flat
            }
            var frameOptions = options
            if maxPixels == nil, let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] {
                // Ausrichtung, Farbprofil und GIF-Zeiten übernehmen
                frameOptions.merge(props) { mine, _ in mine }
            }
            CGImageDestinationAddImage(dest, cg, frameOptions as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // MARK: PDF

    private static func imagesToPDF(_ urls: [URL], in dir: URL) -> URL? {
        let document = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, let first = urls.first else { return nil }
        let out = output(for: first, ext: "pdf", in: dir)
        return document.write(to: out) ? out : nil
    }

    private static func pdfToImages(_ url: URL, as type: UTType, in dir: URL) -> [URL] {
        guard let document = PDFDocument(url: url) else { return [] }
        var results: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // Doppelte Auflösung, damit Text scharf bleibt
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let suffix = document.pageCount > 1 ? " \(index + 1)" : ""
            let out = output(for: url, ext: type.preferredFilenameExtension ?? "png", in: dir, suffix: suffix)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { continue }
            let final = type == .jpeg ? (flatten(cg) ?? cg) : cg
            CGImageDestinationAddImage(dest, final, nil)
            if CGImageDestinationFinalize(dest) { results.append(out) }
        }
        return results
    }

    // MARK: Video

    private static func exportVideos(_ urls: [URL], preset: String, type: AVFileType, ext: String,
                                     in dir: URL, completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(type) else { continue }
            let out = output(for: url, ext: ext, in: dir)
            session.outputURL = out
            session.outputFileType = type
            group.enter()
            session.exportAsynchronously {
                if session.status == .completed {
                    lock.lock(); results.append(out); lock.unlock()
                } else {
                    Log.importing.error("Video-Umwandlung fehlgeschlagen: \(session.error?.localizedDescription ?? "", privacy: .public)")
                }
                group.leave()
            }
        }
        group.notify(queue: .global()) { completion(results) }
    }

    // MARK: Hilfen

    /// Zieldatei: gleicher Name mit neuer Endung, bei Bedarf durchnummeriert
    private static func output(for url: URL, ext: String, in dir: URL, suffix: String = "") -> URL {
        let base = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
