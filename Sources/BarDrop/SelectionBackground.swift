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
    /// So viel ist unten vom sichtbaren Bereich verdeckt (Aktionsleiste): Der Rahmen endet darüber
    var bottomInset: CGFloat = 0
    weak var ui: ShelfUIModel?

    private var start: CGPoint?
    private var modifiers: NSEvent.ModifierFlags = []
    private var banding = false
    /// Letzte Zeigerposition im Fenster, für das Weiterscrollen ohne Mausbewegung
    private var lastWindowPoint: CGPoint?
    private var scrollTimer: Timer?

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
        guard start != nil, allowsBand else { return }
        lastWindowPoint = event.locationInWindow
        updateBand()
        if banding { startScrollTimer() }
    }

    /// Sichtbarer Teil der Ablage, in dem der Rahmen bleibt: ohne die Aktionsleiste unten
    private var bandArea: CGRect {
        var area = visibleRect.insetBy(dx: 8, dy: 2)
        area.size.height = max(0, area.height - bottomInset)
        return area
    }

    /// Rahmen bis zum Zeiger, aber nie über den sichtbaren Bereich hinaus. Liegt der
    /// Zeiger darüber oder darunter, scrollt die Ablage mit, wie im Finder.
    private func updateBand() {
        guard let start, let windowPoint = lastWindowPoint else { return }
        let raw = convert(windowPoint, from: nil)
        let area = bandArea
        let p = CGPoint(x: min(max(raw.x, area.minX), area.maxX),
                        y: min(max(raw.y, area.minY), area.maxY))
        if !banding && hypot(p.x - start.x, p.y - start.y) < 3 { return }
        if !banding { ui?.bandActive = true }
        banding = true
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(p.x - start.x), height: abs(p.y - start.y))
        onBandChanged(rect, modifiers)
    }

    /// Scrollt, solange der Zeiger über oder unter dem sichtbaren Bereich steht
    private func startScrollTimer() {
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.scrollTowardsPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func stopScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func scrollTowardsPointer() {
        guard banding, let windowPoint = lastWindowPoint,
              let clip = enclosingScrollView?.contentView, let document = clip.documentView else {
            return stopScrollTimer()
        }
        let raw = convert(windowPoint, from: nil)
        let area = bandArea
        let overshoot: CGFloat
        if raw.y > area.maxY { overshoot = raw.y - area.maxY }
        else if raw.y < area.minY { overshoot = raw.y - area.minY }
        else { return }
        // Je weiter darüber hinaus, desto schneller, höchstens 18 pt pro Bild
        let step = max(-18, min(18, overshoot / 3))
        var origin = clip.bounds.origin
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let flipped = clip.isFlipped
        origin.y = min(max(origin.y + (flipped ? step : -step), 0), maxY)
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        updateBand()
    }

    override func mouseUp(with event: NSEvent) {
        stopScrollTimer()
        lastWindowPoint = nil
        if banding {
            onBandChanged(nil, modifiers)
            ui?.bandActive = false
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
        ShelfUIModel.keepOpen(ui) { ShelfMenu.popUp(menu, with: event, for: self) }
    }
}

struct SelectionBackground: NSViewRepresentable {
    var ui: ShelfUIModel
    var onBandChanged: (CGRect?, NSEvent.ModifierFlags) -> Void
    var onClick: () -> Void
    var menu: () -> NSMenu?
    var allowsBand = true
    var bottomInset: CGFloat = 0

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
        view.bottomInset = bottomInset
    }
}

/// Rahmen der Kacheln im Koordinatensystem des Rasters, für die Lasso-Auswahl.
struct TileFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
