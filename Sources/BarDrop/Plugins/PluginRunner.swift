import AppKit
import UniformTypeIdentifiers
import Combine
import SwiftUI

/// Startet Plugins für Objekte der Ablage und bringt ihre Ergebnisse zurück:
/// über den Rechtsklick, die Aktionsleiste oder automatisch beim Ablegen.
///
/// Laufende Plugins erscheinen als Platzhalter direkt neben dem Original. Ist ein Plugin
/// fertig, liegt das Ergebnis an genau dieser Stelle und ist sofort mit Vorschau zu sehen.
final class PluginRunner: ObservableObject, PluginPrompter {
    @Published private(set) var jobs: [PluginJob] = [] {
        didSet {
            let counts = Dictionary(jobs.map { ($0.plugin.id, 1) }, uniquingKeysWith: +)
            if manager.runningCounts != counts { manager.runningCounts = counts }
        }
    }

    private let manager: PluginManager
    private weak var actions: ShelfActions?
    private var runtimes: [UUID: PluginRuntime] = [:]
    private var tools: PluginTools { manager.tools }
    /// Höchstens so viele Plugins gleichzeitig; weitere warten (schont den Mac)
    static let maxConcurrent = 3
    private var waiting: [PluginJob] = []
    /// Sieht nach, ob laufende Plugins schon ein Ergebnis geschrieben haben (Vorschau im Platzhalter)
    private var previewTimer: Timer?
    /// Letzter Stand je Auftrag: neueste Ergebnisdatei und ihre Größe
    private var previewCandidates: [UUID: (url: URL, size: Int)] = [:]
    /// Fehler eines Laufs per Rechtsklick oder Aktionsleiste als Dialog zeigen (Tests: aus)
    var showsErrorDialogs = true
    private var watchers: Set<AnyCancellable> = []

    init(manager: PluginManager = .shared, actions: ShelfActions) {
        self.manager = manager
        self.actions = actions
        // „Beenden“ in den Einstellungen: alle Läufe dieses Plugins abbrechen
        manager.stopRuns = { [weak self] id in
            guard let self else { return }
            for job in self.jobs where job.plugin.id == id {
                PluginLog.shared.record(id, "abbruch", "in den Einstellungen beendet")
                self.cancel(job, inShelf: false)
            }
        }
        // Ausgeschaltet oder entfernt: laufende und wartende Aufträge des Plugins abbrechen
        manager.objectWillChange
            .merge(with: AppSettings.shared.$pluginsEnabled.map { _ in () }.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cancelInactiveJobs() }
            .store(in: &watchers)
    }

    /// Aufträge von Plugins, die nicht mehr eingeschaltet (oder nicht mehr installiert) sind
    func cancelInactiveJobs() {
        guard !jobs.isEmpty else { return }
        // Eigene Läufe (Cloud-Upload) gehören zu keinem installierten Plugin; ohne die
        // Ausnahme brach jede Änderung am Plugin-Verwalter den Upload sofort ab (30.10.2026)
        for job in jobs where !job.isNative && !manager.isActive(job.plugin.id) {
            PluginLog.shared.record(job.plugin.id, "abbruch", "Plugin ausgeschaltet oder entfernt")
            cancel(job, inShelf: false)
        }
    }

    private var store: ShelfStore? { actions?.store }
    private var settings: AppSettings { AppSettings.shared }

    // MARK: Welche Plugins passen

    /// Eingeschaltete Plugins, die zu mindestens einer der Dateien passen und den Auslöser kennen
    func plugins(for urls: [URL], trigger: PluginTrigger) -> [InstalledPlugin] {
        let active = manager.activePlugins.filter { $0.manifest.allTriggers.contains(trigger) }
        guard !active.isEmpty, !urls.isEmpty else { return [] }
        let items = urls.prefix(50).map(PluginItem.init(url:))
        return active.filter { plugin in items.contains { PluginMatcher.matches(plugin.manifest.match, $0) } }
    }

    /// So lange nach dem Start bleibt ein Lauf unsichtbar (kein Platzhalter, kein „Plugin läuft“)
    static let showDelay: TimeInterval = 0.3

    /// Läufe, die schon zu sehen sind
    var visibleJobs: [PluginJob] { jobs.filter(\.shown) }
    var hasVisibleJobs: Bool { jobs.contains(where: \.shown) }

    func job(for id: UUID?) -> PluginJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Laufende Plugins, die neben dieser Datei erscheinen
    func jobs(nextTo fileIDs: [UUID]) -> [PluginJob] {
        guard !jobs.isEmpty else { return [] }
        let ids = Set(fileIDs)
        return jobs.filter { $0.shown && ids.contains($0.anchorFileID) && !$0.replacesOriginal }
    }

    // MARK: Starten

    /// Rechtsklick oder Aktionsleiste: das Plugin für alle passenden Dateien
    func run(_ pluginID: String, on files: [ShelfFile]) {
        guard let plugin = manager.refreshed(pluginID), manager.isActive(pluginID) else { return NSSound.beep() }
        let matching = files.filter { PluginMatcher.matches(plugin.manifest.match, PluginItem(url: $0.url)) }
        guard !matching.isEmpty else {
            NSSound.beep()
            // Kurz: Die Kopfzeile der Ablage ist schmal
            actions?.announce(L("Not suitable", "Nicht passend"), duration: 1.6)
            return
        }
        // Läuft dasselbe Plugin schon für eine Datei, nicht ein zweites Mal starten
        // Ein gescheiterter Lauf, der nur noch kurz rüttelt, zählt nicht: Sonst hieß ein
        // neuer Versuch gleich danach „Läuft schon“
        let fresh = matching.filter { file in !jobs.contains { !$0.failed && $0.fileIDs.contains(file.id) && $0.plugin.id == plugin.id } }
        guard !fresh.isEmpty else {
            actions?.announce(L("Already running", "Läuft schon"), duration: 1.6)
            return
        }
        // Fehlt noch etwas, jetzt alles in einem Fenster erfragen, nicht mitten im Lauf
        guard prepare(plugin) else { return }
        if plugin.manifest.batch == true {
            // Einmal mit allen passenden Objekten; Ergebnis neben dem ersten
            enqueue(PluginJob(plugin: plugin, items: fresh.map { (PluginItem(url: $0.url), $0.id) }, automatic: false))
            return
        }
        let replaces = replacesOriginal(plugin)
        for file in fresh {
            enqueue(PluginJob(plugin: plugin, item: PluginItem(url: file.url), anchorFileID: file.id, automatic: false,
                              replacesOriginal: replaces))
        }
        // Keine eigene Meldung: Oben steht gleich „Plugin läuft“
    }

    /// Frisch abgelegte Dateien: je Datei das erste passende Plugin mit „Automatisch“
    func handleDropped(_ files: [ShelfFile]) {
        guard settings.pluginsEnabled, !IntroGate.active else { return }
        // Frisch von der Platte, wie beim Rechtsklick: ein bearbeitetes Plugin läuft mit dem neuen Code
        let automatic = manager.activePlugins.filter { manager.isAutomatic($0) }.compactMap { manager.refreshed($0.id) }
        guard !automatic.isEmpty else { return }
        var started: [String: Int] = [:]
        var blocked = false
        var declined: Set<String> = []
        // Plugins mit `batch`: alles, was zusammen abgelegt wurde, in einem Lauf
        var batches: [(plugin: InstalledPlugin, items: [(item: PluginItem, fileID: UUID)])] = []
        for file in files {
            let item = PluginItem(url: file.url)
            guard let plugin = automatic.first(where: { PluginMatcher.matches($0.manifest.match, item) }) else { continue }
            // Automatisch nur mit Zustimmung, allen Rechten und erlaubten Programmen. Fehlt
            // etwas (etwa nach einem Update, das die Rechte zurücksetzt), jetzt fragen: Wer
            // gerade abgelegt hat, sitzt vor dem Mac. Je Ablegen nur einmal je Plugin.
            guard !declined.contains(plugin.id), prepare(plugin) else {
                if !declined.contains(plugin.id) {
                    PluginLog.shared.record(plugin.id, "fehler", "automatisch nicht gestartet: Zustimmung, Rechte oder Programme nicht erteilt")
                }
                declined.insert(plugin.id)
                blocked = true
                continue
            }
            started[plugin.manifest.title, default: 0] += 1
            if plugin.manifest.batch == true {
                if let index = batches.firstIndex(where: { $0.plugin.id == plugin.id }) {
                    batches[index].items.append((item, file.id))
                } else {
                    batches.append((plugin, [(item, file.id)]))
                }
                continue
            }
            enqueue(PluginJob(plugin: plugin, item: item, anchorFileID: file.id, automatic: true,
                              replacesOriginal: replacesOriginal(plugin)))
        }
        for batch in batches {
            enqueue(PluginJob(plugin: batch.plugin, items: batch.items, automatic: true))
        }
        // Gestartet: keine eigene Meldung, oben steht gleich „Plugin läuft“
        if started.isEmpty && blocked {
            actions?.announce(L("Not started", "Nicht gestartet"), duration: 2)
        }
    }

    /// Eingebaute Aufgabe mit demselben Platzhalter wie ein Plugin (Hochladen in die Cloud).
    /// `identity` gibt Name und Symbol, `work` bekommt den Auftrag (für Fortschritt) und einen
    /// leeren Ausgabeordner; was es dort zurückgibt, erscheint wie Ergebnisse eines Plugins
    /// neben dem ersten Objekt. Fehler mit `CloudError` zeigen Text und Tipp wie bei Plugins.
    /// `placeholder: false`: ohne eigene Kachel; den Fortschritt zeigt dann die Datei selbst
    /// (Cloud, `CloudUploads`)
    func runNative(_ identity: InstalledPlugin, on files: [ShelfFile], placeholder: Bool = true,
                   // Auf dem Hauptthread: Die Arbeit meldet sich in der Ablage (Meldungen, @Published,
                   // Zwischenablage). Was dauert, sind eigene async-Aufrufe, die ihn verlassen
                   work: @escaping @MainActor (PluginJob, URL) async throws -> [URL]) {
        guard !files.isEmpty else { return }
        let job = PluginJob(plugin: identity, items: files.map { (PluginItem(url: $0.url), $0.id) }, automatic: false)
        let output = manager.scratchDirectory.appendingPathComponent(job.id.uuidString, isDirectory: true)
        let task = Task { @MainActor [weak self] in
            let result: Result<[URL], PluginRunError>
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                result = .success(try await work(job, output))
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch let error as CloudError {
                result = .failure(.script(error.message, hint: error.hint))
            } catch {
                result = .failure(job.cancelledByUser ? .cancelled : .script(error.localizedDescription))
            }
            self?.finished(job, result: result, workDirectory: output)
            // Ergebnisse sind schon in die Ablage verschoben (`adoptResults`): Rest wegräumen
            try? FileManager.default.removeItem(at: output)
        }
        job.startNative { task.cancel() }
        jobs.append(job)
        PluginLog.shared.record(identity.id, "start", "\(files.count) Objekt(e)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
            guard placeholder, let self, self.jobs.contains(where: { $0 === job }) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                job.shown = true
                self.objectWillChange.send()
            }
        }
    }

    /// Zustimmung, Rechte und Programme vor dem Start: was fehlt, in einem Fenster
    /// erfragen (ohne Dialoge, etwa in Tests, nur prüfen)
    private func prepare(_ plugin: InstalledPlugin) -> Bool {
        if manager.isFullyAuthorized(plugin) { return true }
        guard showsErrorDialogs else { return false }
        guard PluginDialogs.authorize(plugin, manager: manager, ui: actions?.ui) else {
            PluginLog.shared.record(plugin.id, "recht", "nicht erlaubt")
            return false
        }
        return manager.isFullyAuthorized(plugin)
    }

    /// „Original ersetzen“ ist für dieses Plugin an
    func replacesOriginal(_ plugin: InstalledPlugin) -> Bool {
        // Bei `batch` gibt es kein einzelnes Original, das ersetzt würde
        plugin.manifest.canReplaceOriginal == true && plugin.manifest.batch != true && manager.state(plugin.id).replaceOriginal
    }

    /// Platzhalter, der an der Stelle dieser Datei steht (sie selbst ist dann nicht zu sehen)
    func replacingJob(for fileID: UUID) -> PluginJob? {
        guard !jobs.isEmpty else { return nil }
        return jobs.first { $0.shown && $0.replacesOriginal && $0.anchorFileID == fileID }
    }

    private func enqueue(_ job: PluginJob) {
        jobs.append(job)
        // Erst nach einem Augenblick zeigen; ist der Lauf bis dahin fertig, sieht man nichts
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
            guard let self, self.jobs.contains(where: { $0 === job }) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                job.shown = true
                self.objectWillChange.send()
            }
        }
        if runtimes.count < Self.maxConcurrent { launch(job) } else { waiting.append(job) }
    }

    private func launch(_ job: PluginJob) {
        let work = manager.scratchDirectory.appendingPathComponent(job.id.uuidString, isDirectory: true)
        let plugin = job.plugin
        var values = manager.settingsValues(of: plugin)
        // Derselbe Wert, nach dem die Ablage das Original ausblendet (beim Einreihen
        // festgelegt), auch wenn der Schalter umgelegt wurde, während der Auftrag wartete
        values["replaceOriginal"] = job.replacesOriginal
        let runtime = PluginRuntime(
            job: job, workDirectory: work, tools: tools, prompter: self,
            settingsValues: values,
            granted: Set(plugin.manifest.allPermissions.filter { manager.isGranted($0, for: plugin) }),
            approvedTools: Set(manager.state(plugin.id).approvedTools),
            onGrant: { [weak self] permission in self?.manager.grant(permission, for: plugin) },
            onToolApproved: { [weak self] tool in
                self?.manager.update(plugin.id) { s in if !s.approvedTools.contains(tool) { s.approvedTools.append(tool) } }
            },
            onNotify: { [weak self] text in self?.actions?.announce(text, duration: 2) }
        )
        runtimes[job.id] = runtime
        watchResults()
        // Der Arbeitsordner bleibt, bis alle gestarteten Programme beendet sind
        runtime.onStopped = { try? FileManager.default.removeItem(at: work) }
        PluginLog.shared.record(plugin.id, "start",
                                "\(plugin.manifest.version) \(job.automatic ? "automatisch" : "von Hand")\(job.replacesOriginal ? ", ersetzt Original" : "") · \(job.item.kind.rawValue) „\(job.item.url.lastPathComponent)“\(job.item.link.map { " " + $0.absoluteString } ?? "")\(job.items.count > 1 ? " und \(job.items.count - 1) weitere" : "")")
        runtime.start { [weak self] result in
            self?.finished(job, result: result, workDirectory: work)
        }
    }

    private func finished(_ job: PluginJob, result: Result<[URL], PluginRunError>, workDirectory: URL) {
        runtimes.removeValue(forKey: job.id)
        previewCandidates.removeValue(forKey: job.id)
        watchResults()
        defer {
            if !waiting.isEmpty, runtimes.count < Self.maxConcurrent { launch(waiting.removeFirst()) }
        }
        switch result {
        case .success(let urls):
            PluginLog.shared.record(job.plugin.id, "ok", urls.isEmpty ? "fertig, kein Ergebnis"
                                    : "fertig: " + urls.map { "„\($0.lastPathComponent)“" }.joined(separator: ", "))
            manager.clearError(job.plugin.id)
            deliver(job, urls)
        case .failure(.cancelled):
            PluginLog.shared.record(job.plugin.id, "abbruch", "abgebrochen")
            removeJob(job)   // ohne Meldung: Die Kachel verschwindet
            dropOriginalIfReplacing(job)
        case .failure(let error):
            PluginLog.shared.record(job.plugin.id, "fehler", error.message)
            if let hint = error.hint { PluginLog.shared.record(job.plugin.id, "hinweis", hint) }
            manager.recordError(job.plugin.id, String(error.message.prefix(600)) + (error.hint.map { "\n\n" + $0 } ?? ""))
            // Erst kurz rütteln, damit man sieht, welcher Platzhalter es war, dann weg
            // (Ohne Dialoge, etwa in Tests, gleich weg)
            if showsErrorDialogs && job.shown {
                job.failed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + PluginJobTile.failureDuration) { [weak self] in
                    self?.removeJob(job)
                }
            } else {
                removeJob(job)
            }
            // Kein Fenster zum Wegklicken: Meldung und Tipp stehen in den Details des
            // Plugins (Einstellungen → Plugins) und im Protokoll
            NSSound.beep()
            actions?.announce(L("Failed", "Fehlgeschlagen"), duration: 2.5)
        }
    }

    /// Ergebnis an die Stelle des Platzhalters. Die Vorschaubilder entstehen schon, solange
    /// noch der Platzhalter steht: Die neue Kachel erscheint dann sofort fertig gezeichnet,
    /// nicht erst als leere Fläche oder beim nächsten Öffnen der Ablage.
    private func deliver(_ job: PluginJob, _ urls: [URL]) {
        guard let store, !urls.isEmpty else {
            removeJob(job)
            return
        }
        // Original aus einem angehefteten Ordner: Ergebnis wie im Finder in denselben Ordner
        if store.position(of: job.anchorFileID) == nil, let actions,
           actions.folder.files.contains(where: { $0.id == job.anchorFileID }) {
            return deliverIntoFolder(job, urls, folder: job.item.url.deletingLastPathComponent())
        }
        let files = store.adoptResults(urls)
        guard !files.isEmpty else { return removeJob(job) }
        let size = CGFloat(settings.tileIconSize)
        let previews = files.map(\.url).filter(ThumbnailView.expectsPreview)
        Task { @MainActor [weak self] in
            // Höchstens kurz warten: Liefert Quick Look nichts, kommt das Symbol
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for url in previews {
                        _ = await Thumbnails.load(url, size: size)
                    }
                }
                group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                await group.next()
                group.cancelAll()
            }
            self?.place(job, files)
        }
    }

    private func place(_ job: PluginJob, _ files: [ShelfFile]) {
        guard let store else { return }
        for file in files { Thumbnails.shownOnce.insert(file.url.path) }
        store.insertResults(files, nextTo: job.anchorFileID, replacing: job.replacesOriginal)
        removeJob(job, animated: false)
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
        if let actions {
            let ids = Set(files.map(\.id))
            if actions.isInStack {
                actions.ui.memberSelection = ids.intersection(actions.stackFiles.map(\.id))
            } else {
                actions.ui.selection = Set(store.entries.filter { $0.files.contains { ids.contains($0.id) } }.map(\.id))
            }
        }
    }

    /// Ergebnisse in den Ordner des Originals legen (Namen wie im Finder eindeutig machen)
    private func deliverIntoFolder(_ job: PluginJob, _ urls: [URL], folder: URL) {
        let fm = FileManager.default
        var placed: [URL] = []
        for url in urls {
            let target = ShelfActions.uniqueURL(for: url.lastPathComponent, in: folder)
            do {
                try fm.moveItem(at: url, to: target)
                placed.append(target)
            } catch {
                Diagnostics.shared.failure("plugin", "Ergebnis in den Ordner legen fehlgeschlagen", error)
            }
        }
        removeJob(job, animated: false)
        if placed.count < urls.count { NSSound.beep() }
        guard let actions, !placed.isEmpty else { return }
        actions.folder.reload(after: 0)
        if actions.isFolderOpen {
            actions.ui.memberSelection = Set(placed.map(FolderBrowser.id(for:)))
        }
    }

    private func removeJob(_ job: PluginJob, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { jobs.removeAll { $0.id == job.id } }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { jobs.removeAll { $0.id == job.id } }
        }
        waiting.removeAll { $0.id == job.id }
        actions?.ui.jobSelection.remove(job.id)
    }

    // MARK: Vorschau des Ergebnisses

    /// Solange Plugins laufen, zweimal pro Sekunde in ihre Ausgabeordner sehen
    private func watchResults() {
        if runtimes.isEmpty {
            previewTimer?.invalidate()
            previewTimer = nil
            previewCandidates = [:]
            return
        }
        guard previewTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.scanResults() }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    /// Die neueste fertige Datei eines Laufs wird zur Vorschau, sobald sie zweimal
    /// hintereinander gleich groß ist: Eine Datei, die noch geschrieben wird, gäbe ein
    /// halbes oder kaputtes Vorschaubild.
    private func scanResults() {
        for (id, runtime) in runtimes {
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            // Was gerade entsteht, auch halb geschrieben: Der Platzhalter zeigt schon sein Symbol
            // Nur einmal festlegen: Programme schreiben oft mehrere Teile nacheinander (Bild,
            // Ton, Zwischenstände). Sprang das Symbol mit, flackerte der Platzhalter.
            if job.resultPreview == nil, job.resultType == nil, let type = Self.typeInProgress(in: runtime.outputDirectory) {
                job.resultType = type
            }
            guard let candidate = Self.newestResult(in: runtime.outputDirectory) else { continue }
            let previous = previewCandidates[id]
            previewCandidates[id] = candidate
            guard previous?.url == candidate.url, previous?.size == candidate.size,
                  job.resultPreview != candidate.url else { continue }
            job.resultPreview = candidate.url
            NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
        }
    }

    /// Art der größten Datei im Ausgabeordner, auch wenn sie noch geschrieben wird. Endungen
    /// halb geladener Dateien zählen nicht: „film.mp4.part“ ist ein Video. Die größte statt
    /// der neuesten: Kleine Nebendateien (Ton, Notizen des Programms) ändern nichts.
    static func typeInProgress(in directory: URL) -> UTType? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var best: (type: UTType, size: Int)?
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            var name = url
            while PluginRuntime.partialExtensions.contains(name.pathExtension.lowercased()) {
                name = name.deletingPathExtension()
            }
            guard !name.pathExtension.isEmpty, let type = UTType(filenameExtension: name.pathExtension),
                  type.isDeclared, type != .data else { continue }
            if best == nil || size > best!.size { best = (type, size) }
        }
        return best?.type
    }

    /// Neueste fertige Datei im Ausgabeordner (keine versteckten, halb geladenen oder leeren)

    static func newestResult(in directory: URL) -> (url: URL, size: Int)? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, size: Int, date: Date)?
        for url in urls where !PluginRuntime.partialExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (url, size, date) }
        }
        return best.map { ($0.url, $0.size) }
    }

    /// Abbrechen auch, solange ein Plugin noch wartet. `inShelf`: in der Ablage abgebrochen
    /// (x, ⌫, Menü), nicht über die Einstellungen oder weil das Plugin aus ist
    func cancel(_ job: PluginJob, inShelf: Bool = true) {
        job.cancelledByUser = inShelf
        if waiting.contains(where: { $0.id == job.id }) {
            removeJob(job)
            dropOriginalIfReplacing(job)
            return
        }
        job.cancel()
    }

    /// Bei „Original ersetzen“ stand der Platzhalter schon an der Stelle des Originals: Wer
    /// abbricht, will es dort nicht wieder sehen. Es verlässt die Ablage (⌘Z holt es zurück,
    /// die Datei im Finder bleibt).
    private func dropOriginalIfReplacing(_ job: PluginJob) {
        guard job.replacesOriginal, job.cancelledByUser, let store,
              store.position(of: job.anchorFileID) != nil else { return }
        // Läuft noch ein anderes Plugin für dasselbe Original, bleibt es stehen
        guard !jobs.contains(where: { $0.anchorFileID == job.anchorFileID && $0.id != job.id }) else { return }
        store.removeQuietly(job.anchorFileID)
    }

    /// Beim Beenden: laufende Plugins abbrechen
    func cancelAll() {
        waiting.removeAll()
        runtimes.values.forEach { $0.cancel() }
    }

    // MARK: Rückfragen

    // Vor dem Start ist alles erteilt (`prepare`). Fehlt mitten im Lauf doch noch etwas
    // (etwa weil das Plugin gerade geändert wurde), kommt dasselbe eine Fenster.

    func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
        PluginDialogs.authorize(plugin, manager: manager, ui: actions?.ui)
    }

    func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool {
        PluginDialogs.authorize(plugin, manager: manager, ui: actions?.ui)
    }
}
