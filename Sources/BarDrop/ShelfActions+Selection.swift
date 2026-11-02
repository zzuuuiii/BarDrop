import AppKit

/// Auswahl im geöffneten Stapel und Tastaturbefehle, die je nach Ansicht
/// auf die Einträge der Ablage oder auf die Dateien im Stapel wirken.
extension ShelfActions {

    // MARK: Auswahl im Stapel

    /// Dateien des geöffneten Stapels (leer, wenn kein Stapel offen ist)
    var stackFiles: [ShelfFile] { openStackEntry?.files ?? [] }

    /// Ein Stapel oder ein angehefteter Ordner ist offen (auch ein leerer Ordner)
    var isInStack: Bool { isFolderOpen || openStackEntry?.isStack == true }

    var selectedMembers: [ShelfFile] {
        stackFiles.filter { ui.memberSelection.contains($0.id) }
    }

    /// Die ausgewählten Dateien, oder nur `file`, wenn sie nicht zur Auswahl gehört.
    func memberTargets(for file: ShelfFile) -> [ShelfFile] {
        ui.memberSelection.contains(file.id) ? selectedMembers : [file]
    }

    func selectMember(_ file: ShelfFile, modifiers: NSEvent.ModifierFlags) {
        if modifiers.isDisjoint(with: [.command, .shift]) { ui.jobSelection = [] }
        let files = stackFiles
        if modifiers.contains(.command) {
            if ui.memberSelection.contains(file.id) {
                ui.memberSelection.remove(file.id)
            } else {
                ui.memberSelection.insert(file.id)
            }
            ui.memberAnchor = file.id
        } else if modifiers.contains(.shift),
                  let anchor = ui.memberAnchor,
                  let a = files.firstIndex(where: { $0.id == anchor }),
                  let b = files.firstIndex(where: { $0.id == file.id }) {
            ui.memberSelection = Set(files[min(a, b)...max(a, b)].map(\.id))
        } else if !ui.memberSelection.contains(file.id) || ui.memberSelection.count == 1 {
            ui.memberSelection = [file.id]
            ui.memberAnchor = file.id
        }
    }

    func clickedMemberWithoutDrag(_ file: ShelfFile, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.isDisjoint(with: [.command, .shift]) else { return }
        ui.memberSelection = [file.id]
        ui.memberAnchor = file.id
        // Im Verlauf der Zwischenablage kopiert ein Klick den Eintrag wieder
        if isFolderOpen, ClipboardHistory.shared.contains(file.url) {
            ClipboardHistory.shared.copyBack(file.url)
            announceCopy(1, pathsOnly: false)
        }
    }

    func memberDragFiles(for file: ShelfFile) -> [ShelfFile] {
        existingForDrag(memberTargets(for: file))
    }

    func detachMembers(_ files: [ShelfFile]) {
        guard !isFolderOpen, let stack = openStackEntry else { return }
        ui.memberSelection.subtract(files.map(\.id))
        store.detach(Set(files.map(\.id)), from: stack.id)
    }

    func removeMembers(_ files: [ShelfFile], sound: Bool = true) {
        guard !isFolderOpen, let stack = openStackEntry, !files.isEmpty else { return }
        ui.memberSelection.subtract(files.map(\.id))
        store.removeFiles(Set(files.map(\.id)), from: stack.id)
        announceRemoval(files.count)
        if sound { Sounds.remove() }
    }

    // MARK: Befehle für die aktuelle Ansicht (Ablage oder Stapel)

    /// URLs der aktuellen Auswahl
    var currentSelectionURLs: [URL] {
        isInStack ? selectedMembers.map(\.url) : selectedEntries.flatMap(\.urls)
    }

    /// URLs aller Objekte der aktuellen Ansicht
    var currentAllURLs: [URL] {
        isInStack ? stackFiles.map(\.url) : orderedEntries.flatMap(\.urls)
    }

    func selectAllCurrent() {
        if isInStack {
            ui.memberSelection = Set(stackFiles.map(\.id))
            ui.memberAnchor = stackFiles.first?.id
        } else {
            selectAll()
        }
    }

    func clearCurrentSelection() {
        ui.jobSelection = []
        if isInStack { ui.memberSelection = [] } else { clearSelection() }
    }

    var hasCurrentSelection: Bool {
        !ui.jobSelection.isEmpty || (isInStack ? !ui.memberSelection.isEmpty : !ui.selection.isEmpty)
    }

    // MARK: Platzhalter laufender Plugins

    /// Klick auf einen Platzhalter: auswählen wie eine Kachel (⌘ bzw. ⇧ fügt hinzu)
    func selectJob(_ job: PluginJob, modifiers: NSEvent.ModifierFlags) {
        panel?.makeKey()
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if ui.jobSelection.contains(job.id) { ui.jobSelection.remove(job.id) } else { ui.jobSelection.insert(job.id) }
        } else {
            ui.jobSelection = [job.id]
            if isInStack { ui.memberSelection = [] } else { ui.selection = [] }
        }
        if isInStack { ui.memberAnchor = job.id } else { ui.selectionAnchor = job.id }
    }

    /// Ausgewählte Platzhalter abbrechen (⌫); true, wenn welche ausgewählt waren
    @discardableResult
    func cancelSelectedJobs() -> Bool {
        guard !ui.jobSelection.isEmpty else { return false }
        let selected = plugins.jobs.filter { ui.jobSelection.contains($0.id) }
        ui.jobSelection = []
        selected.forEach { plugins.cancel($0) }
        return !selected.isEmpty
    }

    /// Kacheln der aktuellen Ansicht in der Reihenfolge, in der man sie sieht, samt den
    /// Platzhaltern laufender Plugins (für die Pfeiltasten)
    var visualIDs: [UUID] {
        let runner = plugins
        if isInStack {
            return stackFiles.flatMap { file -> [UUID] in
                let shown = runner.replacingJob(for: file.id)?.id ?? file.id
                return [shown] + runner.jobs(nextTo: [file.id]).map(\.id)
            }
        }
        return orderedEntries.flatMap { entry -> [UUID] in
            var shown = entry.id
            if !entry.isStack, let file = entry.files.first, let job = runner.replacingJob(for: file.id) { shown = job.id }
            return [shown] + runner.jobs(nextTo: entry.files.map(\.id)).map(\.id)
        }
    }

    /// Pfeiltasten: Auswahl verschieben, auch über Platzhalter. `step` ist ±1 oder ±Spaltenanzahl.
    func moveCurrentSelection(by step: Int, extend: Bool) {
        let ids = visualIDs
        guard !ids.isEmpty else { return }
        let inStack = isInStack
        let anchor = inStack ? ui.memberAnchor : ui.selectionAnchor
        let current = anchor.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let id = ids[min(max(current + step, 0), ids.count - 1)]
        let isJob = plugins.job(for: id) != nil
        if !extend {
            ui.jobSelection = []
            if inStack { ui.memberSelection = [] } else { ui.selection = [] }
        }
        if isJob {
            ui.jobSelection.insert(id)
        } else if inStack {
            ui.memberSelection.insert(id)
        } else {
            ui.selection.insert(id)
        }
        if inStack { ui.memberAnchor = id } else { ui.selectionAnchor = id }
        ui.requestScroll(to: id)
    }

    /// Entfernen per Taste: Danach ist das Objekt dahinter ausgewählt (am Ende das davor),
    /// sodass man mit ⌫ gleich weitermachen kann, wie in Mail.
    func removeCurrentSelection(sound: Bool = true) {
        // Ausgewählte Platzhalter: das Plugin abbrechen. Waren nur sie ausgewählt, ist das alles
        if cancelSelectedJobs(), !hasCurrentSelection { return }
        // Im angehefteten Ordner wie im Finder: ⌫ allein tut nichts, ⌘⌫ legt in den Papierkorb
        if isFolderOpen { return NSSound.beep() }
        if isInStack {
            let removed = selectedMembers
            let next = Self.neighbor(of: Set(removed.map(\.id)), in: stackFiles.map(\.id))
            removeMembers(removed, sound: sound)
            // Der Stapel kann sich dabei aufgelöst haben
            if let next, stackFiles.contains(where: { $0.id == next }) {
                ui.memberSelection = [next]
                ui.memberAnchor = next
            }
        } else {
            let removed = selectedEntries
            let next = Self.neighbor(of: Set(removed.map(\.id)), in: orderedEntries.map(\.id))
            remove(removed, sound: sound)
            if let next, orderedEntries.contains(where: { $0.id == next }) {
                ui.selection = [next]
                ui.selectionAnchor = next
            }
        }
    }

    /// ⌘⌫ wie im Finder: Auswahl in den Papierkorb. Danach ist wie bei ⌫ das Objekt
    /// dahinter ausgewählt.
    /// ⌘D: Auswahl duplizieren wie im Finder, in der Ablage und im Stapel. Danach sind die
    /// Kopien ausgewählt. In angehefteten Ordnern nicht (dort lägen die Kopien im Finder)
    func duplicateCurrentSelection() {
        guard !isFolderOpen else { return NSSound.beep() }
        if isInStack {
            guard !selectedMembers.isEmpty else { return NSSound.beep() }
            duplicateMembers(selectedMembers)
        } else {
            guard !selectedEntries.isEmpty else { return NSSound.beep() }
            duplicate(selectedEntries)
        }
    }

    /// Objekte der Ablage duplizieren (⌘D oder Rechtsklick); danach sind die Kopien ausgewählt
    func duplicate(_ entries: [ShelfEntry]) {
        let made = store.duplicate(entries: Set(entries.map(\.id)))
        guard !made.isEmpty else { return }
        ui.selection = Set(made)
        ui.selectionAnchor = made.last
    }

    /// Dateien im geöffneten Stapel duplizieren; die Kopien stehen direkt dahinter
    func duplicateMembers(_ files: [ShelfFile]) {
        guard let stack = openStackEntry else { return }
        let made = store.duplicate(files: Set(files.map(\.id)), in: stack.id)
        guard !made.isEmpty else { return }
        ui.memberSelection = Set(made)
        ui.memberAnchor = made.last
    }

    func trashCurrentSelection() {
        let urls = currentSelectionURLs
        guard !urls.isEmpty else { return NSSound.beep() }
        let removedIDs: Set<UUID>
        let ids: [UUID]
        if isInStack {
            removedIDs = Set(selectedMembers.map(\.id))
            ids = stackFiles.map(\.id)
        } else {
            removedIDs = Set(selectedEntries.map(\.id))
            ids = orderedEntries.map(\.id)
        }
        let next = Self.neighbor(of: removedIDs, in: ids)
        let inStack = isInStack
        // Erst nachdem der Papierkorb geantwortet hat, steht fest, was noch da ist
        moveToTrash(urls) { [weak self] in
            guard let self, let next else { return }
            if inStack {
                guard self.stackFiles.contains(where: { $0.id == next }), self.ui.memberSelection.isEmpty else { return }
                self.ui.memberSelection = [next]
                self.ui.memberAnchor = next
            } else {
                guard self.orderedEntries.contains(where: { $0.id == next }), self.ui.selection.isEmpty else { return }
                self.ui.selection = [next]
                self.ui.selectionAnchor = next
            }
        }
    }

    /// ⌘X wie Strg+X unter Windows: in die Zwischenablage und aus der Ablage nehmen.
    /// Eigene Dateien (Bilder aus dem Web, Kopien) bleiben erhalten, solange sich das
    /// Entfernen mit ⌘Z widerrufen lässt, damit das Einfügen im Finder klappt.
    func cutCurrentSelection() {
        // Aus einem echten Ordner lässt sich nichts herausnehmen, ohne es zu verschieben
        if isFolderOpen { return NSSound.beep() }
        let urls = currentSelectionURLs
        guard !urls.isEmpty else { return NSSound.beep() }
        Self.copyFiles(urls)
        // Ausschneiden bricht keine Plugins ab: Platzhalter bleiben, nur nicht mehr ausgewählt
        ui.jobSelection = []
        removeCurrentSelection(sound: false)
        announce(L("Cut", "Ausgeschnitten"), canUndo: true)
    }

    /// Nächster Nachbar nach den entfernten Einträgen, sonst der davor
    static func neighbor(of removed: Set<UUID>, in ids: [UUID]) -> UUID? {
        guard let last = ids.lastIndex(where: removed.contains) else { return nil }
        if let after = ids[(last + 1)...].first(where: { !removed.contains($0) }) { return after }
        return ids[..<last].last(where: { !removed.contains($0) })
    }

    func openCurrentSelection() {
        if isInStack { return openMembers(selectedMembers) }
        // ↩ bzw. ⌘O auf einem einzelnen Ordner: wie der Doppelklick in der Ablage zeigen
        let selected = selectedEntries
        if selected.count == 1, let entry = selected.first, isBrowsableFolder(entry) {
            return openFolder(from: entry)
        }
        currentSelectionURLs.forEach { NSWorkspace.shared.open($0) }
    }

    /// Doppelklick bzw. ⌘O im Stapel oder Ordner: ein einzelner Unterordner eines
    /// angehefteten Ordners öffnet sich in der Ablage, alles andere wie gewohnt
    func openMembers(_ files: [ShelfFile]) {
        if isFolderOpen, files.count == 1, let url = files.first?.url, FolderBrowser.isBrowsable(url) {
            return enterFolder(url)
        }
        files.forEach { NSWorkspace.shared.open($0.url) }
    }

    func revealCurrentSelection() {
        let urls = currentSelectionURLs
        guard !urls.isEmpty else { return }
        reveal(urls)
    }

    /// ⌘C bzw. ⌥⌘C: Auswahl kopieren, ohne Auswahl alles in der Ansicht.
    func copyCurrent(pathsOnly: Bool) {
        var urls = hasCurrentSelection ? currentSelectionURLs : currentAllURLs
        // Die Auswahl nannte nur Objekte, die es nicht mehr gibt (etwa nach dem Auflösen eines
        // Stapels): wie ohne Auswahl alles kopieren statt nur zu piepen
        if urls.isEmpty, ui.jobSelection.isEmpty { urls = currentAllURLs }
        guard !urls.isEmpty else { return NSSound.beep() }
        if pathsOnly { Self.copyPaths(originals(urls)) } else { Self.copyFiles(urls) }
        announceCopy(urls.count, pathsOnly: pathsOnly)
    }

    func announceCopy(_ count: Int, pathsOnly: Bool) {
        if pathsOnly {
            announce(count == 1 ? L("Path copied", "Pfad kopiert") : L("Paths copied", "Pfade kopiert"))
        } else {
            announce(L("Copied", "Kopiert"))
        }
    }

    func toggleQuickLookCurrent() {
        if isQuickLookVisible {
            closeQuickLook()
            return
        }
        var urls = currentSelectionURLs
        if urls.isEmpty { urls = Array(currentAllURLs.prefix(1)) }
        // Mehrere ausgewählt: Die Übersicht blättert darin selbst. Sonst (auch bei einem
        // Stapel) wechseln die Pfeiltasten wie im Finder zum nächsten Objekt der Ablage
        quickLookPagesSelection = (isInStack ? selectedMembers.count : selectedEntries.count) > 1
        quickLook(urls: urls)
    }
}
