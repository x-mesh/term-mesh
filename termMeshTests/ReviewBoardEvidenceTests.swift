import CryptoKit
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ReviewBoardEvidenceTests: XCTestCase {

    // MARK: - The digest definition

    /// Nothing produced a `diff_digest` before this: the coordinator validated
    /// the `sha256:` prefix and never the content, and every value it had seen
    /// was a test literal. The definition therefore has to be pinned here, or
    /// two callers can each be "correct" and still disagree.
    func test_the_digest_is_sha256_over_the_patch_bytes() {
        let patch = Data("diff --git a/x b/x\n+one\n".utf8)
        let expected = SHA256.hash(data: patch)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(ReviewBoardEvidence.digest(forPatch: patch), "sha256:\(expected)")
        // The prefix is not decoration — the coordinator rejects a digest
        // without it (api.rs:1028-1036).
        XCTAssertTrue(ReviewBoardEvidence.digest(forPatch: patch).hasPrefix("sha256:"))
    }

    /// Bytes, not a decoded string. A patch touching a binary file or a
    /// non-UTF-8 encoding does not survive a round trip through `String`, and
    /// a digest that changes depending on whether the bytes happened to decode
    /// is not evidence of anything.
    func test_the_digest_survives_bytes_that_are_not_text() {
        let invalidUTF8 = Data([0x64, 0x69, 0x66, 0x66, 0xFF, 0xFE, 0x0A])
        let digest = ReviewBoardEvidence.digest(forPatch: invalidUTF8)
        // Round-tripping through String would replace the bad bytes and
        // produce a different hash — this is that difference, asserted.
        let lossy = Data(String(decoding: invalidUTF8, as: UTF8.self).utf8)
        XCTAssertNotEqual(digest, ReviewBoardEvidence.digest(forPatch: lossy))
    }

    // MARK: - Reading a real worktree

    /// The whole point: run it against an actual repository. A parser test
    /// over hand-written fixtures would pass while `git diff` is invoked with
    /// the wrong range.
    func test_reading_a_branch_reports_its_own_commits_only() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        try git(repo, "checkout", "-b", "feature")
        try write(repo, "added.txt", "new file\n")
        try write(repo, "seed.txt", "seed\nchanged\n")
        try git(repo, "add", "-A")
        try git(repo, "commit", "-m", "feature work")

        // A commit that lands on the parent AFTER the branch was cut. Diffing
        // against the parent's tip would drag it in; merge-base must not.
        try git(repo, "checkout", "main")
        try write(repo, "elsewhere.txt", "somebody else\n")
        try git(repo, "add", "-A")
        try git(repo, "commit", "-m", "unrelated")
        try git(repo, "checkout", "feature")

        let patch = try await ReviewBoardEvidence.read(worktreePath: repo, parentRef: "main")

        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(patch.headSHA, try output(repo, "rev-parse", "HEAD"))
        XCTAssertEqual(patch.baseSHA, try output(repo, "merge-base", "main", "HEAD"))

        let paths = Set(patch.files.map(\.path))
        XCTAssertEqual(paths, ["added.txt", "seed.txt"])
        XCTAssertFalse(
            paths.contains("elsewhere.txt"),
            "the parent moved on; its commits are not part of this review"
        )

        let added = try XCTUnwrap(patch.files.first { $0.path == "added.txt" })
        XCTAssertEqual(added.kind, "added")
        XCTAssertEqual(added.add, 1)
        XCTAssertEqual(added.del, 0)

        let modified = try XCTUnwrap(patch.files.first { $0.path == "seed.txt" })
        XCTAssertEqual(modified.kind, "modified")

        XCTAssertTrue(patch.text.contains("added.txt"))
        XCTAssertFalse(patch.isTruncated)
    }

    /// The digest the coordinator will re-check has to be the hash of the
    /// patch git actually produced — computed independently here rather than
    /// trusted from the same code path that made it.
    func test_the_reported_digest_matches_git_diff_itself() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        try git(repo, "checkout", "-b", "feature")
        try write(repo, "seed.txt", "seed\nmore\n")
        try git(repo, "add", "-A")
        try git(repo, "commit", "-m", "change")

        let patch = try await ReviewBoardEvidence.read(worktreePath: repo, parentRef: "main")
        let raw = try outputData(repo, "diff", "\(patch.baseSHA)..\(patch.headSHA)")

        XCTAssertEqual(patch.digest, ReviewBoardEvidence.digest(forPatch: raw))
    }

    /// Without a parent there is no base, and guessing one would silently
    /// review the last commit instead of the branch.
    func test_a_worktree_with_no_parent_is_refused_rather_than_guessed() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        for parent in [nil, "", "   "] as [String?] {
            do {
                _ = try await ReviewBoardEvidence.read(worktreePath: repo, parentRef: parent)
                XCTFail("expected a refusal for parentRef \(String(describing: parent))")
            } catch let error as ReviewBoardEvidenceError {
                XCTAssertEqual(error, .unknownBase)
            }
        }
    }

    /// A missing worktree is a reported failure, not a crash and not an empty
    /// patch that would read as "nothing changed".
    func test_a_missing_worktree_reports_the_failure() async throws {
        do {
            _ = try await ReviewBoardEvidence.read(
                worktreePath: "/definitely/not/here-\(UUID().uuidString)",
                parentRef: "main"
            )
            XCTFail("expected a failure")
        } catch let error as ReviewBoardEvidenceError {
            guard case .commandFailed = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
    }

    // MARK: - Parsing

    /// A binary file reports `-` for both counts rather than a number, and a
    /// rename reports two paths — the new one is what a reviewer opens.
    func test_numstat_shapes_that_are_not_two_numbers_and_a_path() throws {
        let files = ReviewBoardEvidence.summarize(
            numstat: "-\t-\tassets/logo.png\n3\t1\tnew/name.swift\n",
            nameStatus: "A\tassets/logo.png\nR094\told/name.swift\tnew/name.swift\n"
        )
        XCTAssertEqual(files.count, 2)

        let binary = try XCTUnwrap(files.first { $0.path == "assets/logo.png" })
        XCTAssertEqual(binary.add, 0, "a dash is not a count")
        XCTAssertEqual(binary.kind, "added")

        let renamed = try XCTUnwrap(files.first { $0.path == "new/name.swift" })
        XCTAssertEqual(renamed.kind, "renamed", "a rename reports two paths; the new one is opened")
        XCTAssertEqual(renamed.add, 3)
    }

    /// The rpc shape `review.snapshot` takes.
    func test_a_file_summary_serializes_the_way_the_coordinator_reads_it() {
        let value = ReviewBoardEvidence.FileSummary(
            path: "a.swift", kind: "modified", add: 2, del: 1
        ).rpcValue
        XCTAssertEqual(value["path"] as? String, "a.swift")
        XCTAssertEqual(value["kind"] as? String, "modified")
        XCTAssertEqual(value["add"] as? Int, 2)
        XCTAssertEqual(value["del"] as? Int, 1)
    }

    // MARK: - Helpers

    private func makeRepo() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tm-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(path, "init", "-q", "-b", "main")
        try git(path, "config", "user.name", "t")
        try git(path, "config", "user.email", "t@t")
        try write(path, "seed.txt", "seed\n")
        try git(path, "add", "-A")
        try git(path, "commit", "-q", "-m", "seed")
        return path
    }

    private func write(_ repo: String, _ name: String, _ contents: String) throws {
        try contents.write(
            toFile: (repo as NSString).appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    @discardableResult
    private func git(_ repo: String, _ arguments: String...) throws -> String {
        try output(repo, arguments)
    }

    private func output(_ repo: String, _ arguments: String...) throws -> String {
        try output(repo, arguments)
    }

    private func output(_ repo: String, _ arguments: [String]) throws -> String {
        String(decoding: try outputData(repo, arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func outputData(_ repo: String, _ arguments: String...) throws -> Data {
        try outputData(repo, arguments)
    }

    private func outputData(_ repo: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: - A patch read off a peer

    /// The peer sends the digest because only the machine holding the worktree
    /// has the untruncated bytes to compute it over. Everything else is raw
    /// git output run through the same parser the local path uses, so both
    /// produce the identical shape — a differently-shaped peer patch would
    /// give the coordinator a digest it could never match.
    func testAPeerPayloadDecodesToTheSameShapeALocalReadProduces() throws {
        // Built rather than pasted: git's numstat and name-status are
        // tab-separated, and a literal tab inside a JSON string is not JSON.
        let payload: [String: Any] = [
            "head_sha": "bbbb2222", "base_sha": "aaaa1111", "branch": "feat/thing",
            "diff_digest": "sha256:cafebabe",
            "numstat": ["3\t1\tSources/a.swift", "0\t9\tdocs/old.md"].joined(separator: "\n"),
            "name_status": ["M\tSources/a.swift", "D\tdocs/old.md"].joined(separator: "\n"),
            "patch": "diff --git a/Sources/a.swift b/Sources/a.swift\n",
            "truncated": false,
        ]
        let json = String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8
        )!
        let patch = try XCTUnwrap(ReviewBoardEvidence.Patch(peerResponse: json))

        XCTAssertEqual(patch.headSHA, "bbbb2222")
        XCTAssertEqual(patch.baseSHA, "aaaa1111")
        XCTAssertEqual(patch.digest, "sha256:cafebabe")
        XCTAssertFalse(patch.isTruncated)
        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(patch.files.map(\.path), ["Sources/a.swift", "docs/old.md"])
        XCTAssertEqual(patch.files.map(\.kind), ["modified", "deleted"])
        XCTAssertEqual(patch.files.map(\.add), [3, 0])
        XCTAssertEqual(patch.files.map(\.del), [1, 9])
    }

    /// A truncated patch has to say so. The digest still covers everything,
    /// which is the only reason showing an excerpt is safe.
    func testATruncatedPeerPatchKeepsTheDigestOverTheWhole() throws {
        let json = #"{"head_sha":"b","base_sha":"a","diff_digest":"sha256:ff","patch":"...","truncated":true}"#
        let patch = try XCTUnwrap(ReviewBoardEvidence.Patch(peerResponse: json))
        XCTAssertTrue(patch.isTruncated)
        XCTAssertEqual(patch.digest, "sha256:ff")
        XCTAssertTrue(patch.isEmpty, "no numstat means no files, which reads as nothing to review")
    }

    /// A payload without a usable digest is refused rather than decoded into a
    /// patch that would be approved against nothing.
    func testAPayloadMissingWhatAnApprovalCitesIsRejected() {
        let cases = [
            #"{"base_sha":"a","diff_digest":"sha256:ff"}"#,
            #"{"head_sha":"b","diff_digest":"sha256:ff"}"#,
            #"{"head_sha":"b","base_sha":"a"}"#,
            #"{"head_sha":"","base_sha":"a","diff_digest":"sha256:ff"}"#,
            // An unprefixed digest is not the algorithm the coordinator compares.
            #"{"head_sha":"b","base_sha":"a","diff_digest":"ff"}"#,
            "not json at all",
        ]
        for json in cases {
            XCTAssertNil(
                ReviewBoardEvidence.Patch(peerResponse: json),
                "must not decode: \(json)"
            )
        }
    }

    /// The bytes a real host actually sent.
    ///
    /// Captured off jw-server over an SSH-forwarded peer socket
    /// (`peer/server.rs::a_patch_can_be_read_off_another_machine`), so this
    /// pins the decoder against the wire rather than against a fixture someone
    /// wrote to match it. The digest is the host's own
    /// `git diff main..HEAD | sha256sum`, which is what an approval cites.
    func testTheDecoderReadsWhatARealHostSent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-task-diff.json")
        let json = try String(contentsOf: url, encoding: .utf8)
        let patch = try XCTUnwrap(ReviewBoardEvidence.Patch(peerResponse: json))

        XCTAssertEqual(patch.headSHA, "74724e88cb570b20d7cd980b944fac1d5cdeb986")
        XCTAssertEqual(patch.baseSHA, "8a9efb1776d7d898b46b9b5630f1d9960d6a4f56")
        XCTAssertEqual(
            patch.digest,
            "sha256:f8870ba9789e0eae7cfba15a2bfbe672e55f2688518d2113bcfc1e7d03dfc5ea"
        )
        XCTAssertFalse(patch.isTruncated)
        XCTAssertEqual(patch.files.map(\.path), ["a.txt", "added.txt"])
        XCTAssertEqual(patch.files.map(\.kind), ["modified", "added"])
        XCTAssertEqual(patch.files.map(\.add), [2, 1])
        XCTAssertEqual(patch.files.map(\.del), [0, 0])
        XCTAssertTrue(patch.text.contains("+new file on the peer"), patch.text)
    }
}
