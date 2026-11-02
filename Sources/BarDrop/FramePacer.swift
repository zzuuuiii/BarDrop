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
    /// Ob die Arbeit eines Bildes rechtzeitig fertig war: Der Takt kann pünktlich kommen und das
    /// Bild trotzdem zu spät gezeigt werden, wenn das Neuzeichnen (SwiftUI, Fenster verschieben)
    /// länger dauert als bis zum nächsten Bildwechsel. Gemessen bis der Hauptthread wieder wartet
    /// (dann schickt Core Animation das Bild ab)
    private var observer: CFRunLoopObserver?
    private var frameStart: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var work: [CFTimeInterval] = []
    private var overruns = 0
    /// Zähler, die eine Bewegung selbst meldet (etwa „verpasst“ beim Ziehen), mit ausgegeben
    private var notes: [String: Int] = [:]

    /// Ereignis während der Messung zählen
    func note(_ name: String) {
        guard link != nil else { return }
        notes[name, default: 0] += 1
    }

    func start(on window: NSWindow, label: String, duration: TimeInterval) {
        guard Diagnostics.shared.isEnabled, let view = window.contentView else { return }
        stop()
        self.label = label
        until = Date().addingTimeInterval(duration)
        intervals = []
        last = 0
        spikes = []
        started = CACurrentMediaTime()
        work = []
        overruns = 0
        notes = [:]
        deadline = 0
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.beforeWaiting()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func beforeWaiting() {
        guard deadline > 0 else { return }
        let now = CACurrentMediaTime()
        work.append(now - frameStart)
        if now > deadline { overruns += 1 }
        deadline = 0
    }

    @objc private func frame(_ link: CADisplayLink) {
        frameStart = CACurrentMediaTime()
        deadline = link.targetTimestamp
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
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        guard intervals.count > 2 else { return }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let late = intervals.filter { $0 > median * 1.5 }.count
        let worst = Int(((sorted.last ?? 0) * 1000).rounded())
        let where_ = spikes.map { String(format: "%.2fs/%dms", $0.at, Int(($0.gap * 1000).rounded())) }.joined(separator: " ")
        let sortedWork = work.sorted()
        let workMedian = sortedWork.isEmpty ? 0 : sortedWork[sortedWork.count / 2] * 1000
        let workMax = (sortedWork.last ?? 0) * 1000
        let extra = notes.keys.sorted().map { " \($0)=\(notes[$0] ?? 0)" }.joined()
        Diagnostics.shared.record("perf", "\(label) frames=\(intervals.count + 1) median=\(String(format: "%.1f", median * 1000))ms worst=\(worst)ms late=\(late) spikes=[\(where_)] work=\(String(format: "%.1f/%.1f", workMedian, workMax))ms overrun=\(overruns)\(extra)")
    }
}
