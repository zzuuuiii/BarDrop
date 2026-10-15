import AppKit
import SwiftUI

/// Leere Fläche hinter den Kacheln: Klick hebt die Auswahl auf, Ziehen
/// zieht ein Auswahlrechteck (Lasso), Rechtsklick öffnet das Ablage-Menü.
final class SelectionBackgroundNSView: NSView {
    var onBandChanged: (CGRect?, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }
    /// false: nur Klick und Rechtsklick, kein Auswahlrahmen (z. B. Kopfbereich)
    var allowsBand = true
    weak var ui: ShelfUIModel?

    private var start: CGPoint?
    private var modifiers: NSEvent.ModifierFlags = []
    private var banding = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
            return
        }
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        modifiers = event.modifierFlags
        banding = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, allowsBand else { return }
        autoscroll(with: event)
        // Der Rahmen bleibt in der sichtbaren Ablage, auch wenn der Zeiger darüber hinausgeht
        let raw = convert(event.locationInWindow, from: nil)
        let area = visibleRect.insetBy(dx: 8, dy: 2)
        let p = CGPoint(x: min(max(raw.x, area.minX), area.maxX),
                        y: min(max(raw.y, area.minY), area.maxY))
        if !banding && hypot(p.x - start.x, p.y - start.y) < 3 { return }
        banding = true
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(p.x - start.x), height: abs(p.y - start.y))
        onBandChanged(rect, modifiers)
    }

    override func mouseUp(with event: NSEvent) {
        if banding {
            onBandChanged(nil, modifiers)
        } else if start != nil {
            onClick()
        }
        start = nil
        banding = false
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        guard let menu = menuProvider() else { return }
        guard let window else { return }
        ui?.menuOpen = true
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }   // für Escape und Hervorhebung
        window.makeKey()
        // Eigenes Menü statt des Systemmenüs: folgt dem Zeiger ohne Verzögerung und
        // zeigt Untermenüs daneben im selben Aussehen
        let point = window.convertPoint(toScreen: event.locationInWindow)
        ChoicePopup.present(menu, at: point, parent: window) { [weak self] in self?.ui?.menuOpen = false }
    }
}

struct SelectionBackground: NSViewRepresentable {
    var ui: ShelfUIModel
    var onBandChanged: (CGRect?, NSEvent.ModifierFlags) -> Void
    var onClick: () -> Void
    var menu: () -> NSMenu?
    var allowsBand = true

    func makeNSView(context: Context) -> SelectionBackgroundNSView {
        let view = SelectionBackgroundNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: SelectionBackgroundNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: SelectionBackgroundNSView) {
        view.ui = ui
        view.onBandChanged = onBandChanged
        view.onClick = onClick
        view.menuProvider = menu
        view.allowsBand = allowsBand
    }
}

/// Rahmen der Kacheln im Koordinatensystem des Rasters, für die Lasso-Auswahl.
struct TileFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
