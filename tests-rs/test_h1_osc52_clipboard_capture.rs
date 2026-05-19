// H1 — PROOF OF FIX: OSC 52 ("copy to clipboard") sequences emitted by a
// child process inside a psmux pane are now captured by the vt100 emulator
// and exposed via `Screen::take_clipboard()`.
//
// Background:
//   - Claude Code's /copy command writes `ESC ] 52 ; c ; <base64> ESC \`
//     to its tty.  Inside a psmux pane this byte stream went to the default
//     `impl Callbacks for ()` whose `copy_to_clipboard` method is a no-op,
//     so the payload was silently dropped.
//   - psmux already has the other direction (its own copy-mode → host
//     terminal) plumbed via `App.clipboard_osc52` (drained server-side,
//     re-emitted by the client on stdout).  We just need the parser to
//     stage the child's OSC 52 onto a slot the server can drain too.
//
// This PoC mirrors the OSC 9;4 pattern (Screen state + take_*() accessor):
//   1. `Screen` gains `osc52_clipboard: Option<(Vec<u8>, Vec<u8>)>`.
//   2. `perform.rs`'s OSC 52 dispatch arm calls `Screen::set_clipboard()`
//      in addition to invoking the existing `copy_to_clipboard` callback.
//   3. The psmux server is expected to call `take_clipboard()` in the same
//      loop it uses for the other parser-internal state (e.g. progress),
//      and stage the result onto `App.clipboard_osc52`.  That wiring is
//      OUT OF SCOPE for this PoC — but the slot is now populated, which
//      is what unblocks the rest.
//
// Required acceptance cases (from goal lock):
//   (a) `c` selector with valid base64 ST-terminated.
//   (b) BEL-terminated.
//   (c) consume-once semantics (take_clipboard returns None after a drain).
//   (d) chunked input (OSC split across `process()` calls).
//   (e) a `set-clipboard = "off"` style gate via a mocked drain — modelled
//       here as: a consumer that chooses NOT to call `take_clipboard()`
//       leaves the slot populated; a consumer that does call it drains it.
//       This is exactly the gate point the server will sit on.

const ST: &[u8] = b"\x1b\\";

fn osc52(selector: &[u8], base64_data: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(b"\x1b]52;");
    v.extend_from_slice(selector);
    v.push(b';');
    v.extend_from_slice(base64_data);
    v.extend_from_slice(ST);
    v
}

fn osc52_bel(selector: &[u8], base64_data: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(b"\x1b]52;");
    v.extend_from_slice(selector);
    v.push(b';');
    v.extend_from_slice(base64_data);
    v.push(0x07); // BEL terminator (legal OSC ST)
    v
}

fn fresh_parser() -> vt100::Parser {
    vt100::Parser::new(24, 80, 0)
}

// =============================================================================
// PART A: baseline — no OSC 52 yet → take_clipboard is None.
// =============================================================================

#[test]
fn baseline_take_clipboard_is_none_on_fresh_screen() {
    let mut p = fresh_parser();
    assert!(p.screen_mut().take_clipboard().is_none());
    assert!(p.screen().clipboard().is_none());
}

// =============================================================================
// PART B: the fix — OSC 52 with `c` selector, ST-terminated.
// =============================================================================

#[test]
fn fix_osc52_c_selector_st_terminated_is_captured() {
    // Claude Code's exact shape: selector='c', payload is valid base64.
    let payload = b"aGVsbG8td29ybGQ="; // base64("hello-world")
    let mut p = fresh_parser();
    p.process(&osc52(b"c", payload));

    let got = p
        .screen_mut()
        .take_clipboard()
        .expect("OSC 52 must populate the clipboard slot");
    assert_eq!(got.0, b"c", "selector must round-trip exactly");
    assert_eq!(got.1, payload, "base64 payload must round-trip verbatim");
}

#[test]
fn fix_osc52_peek_does_not_consume() {
    let payload = b"cGVlay10ZXN0";
    let mut p = fresh_parser();
    p.process(&osc52(b"c", payload));

    let peek = p.screen().clipboard().expect("clipboard must be staged");
    assert_eq!(peek.0, b"c");
    assert_eq!(peek.1, payload);

    // After peeking, take_clipboard still drains.
    let drained = p.screen_mut().take_clipboard().expect("not yet drained");
    assert_eq!(drained.0, b"c");
    assert_eq!(drained.1, payload);
}

// =============================================================================
// PART C: BEL-terminated variant.
// =============================================================================

#[test]
fn fix_osc52_c_selector_bel_terminated_is_captured() {
    let payload = b"YmVsLXRlcm0=";
    let mut p = fresh_parser();
    p.process(&osc52_bel(b"c", payload));

    let got = p
        .screen_mut()
        .take_clipboard()
        .expect("BEL-terminated OSC 52 must populate clipboard");
    assert_eq!(got.0, b"c");
    assert_eq!(got.1, payload);
    assert!(
        !p.screen_mut().take_audible_bell(),
        "BEL terminator of an OSC must NOT count as audible bell"
    );
}

// =============================================================================
// PART D: consume-once semantics.
// =============================================================================

#[test]
fn fix_consume_once_returns_none_on_second_take() {
    let payload = b"Y29uc3VtZS1vbmNl";
    let mut p = fresh_parser();
    p.process(&osc52(b"c", payload));

    assert!(p.screen_mut().take_clipboard().is_some(), "first take drains");
    assert!(
        p.screen_mut().take_clipboard().is_none(),
        "second take must be None — slot was drained"
    );
}

#[test]
fn fix_new_osc52_after_drain_repopulates() {
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b"Zmlyc3Q="));
    let first = p.screen_mut().take_clipboard().unwrap();
    assert_eq!(first.1, b"Zmlyc3Q=");

    p.process(&osc52(b"c", b"c2Vjb25k"));
    let second = p
        .screen_mut()
        .take_clipboard()
        .expect("a new OSC 52 after a drain must re-populate the slot");
    assert_eq!(second.1, b"c2Vjb25k");
}

#[test]
fn fix_back_to_back_osc52_without_drain_overwrites() {
    // If a child emits two OSC 52s before the server drains, the latest
    // wins.  Acceptable behaviour: clipboard is "current selection", not
    // a queue.  This matches xterm and Windows Terminal semantics.
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b"b2xkLXZhbHVl"));
    p.process(&osc52(b"c", b"bmV3LXZhbHVl"));
    let got = p.screen_mut().take_clipboard().unwrap();
    assert_eq!(got.1, b"bmV3LXZhbHVl", "second OSC 52 must overwrite first");
}

// =============================================================================
// PART E: chunked input — OSC may be split anywhere across `process()` calls.
// =============================================================================

#[test]
fn fix_chunked_osc52_is_stitched() {
    let mut p = fresh_parser();
    // Split mid-base64.  Full payload is base64("chunked") == "Y2h1bmtlZA==".
    p.process(b"\x1b]52;c;Y2h1bm");
    assert!(
        p.screen().clipboard().is_none(),
        "before terminator: must not be staged"
    );
    p.process(b"tlZA==\x1b\\");
    let got = p
        .screen_mut()
        .take_clipboard()
        .expect("after terminator: must be staged");
    assert_eq!(got.0, b"c");
    assert_eq!(got.1, b"Y2h1bmtlZA=="); // base64("chunked")
}

#[test]
fn fix_chunked_at_introducer_is_stitched() {
    let mut p = fresh_parser();
    // Split right after the ESC introducer.
    p.process(b"\x1b");
    p.process(b"]52;c;");
    p.process(b"WA==\x1b\\");
    let got = p.screen_mut().take_clipboard().expect("chunk split at ESC");
    assert_eq!(got.1, b"WA=="); // base64("X")
}

// =============================================================================
// PART F: gate / "set-clipboard = off" — mocked drain.
//
// Mirror what `App.clipboard_osc52` does server-side: a `MockDrain` policy
// that decides whether to consume or discard the staged payload.
// =============================================================================

struct MockDrain {
    enabled: bool,
    last_seen: Option<(Vec<u8>, Vec<u8>)>,
}

impl MockDrain {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            last_seen: None,
        }
    }

    /// Mirrors what the server loop would do once per tick: pull the
    /// staged clipboard if the `set-clipboard` option allows it, otherwise
    /// leave it staged (and a later policy change would still see it).
    fn drain(&mut self, parser: &mut vt100::Parser) {
        if self.enabled {
            if let Some(pair) = parser.screen_mut().take_clipboard() {
                self.last_seen = Some(pair);
            }
        }
        // else: do nothing — slot remains for a later policy-on read.
    }
}

#[test]
fn fix_gate_off_leaves_payload_staged() {
    let mut p = fresh_parser();
    let mut drain = MockDrain::new(false); // set-clipboard = off
    p.process(&osc52(b"c", b"Z2F0ZS1vZmY="));
    drain.drain(&mut p);
    assert!(drain.last_seen.is_none(), "drain disabled — must not capture");

    // Slot is still populated because no one drained it.
    assert!(
        p.screen().clipboard().is_some(),
        "with drain off the staged payload must remain available"
    );
}

#[test]
fn fix_gate_on_then_off_then_on_still_sees_latest() {
    let mut p = fresh_parser();
    let mut drain_off = MockDrain::new(false);
    let mut drain_on = MockDrain::new(true);

    p.process(&osc52(b"c", b"YQ=="));
    drain_off.drain(&mut p); // policy off — payload still staged

    p.process(&osc52(b"c", b"Yg==")); // overwrites
    drain_on.drain(&mut p);

    assert!(drain_off.last_seen.is_none());
    let seen = drain_on.last_seen.expect("drain on must capture");
    assert_eq!(seen.1, b"Yg==", "policy-on drain must see latest payload");
}

#[test]
fn fix_gate_on_drains_and_clears_slot() {
    let mut p = fresh_parser();
    let mut drain = MockDrain::new(true);
    p.process(&osc52(b"c", b"ZHJhaW4=")); // base64("drain")
    drain.drain(&mut p);

    let seen = drain.last_seen.expect("drain on captures");
    assert_eq!(seen.0, b"c");
    assert_eq!(seen.1, b"ZHJhaW4=");

    // Slot is cleared after a successful drain.
    assert!(
        p.screen().clipboard().is_none(),
        "slot must be cleared after successful drain"
    );
}

// =============================================================================
// PART G: side-effect isolation — OSC 52 must not pollute other channels.
// =============================================================================

#[test]
fn fix_osc52_does_not_appear_in_screen_contents() {
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b"YWJj"));
    let contents = p.screen().contents();
    assert!(!contents.contains("\x1b]"), "ESC ] leaked into contents");
    assert!(!contents.contains("YWJj"), "base64 payload leaked into contents");
}

#[test]
fn fix_osc52_does_not_set_title_or_path_or_progress() {
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b"YWJj"));
    assert_eq!(p.screen().title(), "", "OSC 52 must not touch title");
    assert_eq!(p.screen().path(), None, "OSC 52 must not touch path");
    assert_eq!(p.screen().progress(), None, "OSC 52 must not touch progress");
}

#[test]
fn fix_state_machine_ready_for_next_sequence_after_osc52() {
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b"YWJj"));
    p.process(b"hello");
    assert!(p.screen().contents().contains("hello"));
}

// =============================================================================
// PART H: real-world Claude Code shape.
// =============================================================================

#[test]
fn fix_claude_code_slash_copy_shape_is_captured() {
    // The exact shape Claude Code's /copy uses:
    //   ESC ] 52 ; c ; <base64> ESC \
    // Round-tripping a multi-line payload to make sure base64 with padding
    // and length > 80 works.
    let raw = "line one\nline two\nline three with some longer text to exceed 60 chars";
    let b64 = simple_b64(raw.as_bytes());
    let mut p = fresh_parser();
    p.process(&osc52(b"c", b64.as_bytes()));

    let got = p.screen_mut().take_clipboard().expect("captured");
    assert_eq!(got.0, b"c");
    assert_eq!(got.1, b64.as_bytes());
}

/// Minimal base64 encoder — avoids pulling in `base64` as a dev-dep just
/// for fixture construction.
fn simple_b64(input: &[u8]) -> String {
    const ALPHA: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i + 3 <= input.len() {
        let n = ((input[i] as u32) << 16)
            | ((input[i + 1] as u32) << 8)
            | (input[i + 2] as u32);
        out.push(ALPHA[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHA[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHA[((n >> 6) & 0x3f) as usize] as char);
        out.push(ALPHA[(n & 0x3f) as usize] as char);
        i += 3;
    }
    let rem = input.len() - i;
    if rem == 1 {
        let n = (input[i] as u32) << 16;
        out.push(ALPHA[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHA[((n >> 12) & 0x3f) as usize] as char);
        out.push('=');
        out.push('=');
    } else if rem == 2 {
        let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8);
        out.push(ALPHA[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHA[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHA[((n >> 6) & 0x3f) as usize] as char);
        out.push('=');
    }
    out
}
