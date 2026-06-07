// Issue #361: prove the psmux-side OSC 8 pipeline end to end WITHOUT ConPTY:
// feed OSC 8 to the vt100 parser, then serialize the screen the same way the
// dump-state does, and verify the run carries the hyperlink URI. (On Windows
// builds where ConPTY passthrough works, that serialized link reaches the
// client, which re-emits OSC 8 via build_osc8_overlay.)
use vt100::Parser;

#[test]
fn serialized_run_carries_hyperlink() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"\x1b]8;;https://example.com\x1b\\Link\x1b]8;;\x1b\\ plain");
    let rows = crate::layout::serialize_screen_rows(p.screen(), 5, 40);
    let first = &rows[0].runs;
    // A run whose text starts with "Link" must carry the URI.
    let linked = first.iter().find(|r| r.text.starts_with("Link"))
        .expect("linked run exists");
    assert_eq!(linked.link.as_deref(), Some("https://example.com"));
    // A later "plain" run must NOT carry a link.
    let plain = first.iter().find(|r| r.text.contains("plain"))
        .expect("plain run exists");
    assert_eq!(plain.link, None);
}

#[test]
fn no_hyperlink_means_no_link_field() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"just text");
    let rows = crate::layout::serialize_screen_rows(p.screen(), 5, 40);
    assert!(rows[0].runs.iter().all(|r| r.link.is_none()));
}

#[test]
fn hyperlink_change_breaks_runs() {
    let mut p: Parser = Parser::new(5, 60, 0);
    // two adjacent links with the same style must still be two runs.
    p.process(b"\x1b]8;;u://a\x1b\\AA\x1b]8;;u://b\x1b\\BB\x1b]8;;\x1b\\");
    let rows = crate::layout::serialize_screen_rows(p.screen(), 5, 60);
    let a = rows[0].runs.iter().find(|r| r.text.starts_with("AA")).unwrap();
    let b = rows[0].runs.iter().find(|r| r.text.starts_with("BB")).unwrap();
    assert_eq!(a.link.as_deref(), Some("u://a"));
    assert_eq!(b.link.as_deref(), Some("u://b"));
}
