import SwiftUI
import AppKit

/// Änderungen der letzten Versionen, direkt aus den GitHub-Releases dieses Repositorys.
/// Wird erst geladen, wenn jemand „Über BarDrop“ öffnet, und nur einmal pro Start
/// (nach einem Fehler beim nächsten Öffnen erneut).
final class ReleaseNotes: ObservableObject {
    static let shared = ReleaseNotes()

    struct Entry: Identifiable, Equatable {
        let version: String
        let date: Date?
        let notesEnglish: [String]?
        let notesGerman: [String]?
        let page: URL?
        var id: String { version }

        /// Notizen in der gewählten Sprache, sonst in der anderen
        var lines: [String] {
            AppSettings.shared.language == .german ? (notesGerman ?? notesEnglish ?? [])
                                                    : (notesEnglish ?? notesGerman ?? [])
        }
    }

    enum State: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state: State = .idle

    private let url = URL(string: "https://api.github.com/repos/zzuuuiii/BarDrop/releases?per_page=8")!
    /// Englisches Änderungsprotokoll: für ältere Releases, deren Notizen nur auf Deutsch sind
    private let changelogURL = URL(string: "https://raw.githubusercontent.com/zzuuuiii/BarDrop/main/CHANGELOG.md")!
    static let allReleases = URL(string: "https://github.com/zzuuuiii/BarDrop/releases")!

    func loadIfNeeded() {
        guard state == .idle || state == .failed else { return }
        state = .loading
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        var releases: Data?
        var changelog: Data?
        let group = DispatchGroup()
        group.enter()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            releases = data
            group.leave()
        }.resume()
        group.enter()
        URLSession.shared.dataTask(with: URLRequest(url: changelogURL, timeoutInterval: 20)) { data, _, _ in
            changelog = data
            group.leave()
        }.resume()
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let english = changelog.flatMap { String(data: $0, encoding: .utf8) }.map(Self.parseChangelog) ?? [:]
            if let parsed = releases.flatMap({ Self.parse($0, englishFallback: english) }), !parsed.isEmpty {
                self.entries = parsed
                self.state = .loaded
            } else {
                self.state = .failed
            }
        }
    }

    /// Abschnitte „## 1.2.3“ im Änderungsprotokoll, je Version die Aufzählungspunkte
    static func parseChangelog(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if let version = current, line.hasPrefix("* ") || line.hasPrefix("- ") {
                result[version, default: []].append(String(line.dropFirst(2)))
            }
        }
        return result
    }

    static func parse(_ data: Data, englishFallback: [String: [String]] = [:]) -> [Entry]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        return list.compactMap { json in
            guard (json["draft"] as? Bool) != true,
                  let tag = json["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let date = (json["published_at"] as? String).flatMap { iso.date(from: $0) }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            let body = json["body"] as? String ?? ""
            // Zweisprachige Releases (ab 1.16): Englisch oben, Deutsch nach der Marke <!-- de -->.
            // Ältere Releases sind nur deutsch; Englisch kommt dann aus dem Änderungsprotokoll.
            let parts = body.components(separatedBy: germanMarker)
            if parts.count > 1 {
                return Entry(version: version, date: date, notesEnglish: cleanNotes(parts[0]),
                             notesGerman: cleanNotes(parts[1]), page: page)
            }
            return Entry(version: version, date: date, notesEnglish: englishFallback[version],
                         notesGerman: cleanNotes(body), page: page)
        }
    }

    /// Trennt in den Release-Notizen die englische von der deutschen Fassung
    static let germanMarker = "<!-- de -->"

    /// Nur die Aufzählung der Änderungen: ohne Überschrift, Installationshinweis
    /// und Notizblöcke, die in jedem Release gleich sind.
    static func cleanNotes(_ body: String) -> [String] {
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix(">") && !line.hasPrefix("<!--")
                    && !line.hasPrefix("**Installation") && !line.hasPrefix("**Install")
            }
            .map { line in
                for marker in ["* ", "- "] where line.hasPrefix(marker) {
                    return String(line.dropFirst(marker.count))
                }
                return line
            }
    }
}

/// Info-Symbol neben der Version: ein Klick zeigt, was sich in den letzten Versionen geändert hat.
struct ReleaseNotesButton: View {
    @ObservedObject private var notes = ReleaseNotes.shared
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary.opacity(hovering ? 0.9 : 0.55))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("What’s new", "Was ist neu"))
        .accessibilityLabel(L("What’s new", "Was ist neu"))
        .onAppear { notes.loadIfNeeded() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ReleaseNotesList(notes: notes)
                .onAppear { notes.loadIfNeeded() }
        }
    }
}

private struct ReleaseNotesList: View {
    @ObservedObject var notes: ReleaseNotes

    private static var dateFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = AppSettings.shared.language.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("What’s new", "Was ist neu"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            Group {
                switch notes.state {
                case .loaded:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(notes.entries) { entry in
                                entryView(entry)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .failed:
                    Text(L("Couldn’t reach GitHub.", "Keine Verbindung zu GitHub."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)

            Divider()

            HStack {
                Spacer()
                Link(L("All versions on GitHub", "Alle Versionen auf GitHub"), destination: ReleaseNotes.allReleases)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 340)
    }

    private func entryView(_ entry: ReleaseNotes.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Version \(entry.version)", "Version \(entry.version)"))
                    .font(.system(size: 13, weight: .semibold))
                if entry.version == Updater.shared.currentVersion {
                    Text(L("installed", "installiert"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                if let date = entry.date {
                    Text(Self.dateFormat.string(from: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(Self.markdown(line))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Fett und Code aus den Release-Notizen darstellen, Rest als Text.
    private static func markdown(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}
