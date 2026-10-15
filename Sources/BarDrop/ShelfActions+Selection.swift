import AppKit

/// Auswahl im geöffneten Stapel und Tastaturbefehle, die je nach Ansicht
/// auf die Einträge der Ablage oder auf die Dateien im Stapel wirken.
extension ShelfActions {

    // MARK: Auswahl im Stapel

    /// Dateien des geöffneten Stapels (leer, wenn kein Stapel offen ist)
    var stackFiles: [ShelfFile] { openStackEntry?.files ?? [] }

    var isInStack: Bool { openStackEntry?.isStack == true }

    var selectedMembers: [ShelfFile] {
        stackFiles.filter { ui.memberSelection.contains($0.id) }
    }

    /// Die ausgewählten Dateien, oder nur `file`, wenn sie nicht zur Auswahl gehört.
    func memberTargets(for file: ShelfFile) -> [ShelfFile] {
        ui.memberSelection.contains(file.id) ? selectedMembers : [file]
    }

    func selectMember(_ file: ShelfFile, modifiers: NSEvent.ModifierFlags) {
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
    }

    func memberDragFiles(for file: ShelfFile) -> [ShelfFile] {
        existingForDrag(memberTargets(for: file))
    }

    func detachMembers(_ files: [ShelfFile]) {
        guard let stack = openStackEntry else { return }
        ui.memberSelection.subtract(files.map(\.id))
        store.detach(Set(files.map(\.id)), from: stack.id)
    }

    func removeMembers(_ files: [ShelfFile]) {
        guard let stack = openStackEntry, !files.isEmpty else { return }
        ui.memberSelection.subtract(files.map(\.id))
        store.removeFiles(Set(files.map(\.id)), from: stack.id)
        announceRemoval(files.count)
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
        if isInStack { ui.memberSelection = [] } else { clearSelection() }
    }

    var hasCurrentSelection: Bool {
        isInStack ? !ui.memberSelection.isEmpty : !ui.selection.isEmpty
    }

    func moveCurrentSelection(by step: Int, extend: Bool) {
        guard isInStack else { return moveSelection(by: step, extend: extend) }
        let ids = stackFiles.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ui.memberAnchor.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let id = ids[min(max(current + step, 0), ids.count - 1)]
        if extend { ui.memberSelection.insert(id) } else { ui.memberSelection = [id] }
        ui.memberAnchor = id
    }

    /// Entfernen per Taste: Danach ist das Objekt dahinter ausgewählt (am Ende das davor),
    /// sodass man mit ⌫ gleich weitermachen kann, wie in Mail.
    func removeCurrentSelection() {
        if isInStack {
            let removed = selectedMembers
            let next = Self.neighbor(of: Set(removed.map(\.id)), in: stackFiles.map(\.id))
            removeMembers(removed)
            // Der Stapel kann sich dabei aufgelöst haben
            if let next, stackFiles.contains(where: { $0.id == next }) {
                ui.memberSelection = [next]
                ui.memberAnchor = next
            }
        } else {
            let removed = selectedEntries
            let next = Self.neighbor(of: Set(removed.map(\.id)), in: orderedEntries.map(\.id))
            remove(removed)
            if let next, orderedEntries.contains(where: { $0.id == next }) {
                ui.selection = [next]
                ui.selectionAnchor = next
            }
        }
    }

    /// ⌘X wie Strg+X unter Windows: in die Zwischenablage und aus der Ablage nehmen.
    /// Eigene Dateien (Bilder aus dem Web, Kopien) bleiben erhalten, solange sich das
    /// Entfernen mit ⌘Z widerrufen lässt, damit das Einfügen im Finder klappt.
    func cutCurrentSelection() {
        let urls = currentSelectionURLs
        guard !urls.isEmpty else { return NSSound.beep() }
        Self.copyFiles(urls)
        removeCurrentSelection()
        announce(urls.count == 1 ? L("1 item cut", "1 Objekt ausgeschnitten")
                                 : L("\(urls.count) items cut", "\(urls.count) Objekte ausgeschnitten"),
                 canUndo: true)
    }

    /// Nächster Nachbar nach den entfernten Einträgen, sonst der davor
    static func neighbor(of removed: Set<UUID>, in ids: [UUID]) -> UUID? {
        guard let last = ids.lastIndex(where: removed.contains) else { return nil }
        if let after = ids[(last + 1)...].first(where: { !removed.contains($0) }) { return after }
        return ids[..<last].last(where: { !removed.contains($0) })
    }

    func openCurrentSelection() {
        currentSelectionURLs.forEach { NSWorkspace.shared.open($0) }
    }

    func revealCurrentSelection() {
        let urls = currentSelectionURLs
        guard !urls.isEmpty else { return }
        reveal(urls)
    }

    /// ⌘C bzw. ⌥⌘C: Auswahl kopieren, ohne Auswahl alles in der Ansicht.
    func copyCurrent(pathsOnly: Bool) {
        let urls = hasCurrentSelection ? currentSelectionURLs : currentAllURLs
        guard !urls.isEmpty else { return NSSound.beep() }
        if pathsOnly { Self.copyPaths(originals(urls)) } else { Self.copyFiles(urls) }
        announceCopy(urls.count, pathsOnly: pathsOnly)
    }

    func announceCopy(_ count: Int, pathsOnly: Bool) {
        if pathsOnly {
            announce(count == 1 ? L("Path copied", "Pfad kopiert") : L("\(count) paths copied", "\(count) Pfade kopiert"))
        } else {
            announce(count == 1 ? L("1 item copied", "1 Objekt kopiert") : L("\(count) items copied", "\(count) Objekte kopiert"))
        }
    }

    func toggleQuickLookCurrent() {
        if isQuickLookVisible {
            closeQuickLook()
            return
        }
        var urls = currentSelectionURLs
        if urls.isEmpty { urls = Array(currentAllURLs.prefix(1)) }
        quickLook(urls: urls)
    }
}
