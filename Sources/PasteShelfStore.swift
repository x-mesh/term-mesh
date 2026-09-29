import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local-only, explicitly captured paste items. This is deliberately not a
/// clipboard monitor: callers must invoke `capture(from:)` themselves.
@MainActor
final class PasteShelfStore: ObservableObject {
    static let shared = PasteShelfStore()
    static let maximumItems = 20
    static let unpinnedLifetime: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let maximumImageBytes = 20 * 1024 * 1024

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
        /// SHA-256 of the stored PNG. Items saved before image dedupe have none.
        var contentHash: String? = nil
    }

    enum CaptureResult: Equatable {
        case added(Item)
        case unsupported
        case tooLarge
        case allItemsPinned
        case storageFailed
    }

    /// An image already normalized, hashed and written to the images
    /// directory, waiting to be published on the main actor.
    enum PreparedImage {
        case ready(filename: String, contentHash: String)
        case failed(CaptureResult)
    }

    @Published private(set) var items: [Item] = []

    private let directoryURL: URL
    private let metadataURL: URL
    private let imagesURL: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private var lastCapturedImagePasteboardChangeCount: Int?
    private var inFlightImagePasteboardChangeCount: Int?
    /// Bumped by `deleteAll()`. An image still being prepared when the user
    /// clears the Shelf was copied before that, so it must not reappear.
    private var clearGeneration = 0

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

    /// `captureText` defaults to the user setting, resolved per call. Copied
    /// images are always taken — only the plaintext-on-disk path is opt-out.
    func capture(
        from pasteboard: NSPasteboard = .general,
        captureText: Bool = PasteShelfCaptureSettings.captureTextEnabled()
    ) async -> CaptureResult {
        sweepExpired()

        if captureText, let text = pasteboard.string(forType: .string), !text.isEmpty {
            return addText(text)
        }
        guard let data = Self.imageData(from: pasteboard) else { return .unsupported }
        return await addImageInBackground(data)
    }

    /// Imports an image copied by any macOS app when Shelf is opened. The
    /// pasteboard change count prevents re-adding the same image on every open.
    @discardableResult
    func captureImageIfNeeded(from pasteboard: NSPasteboard = .general) async -> CaptureResult {
        sweepExpired()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastCapturedImagePasteboardChangeCount,
              changeCount != inFlightImagePasteboardChangeCount,
              let data = Self.imageData(from: pasteboard)
        else { return .unsupported }

        inFlightImagePasteboardChangeCount = changeCount
        let generation = clearGeneration
        let result = await addImageInBackground(data)
        if inFlightImagePasteboardChangeCount == changeCount {
            inFlightImagePasteboardChangeCount = nil
        }
        // A capture the user cleared still consumed this clipboard image;
        // reopening the Shelf must not bring it back.
        if case .added = result {
            lastCapturedImagePasteboardChangeCount = changeCount
        } else if generation != clearGeneration {
            lastCapturedImagePasteboardChangeCount = changeCount
        }
        return result
    }

    /// Copying text that is already on the Shelf brings that item back to the
    /// top instead of spending a second slot on it.
    @discardableResult
    func addText(_ text: String) -> CaptureResult {
        if let existing = items.first(where: { $0.kind == .text && $0.text == text }) {
            return moveToTop(existing)
        }
        let room = plannedTrim(items, to: Self.maximumItems - 1)
        guard room.fits else { return .allItemsPinned }
        let item = Item(id: UUID(), kind: .text, text: text, imageFilename: nil, createdAt: now(), isPinned: false)
        guard commit([item] + room.kept, removing: room.evicted) else { return .storageFailed }
        return .added(item)
    }

    @discardableResult
    func addImage(_ data: Data) -> CaptureResult {
        commitImage(Self.prepareImage(data, in: imagesURL, fileManager: fileManager))
    }

    /// Normalizing, hashing and writing a large capture takes about half a
    /// second (measured with a 5K image), so that work runs off the main
    /// thread and only the finished item is published here.
    func addImageInBackground(_ data: Data) async -> CaptureResult {
        let imagesURL = imagesURL
        let fileManager = fileManager
        let generation = clearGeneration
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareImage(data, in: imagesURL, fileManager: fileManager)
        }.value
        guard generation == clearGeneration else {
            if case let .ready(filename, _) = prepared {
                try? fileManager.removeItem(at: imagesURL.appendingPathComponent(filename))
            }
            return .unsupported
        }
        return commitImage(prepared)
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isPinned = pinned
        commit(updated, removing: [])
    }

    func delete(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        commit(items.filter { $0.id != id }, removing: [item])
    }

    func deleteAll() {
        clearGeneration += 1
        commit([], removing: items)
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
        let expiredIDs = Set(expired.map(\.id))
        commit(items.filter { !expiredIDs.contains($0.id) }, removing: expired)
    }

    func imageURL(for item: Item) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }

    private func moveToTop(_ existing: Item) -> CaptureResult {
        let refreshed = Item(
            id: existing.id,
            kind: existing.kind,
            text: existing.text,
            imageFilename: existing.imageFilename,
            createdAt: now(),
            isPinned: existing.isPinned,
            contentHash: existing.contentHash
        )
        guard commit([refreshed] + items.filter { $0.id != existing.id }, removing: []) else {
            return .storageFailed
        }
        return .added(refreshed)
    }

    private func commitImage(_ prepared: PreparedImage) -> CaptureResult {
        let filename: String
        let contentHash: String
        switch prepared {
        case let .failed(result):
            return result
        case let .ready(readyFilename, readyHash):
            filename = readyFilename
            contentHash = readyHash
        }
        let fileURL = imagesURL.appendingPathComponent(filename)

        if let existing = items.first(where: { $0.kind == .image && $0.contentHash == contentHash }) {
            try? fileManager.removeItem(at: fileURL)
            return moveToTop(existing)
        }
        let room = plannedTrim(items, to: Self.maximumItems - 1)
        guard room.fits else {
            try? fileManager.removeItem(at: fileURL)
            return .allItemsPinned
        }
        let item = Item(
            id: UUID(),
            kind: .image,
            text: nil,
            imageFilename: filename,
            createdAt: now(),
            isPinned: false,
            contentHash: contentHash
        )
        guard commit([item] + room.kept, removing: room.evicted) else {
            try? fileManager.removeItem(at: fileURL)
            return .storageFailed
        }
        return .added(item)
    }

    /// Oldest-first eviction plan down to `limit`. `fits` is false when only
    /// pinned items are left and the limit is still exceeded.
    private func plannedTrim(_ source: [Item], to limit: Int) -> (kept: [Item], evicted: [Item], fits: Bool) {
        var kept = source
        var evicted: [Item] = []
        while kept.count > limit {
            guard let index = kept.indices.reversed().first(where: { !kept[$0].isPinned }) else {
                return (kept, evicted, false)
            }
            evicted.append(kept.remove(at: index))
        }
        return (kept, evicted, true)
    }

    /// Metadata is written before anything is published or deleted, so a
    /// failed write leaves memory, metadata and image files agreeing: the
    /// previous state stays, and no evicted image is lost for an item that
    /// the metadata on disk still lists.
    @discardableResult
    private func commit(_ newItems: [Item], removing removed: [Item]) -> Bool {
        do {
            try writeMetadata(newItems)
        } catch {
            NSLog("Paste Shelf: saving %@ failed: %@", metadataURL.path, String(describing: error))
            return false
        }
        items = newItems
        removed.forEach(removeAsset)
        return true
    }

    private func load() {
        defer { sweepExpired() }
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            // With no metadata, any image on disk is left over from a save
            // that never completed.
            removeOrphanedAssets()
            return
        }
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([Item].self, from: data)
        else {
            // Unreadable metadata may still describe the images on disk, so
            // they are left alone rather than treated as orphans.
            NSLog("Paste Shelf: %@ is unreadable; keeping image files", metadataURL.path)
            return
        }

        let present = decoded.filter { item in
            guard item.kind == .image else { return true }
            return imageURL(for: item).map { fileManager.fileExists(atPath: $0.path) } ?? false
        }
        items = present.sorted { $0.createdAt > $1.createdAt }
        // Nothing is being inserted here, so only genuinely over-capacity
        // items may go. Trimming to `maximumItems - 1` would drop one item on
        // every launch that started at exactly `maximumItems`.
        let trimmed = plannedTrim(items, to: Self.maximumItems)
        if trimmed.kept.count != decoded.count {
            commit(trimmed.kept, removing: trimmed.evicted)
        }
        removeOrphanedAssets()
        restrictExistingFilePermissions()
    }

    /// The replacement file gets its permissions before it takes the
    /// metadata's name, so the save either lands whole and private or not at
    /// all; a permission change after the write could fail with the new
    /// metadata already on disk.
    private func writeMetadata(_ items: [Item]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        let replacementURL = directoryURL.appendingPathComponent(".paste-shelf-\(UUID().uuidString).json")
        guard fileManager.createFile(
            atPath: replacementURL.path,
            contents: data,
            attributes: [.posixPermissions: Self.privateFilePermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: replacementURL.path])
        }
        guard rename(replacementURL.path, metadataURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fileManager.removeItem(at: replacementURL)
            throw POSIXError(code)
        }
    }

    private func removeAsset(_ item: Item) {
        guard let url = imageURL(for: item) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Release and Debug builds share this directory and can run at the same
    /// time, so a file missing from this instance's metadata may be another
    /// instance's live item or in-flight capture. Only files older than any
    /// unpinned item can live are removed.
    private func removeOrphanedAssets() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: imagesURL.path) else { return }
        let referenced = Set(items.compactMap(\.imageFilename))
        let cutoff = now().addingTimeInterval(-Self.unpinnedLifetime)
        for name in names where name.hasSuffix(".png") && !referenced.contains(name) {
            let url = imagesURL.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Files written before the Shelf restricted its permissions were created
    /// with the default umask and can be readable by other local users.
    private func restrictExistingFilePermissions() {
        let privateFile: [FileAttributeKey: Any] = [.posixPermissions: Self.privateFilePermissions]
        try? fileManager.setAttributes(privateFile, ofItemAtPath: metadataURL.path)
        if fileManager.fileExists(atPath: imagesURL.path) {
            try? fileManager.setAttributes([.posixPermissions: Self.privateDirectoryPermissions], ofItemAtPath: imagesURL.path)
        }
        for item in items {
            guard let url = imageURL(for: item) else { continue }
            try? fileManager.setAttributes(privateFile, ofItemAtPath: url.path)
        }
    }

    /// Captured text and images can hold secrets, so the Shelf's own files
    /// are readable only by the user. The parent directory is shared with
    /// other term-mesh state and keeps its permissions.
    nonisolated private static let privateFilePermissions = 0o600
    nonisolated private static let privateDirectoryPermissions = 0o700

    nonisolated private static func prepareImage(
        _ data: Data,
        in imagesURL: URL,
        fileManager: FileManager
    ) -> PreparedImage {
        guard let pngData = normalizedPNGData(from: data) else { return .failed(.unsupported) }
        guard pngData.count <= maximumImageBytes else { return .failed(.tooLarge) }
        let contentHash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let filename = "\(UUID().uuidString).png"
        let fileURL = imagesURL.appendingPathComponent(filename)
        do {
            if !fileManager.fileExists(atPath: imagesURL.path) {
                try fileManager.createDirectory(
                    at: imagesURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: privateDirectoryPermissions]
                )
            }
            try pngData.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: privateFilePermissions], ofItemAtPath: fileURL.path)
            return .ready(filename: filename, contentHash: contentHash)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return .failed(.storageFailed)
        }
    }

    nonisolated private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        return types.lazy.compactMap { pasteboard.data(forType: $0) }.first
    }

    /// Shelf assets are always PNG, irrespective of the original pasteboard
    /// representation. This keeps the on-disk extension and preview decoder
    /// deterministic while avoiding a dependency on a source UTType. PNG input
    /// is kept byte for byte: re-encoding it is a full decode and encode of
    /// the same pixels.
    nonisolated private static func normalizedPNGData(from data: Data) -> Data? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetType(source) as String? == UTType.png.identifier,
           CGImageSourceGetCount(source) > 0 {
            return data
        }
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
