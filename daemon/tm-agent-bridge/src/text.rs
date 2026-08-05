//! Reading and bounding what a CLI hands over.

// The limits are consumed by the bridges as each one is ported; until then
// the compiler is right that nothing reads them.
#![allow(dead_code)]

use serde_json::Value;

/// Cut a shell log at this many characters.
pub const TEXT_LIMIT: usize = 4000;
/// Cut a patch at this many. A diff earns a larger budget than a screenful of
/// shell output, because reading it is the entire point of drawing the row.
pub const DIFF_LIMIT: usize = 65536;

/// Largest instruction frame the bridge accumulates before giving up on a
/// writer. The daemon's socket reader has always bounded its lines; the raw
/// reader did not, so a writer that never sent a newline could grow the
/// pending buffer until the process — or the host — ran out of memory. A
/// long-lived native agent pane is exactly where that costs an attacker
/// nothing and the user everything. Real capsules are kilobytes.
pub const MAX_FRAME_BYTES: usize = 1_048_576;

/// Newline-delimited frames, plus whatever is left over.
pub struct Frames {
    pub frames: Vec<String>,
    pub remainder: Vec<u8>,
    /// The byte count that blew the cap, or `None` when everything fit.
    pub oversize: Option<usize>,
}

/// Split newline-delimited frames and bound what is left over.
///
/// The cap applies per frame and to the still-unterminated remainder, never to
/// the accumulated buffer: bounding the buffer would punish a legitimate batch
/// of complete frames that happened to arrive in one read, while the case
/// worth killing a transport over is a writer that never sends a newline.
pub fn split_input_frames(pending: &mut Vec<u8>, chunk: &[u8]) -> Frames {
    pending.extend_from_slice(chunk);
    let mut frames = Vec::new();

    while let Some(at) = pending.iter().position(|b| *b == b'\n') {
        let raw: Vec<u8> = pending.drain(..=at).take(at).collect();
        if raw.len() > MAX_FRAME_BYTES {
            // Terminated, but still a flood — it just arrived with its newline
            // attached, which must not be a way past the cap.
            return Frames {
                frames,
                remainder: std::mem::take(pending),
                oversize: Some(raw.len()),
            };
        }
        frames.push(String::from_utf8_lossy(&raw).into_owned());
    }

    let oversize = (pending.len() > MAX_FRAME_BYTES).then(|| pending.len());
    Frames {
        frames,
        remainder: std::mem::take(pending),
        oversize,
    }
}

/// Cut long output at a line boundary, and say that it was cut.
///
/// Mid-line is fine for a shell log and wrong for a patch: half a hunk header
/// is not a diff any more, and a reader that knows how to draw one would be
/// handed something that cannot be drawn. So the cut lands between lines, and
/// the tail says how much is missing rather than the text simply stopping and
/// letting that pass for all of it.
pub fn clamp(text: &str, limit: usize) -> String {
    // Character counts, matching Python's `len` on a str: the same input has
    // to survive to the same length in either bridge.
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let cut_at = text
        .char_indices()
        .nth(limit)
        .map(|(i, _)| i)
        .unwrap_or(text.len());
    let mut head = &text[..cut_at];
    if let Some(edge) = head.rfind('\n') {
        if edge > 0 {
            head = &head[..edge];
        }
    }
    let dropped = text[head.len()..].matches('\n').count() + 1;
    format!("{head}\n… {dropped} more lines")
}

/// Pull the text out of ACP content blocks.
///
/// `[{"type": "content", "content": {"type": "text", "text": …}}]` is the
/// nested shape; `[{"type": "text", "text": …}]` the flat one. Both appear.
pub fn acp_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    let mut out = String::new();
    for block in blocks {
        let Some(block) = block.as_object() else {
            continue;
        };
        let inner = block.get("content");
        match inner {
            Some(Value::Object(map)) if map.get("type").and_then(Value::as_str) == Some("text") => {
                out.push_str(map.get("text").and_then(Value::as_str).unwrap_or(""));
            }
            _ if block.get("type").and_then(Value::as_str) == Some("text") => {
                out.push_str(block.get("text").and_then(Value::as_str).unwrap_or(""));
            }
            Some(Value::String(s)) => out.push_str(s),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn short_output_is_left_alone() {
        assert_eq!(clamp("hello", 100), "hello");
    }

    #[test]
    fn a_cut_lands_between_lines_and_says_so() {
        let text: String = (0..200).map(|n| format!("line {n}\n")).collect();

        let cut = clamp(&text, 100);

        let (body, tail) = cut.rsplit_once('\n').unwrap();
        assert!(body.split('\n').all(|line| line.starts_with("line ")));
        assert!(
            tail.starts_with("… ") && tail.ends_with(" more lines"),
            "unexpected tail: {tail}"
        );
    }

    /// Literal output of the Python `clamp` for these inputs, captured by
    /// running it. Both bridges cut the same text the same way while they
    /// ship together, and the third case is the one worth pinning: with no
    /// newline to cut at, the head keeps its full budget and the tail still
    /// admits a line went missing.
    #[test]
    fn clamping_matches_the_python_bridge() {
        let lines: String = (0..200).map(|n| format!("line {n}\n")).collect();
        assert_eq!(
            clamp(&lines, 100),
            "line 0\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\n\
             line 9\nline 10\nline 11\nline 12\n… 189 more lines"
        );

        assert_eq!(
            clamp(&"가나다라마바사아자차\n".repeat(50), 25),
            "가나다라마바사아자차\n가나다라마바사아자차\n… 50 more lines"
        );

        assert_eq!(
            clamp("no newline at all here just one long line", 10),
            "no newline\n… 1 more lines"
        );
    }

    #[test]
    fn a_cut_never_lands_inside_a_character() {
        // Python slices by character; bytes would panic here, and a diff cut
        // through a multi-byte character is not a diff a reader can draw.
        let text = "가나다라마바사아자차\n".repeat(50);

        let cut = clamp(&text, 25);

        assert!(cut.contains("more lines"));
        assert!(cut.starts_with("가나다라마바사아자차"));
    }

    #[test]
    fn frames_split_on_newlines_and_keep_the_remainder() {
        let mut pending = Vec::new();
        let out = split_input_frames(&mut pending, b"one\ntwo\nthr");

        assert_eq!(out.frames, vec!["one", "two"]);
        assert_eq!(out.remainder, b"thr");
        assert!(out.oversize.is_none());
    }

    #[test]
    fn a_writer_that_never_sends_a_newline_is_capped() {
        let mut pending = Vec::new();
        let flood = vec![b'x'; MAX_FRAME_BYTES + 1];

        let out = split_input_frames(&mut pending, &flood);

        assert_eq!(out.frames.len(), 0);
        assert_eq!(out.oversize, Some(MAX_FRAME_BYTES + 1));
    }

    #[test]
    fn a_newline_does_not_buy_a_way_past_the_cap() {
        let mut pending = Vec::new();
        let mut flood = vec![b'x'; MAX_FRAME_BYTES + 1];
        flood.push(b'\n');

        let out = split_input_frames(&mut pending, &flood);

        assert_eq!(out.oversize, Some(MAX_FRAME_BYTES + 1));
    }

    #[test]
    fn a_batch_of_complete_frames_is_not_punished_for_arriving_together() {
        // Together they exceed the cap; individually none does. Bounding the
        // buffer rather than the frame would kill this legitimate read.
        let mut pending = Vec::new();
        let one = "y".repeat(MAX_FRAME_BYTES / 2);
        let chunk = format!("{one}\n{one}\n{one}\n");

        let out = split_input_frames(&mut pending, chunk.as_bytes());

        assert_eq!(out.frames.len(), 3);
        assert!(out.oversize.is_none());
    }

    #[test]
    fn acp_content_is_read_in_both_shapes() {
        assert_eq!(acp_text(&json!("plain")), "plain");
        assert_eq!(
            acp_text(&json!([{"type": "content",
                              "content": {"type": "text", "text": "nested"}}])),
            "nested"
        );
        assert_eq!(acp_text(&json!([{"type": "text", "text": "flat"}])), "flat");
        assert_eq!(acp_text(&json!([{"content": "bare"}])), "bare");
        assert_eq!(acp_text(&json!(42)), "");
        assert_eq!(acp_text(&json!([null, {"type": "other"}])), "");
    }
}
