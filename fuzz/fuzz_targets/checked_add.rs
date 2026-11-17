#![no_main]
//! Differential oracle: checked_add must agree with exact 64-bit arithmetic on every input.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (u32, u32)| {
    let (a, b) = input;
    let wide = u64::from(a) + u64::from(b);
    let want = u32::try_from(wide).ok();
    assert_eq!(rust_cicd_core::checked_add(a, b), want, "FUZZ-ORACLE checked_add({a}, {b})");
});
