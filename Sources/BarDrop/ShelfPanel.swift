import AppKit
import SwiftUI
import Quartz

/// Randloses, nicht aktivierendes Fenster, das auf allen Spaces und über
/// Vollbild-Apps liegt.
final class ShelfPanel: NSPanel {
    weak var actions: ShelfActions?
    var onEscape: () -> Void = {}

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    /// Klick auf den Griff (auch knapp daneben, wenn der größere Trefferbereich an ist):
    /// Ablage ganz öffnen. Das Fenster nimmt Klicks in dieser Stufe nur an, wenn es soll.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let ui = actions?.ui, ui.level == .hint {
            ui.expandRequested = true
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        actions?.ui.isKey = true
    }

    override func resignKey() {
        super.resignKey()
        actions?.ui.isKey = false
    }

    override func keyDown(with event: NSEvent) {
        guard let actions else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: // Leertaste
            actions.toggleQuickLookCurrent()
        case 51, 117: // Löschen
            actions.removeCurrentSelection()
        case 53: // Escape: Auswahl aufheben, Stapel verlassen, schließen
            if actions.hasCurrentSelection {
                actions.clearCurrentSelection()
            } else if actions.ui.openStack != nil {
                actions.closeStack()
            } else {
                onEscape()
            }
        case 36, 76: // Return
            actions.openCurrentSelection()
        case 123: // ←
            actions.moveCurrentSelection(by: -1, extend: shift)
        case 124: // →
            actions.moveCurrentSelection(by: 1, extend: shift)
        case 126: // ↑
            actions.moveCurrentSelection(by: -actions.columnCount, extend: shift)
        case 125: // ↓
            actions.moveCurrentSelection(by: actions.columnCount, extend: shift)
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let actions, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a":
            actions.selectAllCurrent()
        case "c":
            actions.copyCurrent(pathsOnly: event.modifierFlags.contains(.option))   // ⌥⌘C: nur Pfade
        case "v":
            actions.store.pasteFromClipboard()
        case "y":
            actions.toggleQuickLookCurrent()
        case "o":
            actions.openCurrentSelection()
        case "r":
            actions.revealCurrentSelection()
        case "z":
            if event.modifierFlags.contains(.shift) { actions.redo() } else { actions.undo() }
        case ",":
            // Wie im Kontextmenü angezeigt: Einstellungen öffnen
            actions.openSettings()
        case "q":
            NSApp.terminate(nil)
        default:
            if event.keyCode == 51 { // ⌘⌫
                actions.removeCurrentSelection()
                return true
            }
            if event.keyCode == 126, actions.ui.openStack != nil { // ⌘↑: Stapel verlassen
                actions.closeStack()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Quick Look Steuerung

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = actions
        panel.delegate = actions
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Gemeinsame Drop-Logik der Ablage: nimmt Dateien, Bilder, Links und Text von
/// außen an. Eigene Objekte (aus der Ablage gezogen) werden hier ignoriert.
final class ShelfDropHandler {
    private let store: ShelfStore
    private let ui: ShelfUIModel

    init(store: ShelfStore, ui: ShelfUIModel) {
        self.store = store
        self.ui = ui
    }

    private func isOwn(_ sender: NSDraggingInfo?) -> Bool {
        sender?.draggingSource is DragSourceNSView
    }

    private func setTargeted(_ value: Bool) {
        guard ui.isDropTargeted != value else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            ui.isDropTargeted = value
        }
    }

    func entered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isOwn(sender) else { return [] }
        setTargeted(true)
        return .copy
    }

    func updated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwn(sender) ? [] : .copy
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        guard !isOwn(sender) else { return false }
        store.ingest(from: sender.draggingPasteboard)
        Haptics.drop()
        setTargeted(false)
        return true
    }

    func finished() {
        setTargeted(false)
    }
}

/// SwiftUI-Träger der Ablage. Er ist selbst das Drop-Ziel, damit Drops nicht
/// von SwiftUI-internen Ansichten abgefangen werden. Tiefer liegende Ziele
/// (die Aktionsleiste) haben weiterhin Vorrang.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    var dropHandler: ShelfDropHandler? {
        didSet { registerForDraggedTypes(ShelfStore.acceptedTypes) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.entered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.updated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHandler?.finished()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = dropHandler?.perform(sender) ?? false
        // Nach dem Ablegen ist die Ablage das Fenster, mit dem man weiterarbeitet.
        // Ohne Fokus zeichnet macOS die neuen Kacheln teils erst beim Schließen.
        if accepted { DispatchQueue.main.async { [weak self] in self?.window?.makeKey() } }
        return accepted
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropHandler?.finished()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHandler?.finished()
    }
}
