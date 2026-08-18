//! Green fixture: idiomatic evidence-preserving Rust. Must produce zero findings.

use std::num::{ParseIntError, TryFromIntError};

/// The parsed shape, named once at the boundary that produces it.
#[derive(Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

/// Parse an untrusted string at its boundary and hand the caller the failure.
pub fn parse_endpoint(raw: &str) -> Result<Endpoint, ParseIntError> {
    let (host, port) = match raw.split_once(':') {
        Some(split) => split,
        None => (raw, "443"),
    };
    Ok(Endpoint {
        host: host.to_owned(),
        port: port.parse()?,
    })
}

/// The fallible conversion reports the overflow an `as` cast would have hidden.
pub fn shard_index(total: u64) -> Result<u32, TryFromIntError> {
    u32::try_from(total)
}

/// A stated invariant is what makes an `unsafe` block reviewable.
pub fn ascii_label(bytes: &[u8]) -> Option<&str> {
    if !bytes.is_ascii() {
        return None;
    }
    // SAFETY: is_ascii() above proves every byte is valid single-byte UTF-8.
    Some(unsafe { std::str::from_utf8_unchecked(bytes) })
}

#[cfg(test)]
mod tests {
    use super::*;

    // A `?`-returning test reports the parse error rather than unwrapping it.
    #[test]
    fn parses_an_endpoint() -> Result<(), ParseIntError> {
        assert_eq!(parse_endpoint("db.internal:5432")?.port, 5432);
        Ok(())
    }

    #[test]
    fn defaults_a_missing_port() -> Result<(), ParseIntError> {
        assert_eq!(parse_endpoint("db.internal")?.port, 443);
        Ok(())
    }
}
