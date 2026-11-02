import CryptoKit
import Foundation

/// Programme, die Plugins brauchen (im Manifest unter `tools`). BarDrop bringt keines
/// davon mit: Sie werden erst nach Zustimmung geladen, geprüft und unter
/// ~/Library/Application Support/BarDrop/Tools abgelegt. Je Programm und Download-Adresse
/// gibt es einen eigenen Ordner: Plugins teilen sich ein Programm nur, wenn es dieselbe
/// Datei von derselben Adresse ist, und überschreiben sich nicht gegenseitig.
final class PluginTools {
    let directory: URL

    private let loadLock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    /// Ordner aller geladenen Programme (für PATH beim Starten von Programmen)
    func folders(for tools: [PluginTool]) -> [String] {
        tools.map { folder($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
    }

    private struct Meta: Codable {
        var url: String
        var sha256: String
        var fetched: Date
        /// „Programme aktualisieren“: beim nächsten Gebrauch neu laden, ohne erneut zu fragen
        var outdated: Bool?
    }

    /// Ordner aller geladenen Programme, auch anderer Plugins (für die Suche nach Programmen)
    func sharedFolders() -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.path).sorted()
    }

    /// „Programme aktualisieren“: Diese Programme gelten als veraltet und werden beim nächsten
    /// `ensure` neu geladen (ohne Frage, da von derselben Adresse)
    func markOutdated(_ tools: [PluginTool]) {
        for tool in tools {
            guard var meta = storedMeta(of: tool) else { continue }
            meta.outdated = true
            try? JSONEncoder().encode(meta).write(to: folder(tool).appendingPathComponent("meta.json"))
        }
    }

    /// Dasselbe Programm (gleiche Adresse, gleiche Prüfsumme, noch gültig), das ein anderes
    /// Plugin unter anderem Namen schon geladen hat: wird mitbenutzt statt neu geladen
    private func sharedCopy(of tool: PluginTool) -> (binary: URL, meta: Meta)? {
        let fm = FileManager.default
        for path in sharedFolders() where path != folder(tool).path {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data),
                  meta.url == tool.resolvedURL, meta.outdated != true else { continue }
            if let pinned = tool.sha256, pinned.lowercased() != meta.sha256 { continue }
            if let days = tool.refreshDays, Date().timeIntervalSince(meta.fetched) > Double(max(days, 1)) * 86_400 { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard let binary = files.first(where: { $0.lastPathComponent != "meta.json" && fm.isExecutableFile(atPath: $0.path) }),
                  PluginPackage.sha256(of: binary)?.lowercased() == meta.sha256 || tool.archive == "zip" else { continue }
            return (binary, meta)
        }
        return nil
    }

    enum ToolError: Error {
        case declined
        case download(String)
        case checksum

        var message: String {
            switch self {
            case .declined: return L("The program wasn’t downloaded.", "Das Programm wurde nicht geladen.")
            case .download(let text): return L("Downloading the program didn’t work: \(text)", "Das Programm ließ sich nicht laden: \(text)")
            case .checksum: return L("The downloaded program didn’t match its checksum and was deleted.",
                                     "Das geladene Programm passte nicht zu seiner Prüfsumme und wurde gelöscht.")
            }
        }
    }

    private func folder(_ tool: PluginTool) -> URL {
        let source = SHA256.hash(data: Data(tool.resolvedURL.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(PluginTools.safeName(tool.id) + "-" + source, isDirectory: true)
    }

    /// Ordner aus älteren Fassungen (nur nach `id` benannt)
    private func legacyFolder(_ tool: PluginTool) -> URL {
        directory.appendingPathComponent(PluginTools.safeName(tool.id), isDirectory: true)
    }

    /// Ein Programm wurde geladen oder mitbenutzt (auf irgendeinem Thread)
    var onLoaded: (() -> Void)?

    /// Namen der Ordner, die zu diesem Programm gehören können (ob vorhanden oder nicht)
    func folderNames(_ tool: PluginTool) -> [String] {
        [folder(tool).lastPathComponent, legacyFolder(tool).lastPathComponent]
    }

    /// Ordner, in denen dieses Programm liegt (auch veraltet oder aus älteren Fassungen), zum
    /// Entfernen mit dem Plugin
    func storedFolders(_ tool: PluginTool) -> [URL] {
        [folder(tool), legacyFolder(tool)].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func storedMeta(of tool: PluginTool) -> Meta? {
        guard let data = try? Data(contentsOf: folder(tool).appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func binary(_ tool: PluginTool) -> URL {
        folder(tool).appendingPathComponent(PluginTools.safeName(tool.id))
    }

    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.hasPrefix(".") ? "tool" + cleaned : cleaned
    }

    /// Schon geladen und noch gültig?
    func installed(_ tool: PluginTool) -> URL? {
        let url = binary(tool)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let meta = storedMeta(of: tool), meta.url == tool.resolvedURL else { return nil }
        if let pinned = tool.sha256, pinned.lowercased() != meta.sha256 { return nil }
        // Höchstens einmal am Tag neu laden: 0 oder weniger hieß sonst bei jedem Lauf
        if let days = tool.refreshDays, Date().timeIntervalSince(meta.fetched) > Double(max(days, 1)) * 86_400 { return nil }
        if meta.outdated == true { return nil }
        return url
    }

    /// Liefert das Programm; lädt es beim ersten Mal nach Zustimmung (`ask`, auf dem
    /// Hauptthread gezeigt). Blockiert den aufrufenden (Hintergrund-)Thread.
    /// `owner`: Plugin, für das geladen wird (fürs Protokoll); `progress`: Anteil 0…1 beim Laden.
    func ensure(_ tool: PluginTool, owner: String = "", ask: () -> Bool, cancelled: () -> Bool,
                progress: (Double) -> Void = { _ in }) throws -> URL {
        // Mehrere Plugins gleichzeitig (z. B. zwei abgelegte Links): nur einer lädt, die
        // anderen warten und nehmen dann die fertige Datei
        loadLock.lock()
        defer { loadLock.unlock() }
        if let url = installed(tool) { return url }
        // Ein veraltetes Programm von derselben Adresse (z. B. „latest“ nach `refreshDays`)
        // wird ohne erneute Frage aktualisiert. Eine neue Adresse fragt immer.
        let sameSource = FileManager.default.fileExists(atPath: binary(tool).path)
            && storedMeta(of: tool)?.url == tool.resolvedURL
        // Während des Wartens auf ein anderes Plugin abgebrochen: nicht mehr fragen (sonst kam
        // die Frage zum Laden noch für einen Lauf, den es nicht mehr gibt). Der Lauf ist dann
        // schon beendet, der Fehler wird nicht mehr gezeigt
        if cancelled() { throw ToolError.declined }
        guard sameSource || ask() else { throw ToolError.declined }
        let who = owner.isEmpty ? tool.id : owner
        // Hat ein anderes Plugin dasselbe Programm schon geladen: mitbenutzen statt laden
        // (Nicht beim Aktualisieren: Dann soll es wirklich neu geladen werden)
        if storedMeta(of: tool)?.outdated != true, let shared = sharedCopy(of: tool) {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder(tool), withIntermediateDirectories: true)
            let target = binary(tool)
            try? fm.removeItem(at: target)
            do {
                // Feste Verknüpfung: kein zweiter Platz auf der Platte; geht das nicht, Kopie
                do { try fm.linkItem(at: shared.binary, to: target) } catch { try fm.copyItem(at: shared.binary, to: target) }
                try JSONEncoder().encode(shared.meta).write(to: folder(tool).appendingPathComponent("meta.json"))
                PluginLog.shared.record(who, "programm", "\(tool.id): von einem anderen Plugin mitbenutzt (\(shared.meta.sha256.prefix(12)))")
                onLoaded?()
                return target
            } catch {
                try? fm.removeItem(at: target)   // dann eben laden
            }
        }
        PluginLog.shared.record(who, "programm", "\(tool.id): lade \(tool.resolvedURL)")
        let started = Date()
        let expected = try expectedChecksum(tool)
        // validate() hat die Adresse schon geprüft; trotzdem kein Absturz, falls nicht
        guard let source = URL(string: tool.resolvedURL) else { throw ToolError.download(tool.resolvedURL) }
        let file: URL
        do {
            file = try fetch(source, cancelled: cancelled, progress: progress)
        } catch {
            PluginLog.shared.record(who, "programm", "\(tool.id): Laden nach \(String(format: "%.1f", Date().timeIntervalSince(started))) s beendet: \((error as? ToolError)?.message ?? error.localizedDescription)")
            throw error
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        defer { try? FileManager.default.removeItem(at: file) }
        guard PluginPackage.sha256(of: file)?.lowercased() == expected else {
            PluginLog.shared.record(who, "programm", "\(tool.id): Prüfsumme passt nicht, gelöscht")
            throw ToolError.checksum
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(tool), withIntermediateDirectories: true)
        let target = binary(tool)
        try? fm.removeItem(at: target)
        if tool.archive == "zip", let inner = tool.executable {
            // Archiv: entpacken, das genannte Programm übernehmen, den Rest verwerfen
            let unpacked = fm.temporaryDirectory.appendingPathComponent("BarDropTool-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: unpacked) }
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            do {
                try PluginPackage.extract(file, to: unpacked)
            } catch {
                throw ToolError.download(L("The archive can’t be unpacked.", "Das Archiv lässt sich nicht entpacken."))
            }
            let source = unpacked.appendingPathComponent(inner).standardizedFileURL
            guard source.path.hasPrefix(unpacked.standardizedFileURL.path + "/"),
                  fm.fileExists(atPath: source.path) else {
                throw ToolError.download(L("“\(inner)” is missing in the archive.", "„\(inner)“ fehlt im Archiv."))
            }
            try fm.moveItem(at: source, to: target)
        } else {
            try fm.moveItem(at: file, to: target)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        removexattr(target.path, "com.apple.quarantine", 0)
        let meta = Meta(url: tool.resolvedURL, sha256: expected, fetched: Date())
        try JSONEncoder().encode(meta).write(to: folder(tool).appendingPathComponent("meta.json"))
        // Fassung aus dem alten, nur nach `id` benannten Ordner wird nicht mehr gebraucht
        try? fm.removeItem(at: legacyFolder(tool))
        PluginLog.shared.record(who, "programm", "\(tool.id): geladen und geprüft, \(size / 1_000_000) MB in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(expected.prefix(12)))")
        onLoaded?()
        return target
    }

    private func expectedChecksum(_ tool: PluginTool) throws -> String {
        if let pinned = tool.sha256 { return pinned.lowercased() }
        guard let source = tool.resolvedChecksums.flatMap(URL.init(string:)) else { throw ToolError.checksum }
        let semaphore = DispatchSemaphore(value: 0)
        var text: String?
        URLSession.shared.dataTask(with: source) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { text = data.flatMap { String(data: $0, encoding: .utf8) } }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        let name = URL(string: tool.resolvedURL)?.lastPathComponent ?? ""
        guard let text, let sum = Self.checksum(in: text, for: name) else { throw ToolError.checksum }
        return sum
    }

    /// Zeile „<sha256>  <Dateiname>“ (oder „<sha256> *<Dateiname>“) für die Datei
    static func checksum(in list: String, for name: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var file = String(parts[1])
            if file.hasPrefix("*") { file.removeFirst() }
            let sum = parts[0].lowercased()
            if file == name, sum.count == 64, sum.allSatisfy(\.isHexDigit) { return sum }
        }
        return nil
    }

    private func fetch(_ url: URL, cancelled: () -> Bool, progress: (Double) -> Void) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(ToolError.download(""))
        let task = URLSession.shared.downloadTask(with: url) { file, response, error in
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: file, to: kept)
                    result = .success(kept)
                } catch {
                    result = .failure(ToolError.download(error.localizedDescription))
                }
            } else {
                result = .failure(ToolError.download(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            semaphore.signal()
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelled() { task.cancel() }
            let expected = task.countOfBytesExpectedToReceive
            if expected > 0 { progress(Double(task.countOfBytesReceived) / Double(expected)) }
        }
        return try result.get()
    }
}
