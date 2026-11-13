//! Root of the `zorcerer-tests` module.
//!
//! Test discovery walks every file reachable from this root, so importing the
//! library is enough to run its test blocks. Keeping the library as a named
//! dependency instead of the test's root module also makes `@import("root")`
//! inside `src/` resolve to `src/root.zig` during tests, not to Zig's generated
//! test runner.

test {
    _ = @import("zorcerer");
}
