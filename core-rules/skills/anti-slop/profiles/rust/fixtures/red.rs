//! Red fixture: every construct here must produce at least one anti-slop finding.
//! One pattern per function, so inverting a lint breaks this file's expectation.

use std::num::NonZeroU32;

/// clippy::unwrap_used — throws the parse error away and panics in its place.
pub fn port_of(raw: &str) -> u16 {
    raw.parse().unwrap()
}

/// clippy::expect_used — a nicer panic message is still a panic.
pub fn retries_of(raw: &str) -> u32 {
    raw.parse().expect("retries must be a number")
}

/// clippy::as_conversions — silent truncation where a fallible convert belongs.
pub fn shard_index(total: u64) -> u32 {
    total as u32
}

/// clippy::undocumented_unsafe_blocks — no stated invariant for a reviewer to check.
pub fn nonzero(count: u32) -> NonZeroU32 {
    unsafe { NonZeroU32::new_unchecked(count) }
}
