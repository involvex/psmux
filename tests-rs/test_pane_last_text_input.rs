// `#{pane_last_text_input}` — the text-input-route classifier that gates the
// per-pane last-text-input timestamp. Only printable text counts; control
// codes, Enter / arrows / shortcuts, and Ctrl/Alt chords do not.
//
// The route separation itself is structural, not tested here: the injected
// route (send-keys / send-paste / send-text) goes through send_text_to_active,
// never forward_key_to_active, so it can't reach this signal. Caveat: a bot
// that injects real key events through the interactive route WILL update it.

use crate::input::is_text_input_key;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

fn k(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, mods)
}

#[test]
fn printable_text_counts() {
    assert!(is_text_input_key(&k(KeyCode::Char('a'), KeyModifiers::NONE)));
    assert!(is_text_input_key(&k(KeyCode::Char('Z'), KeyModifiers::SHIFT))); // capitals
    assert!(is_text_input_key(&k(KeyCode::Char(' '), KeyModifiers::NONE))); // space is text
    assert!(is_text_input_key(&k(KeyCode::Char('é'), KeyModifiers::NONE))); // non-ASCII
}

#[test]
fn control_nav_and_modified_do_not_count() {
    assert!(!is_text_input_key(&k(KeyCode::Char('c'), KeyModifiers::CONTROL))); // Ctrl-C
    assert!(!is_text_input_key(&k(KeyCode::Char('x'), KeyModifiers::ALT))); // Alt-x
    assert!(!is_text_input_key(&k(KeyCode::Enter, KeyModifiers::NONE)));
    assert!(!is_text_input_key(&k(KeyCode::Tab, KeyModifiers::NONE)));
    assert!(!is_text_input_key(&k(KeyCode::Backspace, KeyModifiers::NONE)));
    assert!(!is_text_input_key(&k(KeyCode::Left, KeyModifiers::NONE))); // navigation
    assert!(!is_text_input_key(&k(KeyCode::F(9), KeyModifiers::NONE))); // function key
}
