import Foundation

/// A file edit, kept as the two sides it actually had.
///
/// The stream already carries everything a diff needs — an `Edit` arrives with
/// `old_string` and `new_string` in hand, a bridged patch arrives as a unified
/// diff — and the pane was reading one field out of that and dropping the rest.
/// What reached the screen was a filename. A filename says a file was touched.
/// It does not say what happened to it, which is the only question worth asking
/// about an edit you did not make yourself.
///
/// Everything here is a pure function of a tool call, deliberately: the diff is
/// worked out once when the call opens and once more when its result lands, and
/// never in a view's body. `AgentSession.Row` exists because deriving
/// presentation per layout pass once pinned the main thread for 25 minutes, and
/// a diff is the larger version of that same trap.
enum AgentDiff {

    /// What one tool call did to one file.
    struct Change: Equatable {
        /// The path as the tool named it. Shortened for display, never here: a
        /// row is a view's problem and a path is the model's fact.
        var path: String
        var kind: Kind
        /// `git diff --numstat` semantics — context lines are not changes.
        /// Counted before anything is folded or cut, so a clipped body still
        /// reports the true size of what happened.
        var added: Int
        var removed: Int
        var lines: [Line]
        /// Lines the cap refused to hold, so the row can say so rather than
        /// quietly showing a diff that is not the diff.
        var elided: Int
        /// The tool said it would replace every occurrence, which makes any
        /// single line number a lie and the counts per-site rather than total.
        var everywhere: Bool
    }

    enum Kind: Equatable {
        case edit
        /// `created` is unknown until the result arrives and says which it was.
        /// The difference between "97 lines of new file" and "97 lines over the
        /// 94 that were there" is the whole meaning of the number beside it.
        case write(created: Bool?)
        case delete
        case multiEdit(sites: Int)
        case notebook(cell: String?)
    }

    /// One line of a diff.
    ///
    /// The numbers are optional because for `old_string`/`new_string` there are
    /// none: the tool hands over a fragment of a file and never says where in
    /// the file it sits. A unified diff does say, in its hunk headers, so one
    /// shape carries both rather than the reader learning two.
    enum Line: Equatable {
        case context(old: Int?, new: Int?, text: String)
        case added(new: Int?, text: String)
        case removed(old: Int?, text: String)
        /// A run of unchanged lines folded away, with how many. Zero means a
        /// break between hunks, where the patch itself never said how much it
        /// skipped.
        case gap(Int)
        /// Where one edit of a `MultiEdit` ends and the next begins.
        case site(Int)
    }

    // MARK: - Limits

    /// Measured across 88 sessions: the largest single edit was 462 lines, so
    /// this holds every real diff and exists for the one that is not real.
    static let maxLines = 800
    /// A minified bundle is one line and tens of kilobytes of it, and a
    /// horizontal scroller will take all of them.
    static let maxLineLength = 500
    /// Below this a diff is small enough that its context *is* the explanation,
    /// and folding it removes the only reason it was included.
    static let foldThreshold = 30
    static let foldContext = 3
    /// The most lines this will compare before refusing to compare them.
    ///
    /// `maxLines` bounds what is *shown* and is applied after the walk;
    /// `CollectionDifference` is O(N·D), so for two large sides that mostly
    /// differ the cost is quadratic and paid before any cap is reached. It is
    /// paid on the main actor too — `change(tool:input:)` is called from
    /// `AgentSession.openTool`, which reads the stream there — so a full-file
    /// `old_string`/`new_string` pair took the whole window with it. The
    /// largest real edit measured across 88 sessions was 462 lines, so this
    /// holds every one of them and exists for the one that is not real.
    static let maxDiffInputLines = 4_000
    /// A single minified line can evade the line budget while still making a
    /// large temporary `String` and horizontal layout. Count bytes first.
    static let maxDiffInputBytes = 1 * 1024 * 1024

    // MARK: - Reading a call

    /// The change a tool call describes, or nil if it does not describe one.
    ///
    /// Dispatched on the *shape* of the input rather than the tool's name. The
    /// same edit is called `Edit` by claude, `edit` by the bridge, `Edit File`
    /// by kiro and `editFile` by cursor; a list of names is a list that is
    /// wrong again with the next CLI, while `old_string` and `new_string`
    /// together mean one thing wherever they turn up.
    static func change(tool name: String, input: [String: Any]) -> Change? {
        let path = (input["file_path"] ?? input["path"]
                    ?? input["notebook_path"]) as? String ?? ""
        let everywhere = input["replace_all"] as? Bool ?? false

        // A patch, which is the one form that knows its own line numbers.
        if let patch = input["unified_diff"] as? String, !patch.isEmpty {
            guard var change = unified(patch) else { return nil }
            if !path.isEmpty { change.path = path }
            if let declared = kind(input["kind"] as? String ?? name) {
                change.kind = declared
            }
            return change
        }

        if let old = input["old_string"] as? String,
           let new = input["new_string"] as? String {
            if let unwalked = tooBigToRead(path: path, kind: .edit,
                                           old: old, new: new,
                                           everywhere: everywhere) {
                return unwalked
            }
            let before = split(old), after = split(new)
            if let unwalked = tooBigToDiff(path: path, kind: .edit, old: before,
                                           new: after, everywhere: everywhere) {
                return unwalked
            }
            return assemble(path: path, kind: .edit,
                            lines: lines(old: before, new: after),
                            everywhere: everywhere)
        }

        if let edits = input["edits"] as? [[String: Any]], !edits.isEmpty {
            return multiEdit(path: path, edits: edits, everywhere: everywhere)
        }

        // A whole file, which is every line added — and, if the file was
        // already there, every line it had removed. Only the result knows.
        if let content = input["content"] as? String, !path.isEmpty {
            return assemble(path: path, kind: .write(created: nil),
                            lines: lines(old: [], new: split(content)),
                            everywhere: false)
        }

        if let source = input["new_source"] as? String, !path.isEmpty {
            return assemble(path: path,
                            kind: .notebook(cell: input["cell_id"] as? String),
                            lines: lines(old: [], new: split(source)),
                            everywhere: false)
        }

        return nil
    }

    /// Refined once the result lands.
    ///
    /// A successful write says either "File created successfully at" or "has
    /// been updated successfully", and those are the difference between `+97`
    /// meaning a new file and `+97` meaning 97 lines put over the ones that
    /// were there. It costs nothing to be honest about which.
    static func refined(_ change: Change, result: String, failed: Bool) -> Change {
        guard !failed, case .write(nil) = change.kind else { return change }
        var out = change
        if result.contains("created successfully") {
            out.kind = .write(created: true)
        } else if result.contains("updated successfully")
                    || result.contains("has been updated") {
            out.kind = .write(created: false)
        }
        return out
    }

    // MARK: - Diffing

    /// Two collections reduced to one column a person can read top to bottom.
    ///
    /// Painting all of `old_string` red and all of `new_string` green is wrong
    /// in the ordinary case, not the rare one: measured, the median edit
    /// replaces 5 lines with 12 of which only a couple actually differ, and
    /// `+12 −5` then hands the reader the job of finding the change themselves.
    ///
    /// `CollectionDifference` is Myers, in the standard library, and reports
    /// offsets into two different collections — so the work here is walking two
    /// cursors to put them back into one sequence. Removals lead insertions at
    /// the same point, the way every diff has done it since 1974.
    static func lines(old: [String], new: [String],
                      firstOld: Int? = nil, firstNew: Int? = nil) -> [Line] {
        // One side empty is the whole answer already: every line of the other
        // is an insertion or a removal. Asking Myers for it costs O(N·D) to be
        // told what a `Write` says in its own shape, and a whole file is
        // exactly where N is large.
        if old.isEmpty {
            return new.indices.map { index in
                Line.added(new: firstNew.map { $0 + index }, text: new[index])
            }
        }
        if new.isEmpty {
            return old.indices.map { index in
                Line.removed(old: firstOld.map { $0 + index }, text: old[index])
            }
        }
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }
        var out: [Line] = []
        var o = 0, n = 0
        while o < old.count || n < new.count {
            if let text = removals[o] {
                out.append(.removed(old: firstOld.map { $0 + o }, text: text))
                o += 1
                continue
            }
            if let text = insertions[n] {
                out.append(.added(new: firstNew.map { $0 + n }, text: text))
                n += 1
                continue
            }
            // Both cursors have to be in range for a line to be unchanged; a
            // difference that ran out on one side ends the walk rather than
            // reading past the end of the other.
            guard o < old.count, n < new.count else { break }
            out.append(.context(old: firstOld.map { $0 + o },
                                new: firstNew.map { $0 + n }, text: old[o]))
            o += 1
            n += 1
        }
        return out
    }

    /// A unified diff, read for what it shows rather than what it claims.
    ///
    /// The hunk header's counts are never trusted — only its two starting line
    /// numbers are used, and the body is whatever the body turns out to be.
    /// `@@ -1,99999999 +1,1 @@` is a valid thing for a subprocess to print and
    /// must cost nothing to read.
    static func unified(_ patch: String) -> Change? {
        var out: [Line] = []
        var added = 0, removed = 0
        var path = ""
        var o = 0, n = 0
        var open = false
        /// Whether any hunk has been read yet, which `open` stops answering the
        /// moment a damaged header closes one.
        var began = false

        // A patch ends in a newline, and that final newline is a terminator
        // rather than an empty last line. Counted as one it becomes a context
        // line at the end of every hunk — invented content, and one that slides
        // nothing but reads as part of the file.
        var raws = patch.components(separatedBy: "\n")
        if raws.last == "" { raws.removeLast() }

        for raw in raws {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            if line.hasPrefix("+++ ") {
                if let found = headerPath(line) { path = found }
                continue
            }
            if line.hasPrefix("@@") {
                guard let starts = hunkStarts(line) else {
                    // A header damaged past reading says where nothing is.
                    // Carrying the previous hunk's cursors into lines that do
                    // not belong to it would number them wrongly, so content
                    // stops until a header that parses — the hunk is skipped
                    // rather than mis-placed, and earlier hunks are kept.
                    open = false
                    continue
                }
                // A second hunk means the patch skipped something without
                // saying how much — and so does a hunk after one that was
                // dropped for being unreadable.
                if began { out.append(.gap(0)) }
                open = true
                began = true
                o = starts.old
                n = starts.new
                continue
            }
            // Everything before the first hunk is provenance, not content.
            guard open else { continue }

            if line.hasPrefix("+") {
                out.append(.added(new: n, text: trim(line.dropFirst())))
                added += 1
                n += 1
            } else if line.hasPrefix("-") {
                out.append(.removed(old: o, text: trim(line.dropFirst())))
                removed += 1
                o += 1
            } else if line.hasPrefix(" ") {
                out.append(.context(old: o, new: n, text: trim(line.dropFirst())))
                o += 1
                n += 1
            } else if line.isEmpty {
                // Some producers leave the leading space off an empty context
                // line. Dropping it would slide every number after it.
                out.append(.context(old: o, new: n, text: ""))
                o += 1
                n += 1
            }
            // Anything else — "\ No newline at end of file", a stray marker —
            // is not part of either side of the file.
        }

        guard added + removed > 0 else { return nil }
        let (shown, elided) = cap(fold(out))
        return Change(path: path, kind: .edit, added: added, removed: removed,
                      lines: shown, elided: elided, everywhere: false)
    }

    // MARK: - Display

    /// A path as it reads next to the others in the same pane.
    static func short(_ path: String, relativeTo root: String) -> String {
        guard !root.isEmpty, path.hasPrefix("/") else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// The whole diff as text, for the copy button. What is on screen may be
    /// folded or cut; this is what was actually read out of the call.
    static func text(_ change: Change) -> String {
        change.lines.map { line in
            switch line {
            case .added(_, let text): return "+" + text
            case .removed(_, let text): return "-" + text
            case .context(_, _, let text): return " " + text
            case .gap(let count): return count > 0 ? "@@ \(count) unchanged @@" : "@@"
            case .site(let index): return "@@ edit \(index + 1) @@"
            }
        }.joined(separator: "\n")
    }

    // MARK: - Assembly

    private static func assemble(path: String, kind: Kind, lines all: [Line],
                                 everywhere: Bool) -> Change? {
        let (added, removed) = count(all)
        guard added + removed > 0 else { return nil }
        let (shown, elided) = cap(fold(all))
        return Change(path: path, kind: kind, added: added, removed: removed,
                      lines: shown, elided: elided, everywhere: everywhere)
    }

    /// A pair too large to walk, reported as its two sizes instead of diffed.
    ///
    /// Not `numstat` semantics, deliberately: nothing was compared, so how many
    /// of those lines actually differ is not known here. `elided` is what tells
    /// the row it is not showing the diff, the same way a cut one does.
    private static func tooBigToDiff(path: String, kind: Kind, old: [String],
                                     new: [String], everywhere: Bool) -> Change? {
        let total = old.count + new.count
        guard total > maxDiffInputLines else { return nil }
        return Change(path: path, kind: kind, added: new.count, removed: old.count,
                      lines: [], elided: total, everywhere: everywhere)
    }

    private static func tooBigToRead(path: String, kind: Kind, old: String,
                                     new: String, everywhere: Bool) -> Change? {
        let bytes = old.utf8.count + new.utf8.count
        guard bytes > maxDiffInputBytes else { return nil }
        let removed = old.isEmpty ? 0 : old.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let added = new.isEmpty ? 0 : new.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return Change(path: path, kind: kind, added: added, removed: removed,
                      lines: [], elided: added + removed, everywhere: everywhere)
    }

    private static func multiEdit(path: String, edits: [[String: Any]],
                                  everywhere: Bool) -> Change? {
        var all: [Line] = []
        var added = 0, removed = 0
        var sites = 0
        var anywhere = everywhere
        var walked = 0
        for (index, edit) in edits.enumerated() {
            guard let old = edit["old_string"] as? String,
                  let new = edit["new_string"] as? String else { continue }
            let before = split(old), after = split(new)
            // The budget is the call's, not each edit's: fifty edits of a
            // hundred lines cost what one edit of five thousand does.
            walked += before.count + after.count
            if walked > maxDiffInputLines {
                // The budget bounds the CollectionDifference walk, not plain
                // counting: this edit and every one still to come contributes
                // its raw before/after size to the totals (same numstat
                // semantics `tooBigToDiff` uses) without diffing it, so a
                // bailout row's count is never smaller than the real change.
                sites += 1
                added += after.count
                removed += before.count
                if edit["replace_all"] as? Bool == true { anywhere = true }
                for remaining in edits[(index + 1)...] {
                    guard let rOld = remaining["old_string"] as? String,
                          let rNew = remaining["new_string"] as? String else { continue }
                    let rBefore = split(rOld), rAfter = split(rNew)
                    walked += rBefore.count + rAfter.count
                    sites += 1
                    added += rAfter.count
                    removed += rBefore.count
                    if remaining["replace_all"] as? Bool == true { anywhere = true }
                }
                return Change(path: path, kind: .multiEdit(sites: sites),
                              added: added, removed: removed,
                              lines: [], elided: walked, everywhere: anywhere)
            }
            let piece = lines(old: before, new: after)
            let (plus, minus) = count(piece)
            guard plus + minus > 0 else { continue }
            if sites > 0 { all.append(.site(sites)) }
            sites += 1
            added += plus
            removed += minus
            all.append(contentsOf: piece)
            if edit["replace_all"] as? Bool == true { anywhere = true }
        }
        guard added + removed > 0 else { return nil }
        let (shown, elided) = cap(fold(all))
        return Change(path: path, kind: .multiEdit(sites: sites),
                      added: added, removed: removed,
                      lines: shown, elided: elided, everywhere: anywhere)
    }

    private static func count(_ lines: [Line]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in lines {
            switch line {
            case .added: added += 1
            case .removed: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    /// Keep what changed and a few lines either side of it.
    ///
    /// Only worth doing once there is enough context for the reader to lose the
    /// change inside it; below that the surrounding lines are what make the
    /// change legible in the first place.
    private static func fold(_ lines: [Line]) -> [Line] {
        guard lines.count > foldThreshold else { return lines }
        var keep = Set<Int>()
        for (index, line) in lines.enumerated() {
            if case .context = line { continue }
            let low = max(0, index - foldContext)
            let high = min(lines.count - 1, index + foldContext)
            for near in low...high { keep.insert(near) }
        }
        guard keep.count < lines.count else { return lines }
        var out: [Line] = []
        var run = 0
        for (index, line) in lines.enumerated() {
            if keep.contains(index) {
                if run > 0 {
                    out.append(.gap(run))
                    run = 0
                }
                out.append(line)
            } else {
                run += 1
            }
        }
        if run > 0 { out.append(.gap(run)) }
        return out
    }

    private static func cap(_ lines: [Line]) -> (lines: [Line], elided: Int) {
        guard lines.count > maxLines else { return (lines, 0) }
        return (Array(lines.prefix(maxLines)), lines.count - maxLines)
    }

    // MARK: - Text

    /// Split text into the lines a file actually has.
    ///
    /// Splitting on "\n" alone leaves a phantom empty line for text that ends
    /// in one, and nearly every file does — a 97-line `Write` reported 98.
    private static func split(_ text: String) -> [String] {
        var out = text.components(separatedBy: "\n")
        if out.last == "" { out.removeLast() }
        return out.map(trim)
    }

    private static func trim<S: StringProtocol>(_ line: S) -> String {
        // A CRLF file otherwise shows a control glyph at every line end and
        // matches nothing on the other side of the diff.
        var text = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) }
        return text
    }

    private static func kind(_ declared: String) -> Kind? {
        switch declared.lowercased() {
        case "add", "write", "create": return .write(created: true)
        case "delete", "remove": return .delete
        case "update", "edit": return .edit
        default: return nil
        }
    }

    /// `@@ -12,3 +12,4 @@ anything` → the two starting line numbers.
    private static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let body = line.dropFirst(2)
        // The trailing text after the closing `@@` is a function name, and it
        // can contain anything at all — including a leading `-`.
        guard let close = body.range(of: "@@") else { return nil }
        var old: Int?
        var new: Int?
        for part in body[..<close.lowerBound].split(separator: " ") {
            guard let mark = part.first, mark == "-" || mark == "+" else { continue }
            // `first`, not `[0]`: a header damaged down to a bare `-` or `-,`
            // splits to nothing at all, and indexing that was a crash — on a
            // string a model or a bridge wrote, which is the one kind of input
            // that must cost nothing to read.
            let number = part.dropFirst().split(separator: ",").first.flatMap { Int($0) }
            if mark == "-", old == nil { old = number }
            if mark == "+", new == nil { new = number }
        }
        guard let o = old, let n = new else { return nil }
        return (o, n)
    }

    /// `+++ b/Sources/Foo.swift` → `Sources/Foo.swift`.
    private static func headerPath(_ line: String) -> String? {
        var value = String(line.dropFirst(4))
        // git appends a timestamp after a tab in some formats.
        if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value != "/dev/null", !value.isEmpty else { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value.isEmpty ? nil : value
    }
}
