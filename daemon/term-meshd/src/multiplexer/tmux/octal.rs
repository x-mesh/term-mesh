//! Per ADR 0002 §"Octal unescape contract" — decodes `\NNN` escapes
//! produced by tmux control mode `%output` events.
//!
//! tmux emits exactly three octal digits after each backslash: `\012` = LF.
//! A literal backslash is encoded as `\\`.

/// Decode tmux control-mode octal escapes from a raw `%output` payload.
///
/// `\\NNN` (backslash + 3 octal digits) → single byte with that value.
/// `\\\\` (two backslashes) → one literal backslash.
/// Any other byte sequence is passed through unchanged.
pub fn unescape_octal(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        if input[i] == b'\\' {
            // Two-backslash escape: \\ → \
            if i + 1 < input.len() && input[i + 1] == b'\\' {
                out.push(b'\\');
                i += 2;
                continue;
            }
            // Octal escape: \NNN (exactly 3 digits)
            if i + 3 < input.len()
                && input[i + 1].is_ascii_digit()
                && input[i + 2].is_ascii_digit()
                && input[i + 3].is_ascii_digit()
                && input[i + 1] <= b'7'
                && input[i + 2] <= b'7'
                && input[i + 3] <= b'7'
            {
                let val = (input[i + 1] - b'0') * 64
                    + (input[i + 2] - b'0') * 8
                    + (input[i + 3] - b'0');
                out.push(val);
                i += 4;
                continue;
            }
        }
        out.push(input[i]);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newline_escape() {
        // \012 = LF
        let result = unescape_octal(b"hello\\012world");
        assert_eq!(result, b"hello\nworld");
    }

    #[test]
    fn ansi_escape_sequence() {
        // \033 = ESC, \033[31m = ESC[31m (red), \033[0m = reset
        let input = b"\\033[31mred\\033[0m";
        let result = unescape_octal(input);
        assert_eq!(result, b"\x1b[31mred\x1b[0m");
    }

    #[test]
    fn no_escapes_passthrough() {
        let input = b"no escapes here";
        let result = unescape_octal(input);
        assert_eq!(result, b"no escapes here");
    }

    #[test]
    fn literal_backslash() {
        // \\ → single backslash
        let result = unescape_octal(b"\\\\not-octal");
        assert_eq!(result, b"\\not-octal");
    }

    #[test]
    fn mixed_octal_and_text() {
        // Multiple octal escapes mixed with plain text
        let result = unescape_octal(b"a\\012b\\015c");
        assert_eq!(result, b"a\nb\rc");
    }
}
