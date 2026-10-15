import AppKit
import SwiftUI

/// Drop-Ziel für eine Aktion. Nimmt Objekte aus der Ablage und von außen an,
/// gibt beim Drüberziehen einen einzelnen Haptik-Impuls und führt die Aktion
/// beim Loslassen aus. Ein Klick wendet die Aktion auf die Auswahl an.
final class ActionDropNSView: NSView {
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (NSPasteboard, NSView) -> Void = { _, _ in }
    var onOwnDrop: ([URL], NSView) -> Void = { _, _ in }
    var onClick: (NSView) -> Void = { _ in }
    weak var ui: ShelfUIModel?

    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ShelfStore.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed && inside { onClick(self) }
        pressed = false
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted(true)
        Haptics.tap()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingSource is DragSourceNSView, let ui {
            // Eigene Objekte: die gespeicherten Dateien verwenden, nicht die frischen
            // Kopien auf dem Drag-Pasteboard (sonst verschiebt z. B. eine Ordner-Aktion nur die Kopie)
            ui.lastDropWasInternal = true
            let urls = ui.draggedFileURLs
            DispatchQueue.main.async { self.onOwnDrop(urls, self) }
            Haptics.drop()
            return true
        }
        onDrop(sender.draggingPasteboard, self)
        Haptics.drop()
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }
}

struct ActionDropTarget: NSViewRepresentable {
    var ui: ShelfUIModel
    var onTargeted: (Bool) -> Void
    var onDrop: (NSPasteboard, NSView) -> Void
    var onOwnDrop: ([URL], NSView) -> Void
    var onClick: (NSView) -> Void

    func makeNSView(context: Context) -> ActionDropNSView {
        let view = ActionDropNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: ActionDropNSView, context: Context) { configure(view) }

    private func configure(_ view: ActionDropNSView) {
        view.ui = ui
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.onOwnDrop = onOwnDrop
        view.onClick = onClick
    }
}

// MARK: Darstellung

/// Symbol einer Aktion: echte App-, Ordner- und AirDrop-Symbole,
/// „Teilen“ im selben Kachelstil gezeichnet.
struct QuickActionIcon: View {
    let action: QuickAction
    var size: CGFloat = 34

    var body: some View {
        if let icon = action.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // Eigene Kachel im macOS-Icon-Raster, im Blau von AirDrop, Ordnern und Mail
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.68, blue: 1.0),
                                              Color(red: 0.1, green: 0.45, blue: 0.95)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .overlay(
                    Image(systemName: action.fallbackSymbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(y: action.kind == .share ? -size * 0.03 : 0)
                )
                .frame(width: size * 0.84, height: size * 0.84)
                .frame(width: size, height: size)
        }
    }
}

struct QuickActionButton: View {
    let action: QuickAction
    @ObservedObject var ui: ShelfUIModel
    let store: ShelfStore
    let actions: ShelfActions

    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            QuickActionIcon(action: action)
                .scaleEffect(targeted ? 1.1 : 1)
            Text(action.title)
                .font(.system(size: 10, weight: targeted ? .semibold : .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.12 : 0))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .overlay(
            ActionDropTarget(
                ui: ui,
                onTargeted: { targeted = $0 },
                onDrop: { pb, anchor in
                    let files = (pb.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                    if !files.isEmpty && files.allSatisfy(ContentImporter.isUserFile) {
                        // Dateien aus dem Finder direkt verwenden
                        DispatchQueue.main.async { actions.perform(action, urls: files, anchor: anchor) }
                    } else {
                        // Bilder aus dem Web, temporäre Dateien, Links, Text: zuerst in die
                        // Ablage übernehmen, dann ausführen
                        store.ingest(from: pb) { urls in
                            actions.perform(action, urls: urls, anchor: anchor)
                        }
                    }
                },
                onOwnDrop: { urls, anchor in
                    actions.perform(action, urls: urls, anchor: anchor)
                },
                onClick: { anchor in
                    actions.perform(action, urls: actions.selectedEntries.flatMap(\.urls), anchor: anchor)
                }
            )
        )
        .help(action.help)
    }
}

struct QuickActionBar: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: ShelfUIModel
    let store: ShelfStore
    let actions: ShelfActions

    var body: some View {
        let all = settings.quickActions
        Group {
            if settings.twoActionRows {
                // Zwei Reihen, wie in den Einstellungen verteilt. Beide auf demselben
                // Raster von fünf Plätzen, damit die Symbole übereinander stehen.
                let split = settings.effectiveActionSplit
                let top = Array(all.prefix(split))
                let bottom = Array(all.dropFirst(split).prefix(QuickAction.perRow))
                if top.isEmpty || bottom.isEmpty {
                    row(top.isEmpty ? bottom : top)
                } else {
                    VStack(spacing: 4) {
                        row(top)
                        row(bottom)
                    }
                }
            } else {
                row(Array(all.prefix(QuickAction.limit(twoRows: false))))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Eine Reihe: die Aktionen teilen sich die ganze Breite, jede mittig in ihrem Teil.
    private func row(_ items: [QuickAction]) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { action in
                QuickActionButton(action: action, ui: ui, store: store, actions: actions)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
