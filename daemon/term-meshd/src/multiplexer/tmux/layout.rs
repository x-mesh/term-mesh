//! tmux window layout string parser — ADR 0002 §"Layout Parser" (Phase 1.1).
//!
//! tmux emits the active window's layout as a single string via
//! `display-message -p '#{window_layout}'` and on every `%layout-change`
//! notification. The format is:
//!
//! ```text
//!   <checksum>,<cell>
//!   cell    := <cols>x<rows>,<x>,<y>(,<pane_index> | {<list>} | [<list>])
//!   list    := <cell>(,<cell>)*
//! ```
//!
//! - `{...}` wraps children that split left-to-right (`split-window -h`).
//! - `[...]` wraps children that split top-to-bottom (`split-window -v`).
//! - A trailing `,<pane_index>` makes the cell a leaf. The integer is the
//!   tmux pane *index* within the window (not the `%N` form); callers map
//!   it to a pane id via `list-panes -F '#{pane_index} #{pane_id}'`.
//!
//! The 4-hex-digit checksum is parsed but not validated; tmux uses it for
//! its own `select-layout` round-tripping and we never need to regenerate
//! a layout string from this parser.

use anyhow::{anyhow, Result};

/// Decoded `window_layout` string — owns a tree of `LayoutNode`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowLayout {
    /// Raw checksum prefix (4 hex digits). Not validated.
    pub checksum: u16,
    pub root: LayoutNode,
}

/// One cell in the layout tree.  Either a single pane leaf, or an interior
/// `Horizontal`/`Vertical` split with two or more children.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutNode {
    Pane {
        size: CellRect,
        pane_index: u32,
    },
    /// `{...}` — children stacked left-to-right.
    Horizontal {
        size: CellRect,
        children: Vec<LayoutNode>,
    },
    /// `[...]` — children stacked top-to-bottom.
    Vertical {
        size: CellRect,
        children: Vec<LayoutNode>,
    },
}

impl LayoutNode {
    pub fn size(&self) -> &CellRect {
        match self {
            LayoutNode::Pane { size, .. } => size,
            LayoutNode::Horizontal { size, .. } => size,
            LayoutNode::Vertical { size, .. } => size,
        }
    }

    /// Visit every `Pane` leaf in document order.
    pub fn for_each_pane<F: FnMut(u32, &CellRect)>(&self, f: &mut F) {
        match self {
            LayoutNode::Pane { size, pane_index } => f(*pane_index, size),
            LayoutNode::Horizontal { children, .. } | LayoutNode::Vertical { children, .. } => {
                for child in children {
                    child.for_each_pane(f);
                }
            }
        }
    }

    /// Collect pane indices in document order — convenience for callers
    /// that need to map indices to `%N` pane ids in one pass.
    pub fn pane_indices(&self) -> Vec<u32> {
        let mut out = Vec::new();
        self.for_each_pane(&mut |idx, _| out.push(idx));
        out
    }
}

/// Rectangle in tmux cell coordinates: `<cols>x<rows>` at offset `<x>,<y>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellRect {
    pub cols: u16,
    pub rows: u16,
    pub x: u16,
    pub y: u16,
}

/// Parse a tmux `#{window_layout}` string.
///
/// Returns `Err` on malformed input (missing checksum, unbalanced brackets,
/// non-integer fields, etc.). Callers should treat parse failure as
/// "layout temporarily stale" per ADR 0002 §"Layout Parser".
pub fn parse_window_layout(input: &str) -> Result<WindowLayout> {
    let trimmed = input.trim();
    let (checksum_str, rest) = trimmed
        .split_once(',')
        .ok_or_else(|| anyhow!("layout missing checksum separator: {trimmed:?}"))?;
    if checksum_str.len() != 4 {
        return Err(anyhow!(
            "layout checksum must be 4 hex digits, got {checksum_str:?}"
        ));
    }
    let checksum = u16::from_str_radix(checksum_str, 16)
        .map_err(|e| anyhow!("invalid checksum {checksum_str:?}: {e}"))?;

    let mut cursor = Cursor::new(rest);
    let root = parse_cell(&mut cursor)?;
    cursor.expect_eof()?;
    Ok(WindowLayout { checksum, root })
}

// ── Recursive-descent cursor ─────────────────────────────────────────────

struct Cursor<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(s: &'a str) -> Self {
        Self {
            src: s.as_bytes(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek()?;
        self.pos += 1;
        Some(c)
    }

    fn expect(&mut self, expected: u8) -> Result<()> {
        match self.peek() {
            Some(c) if c == expected => {
                self.pos += 1;
                Ok(())
            }
            Some(other) => Err(anyhow!(
                "expected {:?} at offset {}, got {:?}",
                expected as char,
                self.pos,
                other as char
            )),
            None => Err(anyhow!(
                "expected {:?} at offset {}, got end of input",
                expected as char,
                self.pos
            )),
        }
    }

    fn read_u16_until(&mut self, terminator: u8) -> Result<u16> {
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c == terminator {
                break;
            }
            if !c.is_ascii_digit() {
                return Err(anyhow!(
                    "expected digit at offset {}, got {:?}",
                    self.pos,
                    c as char
                ));
            }
            self.pos += 1;
        }
        if self.pos == start {
            return Err(anyhow!(
                "expected number at offset {}, got {:?}",
                self.pos,
                self.peek().map(|b| b as char)
            ));
        }
        let s = std::str::from_utf8(&self.src[start..self.pos])
            .map_err(|e| anyhow!("non-utf8 number at offset {}: {e}", start))?;
        s.parse::<u16>()
            .map_err(|e| anyhow!("number overflow at offset {start}: {e}"))
    }

    fn read_u32_until_terminator(&mut self) -> Result<u32> {
        let start = self.pos;
        while let Some(c) = self.peek() {
            if !c.is_ascii_digit() {
                break;
            }
            self.pos += 1;
        }
        if self.pos == start {
            return Err(anyhow!("expected pane index at offset {}", self.pos));
        }
        let s = std::str::from_utf8(&self.src[start..self.pos])
            .map_err(|e| anyhow!("non-utf8 pane index at offset {}: {e}", start))?;
        s.parse::<u32>()
            .map_err(|e| anyhow!("pane index overflow at offset {start}: {e}"))
    }

    fn expect_eof(&self) -> Result<()> {
        if self.pos == self.src.len() {
            Ok(())
        } else {
            Err(anyhow!(
                "unexpected trailing input at offset {}: {:?}",
                self.pos,
                String::from_utf8_lossy(&self.src[self.pos..])
            ))
        }
    }
}

fn parse_cell(cur: &mut Cursor) -> Result<LayoutNode> {
    let cols = cur.read_u16_until(b'x')?;
    cur.expect(b'x')?;
    let rows = cur.read_u16_until(b',')?;
    cur.expect(b',')?;
    let x = cur.read_u16_until(b',')?;
    cur.expect(b',')?;
    // y is terminated by either ',' (leaf or sibling) or '{'/'[' (children)
    // or end of input.
    let y_start = cur.pos;
    while let Some(c) = cur.peek() {
        if matches!(c, b',' | b'{' | b'[') {
            break;
        }
        if !c.is_ascii_digit() {
            return Err(anyhow!(
                "expected digit in y coord at offset {}, got {:?}",
                cur.pos,
                c as char
            ));
        }
        cur.pos += 1;
    }
    let y_str = std::str::from_utf8(&cur.src[y_start..cur.pos])
        .map_err(|e| anyhow!("non-utf8 y coord: {e}"))?;
    if y_str.is_empty() {
        return Err(anyhow!("missing y coord at offset {}", cur.pos));
    }
    let y: u16 = y_str
        .parse()
        .map_err(|e| anyhow!("invalid y coord {y_str:?}: {e}"))?;

    let size = CellRect { cols, rows, x, y };

    match cur.peek() {
        Some(b',') => {
            cur.expect(b',')?;
            let pane_index = cur.read_u32_until_terminator()?;
            Ok(LayoutNode::Pane { size, pane_index })
        }
        Some(b'{') => {
            cur.expect(b'{')?;
            let children = parse_children(cur, b'}')?;
            cur.expect(b'}')?;
            Ok(LayoutNode::Horizontal { size, children })
        }
        Some(b'[') => {
            cur.expect(b'[')?;
            let children = parse_children(cur, b']')?;
            cur.expect(b']')?;
            Ok(LayoutNode::Vertical { size, children })
        }
        Some(other) => Err(anyhow!(
            "expected ',' '{{' or '[' after cell at offset {}, got {:?}",
            cur.pos,
            other as char
        )),
        None => Err(anyhow!(
            "expected ',' '{{' or '[' after cell at offset {}, got end of input",
            cur.pos
        )),
    }
}

fn parse_children(cur: &mut Cursor, terminator: u8) -> Result<Vec<LayoutNode>> {
    let mut out = vec![parse_cell(cur)?];
    while cur.peek() == Some(b',') {
        // Distinguish "child separator" from "trailing pane index of parent".
        // Parent cells never carry a pane index, so after a child is parsed
        // we expect either ',' followed by another cell, or the closing
        // bracket. A pane-index after a child would have been consumed by
        // parse_cell itself.
        cur.expect(b',')?;
        out.push(parse_cell(cur)?);
    }
    if cur.peek() != Some(terminator) {
        return Err(anyhow!(
            "expected {:?} after children at offset {}, got {:?}",
            terminator as char,
            cur.pos,
            cur.peek().map(|b| b as char)
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(cols: u16, rows: u16, x: u16, y: u16) -> CellRect {
        CellRect { cols, rows, x, y }
    }

    #[test]
    fn parses_single_pane_window() {
        let layout = parse_window_layout("af23,80x24,0,0,1").unwrap();
        assert_eq!(layout.checksum, 0xaf23);
        assert_eq!(
            layout.root,
            LayoutNode::Pane {
                size: rect(80, 24, 0, 0),
                pane_index: 1,
            }
        );
    }

    #[test]
    fn parses_horizontal_split() {
        // {...} = side by side
        let layout = parse_window_layout("1f3a,80x24,0,0{40x24,0,0,0,40x24,40,0,1}").unwrap();
        match layout.root {
            LayoutNode::Horizontal { size, children } => {
                assert_eq!(size, rect(80, 24, 0, 0));
                assert_eq!(children.len(), 2);
                assert_eq!(
                    children[0],
                    LayoutNode::Pane {
                        size: rect(40, 24, 0, 0),
                        pane_index: 0
                    }
                );
                assert_eq!(
                    children[1],
                    LayoutNode::Pane {
                        size: rect(40, 24, 40, 0),
                        pane_index: 1
                    }
                );
            }
            other => panic!("expected Horizontal, got {other:?}"),
        }
    }

    #[test]
    fn parses_vertical_split() {
        // [...] = stacked
        let layout = parse_window_layout("1f3a,80x24,0,0[80x12,0,0,0,80x11,0,13,1]").unwrap();
        match layout.root {
            LayoutNode::Vertical { children, .. } => {
                assert_eq!(children.len(), 2);
                assert!(matches!(
                    children[0],
                    LayoutNode::Pane {
                        pane_index: 0,
                        size: CellRect {
                            cols: 80,
                            rows: 12,
                            x: 0,
                            y: 0
                        }
                    }
                ));
                assert!(matches!(
                    children[1],
                    LayoutNode::Pane {
                        pane_index: 1,
                        size: CellRect {
                            cols: 80,
                            rows: 11,
                            x: 0,
                            y: 13
                        }
                    }
                ));
            }
            other => panic!("expected Vertical, got {other:?}"),
        }
    }

    #[test]
    fn parses_nested_split() {
        // Outer {} with a [] in the second child:
        //   80x24 horizontal: [40x24 pane 0] and [40x24 vertical of two stacked panes]
        let s = "abcd,80x24,0,0{40x24,0,0,0,40x24,40,0[40x12,40,0,1,40x11,40,13,2]}";
        let layout = parse_window_layout(s).unwrap();
        let LayoutNode::Horizontal { children, .. } = &layout.root else {
            panic!("expected outer horizontal");
        };
        assert_eq!(children.len(), 2);
        assert_eq!(
            children[0],
            LayoutNode::Pane {
                size: rect(40, 24, 0, 0),
                pane_index: 0
            }
        );
        let LayoutNode::Vertical {
            size,
            children: inner,
        } = &children[1]
        else {
            panic!("expected inner vertical");
        };
        assert_eq!(*size, rect(40, 24, 40, 0));
        assert_eq!(inner.len(), 2);
        assert_eq!(
            inner[0],
            LayoutNode::Pane {
                size: rect(40, 12, 40, 0),
                pane_index: 1
            }
        );
        assert_eq!(
            inner[1],
            LayoutNode::Pane {
                size: rect(40, 11, 40, 13),
                pane_index: 2
            }
        );
    }

    #[test]
    fn parses_three_children_horizontal() {
        // Real-world case: split twice → three panes side-by-side.
        let layout =
            parse_window_layout("abcd,90x24,0,0{30x24,0,0,0,30x24,30,0,1,30x24,60,0,2}").unwrap();
        let LayoutNode::Horizontal { children, .. } = layout.root else {
            panic!("expected horizontal");
        };
        assert_eq!(children.len(), 3);
        assert_eq!(
            children
                .iter()
                .map(|c| match c {
                    LayoutNode::Pane { pane_index, .. } => *pane_index,
                    _ => unreachable!(),
                })
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn pane_indices_collects_in_order() {
        let layout =
            parse_window_layout("abcd,80x24,0,0{40x24,0,0,5,40x24,40,0[40x12,40,0,7,40x11,40,13,9]}")
                .unwrap();
        assert_eq!(layout.root.pane_indices(), vec![5, 7, 9]);
    }

    #[test]
    fn rejects_missing_checksum() {
        assert!(parse_window_layout("80x24,0,0,1").is_err());
    }

    #[test]
    fn rejects_short_checksum() {
        assert!(parse_window_layout("ab,80x24,0,0,1").is_err());
    }

    #[test]
    fn rejects_unbalanced_brackets() {
        assert!(parse_window_layout("abcd,80x24,0,0{40x24,0,0,0,40x24,40,0,1").is_err());
        assert!(parse_window_layout("abcd,80x24,0,0[40x12,0,0,0").is_err());
    }

    #[test]
    fn rejects_trailing_garbage() {
        assert!(parse_window_layout("abcd,80x24,0,0,1xyz").is_err());
    }

    #[test]
    fn rejects_non_digit_in_size() {
        assert!(parse_window_layout("abcd,80xZZ,0,0,1").is_err());
    }
}
