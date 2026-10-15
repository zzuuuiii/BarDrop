import AppKit
import SwiftUI
import Quartz

/// Alle Aktionen auf Einträgen der Ablage (Kontextmenü, Tastatur, Aktionsleiste).
final class ShelfActions: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSSharingServicePickerDelegate {
    let store: ShelfStore
    let ui: ShelfUIModel
    let settings: AppSettings
    var openSettings: () -> Void = {}
    weak var panel: NSPanel?

    private var previewURLs: [URL] = []

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
    }

    // MARK: Reihenfolge und Auswahl

    /// Einträge in der eingestellten Reihenfolge. Gespeichert wird immer neueste zuerst.
    var orderedEntries: [ShelfEntry] {
        settings.sortOrder == .oldestFirst ? Array(store.entries.reversed()) : store.entries
    }

    var selectedEntries: [ShelfEntry] {
        orderedEntries.filter { ui.selection.contains($0.id) }
    }

    /// Die ausgewählten Einträge, oder nur `entry`, wenn er nicht zur Auswahl gehört.
    func targets(for entry: ShelfEntry) -> [ShelfEntry] {
        ui.selection.contains(entry.id) ? selectedEntries : [entry]
    }

    func select(_ entry: ShelfEntry, modifiers: NSEvent.ModifierFlags) {
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
    }

    /// Pfeiltasten: Auswahl verschieben. `step` ist ±1 oder ±Spaltenanzahl.
    func moveSelection(by step: Int, extend: Bool) {
        guard !store.entries.isEmpty else { return }
        let ids = orderedEntries.map(\.id)
        let current = ui.selectionAnchor.flatMap { ids.firstIndex(of: $0) }
            ?? (step > 0 ? -1 : ids.count)
        let next = min(max(current + step, 0), ids.count - 1)
        let id = ids[next]
        if extend {
            ui.selection.insert(id)
        } else {
            ui.selection = [id]
        }
        ui.selectionAnchor = id
    }

    var columnCount: Int {
        let usable = CGFloat(settings.shelfWidth) - 24
        return max(1, Int((usable + 8) / (78 + 8)))
    }

    // MARK: Aktionen auf Einträgen

    func open(_ entries: [ShelfEntry]) {
        entries.flatMap(\.urls).forEach { NSWorkspace.shared.open($0) }
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

    func remove(_ entries: [ShelfEntry]) {
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        let count = entries.reduce(0) { $0 + $1.files.count }
        ui.selection.subtract(ids)
        if let open = ui.openStack, ids.contains(open) { closeStack() }
        store.remove(ids)
        announceRemoval(count)
    }

    // MARK: Rückmeldung und Widerrufen

    /// Zeigt kurz eine Rückmeldung oben in der Ablage an Stelle der Anzahl.
    func announce(_ text: String, canUndo: Bool = false) {
        let notice = ShelfUIModel.Notice(text: text, canUndo: canUndo)
        withAnimation(.easeOut(duration: 0.18)) { ui.notice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + (canUndo ? 3 : 2)) { [weak self] in
            guard let self, self.ui.notice?.id == notice.id else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.ui.notice = nil }
        }
    }

    func announceRemoval(_ count: Int) {
        guard count > 0 else { return }
        announce(count == 1 ? L("1 item removed", "1 Objekt entfernt") : L("\(count) items removed", "\(count) Objekte entfernt"), canUndo: true)
    }

    /// ⌘Z: zuletzt Entferntes zurückholen und auswählen.
    func undo() {
        guard store.undoManager.canUndo else { return NSSound.beep() }
        let restored = store.undoLast()
        // Nichts mehr da, was sich zurückholen ließe
        guard !restored.isEmpty else { return NSSound.beep() }
        if isInStack {
            ui.memberSelection = Set(stackFiles.map(\.id)).intersection(restored)
        } else {
            ui.selection = Set(store.entries.filter { entry in entry.files.contains { restored.contains($0.id) } }.map(\.id))
        }
        announce(restored.count == 1 ? L("1 item restored", "1 Objekt zurückgeholt") : L("\(restored.count) items restored", "\(restored.count) Objekte zurückgeholt"))
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
        if !operation.isEmpty && !internalDrop && settings.removeAfterDragOut {
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

    func quickLook(_ entries: [ShelfEntry]) {
        quickLook(urls: entries.flatMap(\.urls))
    }

    func closeQuickLook() {
        if isQuickLookVisible { QLPreviewPanel.shared().orderOut(nil) }
    }

    func quickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewURLs = urls
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
        let ql = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible {
            ql.reloadData()
        } else {
            placeOnShelfScreen(ql)
            ql.makeKeyAndOrderFront(nil)
            // Quick Look stellt beim Öffnen manchmal seinen alten Ort wieder her
            DispatchQueue.main.async { [weak self] in self?.placeOnShelfScreen(ql) }
        }
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

    var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
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
            NSApp.activate(ignoringOtherApps: true)
            if let urls = shareFinishURLs { finishAction(urls) }
        }
        shareFinishURLs = nil
    }

    // MARK: Aktionsleiste

    func perform(_ action: QuickAction, urls: [URL], anchor: NSView) {
        guard !urls.isEmpty else {
            // Ohne Objekte: Ordner bzw. App öffnen
            if action.kind == .folder || action.kind == .app, let url = action.url {
                NSWorkspace.shared.open(url)
            }
            return
        }
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
            move(urls, to: folder) { [weak self] moved in self?.finishAction(moved) }
        case .convert:
            break   // gibt es nicht mehr als Aktion
        case .trash:
            // Wie im Finder: in den Papierkorb, von dort lässt es sich zurücklegen.
            // Danach immer aus der Ablage, denn die Dateien sind dort nicht mehr.
            NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error != nil { NSSound.beep() }
                    self.ui.selection = []
                    self.store.forgetFiles(at: Array(trashed.keys))
                    self.store.pruneMissingFiles()
                }
            }
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
        announce(L("Converting", "Wird umgewandelt"))
        Converter.convert(urls, to: target) { [weak self] results in
            guard let self else { return }
            guard !results.isEmpty else {
                NSSound.beep()
                self.announce(L("Couldn’t convert", "Umwandeln hat nicht geklappt"))
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
                self?.announce(n == 1 ? L("1 item converted", "1 Objekt umgewandelt")
                                      : L("\(n) items converted", "\(n) Objekte umgewandelt"))
            }
        }
    }

    /// Nach einer Schnellaktion: Objekte aus der Ablage nehmen, außer „Nach Aktionen behalten“ ist an.
    private func finishAction(_ urls: [URL]) {
        guard !settings.keepAfterAction else { return }
        ui.selection = []
        store.removeFiles(at: urls, deleteOwnedAfter: 15 * 60)
    }

    @discardableResult
    private func performService(_ name: NSSharingService.Name, urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: name), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
        return true
    }

    /// Verschiebt Dateien im Hintergrund in einen Ordner (über Laufwerksgrenzen hinweg
    /// kann das dauern) und meldet ihre neuen Adressen auf dem Hauptthread.
    private func move(_ urls: [URL], to folder: URL, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager()
            var moves: [(URL, URL)] = []
            var unchanged: [URL] = []
            var failed = false
            for url in urls {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    unchanged.append(url)
                    continue
                }
                let target = Self.uniqueURL(for: url.lastPathComponent, in: folder)
                do {
                    try fm.moveItem(at: url, to: target)
                    moves.append((url, target))
                } catch {
                    failed = true
                    Log.export.error("Verschieben fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if failed { NSSound.beep() }
                for (old, new) in moves { self.store.relocate(old, to: new) }
                self.store.pruneMissingFiles()
                completion(unchanged + moves.map(\.1))
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
        NSApp.activate(ignoringOtherApps: true)
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

    var openStackEntry: ShelfEntry? { entry(ui.openStack) }

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
        let previous = ui.openStack
        ui.memberSelection = []
        withAnimation(settings.animationStyle.close) { ui.openStack = nil }
        if let previous { ui.selection = [previous] }
    }

    func mergeSelection(_ entries: [ShelfEntry]) {
        store.merge(Set(entries.map(\.id)))
        ui.selection = []
    }

    /// Doppelklick: Stapel öffnen, sonst Dateien öffnen.
    func activate(_ entry: ShelfEntry) {
        let targets = targets(for: entry)
        if targets.count == 1, entry.isStack {
            openStack(entry)
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
        menu.addItem(ClosureMenuItem(L("Copy", "Kopieren"), key: "c") { [weak self] in
            ShelfActions.copyFiles(urls)
            self?.announceCopy(urls.count, pathsOnly: false)
        })
        menu.addItem(ClosureMenuItem(L("Copy Path", "Pfad kopieren"), key: "c", modifiers: [.command, .option]) { [weak self] in
            ShelfActions.copyPaths(self?.originals(urls) ?? urls)
            self?.announceCopy(urls.count, pathsOnly: true)
        })
        menu.addItem(ClosureMenuItem(L("Share", "Teilen"), symbol: "square.and.arrow.up") { [weak self, weak anchor] in
            guard let anchor else { return }
            // erst nach dem Schließen des Menüs zeigen, damit der Picker an der Kachel sitzt
            DispatchQueue.main.async { self?.share(urls, from: anchor) }
        })
        if let convert = convertMenuItem(for: urls, anchor: anchor) { menu.addItem(convert) }
    }

    /// Kontextmenü für eine Kachel. Gilt für die ganze Auswahl, wenn die Kachel dazugehört.
    func menu(for entry: ShelfEntry, anchor: NSView) -> NSMenu {
        let targets = targets(for: entry)
        let urls = targets.flatMap(\.urls)
        let multiple = targets.count > 1
        let menu = NSMenu()
        addFileItems(to: menu, urls: urls, anchor: anchor) { [weak self] in self?.open(targets) }

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
        let title = multiple ? L("Remove \(targets.count) Items", "\(targets.count) Objekte entfernen") : L("Remove", "Entfernen")
        menu.addItem(ClosureMenuItem(title, key: "\u{8}") { [weak self] in self?.remove(targets) })
        return menu
    }

    /// Kontextmenü für Dateien im geöffneten Stapel. Gilt für die Auswahl, wenn die Datei dazugehört.
    func menu(for file: ShelfFile, in entry: ShelfEntry, anchor: NSView) -> NSMenu {
        let files = memberTargets(for: file)
        let urls = files.map(\.url)
        let menu = NSMenu()
        addFileItems(to: menu, urls: urls, anchor: anchor) { urls.forEach { NSWorkspace.shared.open($0) } }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(files.count > 1 ? L("Take \(files.count) Items Out of Stack", "\(files.count) Objekte aus Stapel lösen") : L("Take Out of Stack", "Aus Stapel lösen")) { [weak self] in
            self?.detachMembers(files)
        })
        menu.addItem(ClosureMenuItem(files.count > 1 ? L("Remove \(files.count) Items", "\(files.count) Objekte entfernen") : L("Remove", "Entfernen"), key: "\u{8}") { [weak self] in
            self?.removeMembers(files)
        })
        return menu
    }

    /// Kontextmenü für die leere Fläche der Ablage.
    func backgroundMenu() -> NSMenu {
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
        menu.addItem(.separator())
        if case .available(let version) = Updater.shared.state {
            menu.addItem(ClosureMenuItem(L("Update to \(version)", "Auf \(version) aktualisieren")) {
                DispatchQueue.main.async { Updater.shared.install() }
            })
        }
        menu.addItem(ClosureMenuItem(L("Settings", "Einstellungen"), symbol: "gearshape", key: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(ClosureMenuItem(L("Quit BarDrop", "BarDrop beenden"), key: "q") {
            NSApp.terminate(nil)
        })
        return menu
    }
}
