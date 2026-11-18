//! Kani harnesses (compiled only under `cargo kani`). Each harness has covers: a proof whose
//! covers are not SATISFIED is vacuous and the gate rejects it (see docs/kani-playbook.md).
use super::checked_add;

#[kani::proof]
fn kani_checked_add_matches_spec() {
    // UNBOUNDED over its input: every (a, b) in u32 x u32, no loops to unwind.
    let (a, b): (u32, u32) = (kani::any(), kani::any());
    let wide = u64::from(a) + u64::from(b);
    let got = checked_add(a, b);
    kani::cover!(got.is_none(), "overflow reached");
    kani::cover!(got.is_some(), "in-range reached");
    match got {
        Some(s) => assert!(wide <= u64::from(u32::MAX) && u64::from(s) == wide),
        None => assert!(wide > u64::from(u32::MAX)),
    }
}
