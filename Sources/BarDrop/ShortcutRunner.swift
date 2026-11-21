import Foundation

/// Kurzbefehle aus der App Kurzbefehle über das mitgelieferte Programm `shortcuts`:
/// auflisten und mit Dateien ausführen. Was ein Kurzbefehl zurückgibt, landet in einem
/// eigenen Ordner und von dort in der Ablage.
enum ShortcutRunner {
    enum Outcome {
        /// Fertig; `results` sind zurückgegebene Dateien (können fehlen), `folder` ihr Ordner
        case done(results: [URL], folder: URL?)
        case failed
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Namen aller Kurzbefehle (leer, wenn es keine gibt oder das Programm fehlt)
    static func list() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return [] }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // Läuft beim Öffnen des Menüs auf dem Hauptthread: Hängt der Dienst der Kurzbefehle,
        // nach 2 s abbrechen (ohne Kurzbefehle), statt die Einstellungen einzufrieren
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Kurzbefehl im Hintergrund ausführen; `completion` auf dem Hauptthread
    static func run(_ name: String, inputs: [URL], completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = runNow(name, inputs: inputs)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func runNow(_ name: String, inputs: [URL]) -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { return .failed }
        let folder = fm.temporaryDirectory.appendingPathComponent("BarDropKurzbefehl-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return .failed }
        let output = folder.appendingPathComponent("Ergebnis")
        let process = Process()
        process.executableURL = tool
        var arguments = ["run", name]
        for url in inputs { arguments += ["--input-path", url.path] }
        arguments += ["--output-path", output.path]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch {
            try? fm.removeItem(at: folder)
            return .failed
        }
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Diagnostics.shared.record("shortcut", "fehlgeschlagen status=\(process.terminationStatus)")
            try? fm.removeItem(at: folder)
            return .failed
        }
        // Ergebnis: eine Datei, ein Ordner mit Dateien oder nichts
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: output.path, isDirectory: &isDir) else {
            try? fm.removeItem(at: folder)
            return .done(results: [], folder: nil)
        }
        let results: [URL]
        if isDir.boolValue {
            results = (try? fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        } else {
            results = [named(output)]
        }
        Diagnostics.shared.record("shortcut", "fertig ergebnisse=\(results.count)")
        return .done(results: results, folder: folder)
    }

    /// Text, wenn der Anfang gültiges UTF-8 ist. Nur den Anfang lesen: Große Ergebnisse
    /// (Videos, Audio) kamen sonst ganz in den Speicher
    private static func isText(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let limit = 64 * 1024
        let head = handle.readData(ofLength: limit + 1)
        guard !head.isEmpty, !head.contains(0) else { return false }
        if head.count <= limit { return String(data: head, encoding: .utf8) != nil }
        // Abgeschnitten: Ein Zeichen kann am Ende geteilt sein (höchstens 3 Bytes)
        let cut = head.prefix(limit)
        return (0...3).contains { String(data: cut.dropLast($0), encoding: .utf8) != nil }
    }

    /// Eine einzelne zurückgegebene Datei kommt ohne Endung: nach ihrem Inhalt benennen
    private static func named(_ file: URL) -> URL {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return file }
        let head = [UInt8](handle.readData(ofLength: 16))
        try? handle.close()
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        let ext: String
        if starts([0x89, 0x50, 0x4E, 0x47]) { ext = "png" }
        else if starts([0xFF, 0xD8, 0xFF]) { ext = "jpg" }
        else if starts([0x47, 0x49, 0x46, 0x38]) { ext = "gif" }
        else if starts([0x25, 0x50, 0x44, 0x46]) { ext = "pdf" }
        else if starts([0x50, 0x4B, 0x03, 0x04]) { ext = "zip" }
        else if starts(Array("ftyphei".utf8), at: 4) || starts(Array("ftypmif1".utf8), at: 4) { ext = "heic" }
        else if starts(Array("ftyp".utf8), at: 4) { ext = "mp4" }
        else if isText(file) { ext = "txt" }
        else { return file }
        let target = file.deletingLastPathComponent()
            .appendingPathComponent(L("Shortcut Result", "Kurzbefehl-Ergebnis")).appendingPathExtension(ext)
        return (try? FileManager.default.moveItem(at: file, to: target)) != nil ? target : file
    }
}
