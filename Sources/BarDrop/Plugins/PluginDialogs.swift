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
        alert.accessoryView = grantList(PluginGrant.rows(permissions: permissions, tools: tools), in: alert)
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

    /// Kurze Liste unter der Frage: je Zeile ein Symbol und ein paar Worte. Mehrere Programme
    /// stehen eingeklappt in einer Zeile; aufgeklappt wächst das Fenster mit
    static func grantList(_ rows: [PluginGrant], in alert: NSAlert) -> NSView? {
        guard !rows.isEmpty else { return nil }
        let host = GrantHost()
        let view = NSHostingView(rootView: GrantList(rows: rows, resized: { [weak host] in host?.resize() }))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        host.view = view
        host.alert = alert
        return view
    }
}

/// Passt das Fenster an, wenn die Liste auf- oder zuklappt (NSAlert ordnet sich dann neu an)
private final class GrantHost {
    weak var view: NSView?
    weak var alert: NSAlert?

    func resize() {
        guard let view, let alert else { return }
        let size = view.fittingSize
        guard abs(size.height - view.frame.height) > 0.5 else { return }
        view.setFrameSize(NSSize(width: view.frame.width, height: size.height))
        alert.layout()
    }
}

/// Eine Zeile in den Fenstern der Plugins: was das Plugin darf, lädt oder mitbringt
struct PluginGrant: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
    /// Ein Programm, das das Plugin lädt (stehen eingeklappt in einer Zeile)
    var isProgram = false

    static func rows(permissions: [PluginPermission], tools: [PluginTool], otherFiles: [String] = []) -> [PluginGrant] {
        var rows = permissions.map { PluginGrant(symbol: $0.symbol, text: $0.summary) }
        for tool in tools {
            let host = URL(string: tool.resolvedURL)?.host ?? tool.resolvedURL
            var text = L("Downloads “\(tool.name)” from \(host)", "Lädt „\(tool.name)“ von \(host)")
            if let license = tool.license { text += " · " + license }
            rows.append(PluginGrant(symbol: "arrow.down.circle", text: text, isProgram: true))
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
    var resized: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        let programs = rows.filter(\.isProgram)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.filter { !$0.isProgram }) { row in
                line(symbol: row.symbol, text: row.text)
            }
            if programs.count == 1, let only = programs.first {
                line(symbol: only.symbol, text: only.text)
            } else if programs.count > 1 {
                // Mehrere Programme: eine Zeile, die Liste erst auf Klick (Nutzer, 01.11.2026)
                Button {
                    expanded.toggle()
                    DispatchQueue.main.async(execute: resized)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 16)
                        Text(L("Downloads \(programs.count) programs", "Lädt \(programs.count) Programme"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityValue(expanded ? L("Expanded", "Aufgeklappt") : L("Collapsed", "Zugeklappt"))
                if expanded {
                    ForEach(programs) { row in
                        Text(row.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                    }
                }
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func line(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

// MARK: Import

/// Import einer .bdrop-Datei: prüfen, kurz zeigen, was das Plugin darf, und erst nach
/// Bestätigung installieren. Ein Doppelklick installiert also nie still. Danach folgt ein
/// Warnhinweis, weil das Plugin nicht aus der Galerie kommt.
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
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.accessoryView = PluginDialogs.grantList(PluginGrant.rows(
            permissions: manifest.allPermissions, tools: manifest.tools ?? [], otherFiles: otherFiles(in: unpacked)), in: alert)
        alert.addButton(withTitle: existing == nil ? L("Install", "Installieren") : L("Update", "Aktualisieren"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        NSApp.activate(ignoringOtherApps: true)
        let accepted = alert.runModal() == .alertFirstButtonReturn && confirmUnknownSource(manifest)
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

    /// Zweite Frage nach „Installieren“: Das Plugin kommt nicht aus der Galerie (Nutzer,
    /// 01.11.2026). „Abbrechen“ ist die Vorgabe, Return installiert also nicht aus Versehen.
    private static func confirmUnknownSource(_ manifest: PluginManifest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("This plugin isn’t from the BarDrop gallery", "Dieses Plugin stammt nicht aus der BarDrop-Galerie")
        alert.informativeText = L("Plugins can run programs and read the files you give them. One from an unknown source could harm your Mac. Only continue if you trust where “\(manifest.name.text)” comes from.",
                                  "Plugins können Programme ausführen und die Dateien lesen, die du ihnen gibst. Eins aus unbekannter Quelle könnte deinem Mac schaden. Fahr nur fort, wenn du der Herkunft von „\(manifest.name.text)“ vertraust.")
        let cancel = alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        let install = alert.addButton(withTitle: L("Install Anyway", "Trotzdem installieren"))
        cancel.keyEquivalent = "\r"
        install.keyEquivalent = ""
        install.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
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
