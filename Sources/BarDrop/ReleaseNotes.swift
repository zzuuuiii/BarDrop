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
        let notes: [String]
        let page: URL?
        var id: String { version }
    }

    enum State: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state: State = .idle

    private let url = URL(string: "https://api.github.com/repos/zzuuuiii/BarDrop/releases?per_page=8")!
    static let allReleases = URL(string: "https://github.com/zzuuuiii/BarDrop/releases")!

    func loadIfNeeded() {
        guard state == .idle || state == .failed else { return }
        state = .loading
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let parsed = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                if let parsed, !parsed.isEmpty {
                    self.entries = parsed
                    self.state = .loaded
                } else {
                    self.state = .failed
                }
            }
        }.resume()
    }

    static func parse(_ data: Data) -> [Entry]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        return list.compactMap { json in
            guard (json["draft"] as? Bool) != true,
                  let tag = json["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let date = (json["published_at"] as? String).flatMap { iso.date(from: $0) }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            return Entry(version: version, date: date,
                         notes: cleanNotes(json["body"] as? String ?? ""), page: page)
        }
    }

    /// Nur die Aufzählung der Änderungen: ohne Überschrift, Installationshinweis
    /// und Notizblöcke, die in jedem Release gleich sind.
    static func cleanNotes(_ body: String) -> [String] {
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix(">")
                    && !line.hasPrefix("**Installation")
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
        .help("Was ist neu")
        .accessibilityLabel("Was ist neu")
        .onAppear { notes.loadIfNeeded() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ReleaseNotesList(notes: notes)
                .onAppear { notes.loadIfNeeded() }
        }
    }
}

private struct ReleaseNotesList: View {
    @ObservedObject var notes: ReleaseNotes

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Was ist neu")
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
                    Text("Keine Verbindung zu GitHub.")
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
                Link("Alle Versionen auf GitHub", destination: ReleaseNotes.allReleases)
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
                Text("Version \(entry.version)")
                    .font(.system(size: 13, weight: .semibold))
                if entry.version == Updater.shared.currentVersion {
                    Text("installiert")
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
            ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, line in
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
