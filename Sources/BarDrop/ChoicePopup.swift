import AppKit
import SwiftUI

/// Eigene Menüs im Stil der Karten: dunkle Fläche, feiner Rand, Zeilen mit sanfter
/// Hervorhebung, Haken vor der gewählten Möglichkeit, rechts die Tastenkürzel und
/// Untermenüs, die sich daneben öffnen, während das Menü stehen bleibt.
///
/// Dient für die Auswahlen der Einstellungen (an einem Knopf) und für die
/// Rechtsklick-Menüs der Ablage (am Zeiger). Gefüllt wird es aus einem gewöhnlichen
/// `NSMenu`, damit die Aufrufer ihre Menüs wie gewohnt bauen.
final class ChoicePopup: NSPanel {
    /// Das offene Menü (die Wurzel, nicht ein Untermenü)
    private static var current: ChoicePopup?
    /// Zuletzt per Klick daneben geschlossen: an welchem Knopf und wann. Ein Klick auf
    /// denselben Knopf schließt dann nur, statt gleich wieder zu öffnen.
    private static var lastClosed: (anchor: CGRect, time: Date)?

    enum Alignment { case leading, trailing }

    private var anchor: CGRect = .zero
    /// Hält die Einträge am Leben, solange das Menü offen ist
    private var menu: NSMenu?
    private var rows: [ChoiceRow] = []
    /// Lage der Zeilen im Menü (von oben links), für Untermenüs daneben
    fileprivate var rowFrames: [Int: CGRect] = [:]
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var onClose: (() -> Void)?
    private weak var rootMenu: ChoicePopup?
    private var child: ChoicePopup?
    private var childIndex: Int?

    private var root: ChoicePopup { rootMenu ?? self }

    // MARK: Zeigen

    /// Einstellungen: Liste unter einem Knopf (`frame` in SwiftUI-Koordinaten im Fenster)
    static func present(_ menu: NSMenu, anchor frame: CGRect, align: Alignment) {
        current?.dismiss()
        if let last = lastClosed, last.anchor == frame, Date().timeIntervalSince(last.time) < 0.6 {
            lastClosed = nil
            return
        }
        guard let parent = NSApp.keyWindow ?? NSApp.currentEvent?.window,
              let content = parent.contentView else { return }
        let popup = make(menu, minWidth: max(frame.width, 160))
        let size = popup.frame.size

        // SwiftUI misst von oben links im Fenster, das Fenster von unten links
        let below = parent.convertPoint(toScreen: NSPoint(x: frame.minX, y: content.bounds.height - frame.maxY))
        let above = parent.convertPoint(toScreen: NSPoint(x: frame.minX, y: content.bounds.height - frame.minY))
        var x = align == .leading ? below.x : below.x + frame.width - size.width
        var y = below.y - 6 - size.height
        if let area = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if y < area.minY + 8 { y = above.y + 6 }   // unten zu wenig Platz: nach oben
            x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        }
        popup.anchor = frame
        popup.show(at: NSPoint(x: x, y: y), parent: parent)
        popup.watch(parent: parent, closeWhenParentResigns: true)
        current = popup
    }

    /// Ablage: Menü am Zeiger, wie ein Rechtsklick-Menü. `onClose` nach dem Schließen.
    static func present(_ menu: NSMenu, at point: NSPoint, parent: NSWindow, onClose: @escaping () -> Void) {
        current?.dismiss()
        let popup = make(menu, minWidth: 180)
        popup.onClose = onClose
        let size = popup.frame.size
        var x = point.x + 2
        var y = point.y - size.height - 2
        if let area = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if y < area.minY + 8 { y = point.y + 2 }
            if x + size.width > area.maxX - 8 { x = point.x - size.width - 2 }
        }
        popup.show(at: NSPoint(x: x, y: y), parent: parent)
        popup.watch(parent: parent, closeWhenParentResigns: false)
        current = popup
    }

    private static func make(_ menu: NSMenu, minWidth: CGFloat) -> ChoicePopup {
        let popup = ChoicePopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = .popUpMenu
        popup.menu = menu
        popup.rows = menu.items.filter { !$0.isHidden }.map(ChoiceRow.init)
        let host = NSHostingView(rootView: ChoiceList(
            rows: popup.rows, minWidth: minWidth,
            choose: { [weak popup] index in popup?.choose(index) },
            hover: { [weak popup] index in popup?.hovered(index) },
            frames: { [weak popup] frames in popup?.rowFrames = frames }
        ))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        popup.contentView = host
        popup.setContentSize(size)
        return popup
    }

    private func show(at origin: NSPoint, parent: NSWindow) {
        setFrameOrigin(origin)
        parent.addChildWindow(self, ordered: .above)
        orderFront(nil)
    }

    // MARK: Auswählen und Untermenüs

    private func choose(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if row.submenu != nil {
            openSubmenu(index)
            return
        }
        root.dismiss()
        row.perform()
    }

    /// Über einer Zeile: Untermenü öffnen bzw. ein anderes schließen
    private func hovered(_ index: Int?) {
        guard let index, rows.indices.contains(index) else { return }
        if rows[index].submenu != nil {
            openSubmenu(index)
        } else if child != nil {
            closeChild()
        }
    }

    private func openSubmenu(_ index: Int) {
        guard childIndex != index, let submenu = rows[index].submenu, let rowFrame = rowFrames[index] else { return }
        closeChild()
        let popup = Self.make(submenu, minWidth: 160)
        popup.rootMenu = root
        let size = popup.frame.size
        // Erste Zeile des Untermenüs auf Höhe der Zeile, rechts daneben
        let rowTop = frame.maxY - rowFrame.minY
        var x = frame.maxX - 4
        var y = rowTop + 5 - size.height
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            if x + size.width > area.maxX - 8 { x = frame.minX - size.width + 4 }
            y = min(max(y, area.minY + 8), area.maxY - size.height - 8)
        }
        popup.show(at: NSPoint(x: x, y: y), parent: self)
        child = popup
        childIndex = index
    }

    private func closeChild() {
        child?.closeChild()
        if let child {
            removeChildWindow(child)
            child.orderOut(nil)
        }
        child = nil
        childIndex = nil
    }

    /// Gehört das Fenster zu diesem Menü oder einem seiner Untermenüs?
    private func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === self || (child?.contains(window) ?? false)
    }

    // MARK: Schließen

    /// Schließt bei Klick daneben, Escape und (in den Einstellungen) wenn das Fenster
    /// in den Hintergrund geht. Solange es offen ist, scrollt nichts dahinter.
    private func watch(parent: NSWindow, closeWhenParentResigns: Bool) {
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel],
                                                        handler: { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { self.dismiss(); return nil }
                return event
            case .scrollWheel:
                return self.contains(event.window) ? event : nil
            default:
                if !self.contains(event.window) {
                    Self.lastClosed = (self.anchor, Date())
                    self.dismiss()
                }
                return event
            }
        }) {
            monitors.append(local)
        }
        // Klicks in anderen Apps
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                          handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(global)
        }
        if closeWhenParentResigns {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: parent, queue: .main) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        closeChild()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
        let close = onClose
        onClose = nil
        close?()
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
    let shortcut: String
    let submenu: NSMenu?
    private weak var item: NSMenuItem?

    init(_ item: NSMenuItem) {
        self.item = item
        title = item.title
        checked = item.state == .on
        separator = item.isSeparatorItem
        submenu = item.submenu
        enabled = !item.isSeparatorItem && (item.submenu != nil || (item.action != nil && item.isEnabled))
        image = item.image
        shortcut = Self.shortcut(of: item)
    }

    /// Tastenkürzel wie im Systemmenü: ⌃⌥⇧⌘ und die Taste
    private static func shortcut(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let mods = item.keyEquivalentModifierMask
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        switch key {
        case "\u{8}", "\u{7f}": text += "⌫"
        case "\r": text += "↩"
        case " ": text += "␣"
        default: text += key.uppercased()
        }
        return text
    }

    func perform() {
        guard let item, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ChoiceList: View {
    let rows: [ChoiceRow]
    let minWidth: CGFloat
    let choose: (Int) -> Void
    let hover: (Int?) -> Void
    let frames: ([Int: CGRect]) -> Void

    private var hasChecks: Bool { rows.contains(where: \.checked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if row.separator {
                    Rectangle()
                        .fill(SettingsTheme.separator)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ChoiceRowView(row: row, reserveCheck: hasChecks,
                                  action: { choose(index) },
                                  hover: { inside in if inside { hover(index) } })
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: RowFramesKey.self,
                                                       value: [index: g.frame(in: .named("choices"))])
                            }
                        )
                }
            }
        }
        .padding(5)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .coordinateSpace(name: "choices")
        .onPreferenceChange(RowFramesKey.self) { frames($0) }
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
    let hover: (Bool) -> Void
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
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }
                Text(row.title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Spacer(minLength: 18)
                if row.submenu != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if !row.shortcut.isEmpty {
                    Text(row.shortcut)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
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
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
    }
}
