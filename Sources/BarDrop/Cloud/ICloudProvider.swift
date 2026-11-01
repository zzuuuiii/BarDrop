import AppKit

/// iCloud Drive ohne Anmeldung: Die Datei kommt in den Ordner „BarDrop Share“ in iCloud
/// Drive, macOS lädt sie hoch, danach erzeugt macOS selbst den Link.
///
/// Den Link holt `osascript` (JavaScript für Automatisierung), nicht BarDrop selbst: Apple
/// erlaubt `URLForPublishingUbiquitousItemAtURL` nur Apps mit iCloud-Berechtigung, die
/// BarDrop nicht hat. Über osascript ging es im Plugin „BarDrop Share“ zuverlässig.
final class ICloudProvider: CloudProvider {
    static let shared = ICloudProvider()
    let service = CloudService.icloud

    /// Höchstens so lange aufs Hochladen warten
    private static let timeout = 3600

    private var drive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    var folder: URL { drive.appendingPathComponent(CloudService.folderName, isDirectory: true) }

    var isConfigured: Bool { true }
    var isConnected: Bool { FileManager.default.fileExists(atPath: drive.path) }
    var account: String? { nil }

    func connect() async throws {
        guard isConnected else {
            await MainActor.run {
                _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
            }
            throw CloudError(message: L("iCloud Drive is off on this Mac.", "iCloud Drive ist auf diesem Mac aus."),
                             hint: L("Turn it on in System Settings → Apple Account → iCloud → iCloud Drive.",
                                     "In Systemeinstellungen → Apple Account → iCloud → iCloud Drive einschalten."))
        }
    }

    func disconnect() {}

    func upload(_ file: URL, name: String, progress: @escaping (Double?, String?) -> Void) async throws -> URL {
        try await connect()
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        CloudFolderIcon.apply(to: folder)
        let target = ShelfActions.uniqueURL(for: name, in: folder)
        // Erst versteckt ablegen, dann umbenennen: iCloud lädt so nur die fertige Datei hoch
        let hidden = folder.appendingPathComponent(".laden-" + target.lastPathComponent)
        try? fm.removeItem(at: hidden)
        try fm.copyItem(at: file, to: hidden)
        try fm.moveItem(at: hidden, to: target)

        let size = OAuthCloudProvider.size(of: target)
        let label = L("Uploading", "Wird hochgeladen") + " · " + OAuthCloudProvider.sizeLabel(size)
        // Einen Prozentwert gibt macOS fremden Programmen nicht: Der Platzhalter atmet
        progress(nil, label)
        let line = try await Self.runPublish(target.path, timeout: Self.timeout)
        if line.hasPrefix("link "), let url = URL(string: String(line.dropFirst(5)).components(separatedBy: " ")[0]) {
            return url
        }
        var reason = line.hasPrefix("error ") ? String(line.dropFirst(6)) : line
        if reason == "timeout" { reason = L("Upload took longer than an hour.", "Hochladen dauerte länger als eine Stunde.") }
        if reason == "notubiquitous" { reason = L("The file isn’t in iCloud Drive.", "Die Datei liegt nicht in iCloud Drive.") }
        throw CloudError(message: L("Couldn’t create the link. ", "Link ließ sich nicht erzeugen. ") + reason,
                         hint: L("Check that iCloud Drive is syncing (Finder → iCloud Drive) and try again.",
                                 "Prüf, ob iCloud Drive synchronisiert (Finder → iCloud Drive), und versuch es noch einmal."))
    }

    func openFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        NSWorkspace.shared.open(folder)
    }

    /// Wartet aufs Hochladen und erzeugt den Link. Letzte Zeile: „link <url> <ablauf>“ oder „error <text>“
    private static let publishScript = """
    ObjC.import('Foundation');
    function value(url, key) {
      url.removeAllCachedResourceValues;
      var v = Ref();
      url.getResourceValueForKeyError(v, key, null);
      return (v[0] && !v[0].isNil()) ? v[0] : null;
    }
    function run(argv) {
      var url = $.NSURL.fileURLWithPath(argv[0]);
      var timeout = parseInt(argv[1], 10) * 1000, start = Date.now();
      var fm = $.NSFileManager.defaultManager;
      if (!fm.isUbiquitousItemAtURL(url)) return 'error notubiquitous';
      while (true) {
        var up = value(url, $.NSURLUbiquitousItemIsUploadedKey);
        if (up && ObjC.unwrap(up)) break;
        var err = value(url, $.NSURLUbiquitousItemUploadingErrorKey);
        if (err) return 'error ' + ObjC.unwrap(err.localizedDescription);
        if (Date.now() - start > timeout) return 'error timeout';
        delay(0.5);
      }
      var e = Ref(), d = Ref();
      var link = fm.URLForPublishingUbiquitousItemAtURLExpirationDateError(url, d, e);
      if (!link || link.isNil()) return 'error ' + ((e[0] && !e[0].isNil()) ? ObjC.unwrap(e[0].localizedDescription) : 'no link');
      var until = (d[0] && !d[0].isNil()) ? String(Math.round(d[0].timeIntervalSince1970)) : '0';
      return 'link ' + ObjC.unwrap(link.absoluteString) + ' ' + until;
    }
    """

    private static func runPublish(_ path: String, timeout: Int) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", publishScript, path, String(timeout)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { finished in
                    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let line = out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    // Beendet von `onCancel`
                    if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: line)
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            // Abbrechen beendet auch osascript (das Plugin ließ es weiterlaufen)
            if process.isRunning { process.terminate() }
        }
    }
}

/// Ordner „BarDrop Share“ mit dem Symbol von BarDrop: ein Ordner mit dem App-Symbol darauf,
/// wie macOS es bei den Ordnern von Apps zeigt. Bei iCloud Drive kommt es mit auf andere Macs.
enum CloudFolderIcon {
    static func apply(to folder: URL) {
        // Nur einmal: Ein neues Symbol schreibt eine versteckte Datei, die wieder hochgeladen würde
        let marker = folder.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: marker.path), let icon = make() else { return }
        DispatchQueue.main.async { NSWorkspace.shared.setIcon(icon, forFile: folder.path, options: []) }
    }

    static func make() -> NSImage? {
        guard let app = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage else { return nil }
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            folderIcon.draw(in: rect)
            // App-Symbol mittig auf der Vorderseite des Ordners, etwa wie bei „Programme“
            let side = rect.width * 0.42
            app.draw(in: NSRect(x: rect.midX - side / 2, y: rect.height * 0.2, width: side, height: side))
            return true
        }
    }
}
