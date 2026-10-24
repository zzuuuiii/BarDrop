import AppKit

/// Menüeintrag, dessen Titel sich im offenen Menü fortlaufend erneuert (Fortschritt
/// eines laufenden Plugins). Nur zur Anzeige, nicht wählbar.
final class LiveMenuItem: NSMenuItem {
    private let provider: () -> String
    private var timer: Timer?

    init(_ provider: @escaping () -> String) {
        self.provider = provider
        super.init(title: provider(), action: nil, keyEquivalent: "")
        isEnabled = false
        // Auch während das Menü offen ist (eigener Ablaufmodus): im gemeinsamen Modus
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, self.menu != nil else { return timer.invalidate() }
            let text = self.provider()
            if text != self.title { self.title = text }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }
}
