//! Spec pack (pilot 3b): Kani harness for humantime. Verification code, not part of the crate.
use crate::parse_rfc3339_weak;

/// H3 (bounded): parse_rfc3339_weak does not panic on "2000-02-DDT00:00:00Z" for any two day digits
/// (100 inputs: day 00, 01-29 valid in a leap February, 30-99 out of range).
#[kani::proof]
#[kani::unwind(22)]
fn kani_rfc3339_weak_day_digits_no_panic() {
    let mut b = *b"2000-02-00T00:00:00Z";
    for i in [8usize, 9] {
        let d: u8 = kani::any();
        kani::assume(d <= 9);
        b[i] = b'0' + d;
    }
    let s = core::str::from_utf8(&b).unwrap();
    let r = parse_rfc3339_weak(s);
    kani::cover!(r.is_ok(), "a valid day parses");
    kani::cover!(r.is_err(), "an impossible day is rejected");
}
