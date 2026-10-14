import SwiftUI
import AppKit

// MARK: Übergang: weich einblenden mit Unschärfe (Stärke je nach Einstellung)

private struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale)
    }
}

private extension AnyTransition {
    static func blurFade(_ radius: CGFloat) -> AnyTransition {
        // „Bewegung reduzieren“: nur überblenden
        if radius == 0 { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: BlurFade(radius: radius, opacity: 0, scale: 0.94),
                                 identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .modifier(active: BlurFade(radius: radius * 0.7, opacity: 0, scale: 0.96),
                               identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

// MARK: Wurzelansicht: die schwarze Form und ihr Inhalt

struct ShelfRootView: View {
    @ObservedObject var ui: ShelfUIModel
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions

    private var edgeAlignment: Alignment { settings.edge == .right ? .trailing : .leading }

    var body: some View {
        let m = ShelfMetrics.for(ui.level, settings: settings)
        let full = ShelfMetrics.for(.expanded, settings: settings)
        let shape = EdgeBlobShape(edge: settings.edge, cornerRadius: m.cornerRadius, fillet: m.fillet,
                                  filletStretch: m.filletStretch, cornerStretch: m.cornerStretch)

        ZStack(alignment: edgeAlignment) {
            Color.clear

            ZStack(alignment: edgeAlignment) {
                // Weicher Schatten, der innerhalb des Fensterrands ganz ausläuft
                // (Platz dafür: ShelfMetrics.panelMargin). Nur eine Ebene: Jeder Schatten
                // wird in jedem Bild der Animation neu berechnet.
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(ui.level == .expanded ? 0.45 : 0),
                            radius: 18, x: 0, y: 8)

                // Feiner heller Rahmen: auf dunklem Hintergrund sichtbar, auf hellem
                // verschwindet er fast. Ohne Linie am Bildschirmrand selbst.
                EdgeBlobShape(edge: settings.edge, cornerRadius: m.cornerRadius, fillet: m.fillet,
                              filletStretch: m.filletStretch, cornerStretch: m.cornerStretch, closed: false)
                    .stroke(Color.white.opacity(settings.showOutline ? 0.2 : 0), lineWidth: 1)
                    .allowsHitTesting(false)

                content(m: m, full: full)
                    .clipShape(shape)
            }
            .frame(width: m.width, height: m.height + 2 * m.fillet, alignment: edgeAlignment)
            // Kleine Stufen sitzen auf der Wunschhöhe (adaptiv: am Zeiger), die offene Ablage mittig im Fenster
            .offset(y: ui.level == .expanded ? 0 : ui.anchorOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    /// Inhalt innerhalb der Form: Pfeil in der mittleren Stufe, Ablage im offenen Zustand.
    private func content(m: ShelfMetrics, full: ShelfMetrics) -> some View {
        ZStack(alignment: edgeAlignment) {
            Color.clear

            if ui.level == .hint {
                Color.clear
                    .frame(width: m.width, height: m.height)
                    .contentShape(Rectangle())
                    .onTapGesture { ui.expandRequested = true }   // Modus „Per Klick“
                    .transition(.opacity)
            }

            if ui.level == .expanded {
                ShelfContent(ui: ui, store: store, settings: settings, actions: actions)
                    .frame(width: full.width, height: full.height)
                    .padding(.vertical, full.fillet)
                    .transition(.blurFade(settings.animationStyle.blur))
            }
        }
        .frame(width: m.width, height: m.height + 2 * m.fillet, alignment: edgeAlignment)
    }
}

// MARK: Inhalt der offenen Ablage

struct ShelfContent: View {
    @ObservedObject var ui: ShelfUIModel
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions

    @State private var tileFrames: [UUID: CGRect] = [:]
    @State private var band: CGRect?
    @State private var selectionBeforeBand: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 8)]

    /// Geöffneter Stapel, solange er noch ein Stapel ist.
    private var stack: ShelfEntry? {
        guard let entry = actions.openStackEntry, entry.isStack else { return nil }
        return entry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .frame(height: 30)
                .padding(.top, 12)
                .padding(.bottom, 4)

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if let stack {
                            stackGrid(stack)
                                .transition(.opacity)
                        } else {
                            mainGrid
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    // Ohne Fokus laufen Einblend-Animationen nicht zuverlässig weiter: neue
                    // Kacheln dann sofort zeigen statt unsichtbar am Anfang der Animation
                    .transaction { if !ui.isKey { $0.animation = nil } }
                    .coordinateSpace(name: "grid")
                    .background(
                        SelectionBackground(
                            ui: ui,
                            onBandChanged: updateBand,
                            onClick: { actions.clearCurrentSelection() },
                            menu: { actions.backgroundMenu() }
                        )
                    )
                    .overlay(alignment: .topLeading) { bandOverlay }
                    .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
                }
            }

            QuickActionBar(settings: settings, ui: ui, store: store, actions: actions)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
        .background(
            // Leere Stellen außerhalb des Rasters (Kopfbereich, Ränder): Klick und Rechtsklick
            SelectionBackground(
                ui: ui,
                onBandChanged: { _, _ in },
                onClick: { actions.clearCurrentSelection() },
                menu: { actions.backgroundMenu() },
                allowsBand: false
            )
        )
        .overlay(dropHighlight)
        .onChange(of: store.entries) { _, _ in
            // Stapel aufgelöst oder entfernt: zurück zur Ablage
            if ui.openStack != nil && stack == nil { ui.openStack = nil }
        }
    }

    // MARK: Kopfbereich

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let stack {
                Button {
                    actions.closeStack()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("Shelf", "Ablage"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Back to the shelf (esc)", "Zurück zur Ablage (esc)"))
                Spacer(minLength: 8)
                let selected = ui.memberSelection.intersection(stack.files.map(\.id)).count
                status(selected > 0 ? L("\(selected) of \(stack.files.count) selected", "\(selected) von \(stack.files.count) ausgewählt")
                                    : L("\(stack.files.count) items in stack", "\(stack.files.count) Objekte im Stapel"))
            } else {
                Text(L("Shelf", "Ablage"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                let count = store.entries.reduce(0) { $0 + $1.files.count }
                let selected = actions.selectedEntries.reduce(0) { $0 + $1.files.count }
                if store.pendingImports > 0 && ui.notice == nil {
                    // Große Dateien, Downloads und iCloud brauchen einen Moment
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        countLabel(L("Importing", "Wird übernommen"))
                    }
                } else {
                    status(count == 0 ? nil
                           : selected > 0 ? L("\(selected) of \(count) selected", "\(selected) von \(count) ausgewählt")
                           : (count == 1 ? L("1 item", "1 Objekt") : L("\(count) items", "\(count) Objekte")))
                }
            }
        }
    }

    /// Rechts im Kopf: kurz eine Rückmeldung, sonst die Anzahl.
    @ViewBuilder
    private func status(_ fallback: String?) -> some View {
        if let notice = ui.notice {
            countLabel(notice.text)
                .id(notice.id)
            .transition(.opacity)
        } else if let fallback {
            countLabel(fallback)
        }
    }

    private func countLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .transaction { $0.animation = nil }   // Zahl ändert sich ohne Animation
            .allowsHitTesting(false)
    }

    // MARK: Raster

    @ViewBuilder
    private var mainGrid: some View {
        if store.entries.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .allowsHitTesting(false)
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(actions.orderedEntries) { entry in
                    TileView(entry: entry, ui: ui, actions: actions,
                             isSelected: ui.selection.contains(entry.id))
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: TileFramesKey.self,
                                                       value: [entry.id: g.frame(in: .named("grid"))])
                            }
                        )
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func stackGrid(_ stack: ShelfEntry) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(stack.files) { file in
                StackMemberTile(file: file, entry: stack, ui: ui, actions: actions,
                                isSelected: ui.memberSelection.contains(file.id))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: TileFramesKey.self,
                                                   value: [file.id: g.frame(in: .named("grid"))])
                        }
                    )
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Auswahlrahmen

    @ViewBuilder
    private var bandOverlay: some View {
        if let band {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }

    private func updateBand(_ rect: CGRect?, modifiers: NSEvent.ModifierFlags) {
        guard let rect else {
            band = nil
            return
        }
        let additive = modifiers.contains(.command) || modifiers.contains(.shift)
        let inStack = stack != nil
        if band == nil {
            selectionBeforeBand = additive ? (inStack ? ui.memberSelection : ui.selection) : []
        }
        band = rect
        let hit = Set(tileFrames.filter { $0.value.intersects(rect) }.map(\.key))
        if let stack {
            ui.memberSelection = selectionBeforeBand.union(hit)
            if let first = stack.files.first(where: { hit.contains($0.id) }) { ui.memberAnchor = first.id }
        } else {
            ui.selection = selectionBeforeBand.union(hit)
            if let first = actions.orderedEntries.first(where: { hit.contains($0.id) }) { ui.selectionAnchor = first.id }
        }
    }

    // MARK: Leerer Zustand, Drop-Hervorhebung

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(ui.isDropTargeted ? 0.95 : 0.45))
                .scaleEffect(ui.isDropTargeted ? 1.12 : 1)
            Text(L("Drop here", "Hier ablegen"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(L("Files, web images,\nlinks and text", "Dateien, Bilder aus dem Web,\nLinks und Text"))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(ui.isDropTargeted ? 0.28 : 0), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(ui.isDropTargeted ? 0.05 : 0))
            )
            .padding(8)
            .allowsHitTesting(false)
    }
}

// MARK: Kachel (Darstellung wie im Finder)

/// Gemeinsame Darstellung: Vorschau mit grauer Fläche und Name in Akzentfarbe, wenn ausgewählt.
struct TileLabel<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let isKey: Bool
    var isDropTarget = false
    @ViewBuilder let preview: () -> Preview

    private var nameBackground: Color {
        guard isSelected else { return .clear }
        return Color(nsColor: isKey ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 4) {
            preview()
                .frame(width: 60, height: 60)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(isSelected || isDropTarget ? 0.14 : 0))
                )
                .scaleEffect(isDropTarget ? 1.06 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isDropTarget)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.88))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(nameBackground))
                .frame(maxWidth: 84, minHeight: 30, alignment: .top)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

struct TileView: View {
    let entry: ShelfEntry
    @ObservedObject var ui: ShelfUIModel
    let actions: ShelfActions
    let isSelected: Bool

    var body: some View {
        TileLabel(title: entry.title, isSelected: isSelected, isKey: ui.isKey || ui.level == .expanded) {
            if entry.isStack {
                StackPreview(files: Array(entry.files.prefix(3)))
            } else if let file = entry.files.first {
                ThumbnailView(url: file.url, size: 56)
            }
        }
        .overlay(
            DragSource(
                ui: ui,
                files: { actions.dragFiles(for: entry) },
                onMouseDown: { mods in actions.select(entry, modifiers: mods) },
                onClick: { clicks, mods in
                    actions.clickedWithoutDrag(entry, modifiers: mods)
                    if clicks >= 2 && !entry.isStack { actions.activate(entry) }
                },
                onDragEnded: { operation in
                    actions.dragEnded(actions.targets(for: entry).flatMap(\.files), operation: operation)
                },
                menu: { anchor in actions.menu(for: entry, anchor: anchor) },
                draggedIDs: { Set(actions.targets(for: entry).map(\.id)) },
                onShelfDrop: { pb in actions.store.ingest(from: pb) },
                onShelfTargeted: { targeted in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { ui.isDropTargeted = targeted }
                }
            )
        )
        .opacity(offlineVolume != nil ? 0.4 : 1)
        .help(offlineVolume.map { L("Drive “\($0)” isn’t connected", "Laufwerk „\($0)“ ist nicht angeschlossen") }
              ?? (entry.isStack ? L("Open stack", "Stapel öffnen") : entry.urls.map(\.lastPathComponent).joined(separator: "\n")))
    }

    /// Alle Dateien liegen auf einem Laufwerk, das gerade nicht angeschlossen ist
    private var offlineVolume: String? {
        let names = entry.files.map(\.offlineVolumeName)
        guard let first = names.first, let name = first, names.allSatisfy({ $0 != nil }) else { return nil }
        return name
    }
}

/// Datei innerhalb eines geöffneten Stapels: auswählbar wie die Kacheln der Ablage.
struct StackMemberTile: View {
    let file: ShelfFile
    let entry: ShelfEntry
    @ObservedObject var ui: ShelfUIModel
    let actions: ShelfActions
    let isSelected: Bool

    var body: some View {
        TileLabel(title: ShelfEntry.displayName(for: file.url), isSelected: isSelected, isKey: ui.isKey || ui.level == .expanded) {
            ThumbnailView(url: file.url, size: 56)
        }
        .overlay(
            DragSource(
                ui: ui,
                files: { actions.memberDragFiles(for: file) },
                onMouseDown: { mods in actions.selectMember(file, modifiers: mods) },
                onClick: { clicks, mods in
                    actions.clickedMemberWithoutDrag(file, modifiers: mods)
                    if clicks >= 2 { actions.memberTargets(for: file).forEach { NSWorkspace.shared.open($0.url) } }
                },
                onDragEnded: { operation in
                    actions.dragEnded(actions.memberTargets(for: file), operation: operation)
                },
                menu: { anchor in actions.menu(for: file, in: entry, anchor: anchor) }
            )
        )
        .opacity(file.offlineVolumeName != nil ? 0.4 : 1)
        .help(file.offlineVolumeName.map { L("Drive “\($0)” isn’t connected", "Laufwerk „\($0)“ ist nicht angeschlossen") } ?? file.url.lastPathComponent)
    }
}

/// Aufgefächerte Vorschau eines Stapels (bis zu drei Dateien).
private struct StackPreview: View {
    let files: [ShelfFile]

    private func angle(_ index: Int) -> Angle {
        .degrees(Double(index) * 7.0 - 7.0)
    }

    private func offsetX(_ index: Int) -> CGFloat {
        CGFloat(index) * 4.0 - 4.0
    }

    var body: some View {
        ZStack {
            ForEach(Array(files.indices.reversed()), id: \.self) { index in
                ThumbnailView(url: files[index].url, size: 46)
                    .rotationEffect(angle(index))
                    .offset(x: offsetX(index), y: CGFloat(-2 * index))
            }
        }
    }
}
