import SwiftUI

/// Enough markdown to read an agent, and no more.
///
/// Agents write markdown whether or not anything renders it, so the pane was
/// showing `**bold**`, `## Heading` and fenced code as literal characters. But
/// a full renderer is the wrong answer here: this is a dense product surface,
/// not a document viewer, and headings blown up to display sizes would turn a
/// five-line answer into a poster.
///
/// So headings carry weight, not size — a heading is body text in bold, and the
/// deepest ones are only bold. What does get real treatment is code, because a
/// fenced block is the one thing in an answer you read character by character.
enum AgentMarkdown {

    // MARK: - Blocks

    enum Block: Identifiable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(marker: String, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case rule

        var id: Int {
            switch self {
            case .paragraph(let s): return s.hashValue
            case .heading(let l, let s): return l &* 31 &+ s.hashValue
            case .bullet(let m, let s): return m.hashValue &+ s.hashValue
            case .quote(let s): return ~s.hashValue
            case .code(let l, let s): return (l ?? "").hashValue &+ s.hashValue
            case .rule: return 0
            }
        }
    }

    /// Split text into blocks in one pass.
    ///
    /// An unterminated fence is deliberately treated as code that runs to the
    /// end: while a turn streams, the closing ``` has not arrived yet, and
    /// showing the opening line as a paragraph until it does would make the
    /// block flicker into existence.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        var lines = text.components(separatedBy: "\n")[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(next)
                }
                out.append(.code(language: language.isEmpty ? nil : language,
                                 text: body.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                    flushParagraph()
                    out.append(.heading(level: hashes,
                                        text: String(line.dropFirst(hashes + 1))))
                    continue
                }
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                out.append(.rule)
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                out.append(.quote(String(line.dropFirst(2))))
                continue
            }

            if let marker = listMarker(line) {
                flushParagraph()
                out.append(.bullet(marker: marker.0, text: marker.1))
                continue
            }

            if line.isEmpty { flushParagraph() } else { paragraph.append(raw) }
        }
        flushParagraph()
        return out
    }

    /// `- item`, `* item`, `1. item`. Ordered lists keep their own number
    /// rather than being renumbered, because an agent quoting "step 3" means 3.
    private static func listMarker(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (digits + ".", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: - Inline

    /// `**bold**`, `*italic*`, `` `code` ``, links.
    ///
    /// Only run when a row has stopped streaming: it allocates, and a long
    /// answer arrives in a couple of hundred deltas. Half-written emphasis is
    /// also unparseable by definition, so there is nothing to gain by trying.
    static func inline(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }

        var out = parsed
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .system(size: 11.5, design: .monospaced)
            out[run.range].backgroundColor = .primary.opacity(0.07)
        }
        return out
    }

    // MARK: - Code

    private struct Grammar {
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var keywords: Set<String> = []
        /// JSON has no keywords worth colouring, but a string in key position
        /// is the thing you scan for.
        var keysAreStrings = false
    }

    private static func grammar(for language: String?) -> Grammar {
        switch (language ?? "").lowercased() {
        case "swift":
            return Grammar(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: [
                "let", "var", "func", "if", "else", "guard", "return", "for", "while",
                "switch", "case", "default", "struct", "class", "enum", "protocol",
                "extension", "import", "self", "nil", "true", "false", "in", "where",
                "try", "throw", "throws", "async", "await", "private", "static", "init"])
        case "json":
            return Grammar(keywords: ["true", "false", "null"], keysAreStrings: true)
        case "bash", "sh", "zsh", "shell", "console":
            return Grammar(lineComments: ["#"], keywords: [
                "if", "then", "fi", "for", "do", "done", "while", "case", "esac",
                "function", "return", "export", "local", "echo", "cd", "set"])
        case "python", "py":
            return Grammar(lineComments: ["#"], keywords: [
                "def", "class", "if", "elif", "else", "for", "while", "return",
                "import", "from", "try", "except", "finally", "with", "as", "in",
                "not", "and", "or", "None", "True", "False", "lambda", "yield"])
        case "rust", "rs":
            return Grammar(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: [
                "fn", "let", "mut", "if", "else", "match", "return", "for", "while",
                "struct", "enum", "impl", "trait", "use", "pub", "self", "mod",
                "async", "await", "true", "false"])
        default:
            // Strings, numbers and the two comment markers nearly every
            // language shares. Guessing keywords for an unknown language
            // colours the wrong words, which is worse than colouring none.
            return Grammar(lineComments: ["#", "//"])
        }
    }

    enum Token: Equatable {
        case plain, comment, string, number, keyword, key
    }

    /// A small scanner rather than a real parser. It gets comments, strings,
    /// numbers and keywords right, which is what makes a block scannable; it
    /// does not attempt to understand the language, which is what would make it
    /// wrong in interesting ways.
    static func tokenize(_ code: String, language: String?) -> [(String, Token)] {
        let g = grammar(for: language)
        var out: [(String, Token)] = []
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            let kind: Token
            if g.keywords.contains(word) { kind = .keyword }
            else if word.first?.isNumber == true { kind = .number }
            else { kind = .plain }
            out.append((word, kind))
            word = ""
        }

        var i = code.startIndex
        while i < code.endIndex {
            let rest = code[i...]

            if let (open, close) = g.blockComment, rest.hasPrefix(open) {
                flushWord()
                let end = rest.range(of: close).map { $0.upperBound } ?? code.endIndex
                out.append((String(code[i..<end]), .comment))
                i = end
                continue
            }
            if let marker = g.lineComments.first(where: { rest.hasPrefix($0) }) {
                _ = marker
                flushWord()
                let end = rest.firstIndex(of: "\n") ?? code.endIndex
                out.append((String(code[i..<end]), .comment))
                i = end
                continue
            }
            if rest.first == "\"" || rest.first == "'" {
                flushWord()
                let quote = rest.first!
                var j = code.index(after: i)
                while j < code.endIndex {
                    if code[j] == "\\", code.index(after: j) < code.endIndex {
                        j = code.index(j, offsetBy: 2); continue
                    }
                    if code[j] == quote { j = code.index(after: j); break }
                    if code[j] == "\n" { break }
                    j = code.index(after: j)
                }
                let text = String(code[i..<j])
                // In JSON the interesting strings are the keys, and a key is a
                // string with a colon after it.
                var kind: Token = .string
                if g.keysAreStrings {
                    let after = code[j...].drop { $0 == " " }
                    if after.first == ":" { kind = .key }
                }
                out.append((text, kind))
                i = j
                continue
            }
            let c = code[i]
            if c.isLetter || c.isNumber || c == "_" {
                word.append(c)
            } else {
                flushWord()
                out.append((String(c), .plain))
            }
            i = code.index(after: i)
        }
        flushWord()
        return out
    }

    static func color(_ token: Token) -> Color {
        switch token {
        case .comment: return .secondary
        case .string:  return .green
        case .number:  return .orange
        case .keyword: return .pink
        case .key:     return .blue
        case .plain:   return .primary
        }
    }

    static func highlighted(_ code: String, language: String?) -> AttributedString {
        var out = AttributedString()
        for (text, token) in tokenize(code, language: language) {
            var piece = AttributedString(text)
            if token != .plain { piece.foregroundColor = color(token) }
            out.append(piece)
        }
        return out
    }
}
