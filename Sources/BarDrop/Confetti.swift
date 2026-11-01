import AppKit
import SwiftUI

/// Konfetti über alle Bildschirme am Ende der Einführung. Nachgebaut nach dem Konfetti der
/// Vorführung auf der Website (app.js, `confetti()`): dieselben Farben, Streifen und Punkte,
/// die flattern und sanft fallen, dann ausblenden. Liegt über allem, nimmt keine Klicks an.
/// Mit „Bewegung reduzieren“ entfällt es.
enum ConfettiShower {
    /// Gesamtdauer; ab `fadeStart` wird ausgeblendet
    static let duration: Double = 5
    static let fadeStart: Double = 4

    /// Offene Fenster, bis das Konfetti vorbei ist
    private static var windows: [NSWindow] = []

    static func play() {
        guard !AnimationStyle.reduceMotion, windows.isEmpty else { return }
        windows = NSScreen.screens.map { screen in
            let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: ConfettiView(size: screen.frame.size))
            host.sizingOptions = []
            window.contentView = host
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            windows.forEach { $0.orderOut(nil) }
            windows = []
        }
    }
}

/// Zeichnet das Konfetti eines Bildschirms Bild für Bild
private struct ConfettiView: View {
    let size: CGSize
    @State private var field: ConfettiField

    init(size: CGSize) {
        self.size = size
        _field = State(initialValue: ConfettiField(size: size))
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, _ in
                let elapsed = field.advance(to: context.date)
                let t = elapsed * 1000
                canvas.opacity = elapsed > ConfettiShower.fadeStart
                    ? max(0, 1 - (elapsed - ConfettiShower.fadeStart) / (ConfettiShower.duration - ConfettiShower.fadeStart))
                    : 1
                for piece in field.pieces {
                    var c = canvas
                    c.translateBy(x: piece.x, y: piece.y)
                    c.rotate(by: .radians(piece.rotation))
                    // Flattern: kippt um die Längsachse wie ein fallendes Blättchen
                    c.scaleBy(x: 1, y: cos(t / 160 + piece.phase))
                    if piece.dot {
                        let r = piece.h * 0.75
                        c.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(piece.color))
                    } else {
                        c.fill(Path(CGRect(x: -piece.w / 2, y: -piece.h / 2, width: piece.w, height: piece.h)),
                               with: .color(piece.color))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// Teilchen und ihre Bewegung. Die Werte der Website gelten je Bild bei 60 Hz und für eine
/// Fläche von etwa 560 pt Höhe; hier nach Zeit gerechnet und auf den Bildschirm hochgerechnet.
private final class ConfettiField {
    struct Piece {
        var x, y, w, h, vx, vy, rotation, spin, phase: Double
        var color: Color
        var dot: Bool
    }

    private(set) var pieces: [Piece]
    private let start = Date()
    private var last: Date
    /// Größe gegenüber der Fläche auf der Website
    private let scale: Double

    static let colors: [Color] = [0xff375f, 0xff9f0a, 0xffd60a, 0x30d158, 0x0a84ff, 0xbf5af2, 0x64d2ff, 0xffffff].map {
        Color(red: Double(($0 >> 16) & 0xff) / 255, green: Double(($0 >> 8) & 0xff) / 255, blue: Double($0 & 0xff) / 255)
    }

    init(size: CGSize) {
        last = start
        let w = Double(size.width), h = Double(size.height)
        scale = max(1, h / 560)
        let count = Int(min(420, max(170, 170 * w / 800)))
        let s = scale
        pieces = (0..<count).map { _ in
            Piece(x: .random(in: 0...w), y: -20 * s - .random(in: 0...(h * 0.7)),
                  w: (7 + .random(in: 0...6)) * min(s, 1.4), h: (3.5 + .random(in: 0...3.5)) * min(s, 1.4),
                  vx: (.random(in: 0...1) - 0.5) * 1.4 * s, vy: (1.5 + .random(in: 0...2.5)) * s,
                  rotation: .random(in: 0...6.28), spin: .random(in: -0.11...0.11), phase: .random(in: 0...6.28),
                  color: Self.colors.randomElement()!, dot: .random(in: 0...1) < 0.22)
        }
    }

    /// Bis `date` weiterrechnen; gibt die Sekunden seit dem Start zurück
    func advance(to date: Date) -> Double {
        // In Bildern zu 60 Hz, damit es bei 120 Hz und nach kurzem Stocken gleich schnell fällt
        let frames = min(4, max(0, date.timeIntervalSince(last) * 60))
        last = date
        let t = date.timeIntervalSince(start) * 1000
        for i in pieces.indices {
            pieces[i].vy = min(pieces[i].vy + 0.03 * scale * frames, 4.2 * scale)
            pieces[i].x += (pieces[i].vx + sin(t / 420 + pieces[i].phase) * 0.9 * scale) * frames
            pieces[i].y += pieces[i].vy * frames
            pieces[i].rotation += pieces[i].spin * frames
        }
        return date.timeIntervalSince(start)
    }
}
