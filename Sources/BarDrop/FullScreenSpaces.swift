import AppKit

/// Welche Bildschirme zeigen gerade einen Vollbild-Schreibtisch?
///
/// macOS legt für jede App im Vollbild einen eigenen Schreibtisch an. Ob der aktive
/// Schreibtisch eines Bildschirms so einer ist, verrät nur eine nicht öffentliche
/// Funktion des Fenstersystems (SkyLight), die auch Fenstermanager wie yabai nutzen.
/// Sie wird zur Laufzeit geladen; fehlt sie, gilt nichts als Vollbild und BarDrop
/// verhält sich wie ohne diese Einstellung.
enum FullScreenSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopyDisplaySpaces)? = {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            (handle.flatMap { dlsym($0, name) }) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        guard let main = symbol("CGSMainConnectionID"),
              let copy = symbol("CGSCopyManagedDisplaySpaces") else {
            Log.edge.info("Vollbild-Erkennung nicht verfügbar")
            return nil
        }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopyDisplaySpaces.self))
    }()

    /// Art „Vollbild“ eines Schreibtischs
    private static let fullScreenType = 4

    /// `all`: Bildschirme teilen sich die Schreibtische (Einstellung „Monitore verwenden
    /// verschiedene Spaces“ aus) und der gemeinsame ist im Vollbild. Sonst die UUIDs der
    /// Bildschirme im Vollbild. nil, wenn sich das nicht feststellen lässt.
    static func displays() -> (all: Bool, uuids: Set<String>)? {
        guard let (main, copy) = functions,
              let list = copy(main())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var all = false
        var uuids = Set<String>()
        for display in list {
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? Int) == fullScreenType else { continue }
            let id = display["Display Identifier"] as? String ?? ""
            if id == "Main" { all = true } else { uuids.insert(id.uppercased()) }
        }
        return (all, uuids)
    }

    /// UUID eines Bildschirms, wie sie das Fenstersystem verwendet
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }
}
