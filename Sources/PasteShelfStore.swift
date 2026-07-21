import AppKit
import Combine
import Foundation

/// Local-only, explicitly captured paste items. This is deliberately not a
/// clipboard monitor: callers must invoke `capture(from:)` themselves.
@MainActor
final class PasteShelfStore: ObservableObject {
    static let shared = PasteShelfStore()
    static let maximumItems = 20
    static let unpinnedLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let maximumImageBytes = 20 * 1024 * 1024

    enum ItemKind: String, Codable {
        case text
        case image
    }

    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        let kind: ItemKind
        let text: String?
        let imageFilename: String?
        let createdAt: Date
        var isPinned: Bool
    }

    enum CaptureResult: Equatable {
        case added(Item)
        case unsupported
        case tooLarge
        case allItemsPinned
    }

    @Published private(set) var items: [Item] = []

    private let directoryURL: URL
    private let metadataURL: URL
    private let imagesURL: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private var lastCapturedImagePasteboardChangeCount: Int?

    init(
        directoryURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.now = now
        let base = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
        self.directoryURL = base
        self.metadataURL = base.appendingPathComponent("paste-shelf.json")
        self.imagesURL = base.appendingPathComponent("paste-shelf-images", isDirectory: true)
        load()
    }

    func capture(from pasteboard: NSPasteboard = .general) -> CaptureResult {
        sweepExpired()

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return addText(text)
        }
        guard let data = imageData(from: pasteboard) else { return .unsupported }
        return addImage(data)
    }

    /// Imports an image copied by any macOS app when Shelf is opened. The
    /// pasteboard change count prevents re-adding the same image on every open.
    @discardableResult
    func captureImageIfNeeded(from pasteboard: NSPasteboard = .general) -> CaptureResult {
        sweepExpired()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastCapturedImagePasteboardChangeCount,
              let data = imageData(from: pasteboard)
        else { return .unsupported }

        let result = addImage(data)
        if case .added = result {
            lastCapturedImagePasteboardChangeCount = changeCount
        }
        return result
    }

    @discardableResult
    func addText(_ text: String) -> CaptureResult {
        guard makeRoom() else { return .allItemsPinned }
        let item = Item(id: UUID(), kind: .text, text: text, imageFilename: nil, createdAt: now(), isPinned: false)
        items.insert(item, at: 0)
        persist()
        return .added(item)
    }

    @discardableResult
    func addImage(_ data: Data) -> CaptureResult {
        guard let pngData = normalizedPNGData(from: data) else { return .unsupported }
        guard pngData.count <= Self.maximumImageBytes else { return .tooLarge }
        guard makeRoom() else { return .allItemsPinned }
        let item = Item(id: UUID(), kind: .image, text: nil, imageFilename: "\(UUID().uuidString).png", createdAt: now(), isPinned: false)
        guard let filename = item.imageFilename else { return .unsupported }
        do {
            try ensureDirectories()
            try pngData.write(to: imagesURL.appendingPathComponent(filename), options: .atomic)
            items.insert(item, at: 0)
            persist()
            return .added(item)
        } catch {
            return .unsupported
        }
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = pinned
        persist()
    }

    func delete(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        remove(items.remove(at: index))
        persist()
    }

    func deleteAll() {
        let deleted = items
        items.removeAll()
        deleted.forEach(remove)
        persist()
    }

    func filteredItems(matching query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            if item.kind == .image {
                return "image".localizedCaseInsensitiveContains(query)
            }
            return item.text?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func sweepExpired() {
        let cutoff = now().addingTimeInterval(-Self.unpinnedLifetime)
        let expired = items.filter { !$0.isPinned && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        items.removeAll { item in expired.contains(where: { $0.id == item.id }) }
        expired.forEach(remove)
        persist()
    }

    func imageURL(for item: Item) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }

    private func makeRoom() -> Bool {
        while items.count >= Self.maximumItems {
            guard let index = items.indices.reversed().first(where: { !items[$0].isPinned }) else { return false }
            remove(items.remove(at: index))
        }
        return true
    }

    private func load() {
        defer { sweepExpired() }
        guard let data = try? Data(contentsOf: metadataURL), let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
        let countBeforeEviction = items.count
        _ = makeRoom()
        if items.count != countBeforeEviction {
            persist()
        }
    }

    private func persist() {
        do {
            try ensureDirectories()
            try JSONEncoder().encode(items).write(to: metadataURL, options: .atomic)
        } catch {
            assertionFailure("Paste Shelf persistence failed: \(error)")
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    private func remove(_ item: Item) {
        guard let url = imageURL(for: item) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        return types.lazy.compactMap { pasteboard.data(forType: $0) }.first
    }

    /// Shelf assets are always PNG, irrespective of the original pasteboard
    /// representation. This keeps the on-disk extension and preview decoder
    /// deterministic while avoiding a dependency on a source UTType.
    private func normalizedPNGData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("term-mesh", isDirectory: true)
    }
}

extension Notification.Name {
    /// Opens the Shelf over a specific terminal pane without changing first responder.
    static let pasteShelfToggleRequested = Notification.Name("termMesh.pasteShelfToggleRequested")
}
