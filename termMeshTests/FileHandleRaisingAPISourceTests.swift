import XCTest

/// `FileHandle`'s pre-`throws` API raises `NSFileHandleOperationException` on
/// I/O failure. Swift cannot catch an Objective-C exception, so a single failed
/// log write reaches `objc_terminate` and aborts the whole app.
///
/// That is issue #479: a full disk turned one line of `RemoteWorkLog` into a
/// process death, taking every terminal session and remote pane with it.
/// Logging is incidental work — a failed line must be dropped, not fatal.
///
/// Every call site was converted to the throwing replacements. This test keeps
/// them converted: the raising overloads must not come back into `Sources/`.
final class FileHandleRaisingAPISourceTests: XCTestCase {
    /// Raising API → the throwing replacement to use instead.
    private static let bannedCalls: [(pattern: String, replacement: String)] = [
        ("seekToEndOfFile()", "try? handle.seekToEnd()"),
        ("seek(toFileOffset:", "try? handle.seek(toOffset:)"),
        ("readDataToEndOfFile()", "try? handle.readToEnd()"),
        ("readData(ofLength:", "try? handle.read(upToCount:)"),
        ("closeFile()", "try? handle.close()"),
    ]

    /// `Process` pipes are drained with the raising read API all over the code
    /// base, and those handles fail for different reasons than a file does.
    /// Only file-backed handles are in scope here.
    private static func isPipeDrain(_ line: String) -> Bool {
        line.contains("fileHandleForReading") || line.contains("fileHandleForWriting")
    }

    func testSourcesDoNotUseRaisingFileHandleAPIs() throws {
        let sources = findProjectRoot().appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                guard !Self.isPipeDrain(line) else { continue }
                for banned in Self.bannedCalls where line.contains(banned.pattern) {
                    offenders.append(
                        "\(url.lastPathComponent):\(number + 1) uses \(banned.pattern) "
                        + "— use \(banned.replacement)"
                    )
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            These calls raise NSFileHandleOperationException, which Swift cannot catch,
            so an I/O failure such as a full disk aborts the app (issue #479).
            """
        )
    }

    /// The write path is the one that actually crashed, and `write(_:)` is easy
    /// to reintroduce because it reads like the throwing overload.
    func testSourcesWriteToFileHandlesOnlyThroughTheThrowingOverload() throws {
        let sources = findProjectRoot().appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        // `handle.write(data)` and friends: a bare identifier receiver, no
        // `contentsOf:` label. `data.write(to:)` and `transport.write($0)` are
        // unrelated APIs and stay out.
        let raisingWrite = try NSRegularExpression(
            pattern: #"\b(handle|fh|fileHandle|out|log)\.write\((?!contentsOf:)"#
        )

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                guard !Self.isPipeDrain(line), !line.contains(".write(to:") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if raisingWrite.firstMatch(in: line, range: range) != nil {
                    offenders.append(
                        "\(url.lastPathComponent):\(number + 1) uses FileHandle.write(_:) "
                        + "— use try? handle.write(contentsOf:)"
                    )
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            FileHandle.write(_:) raises on failure and aborts the process.
            Append through try? handle.write(contentsOf:) instead (issue #479).
            """
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
