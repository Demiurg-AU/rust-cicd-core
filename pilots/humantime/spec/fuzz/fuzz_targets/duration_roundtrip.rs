#![no_main]
//! Spec pack (pilot 3b), H2: format_duration then parse_duration returns the same Duration.
//! Domain: seconds < 10^12 (about 31 700 years), any nanoseconds. Oracle: the round trip itself
//! (the formatter and the parser are checked against each other, not against an independent reference).
use libfuzzer_sys::fuzz_target;
use std::time::Duration;

fuzz_target!(|input: (u64, u32)| {
    let (secs, nanos) = input;
    let d = Duration::new(secs % 1_000_000_000_000, nanos % 1_000_000_000);
    let text = humantime::format_duration(d).to_string();
    let back = humantime::parse_duration(&text);
    assert_eq!(back, Ok(d), "FUZZ-ORACLE roundtrip {d:?} -> {text:?}");
});
