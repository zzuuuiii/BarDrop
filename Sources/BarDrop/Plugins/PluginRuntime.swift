import AppKit
import UniformTypeIdentifiers
import JavaScriptCore

/// Fragen an den Nutzer, die ein laufendes Plugin auslösen kann (immer auf dem Hauptthread).
protocol PluginPrompter: AnyObject {
    /// Ein Plugin möchte ein Recht zum ersten Mal nutzen
    func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool
    /// Ein Plugin braucht ein Programm, das erst geladen werden muss
    func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool
}

/// Ein laufendes Plugin: Fortschritt für den Platzhalter in der Ablage, Anhalten,
/// Fortsetzen und Abbrechen über den Rechtsklick.
final class PluginJob: ObservableObject, Identifiable {
    let id = UUID()
    let plugin: InstalledPlugin
    let item: PluginItem
    /// Alle Objekte des Laufs: bei `batch` mehrere, sonst nur `item`
    let items: [PluginItem]
    /// Dateien der Ablage, für die der Lauf ist (die erste ist `anchorFileID`)
    let fileIDs: [UUID]
    /// Datei der Ablage, neben der das Ergebnis erscheint
    let anchorFileID: UUID
    let automatic: Bool
    /// Das Ergebnis ersetzt das Original („Original ersetzen“, beim Start festgelegt):
    /// Dann steht der Platzhalter an der Stelle des Originals, das solange nicht zu sehen ist
    let replacesOriginal: Bool
    /// 0…1, nil solange das Plugin keinen Fortschritt meldet
    @Published fileprivate(set) var progress: Double?
    @Published fileprivate(set) var label: String?
    @Published fileprivate(set) var paused = false
    /// Datei, die das Plugin schon als Ergebnis geschrieben hat (sobald sie nicht mehr wächst):
    /// Der Platzhalter zeigt dann sie statt der Ausgangsdatei
    @Published var resultPreview: URL?
    /// Art der Datei, die gerade entsteht (auch halb geschrieben, etwa „film.mp4.part“):
    /// Der Platzhalter zeigt ihr Symbol, bis `resultPreview` da ist
    @Published var resultType: UTType?
    /// Gescheitert: Der Platzhalter rüttelt kurz, bevor er verschwindet
    @Published var failed = false
    /// Vom Nutzer abgebrochen (x am Platzhalter, ⌫, Menü), nicht beim Beenden von BarDrop
    var cancelledByUser = false
    /// Zu sehen erst nach einem Augenblick: Ein Lauf, der sofort fertig ist (etwa ein Plugin,
    /// das nichts zu tun hat), blitzt so nicht als Platzhalter auf
    var shown = false

    fileprivate weak var runtime: PluginRuntime?
    /// Letzte Meldung an die Oberfläche (höchstens alle 100 ms, sonst zeichnet die Ablage zu oft)
    private var lastPublished = Date.distantPast
    /// Letztes erzwungenes Neuzeichnen der ganzen Ablage. Das kostet viel und unterbricht
    /// laufende Animationen (das Atmen flackerte): nur bei sichtbarer Änderung, höchstens
    /// zweimal pro Sekunde
    private var lastRedraw = Date.distantPast
    private var lastRedrawPercent: Int?

    convenience init(plugin: InstalledPlugin, item: PluginItem, anchorFileID: UUID, automatic: Bool, replacesOriginal: Bool = false) {
        self.init(plugin: plugin, items: [(item, anchorFileID)], automatic: automatic, replacesOriginal: replacesOriginal)
    }

    /// Ein Lauf für mehrere Objekte (`batch`); das Ergebnis erscheint neben dem ersten
    init(plugin: InstalledPlugin, items: [(item: PluginItem, fileID: UUID)], automatic: Bool, replacesOriginal: Bool = false) {
        precondition(!items.isEmpty)
        self.plugin = plugin
        self.item = items[0].item
        self.items = items.map(\.item)
        self.fileIDs = items.map(\.fileID)
        self.anchorFileID = items[0].fileID
        self.automatic = automatic
        self.replacesOriginal = replacesOriginal
    }

    var title: String { plugin.manifest.title }

    /// Läuft schon (sonst wartet es, weil schon drei Plugins laufen)
    @Published fileprivate(set) var isStarted = false

    /// Fortschritt in Prozent für Menüs, nil ohne Angabe
    var percent: Int? { progress.map { Int(($0 * 100).rounded()) } }

    func pause() { runtime?.setPaused(true) }
    func resume() { runtime?.setPaused(false) }
    func cancel() { runtime?.cancel() }

    func report(_ value: Double?, label newLabel: String?, force: Bool = false) {
        let clamped = value.map { min(max($0, 0), 1) }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) > 0.1 || clamped == 1 else { return }
        lastPublished = now
        if clamped != progress { progress = clamped }
        // Leerer Text nimmt die Beschriftung zurück (dann steht wieder der Name da)
        var labelChanged = false
        if let newLabel {
            let value = newLabel.isEmpty ? nil : newLabel
            if value != label { label = value; labelChanged = true }
        }
        let shownPercent = percent
        guard labelChanged || force || clamped == 1
              || (shownPercent != lastRedrawPercent && now.timeIntervalSince(lastRedraw) > 0.5) else { return }
        lastRedraw = now
        lastRedrawPercent = shownPercent
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
    }

    fileprivate func setPausedState(_ value: Bool) {
        paused = value
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
    }
}

enum PluginRunError: Error, Equatable {
    case cancelled
    /// Fehler im Skript; `hint` ist ein Tipp des Plugins (`throw { message, hint }`), den
    /// BarDrop abgesetzt unter der Meldung zeigt
    case script(String, hint: String? = nil)
    case permissionDenied(PluginPermission)

    var message: String {
        switch self {
        case .cancelled: return L("Canceled", "Abgebrochen")
        case .script(let text, _): return text
        case .permissionDenied(let p): return L("Not allowed: \(p.title)", "Nicht erlaubt: \(p.title)")
        }
    }

    var hint: String? {
        if case .script(_, let hint) = self { return hint }
        return nil
    }
}

/// Führt das Skript eines Plugins in JavaScriptCore aus, in einem eigenen, kurzlebigen
/// Kontext auf einer eigenen Warteschlange. Das Skript sieht nur `bardrop`: Dateien schreibt
/// es nur in seinen Ausgabeordner, alles Weitere (Internet, Programme, Zwischenablage)
/// geht über Rechte, die beim ersten Gebrauch erfragt werden.
///
/// Was am Ende im Ausgabeordner liegt, wird zu neuen Objekten neben dem Original.
final class PluginRuntime {
    let job: PluginJob
    private let plugin: InstalledPlugin
    private let workDirectory: URL
    let outputDirectory: URL
    private let tools: PluginTools
    private weak var prompter: PluginPrompter?
    private let queue: DispatchQueue
    /// Beim Start auf dem Hauptthread festgehalten: Das Skript läuft im Hintergrund und
    /// liest die Verwaltung nicht selbst
    private let settingsValues: [String: Any]
    private var granted: Set<PluginPermission>
    /// Programme, deren Download schon erlaubt ist (gilt auch ohne Rückfrage)
    private var approvedTools: Set<String>
    private let onGrant: (PluginPermission) -> Void
    private let onToolApproved: (String) -> Void
    private let onNotify: (String) -> Void

    private var context: JSContext?
    /// Beim Start festgehalten (Updater gehört dem Hauptthread)
    private let appVersion = Updater.shared.currentVersion
    /// Nur unter `lock`: Abbrechen meldet das Ende vom Hauptthread aus, auch wenn das
    /// Skript seine Warteschlange nie wieder freigibt (Endlosschleife)
    private var completion: ((Result<[URL], PluginRunError>) -> Void)?
    /// Kommt auf dem Hauptthread, sobald alle gestarteten Programme beendet sind (erst
    /// dann darf der Arbeitsordner weg). Immer nach `completion`.
    var onStopped: (() -> Void)?

    /// Eigene Sitzung je Lauf: keine Cookies und kein Zwischenspeicher mit BarDrop oder
    /// anderen Plugins, alles verschwindet mit dem Lauf
    private let session = URLSession(configuration: .ephemeral)

    private let lock = NSLock()
    /// Nach dem Ende des Laufs (auch Abbrechen) beendet der Wächter das Skript, selbst
    /// mitten in einer Endlosschleife (siehe ScriptWatchdog)
    private let stopFlag = ScriptWatchdog.StopFlag()
    /// Skripte, die gerade rechnen (nicht nur auf etwas warten), über alle Läufe; für Tests
    private static let busyLock = NSLock()
    private static var _busyScripts = 0
    static var busyScripts: Int { busyLock.lock(); defer { busyLock.unlock() }; return _busyScripts }
    private static func changeBusy(_ delta: Int) { busyLock.lock(); _busyScripts += delta; busyLock.unlock() }
    private var processes: [PluginProcess] = []
    private var tasks: [URLSessionTask] = []
    private var _cancelled = false
    private var _paused = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// Der Lauf ist zu Ende (fertig, gescheitert oder abgebrochen)
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return completion == nil }

    init(job: PluginJob, workDirectory: URL, tools: PluginTools, prompter: PluginPrompter?,
         settingsValues: [String: Any], granted: Set<PluginPermission>, approvedTools: Set<String> = [],
         onGrant: @escaping (PluginPermission) -> Void, onToolApproved: @escaping (String) -> Void = { _ in },
         onNotify: @escaping (String) -> Void) {
        self.job = job
        self.plugin = job.plugin
        self.workDirectory = workDirectory
        self.outputDirectory = workDirectory.appendingPathComponent("Output", isDirectory: true)
        self.tools = tools
        self.prompter = prompter
        self.settingsValues = settingsValues
        self.granted = granted
        self.approvedTools = approvedTools
        self.onGrant = onGrant
        self.onToolApproved = onToolApproved
        self.onNotify = onNotify
        self.queue = DispatchQueue(label: "BarDrop.plugin.\(job.plugin.id)", qos: .userInitiated)
        job.runtime = self
        job.isStarted = true
    }

    // MARK: Start und Ende

    /// Startet das Skript. `completion` kommt auf dem Hauptthread, genau einmal.
    func start(completion: @escaping (Result<[URL], PluginRunError>) -> Void) {
        lock.lock(); self.completion = completion; lock.unlock()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        queue.async { [self] in
            Self.changeBusy(1)
            defer { Self.changeBusy(-1) }
            let vm = JSVirtualMachine()
            guard let context = JSContext(virtualMachine: vm) else {
                return finish(.failure(.script("JavaScriptCore")))
            }
            self.context = context
            ScriptWatchdog.install(on: context, flag: stopFlag)
            context.name = plugin.manifest.name.text(for: .english)
            context.exceptionHandler = { [weak self] _, exception in
                self?.finish(.failure(.script(PluginRuntime.describe(exception), hint: PluginRuntime.hint(of: exception))))
            }
            installAPI(in: context)
            // console.log & Co. landen im Diagnoseprotokoll (JavaScriptCore kennt kein console)
            context.evaluateScript("""
            var console = (function () {
              function line(args) { return Array.prototype.map.call(args, function (a) {
                try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }).join(' '); }
              return { log: function () { bardrop.log(line(arguments)); },
                       info: function () { bardrop.log(line(arguments)); },
                       warn: function () { bardrop.log('warn: ' + line(arguments)); },
                       error: function () { bardrop.log('error: ' + line(arguments)); } };
            })();
            """)
            // URL, setTimeout, TextEncoder, Binärdaten & Co. (siehe PluginPrelude)
            context.evaluateScript(PluginPrelude.source, withSourceURL: URL(string: "bardrop-prelude.js"))
            context.evaluateScript(plugin.script, withSourceURL: plugin.scriptURL)
            guard !isFinished else { return }
            // Als Name prüfen, nicht als Eigenschaft des globalen Objekts: `const run = …`
            // und `let run = …` liegen nicht auf dem globalen Objekt, sind aber gültig
            guard context.evaluateScript("typeof run === 'function'")?.toBool() == true else {
                return finish(.failure(.script(L("The script has no function “run”.", "Im Skript fehlt die Funktion „run“."))))
            }
            // Zweites Argument: alle Objekte des Laufs (bei `batch` mehrere, sonst nur `item`)
            let bootstrap = """
            (function (item, items) {
              return Promise.resolve().then(function () { return run(item, items); })
                .then(function () { __bardropDone(); },
                      function (e) { __bardropFail(e); });
            })
            """
            context.evaluateScript(bootstrap)?.call(withArguments: [job.item.scriptValue, job.items.map(\.scriptValue)])
        }
    }

    /// Fehlermeldung eines Skripts: Text, bei Fehlern im Skript mit Datei und Zeile
    /// („TypeError: … (main.js:12)“), damit man die Stelle findet
    /// Tipp zu einem Fehler: Eigenschaft `hint` des geworfenen Objekts (Text, höchstens 300 Zeichen)
    static func hint(of error: JSValue?) -> String? {
        guard let error, error.isObject, error.hasProperty("hint"),
              let value = error.forProperty("hint"), value.isString else { return nil }
        let text = (value.toString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }

    static func describe(_ error: JSValue?) -> String {
        guard let error, !error.isUndefined, !error.isNull else { return "Error" }
        guard error.isObject, error.hasProperty("message") else { return error.toString() ?? "Error" }
        let message = error.forProperty("message")?.toString() ?? ""
        // Ein einfaches Objekt ({ message, hint }) hat keinen Namen: kein „undefined:“ davor
        let name = error.forProperty("name").flatMap { $0.isString ? $0.toString() : nil } ?? ""
        let plain = name.isEmpty || name == "Error"
        var text = plain ? message : "\(name): \(message)"
        // Datei und Zeile nur bei Fehlern im Code (TypeError, ReferenceError …). Eine Meldung,
        // die das Plugin selbst mit `throw new Error(…)` gibt, ist für Menschen gedacht.
        if !plain, let line = error.forProperty("line"), line.isNumber, line.toInt32() > 0 {
            let source = error.forProperty("sourceURL").flatMap { $0.isString ? URL(string: $0.toString())?.lastPathComponent : nil }
            text += " (\(source ?? "script"):\(line.toInt32()))"
        }
        return text.isEmpty ? "Error" : text
    }

    /// Beendet den Lauf, genau einmal. Aus der Warteschlange des Skripts oder (beim
    /// Abbrechen) vom Hauptthread.
    private func finish(_ result: Result<[URL], PluginRunError>) {
        lock.lock()
        guard let completion else { lock.unlock(); return }
        self.completion = nil
        // Rechnet das Skript noch (etwa in einer Endlosschleife), beendet der Wächter es jetzt
        stopFlag.set()
        let cancelled = _cancelled
        let running = processes
        processes = []
        let open = tasks
        tasks = []
        lock.unlock()
        var final = result
        if cancelled { final = .failure(.cancelled) }
        if case .success = final {
            final = .success(collectOutput())
        }
        open.forEach { $0.cancel() }
        // Erst das Ergebnis melden (es wird aus dem Arbeitsordner übernommen), dann die
        // Programme beenden und erst danach den Ordner freigeben
        DispatchQueue.main.async { completion(final) }
        ProcessTree.terminate(running) { [self] in
            DispatchQueue.main.async { self.onStopped?() }
        }
        // Kontext freigeben, aber nicht mitten in einem eigenen Aufruf. Hängt das Skript
        // in einer Endlosschleife, kommt das nie dran; der Platzhalter ist trotzdem weg.
        // Die Sitzung ebenfalls dort schließen: Neue Anfragen entstehen nur auf dieser
        // Warteschlange, so kommt keine mehr nach dem Schließen.
        queue.async { [weak self] in
            self?.context = nil
            self?.session.finishTasksAndInvalidate()
        }
    }

    /// Endungen halb geladener oder noch entstehender Dateien: Sie zählen nicht zum Ergebnis
    static let partialExtensions: Set<String> = ["part", "ytdl", "tmp", "download", "crdownload"]

    /// Fertige Dateien im Ausgabeordner, ohne versteckte und halb geladene
    private func collectOutput() -> [URL] {
        let partial = Self.partialExtensions
        let items = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && !partial.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Abbrechen wirkt sofort: Platzhalter weg, Platz für das nächste Plugin frei, Programme
    /// und Anfragen werden beendet. Nicht über die Warteschlange des Skripts, die eine
    /// Endlosschleife nie wieder freigibt.
    func cancel() {
        lock.lock()
        guard !_cancelled else { lock.unlock(); return }
        _cancelled = true
        lock.unlock()
        finish(.failure(.cancelled))
    }

    /// Anhalten: laufende Programme stehen (SIGSTOP), Downloads pausieren. Fortsetzen
    /// macht an derselben Stelle weiter. Beim Beenden von BarDrop ist beides verloren.
    func setPaused(_ paused: Bool) {
        lock.lock()
        guard _paused != paused, !_cancelled else { lock.unlock(); return }
        _paused = paused
        let running = processes
        let open = tasks
        lock.unlock()
        for process in running where process.isRunning {
            ProcessTree.signal(process.processIdentifier, paused ? SIGSTOP : SIGCONT)
        }
        open.forEach { paused ? $0.suspend() : $0.resume() }
        DispatchQueue.main.async { self.job.setPausedState(paused) }
    }

    // MARK: Schnittstelle für das Skript

    private func installAPI(in context: JSContext) {
        let api = JSValue(newObjectIn: context)!
        let language = AppLanguage.current.resolved == .german ? "de" : "en"

        func set(_ name: String, _ block: Any) {
            api.setObject(block, forKeyedSubscript: name as NSString)
        }

        api.setObject(language, forKeyedSubscript: "language" as NSString)
        api.setObject(appVersion, forKeyedSubscript: "appVersion" as NSString)
        api.setObject(outputDirectory.path, forKeyedSubscript: "outputDirectory" as NSString)
        // Eigener Ordner des Plugins (manifest.json, Skript, Vorlagen): für readFile
        api.setObject(plugin.directory.standardizedFileURL.path, forKeyedSubscript: "pluginDirectory" as NSString)
        api.setObject(["id": plugin.id, "version": plugin.manifest.version], forKeyedSubscript: "plugin" as NSString)
        api.setObject(settingsValues, forKeyedSubscript: "settings" as NSString)

        let log: @convention(block) (JSValue) -> Void = { [plugin] value in
            let text = String((value.toString() ?? "").prefix(300))
            PluginLog.shared.record(plugin.id, "skript", text)
        }
        set("log", log)

        let progress: @convention(block) (JSValue, JSValue) -> Void = { [weak self] value, label in
            guard let self else { return }
            let fraction: Double? = value.isNumber ? value.toDouble() : nil
            let text: String? = label.isString ? String(label.toString().prefix(60)) : nil
            DispatchQueue.main.async { self.job.report(fraction, label: text) }
        }
        set("progress", progress)

        let cancelled: @convention(block) () -> Bool = { [weak self] in self?.isCancelled ?? true }
        set("isCancelled", cancelled)

        let notify: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = String(value.toString().prefix(40))
            DispatchQueue.main.async { self?.onNotify(text) }
        }
        set("notify", notify)

        let writeFile: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] name, contents in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard name.isString, !contents.isUndefined, !contents.isNull else {
                ctx.exception = JSValue(newErrorFromMessage: L("writeFile needs a name and some text.", "writeFile braucht einen Namen und einen Text."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let target = self.newOutputURL(name.toString())
            do {
                try contents.toString().write(to: target, atomically: true, encoding: .utf8)
                return JSValue(object: target.path, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        set("writeFile", writeFile)

        let createLink: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, title in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            // Nur Webadressen: ein Link auf file:// o. Ä. würde beim Öffnen Dateien oder Apps starten
            guard address.isString, let link = URL(string: address.toString()),
                  ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
                ctx.exception = JSValue(newErrorFromMessage: L("Invalid web address.", "Ungültige Webadresse."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let name = title.isString ? title.toString()! : (link.host ?? "Link")
            // Wie bei writeFile zählt nur der letzte Teil eines Pfads. Die Endung bleibt beim
            // Kürzen auf 80 Zeichen erhalten (newOutputURL kürzt nur den Namen davor).
            let base = ContentImporter.sanitize((name as NSString).lastPathComponent)
            let target = self.newOutputURL(base + ".webloc")
            let plist = ["URL": link.absoluteString]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: target)
            }
            return JSValue(object: target.path, in: ctx)
        }
        set("createLink", createLink)

        let readFile: @convention(block) (JSValue) -> JSValue = { [weak self] path in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard let data = self.readAllowed(path, call: "readFile", in: ctx) else { return JSValue(undefinedIn: ctx) }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return JSValue(object: text, in: ctx)
        }
        set("readFile", readFile)

        // Binärdaten: Swift reicht Base64 weiter, das Vorspiel macht daraus Uint8Array (PluginPrelude)
        let readData: @convention(block) (JSValue) -> JSValue = { [weak self] path in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard let data = self.readAllowed(path, call: "readData", in: ctx) else { return JSValue(undefinedIn: ctx) }
            return JSValue(object: data.base64EncodedString(), in: ctx)
        }
        context.setObject(readData, forKeyedSubscript: "__bardropReadData" as NSString)

        let writeData: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] name, base64 in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard name.isString, base64.isString,
                  let data = Data(base64Encoded: base64.toString(), options: .ignoreUnknownCharacters) else {
                ctx.exception = JSValue(newErrorFromMessage: L("writeData needs a name and data.", "writeData braucht einen Namen und Daten."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let target = self.newOutputURL(name.toString())
            do {
                try data.write(to: target, options: .atomic)
                return JSValue(object: target.path, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(writeData, forKeyedSubscript: "__bardropWriteData" as NSString)

        // Adressen zerlegen für `URL` im Vorspiel: Foundation kennt die Regeln
        let parseURL: @convention(block) (JSValue, JSValue) -> JSValue = { input, base in
            guard let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard let parts = PluginRuntime.urlParts(input.toString() ?? "", base: base.isString ? base.toString() : nil) else {
                return JSValue(nullIn: ctx)
            }
            return JSValue(object: parts, in: ctx)
        }
        context.setObject(parseURL, forKeyedSubscript: "__bardropParseURL" as NSString)

        let clipboard: @convention(block) (JSValue) -> Void = { [weak self] text in
            guard let self, self.require(.clipboard) else { return }
            let string = text.toString() ?? ""
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
        set("setClipboard", clipboard)

        let fetch: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, options in
            self?.promise { resolve, reject in self?.fetch(address, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("fetch", fetch)

        let download: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, options in
            self?.promise { resolve, reject in self?.download(address, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("download", download)

        // Programm suchen, wie `which`, aber an allen Orten, die auch `run` kennt; lädt nichts
        let findProgram: @convention(block) (JSValue) -> JSValue = { [weak self] name in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard name.isString else { return JSValue(nullIn: ctx) }
            let found = self.findProgram(name.toString() ?? "")
            PluginLog.shared.record(self.plugin.id, "programm", "suche \(name.toString() ?? ""): \(found ?? "nicht gefunden")")
            return found.map { JSValue(object: $0, in: ctx) } ?? JSValue(nullIn: ctx)
        }
        set("findProgram", findProgram)

        let sleep: @convention(block) (JSValue) -> JSValue = { [weak self] ms in
            let seconds = max(0, min(ms.isNumber ? ms.toDouble() / 1000 : 0, 3600))
            return self?.promise { resolve, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { resolve(nil) }
            } ?? JSValue(undefinedIn: JSContext.current())
        }
        set("sleep", sleep)

        let run: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] command, args, options in
            self?.promise { resolve, reject in self?.run(command, args, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("run", run)

        context.setObject(api, forKeyedSubscript: "bardrop" as NSString)

        let done: @convention(block) () -> Void = { [weak self] in self?.finish(.success([])) }
        context.setObject(done, forKeyedSubscript: "__bardropDone" as NSString)
        let fail: @convention(block) (JSValue) -> Void = { [weak self] error in
            self?.finish(.failure(.script(PluginRuntime.describe(error), hint: PluginRuntime.hint(of: error))))
        }
        context.setObject(fail, forKeyedSubscript: "__bardropFail" as NSString)
    }

    /// Ein Versprechen für das Skript. `body` läuft sofort; resolve/reject dürfen später
    /// aus beliebigen Threads kommen und werden auf die Warteschlange des Skripts gelegt.
    private func promise(_ body: @escaping (@escaping (Any?) -> Void, @escaping (String) -> Void) -> Void) -> JSValue? {
        guard let ctx = JSContext.current() else { return nil }
        var resolveFn: JSValue?
        var rejectFn: JSValue?
        let promise = JSValue(newPromiseIn: ctx) { resolve, reject in
            resolveFn = resolve
            rejectFn = reject
        }
        let resolve: (Any?) -> Void = { [weak self] value in
            self?.queue.async {
                guard self?.isFinished == false else { return }
                resolveFn?.call(withArguments: value.map { [$0] } ?? [])
                resolveFn = nil
                rejectFn = nil
            }
        }
        let reject: (String) -> Void = { [weak self] message in
            self?.queue.async {
                guard self?.isFinished == false, let reject = rejectFn else { return }
                reject.call(withArguments: [JSValue(newErrorFromMessage: message, in: reject.context)!])
                resolveFn = nil
                rejectFn = nil
            }
        }
        body(resolve, reject)
        return promise
    }

    // MARK: Rechte

    /// Darf das Plugin das? Fragt beim ersten Gebrauch (nicht bei automatischen Läufen).
    /// Läuft auf der Warteschlange des Skripts.
    private func require(_ permission: PluginPermission) -> Bool {
        guard plugin.manifest.allPermissions.contains(permission) else {
            if let ctx = JSContext.current() {
                ctx.exception = JSValue(newErrorFromMessage: L("The permission “\(permission.rawValue)” is missing in manifest.json.",
                                                                 "Das Recht „\(permission.rawValue)“ fehlt in der manifest.json."), in: ctx)
            }
            return false
        }
        lock.lock()
        let has = granted.contains(permission)
        lock.unlock()
        if has { return true }
        guard !job.automatic, let prompter else {
            PluginLog.shared.record(plugin.id, "recht", "\(permission.rawValue): fehlt (automatischer Lauf fragt nicht)")
            return false
        }
        let plugin = plugin
        let allowed = DispatchQueue.main.sync { prompter.allow(permission, for: plugin) }
        PluginLog.shared.record(plugin.id, "recht", "\(permission.rawValue): \(allowed ? "erlaubt" : "nicht erlaubt")")
        if allowed {
            lock.lock(); granted.insert(permission); lock.unlock()
            DispatchQueue.main.async { self.onGrant(permission) }
        }
        return allowed
    }

    /// Datei für readFile und readData: Pfad prüfen, höchstens 20 MB. Sonst ein Fehler im Skript.
    private func readAllowed(_ path: JSValue, call: String, in ctx: JSContext) -> Data? {
        // Ohne „/“ am Anfang: relativ zum Ausgabeordner
        guard path.isString else {
            ctx.exception = JSValue(newErrorFromMessage: L("\(call) needs a path.", "\(call) braucht einen Pfad."), in: ctx)
            return nil
        }
        let raw = path.toString() ?? ""
        let url = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw)
                   : outputDirectory.appendingPathComponent(raw)).standardizedFileURL
        guard mayRead(url) else {
            ctx.exception = JSValue(newErrorFromMessage: L("The plugin may only read the items themselves, its output folder and its own files.", "Das Plugin darf nur die Objekte selbst, seinen Ausgabeordner und seine eigenen Dateien lesen."), in: ctx)
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 20 * 1024 * 1024, let data = try? Data(contentsOf: url) else {
            ctx.exception = JSValue(newErrorFromMessage: L("The file can’t be read (missing or larger than 20 MB).", "Die Datei lässt sich nicht lesen (fehlt oder ist größer als 20 MB)."), in: ctx)
            return nil
        }
        return data
    }

    /// Teile einer Adresse wie bei `URL` im Browser (protocol mit „:“, search mit „?“ …),
    /// relativ zu `base`, wenn angegeben. nil: keine gültige absolute Adresse.
    static func urlParts(_ input: String, base: String?) -> [String: String]? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: URL?
        if let base {
            guard let baseURL = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)), baseURL.scheme != nil else { return nil }
            resolved = URL(string: text, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: text)
        }
        guard let url = resolved, let scheme = url.scheme, !scheme.isEmpty,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        return [
            "protocol": scheme.lowercased() + ":",
            "username": c.percentEncodedUser ?? "",
            "password": c.percentEncodedPassword ?? "",
            "hostname": (c.percentEncodedHost ?? "").lowercased(),
            "port": c.port.map(String.init) ?? "",
            "pathname": c.percentEncodedPath,
            "search": c.percentEncodedQuery.map { $0.isEmpty ? "" : "?" + $0 } ?? "",
            "hash": c.percentEncodedFragment.map { $0.isEmpty ? "" : "#" + $0 } ?? ""
        ]
    }

    private func mayRead(_ url: URL) -> Bool {
        let path = url.path
        let roots = [outputDirectory.standardizedFileURL.path, plugin.directory.standardizedFileURL.path]
        return job.items.contains { path == $0.url.standardizedFileURL.path } || roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Neuer Name im Ausgabeordner, ohne etwas zu überschreiben. Nur der letzte Teil eines
    /// Pfads zählt; zu lange Namen werden gekürzt, die Endung bleibt (ContentImporter.sanitize).
    private func newOutputURL(_ name: String) -> URL {
        var clean = ContentImporter.sanitize((name as NSString).lastPathComponent)
        if clean.isEmpty { clean = "Item" }
        return ShelfActions.uniqueURL(for: clean, in: outputDirectory)
    }

    private func track(_ task: URLSessionTask) {
        lock.lock()
        // Schon zu Ende (etwa gerade abgebrochen): gar nicht erst laden
        guard completion != nil else { lock.unlock(); return task.cancel() }
        tasks.append(task)
        let paused = _paused
        lock.unlock()
        task.resume()
        if paused { task.suspend() }
    }

    /// Fertige Anfragen vergessen
    private func untrackFinished() {
        lock.lock(); tasks.removeAll { $0.state == .completed }; lock.unlock()
    }

    // MARK: Internet

    private func request(_ address: JSValue, _ options: JSValue) -> URLRequest? {
        guard let url = URL(string: address.toString()), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("BarDrop/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if options.isObject {
            if let method = options.forProperty("method"), method.isString { request.httpMethod = method.toString() }
            if let headers = options.forProperty("headers")?.toDictionary() as? [String: Any] {
                for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
            }
            if let body = options.forProperty("body"), body.isString { request.httpBody = Data(body.toString().utf8) }
        }
        return request
    }

    private func fetch(_ address: JSValue, _ options: JSValue,
                       _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.network) else { return reject(L("Internet access isn’t allowed.", "Der Zugriff aufs Internet ist nicht erlaubt.")) }
        guard let request = request(address, options) else { return reject(L("Invalid web address.", "Ungültige Webadresse.")) }
        let pluginID = plugin.id
        let host = request.url?.host ?? "?"
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.untrackFinished()
            if let error {
                PluginLog.shared.record(pluginID, "netz", "fetch \(host): \(error.localizedDescription)")
                return reject(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            PluginLog.shared.record(pluginID, "netz", "fetch \(host): Status \(http?.statusCode ?? 0)")
            let limited = (data ?? Data()).prefix(20 * 1024 * 1024)
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)".lowercased()] = "\(value)" }
            resolve(["status": http?.statusCode ?? 0,
                     "url": response?.url?.absoluteString ?? "",
                     "headers": headers,
                     "text": String(data: limited, encoding: .utf8) ?? String(decoding: limited, as: UTF8.self)])
        }
        track(task)
    }

    private func download(_ address: JSValue, _ options: JSValue,
                          _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.network) else { return reject(L("Internet access isn’t allowed.", "Der Zugriff aufs Internet ist nicht erlaubt.")) }
        guard let request = request(address, options) else { return reject(L("Invalid web address.", "Ungültige Webadresse.")) }
        let wanted = options.isObject ? options.forProperty("name").flatMap { $0.isString ? $0.toString() : nil } : nil
        let observation = ObservationHolder()
        let task = session.downloadTask(with: request) { [weak self] file, response, error in
            observation.invalidate()
            guard let self else { return }
            self.untrackFinished()
            PluginLog.shared.record(self.plugin.id, "netz",
                                    "download \(request.url?.host ?? "?"): \(error?.localizedDescription ?? "Status \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
            if let error { return reject(error.localizedDescription) }
            guard let file, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return reject(L("The server answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).",
                                 "Der Server antwortete mit Status \((response as? HTTPURLResponse)?.statusCode ?? 0)."))
            }
            let name = wanted ?? response?.suggestedFilename ?? request.url?.lastPathComponent ?? "Download"
            let target = self.newOutputURL(name)
            do {
                try FileManager.default.moveItem(at: file, to: target)
                resolve(target.path)
            } catch {
                reject(error.localizedDescription)
            }
        }
        observation.set(task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { self?.job.report(value, label: nil) }
        })
        track(task)
    }

    // MARK: Programme

    /// Orte für Programme ohne Pfad: System und Homebrew
    /// Orte für Programme ohne Pfad: System, Homebrew und die Programmordner im
    /// Benutzerordner (`~/.<werkzeug>/bin`, `~/.local/bin`): Viele Laufzeiten und
    /// Paketverwaltungen installieren dorthin, wenn nicht über Homebrew
    static let searchPaths: [String] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let hidden = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." && $0 != ".Trash" }
            .sorted()
            .map { home.appendingPathComponent($0).appendingPathComponent("bin").path }
            .filter { var dir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
        return ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
            + hidden + [home.appendingPathComponent(".local/bin").path].filter { !hidden.contains($0) }
    }()

    /// Wo nach einem Programm ohne Pfad gesucht wird, in dieser Reihenfolge: eigene Werkzeuge,
    /// System und Homebrew, Benutzerordner, zuletzt Werkzeuge, die andere Plugins schon geladen
    /// haben (geprüfte Downloads; so findet ein Plugin eine Laufzeit, die es nicht selbst lädt).
    /// Auch PATH der gestarteten Programme, damit `which` dasselbe findet.
    private var programFolders: [String] {
        let own = tools.folders(for: plugin.manifest.tools ?? [])
        return own + Self.searchPaths + tools.sharedFolders().filter { !own.contains($0) }
    }

    /// Programm suchen, ohne etwas zu laden: Pfad oder nil
    private func findProgram(_ name: String) -> String? {
        if let tool = plugin.manifest.tools?.first(where: { $0.id == name }), let url = tools.installed(tool) {
            return url.path
        }
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return programFolders.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile)
    }

    private func run(_ command: JSValue, _ args: JSValue, _ options: JSValue,
                     _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.run) else { return reject(L("Running programs isn’t allowed.", "Programme auszuführen ist nicht erlaubt.")) }
        let name = command.toString() ?? ""
        let arguments = (args.toArray() ?? []).map { "\($0)" }
        let onOutput: JSValue? = options.isObject ? options.forProperty("onOutput").flatMap { $0.isObject ? $0 : nil } : nil
        let automatic = job.automatic
        let plugin = plugin
        // Werkzeuge erst laden (kann dauern), nicht auf der Warteschlange des Skripts
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let executable: URL
            do {
                executable = try self.resolveExecutable(name, automatic: automatic, plugin: plugin)
            } catch let error as PluginTools.ToolError {
                PluginLog.shared.record(plugin.id, "programm", "\(name): \(error.message)")
                return reject(error.message)
            } catch let error as PluginRunError {
                PluginLog.shared.record(plugin.id, "programm", "\(name): \(error.message)")
                return reject(error.message)
            } catch {
                PluginLog.shared.record(plugin.id, "programm", "\(name): \(error.localizedDescription)")
                return reject(error.localizedDescription)
            }
            self.launch(executable, arguments, onOutput: onOutput, resolve, reject)
        }
    }

    private func resolveExecutable(_ name: String, automatic: Bool, plugin: InstalledPlugin) throws -> URL {
        if let tool = plugin.manifest.tools?.first(where: { $0.id == name }) {
            // Muss erst geladen werden: am Platzhalter zeigen, was gerade passiert
            let loading = tools.installed(tool) == nil
            if loading {
                DispatchQueue.main.async { self.job.report(nil, label: L("Downloading \(tool.name)", "Lädt \(tool.name)"), force: true) }
            }
            defer {
                if loading { DispatchQueue.main.async { self.job.report(nil, label: "", force: true) } }
            }
            return try tools.ensure(tool, owner: plugin.id, ask: {
                self.lock.lock()
                let approved = self.approvedTools.contains(tool.approvalKey)
                self.lock.unlock()
                if approved { return true }
                guard !automatic, let prompter = self.prompter else { return false }
                let allowed = DispatchQueue.main.sync { prompter.allowDownload(of: tool, for: plugin) }
                if allowed {
                    self.lock.lock(); self.approvedTools.insert(tool.approvalKey); self.lock.unlock()
                    DispatchQueue.main.async { self.onToolApproved(tool.approvalKey) }
                }
                return allowed
            }, cancelled: { self.isCancelled }, progress: { fraction in
                DispatchQueue.main.async {
                    self.job.report(fraction, label: L("Downloading \(tool.name) \(Int(fraction * 100))%", "Lädt \(tool.name) \(Int(fraction * 100)) %"))
                }
            })
        }
        if name.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw PluginRunError.script(L("Program not found: \(name)", "Programm nicht gefunden: \(name)"))
            }
            return URL(fileURLWithPath: name)
        }
        guard !name.contains("/"),
              let path = programFolders.map({ $0 + "/" + name }).first(where: FileManager.default.isExecutableFile) else {
            throw PluginRunError.script(L("Program not found: \(name)", "Programm nicht gefunden: \(name)"))
        }
        return URL(fileURLWithPath: path)
    }

    /// Programme sprechen UTF-8. Aus dem Finder gestartet hat BarDrop kein `LANG`; dann
    /// gaben Programme wie `pbpaste` Umlaute und Emoji als „?“ aus (Schnittstellen-Test
    /// „setClipboard und zurücksetzen“, je nachdem, wie BarDrop gestartet wurde).
    static func utf8Environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        func isUTF8(_ key: String) -> Bool {
            guard let value = environment[key]?.lowercased() else { return false }
            return value.contains("utf-8") || value.contains("utf8")
        }
        // LC_ALL gewinnt vor allem anderen: dann nur, wenn es selbst UTF-8 ist
        if let all = environment["LC_ALL"], !all.isEmpty {
            if !isUTF8("LC_ALL") { environment["LC_ALL"] = "en_US.UTF-8" }
            return environment
        }
        if !isUTF8("LC_CTYPE") && !(environment["LC_CTYPE"] == nil && isUTF8("LANG")) {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
        if environment["LANG"]?.isEmpty ?? true { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    private func launch(_ executable: URL, _ arguments: [String], onOutput: JSValue?,
                        _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        var environment = Self.utf8Environment(ProcessInfo.processInfo.environment)
        // Programme dieses Plugins zuerst (so findet z. B. ein Werkzeug eine mitgeladene
        // Laufzeit), dann System und Homebrew
        environment["PATH"] = programFolders.joined(separator: ":")
        environment["BARDROP_OUTPUT"] = outputDirectory.path
        let out = Pipe(), err = Pipe()
        // Eigener Start statt Process: Argumente wörtlich (siehe PluginProcess)
        let process = PluginProcess(executable: executable, arguments: arguments, environment: environment,
                                    directory: outputDirectory, standardOutput: out, standardError: err)

        let collected = OutputCollector()
        let started = Date()
        PluginLog.shared.record(plugin.id, "programm", "\(executable.path) " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        let lineHandler: (String) -> Void = { [weak self] line in
            guard let self, let onOutput else { return }
            self.queue.async {
                guard !self.isFinished else { return }
                onOutput.call(withArguments: [line])
            }
        }
        // Jede Ausgabe hat genau einen Leser, bis zu ihrem Ende. Fertig ist der Aufruf erst,
        // wenn beide zu Ende gelesen sind und das Programm beendet ist. (Las beim Ende ein
        // zweiter Faden den Rest, während der erste noch das letzte Stück verarbeitete,
        // kamen Zeilen in falscher Reihenfolge an.)
        let finished = DispatchGroup()
        finished.enter(); finished.enter(); finished.enter()
        func read(_ pipe: Pipe, stderr isErr: Bool) {
            Thread.detachNewThread {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    collected.add(data, stderr: isErr, lines: lineHandler)
                }
                finished.leave()
            }
        }
        process.terminationHandler = { _ in finished.leave() }
        let ended: () -> Void = { [weak self] in
            collected.flush(lines: lineHandler)
            if let self {
                self.lock.lock(); self.processes.removeAll { $0 === process }; self.lock.unlock()
            }
            let result = collected.result
            if let self {
                let tail = result.stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " | ")
                PluginLog.shared.record(self.plugin.id, "programm",
                                        "\(executable.lastPathComponent) beendet: Code \(process.terminationStatus), \(String(format: "%.1f", Date().timeIntervalSince(started))) s\(tail.isEmpty ? "" : ", stderr: " + tail)")
            }
            resolve(["code": Int(process.terminationStatus), "stdout": result.stdout, "stderr": result.stderr])
        }
        lock.lock()
        // Auch nach dem Ende nichts mehr starten: Ein Programm, auf das das Skript nicht
        // gewartet hat, liefe sonst unbeobachtet weiter
        guard !_cancelled, completion != nil else { lock.unlock(); return reject(L("Canceled", "Abgebrochen")) }
        // Starten und Eintragen unter der Sperre: Ein gleichzeitiges Ende sieht das
        // Programm dann sicher und beendet es mit
        do {
            try process.run()
            processes.append(process)
            if _paused { kill(process.processIdentifier, SIGSTOP) }
            lock.unlock()
            read(out, stderr: false)
            read(err, stderr: true)
            finished.notify(queue: .global(qos: .userInitiated), execute: ended)
        } catch {
            lock.unlock()
            reject(error.localizedDescription)
        }
    }
}

/// Sammelt die Ausgabe eines Programms (höchstens 1 MB je Kanal) und meldet sie
/// zeilenweise, getrennt nach stdout und stderr. Zeilen enden auch an \r, damit
/// Fortschrittsanzeigen ankommen. Sehr lange Zeilen werden nach 64 KB weitergereicht.
final class OutputCollector {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pendingOut = Data()
    private var pendingErr = Data()
    private let limit = 1024 * 1024
    private let maxLine = 64 * 1024

    func add(_ data: Data, stderr isErr: Bool, lines: (String) -> Void) {
        guard !data.isEmpty else { return }
        lock.lock()
        var pending: Data
        if isErr {
            if stderr.count < limit { stderr.append(data.prefix(limit - stderr.count)) }
            pending = pendingErr
        } else {
            if stdout.count < limit { stdout.append(data.prefix(limit - stdout.count)) }
            pending = pendingOut
        }
        pending.append(data)
        var found: [String] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = Data(pending[pending.startIndex..<index])
            pending = Data(pending[pending.index(after: index)...])
            if !line.isEmpty { found += Self.pieces(line, max: maxLine) }
        }
        // Noch ohne Zeilenende, aber schon zu lang: volle Stücke weiterreichen, den Rest behalten
        while pending.count > maxLine {
            let cut = Self.boundary(pending, before: maxLine)
            found.append(String(decoding: pending.prefix(cut), as: UTF8.self))
            pending = Data(pending.dropFirst(cut))
        }
        if isErr { pendingErr = pending } else { pendingOut = pending }
        lock.unlock()
        found.forEach(lines)
    }

    /// Eine Zeile in Stücke von höchstens `max` Bytes, nie mitten in einem Zeichen
    static func pieces(_ line: Data, max: Int) -> [String] {
        var rest = line
        var result: [String] = []
        while rest.count > max {
            let cut = boundary(rest, before: max)
            result.append(String(decoding: rest.prefix(cut), as: UTF8.self))
            rest = Data(rest.dropFirst(cut))
        }
        if !rest.isEmpty { result.append(String(decoding: rest, as: UTF8.self)) }
        return result
    }

    /// Schnittstelle bei höchstens `limit` Bytes, an einem Zeichenanfang (UTF-8-Folgebytes
    /// beginnen mit 10xxxxxx)
    static func boundary(_ data: Data, before limit: Int) -> Int {
        var cut = min(limit, data.count)
        let start = data.startIndex
        while cut > 0, cut < data.count, data[start + cut] & 0xC0 == 0x80 { cut -= 1 }
        return cut > 0 ? cut : min(limit, data.count)
    }

    func flush(lines: (String) -> Void) {
        lock.lock()
        let rest = [pendingOut, pendingErr]
        pendingOut = Data()
        pendingErr = Data()
        lock.unlock()
        for data in rest where !data.isEmpty { lines(String(decoding: data, as: UTF8.self)) }
    }

    var result: (stdout: String, stderr: String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

/// Signale an ein Programm und alle Programme, die es selbst gestartet hat (z. B. ein
/// Werkzeug, das ein weiteres Programm startet): Anhalten und Abbrechen wirken auf den ganzen Baum.
enum ProcessTree {
    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let current = queue.popLast(), result.count < 256 {
            let count = proc_listchildpids(current, nil, 0)
            guard count > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(count) + 8)
            let filled = proc_listchildpids(current, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard filled > 0 else { continue }
            let children = buffer.prefix(Int(filled)).filter { $0 > 0 }
            result += children
            queue += children
        }
        return result
    }

    /// Erst die Nachkommen, dann das Programm selbst
    static func signal(_ pid: pid_t, _ sig: Int32) {
        for child in descendants(of: pid).reversed() { kill(child, sig) }
        kill(pid, sig)
    }

    /// Beendet Programme samt allen Programmen, die sie gestartet haben: erst höflich
    /// (SIGTERM), nach 3 s hart (SIGKILL). Die Nachkommen werden vorher einmal ermittelt,
    /// so werden auch Unterprogramme erreicht, deren Elternprogramm schon beendet ist.
    /// `done` kommt, wenn nichts mehr läuft (auf einer Hintergrund-Warteschlange).
    static func terminate(_ processes: [PluginProcess], done: @escaping () -> Void) {
        let running = processes.filter(\.isRunning)
        guard !running.isEmpty else { return done() }
        let pids: [pid_t] = running.flatMap { process -> [pid_t] in
            let pid = process.processIdentifier
            return Array(descendants(of: pid).reversed()) + [pid]
        }
        for pid in pids {
            kill(pid, SIGCONT)
            kill(pid, SIGTERM)
        }
        let queue = DispatchQueue.global(qos: .utility)
        func alive() -> [pid_t] { pids.filter { kill($0, 0) == 0 } }
        func check(_ round: Int) {
            let left = alive()
            if left.isEmpty { return done() }
            if round == 12 { left.forEach { kill($0, SIGKILL) } }
            if round >= 16 { return done() }
            queue.asyncAfter(deadline: .now() + 0.25) { check(round + 1) }
        }
        queue.asyncAfter(deadline: .now() + 0.25) { check(1) }
    }
}

/// Hält die Beobachtung des Fortschritts eines Downloads, bis er fertig ist
private final class ObservationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    func set(_ value: NSKeyValueObservation) {
        lock.lock(); observation = value; lock.unlock()
    }

    func invalidate() {
        lock.lock(); let o = observation; observation = nil; lock.unlock()
        o?.invalidate()
    }
}
