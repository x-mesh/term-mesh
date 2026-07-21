import AppKit
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class PasteShelfStoreTests: XCTestCase {
    private var directory: URL!
    private var currentDate: Date!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        currentDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store() -> PasteShelfStore {
        PasteShelfStore(directoryURL: directory, now: { self.currentDate })
    }

    func testEvictsOldestUnpinnedAtCapacity() {
        let store = store()
        for index in 0..<PasteShelfStore.maximumItems {
            currentDate = currentDate.addingTimeInterval(1)
            _ = store.addText("item-\(index)")
        }
        _ = store.addText("newest")

        XCTAssertEqual(store.items.count, PasteShelfStore.maximumItems)
        XCTAssertFalse(store.items.contains { $0.text == "item-0" })
        XCTAssertEqual(store.items.first?.text, "newest")
    }

    func testRejectsCaptureWhenEveryItemIsPinned() {
        let store = store()
        for index in 0..<PasteShelfStore.maximumItems {
            guard case let .added(item) = store.addText("item-\(index)") else { return XCTFail() }
            store.setPinned(true, id: item.id)
        }
        XCTAssertEqual(store.addText("overflow"), .allItemsPinned)
    }

    func testReloadPersistsPinnedItemAndImageAsset() {
        let first = store()
        guard case let .added(text) = first.addText("persisted text"),
              case let .added(image) = first.addImage(onePixelPNG()),
              let imageURL = first.imageURL(for: image)
        else { return XCTFail() }
        first.setPinned(true, id: text.id)

        let reloaded = store()

        XCTAssertEqual(reloaded.items.map(\.id), [image.id, text.id])
        XCTAssertTrue(reloaded.items.first(where: { $0.id == text.id })?.isPinned == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testSweepRemovesExpiredUnpinnedAndKeepsPinned() {
        let store = store()
        guard case let .added(expired) = store.addText("expired"),
              case let .added(pinned) = store.addText("pinned") else { return XCTFail() }
        store.setPinned(true, id: pinned.id)
        currentDate = currentDate.addingTimeInterval(PasteShelfStore.unpinnedLifetime + 1)
        store.sweepExpired()

        XCTAssertFalse(store.items.contains { $0.id == expired.id })
        XCTAssertTrue(store.items.contains { $0.id == pinned.id })
    }

    func testSweepRemovesExpiredImageAsset() {
        let store = store()
        guard case let .added(image) = store.addImage(onePixelPNG()),
              let imageURL = store.imageURL(for: image)
        else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        currentDate = currentDate.addingTimeInterval(PasteShelfStore.unpinnedLifetime + 1)
        store.sweepExpired()

        XCTAssertFalse(store.items.contains { $0.id == image.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testImportsImageClipboardOnlyOncePerChange() {
        let store = store()
        let pasteboard = NSPasteboard(name: .init("term-mesh.test.paste-shelf.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG(), forType: .png)

        guard case .added = store.captureImageIfNeeded(from: pasteboard) else {
            return XCTFail("Expected image clipboard capture")
        }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.captureImageIfNeeded(from: pasteboard), .unsupported)
        XCTAssertEqual(store.items.count, 1)
    }

    func testSearchMatchesTextAndImageItems() {
        let store = store()
        _ = store.addText("deploy checklist")
        _ = store.addText("incident notes")
        _ = store.addImage(onePixelPNG())

        XCTAssertEqual(store.filteredItems(matching: "DEPLOY").map(\.text), ["deploy checklist"])
        XCTAssertEqual(store.filteredItems(matching: "image").map(\.kind), [.image])
    }

    func testDeleteAllRemovesSavedImageAssets() {
        let store = store()
        guard case let .added(image) = store.addImage(onePixelPNG()),
              let imageURL = store.imageURL(for: image)
        else { return XCTFail() }

        store.deleteAll()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    // MARK: - Shelf attachment path rewriting (peer submit)

    /// Every attachment must be rewritten, not just the first — a path left
    /// pointing at the viewer's disk resolves to nothing on the peer.
    func test_rewritingShelfPaths_rewritesEveryAttachment() {
        let text = "look at /tmp/a.png and /tmp/b.png"
        let rewritten = TerminalSurface.rewritingShelfPaths(
            in: text,
            with: [
                (local: "/tmp/a.png", remote: "/remote/a.png"),
                (local: "/tmp/b.png", remote: "/remote/b.png"),
            ]
        )

        XCTAssertEqual(rewritten, "look at /remote/a.png and /remote/b.png")
    }

    /// One attachment path prefixing another must not corrupt the longer one.
    /// The transfer names remote files independently, so the remote path does
    /// not mirror the local one — rewriting the short path first would leave a
    /// spliced `/remote/x.png.orig` that points at nothing.
    func test_rewritingShelfPaths_prefixPathDoesNotCorruptLongerPath() {
        let text = "/tmp/a.png plus /tmp/a.png.orig"
        let rewritten = TerminalSurface.rewritingShelfPaths(
            in: text,
            with: [
                (local: "/tmp/a.png", remote: "/remote/x.png"),
                (local: "/tmp/a.png.orig", remote: "/remote/y.png"),
            ]
        )

        XCTAssertEqual(rewritten, "/remote/x.png plus /remote/y.png")
    }

    // MARK: - Overlay selection clamping

    /// The overlay renders filtered items, so the selection has to be clamped
    /// against the filtered count. Clamping against the full store leaves the
    /// selection past the last visible row and Enter silently doing nothing.
    @MainActor
    func test_overlaySelection_clampsToFilteredCountAfterDelete() {
        let state = PasteShelfOverlayState()
        state.moveSelection(by: 2, itemCount: 3)
        XCTAssertEqual(state.selectedIndex, 2)

        // Search narrowed the list to 3 rows; deleting the selected one leaves 2.
        state.reset(itemCount: 2)

        XCTAssertEqual(state.selectedIndex, 1, "selection must stay inside the visible rows")
    }

    private func onePixelPNG() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return bitmap.representation(using: .png, properties: [:])!
    }
}
