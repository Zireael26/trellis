//! Carved-out fixture: an integration test, matched by the `**/tests/**` carve-out
//! glob in hooks/lib/slop-patterns.sh. `.expect(` is idiomatic here — a test's panic
//! IS its failure report — and the path glob, not a grep exception, is what keeps it
//! quiet. The tripwire's `rs-expect` row has no escape hatch by design, which is why
//! this line lives in a carved-out path instead of in green.rs. Clippy reaches this
//! target only under `--all-targets`; see ../../README.md § Self-test.

use anti_slop_fixtures::parse_endpoint;

#[test]
fn parses_the_port() {
    let endpoint = parse_endpoint("db.internal:5432").expect("fixture endpoint parses");
    assert_eq!(endpoint.port, 5432);
}
