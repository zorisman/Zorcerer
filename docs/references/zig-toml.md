# zig-toml Integration Reference

Technical integration guide for the `zig-toml` dependency as vendored in Zorcerer.
Every claim is verified against the vendored source; speculation is labeled explicitly.

Date of investigation: 2026-10-22.

## 1. Revision and provenance

| Item | Value | Source |
|---|---|---|
| Location | Vendored Git submodule at `extern/zig-toml` | `.gitmodules`: url `https://github.com/sam701/zig-toml.git`, branch `zig-0.16` |
| Pinned commit | `8685923e32e8b8a795eb2715684236975a70faed` ("Adjust CI for zig 0.16", 2026-06-11) | `git ls-files -s extern/zig-toml` (mode `160000`); checkout HEAD matches gitlink exactly; working tree clean |
| Declared identity | TOML v1.1.0 parser, package `toml` v0.3.0, `minimum_zig_version = "0.15.1"` | `extern/zig-toml/build.zig.zon:1-15`, `extern/zig-toml/README.md:4` |
| Upstream CI matrix | Zig `0.16.0` only (`zig build`, `zig build test` in Debug/fast/safe) | `extern/zig-toml/.github/workflows/build-and-test.yml` |
| Toolchain in use | Zig 0.16.0 (matches upstream CI) | `zig version` |

**No mismatch was found between the inspected source and the revision the project
depends on**: the vendored checkout is the exact gitlink commit, unmodified.
Whether upstream has newer commits on `zig-0.16` that change this analysis cannot be
checked without network access, so "this is the newest zig-0.16 state" is explicitly
**not verified**.

## 2. Public API

All symbols exported from `extern/zig-toml/src/root.zig`:

| Symbol                     | Kind                                                                                                                                                 | Defined at                   |
|----------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------|
| `Parser(comptime T)`       | Generic parser state struct                                                                                                                          | `root.zig:73-149`            |
| `Parsed(T)`                | Result wrapper: `{ arena: std.heap.ArenaAllocator, value: T }` + `deinit()`                                                                          | `root.zig:62-71`             |
| `ErrorInfo`                | `union(enum) { parse: Position, struct_mapping: FieldPath }`                                                                                         | `root.zig:57-60`             |
| `Position`                 | `{ pos: usize, line: usize }`; line and column are 1-based, bytes counted                                                                            | `parser.zig:4-16`            |
| `FieldPath`                | `[]const []const u8`                                                                                                                                 | `root.zig:55`                |
| `Table`                    | `std.StringHashMap(Value)`                                                                                                                           | `table.zig:12`               |
| `Value`                    | `union(enum)`: `string: []const u8`, `integer: i64`, `float: f64`, `boolean: bool`, `date`, `time`, `datetime`, `array: *ValueList`, `table: *Table` | `value.zig:15-27`            |
| `Date`, `Time`, `DateTime` | `{ year: u16, month: u4, day: u5 }` / `{ hour: u5, minute: u6, second: u6 = 0, nanosecond: u30 = 0 }` / `{ date, time, offset_minutes: ?i16 = 0 }`   | `datetime.zig:5-22`          |
| `HashMap(comptime T)`      | Map-mapping wrapper with a `tomlIntoStruct` hook                                                                                                     | `struct_mapping.zig:228-249` |
| `serialize`                | `fn (allocator, obj: anytype, writer: *std.Io.Writer) !void`                                                                                         | `serialize/root.zig:29-35`   |

`Parser` methods (defined on `*Self`):

- `init(alloc)` / `deinit()` — `root.zig:80-88`
- `parseFile(io: std.Io, filename)` — **requires the Zig 0.15/0.16 `std.Io` handle** — `root.zig:101-117`
- `parseString(input: []const u8)` — `root.zig:119-147`

`parseString` also accepts the special case `T == toml.Table` and returns the raw
root table (`root.zig:134-136`).

## 3. Parsing workflow (confirmed)

1. `var parser = toml.Parser(T).init(alloc); defer parser.deinit();`
2. `var result = try parser.parseFile(io, path)` or `try parser.parseString(text); defer result.deinit();`
3. Use `result.value` — all data lives in the per-call arena inside `result`.
4. A `Parser` instance is reusable across calls: every call allocates a fresh
   arena, and any stale `ErrorInfo` is freed before the next parse (`root.zig:120`).

Internally, `parseFile` (`root.zig:101-117`) opens the file via
`std.Io.Dir.cwd().openFile(io, ...)`, `stat`s it, allocates one buffer of the file
size with the *caller's* allocator, reads it with `std.Io.Writer.fixed` +
`sendFileAll`, calls `parseString`, and frees the buffer. This is **safe**: string
*values* are always copied into the arena (`string.parseString` builds an
`ArrayListUnmanaged` and returns `output.toOwnedSlice(ctx.alloc)` —
`string.zig:25-46`), and *keys* are always `@memcpy`-d before storage
(`table.zig:14-20`). Bare keys transiently reference the input buffer
(`key.zig:15-17`, `allocated = false`) but are copied before being stored in the
table. No dangling-slice path was found.

A `std.Io` handle is required even though parsing itself is pure string work.
In Zorcerer, the established fallback is a single-threaded `std.Io.Threaded`
adapter when no `init.io` is available (`src/PluginManager.zig:24-25, 88`).

## 4. Type conversion and struct mapping

Source: `extern/zig-toml/src/struct_mapping.zig`.

- Supports structs, slices (including `[[table]]` arrays -> `[]const T`),
  fixed-size arrays (**exact length enforced** -> `error.InvalidArrayLength`,
  line 160), one-level pointers to structs (allocated in the arena, lines
  120-126), optionals, enums (string must equal a `@tagName`), unions (tag-name
  string or inline table keyed by the tag name, lines 197-223), and
  `toml.HashMap(T)` maps (keys copied). Strings are serialized only as table
  keys for map types.
- Scalars: TOML integers are always parsed as `i64` and assigned with `@intCast`
  to narrower fields (**panics, not an error**, if out of range — line 96).
  Floats accept integers via `@floatFromInt`. Unicode escapes `\x..`, `\u..`,
  `\U..` are supported with full UTF-8 encoding (`string.zig:91-101`).
- Numbers: decimal, hex (`0x`), octal (`0o`), binary (`0b`), `_` separators,
  `inf`/`nan` (`integer.zig` and `float.zig` test blocks).
- Custom hook: if `T` declares `fn tomlIntoStruct(ctx: *Context, table: *Table) !T`,
  it replaces field mapping (`std.meta.hasFn` check, line 26).
- Missing fields: optional field -> `null`; non-optional with a default ->
  the default; otherwise `error.MissingRequiredField` (lines 34-43).
- **Unknown keys are silently dropped** (leftovers are freed at lines 46-51).
  Typos in manifests/observations are invisible to the parser; validate
  externally if strictness matters.

## 5. Error handling

Source: `extern/zig-toml/src/root.zig`, `parser.zig`, `table.zig`, `value.zig`.

- Syntax errors: caught at `root.zig:129-133`,
  `parser.error_info = .{ .parse = ctx.position }`. The position points at the
  **start** of the offending value (lib test `table.zig:239-246`:
  input `bb = 4u` -> `line 2, pos 6`; `4` is column 6).
- Error set includes `error.CannotParseValue`, `error.UnexpectedToken`,
  `error.UnexpectedEOF`, `error.UnexpectedMultilineString`,
  `error.InvalidCharacter`, `error.InvalidEscape`, `error.InvalidUnicode`,
  `error.InvalidTime`, `error.FieldTypeRedifinition` (the typo is literal
  upstream, `table.zig:97-101`).
- Mapping errors: `error.MissingRequiredField`, `error.InvalidValueType`,
  `error.NotSupportedFieldType`, `error.InvalidArrayLength`; info is
  `.{ .struct_mapping = path }`, where `path` is the field path at failure time.
- `ErrorInfo` access: read `parser.error_info` after a failed call; it is
  cleaned up by the next `parseString` call or by `Parser.deinit()`
  (`root.zig:86-99, 120`).
- The in-source comment "`i suspect this might leak memory`" (`root.zig:143`)
  is a false alarm: the inner path segments are comptime field-name constants
  (`struct_mapping.zig:33`); only the outer slice is dup'ed and freed in
  `freeErrorInfo`.
- Errors are returned as `anyerror`; there is no error-string formatting
  facility. Callers switch on `parser.error_info`.

## 6. Allocator and memory ownership

- All parse output is owned by a **per-call `ArenaAllocator`** held inside
  `Parsed`. Strings, tables, array-of-tables, pointer targets, and even
  `toml.HashMap` backing storage are arena-owned. `result.deinit()` releases
  everything in one call.
- Never `free` any data inside `result.value` manually.
- Strings from `result.value` are **not stable** across `result.deinit()`;
  dupe whatever must outlive the parse. Zorcerer's `src/PluginManager.zig:56-79, 120`
  demonstrates the correct pattern.
- `Parser` itself owns only the transient file buffer (caller allocator,
  freed inside `parseFile`) and `error_info` (caller allocator, freed in
  `Parser.deinit()`).
- `Parser`/`Parsed` instances are not thread-safe, but distinct instances on
  distinct allocators are independent.

## 7. Build integration

Zorcerer side (`build.zig`):

- `toml` module registered at `build.zig:26-31` with `pic = true`,
  target `x86_64-linux-gnu`; imported by the `zorcerer` module (`build.zig:45`)
  and used by `src/PluginManager.zig` and `build/analyzers/AnalyzerDataAdapter.zig`
  (`toml.Parser(AnalyzerConfig)` at line 158).
- `toml-tests` compile target exists (`build.zig:56-59`), but its run step is
  commented out of the `tests` step (`build.zig:84-85`).

Upstream side (`extern/zig-toml/build.zig`):

- Steps: `test`, `examples`, `docs` (installed via `getEmittedDocs`).
- The `.zig-cache` directory inside the vendored submodule is build residue.

The README's package-manager instructions (`zig fetch`, fetch branches such as
`last-zig-0.13`) do not match the `zig-0.16`-branch checkout style this project
actually uses; informational only, since integration here is via the submodule.

## 8. Minimal working examples (source-verified)

- Canonical example: `extern/zig-toml/examples/example1.zig` +
  `example1.toml`. Parses into a `Config` with a `*Address` subtable,
  `[]const Address` array-of-tables, `toml.DateTime`, and an optional
  `description`. Uses `pub fn main(init: std.process.Init)`, `init.gpa`,
  `init.io` — consistent with `README.md:53-85`.
- Zorcerer's real-world usage: `src/PluginManager.zig:85-129` — walk the manifest
  directory, `toml.Parser(Manifest).init(self.allocator)`, `parseFile(io, full_path)`,
  dupe strings out of the arena, retain owned results.
- Writer pattern for `serialize`: `std.Io.Writer.fixed(&buf)`, results read via
  `writer.buffered()`, reset with `writer.end = 0`
  (`extern/zig-toml/src/serialize/tests.zig:11-17`).
- Raw dynamic access: `toml.Parser(toml.Table)` returns the root
  `std.StringHashMap(Value)` (`root.zig:134-136`);
  `Value.deinit`/`Value.print` exist for manual use (`value.zig:27-78`).

## 9. Verification executed

- `zig build test` inside `extern/zig-toml`: **74/74 tests pass**, 530 ms compile,
  Debug, Zig 0.16.0.
- `zig build -Dskip-analyze compile-modules` at the repository root: all steps
  succeeded (cached) — the `zorcerer` library plus `zorcerer-tests`,
  `hooks-tests`, and **`toml-tests`** compile under the project's target and
  `pic` options.
- The comment at `build.zig:84-85` ("two of these tests fail", consequently
  `run_toml_tests` is commented out of the `tests` step) does **not** match the
  current dependency: the vendored suite passes fully. It is a stale remark.
  Assumption: the failures it refers to are either from an older revision or
  concern the commented-out run plumbing rather than the tests themselves.
- An ad-hoc runtime probe was not possible (scratch-file writes were not
  permitted during the investigation). Behavioral claims not covered by the
  executed test suite are labeled below as source-inspected only.

## 10. Limitations, quirks, and common mistakes

Confirmed by source plus test evidence:

1. **`DateTime` serialization is broken.** `serialize/root.zig:53-63` emits the
   date and time concatenated with **no `T` or space separator**, and always
   prints a `-` for any non-zero offset. The library's own test locks this in:
   `offset_minutes = 150` (+02:30, east of UTC) is asserted to output a
   `-02:30` suffix (`serialize/tests.zig:170-176`), i.e. the sign is inverted,
   and the output cannot be re-parsed by `datetime.interpretDateTime`
   (which requires `txt[10] == 'T'`, `datetime.zig:168`).
   Treat `toml.serialize` + `DateTime` as non-round-trippable. Use
   parse-into-memory, serialize `Date`/`Time` alone, or write datetimes
   manually (or write TOML by hand for the required subset).
2. **Negative UTC offsets in the serializer likely panic** in Debug/ReleaseSafe:
   `@intCast(@divFloor(om, 60))` casts a negative value to `u16`
   (`serialize/root.zig:58`). Source-inspected only; the runtime panic was not
   observed because the suite has no negative-offset test. In ReleaseFast this
   would be undefined behavior.
3. **Null-optional fields serialize as empty assignments.** `field = ` is
   printed and then `serializeValue` no-ops for `.optional` + null
   (`serialize/root.zig:122-125, 250-254`; corroborated by the "optionals"
   test producing `""`, `tests.zig:92-98`). Structs containing a null optional
   produce invalid TOML when serialized.
4. Narrow integer (and float) fields **panic** via `@intCast`/`@floatCast` on
   out-of-range TOML values (`struct_mapping.zig:93-110`); parse-time input like
   `retries = 90000` for an `i16` field is not reported as an error.
5. `Parser(T)` only accepts struct `T` (or the special case `T == toml.Table`);
   anything else is `unreachable` (`struct_mapping.zig:30-54`).
6. Unknown TOML keys are silently dropped (Section 4). Good for forward
   compatibility, bad for typo detection in manifests.
7. Multi-line **literal** strings retain the leading newline after `'''`
   (`string.zig:131-147`), while multi-line basic strings trim it.
   Line-ending backslash handling is a marked TODO (`string.zig:294-295`).
8. Errors are `anyerror`-flavored union values with no formatting facility;
   callers switch on `parser.error_info` themselves.

Stale documentation — do not copy from these:

- The doc-comment example at the top of `root.zig:1-35` is outdated
  (`parseFile` without the `io` parameter, `GeneralPurposeAllocator` naming).
  Use `README.md` / `examples/example1.zig` instead.
- `README.md:43-51` fetch instructions reference `zig-master`/`zig-0.13`,
  which does not match the vendored `zig-0.16`-branch practice.

Not verified (requires network):

- Whether newer upstream commits on `zig-0.16` fix the serializer/`DateTime`
  issues. Until checked, this vendored revision is the effective contract.

## 11. Guidance summary for Zorcerer

- Keep the submodule pinned to this commit. The current integration (module
  registration, `std.Io`-based `parseFile`) is correct as built.
- For config/manifest parsing, the library is solid, cheap, and safe
  (arena-scoped; 74 passing tests with release-mode CI coverage).
- For generating TOML, it is safe only for basic types and `Date`/`Time`
  without offsets. Avoid serializing `DateTime` with non-zero offsets and
  structs containing null-optional fields;
  hand-rolled TOML output for the required subset is the reliable path.
- Optional follow-ups requiring a decision:
  - Re-enable `run_toml_tests` in the `tests` step of `build.zig` (its blocker
    appears stale), and delete the outdated doc-comment in
    `extern/zig-toml/src/root.zig` only after establishing a policy for
    changes to vendored submodules.
