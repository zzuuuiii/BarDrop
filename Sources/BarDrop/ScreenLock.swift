import AppKit

/// Merkt, ob der Bildschirm gesperrt ist oder ein anderer Benutzer gerade am Mac ist.
///
/// Auf dem Sperrbildschirm lief der Takt der Ablage weiter: Fuhr man dort an den Rand,
/// vibrierte das Trackpad, obwohl von BarDrop nichts zu sehen war. Solange gesperrt ist,
/// reagiert die Ablage deshalb gar nicht auf den Rand.
final class ScreenLock {
    static let shared = ScreenLock()

    /// Gesperrt oder Sitzung nicht im Vordergrund (Benutzerwechsel)
    var isLocked: Bool { screenLocked || !sessionActive }

    private var screenLocked = false
    private var sessionActive = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        screenLocked = Self.lockedNow()
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionActive = true }
    }

    /// Zustand beim Start (BarDrop kann auch bei gesperrtem Bildschirm starten)
    private static func lockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping (ScreenLock) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            Diagnostics.shared.record("lock", "locked=\(self.isLocked)")
        }
        observers.append((center, token))
    }
}
