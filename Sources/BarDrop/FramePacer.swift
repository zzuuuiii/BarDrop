import AppKit
import QuartzCore

/// Diagnose (nur mit Diagnoseprotokoll): misst, wie gleichmäßig die Bilder einer Bewegung
/// kommen (Öffnen, Ziehen). Jeder Bildwechsel des Bildschirms ruft hier an; kommt der Aufruf
/// zu spät, war der Hauptthread beschäftigt, und die Bewegung ruckelt.
final class FramePacer: NSObject {
    static let shared = FramePacer()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [CFTimeInterval] = []
    private var label = ""
    private var until = Date.distantPast
    /// Beginn der Messung und die Ausreißer (Zeitpunkt seit Beginn, Dauer): Zeigt, wo in der
    /// Bewegung die späten Bilder liegen (Lösen, Andocken), nicht nur wie viele es gab
    private var started: CFTimeInterval = 0
    private var spikes: [(at: CFTimeInterval, gap: CFTimeInterval)] = []

    func start(on window: NSWindow, label: String, duration: TimeInterval) {
        guard Diagnostics.shared.isEnabled, let view = window.contentView else { return }
        stop()
        self.label = label
        until = Date().addingTimeInterval(duration)
        intervals = []
        last = 0
        spikes = []
        started = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        if last > 0 {
            let gap = link.timestamp - last
            intervals.append(gap)
            // Ab zwei verpassten Bildern (bei 48 Hz) festhalten, höchstens zwölf
            if gap > 0.035, spikes.count < 12 { spikes.append((link.timestamp - started, gap)) }
        }
        last = link.timestamp
        if Date() > until { stop() }
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        guard intervals.count > 2 else { return }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let late = intervals.filter { $0 > median * 1.5 }.count
        let worst = Int(((sorted.last ?? 0) * 1000).rounded())
        let where_ = spikes.map { String(format: "%.2fs/%dms", $0.at, Int(($0.gap * 1000).rounded())) }.joined(separator: " ")
        Diagnostics.shared.record("perf", "\(label) frames=\(intervals.count + 1) median=\(String(format: "%.1f", median * 1000))ms worst=\(worst)ms late=\(late) spikes=[\(where_)]")
    }
}
