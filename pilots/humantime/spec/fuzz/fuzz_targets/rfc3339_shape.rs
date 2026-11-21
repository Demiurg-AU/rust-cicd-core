#![no_main]
//! Spec pack (pilot 3b), H3 on the inputs a random string almost never reaches (K5 showed parse_no_panic covered
//! under 10% of date.rs): every "DDDD-DD-DDTDD:DD:DDZ" with any digits. Oracle: no panic, and every accepted
//! time formats back (format_rfc3339_seconds) to a string that parses to the same time.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|digits: [u8; 14]| {
    let mut b = *b"0000-00-00T00:00:00Z";
    for (k, i) in [0usize, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18].into_iter().enumerate() {
        b[i] = b'0' + digits[k] % 10;
    }
    let s = std::str::from_utf8(&b).expect("ASCII by construction");
    if let Ok(t) = humantime::parse_rfc3339_weak(s) {
        let again = humantime::format_rfc3339_seconds(t).to_string();
        assert_eq!(humantime::parse_rfc3339_weak(&again), Ok(t), "FUZZ-ORACLE rfc3339 {s} -> {again}");
    }
});
