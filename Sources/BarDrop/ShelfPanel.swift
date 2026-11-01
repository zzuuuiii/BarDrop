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
        // `canJoinAllApplications`: In Stage Manager gehört die Ablage zu keiner App-Gruppe,
        // sondern liegt über allen wie ein Teil des Systems. Ohne das behandelte Stage Manager sie
        // als eigenes Fenster und zeichnete beim Darüberfahren eckige Schatten (Nutzer, 28.10.2026)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        isFloatingPanel = true
        // Erst nach isFloatingPanel: Das setzt die Ebene sonst auf „schwebend“ zurück, und die
        // Ablage lag unter dem abgedunkelten Hintergrund der Einführung
        level = Self.shelfLevel
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// Ebene der Ablage: wie die Menüleiste, aber immer über dem abgedunkelten Hintergrund
    /// der Einführung. Der liegt eine Ebene über dem Dock, und dessen Ebene meldet macOS
    /// je nach Version höher als die der Menüleiste; dann lag die Abdunklung über der Ablage.
    static var shelfLevel: NSWindow.Level {
        let above = OnboardingController.backdropLevel.rawValue + 2
        let level = min(max(NSWindow.Level.statusBar.rawValue, above), NSWindow.Level.popUpMenu.rawValue - 1)
        return NSWindow.Level(rawValue: level)
    }

    override var canBecomeKey: Bool { true }

    /// Klick auf den Griff (auch knapp daneben, wenn der größere Trefferbereich an ist):
    /// Ablage ganz öffnen. Das Fenster nimmt Klicks in dieser Stufe nur an, wenn es soll.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let ui = actions?.ui, ui.level == .hint {
            ui.expandRequested = true
        }
        if event.type == .rightMouseDown, Diagnostics.shared.isEnabled {
            // Rechtsklick ging gleich nach dem Öffnen teils ins Leere: festhalten, wohin er geht
            let hit = contentView?.hitTest(contentView?.superview?.convert(event.locationInWindow, from: nil)
                                           ?? event.locationInWindow)
            Diagnostics.shared.record("menu", "right level=\(actions?.ui.level ?? .hidden) hit=\(hit.map { String(describing: type(of: $0)) } ?? "–") key=\(isKeyWindow) disabled=\(ShelfMenu.disabled) locked=\(actions?.ui.isLocked ?? false)")
        }
        super.sendEvent(event)
    }
    /// Nur während die Übersicht offen ist, wird die Ablage Hauptfenster: Dort sucht die
    /// Übersicht ihre Steuerung, während sie selbst den Fokus hat (wie ein Finder-Fenster)
    var allowsMain = false
    override var canBecomeMain: Bool { allowsMain }

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
        case 49: // Leertaste; gedrückt gehalten nicht in schneller Folge auf und zu
            guard !event.isARepeat else { return }
            Diagnostics.shared.record("key", "space in shelf quickLook=\(actions.isQuickLookVisible)")
            actions.toggleQuickLookCurrent()
        case 51, 117: // Löschen; gedrückt halten entfernt nicht alles nacheinander
            if !event.isARepeat { actions.removeCurrentSelection() }
        case 53: // Escape: Übersicht schließen, Auswahl aufheben, Stapel verlassen, schließen
            if actions.isQuickLookVisible {
                actions.closeQuickLook()
            } else if actions.isFolderOpen {
                actions.closeStack()        // im Ordner: gleich eine Ebene zurück
            } else if actions.hasCurrentSelection {
                actions.clearCurrentSelection()
            } else if actions.ui.openStack != nil {
                actions.closeStack()
            } else {
                onEscape()
            }
        case 36, 76: // Return
            actions.openCurrentSelection()
        case 123, 124, 125, 126: // Pfeiltasten (bei offener Übersicht blättert sie mit)
            if actions.quickLookArrow(event.keyCode) { return }
            let step: Int
            switch event.keyCode {
            case 123: step = -1
            case 124: step = 1
            case 126: step = -actions.columnCount
            default: step = actions.columnCount
            }
            actions.moveCurrentSelection(by: step, extend: shift)
            actions.quickLookFollowSelection()
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
        case "x":
            // Gehaltene Taste nur einmal: sonst schnitt sie Objekt um Objekt aus
            if !event.isARepeat { actions.cutCurrentSelection() }
        case "d":
            // Wie im Finder: Auswahl duplizieren (gehaltene Taste nur einmal)
            if !event.isARepeat { actions.duplicateCurrentSelection() }
        case "v":
            // Gehaltene Taste nur einmal: sonst landete derselbe Inhalt viele Male in der Ablage
            guard !event.isARepeat else { return true }
            if actions.isFolderOpen { actions.pasteIntoFolder() } else { actions.store.pasteFromClipboard() }
        case "y":
            actions.toggleQuickLookCurrent()
        case "o":
            actions.openCurrentSelection()
        case "r":
            actions.revealCurrentSelection()
        case "i":
            actions.getInfo(actions.currentSelectionURLs)
        case "z":
            if event.modifierFlags.contains(.shift) { actions.redo() } else { actions.undo() }
        case ",":
            // Wie im Kontextmenü angezeigt: Einstellungen öffnen
            actions.openSettings()
        case "q":
            NSApp.terminate(nil)
        default:
            if event.keyCode == 51 || event.keyCode == 117 { // ⌘⌫: in den Papierkorb, wie im Finder
                if !event.isARepeat { actions.trashCurrentSelection() }
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
        // Wie von Apple vorgesehen leeren, aber nicht, solange sie noch offen sein soll: sonst
        // stünde dort „Keine Objekte ausgewählt“
        if actions?.quickLookRequested != true {
            panel.dataSource = nil
            panel.delegate = nil
        }
        // Übersicht mit esc oder ihrem Knopf geschlossen: weiter in der Ablage
        DispatchQueue.main.async { [weak self] in
            // Nur wenn BarDrop vorn ist: Hat man zu einer anderen App gewechselt, bekäme
            // die Ablage sonst deren Tasten
            guard let self, let ui = self.actions?.ui, ui.level == .expanded, AppActivation.isFrontmost,
                  self.actions?.isQuickLookVisible == false else { return }
            self.makeKey()
        }
    }
}

/// Gemeinsame Drop-Logik der Ablage: nimmt Dateien, Bilder, Links und Text von
/// außen an. Eigene Objekte (aus der Ablage gezogen) werden hier ignoriert.
final class ShelfDropHandler {
    private let store: ShelfStore
    private let ui: ShelfUIModel
    /// Für den geöffneten Ordner: Abgelegtes landet dann im Ordner
    weak var actions: ShelfActions?

    init(store: ShelfStore, ui: ShelfUIModel) {
        self.store = store
        self.ui = ui
    }

    private func isOwn(_ sender: NSDraggingInfo?) -> Bool {
        sender?.draggingSource is DragSourceNSView
    }

    private func setTargeted(_ value: Bool) {
        guard ui.isDropTargeted != value else { return }
        // Losgelöst oder schwebend: dezenter Impuls, sobald etwas über der Ablage abgelegt
        // werden kann (am Rand kündigt das schon das Aufgehen an)
        if value && ui.tear != nil { Haptics.tap() }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            ui.isDropTargeted = value
        }
    }

    /// Geöffneter Ordner, falls Abgelegtes dorthin geht
    private var openFolder: URL? {
        guard let actions, actions.isFolderOpen else { return nil }
        return actions.folder.folder
    }

    /// Dateien (Adressen) aus dem Pasteboard
    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Ins geöffnete Ordner: Dateien und Datei-Versprechen (Mail, Fotos …), wie im Finder
    /// verschieben oder kopieren. Eigene Objekte aus dem Ordner selbst bleiben liegen.
    private func folderOperation(_ sender: NSDraggingInfo, folder: URL) -> NSDragOperation {
        let urls = isOwn(sender) ? ui.draggedFileURLs : Self.fileURLs(sender.draggingPasteboard)
        if let first = urls.first {
            if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }) {
                return isOwn(sender) ? .generic : []
            }
            return ShelfActions.folderOperation(for: first, into: folder, modifiers: NSEvent.modifierFlags)
        }
        let promises = sender.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return promises ? .copy : []
    }

    func entered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let folder = openFolder {
            let operation = folderOperation(sender, folder: folder)
            setTargeted(!operation.isEmpty && operation != .generic)
            return operation
        }
        // Kein Hinweis „Hier ablegen“ für eigene Objekte: Beim Herausziehen beginnt der
        // Zug ja über der Ablage
        if !isOwn(sender) { setTargeted(true) }
        // Nur in der Einführung: ein leichter Impuls, sobald das Übungsfoto die Fläche zum
        // Ablegen erreicht (dort steht die Ablage schon offen, der Impuls beim Öffnen fehlt)
        if IntroGate.active && !isOwn(sender) { Haptics.tap() }
        ui.setPinCandidate(isOwn(sender) ? nil : Self.pinCandidate(sender.draggingPasteboard))
        // Eigenes Objekt zurück in die Ablage: einfach zurücklegen
        return isOwn(sender) ? .generic : .copy
    }

    func updated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let folder = openFolder { return folderOperation(sender, folder: folder) }
        ui.holdPinCandidate()
        return isOwn(sender) ? .generic : .copy
    }

    /// Genau ein Ordner oder eine App aus dem Finder, die sich anheften ließe.
    /// Nur beim Hineinziehen gelesen, nicht bei jeder Bewegung.
    static func pinCandidate(_ pasteboard: NSPasteboard) -> URL? {
        let settings = AppSettings.shared
        guard settings.pinFromShelf,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first,
              ContentImporter.isUserFile(url), QuickAction.pinnableKind(url) != nil else { return nil }
        guard settings.canPin(url) else {
            // Ein Ordner oder eine App, aber kein Platz zum Anheften: warum (fürs Protokoll)
            let full = settings.quickActions.count >= QuickAction.limit
            let already = settings.quickActions.contains { $0.path == url.path }
            Diagnostics.shared.record("pin", "not offered full=\(full) alreadyPinned=\(already)")
            return nil
        }
        return url
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        if let folder = openFolder, let actions {
            setTargeted(false)
            let operation = folderOperation(sender, folder: folder)
            guard !operation.isEmpty else { return false }
            if operation == .generic {
                ui.lastDropWasInternal = true          // aus dem Ordner in denselben Ordner
                return true
            }
            let urls = isOwn(sender) ? ui.draggedFileURLs : Self.fileURLs(sender.draggingPasteboard)
            if isOwn(sender) { ui.lastDropWasInternal = true }
            if !urls.isEmpty {
                actions.fileIntoOpenFolder(urls)
            } else if let receivers = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                                                             options: nil) as? [NSFilePromiseReceiver] {
                let queue = OperationQueue()
                for receiver in receivers {
                    receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { _, error in
                        if let error { Diagnostics.shared.failure("drop", "Versprochene Datei nicht erhalten", error) }
                        DispatchQueue.main.async { actions.folder.reload() }
                    }
                }
            }
            Haptics.drop()
            return true
        }
        if isOwn(sender) {
            // Zurückgelegt: Das Objekt bleibt, wo es war, und wird nicht entfernt
            ui.lastDropWasInternal = true
            setTargeted(false)
            return true
        }
        Diagnostics.shared.record("drop", "shelf types=\(sender.draggingPasteboard.types?.map(\.rawValue).prefix(12).joined(separator: ",") ?? "–") items=\(sender.draggingPasteboard.pasteboardItems?.count ?? 0) source=\(sender.draggingSource.map { String(describing: type(of: $0)) } ?? "external") intro=\(IntroGate.active)")
        ShelfSnapshots.capture(actions?.panel, "drop", after: [0.2, 0.6, 1.5, 3])
        ShelfSnapshots.describe(actions?.panel, "drop", after: [0.05, 0.3, 1])
        store.ingest(from: sender.draggingPasteboard, byUser: true)
        Haptics.drop()
        setTargeted(false)
        ui.setPinCandidate(nil)
        return true
    }

    func finished() {
        setTargeted(false)
        ui.releasePinCandidate()
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

    /// Rechtsklick, der bis hierher durchfällt: Gleich nach dem Öffnen sind die Flächen mit
    /// den Menüs noch nicht an ihrem Platz (laut Protokoll ging der Klick 0,3 s nach dem
    /// Öffnen an diese Ansicht selbst), und es kam gar kein Menü. Dann das Menü der Ablage.
    override func rightMouseDown(with event: NSEvent) {
        guard let actions = dropHandler?.actions, actions.ui.level == .expanded else {
            super.rightMouseDown(with: event)
            return
        }
        actions.ui.menuOpen = true
        ShelfMenu.popUp(actions.backgroundMenu(), with: event, for: self)
        actions.ui.menuOpen = false
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
