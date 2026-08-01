import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Covers the two blockers found in #132's exact-SHA review of
/// "authenticate peer CLI binary paths per capability":
///
/// 1. `connectionState` flips to `.connected` synchronously (lease
///    acquired), but the authenticated `hostCLIBinDirs` only land after a
///    second async round trip inside `fetchWorkspaces`. A launch gated on
///    `isConnected` alone can race that window and start a remote CLI with
///    an empty PATH addition — the fixed `/Applications/term-mesh.app/...`
///    entry this PR removed is gone, so there is no more fallback.
///    `HostEntry.isLaunchable` closes the gap; this file pins its truth
///    table so the race stays fixed even if `isLaunchable`'s definition is
///    ever "simplified" back to `isConnected`.
///
/// 2. The host editor's readiness check falls back to a previous
///    connection's cached `hostCLIBinDirs` when a fresh doctor run fails.
///    Matching on `profileID` alone (the pre-fix behavior) can leak a
///    stale connection's authenticated directories onto a since-edited
///    endpoint that connection never reached, because a profile's id is
///    stable across edits to its sshTarget/port/identityFile/socket.
@MainActor
final class PeerHostCLIBinDirsReadinessTests: XCTestCase {

    // MARK: - Helpers

    private func host(
        id: String = "ssh:root@jw-server",
        connectionState: HostConnectionState = .connected,
        sshTarget: String? = "root@jw-server",
        remoteSockPath: String? = "/tmp/peer.sock",
        sshPort: Int? = nil,
        identityFile: String? = nil,
        profileID: UUID? = nil,
        hostCLIBinDirs: [String] = [],
        hostCLIBinDirsResolved: Bool = false
    ) -> HostEntry {
        var entry = HostEntry(
            id: id,
            displayName: "jw-server",
            connectionState: connectionState,
            workspaces: [],
            activeSockPath: "/tmp/active.sock",
            sshTarget: sshTarget,
            remoteSockPath: remoteSockPath,
            sshPort: sshPort,
            identityFile: identityFile,
            profileID: profileID
        )
        entry.hostCLIBinDirs = hostCLIBinDirs
        entry.hostCLIBinDirsResolved = hostCLIBinDirsResolved
        return entry
    }

    // MARK: - 1. Readiness race: isConnected vs. isLaunchable

    /// The exact race window: lease acquired (`.connected`) but the
    /// handshake's authenticated bin dirs have not landed yet. A caller
    /// still checking `isConnected` alone would proceed to launch here.
    func testConnectedButUnresolvedBinDirsIsNotLaunchable() {
        let entry = host(connectionState: .connected, hostCLIBinDirsResolved: false)

        XCTAssertTrue(entry.isConnected, "connectionState alone reports connected")
        XCTAssertFalse(
            entry.isLaunchable,
            "authenticated bin dirs have not landed yet — launching now races an empty PATH addition"
        )
    }

    /// Once `fetchWorkspaces` completes its round trip and stamps
    /// `hostCLIBinDirsResolved = true` (regardless of whether the host
    /// reported zero directories — that is a legitimate authenticated
    /// answer, not "still pending"), the host becomes launchable.
    func testConnectedWithResolvedBinDirsIsLaunchableEvenWhenEmpty() {
        let entry = host(
            connectionState: .connected,
            hostCLIBinDirs: [],
            hostCLIBinDirsResolved: true
        )

        XCTAssertTrue(
            entry.isLaunchable,
            "an authenticated empty answer is resolved, not pending — must not block launch forever"
        )
    }

    func testConnectedWithResolvedNonEmptyBinDirsIsLaunchable() {
        let entry = host(
            connectionState: .connected,
            hostCLIBinDirs: ["/home/root/.local/bin"],
            hostCLIBinDirsResolved: true
        )

        XCTAssertTrue(entry.isLaunchable)
    }

    /// A host that never reached `.connected` is neither connected nor
    /// launchable, independent of whatever stale bin dirs it may carry
    /// from a prior session.
    func testDisconnectedHostIsNeverLaunchable() {
        let entry = host(
            connectionState: .saved,
            hostCLIBinDirs: ["/home/root/.local/bin"],
            hostCLIBinDirsResolved: true
        )

        XCTAssertFalse(entry.isConnected)
        XCTAssertFalse(entry.isLaunchable)
    }

    // MARK: - 2. Cached CLI metadata must match the exact endpoint tuple

    private let profileID = UUID()

    func testCachedBinDirsReusedWhenEndpointTupleMatchesExactly() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                sshPort: 22,
                identityFile: "/Users/x/.ssh/id_ed25519",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: 22,
            identityFile: "/Users/x/.ssh/id_ed25519",
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, ["/home/root/.local/bin"])
    }

    /// The profile id did not change, but its sshTarget did — the
    /// pre-fix behavior (`profileID`-only matching) would still return
    /// the old connection's authenticated directories here, which is
    /// exactly the stale-cache leak the review flagged.
    func testStaleCacheNotReusedWhenSSHTargetChanged() {
        let hosts = [
            host(
                sshTarget: "root@old-server",
                remoteSockPath: "/tmp/peer.sock",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@new-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [], "sshTarget changed — must not leak the old endpoint's bin dirs")
    }

    func testStaleCacheNotReusedWhenPortChanged() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                sshPort: 22,
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: 2222,
            identityFile: nil,
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [], "port changed — must not leak the old endpoint's bin dirs")
    }

    func testStaleCacheNotReusedWhenIdentityFileChanged() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                identityFile: "/Users/x/.ssh/id_ed25519",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: "/Users/x/.ssh/id_other",
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [], "identityFile changed — must not leak the old endpoint's bin dirs")
    }

    func testStaleCacheNotReusedWhenPinnedRemoteSocketChanged() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer-a.sock",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "/tmp/peer-b.sock",
            in: hosts
        )

        XCTAssertEqual(result, [], "pinned remote socket changed — must not leak the old endpoint's bin dirs")
    }

    /// An unedited, still-empty `remoteSocket` (auto-detect) is a stable
    /// identity even though the live connection resolved it to a concrete
    /// path — that resolution is not a user-visible edit, so it must not
    /// be treated as an endpoint change.
    func testAutoDetectRemoteSocketStillMatchesResolvedPath() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/auto-resolved.sock",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "",
            in: hosts
        )

        XCTAssertEqual(result, ["/home/root/.local/bin"])
    }

    /// A different profile id must never match, even with an identical
    /// endpoint tuple — this is the "another profile can reuse the same
    /// sshTarget" case the original doc comment already called out.
    func testDifferentProfileIDNeverMatchesEvenWithIdenticalEndpoint() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                profileID: UUID(),
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [])
    }

    /// A connection that is still resolving its bin dirs (the readiness
    /// race from part 1) must not be treated as a valid cache source
    /// either — its `hostCLIBinDirs` is a transient default, not an
    /// authenticated answer yet.
    func testUnresolvedConnectionNeverReusedAsCache() {
        let hosts = [
            host(
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                profileID: profileID,
                hostCLIBinDirs: [],
                hostCLIBinDirsResolved: false
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [])
    }

    /// A disconnected host — even one whose endpoint tuple still matches
    /// exactly and once carried authenticated dirs — is not a live
    /// connection to trust.
    func testDisconnectedHostNeverReusedAsCache() {
        let hosts = [
            host(
                connectionState: .saved,
                sshTarget: "root@jw-server",
                remoteSockPath: "/tmp/peer.sock",
                profileID: profileID,
                hostCLIBinDirs: ["/home/root/.local/bin"],
                hostCLIBinDirsResolved: true
            ),
        ]

        let result = RemoteHostStore.hostCLIBinDirs(
            forProfileID: profileID,
            sshTarget: "root@jw-server",
            port: nil,
            identityFile: nil,
            remoteSocket: "/tmp/peer.sock",
            in: hosts
        )

        XCTAssertEqual(result, [])
    }
}
