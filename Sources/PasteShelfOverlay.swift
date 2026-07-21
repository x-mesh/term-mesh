import AppKit
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

/// Keyboard-first Shelf surface mounted above the active terminal portal.
/// It never becomes first responder, so selection remains owned by the target pane.
struct PasteShelfOverlay: View {
    @ObservedObject var store: PasteShelfStore
    @ObservedObject var state: PasteShelfOverlayState
    let onPaste: (PasteShelfStore.Item) -> Void
    let onClose: () -> Void
    @State private var imagePreviewItem: PasteShelfStore.Item?
    @State private var isClearConfirmationPresented = false

    var body: some View {
        let visibleItems = store.filteredItems(matching: state.searchQuery)

        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
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
                    .frame(maxHeight: 320)
                }

                Divider()

                Text("↑↓/j k select · Enter paste · Esc close")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            .frame(width: 390)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(20)
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
                    Text(item.isPinned ? "Pinned" : relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

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
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    @ViewBuilder
    private var preview: some View {
        if item.kind == .image,
           let url = store.imageURL(for: item),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "text.alignleft")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
    }

    private var title: String {
        item.kind == .text
            ? (item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Text")
            : "Image"
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
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
