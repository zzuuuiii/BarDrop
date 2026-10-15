import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Macht aus allem, was in die Ablage gezogen oder eingefügt wird, echte Dateien.
///
/// Grundsatz: Eine Datei wird nur dann bloß *referenziert*, wenn sie dem Nutzer gehört
/// (Schreibtisch, Dokumente, iCloud Drive, externe Laufwerke …). Alles andere, also
/// temporäre Dateien von Browsern, Dateien aus fremden App-Containern, Bilddaten,
/// Bilder aus dem Web, Links und Text, wird als eigene Datei gespeichert. So existiert
/// jede Datei in der Ablage auch noch, wenn die Quelle sie längst gelöscht hat.
///
/// Reihenfolge beim Einlesen (nach perch): Datei-Versprechen, Dateiadressen,
/// Bilddaten und Bildobjekte, Web-Adressen, Text. Kopiert wird im Hintergrund,
/// höchstens zwei Dateien gleichzeitig.
final class ContentImporter {
    let storage: URL
    var convertImages: Bool
    /// Auch Dateien des Nutzers kopieren statt nur zu referenzieren (Einstellung „Immer eine Kopie anlegen“)
    var alwaysCopy = false
    /// Kopie einer sofort gezeigten Datei ist fertig (Hauptthread): ID des Platzhalters
    /// und die Kopie, nil wenn das Kopieren scheiterte (dann bleibt der Verweis aufs Original)
    var onCopyFinished: (UUID, URL?) -> Void = { _, _ in }

    /// Datei-Versprechen werden hier erfüllt.
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.name = "BarDrop.import.promises"
        return queue
    }()

    /// Kopien in den eigenen Speicher (nach perch: höchstens zwei gleichzeitig).
    private let copyQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.name = "BarDrop.import.copy"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(storage: URL, convertImages: Bool) {
        self.storage = storage
        self.convertImages = convertImages
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    }

    // MARK: Einstieg

    /// Liest das Pasteboard aus und liefert die entstandenen Dateien (immer auf dem Hauptthread).
    /// `showWhileCopying`: Dateien des Nutzers, die kopiert werden, sofort als Verweis liefern
    /// und erst nach dem Kopieren austauschen (`onCopyFinished`). Nur für das bloße Ablegen,
    /// nicht wenn danach eine Aktion mit den Dateien arbeitet.
    func importContent(of pb: NSPasteboard, showWhileCopying: Bool = false,
                       completion: @escaping ([ShelfFile]) -> Void) {
        let fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []

        // Dateien aus dem Finder: nur referenzieren, auch wenn zusätzlich ein Versprechen anliegt
        let onlyUserFiles = !fileURLs.isEmpty && fileURLs.allSatisfy(Self.isUserFile)

        // 1. Datei-Versprechen (Safari, Chrome, Fotos, Mail …)
        if !promises.isEmpty && !onlyUserFiles {
            // Inhalte sichern, solange das Drag-Pasteboard noch gültig ist
            let snapshot = PasteboardSnapshot(pb)
            Log.importing.info("Datei-Versprechen: \(promises.count, privacy: .public)")
            receive(promises) { [weak self] files in
                guard let self else { return }
                if !files.isEmpty {
                    self.finish(files, completion)
                } else if !fileURLs.isEmpty {
                    Log.importing.info("Versprechen leer, nehme Dateiadressen")
                    self.importFiles(fileURLs, completion: completion)
                } else {
                    Log.importing.info("Versprechen leer, nehme übrige Inhalte")
                    self.importSnapshot(snapshot, completion: completion)
                }
            }
            return
        }

        // 2. Dateiadressen
        if !fileURLs.isEmpty {
            // Große Dateien aus dem Finder mit „Immer eine Kopie anlegen“: gleich zeigen,
            // im Hintergrund kopieren
            if showWhileCopying, alwaysCopy, onlyUserFiles {
                importShowingWhileCopying(fileURLs, completion: completion)
                return
            }
            importFiles(fileURLs, completion: completion)
            return
        }

        // 3.–5. Bilddaten und Bildobjekte, Web-Adressen, Text
        importSnapshot(PasteboardSnapshot(pb), completion: completion)
    }

    private func finish(_ files: [ShelfFile], _ completion: @escaping ([ShelfFile]) -> Void) {
        if Thread.isMainThread {
            completion(files)
        } else {
            DispatchQueue.main.async { completion(files) }
        }
    }

    // MARK: Dateien

    /// Gehört die Datei dem Nutzer (dann genügt ein Verweis)?
    /// Temporäre Ordner, ~/Library (App-Container, Caches) und Systemordner gehören nicht dazu,
    /// iCloud Drive und Cloud-Anbieter in ~/Library dagegen schon.
    static func isUserFile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") {
            return true
        }
        if path.hasPrefix(home + "/Library/") || path == home + "/Library" { return false }
        // Eigene Ordner des Nutzers, auch wenn sie „tmp“ oder „Caches“ heißen
        if path.hasPrefix(home + "/") { return true }
        // Außerhalb des Benutzerordners: temporäre Ordner von System, Browsern und Apps
        let lowered = path.lowercased()
        if lowered.contains("/tmp/") || lowered.contains("/temporaryitems/") || lowered.contains("/caches/") {
            return false
        }
        if path.hasPrefix("/Volumes/") || path.hasPrefix("/Users/Shared/") { return true }
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") { return true }
        return false
    }

    /// Dateien des Nutzers sofort als Verweis liefern und im Hintergrund kopieren.
    /// Ist eine Kopie fertig, tauscht die Ablage den Verweis gegen sie aus.
    private func importShowingWhileCopying(_ urls: [URL], completion: @escaping ([ShelfFile]) -> Void) {
        let placeholders = urls.map { ShelfFile(url: $0, owned: false) }
        finish(placeholders, completion)
        for (url, placeholder) in zip(urls, placeholders) {
            CloudFiles.whenDownloaded(url) { [weak self] _ in
                guard let self else { return }
                self.copyQueue.addOperation {
                    let copied = self.copyIntoStorage(url, foreign: false)
                    DispatchQueue.main.async { self.onCopyFinished(placeholder.id, copied) }
                }
            }
        }
    }

    /// Dateiadressen übernehmen: Dateien des Nutzers referenzieren, alles andere im
    /// Hintergrund kopieren. Die Reihenfolge bleibt erhalten.
    private func importFiles(_ urls: [URL], completion: @escaping ([ShelfFile]) -> Void) {
        let lock = NSLock()
        var results = [ShelfFile?](repeating: nil, count: urls.count)
        let group = DispatchGroup()

        for (index, url) in urls.enumerated() {
            let userFile = Self.isUserFile(url)
            if userFile && !alwaysCopy {
                results[index] = ShelfFile(url: url, owned: false)
                CloudFiles.requestDownload(url)     // damit Herausziehen später sofort klappt
                continue
            }
            group.enter()
            // Fremde Dateien (Browser, App-Container) löscht die Quelle oft gleich nach dem
            // Ablegen. Deshalb sofort klonen (auf APFS ohne Wartezeit), erst danach in Ruhe
            // im Hintergrund sauber schreiben.
            if !userFile, let staged = stage(url) {
                copyQueue.addOperation {
                    let copied = self.finishStaged(staged, name: url.lastPathComponent)
                    lock.lock()
                    results[index] = copied.map { ShelfFile(url: $0, owned: true) }
                    lock.unlock()
                    group.leave()
                }
                continue
            }
            CloudFiles.whenDownloaded(url) { [weak self] _ in
                guard let self else { group.leave(); return }
                self.copyQueue.addOperation {
                    // Eigene Dateien des Nutzers unverändert kopieren, fremde sauber neu schreiben
                    let copied = self.copyIntoStorage(url, foreign: !userFile)
                    lock.lock()
                    // Kopie einer Datei des Nutzers merkt sich ihr Original
                    results[index] = copied.map { userFile ? ShelfFile(copy: $0, of: url) : ShelfFile(url: $0, owned: true) }
                    lock.unlock()
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let files = results.compactMap { $0 }
            if files.count < urls.count {
                Log.importing.error("\(urls.count - files.count, privacy: .public) von \(urls.count, privacy: .public) Dateien nicht übernommen")
            }
            completion(files)
        }
    }

    /// Kopiert eine Datei in den eigenen Speicher (synchron, nicht auf dem Hauptthread
    /// aufrufen). Fremde Dateien werden dabei frisch geschrieben (nur die Daten, sonst
    /// Fehler −8060 beim Weiterziehen) und Bilder verträglich gemacht.
    func copyIntoStorage(_ url: URL, foreign: Bool = true) -> URL? {
        let fm = FileManager()
        let dir = newDirectory()
        let name = url.lastPathComponent.isEmpty ? L("Item", "Objekt") : url.lastPathComponent
        let target = dir.appendingPathComponent(name)
        // Erst unter einem Zwischennamen schreiben, dann umbenennen: nie eine halbe Datei in der Ablage
        let partial = dir.appendingPathComponent(".\(UUID().uuidString).partial")

        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)

        var coordinationError: NSError?
        var ok = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { source in
            if foreign && !isDir.boolValue {
                ok = FileSanitizer.cleanCopy(from: source, to: partial)
            } else {
                ok = (try? fm.copyItem(at: source, to: partial)) != nil
            }
        }
        guard ok, coordinationError == nil, (try? fm.moveItem(at: partial, to: target)) != nil else {
            Log.importing.error("Kopieren fehlgeschlagen: \(coordinationError?.localizedDescription ?? "", privacy: .public)")
            try? fm.removeItem(at: dir)
            return nil
        }
        return foreign ? ImageNormalizer.normalize(target, convert: convertImages) : target
    }

    /// Sofortiger Klon einer fremden Datei in einen eigenen Ordner (Hauptthread).
    /// nil, wenn das nicht ohne Kopieren möglich ist (z. B. anderes Laufwerk).
    private func stage(_ url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let dir = newDirectory()
        let staged = dir.appendingPathComponent(".staged-\(UUID().uuidString)")
        let result = url.withUnsafeFileSystemRepresentation { src in
            staged.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE))
            }
        }
        if result == 0 { return staged }
        // Anderes Laufwerk, Klonen geht nicht: kleine Dateien sofort kopieren, bevor die
        // Quelle sie löscht; große im Hintergrund (sonst stockt die Oberfläche)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if size <= 50_000_000, FileSanitizer.cleanCopy(from: url, to: staged) { return staged }
        try? fm.removeItem(at: dir)
        return nil
    }

    /// Macht aus einem Klon die endgültige, saubere Datei (Hintergrund).
    private func finishStaged(_ staged: URL, name: String) -> URL? {
        let fm = FileManager()
        let dir = staged.deletingLastPathComponent()
        let target = dir.appendingPathComponent(Self.sanitize(name.isEmpty ? L("Item", "Objekt") : name))
        defer { try? fm.removeItem(at: staged) }
        guard FileSanitizer.cleanCopy(from: staged, to: target) else {
            Log.importing.error("Sauber schreiben fehlgeschlagen")
            try? fm.removeItem(at: dir)
            return nil
        }
        return ImageNormalizer.normalize(target, convert: convertImages)
    }

    // MARK: Datei-Versprechen

    private func receive(_ promises: [NSFilePromiseReceiver], completion: @escaping ([ShelfFile]) -> Void) {
        let dir = newDirectory()
        let expected = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let state = PromiseCollector(expected: expected, directory: dir, completion: completion)
        let convert = convertImages

        for promise in promises {
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { received, error in
                var url: URL?
                if let error {
                    Log.importing.error("Versprechen nicht erfüllt: \(error.localizedDescription, privacy: .public)")
                } else if ImporterChecks.isUsableFile(received) {
                    // Vom Browser geschrieben: als saubere Datei neu anlegen
                    FileSanitizer.recreate(received)
                    url = ImageNormalizer.normalize(received, convert: convert)
                }
                state.add(url)
            }
        }
        // Nicht ewig warten, falls eine Quelle weniger Dateien liefert als angekündigt.
        // Großzügig bemessen: Fotos exportiert große Videos erst beim Ablegen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { state.complete() }
    }

    // MARK: Bilddaten, Links, Text

    private func importSnapshot(_ s: PasteboardSnapshot, completion: @escaping ([ShelfFile]) -> Void) {
        // Ohne „Als PNG oder JPEG speichern“ soll das Bild so bleiben, wie es im Web liegt.
        // Liegt im Pasteboard nur eine vom Browser gezeichnete Fassung (TIFF, Bildobjekt),
        // zuerst das Original von seiner Adresse laden; die Zeichnung nur als Rückfall.
        let renderedOnly = s.image?.1 == "tiff" || (s.image == nil && s.objectImage != nil)
        if !convertImages, renderedOnly, let source = s.imageSource {
            download(source) { [weak self] url in
                guard let self else { return }
                if let url {
                    self.finish([ShelfFile(url: url, owned: true)], completion)
                } else if let (data, ext) = s.image ?? s.objectImage,
                          let fallback = self.writeImage(data, ext: ext, name: s.suggestedImageName) {
                    self.finish([ShelfFile(url: fallback, owned: true)], completion)
                } else {
                    self.finish([], completion)
                }
            }
            return
        }

        // 3. Bilddaten direkt aus dem Pasteboard, sonst ein Bildobjekt (PDF, BMP …)
        if let (data, ext) = s.image ?? s.objectImage,
           let url = writeImage(data, ext: ext, name: s.suggestedImageName) {
            finish([ShelfFile(url: url, owned: true)], completion)
            return
        }

        // 4. Bildadresse (aus <img src> oder einem Link) herunterladen
        if let source = s.imageSource ?? s.webURL {
            download(source) { [weak self] url in
                guard let self else { return }
                if let url {
                    self.finish([ShelfFile(url: url, owned: true)], completion)
                } else if let link = s.webURL, let webloc = self.writeWebloc(link, title: s.urlTitle) {
                    // Kein Bild hinter der Adresse: als Link speichern
                    self.finish([ShelfFile(url: webloc, owned: true)], completion)
                } else {
                    Log.importing.error("Adresse ließ sich weder als Bild noch als Link speichern")
                    self.finish([], completion)
                }
            }
            return
        }

        // 5. Text
        if let text = s.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = writeText(text) {
            finish([ShelfFile(url: url, owned: true)], completion)
            return
        }
        Log.importing.info("Nichts Verwertbares im Pasteboard")
        finish([], completion)
    }

    func writeImage(_ data: Data, ext: String, name: String?) -> URL? {
        let dir = newDirectory()
        let base = Self.sanitize(name ?? L("Image \(Self.timestamp)", "Bild \(Self.timestamp)"))
        let raw = dir.appendingPathComponent("\(base).\(ext)")
        guard (try? data.write(to: raw)) != nil else { return nil }
        let url = ImageNormalizer.normalize(raw, convert: convertImages)
        guard ImporterChecks.isReadableImage(url) else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return url
    }

    /// Lädt eine Adresse herunter. Liefert nur dann eine Datei, wenn wirklich ein Bild zurückkommt.
    func download(_ source: URL, completion: @escaping (URL?) -> Void) {
        guard let scheme = source.scheme?.lowercased(), ["http", "https", "data"].contains(scheme) else {
            finishURL(nil, completion)
            return
        }
        var request = URLRequest(url: source, timeoutInterval: 20)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let convert = convertImages
        // Wächter: bricht ab, sobald klar ist, dass hinter der Adresse kein Bild steckt
        // (ZIP, Video, Disk-Image …) oder eine Datei unbekannten Typs zu groß wird.
        // Bilder werden nie abgebrochen; der Ablauf danach ist unverändert.
        let guardian = ObservationBox()
        let task = URLSession.shared.downloadTask(with: request) { [weak self] tmp, response, error in
            guardian.release()
            guard let self else { return }
            guard let tmp, error == nil else {
                Log.importing.error("Download fehlgeschlagen: \(error?.localizedDescription ?? "", privacy: .public)")
                self.finishURL(nil, completion)
                return
            }
            let mime = response?.mimeType?.lowercased() ?? ""
            let isImageResponse = mime.hasPrefix("image/") || ImporterChecks.isReadableImage(tmp)
            guard isImageResponse else {
                self.finishURL(nil, completion)
                return
            }

            let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "img"
            var base = source.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
            if base.isEmpty || base == "/" { base = L("Image \(Self.timestamp)", "Bild \(Self.timestamp)") }
            let dir = self.newDirectory()
            let raw = dir.appendingPathComponent("\(Self.sanitize(base)).\(ext)")
            do {
                try FileManager.default.moveItem(at: tmp, to: raw)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                self.finishURL(nil, completion)
                return
            }
            FileSanitizer.recreate(raw)
            let url = ImageNormalizer.normalize(raw, convert: convert)
            if ImporterChecks.isReadableImage(url) {
                self.finishURL(url, completion)
            } else {
                try? FileManager.default.removeItem(at: dir)
                self.finishURL(nil, completion)
            }
        }
        guardian.observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
            if Self.shouldStopDownload(response: task.response, received: task.countOfBytesReceived) {
                Log.importing.info("Kein Bild hinter der Adresse, Download abgebrochen")
                task.cancel()
            }
        }
        task.resume()
    }

    /// Ab dieser Größe wird eine Datei unbekannten Typs nicht weiter geladen.
    static let maxUnknownDownload: Int64 = 30_000_000

    /// Typen, die nie ein Bild sind: Hier lohnt kein einziges weiteres Byte.
    private static let nonImageTypes: Set<String> = [
        "application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
        "application/x-tar", "application/x-bzip2", "application/x-xz", "application/x-7z-compressed",
        "application/x-rar-compressed", "application/vnd.rar", "application/x-apple-diskimage",
        "application/x-msdownload", "application/vnd.android.package-archive", "application/x-iso9660-image"
    ]

    /// Soll ein laufender Download abgebrochen werden? Bilder nie; Archive, Videos und
    /// Audio sofort; alles andere (auch Webseiten und „application/octet-stream“, hinter
    /// dem sich oft Bilder verbergen) erst, wenn es zu groß wird.
    static func shouldStopDownload(response: URLResponse?, received: Int64) -> Bool {
        guard let response else { return false }
        let mime = (response.mimeType ?? "").lowercased()
        if mime.hasPrefix("image/") { return false }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") || nonImageTypes.contains(mime) { return true }
        return received > maxUnknownDownload || response.expectedContentLength > maxUnknownDownload
    }

    private func finishURL(_ url: URL?, _ completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async { completion(url) }
    }

    func writeWebloc(_ link: URL, title: String?) -> URL? {
        let dir = newDirectory()
        let url = dir.appendingPathComponent("\(Self.sanitize(title ?? link.host ?? "Link")).webloc")
        let plist = ["URL": link.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func writeText(_ text: String) -> URL? {
        let dir = newDirectory()
        let url = dir.appendingPathComponent("\(Self.sanitize(String(text.prefix(40)))).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    // MARK: Hilfen

    func newDirectory() -> URL {
        let dir = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Kein versteckter Name („.…“) und nicht zu lang
        let visible = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return visible.isEmpty ? L("Item", "Objekt") : String(visible.prefix(80))
    }

    static var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = L("yyyy-MM-dd 'at' HH.mm.ss", "yyyy-MM-dd 'um' HH.mm.ss")
        return f.string(from: Date())
    }
}

/// Hält die Beobachtung eines Downloads, bis er fertig ist.
private final class ObservationBox {
    private let lock = NSLock()
    private var _observation: NSKeyValueObservation?
    var observation: NSKeyValueObservation? {
        get { lock.lock(); defer { lock.unlock() }; return _observation }
        set { lock.lock(); _observation = newValue; lock.unlock() }
    }
    func release() {
        lock.lock(); let o = _observation; _observation = nil; lock.unlock()
        o?.invalidate()
    }
}

/// Sammelt empfangene Datei-Versprechen threadsicher und meldet genau einmal das Ergebnis.
private final class PromiseCollector {
    private let lock = NSLock()
    private let expected: Int
    private let directory: URL
    private let completion: ([ShelfFile]) -> Void
    private var finished = 0
    private var urls: [URL] = []
    private var done = false

    init(expected: Int, directory: URL, completion: @escaping ([ShelfFile]) -> Void) {
        self.expected = expected
        self.directory = directory
        self.completion = completion
    }

    func add(_ url: URL?) {
        lock.lock()
        finished += 1
        if let url { urls.append(url) }
        let all = finished >= expected
        lock.unlock()
        if all { complete() }
    }

    func complete() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let result = urls
        lock.unlock()
        if result.isEmpty { try? FileManager.default.removeItem(at: directory) }
        let completion = self.completion
        DispatchQueue.main.async { completion(result.map { ShelfFile(url: $0, owned: true) }) }
    }
}

enum ImporterChecks {
    static func isUsableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }
}

/// Kopie der relevanten Pasteboard-Inhalte, weil Drag-Pasteboards nach dem Drop ungültig werden.
struct PasteboardSnapshot {
    var image: (Data, String)?
    /// Bild, das nur als Bildobjekt vorliegt (z. B. PDF oder BMP), als PNG
    var objectImage: (Data, String)?
    /// Bildadresse aus HTML (<img src="…">), z. B. beim Ziehen aus Chrome oder Firefox
    var imageSource: URL?
    var webURL: URL?
    var urlTitle: String?
    var text: String?

    static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (NSPasteboard.PasteboardType("public.png"), "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"),
        (NSPasteboard.PasteboardType("public.avif"), "avif"),
        (.tiff, "tiff")
    ]

    /// Dateiname aus der Bildadresse, falls vorhanden
    var suggestedImageName: String? {
        let candidate = (imageSource ?? webURL)?.deletingPathExtension().lastPathComponent
        guard let candidate, !candidate.isEmpty, candidate != "/" else { return nil }
        return candidate.removingPercentEncoding ?? candidate
    }

    init(_ pb: NSPasteboard) {
        for (type, ext) in Self.imageTypes {
            if let data = pb.data(forType: type), !data.isEmpty {
                image = (data, ext)
                break
            }
        }
        if image == nil, let png = Self.objectImagePNG(pb) {
            objectImage = (png, "png")
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first(where: { !$0.isFileURL }) {
            webURL = first
        }
        if let html = pb.string(forType: .html) {
            imageSource = Self.imageSource(in: html, relativeTo: webURL)
        }
        urlTitle = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
        text = pb.string(forType: .string)
        if webURL == nil, let t = text, let u = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = u.scheme, ["http", "https"].contains(scheme), !t.contains(" ") {
            webURL = u
        }
    }

    /// Ein Bildobjekt, das AppKit aus dem Pasteboard lesen kann, als PNG.
    /// Nur wenn keine Dateien oder Adressen dabei sind (sonst wäre es nur ein Symbol).
    private static func objectImagePNG(_ pb: NSPasteboard) -> Data? {
        guard !pb.canReadObject(forClasses: [NSURL.self], options: nil),
              pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Sucht die erste Bildadresse in HTML.
    static func imageSource(in html: String, relativeTo base: URL?) -> URL? {
        let pattern = #"<img[^>]+src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let src = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: src, relativeTo: base)?.absoluteURL
    }
}
