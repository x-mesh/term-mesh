import AppKit
import ImageIO
import SwiftUI

@MainActor
final class PasteShelfOverlayState: ObservableObject {
    @Published private(set) var selectedIndex = 0
    @Published var searchQuery = ""

    func moveSelection(by delta: Int, itemCount: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), itemCount - 1)
    }

    /// Keep the selection inside the rows currently on screen. `itemCount` must
    /// be the *filtered* count — the list renders filtered rows, so clamping
    /// against the whole store leaves the selection past the last visible row.
    func clampSelection(itemCount: Int) {
        selectedIndex = itemCount == 0 ? 0 : min(selectedIndex, itemCount - 1)
    }

    /// Start a fresh presentation: the Shelf opens on the newest item with no
    /// search applied. Carrying the previous query over means reopening can
    /// show an empty Shelf while items exist.
    func resetForPresentation() {
        selectedIndex = 0
        searchQuery = ""
    }

    func select(_ index: Int) {
        selectedIndex = index
    }
}

/// Window-wide host for the Shelf. Items are global and only the paste target
/// belongs to a pane, so the Shelf spans the window instead of being clipped
/// to that pane and leaving the other panes clickable under a live key monitor.
@MainActor
final class PasteShelfWindowContainerView: NSView {
    /// Portals composite by layer, not by subview order: terminal 100,
    /// browser 200, file-drop overlay 300, command palette 400.
    private static let layerZPosition: CGFloat = 350

    /// Closes this Shelf through the pane that opened it, which also owns the
    /// key monitor that must go with it.
    private(set) var dismiss: (() -> Void)?

    override var isOpaque: Bool { false }

    static func installed(in window: NSWindow) -> PasteShelfWindowContainerView? {
        window.contentView?.superview?.subviews.lazy.compactMap { $0 as? PasteShelfWindowContainerView }.first
    }

    static func install(
        _ content: NSView,
        in window: NSWindow,
        dismiss: @escaping () -> Void
    ) -> PasteShelfWindowContainerView? {
        guard let contentView = window.contentView, let themeFrame = contentView.superview else { return nil }
        let container = PasteShelfWindowContainerView(frame: contentView.frame)
        container.dismiss = dismiss
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.zPosition = layerZPosition
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        themeFrame.addSubview(container, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }
}

/// The Shelf size the user picked with the corner grip. It is stored once for
/// every window, so each render clamps it to the window that shows the Shelf:
/// a size chosen in a large window must still fit a small one.
enum PasteShelfPanelSize {
    static let widthKey = "pasteShelf.panelWidth"
    static let heightKey = "pasteShelf.panelHeight"
    static let defaultSize = CGSize(width: 560, height: 520)
    static let minimumSize = CGSize(width: 360, height: 260)
    static let margin: CGFloat = 20

    static func clamped(_ size: CGSize, in container: CGSize) -> CGSize {
        let available = CGSize(
            width: max(0, container.width - margin * 2),
            height: max(0, container.height - margin * 2)
        )
        return CGSize(
            width: min(max(size.width, min(minimumSize.width, available.width)), available.width),
            height: min(max(size.height, min(minimumSize.height, available.height)), available.height)
        )
    }
}

/// Keyboard-first Shelf surface mounted above the terminal portals. Its search
/// field takes keyboard focus while it is open; the pane that opened it stays
/// the paste target.
struct PasteShelfOverlay: View {
    @ObservedObject var store: PasteShelfStore
    @ObservedObject var state: PasteShelfOverlayState
    let onPaste: (PasteShelfStore.Item) -> Void
    let onClose: () -> Void
    @State private var imagePreviewItem: PasteShelfStore.Item?
    @State private var isClearConfirmationPresented = false
    @AppStorage(PasteShelfPanelSize.widthKey)
    private var storedWidth = Double(PasteShelfPanelSize.defaultSize.width)
    @AppStorage(PasteShelfPanelSize.heightKey)
    private var storedHeight = Double(PasteShelfPanelSize.defaultSize.height)
    @State private var resizeStartSize: CGSize?
    @State private var liveSize: CGSize?

    var body: some View {
        let visibleItems = store.filteredItems(matching: state.searchQuery)

        GeometryReader { proxy in
            let panelSize = PasteShelfPanelSize.clamped(
                liveSize ?? CGSize(width: storedWidth, height: storedHeight),
                in: proxy.size
            )
            ZStack {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                panel(visibleItems: visibleItems)
                    .frame(width: panelSize.width, height: panelSize.height)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        resizeGrip(currentSize: panelSize, container: proxy.size)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear { store.sweepExpired() }
        // Recomputed rather than reusing `visibleItems`: that is the value from
        // the render pass that installed the handler, which is already stale by
        // the time the store changes.
        .onChange(of: store.items.count) { _ in
            state.clampSelection(itemCount: store.filteredItems(matching: state.searchQuery).count)
        }
        .onChange(of: state.searchQuery) { _ in
            state.clampSelection(itemCount: store.filteredItems(matching: state.searchQuery).count)
        }
        .alert("Delete all Shelf items?", isPresented: $isClearConfirmationPresented) {
            Button("Delete All", role: .destructive) {
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also deletes pinned items and saved images.")
        }
        .sheet(item: $imagePreviewItem) { item in
            PasteShelfImagePreview(item: item, imageURL: store.imageURL(for: item))
        }
    }

    private func panel(visibleItems: [PasteShelfStore.Item]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square")
                    .foregroundColor(.secondary)
                Text("Paste Shelf")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear All", role: .destructive) {
                        isClearConfirmationPresented = true
                    }
                    .controlSize(.small)
                }
                Text("⌘⇧V to close")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            searchField

            if visibleItems.isEmpty {
                Text("Copy terminal text with ⌘C, or copy an image in any app and open Shelf")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                PasteShelfOverlayRow(
                                    item: item,
                                    store: store,
                                    isSelected: state.selectedIndex == index,
                                    onPaste: { onPaste(item) },
                                    onPreviewImage: { imagePreviewItem = item }
                                )
                            }
                        }
                        .padding(6)
                    }
                    // Keyboard selection must stay on screen: Enter pastes the
                    // selected row even when it has scrolled out of view.
                    .onChange(of: state.selectedIndex) { index in
                        let items = store.filteredItems(matching: state.searchQuery)
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            Text("↑↓ select · Enter paste · Esc close")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func resizeGrip(currentSize: CGSize, container: CGSize) -> some View {
        PasteShelfResizeGrip()
            .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(
                // Global space: the grip moves while the panel grows, so a
                // local translation would feed that motion back into the drag.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStartSize ?? currentSize
                        resizeStartSize = start
                        // The panel stays centered, so each edge moves by half
                        // of the size change; doubling keeps the grip under the pointer.
                        liveSize = PasteShelfPanelSize.clamped(
                            CGSize(
                                width: start.width + value.translation.width * 2,
                                height: start.height + value.translation.height * 2
                            ),
                            in: container
                        )
                    }
                    .onEnded { _ in
                        if let liveSize {
                            storedWidth = liveSize.width
                            storedHeight = liveSize.height
                        }
                        liveSize = nil
                        resizeStartSize = nil
                    }
            )
            .onTapGesture(count: 2) {
                storedWidth = PasteShelfPanelSize.defaultSize.width
                storedHeight = PasteShelfPanelSize.defaultSize.height
            }
            .backport.pointerStyle(.resizeBottomTrailing)
            .help("Drag to resize · Double-click to reset")
            .accessibilityLabel("Resize Shelf")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search Shelf", text: $state.searchQuery)
                .textFieldStyle(.plain)
            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PasteShelfOverlayRow: View {
    let item: PasteShelfStore.Item
    @ObservedObject var store: PasteShelfStore
    let isSelected: Bool
    let onPaste: () -> Void
    let onPreviewImage: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    /// Tooltips are for telling similar long entries apart, not for reading
    /// a whole log dump.
    private static let tooltipCharacterLimit = 2000

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if item.kind == .image {
                    Button(action: onPreviewImage) {
                        preview
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview image")
                    .help("Preview image")
                } else {
                    preview
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Button(action: onPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(tooltip)

            Menu {
                Button(item.isPinned ? "Unpin" : "Pin") {
                    store.setPinned(!item.isPinned, id: item.id)
                }
                Button("Delete", role: .destructive) {
                    store.delete(id: item.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered = $0 }
        .task(id: item.id) {
            guard item.kind == .image, let url = store.imageURL(for: item) else { return }
            thumbnail = await PasteShelfThumbnailCache.shared.thumbnail(for: url)
        }
        .contextMenu {
            Button("Paste", action: onPaste)
            Button(item.isPinned ? "Unpin" : "Pin") {
                store.setPinned(!item.isPinned, id: item.id)
            }
            Button("Delete", role: .destructive) {
                store.delete(id: item.id)
            }
        }
    }

    /// Hover only tints the row; moving the keyboard selection with it would
    /// fight auto-scroll, which slides rows under a resting pointer.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovered ? Color.primary.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var preview: some View {
        if item.kind == .image, let image = thumbnail ?? cachedThumbnail {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
    }

    /// Rows are rebuilt as the lazy list scrolls; reading the cache here keeps
    /// a returning row from flashing the placeholder.
    private var cachedThumbnail: NSImage? {
        store.imageURL(for: item).flatMap { PasteShelfThumbnailCache.shared.cached(for: $0) }
    }

    private var subtitle: String {
        let when = item.isPinned ? "Pinned" : relativeDate
        guard let text = item.text else { return when }
        let lineCount = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count
        return lineCount > 1 ? "\(when) · \(lineCount) lines" : when
    }

    private var tooltip: String {
        guard let text = item.text else { return "" }
        guard text.count > Self.tooltipCharacterLimit else { return text }
        return String(text.prefix(Self.tooltipCharacterLimit)) + "…"
    }

    private var title: String {
        item.kind == .text
            ? (item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Text")
            : "Image"
    }

    private var relativeDate: String {
        Self.relativeDateFormatter.localizedString(for: item.createdAt, relativeTo: Date())
    }
}

/// Row previews are 34 pt squares while Shelf images can be 20 MB captures.
/// Building them from the full file in the row body repeated that decode on
/// every render, on the main thread.
@MainActor
final class PasteShelfThumbnailCache {
    static let shared = PasteShelfThumbnailCache()
    nonisolated private static let maximumPixelSize = 128
    private let cache = NSCache<NSURL, NSImage>()

    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cached(for: url) { return hit }
        let cgImage = await Task.detached(priority: .utility) {
            Self.makeThumbnail(at: url)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    nonisolated private static func makeThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct PasteShelfImagePreview: View {
    let item: PasteShelfStore.Item
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image")
                .font(.headline)
            Group {
                if let imageURL, let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                }
            }
            .frame(minWidth: 420, idealWidth: 720, minHeight: 300, idealHeight: 560)
        }
        .padding(20)
    }
}

private struct PasteShelfResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 4
        let corner = CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
        var path = Path()
        for length in [5.0, 9.0] as [CGFloat] {
            path.move(to: CGPoint(x: corner.x - length, y: corner.y))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y - length))
        }
        return path
    }
}
