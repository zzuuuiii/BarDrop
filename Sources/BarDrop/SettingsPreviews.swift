import SwiftUI
import AppKit

// MARK: Vorschauen in den Einstellungen

/// Gemeinsamer Rahmen aller Vorschauen (Öffnen, Aussehen, Aktionen): ein Ausschnitt des
/// Bildschirms mit ruhigem Hintergrund in der Akzentfarbe, darin die echte Ablage. Alle drei
/// sehen gleich aus und unterscheiden sich nur im Ausschnitt (Nutzer, 07.11.2026: „die sollen
/// alle designtechnisch passen“)
struct PreviewScreen<Content: View>: View {
    let height: CGFloat
    var width: CGFloat? = nil
    /// Höhe der Menüleiste oben (0: Ausschnitt ohne Menüleiste)
    var menuBar: CGFloat = 0
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                PreviewBackground()
                if menuBar > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(height: menuBar)
                }
                content(geo.size)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .padding(14)
    }
}

/// Die offene Ablage am Rand, verkleinert um `scale`: Form mit den Bögen zum Bildschirmrand,
/// Kopfzeile, so viele Kacheln, wie bei der Symbolgröße hineinpassen, und die echte
/// Aktionsleiste. Breite und Höhe wie eingestellt
struct MiniShelf: View {
    @ObservedObject var settings: AppSettings
    let scale: CGFloat

    /// Bögen zum Rand oben und unten (wie ShelfMetrics der offenen Ablage)
    static let fillet: CGFloat = 16
    /// Höhe samt Bögen in Punkten der echten Ablage
    static func outerHeight(_ settings: AppSettings) -> CGFloat { CGFloat(settings.shelfHeight) + 2 * fillet }

    var body: some View {
        let fillet = Self.fillet * scale
        EdgeBlobShape(edge: settings.edge, cornerRadius: 28 * scale, fillet: fillet)
            .fill(Color.black)
            .overlay {
                MiniShelfContent(settings: settings, scale: scale)
                    .padding(.vertical, fillet)
                    .clipped()
            }
            .overlay {
                if settings.showOutline {
                    EdgeBlobShape(edge: settings.edge, cornerRadius: 28 * scale, fillet: fillet, closed: false)
                        .stroke(Color.white.opacity(0.22), lineWidth: max(0.5, min(1, scale)))
                }
            }
            .frame(width: CGFloat(settings.shelfWidth) * scale, height: Self.outerHeight(settings) * scale)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

/// Inhalt der verkleinerten Ablage
private struct MiniShelfContent: View {
    @ObservedObject var settings: AppSettings
    let scale: CGFloat

    var body: some View {
        let w = settings.shelfWidth, h = settings.shelfHeight, icon = settings.tileIconSize
        let columns = ShelfGrid.columns(shelfWidth: w, iconSize: icon)
        let fraction = ShelfRows.rows(forHeight: h, iconSize: icon)
        let shownRows = max(1, Int(fraction.rounded(.up)))
        let box = Double(TileMetrics.box(CGFloat(icon))) * scale
        let tile = ShelfRows.tileHeight(icon) * scale
        VStack(spacing: 0) {
            // Kopfzeile: „BarDrop“ als Strich
            HStack {
                Capsule().fill(Color.white.opacity(0.55)).frame(width: 44 * scale, height: max(1.5, 6 * scale))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18 * scale)
            .frame(height: ShelfRows.headerHeight * scale)
            // Kacheln; eine nicht ganz passende Reihe angeschnitten wie in der echten Ablage
            VStack(spacing: ShelfRows.rowSpacing * scale) {
                ForEach(0..<shownRows, id: \.self) { _ in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { _ in
                            VStack(spacing: 4 * scale) {
                                RoundedRectangle(cornerRadius: box * 0.18, style: .continuous)
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: box * 0.8, height: box * 0.8)
                                Capsule().fill(Color.white.opacity(0.3))
                                    .frame(width: box * 0.6, height: max(1, 5 * scale))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: tile)
                        }
                    }
                }
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            // Die Kacheln bekommen den Platz, den die Leiste übrig lässt (wie in der Ablage)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            MiniActionBar(settings: settings, scale: scale)
                .padding(.top, 2 * scale)
                .padding(.bottom, 10 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
}

/// Die Aktionsleiste mit den echten Symbolen, aufgeteilt wie in der Ablage (QuickActionBar)
struct MiniActionBar: View {
    @ObservedObject var settings: AppSettings
    let scale: CGFloat

    var body: some View {
        let all = settings.quickActions.filter { $0.kind != .plugin || PluginManager.shared.isActive($0.path) }
        let split = AppSettings.clampSplit(settings.actionRowSplit, count: all.count)
        let rows = [Array(all.prefix(split)), Array(all.dropFirst(split).prefix(QuickAction.perRow))].filter { !$0.isEmpty }
        let size = iconSize(forActions: rows.map(\.count).max() ?? 1)
        VStack(spacing: 4 * scale) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2 * scale) {
                    ForEach(row) { action in
                        VStack(spacing: 4 * scale) {
                            QuickActionIcon(action: action, size: size * scale)
                            if settings.showActionLabels {
                                let named = !settings.labelsOnlyFolders || action.kind == .folder
                                label(action.title).opacity(named ? 1 : 0)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 16 * scale)
    }

    /// Ab etwa Originalgröße der Name als Text, kleiner nur als Strich
    @ViewBuilder
    private func label(_ title: String) -> some View {
        if scale >= 0.9 {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 24 * scale, height: max(1, 4 * scale))
        }
    }

    /// Wie in QuickActionBar: eingestellt, ohne Namen etwas größer, nie breiter als ihr Platz
    private func iconSize(forActions count: Int) -> CGFloat {
        let base = CGFloat(settings.actionIconSize) + (settings.showActionLabels ? 0 : 10)
        let places = CGFloat(max(count, 1))
        let inner = CGFloat(settings.shelfWidth) - 2 * 10 - 2 * 6
        let slot = (inner - 2 * (places - 1)) / places
        return min(base, max(20, slot - 6))
    }
}

/// Öffnen: der ganze Bildschirm, die offene Ablage an ihrem Rand in echter Größe und Lage.
/// Am Zeiger: der Bereich des Rands, in dem sie erscheint, und die Ablage in seiner Mitte
struct ScreenPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let visible = screen?.visibleFrame ?? frame
        let width: CGFloat = 300
        let scale = width / frame.width
        let height = frame.height * scale
        let menu = max(0, frame.maxY - visible.maxY) * scale
        PreviewScreen(height: height, width: width, menuBar: menu) { size in
            let shelfH = MiniShelf.outerHeight(settings) * scale
            let shelfW = CGFloat(settings.shelfWidth) * scale
            let usable = size.height - menu
            let center: CGFloat = {
                if settings.adaptivePosition { return menu + usable / 2 }
                let y = menu + usable * (1 - CGFloat(settings.verticalPosition))
                return min(max(y, menu + shelfH / 2), size.height - shelfH / 2)
            }()
            let x = settings.edge == .right ? size.width - shelfW : 0
            ZStack(alignment: .topLeading) {
                if settings.adaptivePosition {
                    // Bereich am Rand, in dem die Ablage am Zeiger erscheint
                    let zone = CGFloat(settings.adaptiveZoneFraction ?? 1)
                    Capsule()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 4, height: usable * zone)
                        .offset(x: settings.edge == .right ? size.width - 4 : 0, y: menu + usable * (1 - zone) / 2)
                }
                MiniShelf(settings: settings, scale: scale)
                    .offset(x: x, y: center - shelfH / 2)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.edge)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.verticalPosition)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.adaptivePosition)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.adaptiveZone)
        }
    }
}

/// Aussehen: der Rand vergrößert, die Ablage so groß wie eingestellt
struct ShelfSizePreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        PreviewScreen(height: 220) { size in
            let outer = MiniShelf.outerHeight(settings)
            let scale = min(0.5, (size.height - 24) / outer, (size.width - 40) / CGFloat(settings.shelfWidth))
            let shelfW = CGFloat(settings.shelfWidth) * scale
            MiniShelf(settings: settings, scale: scale)
                .offset(x: settings.edge == .right ? size.width - shelfW : 0,
                        y: (size.height - outer * scale) / 2)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.shelfWidth)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.shelfHeight)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.tileIconSize)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.actionIconSize)
        }
        .accessibilityElement()
        .accessibilityLabel(L("Preview of the shelf", "Vorschau der Ablage"))
    }
}

/// Aktionen: der untere Teil der Ablage in Originalgröße, mit der Aktionsleiste wie eingestellt.
/// Die Höhe richtet sich nach der Leiste (eine oder zwei Reihen, mit oder ohne Namen)
struct ActionBarPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.width - 40) / CGFloat(settings.shelfWidth))
            let fillet = MiniShelf.fillet * scale
            HStack(spacing: 0) {
                if settings.edge == .right { Spacer(minLength: 0) }
                MiniActionBar(settings: settings, scale: scale)
                    .padding(.top, 34 * scale)
                    .padding(.bottom, 10 * scale + fillet)
                    .frame(width: CGFloat(settings.shelfWidth) * scale)
                    .background(
                        EdgeBlobShape(edge: settings.edge, cornerRadius: 28 * scale, fillet: fillet).fill(Color.black)
                            // Oben weit über den Ausschnitt hinaus: Die Ablage geht nach oben weiter
                            .padding(.top, -200)
                    )
                    .environment(\.colorScheme, .dark)
                if settings.edge == .left { Spacer(minLength: 0) }
            }
            .frame(height: geo.size.height, alignment: .bottom)
            .padding(.bottom, 14)
            .background(PreviewBackground())
        }
        .frame(height: barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .padding(14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.quickActions)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.actionIconSize)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.showActionLabels)
        .accessibilityElement()
        .accessibilityLabel(L("Preview of the action bar", "Vorschau der Aktionsleiste"))
    }

    /// Höhe des Ausschnitts: Leiste wie in der Ablage plus etwas Ablage darüber und Rand darunter
    private var barHeight: CGFloat {
        let all = settings.quickActions.filter { $0.kind != .plugin || PluginManager.shared.isActive($0.path) }
        let rows: CGFloat = all.count > AppSettings.clampSplit(settings.actionRowSplit, count: all.count) ? 2 : 1
        let icon = CGFloat(settings.actionIconSize) + (settings.showActionLabels ? 16 : 10)
        return rows * icon + (rows - 1) * 4 + 34 + 10 + 14 + 6
    }
}

/// Hintergrund aller Vorschauen: ruhiger Verlauf in der Akzentfarbe
struct PreviewBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.6),
                                Color(nsColor: .controlAccentColor).opacity(0.25)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
