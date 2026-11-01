import Foundation
import UniformTypeIdentifiers

/// Was ein Plugin über ein Objekt der Ablage erfährt: Datei, Typ und, bei Links, die Adresse.
struct PluginItem: Equatable {
    enum Kind: String {
        case file, folder, link
    }

    let url: URL
    let kind: Kind
    /// Uniform Type Identifier der Datei
    let type: UTType?
    /// Adresse eines Links (.webloc in der Ablage)
    let link: URL?

    var fileExtension: String { url.pathExtension.lowercased() }

    init(url: URL, kind: Kind, type: UTType?, link: URL?) {
        self.url = url
        self.kind = kind
        self.type = type
        self.link = link
    }

    /// Beschreibt eine Datei der Ablage. Liest nur, was nötig ist (Typ aus der Endung,
    /// bei .webloc die Adresse), damit das auch beim Öffnen eines Menüs schnell geht.
    init(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if ext == "webloc", let link = Self.readWebloc(url) {
            kind = .link
            self.link = link
            type = UTType("com.apple.web-internet-location") ?? UTType(filenameExtension: ext)
            return
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let packaged = isDirectory.boolValue
            && ((try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
        if exists && isDirectory.boolValue && !packaged {
            kind = .folder
            type = .folder
        } else {
            kind = .file
            type = UTType(filenameExtension: ext)
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        }
        link = nil
    }

    static func readWebloc(_ url: URL) -> URL? {
        // Läuft beim Öffnen von Menüs auf dem Hauptthread: ein Link ist klein, Riesiges gar nicht lesen
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1 << 20,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String, let link = URL(string: string), link.scheme != nil else { return nil }
        return link
    }

    /// Fürs Skript: einfache Werte, kein Swift
    var scriptValue: [String: Any] {
        var value: [String: Any] = [
            "kind": kind.rawValue,
            "path": url.path,
            "name": kind == .link ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
            "extension": fileExtension,
            "type": type?.identifier ?? ""
        ]
        if let link { value["url"] = link.absoluteString }
        if kind != .folder, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { value["size"] = size }
        return value
    }
}

/// Entscheidet, ob ein Plugin für ein Objekt zuständig ist.
enum PluginMatcher {
    /// Passt die Adresse zu den Link-Regeln (ohne Typen und Endungen)?
    static func matchesLink(_ match: PluginMatch, _ link: URL) -> Bool {
        guard let rules = match.links else { return false }
        return matchesHost(link, rules.hosts ?? []) || matchesPattern(link, rules.patterns ?? [])
    }

    /// Passt die Adresse zu einer gezielten Link-Regel? Regeln, die jede Adresse annehmen
    /// (Domain „*“ oder ein Muster, das auf beliebige Seiten passt), zählen hier nicht: Sie
    /// sollen ein Bild aus dem Web nicht in einen Link verwandeln, nur weil es in einem Link steckt.
    static func specificallyMatchesLink(_ match: PluginMatch, _ link: URL) -> Bool {
        guard let rules = match.links else { return false }
        let hosts = (rules.hosts ?? []).filter { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) != "*" }
        let patterns = (rules.patterns ?? []).filter { !isCatchAll($0) }
        return matchesHost(link, hosts) || matchesPattern(link, patterns)
    }

    /// Passt das Muster auf beliebige Seiten (geprüft an Adressen, die kein Plugin gezielt meint)?
    static func isCatchAll(_ pattern: String) -> Bool {
        let probes = ["https://bardrop-probe.invalid/a/b?c=1", "http://x.invalid/"].compactMap(URL.init(string:))
        return probes.allSatisfy { matchesPattern($0, [pattern]) }
    }

    static func matches(_ match: PluginMatch, _ item: PluginItem) -> Bool {
        if item.kind == .link, let link = item.link, let rules = match.links {
            if matchesHost(link, rules.hosts ?? []) || matchesPattern(link, rules.patterns ?? []) { return true }
        }
        if let ext = match.extensions, !ext.isEmpty, !item.fileExtension.isEmpty,
           ext.contains(where: { normalized($0) == item.fileExtension }) {
            return true
        }
        if let types = match.types, !types.isEmpty, let type = item.type {
            for identifier in types {
                guard let wanted = UTType(identifier) else { continue }
                if type.conforms(to: wanted) { return true }
            }
        }
        return false
    }

    private static func normalized(_ ext: String) -> String {
        var e = ext.lowercased()
        while e.hasPrefix(".") { e.removeFirst() }
        return e
    }

    static func matchesHost(_ link: URL, _ hosts: [String]) -> Bool {
        guard let host = link.host?.lowercased() else { return false }
        for rule in hosts {
            var r = rule.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if r == "*" { return link.scheme == "http" || link.scheme == "https" }
            // „*.example.com“ meint dasselbe wie „example.com“ (Unterdomains passen ohnehin)
            if r.hasPrefix("*.") { r.removeFirst(2) }
            guard !r.isEmpty, !r.contains("*") else { continue }
            if host == r || host.hasSuffix("." + r) { return true }
        }
        return false
    }

    /// Reguläre Ausdrücke werden zwischengespeichert: Menüs fragen oft nach
    private static let lock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    static func matchesPattern(_ link: URL, _ patterns: [String]) -> Bool {
        let text = link.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            lock.lock()
            var regex = regexCache[pattern]
            if regex == nil {
                regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                if let regex { regexCache[pattern] = regex }
            }
            lock.unlock()
            if regex?.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }
}
