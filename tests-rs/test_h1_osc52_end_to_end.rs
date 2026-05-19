// H1 — End-to-end PoC for OSC 52 pane-to-host forwarding.
//
// This test models the FULL flow that the parser fix unblocks, without
// touching `src/server/mod.rs` or `src/client.rs` (PoC constraint):
//
//   1. Child process inside a pane writes `ESC ] 52 ; c ; <b64> ESC \`.
//      → Modelled by feeding bytes into `vt100::Parser`.
//
//   2. Parser stages the (selector, base64) pair on `Screen` via the new
//      `set_clipboard` hook in `perform.rs`.
//      → Asserted via `take_clipboard()`.
//
//   3. Server drains the slot once per dump-state tick and stages the
//      *decoded* text onto `App.clipboard_osc52: Option<String>`.
//      → Modelled by `MockServer::drain_pane_clipboard()` below.  This
//        mirrors the one-line change needed in `src/server/mod.rs`'s
//        dump-state loop (alongside the existing `app.clipboard_osc52.take()`
//        at server/mod.rs:1531 and :4474).
//
//   4. Server emits the field into the JSON dump; client receives it and
//      calls `crate::copy_mode::emit_osc52(stdout, &clip_text)` which
//      base64-encodes the text and writes `ESC ] 52 ; c ; <b64> BEL`.
//      → Modelled by calling the real `emit_osc52` helper.  Wait — that
//        function is private to the crate, so we re-implement the exact
//        byte shape here.  This keeps the test in the same crate as a
//        plain integration test and avoids leaking internals.
//
// The acceptance bar: the bytes a host terminal (Windows Terminal) would
// see on the client's stdout MUST contain a well-formed OSC 52 carrying
// a base64 of the original child payload text.

const ST_BEL: u8 = 0x07;

/// Minimal base64 decoder for the test payload — we don't pull in `base64`
/// for fixture parsing.
fn b64_decode(input: &[u8]) -> Vec<u8> {
    const REV: [i16; 256] = build_rev();
    const fn build_rev() -> [i16; 256] {
        let mut r = [-1i16; 256];
        let alpha = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut i = 0;
        while i < 64 {
            r[alpha[i] as usize] = i as i16;
            i += 1;
        }
        r
    }
    let trimmed: Vec<u8> =
        input.iter().copied().filter(|b| *b != b'=' && !b.is_ascii_whitespace()).collect();
    let mut out = Vec::new();
    let mut acc: u32 = 0;
    let mut bits = 0;
    for b in trimmed {
        let v = REV[b as usize];
        if v < 0 {
            continue;
        }
        acc = (acc << 6) | (v as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xff) as u8);
        }
    }
    out
}

fn b64_encode(input: &[u8]) -> String {
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

/// Models the *one* line of code the psmux server needs to add to its
/// dump-state loop, right next to the existing
/// `if let Some(clip_text) = app.clipboard_osc52.take()` at
/// `src/server/mod.rs:1531`:
///
/// ```ignore
/// for pane in &mut app.panes {
///     if let Some((_sel, b64_payload)) = pane.parser.screen_mut().take_clipboard() {
///         if let Ok(text) = String::from_utf8(base64_decode(&b64_payload)) {
///             app.clipboard_osc52 = Some(text);
///         }
///     }
/// }
/// ```
///
/// This struct stands in for `App` for the purposes of the test.
struct MockApp {
    clipboard_osc52: Option<String>,
}

impl MockApp {
    fn new() -> Self {
        Self { clipboard_osc52: None }
    }

    /// Mirror of the server drain step (see top-of-file comment).
    fn drain_pane(&mut self, parser: &mut vt100::Parser) {
        if let Some((_selector, b64_payload)) = parser.screen_mut().take_clipboard() {
            let decoded = b64_decode(&b64_payload);
            if let Ok(text) = String::from_utf8(decoded) {
                self.clipboard_osc52 = Some(text);
            }
        }
    }
}

/// Mirror of `src/copy_mode.rs::emit_osc52` — the exact bytes the client
/// writes to its stdout (which the host terminal reads).
fn emit_osc52_to_buf(buf: &mut Vec<u8>, text: &str) {
    let encoded = b64_encode(text.as_bytes());
    buf.extend_from_slice(b"\x1b]52;c;");
    buf.extend_from_slice(encoded.as_bytes());
    buf.push(ST_BEL);
}

/// Full pipeline: pane emits OSC 52 → parser captures → server drains →
/// client re-emits to stdout.  We then look for the OSC 52 framing and
/// for a base64 that decodes back to the original child payload.
fn pipeline(child_payload: &str) -> Vec<u8> {
    // (1) Child writes OSC 52 to pane tty.
    let mut child_out = Vec::new();
    child_out.extend_from_slice(b"\x1b]52;c;");
    child_out.extend_from_slice(b64_encode(child_payload.as_bytes()).as_bytes());
    child_out.extend_from_slice(b"\x1b\\");

    // (2) Parser receives the bytes.
    let mut parser = vt100::Parser::new(24, 80, 0);
    parser.process(&child_out);

    // (3) Server drains the staged slot.
    let mut app = MockApp::new();
    app.drain_pane(&mut parser);
    assert!(app.clipboard_osc52.is_some(), "server drain must have staged text");

    // (4) Client emits OSC 52 to its stdout (what Windows Terminal sees).
    let mut client_stdout = Vec::new();
    if let Some(text) = app.clipboard_osc52.take() {
        emit_osc52_to_buf(&mut client_stdout, &text);
    }
    client_stdout
}

#[test]
fn end_to_end_round_trips_simple_ascii() {
    let payload = "hello-world";
    let client_out = pipeline(payload);

    // The client must have produced exactly one OSC 52 frame.
    let intro = b"\x1b]52;c;";
    let pos = client_out
        .windows(intro.len())
        .position(|w| w == intro)
        .expect("client stdout must contain OSC 52 introducer");
    let after = &client_out[pos + intro.len()..];

    // BEL terminator.
    let bel_pos = after.iter().position(|b| *b == 0x07).expect("BEL terminator");
    let b64 = &after[..bel_pos];
    let decoded = b64_decode(b64);
    assert_eq!(
        decoded, payload.as_bytes(),
        "OSC 52 on client stdout must carry the original child payload"
    );
}

#[test]
fn end_to_end_round_trips_multiline() {
    let payload = "line one\nline two\n  indented\nfinal line";
    let client_out = pipeline(payload);
    let intro = b"\x1b]52;c;";
    let pos = client_out
        .windows(intro.len())
        .position(|w| w == intro)
        .unwrap();
    let after = &client_out[pos + intro.len()..];
    let bel_pos = after.iter().position(|b| *b == 0x07).unwrap();
    let decoded = b64_decode(&after[..bel_pos]);
    assert_eq!(decoded, payload.as_bytes());
}

#[test]
fn end_to_end_round_trips_unicode() {
    let payload = "snowman: ☃  fire: 🔥  jp: こんにちは";
    let client_out = pipeline(payload);
    let intro = b"\x1b]52;c;";
    let pos = client_out
        .windows(intro.len())
        .position(|w| w == intro)
        .unwrap();
    let after = &client_out[pos + intro.len()..];
    let bel_pos = after.iter().position(|b| *b == 0x07).unwrap();
    let decoded = b64_decode(&after[..bel_pos]);
    assert_eq!(decoded, payload.as_bytes());
}

#[test]
fn end_to_end_claude_code_slash_copy_shape() {
    // The actual shape Claude Code's /copy emits is a moderately large
    // multi-line block.  Make sure base64 padding and lengths > 80 work
    // through the whole pipeline.
    let payload =
        "First line of code\n\
         fn foo() -> i32 {\n\
         \x20\x20\x20\x20let x = 42;\n\
         \x20\x20\x20\x20x + 1\n\
         }\n\
         // trailing comment with some =/+ characters\n";
    let client_out = pipeline(payload);
    let intro = b"\x1b]52;c;";
    let pos = client_out
        .windows(intro.len())
        .position(|w| w == intro)
        .expect("OSC 52 introducer present in client stdout");
    let after = &client_out[pos + intro.len()..];
    let bel_pos = after.iter().position(|b| *b == 0x07).unwrap();
    let decoded = b64_decode(&after[..bel_pos]);
    assert_eq!(
        decoded, payload.as_bytes(),
        "Claude /copy payload must round-trip end-to-end"
    );
}

#[test]
fn end_to_end_no_osc52_when_child_does_not_emit() {
    // Sanity: a pane that produces no OSC 52 must NOT cause the client to
    // emit one.  Otherwise we'd risk stale clipboards.
    let mut parser = vt100::Parser::new(24, 80, 0);
    parser.process(b"just some plain output\nno escape sequences here\n");
    let mut app = MockApp::new();
    app.drain_pane(&mut parser);
    assert!(app.clipboard_osc52.is_none());
}
