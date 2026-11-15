//! Minimal library used to exercise the CI core.

/// Adds two numbers, returning `None` on overflow.
#[must_use]
pub fn checked_add(a: u32, b: u32) -> Option<u32> {
    a.checked_add(b)
}

#[cfg(test)]
mod tests {
    use super::checked_add;

    #[test]
    fn adds() {
        assert_eq!(checked_add(2, 3), Some(5));
    }

    #[test]
    fn detects_overflow() {
        assert_eq!(checked_add(u32::MAX, 1), None);
    }
}
