-- Formal model of `checked_add` (src/lib.rs), with an explicit bound `max` (u32::MAX in Rust).
-- This is a model, not a proof about the compiled Rust code; the link is proof-map.tsv + tests.

def checkedAdd (a b max : Nat) : Option Nat :=
  if a + b ≤ max then some (a + b) else none

theorem checkedAdd_none_iff_overflow (a b max : Nat) :
    checkedAdd a b max = none ↔ max < a + b := by
  unfold checkedAdd
  split <;> simp <;> omega

theorem checkedAdd_some_is_sum (a b max s : Nat) (h : checkedAdd a b max = some s) :
    s = a + b := by
  unfold checkedAdd at h
  split at h <;> simp_all
