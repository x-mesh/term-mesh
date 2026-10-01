#[test]
fn shrinking_clears_clipped_wide_cells_before_erase_or_overwrite() {
    for alternate in [false, true] {
        for character in ["한", "界", "😀"] {
            for cols in [2u16, 3, 70, 137] {
                for action in ["\x1b[X", "\x1b[K", "\x1b[P", "x"] {
                    let mut parser = vt100::Parser::new(3, cols, 0);
                    if alternate {
                        parser.process(b"\x1b[?1049h");
                    }
                    parser.process(format!("\x1b[1;{}H\x1b[31m{character}", cols - 1).as_bytes());
                    parser.screen_mut().set_size(3, cols - 1);
                    let edge = parser.screen().cell(0, cols - 2).unwrap();
                    assert!(!edge.is_wide());
                    assert!(edge.contents().is_empty());
                    assert_eq!(edge.fgcolor(), vt100::Color::Idx(1));
                    parser.process(format!("\x1b[1;{}H{action}", cols - 1).as_bytes());
                    parser.process(b"\x1b[2;1Hok");
                    assert!(parser.screen().contents().contains("ok"));
                }
            }
        }
    }
}

#[test]
fn resizing_preserves_complete_wide_characters_and_unaffected_cells() {
    let mut parser = vt100::Parser::new(3, 70, 10);
    parser.process("prefix\x1b[1;68H한".as_bytes());
    for cols in [69, 70, 137, 69] {
        parser.screen_mut().set_size(3, cols);
        assert!(parser.screen().contents().starts_with("prefix"));
        assert_eq!(parser.screen().cell(0, 67).unwrap().contents(), "한");
        assert!(parser.screen().cell(0, 68).unwrap().is_wide_continuation());
    }
    parser.screen_mut().set_size(3, 68);
    assert!(parser.screen().cell(0, 67).unwrap().contents().is_empty());
    parser.screen_mut().set_size(3, 70);
    parser.process(b"\x1b[1;68Hx\x1b[2;1Halive");
    assert!(parser.screen().contents().contains("alive"));
}
