#![no_main]
//! CANARY: the same oracle against a planted bug (wrapping instead of checked).
//! The fuzz workflow requires this target to CRASH; if it survives, the fuzzer/oracle is blind.
use libfuzzer_sys::fuzz_target;

fn planted_bug(a: u32, b: u32) -> Option<u32> {
    Some(a.wrapping_add(b))
}

fuzz_target!(|input: (u32, u32)| {
    let (a, b) = input;
    let wide = u64::from(a) + u64::from(b);
    let want = u32::try_from(wide).ok();
    assert_eq!(planted_bug(a, b), want, "FUZZ-ORACLE canary({a}, {b})");
});
