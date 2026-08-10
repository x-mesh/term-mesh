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
        if case .ground = state, !input.contains(0x1B) {
            return input
        }

        var out = [UInt8]()
        out.reserveCapacity(input.count)

        for byte in input {
            switch state {
            case .ground:
                if byte == 0x1B {
                    pending.removeAll(keepingCapacity: true)
                    pending.append(byte)
                    state = .escape
                } else {
                    out.append(byte)
                }

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
                }

            case .csi:
                pending.append(byte)
                if (0x40...0x7E).contains(byte) {
                    if !Self.isCSIQuery(pending) {
                        out.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else if !(0x20...0x3F).contains(byte) || pending.count > Self.maxPending {
                    // Invalid byte in the parameter region, or long enough
                    // that this is not a sequence. Flush rather than swallow.
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                }

            case .osc:
                if byte == 0x07 {
                    if !Self.isOSCQuery(pending) {
                        out.append(contentsOf: pending)
                        out.append(0x07)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else if byte == 0x1B {
                    state = .oscEscape
                } else {
                    pending.append(byte)
                    if pending.count > Self.maxPending {
                        out.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                        state = .ground
                    }
                }

            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    if !Self.isOSCQuery(pending) {
                        out.append(contentsOf: pending)
                        out.append(0x1B)
                        out.append(UInt8(ascii: "\\"))
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else {
                    // The ESC inside the OSC was not a String Terminator.
                    // Flush what we have; do not try to recover further.
                    out.append(contentsOf: pending)
                    out.append(0x1B)
                    out.append(byte)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
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
        guard sequence.count >= 3 else { return false }
        let final = sequence[sequence.count - 1]
        let body = Array(sequence[2..<(sequence.count - 1)])
        switch final {
        case UInt8(ascii: "n"):
            // Device Status Report (5) and Cursor Position Report (6).
            return body == Array("5".utf8) || body == Array("6".utf8)
        case UInt8(ascii: "q"):
            // XTVERSION. This is the one that was landing in the prompt.
            return body == Array(">".utf8) || body == Array(">0".utf8)
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
        guard body.count >= 4 else { return false }
        let payload = Array(body[2...])
        guard let semi = payload.firstIndex(of: UInt8(ascii: ";")) else { return false }
        let ps = Array(payload[..<semi])
        let pt = Array(payload[(semi + 1)...])
        guard pt == Array("?".utf8) else { return false }
        return ps == Array("10".utf8) || ps == Array("11".utf8)
    }
}
