import AppKit
import SwiftUI

/// Auswahlliste der Einstellungen im selben Stil wie die Karten: dunkle, leicht
/// durchscheinende Fläche, feiner Rand, Zeilen mit sanfter Hervorhebung beim
/// Darüberfahren und einem Haken vor der gewählten Möglichkeit. Ersetzt die
/// Systemmenüs, die in den Einstellungen wie ein Fremdkörper wirkten.
///
/// Gefüllt wird sie aus einem gewöhnlichen `NSMenu` (Titel, Haken, ausgegraute
/// Einträge, Trennlinien, Symbole), damit die Aufrufer unverändert bleiben.
final class ChoicePopup: NSPanel {
    private static var current: ChoicePopup?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    enum Alignment { case leading, trailing }

    /// Zeigt die Einträge von `menu` unter `frame` (SwiftUI-Koordinaten im Fenster)
    static func present(_ menu: NSMenu, anchor frame: CGRect, align: Alignment) {
        current?.dismiss()
        guard let parent = NSApp.keyWindow ?? NSApp.currentEvent?.window,
              let content = parent.contentView else { return }

        let rows = menu.items.map(ChoiceRow.init)
        let popup = ChoicePopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = .popUpMenu
        let host = NSHostingView(rootView: ChoiceList(rows: rows, minWidth: max(frame.width, 160)) { [weak popup] row in
            popup?.dismiss()
            row.perform()
        })
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        popup.contentView = host

        // SwiftUI misst von oben links im Fenster, das Fenster von unten links
        let topLeft = NSPoint(x: frame.minX, y: content.bounds.height - frame.maxY)
        let anchorBelow = parent.convertPoint(toScreen: topLeft)
        let anchorTop = parent.convertPoint(toScreen: NSPoint(x: frame.minX, y: content.bounds.height - frame.minY))
        var x = align == .leading ? anchorBelow.x : anchorBelow.x + frame.width - size.width
        var y = anchorBelow.y - 6 - size.height
        if let screen = parent.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            // Unten zu wenig Platz: nach oben aufklappen
            if y < area.minY + 8 { y = anchorTop.y + 6 }
            x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        }
        popup.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        parent.addChildWindow(popup, ordered: .above)
        popup.orderFront(nil)
        popup.watch(parent)
        current = popup
    }

    /// Schließt bei Klick daneben, Escape und wenn das Fenster in den Hintergrund geht
    private func watch(_ parent: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss(); return nil }
                return event
            }
            if event.window !== self {
                self.dismiss()
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: parent, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    override var canBecomeKey: Bool { false }
}

/// Ein Eintrag der Liste, aus einem Menüeintrag übernommen
struct ChoiceRow: Identifiable {
    let id = UUID()
    let title: String
    let checked: Bool
    let enabled: Bool
    let separator: Bool
    let image: NSImage?
    private weak var item: NSMenuItem?

    init(_ item: NSMenuItem) {
        self.item = item
        title = item.title
        checked = item.state == .on
        separator = item.isSeparatorItem
        enabled = !item.isSeparatorItem && item.action != nil && item.isEnabled
        image = item.image
    }

    func perform() {
        guard let item, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

private struct ChoiceList: View {
    let rows: [ChoiceRow]
    let minWidth: CGFloat
    let choose: (ChoiceRow) -> Void

    private var hasChecks: Bool { rows.contains(where: \.checked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                if row.separator {
                    Rectangle()
                        .fill(SettingsTheme.separator)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ChoiceRowView(row: row, reserveCheck: hasChecks) { choose(row) }
                }
            }
        }
        .padding(5)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
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

private struct ChoiceRowView: View {
    let row: ChoiceRow
    let reserveCheck: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if reserveCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(row.checked ? 1 : 0)
                        .frame(width: 12)
                }
                if let image = row.image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(row.title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .foregroundStyle(row.enabled ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && row.enabled ? SettingsTheme.selectedRow : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .onHover { hovering = $0 }
    }
}
