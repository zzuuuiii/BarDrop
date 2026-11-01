import AppKit
import Combine

/// Diagnose für die Entwicklung: Bilder der Ablage, genau so, wie sie gerade auf dem
/// Bildschirm steht, in ~/Library/Logs/BarDrop/Bilder. Für Fehler, die nur zu sehen sind
/// (Kacheln, die nicht erscheinen, Symbole, die springen): Das Protokoll sagt, was die App
/// weiß, die Bilder, was davon gezeigt wird.
///
/// Die Bilder zeigen Dateinamen und Vorschaubilder. Das Diagnoseprotokoll verspricht, so
/// etwas nicht zu erfassen, darum gibt es sie nur, wenn der Ordner „Bilder“ dort schon
/// angelegt ist (von Hand, BarDrop legt ihn nie selbst an) und das Protokoll läuft.
/// Ausschalten des Protokolls löscht den Ordner samt Bildern.
enum ShelfSnapshots {
    static let directory: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BarDrop/Bilder", isDirectory: true)
    }()

    private static let keep = 60
    private static var counter = 0

    /// Bilder und Befehle sind eingeschaltet (siehe oben)
    static var isActive: Bool {
        var isDirectory: ObjCBool = false
        return Diagnostics.shared.isEnabled
            && FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Das Fenster jetzt und nach den angegebenen Verzögerungen aufnehmen
    static func capture(_ window: NSWindow?, _ reason: String, after delays: [TimeInterval] = [0, 0.3, 1]) {
        guard isActive, let window else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                save(window, "\(reason)+\(Int(delay * 1000))ms")
            }
        }
    }

    /// Bild des Fensters, wie es der Bildschirm zeigt (eigene Fenster brauchen dafür keine
    /// Erlaubnis). Über dlsym: Die Funktion ist im SDK als veraltet markiert, läuft aber.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// Aufnehmen und Speichern im Hintergrund: Auf dem Hauptthread kostete jedes Bild
    /// Zeit, und Animationen ruckelten, solange die Bilder eingeschaltet waren
    private static let queue = DispatchQueue(label: "BarDrop.Snapshots", qos: .utility)

    private static func save(_ window: NSWindow, _ name: String) {
        guard window.isVisible, let createImage else { return }
        let number = UInt32(window.windowNumber)
        counter += 1
        let index = counter
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withTime, .withColonSeparatorInTime])
        queue.async {
            // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
            guard let image = createImage(.null, 8, number, 1)?.takeRetainedValue() else {
                DispatchQueue.main.async { Diagnostics.shared.record("shot", "\(name) nicht möglich") }
                return
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let file = directory.appendingPathComponent(String(format: "%@ %03d %@.png", stamp, index % 1000, name)
                .replacingOccurrences(of: ":", with: "-"))
            try? data.write(to: file)
            prune()
            DispatchQueue.main.async { Diagnostics.shared.record("shot", file.lastPathComponent) }
        }
    }

    /// Zustand der Scrollbereiche im Fenster ins Protokoll (Größe des Inhalts, ob etwas
    /// aussteht, in welchem Modus die Ereignisschleife läuft), jetzt und nach den Verzögerungen
    static func describe(_ window: NSWindow?, _ reason: String, after delays: [TimeInterval]) {
        guard isActive, let window else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var parts: [String] = []
                func walk(_ view: NSView) {
                    if let scroll = view as? NSScrollView {
                        let doc = scroll.documentView
                        parts.append("scroll doc=\(Int(doc?.frame.height ?? -1)) clip=\(Int(scroll.contentView.bounds.minY))/\(Int(scroll.contentView.bounds.height)) docLayout=\(doc?.needsLayout ?? false) docDisplay=\(doc?.needsDisplay ?? false) subviews=\(doc?.subviews.count ?? -1) live=\(scroll.inLiveResize)")
                    }
                    view.subviews.forEach(walk)
                }
                if let content = window.contentView { walk(content) }
                let mode = RunLoop.current.currentMode?.rawValue ?? "–"
                Diagnostics.shared.record("shot", "\(reason)+\(Int(delay * 1000))ms mode=\(mode) key=\(window.isKeyWindow) \(parts.joined(separator: " | "))")
            }
        }
    }

    private static func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.dropLast(keep) { try? FileManager.default.removeItem(at: file) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Diagnose für die Entwicklung, eingeschaltet wie die Bilder (siehe ShelfSnapshots):
/// Schritte, die sonst nur mit der Maus gehen, aus einer Textdatei ausführen, damit sich ein
/// Fehler genau gleich wiederholen lässt. Liegt ~/Library/Logs/BarDrop/Befehl.txt vor, wird
/// sie gelesen, gelöscht und Zeile für Zeile ausgeführt: open, close, add <Pfad>,
/// folder <Pfad>, back, move <von> <nach>, shot <Name>, intro-shot <Name>, edge left|right,
/// intro [Schritt], wait <Sekunden>. Nachgesehen wird
/// nur, solange das Diagnoseprotokoll läuft.
final class DiagnosticCommands {
    /// Befehl „intro“: die Einführung öffnen (AppDelegate)
    static let showIntro = Notification.Name("BarDropDiagnoseIntro")
    private let controller: EdgeController
    private var timer: Timer?
    private var observer: AnyCancellable?
    private let file = ShelfSnapshots.directory.deletingLastPathComponent()
        .appendingPathComponent("Befehl.txt")

    init(controller: EdgeController) {
        self.controller = controller
        let settings = AppSettings.shared
        observer = settings.$diagnosticsEnabled.combineLatest(settings.$betaUpdates)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setPolling(on) }
    }

    private func setPolling(_ on: Bool) {
        timer?.invalidate()
        timer = on ? Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() } : nil
    }

    private func poll() {
        guard ShelfSnapshots.isActive,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        var delay: TimeInterval = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            if command == "wait" {
                delay += Double(argument) ?? 0
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.run(command, argument) }
        }
    }

    private func run(_ command: String, _ argument: String) {
        Diagnostics.shared.record("cmd", command)
        let actions = controller.actions
        let panel = controller.panel
        switch command {
        case "open":
            if controller.ui.level != .expanded { controller.toggle() }
        case "close":
            if controller.ui.level == .expanded { controller.close() }
        case "add":
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("BarDrop.diagnose.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects(argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) as NSURL })
            ShelfSnapshots.capture(panel, "add", after: [0.2, 0.6, 1.5, 3])
            ShelfSnapshots.describe(panel, "add", after: [0.05, 0.3, 1])
            controller.store.ingest(from: pasteboard, byUser: true)
        case "folder":
            actions.openFolder(URL(fileURLWithPath: argument))
        case "back":
            actions.closeFolder()
            ShelfSnapshots.capture(panel, "back", after: [0.1, 0.5, 1.5])
        case "move":
            let indices = argument.split(separator: " ").compactMap { Int($0) }
            let list = controller.settings.quickActions
            guard indices.count == 2, list.indices.contains(indices[0]), list.indices.contains(indices[1]) else { return }
            controller.settings.moveQuickAction(list[indices[0]].id, to: list[indices[1]].id)
            ShelfSnapshots.capture(panel, "move", after: [0.05, 0.2, 0.5])
        case "shot":
            ShelfSnapshots.capture(panel, argument.isEmpty ? "shot" : argument, after: [0])
        case "tear":
            // tear <Richtung in pt> <Schritte>: geradlinig weg vom Rand (negativ: zum anderen Rand)
            let values = argument.split(separator: " ").compactMap { Double($0) }
            let total = values.first ?? 300, steps = Int(values.count > 1 ? values[1] : 40)
            let away: CGFloat = controller.settings.edge == .right ? -1 : 1
            let points = (0...steps).map { NSPoint(x: away * CGFloat(total) * CGFloat($0) / CGFloat(steps), y: 0) }
            controller.simulateTear(path: points, shots: Set(stride(from: 0, through: steps, by: max(1, steps / 10))))
        case "intro-shot":
            // Fenster der Einführung (nur BarDrops eigenes Fenster, keine Bildschirmaufnahme)
            ShelfSnapshots.capture(NSApp.windows.first { $0 is IntroWindow }, argument.isEmpty ? "intro" : argument, after: [0])
        case "edge":
            if let edge = ScreenEdge(rawValue: argument) { controller.settings.edge = edge }
        case "intro":
            // Mit Nummer gleich zu diesem Schritt (0 = Willkommen)
            NotificationCenter.default.post(name: DiagnosticCommands.showIntro, object: Int(argument))
        default:
            Diagnostics.shared.record("cmd", "unbekannt")
        }
    }
}
