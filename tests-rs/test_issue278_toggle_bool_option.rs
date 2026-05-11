use super::*;
use crate::types::{AppState, Node, LayoutKind};

fn mock_app() -> AppState {
    let mut app = AppState::new("test_session".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id,
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
    }
}

fn mock_app_with_window() -> AppState {
    let mut app = mock_app();
    app.windows.push(make_window("shell", 0));
    app
}

// --- is_boolean_option ---

#[test]
fn mouse_is_boolean() {
    assert!(crate::server::options::is_boolean_option("mouse"));
}

#[test]
fn focus_events_is_boolean() {
    assert!(crate::server::options::is_boolean_option("focus-events"));
}

#[test]
fn status_is_boolean() {
    assert!(crate::server::options::is_boolean_option("status"));
}

#[test]
fn escape_time_is_not_boolean() {
    assert!(!crate::server::options::is_boolean_option("escape-time"));
}

#[test]
fn status_left_is_not_boolean() {
    assert!(!crate::server::options::is_boolean_option("status-left"));
}

#[test]
fn history_limit_is_not_boolean() {
    assert!(!crate::server::options::is_boolean_option("history-limit"));
}

// --- toggle_option ---

#[test]
fn toggle_mouse_on_to_off() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    let toggled = crate::server::options::toggle_option(&mut app, "mouse");
    assert!(toggled, "mouse should be togglable");
    assert!(!app.mouse_enabled, "mouse should be off after toggle");
}

#[test]
fn toggle_mouse_off_to_on() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = false;
    let toggled = crate::server::options::toggle_option(&mut app, "mouse");
    assert!(toggled, "mouse should be togglable");
    assert!(app.mouse_enabled, "mouse should be on after toggle");
}

#[test]
fn toggle_mouse_roundtrip() {
    let mut app = mock_app_with_window();
    let initial = app.mouse_enabled;
    crate::server::options::toggle_option(&mut app, "mouse");
    assert_ne!(app.mouse_enabled, initial);
    crate::server::options::toggle_option(&mut app, "mouse");
    assert_eq!(app.mouse_enabled, initial);
}

#[test]
fn toggle_focus_events() {
    let mut app = mock_app_with_window();
    let before = app.focus_events;
    crate::server::options::toggle_option(&mut app, "focus-events");
    assert_ne!(app.focus_events, before);
}

#[test]
fn toggle_synchronize_panes() {
    let mut app = mock_app_with_window();
    let before = app.sync_input;
    crate::server::options::toggle_option(&mut app, "synchronize-panes");
    assert_ne!(app.sync_input, before);
}

#[test]
fn toggle_non_boolean_returns_false() {
    let mut app = mock_app_with_window();
    let toggled = crate::server::options::toggle_option(&mut app, "escape-time");
    assert!(!toggled, "escape-time is not boolean, toggle should return false");
}

#[test]
fn toggle_non_boolean_does_not_change_value() {
    let mut app = mock_app_with_window();
    let before = app.escape_time_ms;
    crate::server::options::toggle_option(&mut app, "escape-time");
    assert_eq!(app.escape_time_ms, before, "Non-boolean option should be unchanged");
}

// --- config parse_set_option toggle path ---

#[test]
fn config_set_mouse_no_value_toggles() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    crate::config::parse_config_content(&mut app, "set -g mouse\n");
    assert!(!app.mouse_enabled, "set mouse with no value should toggle on->off");
}

#[test]
fn config_set_mouse_no_value_toggles_off_to_on() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = false;
    crate::config::parse_config_content(&mut app, "set -g mouse\n");
    assert!(app.mouse_enabled, "set mouse with no value should toggle off->on");
}

#[test]
fn config_set_option_mouse_no_value_toggles() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    crate::config::parse_config_content(&mut app, "set-option -g mouse\n");
    assert!(!app.mouse_enabled, "set-option mouse with no value should toggle");
}

#[test]
fn config_set_mouse_explicit_on_still_works() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = false;
    crate::config::parse_config_content(&mut app, "set -g mouse on\n");
    assert!(app.mouse_enabled, "set mouse on should set to on");
}

#[test]
fn config_set_mouse_explicit_off_still_works() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    crate::config::parse_config_content(&mut app, "set -g mouse off\n");
    assert!(!app.mouse_enabled, "set mouse off should set to off");
}

#[test]
fn config_set_focus_events_no_value_toggles() {
    let mut app = mock_app_with_window();
    let before = app.focus_events;
    crate::config::parse_config_content(&mut app, "set -g focus-events\n");
    assert_ne!(app.focus_events, before, "focus-events should toggle");
}

#[test]
fn config_set_non_boolean_no_value_is_noop() {
    let mut app = mock_app_with_window();
    let before = app.escape_time_ms;
    crate::config::parse_config_content(&mut app, "set -g escape-time\n");
    assert_eq!(app.escape_time_ms, before, "Non-boolean without value should not change");
}

#[test]
fn config_set_without_g_flag_toggles() {
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    crate::config::parse_config_content(&mut app, "set mouse\n");
    assert!(!app.mouse_enabled, "set mouse (no -g flag) should still toggle");
}

// --- Exact user scenario from issue #278 ---

#[test]
fn issue278_bind_m_set_mouse_simulated() {
    // The user's config: bind m set mouse
    // When triggered, it runs "set mouse" which should toggle
    let mut app = mock_app_with_window();
    app.mouse_enabled = true;
    
    // Simulate what execute_command_string does when keybinding triggers "set mouse"
    crate::config::parse_config_line(&mut app, "set mouse");
    assert!(!app.mouse_enabled, "bind m set mouse: first press should toggle on->off");
    
    crate::config::parse_config_line(&mut app, "set mouse");
    assert!(app.mouse_enabled, "bind m set mouse: second press should toggle off->on");
}

// --- All boolean options should be recognized ---

#[test]
fn all_boolean_options_recognized() {
    let booleans = [
        "mouse", "scroll-enter-copy-mode", "pwsh-mouse-selection",
        "mouse-selection", "paste-detection", "choose-tree-preview",
        "focus-events", "renumber-windows", "automatic-rename",
        "allow-rename", "allow-set-title", "monitor-activity",
        "visual-activity", "synchronize-panes", "remain-on-exit",
        "destroy-unattached", "exit-empty", "set-titles",
        "aggressive-resize", "visual-bell", "prediction-dimming",
        "allow-predictions", "cursor-blink", "warm",
        "alternate-screen", "claude-code-fix-tty",
        "claude-code-force-interactive", "status",
    ];
    for name in &booleans {
        assert!(
            crate::server::options::is_boolean_option(name),
            "{} should be recognized as boolean",
            name
        );
    }
}
