import AppKit
import Combine
import SwiftUI
import Quartz
import UniformTypeIdentifiers

/// Alle Aktionen auf Einträgen der Ablage (Kontextmenü, Tastatur, Aktionsleiste).
final class ShelfActions: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSSharingServicePickerDelegate {
    let store: ShelfStore
    let ui: ShelfUIModel
    /// Losgelöst schwebend (vom Rand-Controller gesetzt)
    var isFloating: () -> Bool = { false }
    /// Die schwebende Ablage zurück an ihren Rand legen
    var returnToEdge: (() -> Void)?
    let settings: AppSettings
    var openSettings: () -> Void = {}
    weak var panel: NSPanel?

    private var previewURLs: [URL] = []
    /// Die Übersicht zeigt mehrere ausgewählte Objekte: Dann blättert sie selbst darin
    var quickLookPagesSelection = false

    /// Plugins: laufen lassen, Platzhalter, Ergebnisse (erst beim ersten Gebrauch angelegt;
    /// Tests setzen einen eigenen)
    lazy var plugins = PluginRunner(actions: self)

    /// Angehefteter Ordner, dessen Inhalt gerade wie ein Stapel zu sehen ist
    let folder = FolderBrowser()
    private var folderClosing: AnyCancellable?

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
        super.init()
        // Ordneransicht verlassen (auch beim Schließen der Ablage): nicht mehr beobachten
        folderClosing = ui.$openStack.sink { [weak self] id in
            guard let self, id != FolderBrowser.entryID, self.folder.isOpen else { return }
            self.folder.close()
        }
        folder.onVanished = { [weak self] in
            guard let self, self.ui.openStack == FolderBrowser.entryID else { return }
            self.ui.memberSelection = []
            withAnimation(self.settings.animationStyle.close) { self.ui.openStack = nil }
        }
        store.onUserDrop = { [weak self] files in
            guard let self, self.settings.pluginsEnabled else { return }
            self.plugins.handleDropped(files)
        }
    }

    // MARK: Reihenfolge und Auswahl

    /// Einträge in der gezeigten Reihenfolge: neueste zuerst, wie gespeichert
    var orderedEntries: [ShelfEntry] { store.entries }

    var selectedEntries: [ShelfEntry] {
        orderedEntries.filter { ui.selection.contains($0.id) }
    }

    /// Die ausgewählten Einträge, oder nur `entry`, wenn er nicht zur Auswahl gehört.
    func targets(for entry: ShelfEntry) -> [ShelfEntry] {
        ui.selection.contains(entry.id) ? selectedEntries : [entry]
    }

    func select(_ entry: ShelfEntry, modifiers: NSEvent.ModifierFlags) {
        if modifiers.isDisjoint(with: [.command, .shift]) { ui.jobSelection = [] }
        if modifiers.contains(.command) {
            if ui.selection.contains(entry.id) { ui.selection.remove(entry.id) } else { ui.selection.insert(entry.id) }
            ui.selectionAnchor = entry.id
        } else if modifiers.contains(.shift),
                  let anchor = ui.selectionAnchor,
                  case let ordered = orderedEntries,
                  let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == entry.id }) {
            ui.selection = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else if !ui.selection.contains(entry.id) || ui.selection.count == 1 {
            ui.selection = [entry.id]
            ui.selectionAnchor = entry.id
        }
    }

    /// Normaler Klick ohne Ziehen: Auswahl auf dieses Objekt reduzieren.
    func clickedWithoutDrag(_ entry: ShelfEntry, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.isDisjoint(with: [.command, .shift]) else { return }
        if entry.isStack {
            openStack(entry)            // Klick auf einen Stapel: hineingehen
        } else {
            ui.selection = [entry.id]
            ui.selectionAnchor = entry.id
        }
    }

    func selectAll() {
        ui.selection = Set(store.entries.map(\.id))
        ui.selectionAnchor = orderedEntries.first?.id
    }

    func clearSelection() {
        ui.selection = []
        ui.jobSelection = []
    }

    /// Spalten des Rasters, wie es `ShelfContent` anlegt (Kachel mindestens Symbol + 22 pt, 8 pt Abstand)
    var columnCount: Int {
        let usable = CGFloat(settings.shelfWidth) - 24
        let tile = CGFloat(settings.tileIconSize) + 22
        return max(1, Int((usable + 8) / (tile + 8)))
    }

    // MARK: Aktionen auf Einträgen

    func open(_ entries: [ShelfEntry]) {
        let urls = entries.flatMap(\.urls)
        // ZIP-Archive werden in der Ablage entpackt: Sonst landete der Inhalt unsichtbar
        // neben dem Archiv in BarDrops eigenem Speicher
        urls.filter { !Self.isZip($0) }.forEach { NSWorkspace.shared.open($0) }
        let zips = urls.filter(Self.isZip)
        if !zips.isEmpty { unzip(zips) }
    }

    // MARK: Entpacken

    /// ZIP-Archiv (nach Dateityp)
    static func isZip(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .zip)
    }

    /// Entpackt ZIP-Archive direkt in die Ablage, neben das Archiv: mehrere Dateien als ein
    /// Stapel, eine einzelne als eigenes Objekt
    func unzip(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        announce(L("Unzipping", "Entpacken"))
        for url in urls {
            let anchor = store.entries.flatMap(\.files).first { $0.url == url }?.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Self.extract(url)
                DispatchQueue.main.async { [weak self] in
                    self?.placeUnzipped(result?.items, nextTo: anchor)
                    if let dir = result?.dir { try? FileManager.default.removeItem(at: dir) }
                }
            }
        }
    }

    /// Entpackt mit ditto (wie das Archivierungsprogramm) in einen eigenen Ordner und liefert
    /// dessen oberste Einträge, ohne die Begleitdaten aus macOS (__MACOSX, versteckte Dateien)
    private static func extract(_ zip: URL) -> (dir: URL, items: [URL])? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("BarDropEntpacken-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, dir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? fm.removeItem(at: dir)
                return nil
            }
            let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent != "__MACOSX" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return (dir, items)
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    private func placeUnzipped(_ urls: [URL]?, nextTo anchor: UUID?) {
        guard let urls, !urls.isEmpty else {
            NSSound.beep()
            announce(L("Couldn’t unzip", "Nicht entpackt"))
            return
        }
        let files = store.adoptResults(urls)
        guard !files.isEmpty else {
            NSSound.beep()
            announce(L("Couldn’t unzip", "Nicht entpackt"))
            return
        }
        store.insertUnpacked(files, nextTo: anchor)
        let ids = Set(files.map(\.id))
        ui.selection = Set(store.entries.filter { $0.files.contains { ids.contains($0.id) } }.map(\.id))
        announce(L("Unzipped", "Entpackt"))
    }

    func reveal(_ entries: [ShelfEntry]) {
        reveal(entries.flatMap(\.urls))
    }

    func copy(_ entries: [ShelfEntry]) {
        Self.copyFiles(entries.flatMap(\.urls))
    }

    /// Legt die Dateien selbst in die Zwischenablage (zum Einfügen im Finder, in Mail …).
    static func copyFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// Kopiert nur die Dateipfade als Text (mehrere: je Zeile ein Pfad), wie ⌥⌘C im Finder.
    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// `sound`: Klang des Papierkorbs wie im Finder (nicht beim Ausschneiden)
    func remove(_ entries: [ShelfEntry], sound: Bool = true) {
        guard !entries.isEmpty else { return }
        Diagnostics.shared.record("remove", "entries=\(entries.count) sound=\(sound)")
        let ids = Set(entries.map(\.id))
        let count = entries.reduce(0) { $0 + $1.files.count }
        // Erst den Stapel verlassen (das wählt ihn aus), dann die Auswahl bereinigen
        if let open = ui.openStack, ids.contains(open) { closeStack() }
        ui.selection.subtract(ids)
        store.remove(ids)
        announceRemoval(count)
        if sound { Sounds.remove() }
    }

    // MARK: Rückmeldung und Widerrufen

    /// Zeigt kurz eine Rückmeldung oben in der Ablage an Stelle der Anzahl.
    /// `duration`: wie lange (Standard: 2 s, mit Widerrufen 3 s)
    func announce(_ text: String, canUndo: Bool = false, duration: TimeInterval? = nil) {
        let notice = ShelfUIModel.Notice(text: text, canUndo: canUndo)
        withAnimation(.easeOut(duration: 0.18)) { ui.notice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? (canUndo ? 3 : 2))) { [weak self] in
            guard let self, self.ui.notice?.id == notice.id else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.ui.notice = nil }
        }
    }

    func announceRemoval(_ count: Int) {
        guard count > 0 else { return }
        announce(L("Removed", "Entfernt"), canUndo: true)
    }

    /// ⌘Z: zuletzt Entferntes zurückholen und auswählen.
    func undo() {
        Diagnostics.shared.record("undo", "canUndo=\(store.undoManager.canUndo) action=\(store.undoManager.undoActionName)")
        guard store.undoManager.canUndo else { return NSSound.beep() }
        let restored = store.undoLast()
        if restored.isEmpty, !store.lastPutBack.isEmpty {
            // Papierkorb aus einem angehefteten Ordner: zurück an den alten Platz
            let back = store.lastPutBack
            folder.reload(after: 0)
            if isFolderOpen { ui.memberSelection = Set(back.map(FolderBrowser.id(for:))) }
            announce(L("Restored", "Wiederhergestellt"))
            return
        }
        // Nichts mehr da, was sich zurückholen ließe
        guard !restored.isEmpty else { return NSSound.beep() }
        if isInStack {
            ui.memberSelection = Set(stackFiles.map(\.id)).intersection(restored)
        } else {
            ui.selection = Set(store.entries.filter { entry in entry.files.contains { restored.contains($0.id) } }.map(\.id))
        }
        announce(L("Restored", "Wiederhergestellt"))
    }

    /// ⇧⌘Z: Widerrufenes erneut entfernen.
    func redo() {
        let manager = store.undoManager
        guard manager.canRedo else { return NSSound.beep() }
        let before = store.entries.reduce(0) { $0 + $1.files.count }
        manager.redo()
        let after = store.entries.reduce(0) { $0 + $1.files.count }
        ui.selection.formIntersection(Set(store.entries.map(\.id)))
        ui.memberSelection.formIntersection(Set(store.entries.flatMap(\.files).map(\.id)))
        announceRemoval(before - after)
    }

    /// Dateien zum Herausziehen. Fehlende Dateien werden nicht angeboten (sonst meldet
    /// das Ziel einen Fehler) und die Ablage räumt sie anschließend auf.
    func dragFiles(for entry: ShelfEntry) -> [ShelfFile] {
        existingForDrag(targets(for: entry).flatMap(\.files))
    }

    func existingForDrag(_ files: [ShelfFile]) -> [ShelfFile] {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if existing.count != files.count {
            DispatchQueue.main.async { [weak self] in self?.store.pruneMissingFiles() }
            if existing.isEmpty { NSSound.beep() }
        }
        return existing
    }

    /// Nach dem Herausziehen: je nach Einstellung aus der Ablage nehmen. Eigene Dateien
    /// werden erst gelöscht, wenn das Ziel sie fertig kopiert hat (nach perch); schlägt
    /// das Kopieren fehl, kommen sie zurück.
    func dragEnded(_ files: [ShelfFile], operation: NSDragOperation) {
        let internalDrop = ui.lastDropWasInternal
        ui.lastDropWasInternal = false
        Diagnostics.shared.record("dragOut", "ended operation=\(operation.rawValue) internal=\(internalDrop) files=\(Diagnostics.anon(files.map(\.url)))")
        // Aus einem angehefteten Ordner gezogen: Die Dateien gehören dem Ordner, die Ablage
        // bleibt, wie sie ist (verschoben hat sie schon das Ziel, wie im Finder)
        let fromFolder = !files.isEmpty && files.allSatisfy { FolderBrowser.id(for: $0.url) == $0.id }
        if fromFolder { folder.reload() }
        if !operation.isEmpty && !internalDrop && settings.removeAfterDragOut && !fromFolder {
            let urls = files.map(\.url).filter { !DragExporter.shared.failedRecently($0) }
            store.removeFiles(at: urls, deleteOwnedAfter: 15 * 60)
            let remaining = Set(store.entries.map(\.id))
            ui.selection.formIntersection(remaining)
            ui.memberSelection.formIntersection(Set(store.entries.flatMap(\.files).map(\.id)))
        }
        // Ein Ziel kann Dateien verschoben haben: über das Lesezeichen wiederfinden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.store.pruneMissingFiles()
        }
    }

    // MARK: Quick Look
    //
    // Wie im Finder und in Apples Beispiel (QuickLookDownloader): BarDrop ist dabei aktiv,
    // die Ablage ist das Hauptfenster und steuert die Übersicht (ShelfPanel.
    // acceptsPreviewPanelControl), die Übersicht selbst hat den Tastaturfokus.
    //
    // Vorher ging die Übersicht auf, ohne BarDrop zu aktivieren und ohne Hauptfenster. Laut
    // Diagnoseprotokoll nahm sie sich dann den Fokus selbst, während BarDrop nicht aktiv
    // war, und Tasten gingen an die App dahinter; ohne Hauptfenster fand sie zeitweise keine
    // Steuerung und zeigte „Keine Objekte ausgewählt“.

    /// Soll die Übersicht offen sein? Gilt statt `isVisible`: Beim Ein- und Ausblenden meldet
    /// die Übersicht noch den alten Zustand, und schnelles Drücken überholte sich sonst.
    private var quickLookWanted = false
    private var quickLookChangedAt = Date.distantPast
    private var quickLookGeneration = 0
    /// So lange gilt allein der eigene Stand (Ein- und Ausblenden dauern etwa 0,25 s)
    private static let quickLookSettle: TimeInterval = 0.6

    private var shelfPanel: ShelfPanel? { panel as? ShelfPanel }

    /// Wurde die Übersicht geöffnet und noch nicht geschlossen? Ohne Abgleich mit macOS
    var quickLookRequested: Bool { quickLookWanted }

    private func markQuickLook(wanted: Bool) {
        quickLookWanted = wanted
        quickLookChangedAt = Date()
        quickLookGeneration += 1
    }

    /// Ist die Übersicht offen? Schließt sie sich selbst (ihr Knopf, macOS blendet sie aus,
    /// weil eine andere App vorn ist), merkt das der nächste Blick nach der Übergangszeit.
    var isQuickLookVisible: Bool {
        if quickLookWanted, Date().timeIntervalSince(quickLookChangedAt) > Self.quickLookSettle,
           !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) {
            quickLookWanted = false
            shelfPanel?.allowsMain = false
        }
        return quickLookWanted
    }

    func quickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewURLs = urls
        let ql = QLPreviewPanel.shared()!
        if isQuickLookVisible && ql.isVisible {
            // Schon offen: nur den Inhalt wechseln
            ql.reloadData()
            ql.currentPreviewItemIndex = 0
            return
        }
        markQuickLook(wanted: true)
        let generation = quickLookGeneration
        // BarDrop aktivieren, ohne die Einstellungen nach vorn zu holen. Gewartet wird nur auf
        // die Bestätigung des Systems; Tasten bleiben so lange in der Warteschlange und kommen
        // danach in der richtigen Reihenfolge an (schnelles Drücken geht nicht verloren).
        AppActivation.activateKeepingWindows(timeout: 0.3)
        guard generation == quickLookGeneration else { return }
        showQuickLook(ql)
        // Kam die Aktivierung doch später an, gab macOS den Fokus der Ablage zurück: dann
        // der Übersicht wiedergeben. Ist sie gar nicht erschienen, noch einmal zeigen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.quickLookGeneration, self.quickLookWanted else { return }
            if !ql.isVisible {
                Diagnostics.shared.record("focus", "quick look shown again")
                self.showQuickLook(ql)
            } else if NSApp.keyWindow === self.panel {
                Diagnostics.shared.record("focus", "quick look key again")
                ql.makeKey()
            }
        }
    }

    private func showQuickLook(_ ql: QLPreviewPanel) {
        // Die Ablage wird Hauptfenster: Dort sucht die Übersicht ihre Steuerung, während sie
        // selbst den Fokus hat
        shelfPanel?.allowsMain = true
        panel?.makeKey()
        panel?.makeMain()
        placeOnShelfScreen(ql)
        ql.updateController()
        // Sollte sie trotzdem keine Steuerung finden: Inhalt direkt geben
        if (ql.dataSource as AnyObject?) !== self {
            ql.dataSource = self
            ql.delegate = self
        }
        ql.reloadData()
        // Sie merkt sich das zuletzt gezeigte Objekt; nach dreien und jetzt einem fand sie keins
        ql.currentPreviewItemIndex = 0
        ql.makeKeyAndOrderFront(nil)
        // Quick Look stellt beim Öffnen manchmal seinen alten Ort wieder her
        DispatchQueue.main.async { [weak self] in self?.placeOnShelfScreen(ql) }
        Diagnostics.shared.record("focus", "quick look shown frontmost=\(AppActivation.isFrontmost) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "–") main=\(NSApp.mainWindow.map { String(describing: type(of: $0)) } ?? "–") controlled=\((ql.dataSource as AnyObject?) === self)")
    }

    func closeQuickLook() {
        guard quickLookWanted || (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
        markQuickLook(wanted: false)
        let generation = quickLookGeneration
        let ql = QLPreviewPanel.shared()!
        ql.orderOut(nil)
        // Weiter in der Ablage: Sie bekommt den Fokus, BarDrop bleibt aktiv, bis sie schließt
        if ui.level == .expanded { panel?.makeKey() }
        shelfPanel?.allowsMain = false
        // Erst nach dem Ausblenden prüfen, ob sie wirklich zu ist (ein zweites Schließen mitten
        // im Ausblenden gab ihr laut Protokoll den Fokus)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, generation == self.quickLookGeneration, !self.quickLookWanted else { return }
            if ql.isVisible {
                Diagnostics.shared.record("focus", "quick look closed again")
                ql.orderOut(nil)
            }
            if self.ui.level == .expanded, NSApp.keyWindow == nil || NSApp.keyWindow === ql {
                self.panel?.makeKey()
            }
        }
    }

    /// Pfeiltasten in der Ablage, während die Übersicht offen ist: Die Übersicht zeigt das
    /// neu ausgewählte Objekt, wie im Finder. Zeigt sie mehrere ausgewählte Objekte,
    /// blättern ← und → darin (true: Taste ist damit erledigt).
    func quickLookArrow(_ keyCode: UInt16) -> Bool {
        guard isQuickLookVisible else { return false }
        let ql = QLPreviewPanel.shared()!
        if quickLookPagesSelection {
            guard keyCode == 123 || keyCode == 124, previewURLs.count > 1 else { return true }
            let next = ql.currentPreviewItemIndex + (keyCode == 123 ? -1 : 1)
            ql.currentPreviewItemIndex = min(max(next, 0), previewURLs.count - 1)
            return true
        }
        return false
    }

    /// Nach dem Bewegen der Auswahl: die Übersicht zeigt das neue Objekt
    func quickLookFollowSelection() {
        guard isQuickLookVisible, !quickLookPagesSelection else { return }
        let urls = currentSelectionURLs
        guard !urls.isEmpty, urls != previewURLs else { return }
        previewURLs = urls
        QLPreviewPanel.shared().reloadData()
        QLPreviewPanel.shared().currentPreviewItemIndex = 0
    }

    /// Die Übersicht erscheint auf dem Bildschirm, auf dem gerade die Ablage ist.
    /// Liegt sie dort schon, bleibt sie, wo der Nutzer sie hingeschoben hat.
    private func placeOnShelfScreen(_ window: NSWindow) {
        guard let screen = panel?.screen ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        guard !vf.contains(center) else { return }
        let width = min(max(window.frame.width, 480), vf.width * 0.8)
        let height = min(max(window.frame.height, 360), vf.height * 0.8)
        let frame = NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height)
        window.setFrame(frame, display: true)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
    }

    /// Tasten, während die Übersicht den Fokus hat: wie in Apples Beispiel alle an die Ablage
    /// weiterreichen. So gilt überall dieselbe Belegung (ShelfPanel.keyDown): Leertaste und
    /// esc schließen, Pfeile wandern durch die Objekte oder blättern, ⌘-Kürzel wirken.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let shelf = shelfPanel else { return false }
        if event.keyCode == 49 { Diagnostics.shared.record("key", "space in quick look") }
        if event.modifierFlags.contains(.command) {
            return shelf.performKeyEquivalent(with: event)
        }
        shelf.keyDown(with: event)
        return true
    }

    // MARK: Teilen (verankert an der Kachel bzw. am Aktionssymbol)

    /// Dateien, die nach erfolgreichem Teilen aus der Ablage genommen werden (Aktionsleiste).
    private var shareFinishURLs: [URL]?

    func share(_ urls: [URL], from anchor: NSView, fromAction: Bool = false) {
        guard !urls.isEmpty else { return }
        ui.sharingOpen = true
        shareFinishURLs = fromAction ? urls : nil
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        let edge: NSRectEdge = settings.edge == .right ? .minX : .maxX
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        ui.sharingOpen = false
        if service != nil {
            AppActivation.activateKeepingWindows()
            if let urls = shareFinishURLs { finishAction(urls) }
        }
        shareFinishURLs = nil
    }

    // MARK: Aktionsleiste

    /// `modifiers`: beim Klick bzw. Loslassen gedrückte Tasten (⌥ kopiert, ⌘ verschiebt)
    /// Eine Aktion der Leiste wurde mit Objekten ausgeführt (userInfo: "urls", "kind")
    static let didPerformAction = Notification.Name("BarDropDidPerformAction")

    /// Klick auf eine Aktion: Sie läuft nicht mit der Auswahl (dafür Objekte darauf ziehen).
    /// Ein Ordner zeigt seinen Inhalt in der Ablage, eine App öffnet sich.
    func click(_ action: QuickAction) {
        Diagnostics.shared.record("action", "click \(action.kind.rawValue)")
        switch action.kind {
        case .folder:
            guard let url = action.url, FolderBrowser.isBrowsable(url) else { return NSSound.beep() }
            if isFolderOpen, folder.root?.standardizedFileURL == url.standardizedFileURL {
                // Derselbe Ordner noch einmal: Er bleibt offen. Aus einem Unterordner geht es
                // zurück zu seiner obersten Ebene, sonst passiert nichts
                if folder.isNested { openFolder(url) }
            } else {
                openFolder(url)
            }
        case .app:
            guard let url = action.url else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    func perform(_ action: QuickAction, urls: [URL], anchor: NSView,
                 modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        Diagnostics.shared.record("action", "\(action.kind.rawValue) items=\(urls.count) modifiers=\(modifiers.rawValue) files=\(Diagnostics.anon(urls))")
        if !urls.isEmpty {
            NotificationCenter.default.post(name: Self.didPerformAction, object: self,
                                            userInfo: ["urls": urls, "kind": action.kind.rawValue])
        }
        guard !urls.isEmpty else { return }
        switch action.kind {
        case .airdrop:
            if performService(.sendViaAirDrop, urls: urls) { finishAction(urls) }
        case .mail:
            if performService(.composeEmail, urls: urls) { finishAction(urls) }
        case .messages:
            if performService(.composeMessage, urls: urls) { finishAction(urls) }
        case .share:
            share(urls, from: anchor, fromAction: true)
        case .app:
            guard let app = action.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            finishAction(urls)
        case .folder:
            guard let folder = action.url else { return }
            // Wie Verschieben im Finder: Was im Ordner gelandet ist, verlässt die Ablage immer,
            // auch beim Kopieren (andere Platte, ⌥) und unabhängig von „Nach Aktion behalten“
            file(urls, into: folder, modifiers: modifiers) { [weak self] used in self?.finishAction(used, always: true) }
        case .convert:
            break   // gibt es nicht mehr als Aktion
        case .trash:
            ui.selection = []
            moveToTrash(urls)
        case .plugin:
            guard let id = action.path else { return }
            let keys = Set(urls.map(\.standardizedFileURL))
            let known = store.entries.flatMap(\.files) + folder.files
            var seen = Set<URL>()
            let files = known.filter { keys.contains($0.url.standardizedFileURL) && seen.insert($0.url.standardizedFileURL).inserted }
            plugins.run(id, on: files)
        case .shortcut:
            guard let name = action.path else { return }
            runShortcut(name, on: urls)
        }
    }

    /// Nur für einen Kurzbefehl in die Ablage übernommen (von außen direkt auf die Aktion
    /// gezogen, z. B. Bilder aus dem Web): Nach dem Lauf verlassen sie die Ablage immer
    var shortcutOnlyInputs = Set<URL>()

    /// Kurzbefehl mit den Dateien ausführen; was er zurückgibt, kommt in die Ablage
    private func runShortcut(_ name: String, on urls: [URL]) {
        // Kurz, der Platz oben rechts ist klein; der Name steht schon an der Aktion
        announce(L("Running shortcut", "Kurzbefehl läuft"))
        ShortcutRunner.run(name, inputs: urls) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failed:
                self.shortcutOnlyInputs.subtract(urls)
                NSSound.beep()
                self.announce(L("Shortcut failed", "Kurzbefehl fehlgeschlagen"))
            case .done(let results, let folder):
                // Wie bei den anderen Aktionen: Verwendetes verlässt die Ablage (außer
                // „Nach dem Verwenden“ sagt behalten), es bleibt nur, was herauskam
                self.finishAction(urls)
                let transient = urls.filter { self.shortcutOnlyInputs.contains($0) }
                self.shortcutOnlyInputs.subtract(urls)
                if !transient.isEmpty { self.store.removeFiles(at: transient, deleteOwnedAfter: 15 * 60) }
                guard !results.isEmpty else {
                    if let folder { try? FileManager.default.removeItem(at: folder) }
                    self.announce(L("Done", "Fertig"))
                    return
                }
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.shortcut"))
                pasteboard.clearContents()
                pasteboard.writeObjects(results as [NSURL])
                self.store.ingest(from: pasteboard) { [weak self] added in
                    if let folder {
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                            try? FileManager.default.removeItem(at: folder)
                        }
                    }
                    self?.announce(L("Done", "Fertig"))
                }
            }
        }
    }

    /// Wie im Finder in den Papierkorb (Aktion, ⌘⌫ und Kontextmenü). Danach sind die
    /// Dateien nicht mehr in der Ablage; ⌘Z legt sie zurück, auch an ihren alten Ort.
    func moveToTrash(_ urls: [URL], then: @escaping () -> Void = {}) {
        guard !urls.isEmpty else { return }
        // Aus einem angehefteten Ordner: ⌘Z legt sie nur dorthin zurück, nicht in die Ablage
        store.moveToTrash(urls, intoShelf: !isFolderOpen) { [weak self] count in
            defer { then() }
            guard let self else { return }
            if count < urls.count { NSSound.beep() }
            guard count > 0 else { return }
            Sounds.trash()
            TrashState.shared.refresh()
            // Das Dock trägt den vollen Papierkorb manchmal erst einen Moment später ein
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TrashState.shared.refresh() }
            self.ui.selection.formIntersection(Set(self.store.entries.map(\.id)))
            self.ui.memberSelection.formIntersection(Set(self.store.entries.flatMap(\.files).map(\.id)))
            if let open = self.ui.openStack, open != FolderBrowser.entryID,
               !self.store.entries.contains(where: { $0.id == open }) {
                self.closeStack()
            }
            if self.folder.isOpen { self.folder.reload(after: 0) }
            self.announce(L("Deleted", "Gelöscht"), canUndo: true)
        }
    }

    /// „Umwandeln“ als Untermenü: Es öffnet sich neben dem Menü, das stehen bleibt.
    private func convertMenuItem(for urls: [URL], anchor: NSView) -> NSMenuItem? {
        let groups = Converter.targets(for: urls).filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }
        let submenu = NSMenu()
        for (index, group) in groups.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            for target in group {
                submenu.addItem(ClosureMenuItem(target.title) { [weak self] in self?.convert(urls, to: target) })
            }
        }
        let item = NSMenuItem(title: L("Convert", "Umwandeln"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func convert(_ urls: [URL], to target: Converter.Target) {
        announce(L("Converting", "Umwandeln"))
        Converter.convert(urls, to: target) { [weak self] results in
            guard let self else { return }
            guard !results.isEmpty else {
                NSSound.beep()
                self.announce(L("Couldn’t convert", "Nicht umgewandelt"))
                return
            }
            // Wie hineingezogene Dateien übernehmen; der Zwischenordner wird danach gelöscht
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.convert"))
            pasteboard.clearContents()
            pasteboard.writeObjects(results as [NSURL])
            self.store.ingest(from: pasteboard) { [weak self] added in
                if let dir = results.first?.deletingLastPathComponent() {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                        try? FileManager.default.removeItem(at: dir)
                    }
                }
                let n = added.count
                self?.announce(n > 0 ? L("Converted", "Umgewandelt") : L("Couldn’t convert", "Nicht umgewandelt"))
            }
        }
    }

    /// Nach einer Schnellaktion: Objekte aus der Ablage nehmen, außer „Nach Aktionen behalten“ ist an.
    private func finishAction(_ urls: [URL], always: Bool = false) {
        guard always || !settings.keepAfterAction else { return }
        ui.selection = []
        store.removeFiles(at: urls, deleteOwnedAfter: 15 * 60)
    }

    @discardableResult
    private func performService(_ name: NSSharingService.Name, urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: name), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return false
        }
        AppActivation.activateKeepingWindows()
        service.perform(withItems: urls)
        return true
    }

    /// Was die Ordner-Aktion mit einer Datei macht, wie beim Ablegen auf einen Ordner im
    /// Finder: auf derselben Platte verschieben, sonst kopieren; ⌥ kopiert immer, ⌘
    /// verschiebt immer.
    static func folderOperation(for url: URL, into folder: URL,
                                modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }
        return sameVolume(url, folder) ? .move : .copy
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = (try? a.resourceValues(forKeys: key))?.volumeIdentifier,
              let vb = (try? b.resourceValues(forKeys: key))?.volumeIdentifier else {
            // Unbekannt: wie der Finder bei getrennten Platten lieber kopieren
            return false
        }
        return va.isEqual(vb)
    }

    /// Legt Dateien im Hintergrund in einen Ordner (über Laufwerksgrenzen hinweg kann das
    /// dauern) und meldet auf dem Hauptthread die verwendeten Objekte der Ablage:
    /// verschobene unter ihrer neuen Adresse, kopierte unter ihrer alten.
    private func file(_ urls: [URL], into folder: URL, modifiers: NSEvent.ModifierFlags,
                      completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager()
            var moves: [(URL, URL)] = []
            var used: [URL] = []
            var failed = false
            /// Wirklich verschoben oder kopiert (für den Klang)
            var filed = 0
            for url in urls {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    used.append(url)     // liegt schon dort, wie im Finder: nichts tun
                    continue
                }
                let target = Self.uniqueURL(for: url.lastPathComponent, in: folder)
                do {
                    if Self.folderOperation(for: url, into: folder, modifiers: modifiers) == .copy {
                        try fm.copyItem(at: url, to: target)
                        used.append(url)
                        filed += 1
                    } else {
                        try fm.moveItem(at: url, to: target)
                        moves.append((url, target))
                        filed += 1
                    }
                } catch {
                    failed = true
                    Log.export.error("Ablegen im Ordner fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                    Diagnostics.shared.failure("folder", "Ablegen im Ordner fehlgeschlagen", error)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if failed { NSSound.beep() }
                if filed > 0 { Sounds.folder() }
                for (old, new) in moves { self.store.relocate(old, to: new) }
                self.store.pruneMissingFiles()
                if self.folder.isOpen { self.folder.reload(after: 0) }
                completion(used + moves.map(\.1))
            }
        }
    }

    /// Fragt nach, bevor alle Objekte entfernt werden. Eigene Dateien (Bilder aus dem
    /// Web, Texte, Links) werden dabei endgültig gelöscht.
    static func confirmRemovingAll(_ count: Int, ui: ShelfUIModel? = nil) -> Bool {
        guard count > 0 else { return false }
        let alert = NSAlert()
        alert.messageText = count == 1 ? L("Remove 1 item from the shelf?", "1 Objekt aus der Ablage entfernen?")
            : L("Remove all \(count) items from the shelf?", "Alle \(count) Objekte aus der Ablage entfernen?")
        alert.informativeText = L("Files from the Finder are kept. You can undo this in the shelf with ⌘Z.",
                                  "Dateien aus dem Finder bleiben erhalten. In der Ablage lässt sich das mit ⌘Z widerrufen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove", "Entfernen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        ui?.menuOpen = true                 // Ablage bleibt offen, solange die Frage steht
        AppActivation.activateKeepingWindows()
        let answer = alert.runModal()
        ui?.menuOpen = false
        return answer == .alertFirstButtonReturn
    }

    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    // MARK: Stapel

    var openStackEntry: ShelfEntry? {
        if ui.openStack == FolderBrowser.entryID { return folder.isOpen ? folder.entry : nil }
        return entry(ui.openStack)
    }

    /// Der Inhalt eines angehefteten Ordners ist zu sehen
    var isFolderOpen: Bool { ui.openStack == FolderBrowser.entryID && folder.isOpen }

    /// Eintrag der Ablage, aus dem der gezeigte Ordner geöffnet wurde (Doppelklick auf einen
    /// abgelegten Ordner): Zurück in der Ablage ist er wieder ausgewählt
    private var folderSourceEntry: UUID?

    /// Ein abgelegter Ordner öffnet sich in der Ablage wie ein angehefteter
    func openFolder(from entry: ShelfEntry) {
        guard !entry.isStack, let url = entry.files.first?.url, FolderBrowser.isBrowsable(url) else { return }
        openFolder(url)
        folderSourceEntry = entry.id
    }

    /// Der Eintrag ist ein einzelner Ordner, in den man hineingehen kann
    func isBrowsableFolder(_ entry: ShelfEntry) -> Bool {
        guard !entry.isStack, let url = entry.files.first?.url else { return false }
        return FolderBrowser.isBrowsable(url)
    }

    /// Angehefteten Ordner wie einen Stapel öffnen
    func openFolder(_ url: URL) {
        ShelfSnapshots.capture(panel, "folder", after: [0.1, 0.5, 1.5])
        folderSourceEntry = nil
        ui.selection = []
        ui.memberSelection = []
        ui.memberAnchor = nil
        folder.open(url)
        withAnimation(settings.animationStyle.close) { ui.openStack = FolderBrowser.entryID }
    }

    /// In einen Unterordner hineingehen
    func enterFolder(_ url: URL) {
        ui.memberSelection = []
        ui.memberAnchor = nil
        withAnimation(settings.animationStyle.close) { folder.enter(url) }
    }

    /// Zurück zur Ablage, aus jeder Tiefe
    func closeFolder() {
        ui.memberSelection = []
        withAnimation(settings.animationStyle.close) { ui.openStack = nil }
        if let source = folderSourceEntry, store.entries.contains(where: { $0.id == source }) {
            ui.selection = [source]
            ui.selectionAnchor = source
        }
        folderSourceEntry = nil
    }

    func entry(_ id: UUID?) -> ShelfEntry? {
        guard let id else { return nil }
        return store.entries.first { $0.id == id }
    }

    /// In einen Stapel hineingehen: die Ablage zeigt nur noch seine Dateien.
    func openStack(_ entry: ShelfEntry) {
        guard entry.isStack else { return }
        ui.selection = []
        ui.memberSelection = []
        ui.memberAnchor = nil
        withAnimation(settings.animationStyle.close) { ui.openStack = entry.id }
    }

    /// Zurück zur gesamten Ablage.
    func closeStack() {
        guard ui.openStack != nil else { return }
        if ui.openStack == FolderBrowser.entryID {
            // Im Ordner: eine Ebene hoch, der zuletzt gezeigte Ordner ist danach ausgewählt
            let left = folder.folder
            ui.memberSelection = []
            if folder.isOpen, folder.isNested {
                withAnimation(settings.animationStyle.close) { _ = folder.goUp() }
                if let left {
                    let id = FolderBrowser.id(for: left)
                    ui.memberSelection = [id]
                    ui.memberAnchor = id
                }
            } else {
                closeFolder()
            }
            return
        }
        let previous = ui.openStack
        ui.memberSelection = []
        withAnimation(settings.animationStyle.close) { ui.openStack = nil }
        if let previous { ui.selection = [previous] }
    }

    func mergeSelection(_ entries: [ShelfEntry]) {
        store.merge(Set(entries.map(\.id)))
        ui.selection = []
    }

    /// Doppelklick: Stapel öffnen, einen einzelnen Ordner in der Ablage zeigen (wie einen
    /// angehefteten), sonst Dateien öffnen.
    func activate(_ entry: ShelfEntry) {
        let targets = targets(for: entry)
        if targets.count == 1, entry.isStack {
            openStack(entry)
        } else if targets.count == 1, isBrowsableFolder(entry) {
            openFolder(from: entry)
        } else {
            open(targets)
        }
    }

    /// Im Finder zeigen: bei Kopien das Original, sofern es noch da ist
    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(originals(urls))
    }

    /// Bei Kopien der Ort des Originals (für „Im Finder zeigen“ und „Pfad kopieren“)
    func originals(_ urls: [URL]) -> [URL] {
        let files = store.entries.flatMap(\.files)
        return urls.map { url in files.first { $0.url == url }?.originURL() ?? url }
    }

    // MARK: Menüs

    private func addFileItems(to menu: NSMenu, urls: [URL], anchor: NSView, open: @escaping () -> Void) {
        menu.addItem(ClosureMenuItem(L("Open", "Öffnen"), key: "o", handler: open))
        menu.addItem(ClosureMenuItem(L("Show in Finder", "Im Finder zeigen"), key: "r") { [weak self] in
            self?.reveal(urls)
        })
        menu.addItem(ClosureMenuItem(L("Get Info", "Informationen"), key: "i") { [weak self] in
            self?.getInfo(urls)
        })
        menu.addItem(ClosureMenuItem(L("Copy", "Kopieren"), key: "c") { [weak self] in
            ShelfActions.copyFiles(urls)
            self?.announceCopy(urls.count, pathsOnly: false)
        })
        menu.addItem(ClosureMenuItem(L("Copy Path", "Pfad kopieren"), key: "c", modifiers: [.command, .option]) { [weak self] in
            ShelfActions.copyPaths(self?.originals(urls) ?? urls)
            self?.announceCopy(urls.count, pathsOnly: true)
        })
        menu.addItem(ClosureMenuItem(L("Share", "Teilen")) { [weak self, weak anchor] in
            guard let anchor else { return }
            // erst nach dem Schließen des Menüs zeigen, damit der Picker an der Kachel sitzt
            DispatchQueue.main.async { self?.share(urls, from: anchor) }
        })
        if let convert = convertMenuItem(for: urls, anchor: anchor) { menu.addItem(convert) }
        let zips = urls.filter(Self.isZip)
        if !zips.isEmpty {
            menu.addItem(ClosureMenuItem(L("Unzip", "Entpacken")) { [weak self] in self?.unzip(zips) })
        }
    }

    /// Kontextmenü für eine Kachel. Gilt für die ganze Auswahl, wenn die Kachel dazugehört.
    func menu(for entry: ShelfEntry, anchor: NSView) -> NSMenu {
        let targets = targets(for: entry)
        let urls = targets.flatMap(\.urls)
        let multiple = targets.count > 1
        let menu = NSMenu()
        addFileItems(to: menu, urls: urls, anchor: anchor) { [weak self] in
            guard let self else { return }
            // Ein einzelner Ordner: wie der Doppelklick in der Ablage zeigen
            if !multiple, self.isBrowsableFolder(entry) { self.openFolder(from: entry) } else { self.open(targets) }
        }

        if multiple {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Group as Stack", "Als Stapel zusammenfassen")) { [weak self] in
                self?.mergeSelection(targets)
            })
        } else if entry.isStack {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Open Stack", "Stapel öffnen")) { [weak self] in
                self?.openStack(entry)
            })
            menu.addItem(ClosureMenuItem(L("Ungroup Stack", "Stapel auflösen")) { [weak self] in
                self?.store.unstack(entry.id)
            })
        }
        menu.addItem(.separator())
        let title = multiple ? L("Remove \(targets.count) Items from Shelf", "\(targets.count) Objekte aus der Ablage entfernen")
                             : L("Remove from Shelf", "Aus der Ablage entfernen")
        menu.addItem(ClosureMenuItem(title, key: "\u{8}", modifiers: []) { [weak self] in self?.remove(targets) })
        menu.addItem(moveToTrashItem(urls))
        addPluginItems(to: menu, files: targets.flatMap(\.files))
        return menu
    }

    /// Kontextmenü für Dateien im geöffneten Stapel. Gilt für die Auswahl, wenn die Datei dazugehört.
    func menu(for file: ShelfFile, in entry: ShelfEntry, anchor: NSView) -> NSMenu {
        let files = memberTargets(for: file)
        let urls = files.map(\.url)
        let menu = NSMenu()
        addFileItems(to: menu, urls: urls, anchor: anchor) { [weak self] in self?.openMembers(files) }
        menu.addItem(.separator())
        if isFolderOpen {
            // Im angehefteten Ordner: nichts lässt sich „aus der Ablage“ nehmen
            menu.addItem(ClosureMenuItem(files.count > 1 ? L("Add \(files.count) Items to Shelf", "\(files.count) Objekte in die Ablage legen") : L("Add to Shelf", "In die Ablage legen")) { [weak self] in
                self?.addToShelf(urls)
            })
            menu.addItem(moveToTrashItem(urls))
            addPluginItems(to: menu, files: files)
            return menu
        }
        menu.addItem(ClosureMenuItem(files.count > 1 ? L("Take \(files.count) Items Out of Stack", "\(files.count) Objekte aus Stapel lösen") : L("Take Out of Stack", "Aus Stapel lösen")) { [weak self] in
            self?.detachMembers(files)
        })
        menu.addItem(ClosureMenuItem(files.count > 1 ? L("Remove \(files.count) Items from Shelf", "\(files.count) Objekte aus der Ablage entfernen") : L("Remove from Shelf", "Aus der Ablage entfernen"), key: "\u{8}", modifiers: []) { [weak self] in
            self?.removeMembers(files)
        })
        menu.addItem(moveToTrashItem(urls))
        addPluginItems(to: menu, files: files)
        return menu
    }

    /// „In den Papierkorb legen“ (⌘⌫), in allen Kontextmenüs gleich
    private func moveToTrashItem(_ urls: [URL]) -> NSMenuItem {
        ClosureMenuItem(L("Move to Trash", "In den Papierkorb legen"), key: "\u{8}") { [weak self] in
            self?.moveToTrash(urls)
        }
    }

    /// „Einstellungen“ und „BarDrop beenden“ am Ende der Menüs ohne Objekt
    private func addAppItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(L("Settings", "Einstellungen"), key: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(ClosureMenuItem(L("Quit BarDrop", "BarDrop beenden"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// Plugins, die zu den Dateien passen: unter den normalen Einträgen, nach einer
    /// Trennlinie. Bis zu drei direkt im Menü, ab vier gesammelt unter „Plugins“.
    private func addPluginItems(to menu: NSMenu, files: [ShelfFile]) {
        guard settings.pluginsEnabled, !files.isEmpty else { return }
        let matching = plugins.plugins(for: files.map(\.url), trigger: .menu)
        guard !matching.isEmpty else { return }
        let items = matching.map { plugin -> NSMenuItem in
            let item = ClosureMenuItem(plugin.manifest.title) { [weak self] in
                // Erst nach dem Schließen des Menüs: Das Plugin kann eine Frage stellen
                DispatchQueue.main.async { self?.plugins.run(plugin.id, on: files) }
            }
            return item
        }
        menu.addItem(.separator())
        if items.count <= 3 {
            items.forEach(menu.addItem)
        } else {
            let submenu = NSMenu()
            items.forEach(submenu.addItem)
            let group = NSMenuItem(title: L("Plugins", "Plugins"), action: nil, keyEquivalent: "")
            group.submenu = submenu
            menu.addItem(group)
        }
    }

    /// Kontextmenü für ein laufendes Plugin (Platzhalter): Fortschritt, Anhalten,
    /// Fortsetzen und Abbrechen. Der Fortschritt läuft im offenen Menü mit.
    func menu(for job: PluginJob) -> NSMenu {
        let menu = NSMenu()
        let status = LiveMenuItem { [weak job] in
            guard let job else { return L("Finished", "Fertig") }
            let name = job.title
            if !job.isStarted { return L("\(name): waiting", "\(name): wartet") }
            if job.paused { return L("\(name): paused", "\(name): angehalten") + (job.percent.map { " · " + Format.percent($0) } ?? "") }
            if let percent = job.percent { return "\(name): " + Format.percent(percent) }
            return L("\(name): running", "\(name): läuft")
        }
        menu.addItem(status)
        menu.addItem(.separator())
        if !job.isStarted {
            // Wartet noch: nur abbrechen
        } else if job.paused {
            menu.addItem(ClosureMenuItem(L("Resume", "Fortsetzen")) { [weak job] in job?.resume() })
        } else {
            menu.addItem(ClosureMenuItem(L("Pause", "Anhalten")) { [weak job] in job?.pause() })
        }
        menu.addItem(ClosureMenuItem(L("Cancel", "Abbrechen")) { [weak self, weak job] in
            guard let job else { return }
            self?.plugins.cancel(job)
        })
        return menu
    }

    /// ⌘I: Informationen wie im Finder (das Fenster „Informationen“ des Finders)
    func getInfo(_ urls: [URL]) {
        let targets = originals(urls).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !targets.isEmpty else { return NSSound.beep() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.info"))
        pasteboard.clearContents()
        pasteboard.writeObjects(targets as [NSURL])
        pasteboard.setPropertyList(targets.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        if !NSPerformService("Finder/Show Info", pasteboard) {
            // Ohne den Dienst des Finders: wenigstens im Finder zeigen
            NSSound.beep()
            reveal(targets)
        }
    }

    /// Dateien eines angehefteten Ordners zusätzlich in die Ablage legen, wie aus dem Finder
    func addToShelf(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.folder"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        store.ingest(from: pasteboard, byUser: true) { [weak self] added in
            let n = added.count
            guard n > 0 else { return }
            self?.announce(L("Added", "Hinzugefügt"))
        }
    }

    /// Kontextmenü für die leere Fläche im geöffneten Ordner
    private func folderBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        if let url = folder.folder {
            menu.addItem(ClosureMenuItem(L("Open in Finder", "Im Finder öffnen")) {
                NSWorkspace.shared.open(url)
            })
        }
        menu.addItem(ClosureMenuItem(L("Paste from Clipboard", "Aus der Zwischenablage einfügen"), key: "v") { [weak self] in
            self?.pasteIntoFolder()
        })
        if store.undoManager.canUndo {
            menu.addItem(ClosureMenuItem(L("Undo", "Widerrufen"), key: "z") { [weak self] in
                self?.undo()
            })
        }
        if !folder.files.isEmpty {
            menu.addItem(ClosureMenuItem(L("Select All", "Alle auswählen"), key: "a") { [weak self] in
                self?.selectAllCurrent()
            })
        }
        menu.addItem(.separator())
        addAppItems(to: menu)
        return menu
    }

    /// ⌘V im geöffneten Ordner: Dateien aus der Zwischenablage hineinkopieren, wie im Finder
    func pasteIntoFolder() {
        guard let target = folder.folder,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return NSSound.beep() }
        file(urls, into: target, modifiers: .option) { _ in }
    }

    /// Dateien in den geöffneten Ordner legen (aus der Ablage hineingezogen, aus dem Finder
    /// …): wie auf die Ordner-Aktion, gleiche Platte verschieben, sonst kopieren
    func fileIntoOpenFolder(_ urls: [URL], modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let target = folder.folder, !urls.isEmpty else { return }
        file(urls, into: target, modifiers: modifiers) { _ in }
    }

    /// Kontextmenü für die leere Fläche der Ablage.
    func backgroundMenu() -> NSMenu {
        if isFolderOpen { return folderBackgroundMenu() }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Paste from Clipboard", "Aus der Zwischenablage einfügen"), key: "v") { [weak self] in
            self?.store.pasteFromClipboard()
        })
        if store.undoManager.canUndo {
            menu.addItem(ClosureMenuItem(L("Undo", "Widerrufen"), key: "z") { [weak self] in
                self?.undo()
            })
        }
        if !store.entries.isEmpty {
            menu.addItem(ClosureMenuItem(L("Select All", "Alle auswählen"), key: "a") { [weak self] in
                self?.selectAllCurrent()
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Remove All Items", "Alle Objekte entfernen")) { [weak self] in
                guard let self else { return }
                let count = self.store.entries.reduce(0) { $0 + $1.files.count }
                // Erst nach dem Schließen des Menüs fragen
                DispatchQueue.main.async {
                    if Self.confirmRemovingAll(count, ui: self.ui) { self.remove(self.store.entries) }
                }
            })
        }
        if isFloating() {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Back to the Edge", "Zurück an den Rand")) { [weak self] in
                self?.returnToEdge?()
            })
        }
        menu.addItem(.separator())
        addAppItems(to: menu)
        return menu
    }
}
