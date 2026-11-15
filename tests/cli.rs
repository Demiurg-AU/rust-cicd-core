//! End-to-end test: runs the compiled binary and checks its output.
use std::process::Command;

#[test]
fn binary_prints_sum() {
    let out = Command::new(env!("CARGO_BIN_EXE_rust-cicd-core"))
        .output()
        .expect("binary should start");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "5");
}
