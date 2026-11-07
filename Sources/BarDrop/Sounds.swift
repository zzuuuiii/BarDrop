import AppKit

/// Klänge wie im Finder.
enum Sounds {
    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"

    /// In den Papierkorb (⌘⌫, Aktion Papierkorb): der Klang von macOS beim Ziehen auf den
    /// Papierkorb. Fehlt er, bleibt es still.
    private static let trashSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "dock/drag to trash.aif"), byReference: true)

    /// Aus der Ablage entfernen (⌫, Entfernen, Alle entfernen): der Klang des Finders
    /// „move to trash“, den BarDrop bis 1.30.0 Beta 14 für alles verwendet hat. Nur sein
    /// erster Schlag: Die Datei blendet 80 ms leise ein und klingt danach noch über eine
    /// Sekunde nach, das wirkte verzögert und zu lang. Leiser abgespielt: man hört ihn oft.
    private static let removeSound: NSSound? = {
        let sound = NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "finder/move to trash.aif"), byReference: false)
        sound?.volume = removeVolume
        return sound
    }()
    private static let removeVolume: Float = 0.5
    private static let removeStart: TimeInterval = 0.08
    private static let removeLength: TimeInterval = 0.17
    private static var removeStop: DispatchWorkItem?

    /// Aktion aus der Leiste gezogen: wie ein Symbol, das man aus dem Dock zieht
    private static let poofSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "dock/poof item off dock.aif"), byReference: false)

    /// Klang beim Ablegen in einen Ordner der Aktionsleiste (macOS: „Volume Mount“)
    private static let folderSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "system/Volume Mount.aif"), byReference: true)

    /// Nach dem Verschieben oder Kopieren in einen Ordner der Aktionsleiste
    static func folder() { play(folderSound) }

    /// In den Papierkorb gelegt. Wie der Finder nur, wenn unter Systemeinstellungen → Ton
    /// „Toneffekte der Benutzeroberfläche“ an ist (gilt für alle Klänge hier).
    static func trash() { play(trashSound) }

    /// Aus der Ablage entfernt (die Datei bleibt, wo sie ist)
    static func remove() {
        guard interfaceSoundsEnabled, let sound = removeSound else { return }
        removeStop?.cancel()
        if sound.isPlaying { sound.stop() }
        sound.currentTime = removeStart
        sound.play()
        let stop = DispatchWorkItem { sound.stop() }
        removeStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + removeLength, execute: stop)
    }

    /// Eine Aktion wurde aus der Leiste gezogen und entfernt
    static func poof() { play(poofSound) }

    private static func play(_ sound: NSSound?) {
        guard interfaceSoundsEnabled, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// „Töne“ in den Einstellungen von BarDrop und „Toneffekte der Benutzeroberfläche abspielen“
    /// von macOS (ohne Eintrag: an, wie bei macOS)
    static var interfaceSoundsEnabled: Bool {
        guard AppSettings.shared.soundsEnabled else { return false }
        let value = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled")
        return (value as? NSNumber)?.boolValue ?? true
    }
}
