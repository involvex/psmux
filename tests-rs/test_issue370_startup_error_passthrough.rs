// Issue #370: server startup spawn errors must be surfaced to the user instead
// of being silently buried in ~/.psmux/server-startup.log.
//
// These unit tests cover the reader/freshness logic that the client uses to
// echo the real failure reason. They drive the path-injectable core
// (`read_fresh_startup_error_at`) against per-test temp files so they never
// mutate the process-global USERPROFILE/HOME env — which would race the
// issue-167 log tests that share this test binary.
//
// The end-to-end proof (a bad default-shell path producing a visible terminal
// error) lives in tests/test_issue370_silent_startup_errors.ps1.

fn write_log(path: &std::path::Path, when_epoch: u64, error_body: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    let body = format!(
        "psmux server startup error\n\
         ==========================\n\
         psmux version : 3.3.5\n\
         when (epoch s): {when}\n\
         os.family     : windows\n\
         \n\
         error:\n\
         {err}\n\
         \n\
         spawn context:\n\
         \x20\x20CWD : nope\n",
        when = when_epoch,
        err = error_body,
    );
    std::fs::write(path, body).unwrap();
}

// Per-test temp path (no Date/random, which are unavailable). The tag keeps
// tests independent so they remain parallel-safe.
fn temp_log(tag: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("psmux_iss370_{}_server-startup.log", tag))
}

#[test]
fn fresh_error_is_surfaced_with_path() {
    let path = temp_log("fresh");
    write_log(
        &path,
        2_000_000_000,
        "  spawn shell error: CreateProcessW `\"C:/nope/bash.exe\"` failed: The system cannot find the path specified. (os error 3)",
    );

    let got = crate::server::read_fresh_startup_error_at(path.to_str().unwrap(), 2_000_000_000);
    assert!(got.is_some(), "fresh log should be surfaced");
    let (reason, returned_path) = got.unwrap();
    assert!(reason.contains("spawn shell error"), "reason should carry the spawn error, got: {reason}");
    assert!(reason.contains("cannot find the path specified"), "reason should carry GetLastError text, got: {reason}");
    assert_eq!(returned_path, path.to_str().unwrap(), "should return the log path it read");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn stale_log_is_ignored() {
    let path = temp_log("stale");
    write_log(&path, 100_000_000, "  STALE should not appear");

    // Current attempt started much later → stale log must be ignored.
    let got = crate::server::read_fresh_startup_error_at(path.to_str().unwrap(), 2_000_000_000);
    assert!(got.is_none(), "stale log (older than attempt start) must NOT be surfaced");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn slack_allows_same_second_or_slightly_earlier_log() {
    let path = temp_log("slack");
    // Log timestamped 1s BEFORE the attempt start (clock granularity); the 2s
    // slack window must still treat it as current.
    write_log(&path, 1_999_999_999, "  spawn shell error: boom");
    let got = crate::server::read_fresh_startup_error_at(path.to_str().unwrap(), 2_000_000_000);
    assert!(got.is_some(), "log within 2s slack must still be surfaced");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn missing_log_returns_none() {
    let path = temp_log("missing");
    let _ = std::fs::remove_file(&path);
    let got = crate::server::read_fresh_startup_error_at(path.to_str().unwrap(), 0);
    assert!(got.is_none(), "no log file → no reason to surface");
}

#[test]
fn multiline_error_block_is_joined() {
    let path = temp_log("multiline");
    write_log(&path, 2_000_000_000, "  line one of error\n  line two continues");
    let got = crate::server::read_fresh_startup_error_at(path.to_str().unwrap(), 2_000_000_000);
    assert!(got.is_some());
    let (reason, _) = got.unwrap();
    assert!(reason.contains("line one of error"), "got: {reason}");
    assert!(reason.contains("line two continues"), "multi-line error should be joined, got: {reason}");

    let _ = std::fs::remove_file(&path);
}
