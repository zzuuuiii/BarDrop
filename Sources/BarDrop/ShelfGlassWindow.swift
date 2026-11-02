import AppKit
import QuartzCore
import SwiftUI

/// Glas hinter der losgelösten Ablage, in einem eigenen Begleitfenster: Liquid Glass reagiert
/// auf Fokus und Klicks des Fensters, in dem es liegt (heller, anders getönt). Dieses Fenster
/// bekommt nie den Fokus, nimmt keine Klicks an und hängt als Kindfenster unter der Ablage,
/// bewegt sich also mit ihr. So bleibt das Glas immer gleich.
///
/// Material: Liquid Glass (ab macOS 26), von Anfang an bis zum Andocken. Es kostete beim Ziehen
/// Bilder, solange das Fenster erst beim Lösen eingehängt und weich ein- und ausgeblendet wurde
/// (Diagnose 27.10.2026, Aussetzer bis 160 ms); beides fällt jetzt weg (siehe EdgeController
/// prepareGlassWindow, syncGlassWindow). Der Blur (blurView) dient vor macOS 26.
final class ShelfGlassWindow: NSPanel {
    /// Blur: vor macOS 26 (ab macOS 26 nur noch für die Tönung „Manuell“, siehe setManualTint)
    private let blurView = NSVisualEffectView()
    /// Liquid Glass, erst bei Bedarf angelegt
    private var glassView: NSView?

    /// Liquid Glass ist eingesetzt (siehe useGlass)
    private var usesGlass = false

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // „menu“ ist das hellste Blur-Material (gemessen 27.10.2026 über dunklem Hintergrund:
        // hudWindow 17, menu 28, Liquid Glass 30 von 255); hudWindow wirkte fast schwarz
        blurView.material = .menu
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.maskImage = Self.mask(EdgeTear.cornerRadius)
        blurView.wantsLayer = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        let content = NSView()
        content.addSubview(blurView)
        contentView = content
        alphaValue = 0
    }

    /// „Manuell“ (Einstellungen → Aussehen): eigene Stellung statt des Reglers von macOS. Liquid
    /// Glass dann im Stil „klar“, der dem Systemregler nicht folgt (Annahme laut Apple-Doku), und
    /// darüber der Blur so stark, wie getönt eingestellt ist: 0 klar, 1 ganz diffus. nil: System
    func setManualTint(_ value: Double?) {
        guard #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView,
              let content = contentView else { return }
        if let value {
            if glass.style != .clear { glass.style = .clear }
            if content.subviews.last !== blurView { content.addSubview(blurView, positioned: .above, relativeTo: glass) }
            blurView.alphaValue = CGFloat(max(0, min(1, value)))
            blurView.isHidden = value < 0.01
        } else {
            if glass.style != .regular { glass.style = .regular }
            if content.subviews.first !== blurView { content.addSubview(blurView, positioned: .below, relativeTo: glass) }
            blurView.alphaValue = 0
            blurView.isHidden = false
        }
    }

    /// Liquid Glass einsetzen (ab macOS 26; davor bleibt der Blur). Früher wechselte das
    /// Begleitfenster weich zwischen Blur und Glas; das kostete beim Ziehen Bilder und fiel weg
    /// (Diagnose 27.10.2026), seitdem gibt es nur noch diesen einen Wechsel, ohne Überblendung
    func useGlass() {
        guard !usesGlass else { return }
        usesGlass = true
        guard #available(macOS 26.0, *) else { return }
        let glass = NSGlassEffectView()
        glass.cornerRadius = EdgeTear.cornerRadius
        // Dunkel: etwas Tönung im Glas selbst, so hell wie der Blur beim Ziehen (und wie das
        // Glas mit der früheren Tönung 0,5 der Ablage); hell ohne
        glass.tintColor = nil
        glass.wantsLayer = true
        glass.frame = blurView.frame
        contentView?.addSubview(glass, positioned: .above, relativeTo: blurView)
        glassView = glass
        glass.alphaValue = 1
        blurView.alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Glas an die Lage der Ablage im Fenster `parent` anpassen (`body` in dessen Koordinaten).
    /// `edge`: Seite zum Bildschirmrand, solange die Ablage mit ihm verbunden ist
    func follow(_ parent: NSWindow, body: NSRect, edge: ScreenEdge? = nil, edgeRadius: CGFloat = EdgeTear.cornerRadius) {
        if level != parent.level { level = parent.level }
        // Glas folgt dem hellen oder dunklen Erscheinungsbild des Systems (hell: heller)
        let light = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        let look = NSAppearance(named: light ? .aqua : .darkAqua)
        if appearance?.name != look?.name { appearance = look }
        if collectionBehavior != parent.collectionBehavior { collectionBehavior = parent.collectionBehavior }
        // Das Fenster ist genau so groß wie die Ablage: Nur sein Rand schneidet das Glas
        // zuverlässig ab. Das Glas zeichnet das Fenstersystem, ein Ausschnitt in einer Ebene
        // darüber (masksToBounds) gilt dafür nicht.
        let target = NSRect(x: parent.frame.minX + body.minX, y: parent.frame.minY + body.minY,
                            width: body.width, height: body.height)
        if frame != target { setFrame(target, display: false) }
        // Verbunden: Früher war das Glas auf der Randseite 6 pt schmaler, damit seine helle Kante
        // nicht als Linie zu sehen war. Seine runden Ecken blieben, und daneben lag ein Streifen
        // ohne Glas: am Rand ein zweiter Rand mit eigenen Ecken. Jetzt reicht das Glas dort über
        // das Fenster hinaus; Kante und Ecken liegen außerhalb, das Fenster schneidet gerade ab.
        // Die Ecken der Ablage auf dieser Seite deckt das Schwarz der Verbindung (TearGoo).
        var glass = NSRect(origin: .zero, size: body.size)
        if let edge {
            let over = EdgeTear.cornerRadius + 4
            glass.size.width += over
            if edge == .left { glass.origin.x -= over }
        }
        if blurView.frame != glass { blurView.frame = glass }
        if let view = glassView, view.frame != glass { view.frame = glass }
        // Die Ecken auf der Randseite rund wie die Ablage selbst (EdgeTear.edgeRadius): Das
        // Fenster schnitt sie gerade ab, beim Zurückziehen an den Rand waren sie eckig
        roundCorners(size: body.size, edge: edge, edgeRadius: edgeRadius)
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .below)
        }
    }

    private let cornerMask = CAShapeLayer()

    private func roundCorners(size: NSSize, edge: ScreenEdge?, edgeRadius: CGFloat) {
        guard let content = contentView else { return }
        content.wantsLayer = true
        guard let edge else {
            // Losgelöst: Das Glas rundet seine Ecken selbst
            if content.layer?.mask != nil { content.layer?.mask = nil }
            return
        }
        let far = EdgeTear.cornerRadius
        let r = min(edgeRadius, size.height / 2)
        let left = edge == .left
        let key = "\(size.width)|\(size.height)|\(r)|\(left)"
        // Unverändert: nichts tun (wird beim Ziehen bei jeder Bewegung aufgerufen); erst danach
        // den Umriss bauen
        if key == cornerKey, content.layer?.mask === cornerMask { return }
        cornerKey = key
        let path = Path { p in
            p.addRoundedRect(in: CGRect(origin: .zero, size: size),
                             cornerRadii: RectangleCornerRadii(topLeading: left ? r : far,
                                                               bottomLeading: left ? r : far,
                                                               bottomTrailing: left ? far : r,
                                                               topTrailing: left ? far : r),
                             style: .continuous)
        }
        // Ohne eigene Animation: Eine frei stehende Ebene animiert Änderungen von Rahmen und
        // Umriss sonst von selbst über 0,25 s. Die Ecken des Glases liefen der Ablage beim
        // Dehnen und Andocken so sichtbar hinterher
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cornerMask.frame = CGRect(origin: .zero, size: size)
        cornerMask.path = path.cgPath
        if content.layer?.mask !== cornerMask { content.layer?.mask = cornerMask }
        CATransaction.commit()
    }

    /// Zuletzt gesetzte Maske (Größe, Radius, Seite)
    private var cornerKey = ""

    /// Ein- und ausblenden (0 bis 1), sofort
    func show(_ amount: CGFloat) {
        alphaValue = max(0, min(1, amount))
    }

    /// Ganz weg und vom Fenster der Ablage gelöst
    func detach() {
        alphaValue = 0
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
