import Foundation

/// Schreibt Dateien, die BarDrop speichert, als frische Dateien.
///
/// Browser (vor allem Safari) und andere Apps hinterlassen an ihren Dateien
/// Zusatz-Metadaten, Zugriffslisten und Datei-Flags (z. B. `com.apple.macl`,
/// `com.apple.provenance`). Einige davon sind vom System geschützt und lassen sich
/// nicht entfernen. Eine frisch geschriebene Datei enthält nur die Daten selbst.
/// Die Quarantäne-Markierung bleibt erhalten, damit der Schutz vor heruntergeladener
/// Software bestehen bleibt.
///
/// Kopiert wird blockweise über `copyfile` (nur die Daten), nicht über den
/// Arbeitsspeicher. Große Dateien belegen dadurch keinen zusätzlichen Speicher.
enum FileSanitizer {
    static let quarantine = "com.apple.quarantine"

    /// Kopiert nur die Daten von `source` nach `target` (neu angelegt, 0644) und
    /// übernimmt höchstens die Quarantäne-Markierung.
    @discardableResult
    static func cleanCopy(from source: URL, to target: URL) -> Bool {
        let quarantineValue = readAttribute(quarantine, of: source)
        let result = source.withUnsafeFileSystemRepresentation { src in
            target.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL))
            }
        }
        guard result == 0 else {
            // Gab es das Ziel schon (EXCL), ist es nicht unsere halbe Kopie, sondern eine fremde
            // Datei: stehen lassen (DragExport ruft das nach „Datei existiert“ auf)
            if errno != EEXIST { try? FileManager.default.removeItem(at: target) }
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        if let quarantineValue { writeAttribute(quarantine, value: quarantineValue, to: target) }
        return true
    }

    /// Schreibt eine Datei an derselben Stelle frisch neu.
    /// Gibt die (gleiche) Adresse zurück; bei Fehlern bleibt die Datei unverändert.
    @discardableResult
    static func recreate(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return url
        }
        let fresh = url.deletingLastPathComponent().appendingPathComponent(".bardrop-\(UUID().uuidString)")
        guard cleanCopy(from: url, to: fresh) else { return url }
        // In einem Schritt ersetzen (rename ist atomar): Vorher wurde erst das Original gelöscht
        // und dann die Kopie verschoben; schlug das fehl, löschte die Fehlerbehandlung auch die
        // Kopie, und die Datei war ganz weg
        let replaced = fresh.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst in rename(src, dst) }
        }
        if replaced != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: fresh)
            Log.importing.error("Neu schreiben fehlgeschlagen: \(String(cString: strerror(code)), privacy: .public)")
        }
        return url
    }

    /// Namen aller Zusatz-Metadaten einer Datei (für Tests und Fehlersuche).
    static func attributeNames(of url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
        return buffer.split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    static func readAttribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }

    static func writeAttribute(_ name: String, value: Data, to url: URL) {
        _ = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    }
}
