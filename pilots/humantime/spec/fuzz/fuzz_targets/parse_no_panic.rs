#![no_main]
//! Spec pack (pilot 3b), H1 and H3 (bounded by the fuzz budget): the parsers return Ok or Err, never panic,
//! on any UTF-8 input. Oracle: absence of a panic (libFuzzer reports any panic as a crash).
use libfuzzer_sys::fuzz_target;

fuzz_target!(|s: &str| {
    let _ = humantime::parse_duration(s);
    let _ = humantime::parse_rfc3339_weak(s);
});
