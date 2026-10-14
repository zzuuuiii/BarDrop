import SwiftUI
import AppKit

// MARK: Einstellungen im Stil von Klack
//
// Eigene Bausteine statt des Systemformulars, damit das Fenster auf jeder
// macOS-Version gleich aussieht: graue Fläche, darauf Karten mit Zeilen und
// feinen Trennlinien, kurze Überschriften, längliche Schalter, schlichte
// Auswahlmenüs mit ⌃⌄. Maße und Farben sind von Klack abgenommen.

enum SettingsTheme {
    /// Fenster und Seitenleiste
    static let window = dynamic(dark: (0.271, 0.282, 0.275), light: (0.925, 0.925, 0.925))
    /// Karten und gewählter Eintrag der Seitenleiste
    static let card = dynamic(dark: (0.318, 0.325, 0.325), light: (0.985, 0.985, 0.985))
    /// Rand der Karten
    static let cardBorder = dynamic(dark: (0.337, 0.345, 0.341), light: (0.86, 0.86, 0.86))
    /// Trennlinien zwischen Zeilen
    static let separator = dynamic(dark: (0.380, 0.388, 0.384), light: (0.89, 0.89, 0.89))
    /// Senkrechte Linie zwischen Seitenleiste und Inhalt
    static let divider = dynamic(dark: (0.337, 0.345, 0.341), light: (0.85, 0.85, 0.85))

    static let rowHeight: CGFloat = 45
    static let cardRadius: CGFloat = 11
    static let rowPadding: CGFloat = 12

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Eine Seite der Einstellungen: senkrecht scrollend, Abschnitte untereinander.
struct SettingsPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.leading, 20)
            .padding(.trailing, 18)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// Abschnitt: Überschrift (optional mit Info und Knöpfen), Karte, darunter ein Hinweis.
struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String?
    var info: String?
    var note: String?
    var noteColor: Color = .secondary
    let trailing: () -> Trailing
    let content: Content

    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.note = note
        self.noteColor = noteColor
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || info != nil {
                SettingsHeader(title ?? "", info: info, trailing: trailing)
                    .padding(.horizontal, 8)
            }
            SettingsCard { content }
            if let note, !note.isEmpty {
                SectionNote(note, color: noteColor)
                    .padding(.horizontal, 8)
            }
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder content: () -> Content) {
        self.init(title, info: info, note: note, noteColor: noteColor,
                  trailing: { EmptyView() }, content: content)
    }
}

/// Karte mit feinen Linien zwischen den Zeilen.
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .fill(SettingsTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    }
}

/// Setzt zwischen die Zeilen einer Karte je eine feine Linie.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(SettingsTheme.separator)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// Zeile: Bezeichnung links (optional mit Info), Bedienelement rechts.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    let control: Control

    init(_ title: String, subtitle: String? = nil, info: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let info { InfoButton(info) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

/// Zeile mit Schalter.
struct ToggleRow: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    init(_ title: String, info: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, info: info) {
            KlackSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
    }
}

/// Länglicher Schalter wie bei Klack: 48 × 24, Knopf als Kapsel.
struct KlackSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.13))
                Capsule()
                    .fill(isOn ? Color(red: 0.86, green: 0.91, blue: 0.99) : Color(white: 0.9))
                    .frame(width: 27, height: 18)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(.horizontal, 3)
            }
            .frame(width: 48, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "Ein" : "Aus")
    }
}

/// Zeile mit Auswahl: aktueller Wert und ⌃⌄, ein Klick öffnet das Menü.
struct PickerRow<Value: Hashable>: View {
    let title: String
    var info: String?
    @Binding var selection: Value
    let options: [(Value, String)]

    init(_ title: String, info: String? = nil, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self.info = info
        self._selection = selection
        self.options = options
    }

    var body: some View {
        SettingsRow(title, info: info) {
            PopupValue(selection: $selection, options: options)
        }
    }
}

/// Schlichtes Auswahlmenü ohne Rahmen: „Wert ⌃⌄“.
struct PopupValue<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var current: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 7) {
                Text(current)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -6)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }

    /// Systemmenü an der Stelle des Werts, der gewählte Eintrag mit Haken.
    private func showMenu() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let menu = NSMenu()
        var selectedItem: NSMenuItem?
        for (value, title) in options {
            let item = ClosureMenuItem(title) { selection = value }
            if value == selection {
                item.state = .on
                selectedItem = item
            }
            menu.addItem(item)
        }
        let point = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: selectedItem, at: point, in: view)
    }
}

/// Regler wie bei Klack: Titel und Wert in einer Zeile, darunter die Leiste.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0,
         format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13.5))
                Spacer()
                Text(format(value))
                    .font(.system(size: 13.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            KlackSlider(value: $value, range: range, step: step)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 11)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    static func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
}

/// Leiste mit blauem Anteil und weißem Knopf; rastet in Schritten ein.
struct KlackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    @Environment(\.isEnabled) private var isEnabled

    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knob)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = usable * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.13))
                    .frame(height: 4)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(height: knob)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(min(max((g.location.x - knob / 2) / usable, 0), 1))
                        set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: knob)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func set(_ raw: Double) {
        let v = step > 0 ? (raw / step).rounded() * step : raw
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// Grauer Knopf wie „Check Updates…“ bei Klack.
struct KlackButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        KlackButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct KlackButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Color(nsColor: .controlAccentColor)
                              : Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.15 : 0.11))
                )
                .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

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
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let info { InfoButton(info) }
            trailing()
        }
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
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(hovering ? 0.95 : 0.6))
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

/// Kleines rundes Symbol rechts in der Überschrift, z. B. „Standard wiederherstellen“.
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(disabled ? 0.3 : hovering ? 0.95 : 0.6))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Erklärtext unter einer Karte: immer linksbündig.
struct SectionNote: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
