# Report: `extern/zig-luajit` and LuaJIT integration paths for Zorcerer

## Scope and evidence

Date of investigation: 2026-10-28.

This is a read-only report based on the vendored checkout:

| Item | Value |
|---|---|
| Location | `extern/zig-luajit` |
| Version | `3.0.0` (`extern/zig-luajit/build.zig.zon:4`) |
| Branch | `v0.16.1` |
| Commit | `11887ffa5b03788c05d23e64f2aafb20b645570a` |
| Zig target | `0.16.0` |

No repository files were modified while producing the investigation. No `zig build` or test run was executed; all findings are from source and documentation inspection. Build/link behavior, PIC compatibility, and runtime behavior remain unverified.

---

## 1. What the dependency actually is

`extern/zig-luajit` is **not LuaJIT itself**. It is a Zig binding layer for the LuaJIT C API and the Lua auxiliary library.

- It wraps `lua_*` and `luaL_*`; the README reports 100% coverage of the Lua C API and auxiliary library, plus the debug API (`extern/zig-luajit/README.md:108-117`).
- LuaJIT itself comes from a separate package, `luajit_build` (`zig-luajit-build`), declared in `extern/zig-luajit/build.zig.zon:5-9`.
- The upstream build fetches that package and builds LuaJIT as a **static** library (`extern/zig-luajit/build.zig:12-28`).
- The bindings import their C headers as the module named `c` (`extern/zig-luajit/src/root.zig:8`), and the upstream build supplies that module with `lib.root_module.addImport("c", luajit_build)` (`extern/zig-luajit/build.zig:26`).

The library is MIT-licensed; LuaJIT is also MIT-licensed (`extern/zig-luajit/LICENSE`, `extern/zig-luajit/COPYRIGHT.md`).

### Important documentation inconsistency

The README's coverage table says "LuaJIT Extensions — No plans to implement" (`README.md:115`), but `src/root.zig` actually exposes LuaJIT-specific library openers:

- `openBitLib` — `root.zig:1824`
- `openJITLib` — `root.zig:1835`
- `openFFILib` — `root.zig:1847`
- `openStringBufferLib` — `root.zig:1861`

For API availability, treat the source as authoritative and the README table as stale. The README is still correct that coroutine `resume`/`yield` are not public API (`README.md:117`).

---

## 2. How to work with the library

### 2.1 Build integration

The upstream-supported pattern is:

1. Add `luajit` as a package dependency.
2. Get the `luajit` module from that dependency.
3. Add it as an import to the executable or library.

From `extern/zig-luajit/README.md:46-63`:

```zig
const luajit_dep = b.dependency("luajit", .{
    .target = target,
    .optimize = optimize,
});

const luajit = luajit_dep.module("luajit");
my_exe.root_module.addImport("luajit", luajit);
```

The important detail is that the dependency's `build.zig` owns both the `c` module and the LuaJIT link wiring. Compiling `extern/zig-luajit/src/root.zig` directly as a module is possible only if you also provide an equivalent `c` module and link the LuaJIT artifact into the final binary.

### 2.2 State lifecycle

`Lua.init(allocator)` creates an independent Lua state. The allocator is copied to the heap so its address stays stable for the state's lifetime; `deinit()` closes the state and frees that copy (`root.zig:40-55`, `root.zig:135-150`).

```zig
const Lua = @import("luajit").Lua;

const lua = try Lua.init(allocator);
defer lua.deinit();
```

Rules:

- One `*Lua` is one independent global environment.
- A Lua state is not thread-safe. Use one state per script/plugin, or serialize access externally.
- `deinit()` invalidates the pointer; no Lua value or callback may be used afterward.
- `Lua.init` does not open any standard libraries.

### 2.3 Opening libraries

Call library openers explicitly. `openLibs()` opens the full standard set, including `io`, `os`, `package`, and `debug` (`root.zig:1710-1727`). That is not appropriate for untrusted scripts.

A minimal sandbox usually starts with:

```zig
lua.openBaseLib();
lua.openStringLib();
lua.openTableLib();
lua.openMathLib();
lua.openBitLib(); // LuaJIT extension; omit for strict Lua 5.1
```

Do **not** open `io`, `os`, `package`, `debug`, or `ffi` for scripts that are not fully trusted. `openFFILib()` enables arbitrary native calls from Lua (`root.zig:1840-1850`) and completely bypasses any Lua-level sandbox.

The base library also contains file/loader helpers such as `dofile` and `loadfile` (and, depending on the LuaJIT build, `loadstring`/`load`). For a sandbox, explicitly set the ones you do not want to `nil` after `openBaseLib()`. Do not assume that "I did not open `io`" means "Lua cannot read files."

### 2.4 Running Lua code

`doString` and `doFile` are load + protected call (`root.zig:1955-1977`):

```zig
lua.doString(
    \\ print("hello from Lua")
) catch |err| {
    // ...
};
```

For scripts that return values, `doString` leaves all results on the stack because it uses `Lua.MultipleReturn`. For an event handler or a script whose result you do not need, use `loadBuffer`/`loadString` followed by `callProtected(0, 0, 0)` so no results remain.

Prefer `loadBuffer` for policy-bound script files:

```zig
try lua.loadBuffer(source_bytes, "@plugin.lua");
try lua.callProtected(0, 0, 0);
```

This matters because `doFile` passes a host filename directly to `luaL_loadfile`; it does **not** consult Zorcerer's `src/io/FileSystem.zig` policy. If script paths must respect `plugin://`/`game://`, read the bytes through the host policy layer and load them with `loadBuffer`.

### 2.5 Calling Lua functions from Zig

Push the function, push arguments in order, then call:

```zig
if (lua.getGlobal("on_event") != .function) {
    lua.pop(1);
    return;
}

lua.pushString("pause");
lua.callProtected(1, 0, 0) catch |err| {
    const message = lua.toString(-1) catch "unknown Lua error";
    Log.logLine("[zlua] on_event failed: {s} ({s})\n", .{
        std.mem.span(message),
        @errorName(err),
    });
    lua.pop(1);
};
```

`callProtected` removes the function and arguments, catches runtime errors, and pushes the error message on failure (`root.zig:1624-1644`). Plain `call` is unprotected and can propagate a Lua error out of the C boundary.

### 2.6 Registering Zig functions in Lua

A Lua-callable Zig function has this signature (`root.zig:640-651`):

```zig
fn(lua: *Lua) callconv(.c) i32
```

Arguments start at stack index 1; return the number of results pushed.

```zig
fn zostdLog(lua: *Lua) callconv(.c) i32 {
    const message = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };

    Log.logLine("[zlua] {s}\n", .{std.mem.span(message)});
    lua.pushBoolean(true);
    return 1;
}

lua.pushCFunction(zostdLog);
lua.setGlobal("zostd_log");
```

**Longjmp warning:** the `check*` helpers ultimately call `luaL_check*`, which can raise a Lua error via longjmp. A longjmp across Zig frames bypasses `defer` and other cleanup. In C callbacks that hold resources or locks, prefer non-throwing conversions such as `toString`/`toInteger` and push an explicit error result, or keep the callback allocation-free and cleanup-free.

### 2.7 Keeping Lua callbacks alive

If a Lua function must survive beyond the current call (for example, an event handler registered by a script), store it in the registry:

```zig
lua.pushValue(-1);
const ref = lua.ref(Lua.PseudoIndex.Registry);
// later:
lua.getTableIndexRaw(Lua.PseudoIndex.Registry, ref);
// when done:
lua.unref(Lua.PseudoIndex.Registry, ref);
```

`ref`/`unref` are at `root.zig:1050-1064`; the registry pseudo-index is documented at `root.zig:653-660`. Do not store raw pointers to Lua stack values.

### 2.8 Errors and stack discipline

`doString` can return `InvalidSyntax`, `Runtime`, or `OutOfMemory`; `doFile` adds `FileOpenOrFileRead` (`root.zig:1866-1878`, `root.zig:1928-1953`). On a runtime error, Lua leaves the error message on the stack. Always pop it after logging and return the stack to a known baseline.

Other practical rules:

- In Debug/ReleaseSafe, stack-index misuse triggers assertions; in ReleaseFast it may not. Keep pushes and pops balanced.
- `toString` may convert a number on the stack into a string; avoid using it while traversing a table (`root.zig:856-866`).
- `pushString` requires a zero-terminated string; use `pushLString` for arbitrary bytes (`root.zig:832-840`, `root.zig:882-890`).
- `atPanic` is not a substitute for protected calls. An unprotected error can call the panic function and then terminate the host (`root.zig:77-87`).

### 2.9 Hooks, coroutines, and JIT

- `setHook` supports call/return/line/count hooks (`root.zig:2969-2998`). Count hooks are the natural place to enforce an instruction budget.
- `resumeCoroutine`/`yieldCoroutine` are private; the README explicitly says coroutine yield/resume is not public API (`README.md:117`). Do not design ZLua around Lua coroutines.
- LuaJIT's JIT is on by default. `openJITLib()` exposes the `jit` control library (`root.zig:1829-1838`).
- LuaJIT debug hooks can be unreliable inside JIT-compiled traces. If instruction budgets or line hooks are a security requirement, disable JIT for those states and verify the behavior with a test. This is LuaJIT behavior to validate, not a claim stated in the vendored docs.
- Never combine untrusted Lua with `ffi`. Also avoid loading untrusted precompiled Lua bytecode; bytecode is not a safe sandbox input.

---

## 3. Current Zorcerer integration state

### 3.1 The build wiring is incomplete

`build.zig:140-145` creates a `luajit` module directly from `extern/zig-luajit/src/root.zig`, and `build.zig:196` adds it as an import to `zorcerer`:

```zig
const luajit = b.addModule("luajit", .{
    .root_source_file = b.path("extern/zig-luajit/src/root.zig"),
    .target = target,
    .optimize = optimize,
    .pic = true,
});

zorcerer.root_module.addImport("luajit", luajit);
```

But:

- `root.zig:8` does `const c = @import("c");`
- The Zorcerer module does not add a `c` import.
- Zorcerer has no root `build.zig.zon`, so the upstream `luajit_build` dependency is not in the package graph.
- No file under `src/` imports `luajit` today. Because Zig analyzes lazily, the missing `c` module is not exercised yet. As soon as a real `@import("luajit")` appears in analyzed code, the build will need the `c` module and the LuaJIT link artifact.

So the current registration is a placeholder, not a working LuaJIT integration.

### 3.2 Architecture intent

`docs/Architecture.md:31-32` says:

> ZLua is the LuaJIT runtime that comes with Zorcerer. It uses `zostd` to speak with the plugin manager.

`docs/Architecture.md:6` places ZLua under the plugin manager. `src/zostd` exists but is empty. No Lua code exists under `src/`.

The exact split between "ZLua" and "plugin manager" is not fully specified in the docs. The only place that can host Lua without touching engine interfaces is the forked manager child.

### 3.3 Plugin loading is `.so`-only

`PluginManager.loadPlugins()` scans plugin directories and opens `.so` files (`src/PluginManager.zig:208-214`). The manifest schema currently allows only:

- `plugin_id`
- `name`
- `version`
- `author`
- `lib_path`

(`src/PluginConfiguration.zig:29-47`)

The parser rejects unknown top-level keys and enforces a 4 KiB manifest limit (`PluginConfiguration.zig:22`, `:59-61`, `:76-79`). There is no script entry point and no plugin type field.

### 3.4 The IPC and trust boundary

`Ipc.max_payload_len` is 4096 bytes (`src/Ipc.zig:22`). `docs/references/json_ipc.md:102` explicitly says to revisit this limit before promising arrays or strings to external languages.

`docs/references/json_ipc.md:76-84` states the critical trust rule:

> The Plugin Manager shares an address space with the plugins. A malicious or compromised plugin can bypass the Manager entirely, or corrupt it.

Therefore:

- Manager-side validation is developer UX and early rejection.
- The Entrypoint is the actual security boundary.
- JSON Schema validates shape, not safety.

### 3.5 Engine access and the fork

The Entrypoint owns the engine interfaces and forks the manager child (`docs/Architecture.md:4-9`). The child must not call inherited engine interfaces; `src/io/Log.zig:13-16` says the forked child inherits the parent's engine sink, "which must not be called across the fork," and replaces it with IPC logging.

`docs/references/json_ipc.md:64` likewise calls out "opaque interface handles for things that cannot cross the fork boundary."

Consequence: Lua in the manager cannot safely call `IVEngineServer`, `IFileSystem`, or other engine interfaces directly. Engine effects must be requested from the Entrypoint over IPC.

### 3.6 The existing `serverCommand` hook

The Entrypoint already installs a detour on `IVEngineServer::ServerCommand` at `Indexes.IVEngineServer.server_command` (index 36), and currently recognizes only the test command `zorcerer ping` (`src/Entrypoint.zig:131-141`, `:287-333`).

The manager answers that test through the same framed JSON-RPC channel (`src/PluginManager.zig:432-435`, `src/Ipc.zig:42-47`, `:489-616`). This is the most important existing seam for a first Lua scenario.

The Source SDK reference notes that numeric vtable indices are a binary-verification concern (`docs/references/source-sdk-2013.md:326-328`), while the interface version is `VEngineServer023` (`source-sdk-2013.md:169`). The existing Entrypoint version gate (`src/Entrypoint.zig:919-925`) is what keeps the generated index honest; a new scenario should reuse that mechanism rather than hand-picking a slot.

### 3.7 Filesystem policy

`docs/references/source-sdk/filesystem.md:262-299` defines the split:

- `game://` must go through the Source Engine filesystem because content lives in VPKs/search paths.
- `plugin://` goes through `std.Io` because it is plain host storage.
- Zorcerer's own core uses `std.Io`.

For Lua:

- `plugin://` file access can be implemented in the manager.
- `game://` file access must be requested from the Entrypoint, which owns the engine filesystem interface.
- `doFile` bypasses this policy entirely; use `loadBuffer` after a policy-checked read.

### 3.8 Event dispatch is synchronous

`Ipc.Event` currently contains only `pause`, `unpause`, `levelInit`, `serverActivate`, and `levelShutdown` (`src/Ipc.zig:289-300`). There is no `gameFrame` event.

`sendManagerEvent` sends an event and waits for the matching response (`src/Entrypoint.zig:1028-1051`). It is explicitly non-reentrant and single-threaded. A slow Lua handler therefore blocks the engine callback until it returns.

---

## 4. Scenarios for integrating LuaJIT into Zorcerer

### Scenario A — `zlua` admin console command

**Verdict: valid with modest changes; recommended first product increment.**

#### Shape

1. `serverCommandDetour` recognizes a `zlua ...` prefix in addition to the existing test ping.
2. The Entrypoint forwards the command text to the manager through the existing framed JSON-RPC channel, using a generalized `serverCommand` request or a new `zlua` method.
3. The manager owns one persistent console Lua state, executes the command in a protected call, and returns either:
   - a single engine command string for the Entrypoint to execute via the original `ServerCommand`, or
   - a status/error string, with output sent through IPC `stderr` notifications.
4. The Entrypoint validates the returned command against an allowlist and then calls the original `ServerCommand`.

This mirrors the existing test round trip exactly: `serverCommandDetour` → `exchangeServerCommand` → manager `serveServerCommandTest` → response → `callOriginalServerCommand` (`src/Entrypoint.zig:287-321`, `src/PluginManager.zig:432-435`).

#### Why it is valid against the docs/references

- `docs/Architecture.md:6` and `:31-32` place ZLua in the plugin manager, not the Entrypoint.
- `docs/references/json_ipc.md:24` explicitly recommends a semantic method such as `engine.serverCommand` rather than exposing raw vtable functions.
- `docs/references/json_ipc.md:83` requires the Entrypoint to enforce the method allowlist and safety policy.
- `src/Entrypoint.zig:328-333` already installs the `ServerCommand` hook, and `src/Ipc.zig` already has the request/response machinery.
- The manager child does not touch engine interfaces; all engine effects return through the Entrypoint.

#### Required changes

- `src/Ipc.zig`: generalize the existing `serverCommand` request/response, or add a dedicated `zlua` method with the same framing.
- `src/Entrypoint.zig`: route `zlua` commands to the manager; validate/allowlist returned commands; preserve the re-entry guard.
- `src/PluginManager.zig`: add a console Lua state and dispatch path.
- New `src/ZLua.zig` (or similar): state creation, safe library setup, protected execution, logging, error handling.
- `build.zig`: fix the `luajit`/`c`/LuaJIT link wiring.

#### Risks and limits

- The 4096-byte IPC payload limit applies to both the command and the reply. Reject oversized input with a clear error rather than truncating silently.
- A slow script blocks the engine callback because the exchange is synchronous.
- Console output can be large; send it as log notifications or chunk it.
- The `ServerCommand` detour must stay re-entry guarded, as it is today (`src/Entrypoint.zig:139-141`, `:294-305`).
- Console scripts are still code running in the manager's address space. Sandboxing protects against accidents, not against a malicious script that escapes Lua.

#### Security policy for v1

- Open only base/string/table/math/bit.
- Remove `dofile`, `loadfile`, and `loadstring`/`load` from the global table.
- Do not open `io`, `os`, `package`, `debug`, or `ffi`.
- Allow `plugin://` reads only through the host policy layer.
- Do not allow direct `game://` reads in v1; add an Entrypoint RPC later.
- Return only allowlisted engine commands to the Entrypoint.

---

### Scenario B — Lua script plugins (`ZLua`)

**Verdict: architecturally valid and the closest match to the documented ZLua vision, but a larger change.**

#### Shape

1. Extend the manifest with a script entry point, for example:
   - `type = "lua"` and `script_path = "main.lua"`, or
   - `script_path` optional alongside `lib_path`, with exactly one of them present.
2. `PluginManager.loadPlugins()` branches on the manifest:
   - `.so` → current `dlopen` path.
   - Lua → create a per-plugin `Lua` state, open safe libraries, register `zostd`, load the script.
3. The script returns a table of lifecycle callbacks, or registers callbacks through `zostd.on(event, fn)`:
   - `on_load`
   - `on_unload`
   - `on_event(event_name, payload)`
4. `PluginManager.listenForEvents()` dispatches `pause`, `unpause`, `levelInit`, `serverActivate`, and `levelShutdown` to each script. Errors are logged per plugin and do not abort the other scripts.
5. On unload, call the script's `on_unload`, unref callbacks, then `lua.deinit()`.

This fits the current manager loop: `listenForEvents` already parses `Ipc.Event` and sends a response (`src/PluginManager.zig:386-437`). Today it only replies `"Event is X"`; the Lua dispatcher would run before the reply.

#### Why it is valid against the docs/references

- `docs/Architecture.md:31-32`: ZLua is the LuaJIT runtime in the plugin manager and uses `zostd`.
- `docs/FAQ.md:13-14`: ZLua was chosen because it is small and fast.
- `docs/FAQ.md:23`: plugins are the intended extension point for additional runtimes; a Lua plugin type is consistent with that.
- `docs/references/json_ipc.md:76-84`: the manager is not the security boundary, so script sandboxing is UX/defense-in-depth, and the Entrypoint must enforce engine effects.
- `docs/references/source-sdk/filesystem.md:262-299`: `plugin://` can be host-side; `game://` needs the engine side.

#### Required changes

- `src/PluginConfiguration.zig`: add script fields, make `lib_path`/`script_path` mutually exclusive, keep the 4 KiB limit.
- `src/PluginManager.zig`: plugin type branch, per-plugin Lua state table, load/unload lifecycle, event dispatch.
- `src/Ipc.zig`: no new event is strictly required for the five existing events. A `gameFrame` event would require a new engine callback and is not present today.
- `src/ZLua.zig`: shared state creation, sandbox setup, script loading, callback registry, budgets.
- `src/zostd/`: Lua-facing API and its Zig implementation.
- `build.zig`: LuaJIT module/artifact wiring, and decide whether script plugins are built into the manager or loaded as separate artifacts.

#### Risks and limits

- **Not a security boundary.** The manager shares an address space with native plugins. A Lua script that escapes the sandbox, or a malicious native plugin, can bypass manager checks. The Entrypoint remains the enforcement point.
- **DoS.** Infinite loops and memory growth are easy in Lua. Use a limited allocator and a count hook; disable JIT for states where the count hook must be reliable.
- **`doFile` bypass.** Use `loadBuffer` with bytes read through the host policy layer.
- **Base-library escapes.** Remove file/loader functions after opening the base library.
- **No coroutines.** Event handlers must be synchronous; do not design around `yield`.
- **Synchronous IPC.** A long handler blocks the engine callback that triggered it.
- **`game://` needs a new RPC path.** The manager cannot call the engine filesystem. Add an Entrypoint-side `readGameFile` method later, with chunking for the 4096-byte limit.
- **Manifest size.** The 4 KiB limit is enough for a small script entry point, but not for large embedded configuration. Keep large data in separate files under `plugin://`.
- **Unload ordering.** Unref Lua callbacks before `deinit`; do not call a Lua state after `deinit`.

---

### Scenario C — A native `.so` plugin embeds Lua itself

**Verdict: architecturally valid and the smallest code change, but it is a plugin-author path, not built-in ZLua.**

#### Shape

A normal Zorcerer plugin:

1. Imports the `luajit` module.
2. Creates its own `Lua` state in `load()`.
3. Runs bundled scripts from `plugin://`.
4. Registers plugin-specific Zig functions.
5. Calls `lua.deinit()` in `unload()`.

The plugin already has the `HostApi.logger` and can import the `zorcerer-filesystem` module for `plugin://`/`game://` access (`src/PluginContext.zig:40-45`, `build.zig:168-179`). No manifest or loader change is needed beyond making the `luajit` module available to plugin builds.

#### Why it is valid against the docs/references

- `docs/FAQ.md:23` explicitly says users are free to implement other runtimes by writing a plugin.
- `docs/Architecture.md:14-17` defines the plugin ABI as `load(ctx)`/`unload(ctx)`.
- `docs/references/source-sdk/filesystem.md:262-299` gives the plugin a policy-compliant filesystem module to use.

#### Required changes

- Fix the build so plugin targets can import `luajit` with its `c` module and LuaJIT artifact.
- Ensure the plugin `.so` and LuaJIT are PIC-compatible.
- Add a documented example plugin.

#### Risks and limits

- **Multiple LuaJIT copies.** If several plugins statically link LuaJIT into the same process, symbol interposition or duplicate runtime state may cause problems. Verify with more than one plugin; prefer a single shared LuaJIT runtime in the manager for the built-in ZLua path.
- **No core sandbox.** Each plugin author is responsible for library selection and FFI policy.
- **No shared `zostd`.** The plugin must implement its own host API or use the filesystem module directly.
- **Build complexity for plugin authors.** They need the same LuaJIT wiring Zorcerer uses.

This scenario is useful as a build proof-of-concept because it exercises `Lua.init`, `openBaseLib`, `doString`, and `deinit` without changing the plugin manager's schema.

---

### Scenario D — A curated `zostd` Lua API

**Verdict: necessary enabler for Scenarios A and B; design-only today.**

`src/zostd` is empty. `docs/Architecture.md:29` says the intent is a module usable not only from Zig but from "pretty much every language," probably via `extern` functions or manual name mangling.

A first Lua-facing `zostd` surface should be small and capability-based:

| Function | Behavior | Backing |
|---|---|---|
| `zostd.version()` | Returns the API version | Constant |
| `zostd.log(message)` | Writes to the server console | IPC `stderr` |
| `zostd.plugin_id()` | Returns the current plugin id | Manager |
| `zostd.read_file(path)` | Reads a `plugin://` file | `std.Io` + policy |
| `zostd.write_file(path, data)` | Writes a `plugin://` file | `std.Io` + policy |
| `zostd.server_command(command)` | Requests an engine command | Entrypoint RPC |
| `zostd.on(event, callback)` | Registers a lifecycle callback | Registry ref |

Design rules:

- No raw pointers or opaque engine handles cross into Lua. Use strings, numbers, booleans, tables, and explicit handles.
- Every function validates argument types and path policy; return `(nil, error_string)` or raise a Lua error consistently.
- `server_command` is a request to the Entrypoint; it is not a direct engine call.
- `game://` is not part of the first version. If added, it must be an Entrypoint RPC with chunking.
- Version the API and reject incompatible scripts at load time.

This is directly supported by:

- `docs/Architecture.md:29` (multi-language `zostd`)
- `docs/Architecture.md:32` (ZLua uses `zostd`)
- `docs/references/json_ipc.md:57-72` (typed methods, safety classes, capabilities)
- `docs/references/json_ipc.md:83` (Entrypoint enforcement)
- `docs/references/source-sdk/filesystem.md:262-299` (scheme policy)

It is not implemented, so it must be treated as a design goal, not an existing contract.

---

### Scenario E — JIT/performance mode

**Verdict: optional; not a security boundary and not documented as a Zorcerer policy yet.**

LuaJIT's main advantage is the JIT. For trusted, CPU-bound scripts, keeping JIT enabled is reasonable. For untrusted scripts, the safer default is:

- JIT off, or at least no reliance on JIT-time hooks for security.
- FFI never opened.
- No untrusted bytecode.
- Instruction and memory budgets enforced.

The bindings expose `openJITLib()` and `openFFILib()` (`root.zig:1829-1850`), but there is no Zorcerer documentation defining when either is allowed. The FAQ's "blazingly fast" rationale (`docs/FAQ.md:13-14`) supports JIT for trusted workloads; it does not justify JIT for untrusted ones.

**Risks:**

- LuaJIT debug hooks may not fire reliably inside traces; verify if budgets depend on them.
- JIT compilation itself consumes memory and can be used for DoS.
- FFI gives arbitrary native calls and must never be exposed to untrusted scripts.
- Multiple Lua states and multiple static LuaJIT copies complicate JIT/global-state behavior; verify before supporting many plugins.

---

## 5. Scenario comparison

| Scenario | Where Lua runs | Engine access | Documentation support | Effort | Main risk | Verdict |
|---|---|---|---|---|---|---|
| A. `zlua` console | Manager child | Via Entrypoint IPC | Architecture, `json_ipc`, existing `ServerCommand` hook | Small–medium | Synchronous blocking, 4096-byte limit | **Recommended first** |
| B. Script plugins | Manager child | `plugin://` direct; `game://` via IPC | Architecture ZLua, FAQ, `json_ipc`, filesystem policy | Large | Manager is not a security boundary; DoS | **Target design** |
| C. Native plugin embeds Lua | Manager child, plugin-owned | Plugin's own filesystem module | FAQ plugin extension point, plugin ABI | Medium | Multiple LuaJIT copies, PIC/link | **Best build proof** |
| D. `zostd` Lua API | Manager child | Policy layer | Architecture `zostd`, `json_ipc`, filesystem policy | Medium–large | Scope creep, versioning | **Enabler** |
| E. JIT mode | Manager child | Same as A/B | Weak; only general LuaJIT/FAQ rationale | Small | Hook reliability, FFI, DoS | **Optional** |

---

## 6. Scenarios that should be rejected

### 6.1 Lua inside the Entrypoint / engine process

Rejected because:

- `docs/Architecture.md:8-9` defines the Entrypoint as socket creation and a fork; the plugin manager is the child.
- `docs/FAQ.md:5-6` says the child process exists specifically so plugins cannot do much to the engine.
- A Lua state in the Entrypoint would give scripts the engine's address space and interface pointers, defeating the process split.

### 6.2 Lua calling engine interfaces directly from the manager child

Rejected because:

- `src/io/Log.zig:13-16` states the inherited engine sink must not be called across the fork.
- `docs/references/json_ipc.md:64` explicitly treats interfaces that cannot cross the fork as opaque handles.
- Engine effects must be requested from the Entrypoint, which can enforce allowlists and payload limits.

### 6.3 Opening all standard libraries for untrusted scripts

`openLibs()` opens `io`, `os`, `package`, and `debug` (`root.zig:1710-1727`). That bypasses the intended file policy and gives scripts process/environment access. Use selective openers and remove base-library loaders.

### 6.4 Exposing `ffi` to untrusted scripts

`openFFILib()` enables arbitrary native calls (`root.zig:1840-1850`). It is incompatible with any Lua-level sandbox. FFI is acceptable only for fully trusted native-plugin code, not for ZLua scripts.

### 6.5 Deriving the Lua API from vtable dumps

Rejected by `docs/references/json_ipc.md:21-24`:

- Vtable entries have no signatures today.
- Most vtable methods are not a sane public API.
- The contract must be a designed semantic API, with explicit bindings and safety classes.

### 6.6 Direct `game://` access from the manager child

Rejected by `docs/references/source-sdk/filesystem.md:270-273`: `game://` content requires the engine filesystem and pathID `GAME`. The manager cannot safely call it after the fork. Use an Entrypoint RPC.

### 6.7 Loading untrusted Lua bytecode

Lua bytecode is not a safe sandbox input; a malformed chunk can crash or corrupt the VM. Accept source from trusted paths, or verify bytecode before loading. This is a hardening rule, not a claim from the vendored docs.

### 6.8 Coroutine-based async design

`resumeCoroutine`/`yieldCoroutine` are private (`README.md:117`). Do not build ZLua's event model around Lua coroutines; use explicit event callbacks and synchronous calls.

---

## 7. Recommended implementation path

### Phase 0 — Build spike (must happen first)

Prove that one analyzed source file can `@import("luajit")` and link into `zorcerer.so`.

Decide one of:

1. **Upstream package dependency** — add a root `build.zig.zon` and use `b.dependency("luajit", ...)`. This is the documented installation path, but it changes Zorcerer's build layout and pulls `luajit_build` remotely.
2. **Vendored build package** — add `zig-luajit-build` under `extern/` and wire a `c` module manually, matching Zorcerer's submodule style.
3. **System LuaJIT** — create a `c` module from installed headers and link `luajit`. Reproducibility for a TF2 server is questionable; not recommended.

Verify:

- The `c` module exposes `lua.h`, `lauxlib.h`, and `luajit.h`.
- The final `zorcerer.so` links the LuaJIT artifact.
- Static LuaJIT is PIC-compatible with the shared `zorcerer.so`. Upstream requests `link_as = .static` (`extern/zig-luajit/build.zig:12`) and Zorcerer builds a dynamic library with `.pic = true` (`build.zig:181-189`); this combination is unverified.
- If static LuaJIT is not PIC, do not edit `extern/zig-luajit`; use a fork/vendored build package or a shared LuaJIT build.

### Phase 1 — Console Lua

Implement Scenario A:

- `src/ZLua.zig`: state lifecycle, safe libraries, protected execution, logging.
- `src/Ipc.zig`: `zlua` request/response or generalized `serverCommand`.
- `src/Entrypoint.zig`: route `zlua`; allowlist returned commands; preserve re-entry guard.
- `src/PluginManager.zig`: console state and dispatch.
- Tests: sandbox globals, path policy, syntax/runtime errors, oversized payloads.

No `game://` and no FFI in this phase.

### Phase 2 — Script plugins

Implement Scenario B:

- Manifest `type`/`script_path`; mutual exclusion with `lib_path`.
- Per-plugin Lua state and lifecycle callbacks.
- Event dispatch for the five existing `Ipc.Event` values.
- Limited allocator and count-hook budget.
- Per-plugin error isolation.

### Phase 3 — `zostd` and `game://`

- Stabilize the Lua-facing `zostd` API and version it.
- Add Entrypoint-side `game://` reads with chunking for the 4096-byte frame limit.
- Document the API and publish the contract.

### Phase 4 — Optional JIT policy

- Define when JIT is allowed.
- Keep FFI out of ZLua.
- Validate hook behavior under JIT before relying on it for budgets.

---

## 8. Open questions that affect the design

1. **Trust model:** Are Lua scripts installed only by the server administrator, or can they come from untrusted sources? This determines whether sandboxing is a safety feature or a security boundary.
2. **Product shape:** Is the goal built-in ZLua for server admins, a scripting API for native plugin authors, or both?
3. **Build policy:** Is adding a root `build.zig.zon` acceptable, or must dependencies remain vendored submodules?
4. **LuaJIT linkage:** Is a static LuaJIT acceptable inside `zorcerer.so`, or is a shared/PIC build required?
5. **Engine access:** Which operations should Lua be allowed to request in v1? A `serverCommand` allowlist and `plugin://` reads are the safest starting point.
6. **`game://`:** Is read access required in the first version? If yes, the 4096-byte IPC limit requires a chunking design before the API is promised.
7. **Events:** Is per-tick Lua needed? There is no `gameFrame` event today; adding one requires a new engine callback and has the same synchronous-blocking cost.

---

## 9. Bottom line

- `extern/zig-luajit` is a usable Zig binding layer, but it is not a self-contained runtime. It needs `luajit_build`, a `c` module, and a LuaJIT link artifact.
- Zorcerer's current `build.zig` registration is incomplete: the module exists, but the `c` import and dependency graph do not. The missing pieces are hidden only because nothing under `src/` imports `luajit` yet.
- The only architecture-consistent place for Lua is the forked manager child. The Entrypoint must remain the engine-facing security boundary.
- The first practical scenario is a `zlua` console command through the existing `ServerCommand` hook. It validates the build, lifecycle, sandbox, and IPC with the smallest surface change.
- The documented ZLua target is script plugins with per-plugin Lua states and a curated `zostd` API. That is valid, but it needs manifest, loader, lifecycle, and security work.
- A native `.so` plugin embedding Lua is the smallest build proof-of-concept and is supported by the FAQ's "write a plugin" stance, but it is not the built-in ZLua.
- Do not expose `ffi`, `io`, `os`, `package`, or `debug` to untrusted scripts; do not call engine interfaces from the manager child; do not derive the Lua API from vtable dumps.
