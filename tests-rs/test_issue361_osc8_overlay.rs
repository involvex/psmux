// Issue #361: the client-side OSC 8 overlay emitter. build_osc8_overlay() takes
// the hyperlink runs collected during a frame and produces the raw escape bytes
// that re-emit each run wrapped in OSC 8 at its screen position.
use crate::client::{build_osc8_overlay, HyperlinkRun};
use ratatui::style::{Color, Modifier, Style};

#[test]
fn wraps_run_in_osc8_at_position() {
    let runs = vec![HyperlinkRun {
        x: 5,
        y: 2,
        text: "link".into(),
        uri: "https://example.com".into(),
        style: Style::default().fg(Color::Red),
    }];
    let s = build_osc8_overlay(&runs);
    assert!(s.starts_with("\x1b7"), "saves cursor (DECSC)");
    assert!(s.ends_with("\x1b8"), "restores cursor (DECRC)");
    // 1-based cursor move to row 3, col 6
    assert!(s.contains("\x1b[3;6H"), "cursor move: {s:?}");
    // OSC 8 open + text + close
    assert!(
        s.contains("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\"),
        "osc8 wrap: {s:?}"
    );
    // red fg = SGR 31
    assert!(s.contains("31"), "red fg sgr: {s:?}");
}

#[test]
fn empty_runs_produce_no_output() {
    assert_eq!(build_osc8_overlay(&[]), "");
}

#[test]
fn blank_text_run_emits_no_osc8() {
    let runs = vec![HyperlinkRun {
        x: 0,
        y: 0,
        text: String::new(),
        uri: "u".into(),
        style: Style::default(),
    }];
    let s = build_osc8_overlay(&runs);
    assert!(!s.contains("\x1b]8"), "no OSC 8 for blank text: {s:?}");
}

#[test]
fn rgb_color_and_modifiers_emitted() {
    let runs = vec![HyperlinkRun {
        x: 0,
        y: 0,
        text: "x".into(),
        uri: "u".into(),
        style: Style::default()
            .fg(Color::Rgb(1, 2, 3))
            .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
    }];
    let s = build_osc8_overlay(&runs);
    assert!(s.contains("38;2;1;2;3"), "rgb fg: {s:?}");
    // bold(1) and underline(4) present in the SGR params
    assert!(s.contains(";1;") || s.contains(";1m"), "bold: {s:?}");
    assert!(s.contains(";4m") || s.contains(";4;"), "underline: {s:?}");
}

#[test]
fn two_runs_each_wrapped() {
    let runs = vec![
        HyperlinkRun { x: 0, y: 0, text: "a".into(), uri: "u1".into(), style: Style::default() },
        HyperlinkRun { x: 3, y: 1, text: "b".into(), uri: "u2".into(), style: Style::default() },
    ];
    let s = build_osc8_overlay(&runs);
    assert!(s.contains("\x1b]8;;u1\x1b\\a\x1b]8;;\x1b\\"));
    assert!(s.contains("\x1b]8;;u2\x1b\\b\x1b]8;;\x1b\\"));
    assert!(s.contains("\x1b[1;1H")); // run a at (0,0) -> 1;1
    assert!(s.contains("\x1b[2;4H")); // run b at (3,1) -> 2;4
}
