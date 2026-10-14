import SwiftUI
import AppKit

// MARK: Bausteine im Stil von Klack
//
// Kurze Überschriften über den Karten, Erklärungen hinter einem kleinen
// Info-Symbol statt langer Texte unter jedem Abschnitt.

/// Überschrift eines Abschnitts: Titel links, rechts optional Info und weitere Knöpfe.
struct SettingsHeader<Trailing: View>: View {
    let title: String
    var info: String?
    let trailing: () -> Trailing

    init(_ title: String, info: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.info = info
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let info { InfoButton(info) }
            trailing()
        }
        .textCase(nil)
    }
}

extension SettingsHeader where Trailing == EmptyView {
    init(_ title: String, info: String? = nil) {
        self.init(title, info: info) { EmptyView() }
    }
}

/// Kleines rundes Info-Symbol; ein Klick zeigt die Erklärung.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    @State private var hovering = false

    init(_ text: String) { self.text = text }

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
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel("Info")
    }
}

/// Kleiner Knopf mit Symbol in der Überschrift, z. B. „Standard wiederherstellen“.
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(disabled ? 0.3 : hovering ? 0.95 : 0.6))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering && !disabled ? 0.1 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Zeile mit Schalter, deren Bezeichnung ein Info-Symbol trägt (wie bei Klack).
struct InfoToggle: View {
    let title: String
    let info: String
    @Binding var isOn: Bool

    init(_ title: String, info: String, isOn: Binding<Bool>) {
        self.title = title
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                InfoButton(info)
            }
        }
    }
}

/// Einheitlicher, durchscheinender Hintergrund für das ganze Fenster:
/// Seitenleiste und Inhalt im selben Grau, wie bei Klack.
struct SettingsWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
