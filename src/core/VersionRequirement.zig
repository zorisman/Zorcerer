//! Minimal semantic-version requirement grammar used by plugin manifests.
//!
//! A manifest may declare an optional `[dependencies]` table whose keys are
//! plugin ids and whose values are version requirements. The grammar is
//! intentionally small:
//!
//!     *            any version
//!     1.2.3        exactly 1.2.3
//!     =1.2.3       exactly 1.2.3
//!     ^1.2.3       >=1.2.3 and <2.0.0 (npm-style 0.x rules)
//!     ~1.2.3       >=1.2.3 and <1.3.0
//!     >1.2.3       strictly newer
//!     >=1.2.3      at least 1.2.3
//!     <1.2.3       strictly older
//!     <=1.2.3      at most 1.2.3
//!
//! Only one comparator is accepted; ranges combined with `||`, hyphen ranges,
//! and x-ranges are not supported. Comparison uses semantic-version
//! precedence, so build metadata is ignored and prerelease versions sort
//! below their release.

const std = @import("std");

/// Maximum accepted length of a requirement string, in bytes.
pub const max_requirement_len: usize = 64;

/// A parsed version requirement.
///
/// The `std.SemanticVersion` payloads borrow prerelease/build text from the
/// input slice passed to `parse()`. Callers must keep that slice alive for as
/// long as the requirement value is used, or only use the value immediately.
pub const VersionRequirement = union(enum) {
    /// Accepts every valid semantic version.
    any,
    /// Requires one exact semantic version.
    exact: std.SemanticVersion,
    /// Requires a compatible version (npm-style caret range).
    caret: std.SemanticVersion,
    /// Requires the same major/minor version (tilde range).
    tilde: std.SemanticVersion,
    /// Requires a strictly newer version.
    greater: std.SemanticVersion,
    /// Requires an equal or newer version.
    greater_equal: std.SemanticVersion,
    /// Requires a strictly older version.
    less: std.SemanticVersion,
    /// Requires an equal or older version.
    less_equal: std.SemanticVersion,

    /// Parses `text` into a version requirement.
    ///
    /// Parameters:
    /// - `text`: raw TOML string value from a manifest's `[dependencies]`
    ///   table. Surrounding spaces and tabs are ignored.
    ///
    /// Returns the parsed requirement, or `error.InvalidVersionRequirement`
    /// when the text is empty, too long, uses an unsupported operator, or
    /// does not contain a valid semantic version.
    ///
    /// Side effects: none. The returned value borrows text from `text`.
    pub fn parse(text: []const u8) error{InvalidVersionRequirement}!@This() {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0 or trimmed.len > max_requirement_len) {
            return error.InvalidVersionRequirement;
        }
        if (std.mem.eql(u8, trimmed, "*")) return .any;

        const Operator = enum {
            exact,
            caret,
            tilde,
            greater,
            greater_equal,
            less,
            less_equal,
        };
        const Split = struct {
            operator: Operator,
            version_text: []const u8,
        };

        const split: Split = if (std.mem.startsWith(u8, trimmed, ">="))
            .{ .operator = .greater_equal, .version_text = trimmed[2..] }
        else if (std.mem.startsWith(u8, trimmed, "<="))
            .{ .operator = .less_equal, .version_text = trimmed[2..] }
        else if (std.mem.startsWith(u8, trimmed, "^"))
            .{ .operator = .caret, .version_text = trimmed[1..] }
        else if (std.mem.startsWith(u8, trimmed, "~"))
            .{ .operator = .tilde, .version_text = trimmed[1..] }
        else if (std.mem.startsWith(u8, trimmed, ">"))
            .{ .operator = .greater, .version_text = trimmed[1..] }
        else if (std.mem.startsWith(u8, trimmed, "<"))
            .{ .operator = .less, .version_text = trimmed[1..] }
        else if (std.mem.startsWith(u8, trimmed, "="))
            .{ .operator = .exact, .version_text = trimmed[1..] }
        else
            .{ .operator = .exact, .version_text = trimmed };

        const version_text = std.mem.trim(u8, split.version_text, " \t");
        if (version_text.len == 0) return error.InvalidVersionRequirement;

        const parsed_version = std.SemanticVersion.parse(version_text) catch
            return error.InvalidVersionRequirement;

        return switch (split.operator) {
            .exact => .{ .exact = parsed_version },
            .caret => .{ .caret = parsed_version },
            .tilde => .{ .tilde = parsed_version },
            .greater => .{ .greater = parsed_version },
            .greater_equal => .{ .greater_equal = parsed_version },
            .less => .{ .less = parsed_version },
            .less_equal => .{ .less_equal = parsed_version },
        };
    }

    /// Returns whether `candidate` satisfies this requirement.
    ///
    /// `candidate` is expected to come from a validated manifest version.
    /// Build metadata is ignored, as required by semantic-version precedence.
    ///
    /// Side effects: none.
    pub fn matches(self: @This(), candidate: std.SemanticVersion) bool {
        return switch (self) {
            .any => true,
            .exact => |required| candidate.order(required) == .eq,
            .caret => |required| atLeast(candidate, required) and
                if (caretUpper(required)) |upper| below(candidate, upper) else false,
            .tilde => |required| atLeast(candidate, required) and
                if (tildeUpper(required)) |upper| below(candidate, upper) else false,
            .greater => |required| candidate.order(required) == .gt,
            .greater_equal => |required| atLeast(candidate, required),
            .less => |required| below(candidate, required),
            .less_equal => |required| candidate.order(required) != .gt,
        };
    }
};

/// Returns whether `candidate` is greater than or equal to `required`.
fn atLeast(candidate: std.SemanticVersion, required: std.SemanticVersion) bool {
    return candidate.order(required) != .lt;
}

/// Returns whether `candidate` is strictly older than `upper`.
fn below(candidate: std.SemanticVersion, upper: std.SemanticVersion) bool {
    return candidate.order(upper) == .lt;
}

/// Returns the exclusive upper bound of a caret requirement, or null when
/// incrementing a version component would overflow.
///
/// Major versions above zero stay below the next major version; a zero major
/// stays below the next minor version; a zero major and minor stay below the
/// next patch version.
fn caretUpper(required: std.SemanticVersion) ?std.SemanticVersion {
    if (required.major > 0) {
        return .{
            .major = std.math.add(usize, required.major, 1) catch return null,
            .minor = 0,
            .patch = 0,
        };
    }
    if (required.minor > 0) {
        return .{
            .major = 0,
            .minor = std.math.add(usize, required.minor, 1) catch return null,
            .patch = 0,
        };
    }
    return .{
        .major = 0,
        .minor = 0,
        .patch = std.math.add(usize, required.patch, 1) catch return null,
    };
}

/// Returns the exclusive upper bound of a tilde requirement, or null when
/// incrementing the minor version would overflow.
fn tildeUpper(required: std.SemanticVersion) ?std.SemanticVersion {
    return .{
        .major = required.major,
        .minor = std.math.add(usize, required.minor, 1) catch return null,
        .patch = 0,
    };
}

fn version(text: []const u8) std.SemanticVersion {
    return std.SemanticVersion.parse(text) catch unreachable;
}

test "any requirement accepts every valid version" {
    const requirement = try VersionRequirement.parse("*");
    try std.testing.expect(requirement.matches(version("0.0.1")));
    try std.testing.expect(requirement.matches(version("99.0.0")));
}

test "exact requirement compares semantic versions" {
    const requirement = try VersionRequirement.parse("1.2.3");
    try std.testing.expect(requirement.matches(version("1.2.3")));
    try std.testing.expect(requirement.matches(version("1.2.3+build.7")));
    try std.testing.expect(!requirement.matches(version("1.2.4")));
    try std.testing.expect(!requirement.matches(version("1.2.3-beta")));
}

test "caret requirement follows npm-style zero-major rules" {
    try std.testing.expect((try VersionRequirement.parse("^1.2.3")).matches(version("1.9.0")));
    try std.testing.expect(!(try VersionRequirement.parse("^1.2.3")).matches(version("2.0.0")));

    try std.testing.expect((try VersionRequirement.parse("^0.2.3")).matches(version("0.2.9")));
    try std.testing.expect(!(try VersionRequirement.parse("^0.2.3")).matches(version("0.3.0")));

    try std.testing.expect((try VersionRequirement.parse("^0.0.3")).matches(version("0.0.3")));
    try std.testing.expect(!(try VersionRequirement.parse("^0.0.3")).matches(version("0.0.4")));
}

test "tilde requirement stays within the same minor version" {
    try std.testing.expect((try VersionRequirement.parse("~1.2.3")).matches(version("1.2.9")));
    try std.testing.expect(!(try VersionRequirement.parse("~1.2.3")).matches(version("1.3.0")));
}

test "comparison requirements" {
    try std.testing.expect((try VersionRequirement.parse(">1.2.3")).matches(version("1.2.4")));
    try std.testing.expect(!(try VersionRequirement.parse(">1.2.3")).matches(version("1.2.3")));
    try std.testing.expect((try VersionRequirement.parse(">=1.2.3")).matches(version("1.2.3")));
    try std.testing.expect(!(try VersionRequirement.parse(">=1.2.3")).matches(version("1.2.2")));
    try std.testing.expect((try VersionRequirement.parse("<1.2.3")).matches(version("1.2.2")));
    try std.testing.expect(!(try VersionRequirement.parse("<1.2.3")).matches(version("1.2.3")));
    try std.testing.expect((try VersionRequirement.parse("<=1.2.3")).matches(version("1.2.3")));
    try std.testing.expect(!(try VersionRequirement.parse("<=1.2.3")).matches(version("1.2.4")));
}

test "requirement parsing accepts whitespace and rejects invalid text" {
    try std.testing.expect((try VersionRequirement.parse("  = 1.2.3  ")).matches(version("1.2.3")));

    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse(""),
    );
    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse("1.2"),
    );
    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse("1.2.3 || 2.0.0"),
    );
    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse("^"),
    );
    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse("1.2.3-"),
    );
}

test "requirement length is bounded" {
    const too_long = "1" ** (max_requirement_len + 1);
    try std.testing.expectError(
        error.InvalidVersionRequirement,
        VersionRequirement.parse(too_long),
    );
}
