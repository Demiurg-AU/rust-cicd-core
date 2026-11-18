//! Minimal library used to exercise the CI core.

/// Adds two numbers, returning `None` on overflow.
#[must_use]
pub fn checked_add(a: u32, b: u32) -> Option<u32> {
    a.checked_add(b)
}

#[cfg(kani)]
mod kani_proofs;

#[cfg(test)]
mod tests;
