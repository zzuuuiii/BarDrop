import AppKit
import SwiftUI

/// Rückfragen rund um Plugins, im Stil der übrigen Dialoge von BarDrop.
enum PluginDialogs {
    static func makeAlert(_ manifest: PluginManifest) -> NSAlert {
        let alert = NSAlert()
        if let image = PluginIconView.image(manifest.icon, size: 64) { alert.icon = image }
        return alert
    }

    /// Die Ablage bleibt offen, solange eine Frage steht
    @discardableResult
    static func run(_ alert: NSAlert, ui: ShelfUIModel?) -> NSApplication.ModalResponse {
        ui?.menuOpen = true
        // Die Einstellungen bleiben dabei, wo sie waren (Frage kam aus der Ablage)
        AppActivation.activateKeepingWindows()
        let answer = alert.runModal()
        ui?.menuOpen = false
        return answer
    }

    /// Alles, was ein Plugin noch braucht, in **einem** kurzen Fenster: Zustimmung zum
    /// Hinweis, Rechte und Programme. Das einzige Erlauben-Fenster: vor dem ersten Lauf
    /// (von Hand oder automatisch), beim Einschalten, bei „Automatisch beim Ablegen“ und
    /// „Erlauben“ in den Einstellungen. Danach fragt niemand mehr, auch nicht mitten im Lauf.
    static func authorize(_ plugin: InstalledPlugin, manager: PluginManager, ui: ShelfUIModel?) -> Bool {
        let name = plugin.manifest.name.text
        let consent = manager.hasConsented(plugin) ? nil : plugin.manifest.consent
        let permissions = plugin.manifest.allPermissions.filter { !manager.isGranted($0, for: plugin) }
        let tools = (plugin.manifest.tools ?? []).filter { !manager.state(plugin.id).approvedTools.contains($0.approvalKey) }
        guard consent != nil || !permissions.isEmpty || !tools.isEmpty else { return true }

        let alert = makeAlert(plugin.manifest)
        let onlyConsent = permissions.isEmpty && tools.isEmpty
        alert.messageText = onlyConsent ? L("Use “\(name)”?", "„\(name)“ verwenden?")
                                        : L("Allow “\(name)”?", "„\(name)“ erlauben?")
        var text: [String] = []
        if let consent { text.append(consent.text) }
        if !onlyConsent { text.append(L("Only allow plugins you trust.", "Erlaub nur Plugins, denen du vertraust.")) }
        alert.informativeText = text.joined(separator: "\n\n")
        alert.accessoryView = grantList(PluginGrant.rows(permissions: permissions, tools: tools))
        alert.addButton(withTitle: onlyConsent ? L("Agree", "Zustimmen") : L("Allow", "Erlauben"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard run(alert, ui: ui) == .alertFirstButtonReturn else { return false }

        manager.grantAll(plugin)
        return true
    }

    /// Einschalten von „Automatisch beim Ablegen“ und „Erlauben“ in den Einstellungen
    static func prepareAutomatic(_ plugin: InstalledPlugin, manager: PluginManager) -> Bool {
        authorize(plugin, manager: manager, ui: nil)
    }

    /// Kurze Liste unter der Frage: je Zeile ein Symbol und ein paar Worte
    static func grantList(_ rows: [PluginGrant]) -> NSView? {
        guard !rows.isEmpty else { return nil }
        let view = NSHostingView(rootView: GrantList(rows: rows))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        return view
    }
}

/// Eine Zeile in den Fenstern der Plugins: was das Plugin darf, lädt oder mitbringt
struct PluginGrant: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String

    static func rows(permissions: [PluginPermission], tools: [PluginTool], otherFiles: [String] = []) -> [PluginGrant] {
        var rows = permissions.map { PluginGrant(symbol: $0.symbol, text: $0.summary) }
        for tool in tools {
            let host = URL(string: tool.resolvedURL)?.host ?? tool.resolvedURL
            var text = L("Downloads “\(tool.name)” from \(host)", "Lädt „\(tool.name)“ von \(host)")
            if let license = tool.license { text += " · " + license }
            rows.append(PluginGrant(symbol: "arrow.down.circle", text: text))
        }
        if !otherFiles.isEmpty {
            var text = L("Also contains ", "Enthält außerdem ") + otherFiles.prefix(4).joined(separator: ", ")
            if otherFiles.count > 4 {
                let more = otherFiles.count - 4
                text += " " + L("and \(more) more", "und \(more) weitere")
            }
            rows.append(PluginGrant(symbol: "doc.on.doc", text: text))
        }
        return rows
    }
}

private struct GrantList: View {
    let rows: [PluginGrant]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.symbol)
                        .frame(width: 16)
                    Text(row.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: Import

/// Import einer .bdrop-Datei: prüfen, kurz zeigen, was das Plugin darf, und erst nach
/// Bestätigung installieren. Ein Doppelklick installiert also nie still. Das Skript gibt
/// es auf Wunsch („Skript ansehen“).
enum PluginImporter {
    /// Liefert das installierte Plugin, nil bei Abbruch oder Fehler (dann mit Meldung)
    @discardableResult
    static func importFile(_ url: URL, parent: NSWindow?, manager: PluginManager = .shared) -> InstalledPlugin? {
        let unpacked: PluginPackage.Unpacked
        do {
            unpacked = try manager.inspect(url)
        } catch let error as PluginManager.InstallError {
            showFailure(error.message, file: url)
            return nil
        } catch {
            showFailure(error.localizedDescription, file: url)
            return nil
        }
        let manifest = unpacked.manifest
        if manager.plugin(manifest.id)?.isStandard == true {
            try? FileManager.default.removeItem(at: unpacked.directory)
            showFailure(PluginManager.InstallError.standardExists.message, file: url)
            return nil
        }
        let existing = manager.plugin(manifest.id)
        // Zu lange Beschreibung: nur neue Plugins und Versionen ablehnen, dieselbe Version
        // noch einmal zu installieren geht weiter
        if let length = manifest.tooLongDescription, existing?.manifest.version != manifest.version {
            try? FileManager.default.removeItem(at: unpacked.directory)
            showFailure(L("The plugin’s description is \(length) characters long. At most \(PluginManifest.maxDescriptionLength) are allowed.",
                          "Die Beschreibung des Plugins ist \(length) Zeichen lang. Erlaubt sind höchstens \(PluginManifest.maxDescriptionLength)."),
                        file: url)
            return nil
        }
        let name = manifest.name.text
        var accepted = false
        while true {
            let alert = PluginDialogs.makeAlert(manifest)
            alert.messageText = existing == nil ? L("Install “\(name)”?", "„\(name)“ installieren?")
                                                : L("Update “\(name)”?", "„\(name)“ aktualisieren?")
            var lines: [String] = []
            if let existing {
                lines.append(L("Version \(existing.manifest.version) → \(manifest.version)",
                               "Version \(existing.manifest.version) → \(manifest.version)"))
            }
            if let description = manifest.description?.text, !description.isEmpty { lines.append(description) }
            // Hinweis des Plugins steht gleich hier: „Installieren“ gilt als Zustimmung
            if let consent = manifest.consent?.text, !consent.isEmpty { lines.append(consent) }
            lines.append(L("This plugin isn’t from the BarDrop catalog. Only install plugins from developers you trust.",
                           "Dieses Plugin stammt nicht aus dem BarDrop-Katalog. Installier nur Plugins von Entwicklern, denen du vertraust."))
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.accessoryView = PluginDialogs.grantList(PluginGrant.rows(
                permissions: manifest.allPermissions, tools: manifest.tools ?? [], otherFiles: otherFiles(in: unpacked)))
            alert.addButton(withTitle: existing == nil ? L("Install", "Installieren") : L("Update", "Aktualisieren"))
            alert.addButton(withTitle: L("Cancel", "Abbrechen"))
            alert.addButton(withTitle: L("View Script", "Skript ansehen"))
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            if answer == .alertThirdButtonReturn {
                showScript(unpacked.script, manifest: manifest)
                continue
            }
            accepted = answer == .alertFirstButtonReturn
            break
        }
        guard accepted else {
            try? FileManager.default.removeItem(at: unpacked.directory)
            return nil
        }
        do {
            let installed = try manager.install(unpacked, standard: false)
            // Rechte und Programme standen in der Liste: Wer „Installieren“ klickt, erlaubt sie.
            // Kein zweites Fenster beim ersten Lauf.
            manager.grantAll(installed)
            // Von Hand importiert: Updates kommen nicht mehr aus der Galerie
            manager.update(installed.id) { $0.fromCatalog = false }
            // Neu installiert: gleich an, mit den Voreinstellungen des Plugins
            if existing == nil { manager.activateWithDefaults(installed) }
            // Plugins einschalten, sonst wäre das neue Plugin nirgends zu sehen
            if !AppSettings.shared.pluginsEnabled { AppSettings.shared.pluginsEnabled = true }
            return installed
        } catch let error as PluginManager.InstallError {
            showFailure(error.message, file: url)
        } catch {
            showFailure(error.localizedDescription, file: url)
        }
        return nil
    }

    /// Das Skript vor dem Installieren lesen, danach zurück zur Frage
    private static func showScript(_ script: String, manifest: PluginManifest) {
        let alert = PluginDialogs.makeAlert(manifest)
        alert.messageText = manifest.name.text + " · " + manifest.script
        let view = NSHostingView(rootView: ScriptText(script: script, fontSize: 11)
            .frame(width: 460, height: 320)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.85)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .environment(\.colorScheme, .dark))
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 320)
        alert.accessoryView = view
        alert.addButton(withTitle: L("Back", "Zurück"))
        alert.runModal()
    }

    /// Dateien im Plugin außer manifest.json und dem Skript (das Skript kann sie lesen und
    /// als Code ausführen, darum zeigt der Dialog sie an)
    static func otherFiles(in unpacked: PluginPackage.Unpacked) -> [String] {
        let base = unpacked.directory.standardizedFileURL.path
        let known: Set<String> = ["manifest.json", unpacked.manifest.script]
        let walker = FileManager.default.enumerator(at: unpacked.directory, includingPropertiesForKeys: [.isRegularFileKey])
        var names: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if !known.contains(relative) && url.lastPathComponent != ".DS_Store" { names.append(relative) }
        }
        return names.sorted()
    }

    /// Dateiauswahl für „Plugin importieren“
    static func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [PluginPackage.contentType]
        panel.prompt = L("Install", "Installieren")
        panel.message = L("Choose a BarDrop plugin (.bdrop).", "Wähl ein BarDrop-Plugin (.bdrop).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, parent: nil)
    }

    private static func showFailure(_ message: String, file: URL) {
        let alert = NSAlert()
        alert.messageText = L("“\(file.lastPathComponent)” can’t be installed", "„\(file.lastPathComponent)“ lässt sich nicht installieren")
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Schreibgeschützte Ansicht eines Skripts in einer festen Schrift, mit einfachen
/// Syntaxfarben (Schlüsselwörter, Texte, Zahlen, Kommentare)
struct ScriptText: View {
    let script: String
    var fontSize: CGFloat = 12

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(ScriptHighlighter.highlight(script, size: fontSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }
}

enum ScriptHighlighter {
    private static let keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                                   "do", "else", "export", "false", "finally", "for", "function", "if", "import", "in",
                                   "let", "new", "null", "of", "return", "switch", "this", "throw", "true", "try",
                                   "typeof", "undefined", "var", "while"]

    /// Höchstens so viele Zeichen einfärben: sehr lange Skripte bleiben flüssig
    private static let limit = 200_000

    static func highlight(_ script: String, size: CGFloat) -> AttributedString {
        var text = AttributedString(script)
        text.font = .system(size: size, design: .monospaced)
        text.foregroundColor = Color(white: 0.88)
        guard script.count <= limit else { return text }
        func paint(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let ns = script as NSString
            for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: script),
                      let lower = AttributedString.Index(range.lowerBound, within: text),
                      let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                text[lower..<upper].foregroundColor = color
            }
        }
        paint(#"\b\d+(\.\d+)?\b"#, Color(red: 0.82, green: 0.75, blue: 0.5))
        paint(#"\b(" + keywords.joined(separator: "|") + #")\b"#, Color(red: 0.99, green: 0.37, blue: 0.64))
        paint(#"\bbardrop\b"#, Color(red: 0.4, green: 0.8, blue: 0.95))
        paint(#"(["'`])(?:\\.|(?!\1).)*\1"#, Color(red: 0.99, green: 0.42, blue: 0.36))
        paint(#"//[^\n]*|/\*[\s\S]*?\*/"#, Color(white: 0.5))
        return text
    }
}
