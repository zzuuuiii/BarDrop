import AppKit
import IOKit

/// Haptisches Feedback auf Force-Touch-Trackpads.
///
/// `NSHapticFeedbackManager` wirkt nur, solange die eigene App aktiv ist. BarDrop
/// läuft fast immer im Hintergrund, deshalb wird der Impuls direkt über den
/// Aktuator des Trackpads ausgelöst (MultitouchSupport, wie z. B. bei HapticKey).
/// Ist das nicht möglich, wird auf `NSHapticFeedbackManager` zurückgegriffen.
enum Haptics {
    /// Einzelner, dezenter Impuls (Öffnen, Drüberziehen einer Aktion).
    /// Zeitpunkt des letzten Impulses (nur auf dem Hauptthread)
    private static var lastTap = Date.distantPast

    static func tap() {
        guard AppSettings.shared.hapticsEnabled else { return }
        // Zwei Auslöser im selben Moment (z. B. Ablage erreicht und Aktion darunter) zählen einmal
        let now = Date()
        guard now.timeIntervalSince(lastTap) > 0.08 else { return }
        lastTap = now
        if !TrackpadActuator.shared.actuate(.weak) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Beim Ablegen bewusst kein Impuls: Das Loslassen auf dem Trackpad klickt schon
    /// selbst, ein zusätzlicher Impuls direkt danach fühlt sich doppelt an. Bleibt als
    /// Stelle für alle Ablageorte erhalten.
    static func drop() {}
}

/// Direkter Zugriff auf den Trackpad-Aktuator über das private Framework
/// MultitouchSupport. Wird zur Laufzeit geladen; fehlt es, liefert `actuate` false.
final class TrackpadActuator {
    enum Strength: Int32 {
        case weak = 3
        case medium = 4
    }

    static let shared = TrackpadActuator()

    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenFn = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32
    private typealias CloseFn = @convention(c) (CFTypeRef) -> Int32

    private var create: CreateFn?
    private var open: OpenFn?
    private var actuateFn: ActuateFn?
    private var close: CloseFn?
    private var actuators: [CFTypeRef] = []
    private var lastRefresh = Date.distantPast

    private init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        if let sym = dlsym(handle, "MTActuatorCreateFromDeviceID") { create = unsafeBitCast(sym, to: CreateFn.self) }
        if let sym = dlsym(handle, "MTActuatorOpen") { open = unsafeBitCast(sym, to: OpenFn.self) }
        if let sym = dlsym(handle, "MTActuatorActuate") { actuateFn = unsafeBitCast(sym, to: ActuateFn.self) }
        if let sym = dlsym(handle, "MTActuatorClose") { close = unsafeBitCast(sym, to: CloseFn.self) }
        refresh()
    }

    /// Sucht alle Multitouch-Geräte (eingebautes Trackpad, Magic Trackpad) und öffnet ihre Aktuatoren.
    private func refresh() {
        lastRefresh = Date()
        // Alte Verbindungen zum Trackpad sauber schließen, bevor neue geöffnet werden
        if let close { actuators.forEach { _ = close($0) } }
        actuators.removeAll()
        guard let create, let open else { return }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let number = value as? NSNumber,
               let actuator = create(number.uint64Value)?.takeRetainedValue(),
               open(actuator) == 0 {
                actuators.append(actuator)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// Löst einen Impuls auf allen Trackpads aus. Gibt false zurück, wenn das nicht möglich war.
    @discardableResult
    func actuate(_ strength: Strength) -> Bool {
        guard let actuateFn else { return false }
        // Ein später angeschlossenes Magic Trackpad wird beim nächsten Impuls gefunden
        if actuators.isEmpty, Date().timeIntervalSince(lastRefresh) > 5 { refresh() }
        var success = false
        for actuator in actuators where actuateFn(actuator, strength.rawValue, 0, 0, 0) == 0 {
            success = true
        }
        if !success && !actuators.isEmpty && Date().timeIntervalSince(lastRefresh) > 30 {
            refresh()   // z. B. nach Ruhezustand neu öffnen
        }
        return success
    }
}
