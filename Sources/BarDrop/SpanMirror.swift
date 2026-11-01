import AppKit
import QuartzCore

/// Mit „Bildschirme verwenden verschiedene Spaces“ zeigt macOS ein Fenster nur auf dem
/// Bildschirm, auf dem sein größerer Teil liegt; der Rest bleibt unsichtbar. Zog man die
/// gelöste Ablage auf einen anderen Bildschirm, war sie halb abgeschnitten und dann weg
/// (Nutzer, 01.11.2026). Dieses Fenster zeigt den fehlenden Teil als Bild auf dem anderen
/// Bildschirm, so gleitet sie am Stück hinüber. Ohne getrennte Spaces bleibt es aus.
final class SpanMirror {
    private var window: NSPanel?
    private let image = CALayer()
    private var snapshot: CGImage?
    private var snapshotSize: NSSize = .zero
    private var capturing = false

    /// Bild des Fensters, wie es der Bildschirm zeigt (eigene Fenster brauchen dafür keine
    /// Erlaubnis; wie in ShelfSnapshots über dlsym, im SDK als veraltet markiert)
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()
    private static let queue = DispatchQueue(label: "BarDrop.SpanMirror", qos: .userInteractive)

    /// Nach jeder Bewegung der gelösten Ablage: Liegt ein Teil auf einem anderen Bildschirm
    /// als dem, den macOS ihr zuordnet, zeigt das Spiegelfenster ihn dort
    func update(for panel: NSWindow) {
        guard NSScreen.screensHaveSeparateSpaces, NSScreen.screens.count > 1, panel.isVisible,
              let home = panel.screen else { return hide() }
        let frame = panel.frame
        var best: NSRect?
        for screen in NSScreen.screens where screen != home {
            let part = screen.frame.intersection(frame)
            guard !part.isNull, part.width >= 1, part.height >= 1 else { continue }
            if best.map({ part.width * part.height > $0.width * $0.height }) ?? true { best = part }
        }
        guard let part = best else { return hide() }
        if snapshotSize != frame.size { snapshot = nil }
        guard let snapshot else { return capture(panel) }

        let window = self.window ?? makeWindow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image.contents == nil { image.contents = snapshot }
        image.contentsScale = panel.backingScaleFactor
        image.frame = CGRect(x: frame.minX - part.minX, y: frame.minY - part.minY,
                             width: frame.width, height: frame.height)
        CATransaction.commit()
        if window.level != panel.level { window.level = panel.level }
        window.setFrame(part, display: false)
        if !window.isVisible { window.orderFront(nil) }
    }

    /// Weg damit; beim nächsten Wechsel entsteht ein frisches Bild
    func hide() {
        window?.orderOut(nil)
        snapshot = nil
        image.contents = nil
    }

    /// Im Hintergrund aufnehmen: Auf dem Hauptthread hätte das ein Bild der Bewegung gekostet.
    /// Bis es da ist, fehlt der kleine Streifen auf dem anderen Bildschirm wie bisher.
    private func capture(_ panel: NSWindow) {
        guard !capturing, let createImage = Self.createImage else { return }
        capturing = true
        let number = UInt32(panel.windowNumber)
        let size = panel.frame.size
        Self.queue.async { [weak self] in
            // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
            let shot = createImage(.null, 8, number, 1)?.takeRetainedValue()
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                guard let shot else { return Diagnostics.shared.record("tear", "Spiegelbild nicht möglich") }
                self.snapshot = shot
                self.snapshotSize = size
                self.image.contents = nil
                self.update(for: panel)
            }
        }
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        image.contentsGravity = .resize
        image.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        view.layer?.addSublayer(image)
        window.contentView = view
        self.window = window
        return window
    }
}
