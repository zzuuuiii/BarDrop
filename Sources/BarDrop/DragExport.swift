import AppKit
import UniformTypeIdentifiers

/// Herausziehen aus der Ablage in andere Programme.
///
/// Dateien des Nutzers (Schreibtisch, Dokumente …) gehen wie im Finder als
/// Dateiadresse auf die Reise. Dateien, die BarDrop selbst gespeichert hat (Bilder
/// aus dem Web, Texte, Links, Kopien), gehen als *Datei-Versprechen* (nach perch):
/// Das Ziel nennt einen Ort, und BarDrop schreibt die Datei selbst dorthin. Der
/// Finder muss die gespeicherte Datei dann nicht selbst kopieren, und BarDrop
/// erfährt, wann und ob die Kopie fertig ist. Für Programme, die keine Versprechen
/// kennen (Terminal, Browser, viele Editoren), liegt zusätzlich eine frische Kopie
/// als Dateiadresse bei (nach NotchDrop), bei Text und Links außerdem der Inhalt
/// selbst (nach boring.notch).
enum DragExport {
    /// Pasteboard-Schreiber für eine Datei der Ablage.
    static func writer(for file: ShelfFile) -> NSPasteboardWriting {
        guard file.owned else { return file.url as NSURL }
        let type = (try? file.url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.url.pathExtension) ?? .data
        let item = ExportItem(source: file.url,
                              fileName: file.url.lastPathComponent,
                              fileType: type.identifier)
        let provider = ExportPromiseProvider(fileType: item.fileType, delegate: DragExporter.shared)
        provider.userInfo = item
        provider.fileURL = Outbox.shared.freshCopy(of: file.url) ?? file.url
        let native = NativeContent(of: file.url)
        provider.nativeString = native.string
        provider.nativeURL = native.url
        return provider
    }
}

/// Eine gespeicherte Datei, die per Versprechen herausgegeben wird.
struct ExportItem {
    let source: URL
    let fileName: String
    let fileType: String
}

/// Text und Links, die BarDrop als Datei gespeichert hat, zusätzlich im eigenen Format.
struct NativeContent {
    var string: String?
    var url: URL?

    init(of file: URL) {
        switch file.pathExtension.lowercased() {
        case "webloc":
            if let data = try? Data(contentsOf: file),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let link = (plist["URL"] as? String).flatMap(URL.init(string:)) {
                url = link
                string = link.absoluteString
            }
        case "txt":
            // Nur kurze Texte; große Dateien bleiben Dateien
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000 {
                string = try? String(contentsOf: file, encoding: .utf8)
            }
        default:
            break
        }
    }
}

/// Datei-Versprechen, das zusätzlich eine Dateiadresse und bei Text und Links den
/// Inhalt anbietet. Programme, die Versprechen verstehen, nehmen das Versprechen;
/// alle anderen finden die Adresse bzw. den Text.
final class ExportPromiseProvider: NSFilePromiseProvider {
    var fileURL: URL?
    var nativeString: String?
    var nativeURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if fileURL != nil { types.append(.fileURL) }
        if nativeURL != nil { types.append(.URL) }
        if nativeString != nil { types.append(.string) }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        switch type {
        case .fileURL, .URL, .string: return []      // sofort bekannt
        default: return super.writingOptions(forType: type, pasteboard: pasteboard)
        }
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            return (fileURL as NSURL?)?.pasteboardPropertyList(forType: .fileURL)
        case .URL:
            return (nativeURL as NSURL?)?.pasteboardPropertyList(forType: .URL)
        case .string:
            return nativeString
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }
}

/// Erfüllt die Datei-Versprechen. Lebt so lange wie die App, damit ein Versprechen
/// auch dann noch erfüllt wird, wenn die Ablage schon wieder verborgen ist.
final class DragExporter: NSObject, NSFilePromiseProviderDelegate {
    static let shared = DragExporter()

    /// Kopien laufen im Hintergrund, höchstens zwei gleichzeitig (nach perch).
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "BarDrop.export"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    private var failedAt: [String: Date] = [:]

    /// Eine Kopie ist fehlgeschlagen (auf dem Hauptthread). Die Ablage kann das
    /// Objekt dann wieder zurückholen.
    var onFailed: (URL) -> Void = { _ in }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Wird die Datei gerade an ein Ziel kopiert?
    func isBusy(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active[Self.key(url), default: 0] > 0
    }

    /// Führt `work` aus, sobald keine Kopie dieser Datei mehr läuft (auf dem Hauptthread).
    func whenIdle(_ url: URL, _ work: @escaping () -> Void) {
        lock.lock()
        if active[Self.key(url), default: 0] > 0 {
            waiting[Self.key(url), default: []].append(work)
            lock.unlock()
        } else {
            lock.unlock()
            if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
        }
    }

    /// Ist eine Kopie dieser Datei gerade eben fehlgeschlagen?
    func failedRecently(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let date = failedAt[Self.key(url)] else { return false }
        return Date().timeIntervalSince(date) < 30
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? ExportItem)?.fileName ?? L("Item", "Objekt")
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let item = filePromiseProvider.userInfo as? ExportItem else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let key = Self.key(item.source)
        lock.lock(); active[key, default: 0] += 1; lock.unlock()
        defer { finish(key) }

        do {
            try FileManager.default.copyItem(at: item.source, to: url)
            Log.export.info("Versprechen erfüllt: \(item.fileName, privacy: .private)")
            completionHandler(nil)
        } catch {
            // Zweiter Versuch: nur die Daten kopieren
            if FileSanitizer.cleanCopy(from: item.source, to: url) {
                Log.export.info("Versprechen erfüllt (nur Daten): \(item.fileName, privacy: .private)")
                completionHandler(nil)
            } else {
                Log.export.error("Versprechen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                lock.lock(); failedAt[key] = Date(); lock.unlock()
                let source = item.source
                DispatchQueue.main.async { [weak self] in self?.onFailed(source) }
                completionHandler(error)
            }
        }
    }

    private func finish(_ key: String) {
        lock.lock()
        active[key, default: 1] -= 1
        var ready: [() -> Void] = []
        if active[key, default: 0] <= 0 {
            active[key] = nil
            ready = waiting.removeValue(forKey: key) ?? []
        }
        lock.unlock()
        if !ready.isEmpty { DispatchQueue.main.async { ready.forEach { $0() } } }
    }
}

/// Frische Kopien für das Herausziehen (nach NotchDrop). Auf APFS sind das
/// Klone: Sie kosten weder Zeit noch Speicherplatz, solange sich nichts ändert.
/// Programme, die nur die Adresse lesen, behalten so eine gültige Datei, auch wenn
/// das Objekt in der Ablage inzwischen entfernt wurde.
final class Outbox {
    static let shared = Outbox()

    /// Nach so vielen Sekunden werden Kopien wieder gelöscht.
    static let lifetime: TimeInterval = 6 * 3_600

    private(set) var directory: URL

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("BarDrop/Outbox", isDirectory: true)
    }

    func freshCopy(of url: URL) -> URL? {
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let result = url.withUnsafeFileSystemRepresentation { src in
            target.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE))
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: dir)
            Log.export.error("Frische Kopie nicht möglich (\(errno, privacy: .public)), nehme Original")
            return nil
        }
        return target
    }

    /// Löscht alte Kopien.
    func cleanUp(olderThan age: TimeInterval = Outbox.lifetime) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for dir in dirs {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: dir) }
        }
    }
}
