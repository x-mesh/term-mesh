import Foundation

/// Removes terminal-control queries from a Mac host's PTY output before it is
/// relayed to a viewer.
///
/// **The problem.** A program asks the terminal a question — `CSI 6n` ("where
/// is the cursor?"), `OSC 11 ?` ("what is the background?"), `CSI > q`
/// (XTVERSION) — and the terminal is expected to answer on the program's
/// stdin. On a relayed pane the bytes reach TWO terminals: the host's own
/// Ghostty, and the viewer's. Both answer. The host's reply is local and
/// arrives at once; the viewer's has to travel viewer → relay → SSH → host
/// PTY, and over a 50–500 ms link the program that asked has usually exited by
/// the time it lands. The answer then falls into the shell prompt, where it is
/// read as something to run.
///
/// Observed exactly that way: `P>|ghostty 1.3.2-main-+5284f731b\` sitting in a
/// prompt on a remote pane — an XTVERSION reply with its ESC bytes invisible.
/// The daemon's header comment records the same shape from the Linux side,
/// down to zsh reporting `command not found: 11`.
///
/// **Why this only strips.** `term-meshd` faces a bare PTY with no terminal
/// behind it, so its `QueryFilter` must synthesize replies itself
/// (`daemon/term-meshd/src/peer/query_filter.rs`). A Mac host has a real
/// Ghostty on the other side of these same bytes, and it already answers
/// correctly and locally. The only thing wrong is the SECOND answer, so the
/// only thing needed here is to keep the question from reaching the viewer.
///
/// State persists across calls: `broadcast` sees whatever the kernel handed
/// back from one read, and a sequence can be split across two of them.
struct PeerTerminalQueryStripper {
    /// Bound on a partially-reassembled sequence. Past this the input is not a
    /// query worth waiting for, and holding bytes back would swallow content.
    /// Matches the daemon's `MAX_PENDING`.
    private static let maxPending = 256

    private enum State {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var state: State = .ground
    private var pending: [UInt8] = []
    /// True when `pending` began with an ESC that interrupted bytes already
    /// emitted to the viewer. If that new sequence is stripped, its ESC never
    /// reaches the viewer, so emit CAN to preserve the parser-state reset.
    private var cancelsPreviousSequence = false

    private static let escape: UInt8 = 0x1B
    private static let cancel: UInt8 = 0x18

    init() {
        pending.reserveCapacity(64)
    }

    /// Output with queries removed. Everything else passes through byte for
    /// byte — this must never reshape ordinary terminal output.
    mutating func strip(_ input: Data) -> Data {
        // Fast path. Nothing is in flight and there is no escape byte, so
        // there is nothing here to reassemble — hand back the same buffer
        // rather than copying it. This runs on Ghostty's IO reader thread for
        // every chunk of every relayed pane, including output floods where it
        // fires thousands of times a second.
        if case .ground = state, !input.contains(Self.escape) {
            return input
        }

        var out = [UInt8]()
        out.reserveCapacity(input.count)

        for byte in input {
            // Ghostty's parser treats ESC as an anywhere transition: it
            // aborts whatever was in flight and immediately begins the new
            // sequence. Do the same here. If we instead append the new ESC to
            // the invalid old sequence, then return to ground, the rest of a
            // fresh query passes through and Ghostty answers it — a bypass.
            if byte == Self.escape {
                switch state {
                case .osc:
                    // May be OSC's two-byte String Terminator. Keep the OSC
                    // pending until the next byte tells us whether this is
                    // ESC '\' or a fresh escape sequence.
                    state = .oscEscape
                    continue
                case .ground:
                    cancelsPreviousSequence = false
                    break
                case .oscEscape:
                    // The previous ESC already aborted the OSC and is the
                    // current introducer. A second ESC replaces it, just as
                    // Ghostty's anywhere transition does.
                    out.append(contentsOf: pending)
                    cancelsPreviousSequence = true
                default:
                    out.append(contentsOf: pending)
                    cancelsPreviousSequence = true
                }
                pending.removeAll(keepingCapacity: true)
                pending.append(byte)
                state = .escape
                continue
            }
            switch state {
            case .ground:
                out.append(byte)

            case .escape:
                pending.append(byte)
                switch byte {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "]"): state = .osc
                default:
                    // ESC followed by something not modelled here (keypad
                    // mode, charset select…). Pass it through untouched.
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    cancelsPreviousSequence = false
                }

            case .csi:
                pending.append(byte)
                if (0x40...0x7E).contains(byte) {
                    if Self.isCSIQuery(pending) {
                        if cancelsPreviousSequence { out.append(Self.cancel) }
                    } else {
                        out.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    cancelsPreviousSequence = false
                } else if !(0x20...0x3F).contains(byte) || pending.count > Self.maxPending {
                    // Invalid byte in the parameter region, or long enough
                    // that this is not a sequence. Flush rather than swallow.
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    cancelsPreviousSequence = false
                }

            case .osc:
                if byte == 0x07 {
                    if Self.isOSCQuery(pending) {
                        if cancelsPreviousSequence { out.append(Self.cancel) }
                    } else {
                        out.append(contentsOf: pending)
                        out.append(0x07)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    cancelsPreviousSequence = false
                } else {
                    pending.append(byte)
                    if pending.count > Self.maxPending {
                        out.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                        state = .ground
                        cancelsPreviousSequence = false
                    }
                }

            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    if Self.isOSCQuery(pending) {
                        if cancelsPreviousSequence { out.append(Self.cancel) }
                    } else {
                        out.append(contentsOf: pending)
                        out.append(0x1B)
                        out.append(UInt8(ascii: "\\"))
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    cancelsPreviousSequence = false
                } else {
                    // The preceding ESC aborted the OSC and starts a fresh
                    // escape sequence. Flush only the interrupted prefix, then
                    // interpret this byte as ESC's second byte. This mirrors
                    // Ghostty's anywhere transition and prevents an embedded
                    // ESC [ 6 n from bypassing the filter.
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    pending.append(Self.escape)
                    pending.append(byte)
                    cancelsPreviousSequence = true
                    switch byte {
                    case UInt8(ascii: "["): state = .csi
                    case UInt8(ascii: "]"): state = .osc
                    default:
                        out.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                        state = .ground
                        cancelsPreviousSequence = false
                    }
                }
            }
        }

        return Data(out)
    }

    /// Whether a fully-reassembled CSI sequence is a query the viewer must not
    /// answer. `sequence` is ESC '[' … final.
    ///
    /// The set matches the daemon's `csi_query_reply` so both hosts hide the
    /// same questions. Anything else — cursor movement, colour, mode toggles —
    /// is ordinary output and passes through.
    static func isCSIQuery(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 3,
              sequence[0] == Self.escape,
              sequence[1] == UInt8(ascii: "[") else { return false }
        let final = sequence[sequence.count - 1]
        let body = sequence[2..<(sequence.count - 1)]
        switch final {
        case UInt8(ascii: "c"):
            // Device Attributes. Keep exactly the daemon's accepted forms:
            // DA1 (empty/0), DA2 (> prefix), and DA3 (= prefix).
            return body.isEmpty
                || body.elementsEqual("0".utf8)
                || body.first == UInt8(ascii: ">")
                || body.first == UInt8(ascii: "=")
        case UInt8(ascii: "n"):
            // Device Status Report (5) and Cursor Position Report (6).
            return body.elementsEqual("5".utf8) || body.elementsEqual("6".utf8)
        case UInt8(ascii: "q"):
            // XTVERSION. This is the one that was landing in the prompt.
            return body.elementsEqual(">".utf8) || body.elementsEqual(">0".utf8)
        default:
            return false
        }
    }

    /// Whether a reassembled OSC body is a colour query. `body` holds ESC ']'
    /// followed by the payload, with the terminator excluded.
    ///
    /// Only `?` payloads count: `OSC 11 ; ?` asks, while `OSC 11 ; rgb:…` sets
    /// — and stripping a set would change how the pane looks.
    static func isOSCQuery(_ body: [UInt8]) -> Bool {
        guard body.count >= 4,
              body[0] == Self.escape,
              body[1] == UInt8(ascii: "]") else { return false }
        let payload = body[2...]
        guard let semi = payload.firstIndex(of: UInt8(ascii: ";")) else { return false }
        let ps = payload[..<semi]
        let pt = payload[(semi + 1)...]
        guard pt.elementsEqual("?".utf8) else { return false }
        return ps.elementsEqual("10".utf8) || ps.elementsEqual("11".utf8)
    }
}
