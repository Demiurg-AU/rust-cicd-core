//! Unit tests (spec, not code): in their own file so the spec epoch can run the base
//! branch's tests against a PR's code.
use super::checked_add;

#[test]
fn adds() {
    assert_eq!(checked_add(2, 3), Some(5));
}

#[test]
fn detects_overflow() {
    assert_eq!(checked_add(u32::MAX, 1), None);
}
