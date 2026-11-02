import AppKit
import CryptoKit
import OSLog
import QuickLookThumbnailing

/// Ausführliches Diagnoseprotokoll für Beta-Versionen. Standardmäßig aus; nur wer es unter
/// Über BarDrop selbst einschaltet (nach einem Hinweis), bekommt es. Alles bleibt auf diesem
/// Mac: BarDrop schickt nichts weg. Mit „Protokoll sichern“ entsteht eine Textdatei, die man
/// selbst weitergeben kann.
///
/// Anonym: Keine Datei- oder Ordnernamen, keine Pfade, keine Inhalte. Dateien erscheinen als
/// Kennung (kurzer Hash des Pfads, damit sich dieselbe Datei verfolgen lässt), Herkunft und
/// Dateiendung.
final class Diagnostics {
    static let shared = Diagnostics()

    /// Eingeschaltet (Einstellung, nur in Beta-Versionen wirksam)
    var isEnabled: Bool { AppSettings.shared.diagnosticsEnabled && AppSettings.shared.betaUpdates }

    private let queue = DispatchQueue(label: "BarDrop.diagnostics", qos: .utility)
    private let started = Date()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ~/Library/Logs/BarDrop/Diagnose.log (wird ab 4 MB in Diagnose-alt.log umbenannt)
    let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BarDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Diagnose.log")
    }()

    private init() {}

    // MARK: Festhalten

    /// Ein Ereignis festhalten. `category`: kurz, z. B. "drop", "edge", "intro".
    func record(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let line = "\(formatter.string(from: Date()))  [\(category)]  \(text)\n"
        queue.async { [logURL] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 4_000_000 {
                let old = logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: logURL, to: old)
            }
            if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                // Werfende Fassungen: Die alten lösen bei vollem Laufwerk eine Ausnahme aus, die
                // sich nicht abfangen lässt und BarDrop beendet
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }
    }

    // MARK: Fehler

    /// Einen Fehler mit Herkunft festhalten: was schiefging, Fehlerbereich und Code mit
    /// verständlichem Namen, der Text des Systems (Namen darin verdeckt), die zugrunde
    /// liegenden Fehler und die Stelle im Code. So lässt sich jeder Fehler zurückverfolgen.
    func failure(_ category: String, _ what: @autoclosure () -> String, _ error: Error? = nil,
                 file: String = #fileID, line: Int = #line, function: String = #function) {
        guard isEnabled else { return }
        let detail = error.map { " " + Self.describe($0) } ?? ""
        record(category, "FEHLER \(what())\(detail) @\(Self.shortFile(file)):\(line) \(function)")
    }

    /// Fehler ausführlich, aber ohne Datei- und Ordnernamen
    static func describe(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        var text = "\(ns.domain)#\(ns.code)"
        if let name = knownName(domain: ns.domain, code: ns.code) { text += " (\(name))" }
        text += " \"\(scrub(ns.localizedDescription))\""
        if let reason = ns.localizedFailureReason { text += " reason=\"\(scrub(reason))\"" }
        if depth < 3, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            text += " <- " + describe(underlying, depth: depth + 1)
        }
        return text
    }

    /// Verständliche Namen für häufige Fehlercodes
    static func knownName(domain: String, code: Int) -> String? {
        switch domain {
        case QLThumbnailError.errorDomain:
            return [0: "generationFailed", 1: "savingToURLFailed", 2: "noCachedThumbnail",
                    3: "noCloudThumbnail", 4: "requestInvalid", 5: "requestCancelled"][code]
        case NSCocoaErrorDomain:
            return [4: "fileNoSuchFile", 255: "fileLocking", 256: "fileReadUnknown", 257: "fileReadNoPermission",
                    258: "fileReadInvalidFileName", 259: "fileReadCorruptFile", 260: "fileReadNoSuchFile",
                    263: "fileReadTooLarge", 264: "fileReadUnknownStringEncoding", 512: "fileWriteUnknown",
                    513: "fileWriteNoPermission", 514: "fileWriteInvalidFileName", 516: "fileWriteFileExists",
                    517: "fileWriteInapplicableStringEncoding", 640: "fileWriteOutOfSpace",
                    642: "fileWriteVolumeReadOnly", 3072: "userCancelled", 3840: "propertyListReadCorrupt",
                    4864: "coderReadCorrupt", 4865: "coderValueNotFound"][code]
        case NSPOSIXErrorDomain:
            return String(cString: strerror(Int32(code)))
        case NSURLErrorDomain:
            return [-1001: "timedOut", -1003: "cannotFindHost", -1004: "cannotConnectToHost",
                    -1005: "networkConnectionLost", -1009: "notConnectedToInternet", -1011: "badServerResponse"][code]
        default:
            return nil
        }
    }

    /// Text ohne Namen und Pfade: Angaben in Anführungszeichen und Pfade werden verdeckt
    static func scrub(_ text: String) -> String {
        var out = text
        for pattern in ["“[^”]*”", "„[^“]*“", "‘[^’]*’", "\"[^\"]*\"", "'[^']*'", "(/Users|/Volumes|/private|/var|/tmp)/[^\\s,;)]*"] {
            out = out.replacingOccurrences(of: pattern, with: "•", options: .regularExpression)
        }
        return out.replacingOccurrences(of: "\n", with: " ")
    }

    /// Dateiname der Quelle ohne Modul, z. B. "Thumbnails.swift"
    static func shortFile(_ fileID: String) -> String {
        fileID.split(separator: "/").last.map(String.init) ?? fileID
    }

    /// Nicht abgefangene Ausnahmen (Absturzursache) festhalten. Schreibt sofort, ohne
    /// Warteschlange, weil das Programm danach endet.
    func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let d = Diagnostics.shared
            guard d.isEnabled else { return }
            let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n    ")
            let line = "\(d.formatter.string(from: Date()))  [crash]  FEHLER Ausnahme \(exception.name.rawValue) \"\(Diagnostics.scrub(exception.reason ?? ""))\"\n    \(stack)\n"
            if let handle = try? FileHandle(forWritingTo: d.logURL) {
                // Werfende Fassungen: Die alten lösen bei vollem Laufwerk eine Ausnahme aus, die
                // sich nicht abfangen lässt und BarDrop beendet
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }
    }

    /// Die letzten Absturzberichte von BarDrop, die macOS geschrieben hat (Pfade verdeckt)
    private func crashReports() -> [String] {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("BarDrop") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        guard !files.isEmpty else { return ["–"] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [String] = []
        for url in files.prefix(3) {
            out.append("### \(url.lastPathComponent.replacingOccurrences(of: NSUserName(), with: "•"))")
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text = text.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: NSUserName(), with: "•")
            out.append(String(text.prefix(60_000)))
        }
        return out
    }

    /// Protokoll löschen (beim Ausschalten)
    func clear() {
        ShelfSnapshots.clear()
        queue.async { [logURL] in
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log"))
        }
    }

    // MARK: Anonymisieren

    /// Datei als Kennung: Herkunft, kurzer Hash des Pfads und Endung, z. B. "user#3f9a1c.pdf"
    static func anon(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        return "\(origin(of: url))#\(digest)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func anon(_ urls: [URL]) -> String {
        urls.isEmpty ? "–" : urls.prefix(20).map { anon($0) }.joined(separator: ", ") + (urls.count > 20 ? " …+\(urls.count - 20)" : "")
    }

    /// Grobe Herkunft einer Datei, ohne den Ort zu verraten
    static func origin(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.contains("/Application Support/BarDrop/") { return "stored" }
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") { return "cloud" }
        if path.hasPrefix("/Volumes/") { return "volume" }
        if path.hasPrefix(NSTemporaryDirectory()) || path.contains("/T/") || path.contains("/tmp/") { return "temp" }
        if path.hasPrefix(home + "/") { return "user" }
        return "other"
    }

    // MARK: Bericht

    /// Bericht zum Sichern: Umgebung, Einstellungen, Zustand der Ablage, eigene Ereignisse und
    /// das Systemprotokoll von BarDrop seit dem Start (private Angaben bleiben verdeckt)
    func report(store: ShelfStore?) -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary
        // Volle Version mit Beta-Zusatz (CFBundleShortVersionString hat nur die Zahlen)
        let version = Updater.shared.currentVersion
        let build = info?["CFBundleVersion"] as? String ?? "?"
        out.append("BarDrop Diagnose / Diagnostics")
        out.append("Erstellt / Created: \(formatter.string(from: Date()))")
        out.append("")
        out.append("## Umgebung / Environment")
        out.append("BarDrop \(version) (\(build))")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        out.append("Mac: \(Self.sysctl("hw.model")), \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        out.append("Laufzeit / Uptime of BarDrop: \(Int(Date().timeIntervalSince(started))) s")
        out.append("Sprache / Language: \(AppSettings.shared.language.rawValue) → \(AppLanguage.current.rawValue), System: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        out.append("Aussehen / Appearance: \(NSApp.effectiveAppearance.name.rawValue)")
        for (i, screen) in NSScreen.screens.enumerated() {
            out.append("Bildschirm \(i + 1): \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, ×\(screen.backingScaleFactor)\(screen == NSScreen.main ? ", main" : "")")
        }
        out.append("Toneffekte / UI sounds: \(Sounds.interfaceSoundsEnabled)")
        out.append("")
        out.append("## Einstellungen / Settings")
        out.append(contentsOf: settingsSnapshot())
        out.append("")
        out.append("## Ablage / Shelf")
        out.append(contentsOf: shelfSnapshot(store))
        out.append("")
        out.append("## Ereignisse / Events (Diagnose.log)")
        let old = logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log")
        for url in [old, logURL] {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append(text) }
        }
        out.append("")
        out.append("## Systemprotokoll seit dem Start / System log since launch")
        out.append(contentsOf: systemLog())
        out.append("")
        out.append("## Absturzberichte / Crash reports")
        out.append(contentsOf: crashReports())
        return out.joined(separator: "\n")
    }

    private func settingsSnapshot() -> [String] {
        let s = AppSettings.shared
        var lines: [String] = [
            "edge=\(s.edge.rawValue) adaptive=\(s.adaptivePosition) zone=\(s.adaptiveZone) spot=\(s.verticalPosition) displays=\(s.displayMode.rawValue)",
            "openMode=\(s.openMode.rawValue) openDelay=\(s.openDelay) dragReveal=\(s.dragReveal.rawValue) fullScreen=\(s.openInFullScreen) excludedApps=\(s.excludedApps.count)",
            "size=\(Int(s.shelfWidth))×\(Int(s.shelfHeight)) icon=\(Int(s.tileIconSize)) strip=\(s.peekThickness)/\(s.peekLength) outline=\(s.showOutline) animation=\(s.animationStyle.rawValue) reduceMotion=\(AnimationStyle.reduceMotion)",
            "stacks=\(s.stackMultiple ? String(s.stackThreshold) : "off") reopenWhereLeft=\(s.reopenWhereLeft) removeAfterDragOut=\(s.removeAfterDragOut) keepAfterAction=\(s.keepAfterAction) dragOutCopyOnly=\(s.dragOutCopyOnly)",
            "finderFiles=\(s.copyAllFiles ? "copy" : "original") webAsPNGorJPEG=\(s.convertWebImages) screenshots=\(s.addScreenshots) airdrop=\(s.addAirDrop) autoRemove=\(Int(s.autoRemoveAfter))s",
            "actions=\(s.quickActions.map(\.kind.rawValue).joined(separator: ",")) split=\(s.effectiveActionSplit) actionIcon=\(Int(s.actionIconSize)) labels=\(s.showActionLabels ? (s.labelsOnlyFolders ? "folders" : "all") : "none") pin=\(s.pinFromShelf)",
            "hotKey=\(s.hotKeyDescription) haptics=\(s.hapticsEnabled) autoUpdate=\(s.autoUpdateCheck) beta=\(s.betaUpdates) introDone=\(s.didLaunchBefore)"
        ]
        lines.append("trashFull=\(TrashState.shared.isFull)")
        return lines
    }

    private func shelfSnapshot(_ store: ShelfStore?) -> [String] {
        guard let store else { return ["–"] }
        let files = store.entries.flatMap(\.files)
        var byExt: [String: Int] = [:]
        for f in files { byExt[f.url.pathExtension.lowercased().isEmpty ? "(none)" : f.url.pathExtension.lowercased(), default: 0] += 1 }
        var byOrigin: [String: Int] = [:]
        for f in files { byOrigin[Self.origin(of: f.url), default: 0] += 1 }
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
        return [
            "entries=\(store.entries.count) stacks=\(store.entries.filter(\.isStack).count) files=\(files.count) owned=\(files.filter(\.owned).count) missing=\(missing) pendingImports=\(store.pendingImports)",
            "byType: " + byExt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            "byOrigin: " + byOrigin.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            "items: " + Self.anon(files.map(\.url))
        ]
    }

    /// Einträge von BarDrop im Systemprotokoll seit dem Start dieses Programms. Was dort
    /// als privat markiert ist (Namen, Pfade), liefert macOS nur verdeckt.
    private func systemLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(nicht lesbar / not readable)"] }
        let subsystem = Bundle.main.bundleIdentifier ?? "com.zzuuuiii.bardrop"
        let position = store.position(date: started)
        guard let entries = try? store.getEntries(at: position,
                                                  matching: NSPredicate(format: "subsystem == %@", subsystem)) else {
            return ["(nicht lesbar / not readable)"]
        }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date))  [\(entry.category)] \(Self.levelName(entry.level))  \(entry.composedMessage)")
            if lines.count > 4000 { lines.append("…"); break }
        }
        return lines.isEmpty ? ["–"] : lines
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "FEHLER"
        case .fault: return "FEHLER(fault)"
        default: return "undefined"
        }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: Sichern

    /// Fragt nach einem Ort und schreibt den Bericht dorthin
    func saveReport(store: ShelfStore?) {
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = "BarDrop-Diagnose-\(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = report(store: store)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
