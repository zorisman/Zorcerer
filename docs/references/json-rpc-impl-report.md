# JSON-RPC IPC Implementation Report

Practical notes for the Zorcerer VSP (engine process) ↔ plugin-manager
(forked child) channel, plus the Source engine console-command registration
that makes `zorcerer ping` work over RCON.

Date of writing: 2026-10-28.

Audience: coding agents continuing this work. This document records the
non-obvious failure modes, the ABI facts that were checked against the vendored
SDK, and the parts that are still hypotheses.

## 0. Verification status

- **Verified against the vendored source:** `ConCommandBase`/`ConCommand`
  field order, `CCommand` layout, `ICvar` interface version and vtable slot
  order, and the generated `Indexes.ConCommand` ordering. See
  `extern/source/source-sdk-2013/src/public/tier1/convar.h`,
  `extern/source/source-sdk-2013/src/public/icvar.h`, and
  `extern/source/source-sdk-2013/src/tier1/tier1.cpp`.
- **Not verified:** the working tree as reviewed here has not been built or
  exercised in this environment, and the console-command registration has
  never run against a live TF2 dedicated server. Registration and dispatch at
  runtime remain hypotheses. Existing tests are described below, but their
  current results were not observed.
- **Not shipped by the SDK:** the actual `CCvar::RegisterConCommand`
  implementation lives in vstdlib, whose source is not in the SDK checkout
  (`src/vstdlib/` only contains an exclude `.vpc`). Its exact behavior is
  binary/engine-level evidence, not source evidence.
- The SDK's `Cmd_ExecuteString` in
  `extern/source/source-sdk-2013/src/tier1/commandbuffer.cpp` is inside
  `#if 0` (lines 418–636). It is stale: it calls `Dispatch()` without an
  argument even though the header declares
  `virtual void Dispatch( const CCommand &command )`. Do not use that file as
  the authority for the dispatch call; use the header plus live-binary
  verification.

## 1. Architecture at a glance

| Piece | Process | Responsibility |
|---|---|---|
| `src/Entrypoint.zig` | TF2 dedicated server | VSP callbacks, engine interface probing, `ServerCommand` detour, ConCommand registration, parent end of the IPC socket |
| `src/PluginManager.zig` | forked child | Loads plugins, serves events, decides the test `serverCommand` reply |
| `src/Ipc.zig` | both | Framing, JSON-RPC parsing/composition, shared schemas |
| `src/io/Log.zig` | both | Engine `LogPrint` in the parent; IPC `stderr` notifications in the child |
| `src/codegen_generated/engine_indexes.zig` | build-generated | Interface versions and vtable slot indices; never hand-write these |

The manager is forked from the entrypoint. The two ends are connected by an
`AF_UNIX`/`SOCK_STREAM` socket pair created immediately before `fork()`:

```text
engine process (VSP)                     forked child (manager)
  Entrypoint.zig  <--- socketpair --->  PluginManager.zig
      |                                      |
      | IVEngineServer / ICvar               | plugin .so files
      v                                      v
  TF2 engine                            dlopen()ed plugins
```

The child sends a `ready` notification after its load attempt. Closing the
parent's socket end is the shutdown signal: the child's read returns EOF, it
unloads its plugins and exits; `ForkedChild.finish()` closes and reaps it.

All engine-callback traffic is **synchronous and serialized**: the entrypoint
sends one request, then waits for exactly one matching response. The engine
invokes VSP callbacks from one thread at a time, so no request queue or
concurrent pending map exists.

## 2. Wire format and protocol

### 2.1 Frame format

One JSON-RPC message is one frame:

```text
+--------+---------------------+--------------------------+
| 0xA5   | u32 little-endian   | JSON payload             |
| marker | payload length      | (UTF-8)                  |
+--------+---------------------+--------------------------+
```

Facts enforced by `src/Ipc.zig`:

- `max_payload_len = 4096` bytes. The length is read before the payload, so an
  oversized/corrupt length is rejected before a read blocks.
- The marker byte distinguishes a frame from a truncated or desynchronized
  stream. A wrong marker stops the listener; the stream cannot be resynced.
- Zero-length payloads are representable (`framed = true`, `received = false`).
- `readFrame` uses `readExact`/`readAtMost` loops; `writeFrame` uses `writeAll`.
  Both retry `EINTR`. EOF before a full frame is `error.PeerClosed`.
- `writeAll` uses `sendto(..., MSG_NOSIGNAL, ...)`. This is deliberate: a
  plain write to a closed socket raises `SIGPIPE`, which would terminate the
  engine process.
- The payload buffer is a fixed-size `Frame` (`payload: [4096]u8`). Do not
  raise the limit without reconsidering stack usage and the design decision in
  `docs/references/json_ipc.md` (§ "Revisit the 4096-byte frame limit").

### 2.2 Messages in use

| Direction | Method | Kind | ID | Payload / result |
|---|---|---|---|---|
| child → parent | `ready` | notification | none | `{"message":"Hello from fork"}` |
| child → parent | `stderr` | notification | none | `{"message":"..."}` |
| parent → child | `pause`, `unpause`, `levelInit`, `serverActivate`, `levelShutdown` | request | `1` | result string `"Event is X"` |
| parent → child | `serverCommand` | request | `2` | result object `{"command":"echo \"Pong!\""}` |

Example event request:

```json
{"jsonrpc": "2.0", "method": "pause", "id": 1}
```

Example test round trip:

```json
{"jsonrpc":"2.0","method":"serverCommand","params":{"command":"zorcerer ping"},"id":2}
```

```json
{"jsonrpc":"2.0","result":{"command":"echo \"Pong!\""},"id":2}
```

The IDs are separate on purpose:

- `event_request_id = 1` (`src/Ipc.zig`).
- `server_command_request_id = 2`.
- Log/readiness traffic is sent as JSON-RPC notifications (`RpcId.ofNone()`),
  so it never consumes a request ID.

The parent answers ID-bearing child requests with the JSON result `"OK"`.
Notifications are never answered, matching JSON-RPC 2.0.

## 3. Bugs and failure modes encountered

Entries whose symptom is stated as **Symptom** were observed during this work.
Entries stated as **Symptom class** are failure modes the implementation now
guards against; they are included because a future change can reintroduce
them.

### 3.1 `Unknown command "zorcerer"` on RCON

**Symptom:** the server replied `Unknown command "zorcerer"` to
`zorcerer ping`.

**Root cause:** the engine tokenizes a console line and looks up only the first
token. Source command names cannot contain whitespace, so a command literally
named `zorcerer ping` cannot exist. Detouring `IVEngineServer::ServerCommand`
is not equivalent to registering a console command, and the engine does not
guarantee that RCON lines pass through that detour at all.

**Fix:** register a real `ConCommand` named `zorcerer` through `ICvar`, and
validate `ping` as `argv[1]` inside `Dispatch`. The `ServerCommand` detour is
retained only to execute the manager's reply through the original engine
function, plus a whole-line fallback. See
`registerTestPingCommand` (`src/Entrypoint.zig`) and
`isTestPingInvocation`.

**Guard:** tests for command-token matching and for the `ConCommand` vtable.

### 3.2 A JSON-RPC response parsed as a request

**Symptom class:** a response frame such as
`{"jsonrpc":"2.0","result":{},"id":2}` is fed to the request parser and
dispatched as a request, producing `UnknownMethod`/`MethodNotFound` noise, or
the synchronous exchange keeps waiting for a response that was already consumed
elsewhere.

**Root cause:** ZigJR's `parseRpcRequest` is total. It does not return an error
for a missing `method`; it returns a request-shaped default with
`method = ""`, `_no_method = true`, and the parse/validation error attached to
`_err`. `RpcRequest.isMissingMethod()` and `request.hasError()` must be
inspected explicitly. A frame without a `method` member can therefore look like
a request.

**Fix:** every request parser in `src/Ipc.zig` (`parseRequest`, `parseEvent`,
`parseManagerRequest`) checks all of:

```zig
if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
const request = rpc.request_msg.request;
if (request.method.len == 0) return error.NotRpcRequest;
if (request.hasError()) return error.InvalidRpcRequest;
```

Use `error.NotRpcRequest` as the *only* signal that the caller should try the
response parser. Do not treat every parse failure as "probably a response":
malformed requests and unknown methods must remain errors.

**Guard:** `test "parseRequest treats a response frame as not a request"` in
`src/Ipc.zig`, plus the equivalent case in
`parseManagerRequest`'s test.

### 3.3 Child log/readiness frames confused with the awaited response

**Symptom class:** while the parent waits for an event or `serverCommand`
response, the child sends a log line or readiness notification. A listener that
assumes "the next frame is the response" fails with `UnexpectedResponseId` or a
JSON schema error, or consumes the notification as the result.

**Root cause:** both directions share one stream, and notifications are
interleaved with synchronous replies.

**Fix:** the listeners loop and classify every frame:

1. Try `parseRequest`/`parseManagerRequest` first.
2. Execute `stderr`/`ready` notifications (log them; for readiness compare
   against `manager_ready_message`).
3. Answer a request that carries an ID with exactly one result.
4. Only when the frame is `error.NotRpcRequest`, parse it as a response and
   validate its ID against the awaited one.

`jsonListener` (`src/Entrypoint.zig`) and `exchangeServerCommand` implement
this on the parent side; `PluginManager.listenForEvents` implements the mirror
image on the child side. `event_request_id` and `server_command_request_id`
are distinct so a response can never satisfy the wrong exchange.

**Guard:** `test "manager ignores event notifications"` and the forked
`serverCommand` round-trip test.

### 3.4 Replying to notifications

**Symptom class:** a notification (no `id`, or `"id": null`) receives a
response anyway. The peer is not waiting for one, so the extra frame is
interpreted as the next reply/message and the stream desynchronizes.

**Root cause:** treating every parsed message as a request that deserves a
response.

**Fix:** check `RpcId.isNotification()` before replying. Note ZigJR's
semantics: both `none` (field absent) and `null` (`"id": null`) are
notifications; only `num` and `str` IDs are valid request IDs.
`zjr.composer.makeResponseJson` returns `null` for notifications, and
`Ipc.sendResultResponse` turns that into `error.NoResponseForNotification`.
On the child side, `listenForEvents` does `if (request_id.isNotification()) continue;`.

**Guard:** notification-aware listener paths plus the explicit error in
`sendResultResponse`.

### 3.5 A malformed frame could hang the synchronous caller

**Symptom class:** the manager cannot decode a request and silently drops it;
the parent waits forever for a response.

**Fix:** `PluginManager.listenForEvents` catches every parse error and calls
`Ipc.sendInvalidEventResponse`, which:

- recovers the request ID when the frame is structurally a request,
- sends exactly one JSON-RPC error (`MethodNotFound`, `InvalidParams`, or the
  parser's `InvalidRequest` code),
- sends nothing for notifications.

The parent's exchange loop therefore always makes progress. A frame that
cannot be read at all (bad marker, oversized length, EOF) still ends the
listener; that is a channel failure, not a recoverable message error.

**Guard:** invalid-event tests in `src/Ipc.zig` and the manager listener.

### 3.6 `SIGPIPE` terminating the engine

**Symptom class:** the manager dies (or the socket is closed during unload),
the parent writes a log line or response, and the whole dedicated server is
killed by `SIGPIPE`.

**Fix:** all writes go through `writeAll`, which uses
`std.os.linux.sendto(..., std.os.linux.MSG.NOSIGNAL, ...)`. A dead peer now
yields `error.WriteFailed`; callers log and stop instead of crashing.

**Guard:** the `MSG_NOSIGNAL` flag is the guard; there is no portable
alternative for a stream socket other than ignoring the signal process-wide,
which is broader than this module should do.

### 3.7 Short reads/writes and `EINTR`

**Symptom class:** a frame arrives in multiple pieces, or a signal interrupts
`read`/`send`; a single `read`/`write` call returns fewer bytes than requested
and the parser sees a truncated JSON payload.

**Fix:** `readExact`/`readAtMost` and `writeAll` loop until the buffer is full
or EOF; `.INTR` is retried; a zero-length write is `error.WriteFailed`.
A stream socket has no message boundaries, so the frame header and payload
must never be read with a single unchecked syscall.

**Guard:** the frame code is the only path used by both processes, and the
forked round-trip tests exercise it.

### 3.8 Corrupt length / marker and oversized payloads

**Symptom class:** a desynchronized stream makes the reader interpret arbitrary
bytes as a length, blocking or reading garbage.

**Fix:** the marker is checked first; a mismatch returns `framed = false` and
stops the listener. The 4-byte length is bounded by `max_payload_len` before
the payload read. The frame struct is fixed-size, so a bogus length cannot
allocate unbounded memory.

**Guard:** `readFrame`'s documented error set and the `Frame` flags
(`framed`, `received`).

### 3.9 Re-entrant ping exchange deadlock

**Symptom class:** the manager's reply is executed through the original
`ServerCommand`. Executing that line can re-enter engine command handling; if
it (or a nested log/command path) triggers `zorcerer ping` again, the parent
starts a second exchange while the first is still waiting, and the two
processes wait on each other.

**Fix:** a module-level `handling_test_ping` guard. Both triggers (the
registered ConCommand's `Dispatch` and the `ServerCommand` detour) reach the
exchange through `runTestPingExchange`, which returns immediately when the
guard is set. The detour additionally forwards a nested test line to the
original `ServerCommand`, so the reply still executes even if the engine
re-enters the detour.

**Guard:** the guard is deliberately process-global because the engine invokes
commands serially; do not replace it with a per-request flag if callbacks ever
become concurrent.

### 3.10 Losing the original `ServerCommand` pointer

**Symptom class:** after installing the detour there is no way to execute the
manager's reply, because the vtable slot now points at the detour.

**Fix:** `VTableHooks.VtableHook.install` returns the original function
pointer; `serverCommandDetour` stores the hook in the module-level
`server_command_hook` and `callOriginalServerCommand` casts
`hook.original_fn` back to the engine signature. A C-ABI callback cannot
capture context, so module-level storage is required.

**Guard:** `installServerCommandHook`/`uninstallServerCommandHook` own the
hook's lifetime; `unload()` removes the hook after unregistering the command.

## 4. How to implement Source engine console commands

### 4.1 Three different things called "command"

Do not conflate them:

1. **Console command table (`ConCommand` + `Cbuf`/`Cmd_ExecuteString`)** —
   what `rcon <line>` and the server console execute. The engine tokenizes the
   line and looks up `argv[0]` in this table. This is the correct registration
   point for `zorcerer ping`.
2. **`IVEngineServer::ServerCommand`** — a direct engine call that feeds a
   command line into the engine. It is useful for *executing* a line from
   plugin code (our reply path) but is not a registration mechanism and is not
   guaranteed to see incoming RCON lines.
3. **VSP callbacks** — `Load`, `LevelInit`, etc. They have nothing to do with
   console-command lookup.

### 4.2 Registration recipe

The working implementation is in `src/Entrypoint.zig`:
`registerTestPingCommand`, `unregisterTestPingCommand`, `ConCommandObject`,
`concommand_vtable`, and `conCommandDispatch`.

1. **Get `ICvar` from the engine factory.** `load()` receives the engine's
   `CreateInterfaceFn`. Fetch `"VEngineCvar004"` exactly as
   `ConnectTier1Libraries` does:

   ```zig
   const cvar = interface_factory(Indexes.cvar_interface_version, null);
   ```

2. **Allocate a DLL identifier** with `ICvar::AllocateDLLIdentifier`
   (generated slot `Indexes.ICvar.allocate_dll_identifier`). The command's
   `GetDLLIdentifier` should return it. Keep it if you ever want
   `UnregisterConCommands(id)`; per-command unregistration is enough for the
   current code.

3. **Build a static `ConCommand`-shaped object.** It must have static storage
   duration and an Itanium C++ ABI layout:

   | Offset (x86_64) | Field | Meaning |
   |---|---|---|
   | 0 | `vptr` | pointer to the function-pointer table |
   | 8 | `m_pNext` | engine-owned link |
   | 16 | `m_bRegistered` | `bool`, 1 byte + 7 padding |
   | 24 | `m_pszName` | NUL-terminated command name |
   | 32 | `m_pszHelpString` | NUL-terminated help text |
   | 40 | `m_nFlags` | `FCVAR_*` flags |
   | 48 | command callback union | unused; `Dispatch` is overridden |
   | 56 | completion callback union | unused; no completion |
   | 64 | callback-kind bitfields | 1 byte + 7 padding |
   | 72 | `sizeof` | |

   `ConCommandBase` ends at 48; `ConCommand` adds the two callback unions and
   the bitfield byte. The sizeof/offset tests in `src/Entrypoint.zig` pin
   this. If the SDK header changes, those tests fail before the engine sees a
   wrong layout.

4. **Fill the vtable by generated index, never by hand.** The generated
   `Indexes.ConCommand` ordering is:

   | Slot | Method |
   |---|---|
   | 0 | complete-object destructor |
   | 1 | deleting destructor |
   | 2 | `IsCommand` |
   | 3 | `IsFlagSet` |
   | 4 | `AddFlags` |
   | 5 | `GetName` |
   | 6 | `GetHelpText` |
   | 7 | `IsRegistered` |
   | 8 | `GetDLLIdentifier` |
   | 9 | `CreateBase` |
   | 10 | `Init` |
   | 11 | `AutoCompleteSuggest` |
   | 12 | `CanAutoComplete` |
   | 13 | `Dispatch` |

   The vtable stores raw pointers (`?*const anyopaque`). The object's vptr
   points at slot 0; the two-word Itanium RTTI header (offset-to-top,
   typeinfo) is not needed for ordinary virtual calls. Whether the live engine
   ever uses `dynamic_cast`/`typeid` on a `ConCommandBase` is not
   source-verified; the SDK's command path uses `IsCommand()` plus a cast. If
   the engine does perform a RTTI-based cast, a vtable without the RTTI header
   would be unsafe.

5. **Register** with `ICvar::RegisterConCommand`
   (`Indexes.ICvar.register_con_command`). The engine is expected to link the
   object into its command table and set `m_bRegistered`; the vstdlib
   implementation is not in the SDK checkout, so confirm that behavior against
   the live binary if registration misbehaves. `IsCommand()` must return true;
   `GetName()` must return the same NUL-terminated name the lookup uses.

6. **Validate the full invocation yourself.** The engine only matches
   `argv[0]`. For `zorcerer ping`, require exactly two tokens:

   - `argv[0] == "zorcerer"`
   - `argv[1] == "ping"`

   `CCommand` layout (same header, x86_64 Itanium):

   | Offset | Field |
   |---|---|
   | 0 | `m_nArgc` (`int`) |
   | 4 | `m_nArgv0Size` (`int`) |
   | 8 | `m_pArgSBuffer[512]` |
   | 520 | `m_pArgvBuffer[512]` |
   | 1032 | `m_ppArgv[64]` (pointers) |
   | 1544 | `sizeof` |

   `argc` counts the command name, and `argv[0]` is the command name.
   `Dispatch` receives a `const CCommand&`, which is ABI-identical to a
   pointer parameter, so the Zig callback is
   `fn (self: *ConCommandObject, command: *const CCommand) callconv(.c) void`.

7. **Execute the reply through the original `ServerCommand`.** Keep the
   detour's captured `original_fn`; call it with a NUL-terminated line. In the
   current test the manager returns `echo "Pong!"`, which the engine executes
   as a normal console command. Do not send the reply back into your own
   `Dispatch` path.

8. **Unregister before unloading.** In `unload()`:

   ```zig
   unregisterTestPingCommand();   // ICvar::UnregisterConCommand
   uninstallServerCommandHook();
   // then stop the manager child
   ```

   If the engine keeps a registered object that points into an unmapped `.so`,
   a later lookup/dispatch crashes the server. Unregistration must happen
   while the module is still loaded. The current code also resets the object's
   `registered` byte and the module-level DLL id after unregistering.

### 4.3 Command flags and dedicated-server behavior

- Flags `0` are fine for the test: the command is always available and is not
  restricted by `FCVAR_CHEAT`.
- `FCVAR_GAMEDLL` matters for the listen-server forwarding decision. The SDK's
  disabled `Cmd_ExecuteString` snapshot computes
  `isServerCommand = FCVAR_GAMEDLL && console source && !IsDedicated()`; treat
  that as a hint, not proof of live-engine behavior. A TF2 dedicated server is
  dedicated, so this flag is not needed here.
- Source command lookup is reported to be case-insensitive, but that is not
  verified against the installed TF2 binary here. The current
  `isTestPingInvocation` compares `argv[0]` with `std.mem.eql` and is
  therefore case-sensitive. If `ZORCERER ping` should work, switch that one
  comparison to a case-insensitive helper; keep the argument check as strict
  as the command contract requires.
- The command name must not contain whitespace. `zorcerer ping` is the name
  `zorcerer` plus the first argument `ping`, not a two-word command name.

### 4.4 Adding a second command

Do not register every subcommand as a separate `ConCommand` with a space in
the name. Either:

- register one command and dispatch on `argv[1]` (the current pattern), or
- register several distinct names (`zorcerer`, `zorcerer_admin`, ...) that
  each carry their own dispatch.

For each command, keep the object static, add it to the load/unload lifecycle,
and add a token-matching unit test. If you replace the hand-built object with
a table, make every vtable entry come from `Indexes.ConCommand`.

## 5. Other notes

### 5.1 Fork safety

The child allocates memory, reads files, and `dlopen`s plugins. The current
design assumes the parent is effectively single-threaded when the VSP `Load`
callback runs; that assumption, not the code, is what makes the fork safe. Do
not assume it holds if the manager is ever forked from a signal handler, a
worker thread, or during an engine callback that may run concurrently with
another thread. Document any change to that assumption.

Never call the engine's `LogPrint` from the child after `fork()`. The child
switches to `Log.setupIpc(fd)` before loading plugins, so every log line
becomes a `stderr` notification to the parent. The parent forwards it through
its own engine sink. This is both a fork-safety measure and the mechanism that
makes child logs visible in the server console.

### 5.2 Logging and wire debugging

- `std.debug.print` is used for the JSON-RPC request/response dumps required by
  the test scenario. It writes to stderr, which the dedicated server shows in
  its console/log.
- Production log lines go through `Log.logLine` (engine `LogPrint` in the
  parent, IPC in the child), not through `std.debug.print`. The log buffer is
  512 bytes; an oversized line is replaced with a fixed note.
- The manager prints the `serverCommand` request before handling it and the
  composed response before sending it. The entrypoint prints the request it
  sends and the response it receives. This makes a failed round trip visibly
  hang at the exact side that stopped.
- Do not use `std.debug.print` from deep protocol code on every frame without
  expecting noisy server logs; it is acceptable for the current test but will
  need a verbosity gate for production.

### 5.3 Synchronous exchange rules

- One outstanding request per direction. The engine serializing callbacks is
  an assumption of this design, not something the SDK proves; revisit the
  protocol before adding concurrent callers.
- A response must carry the exact ID of the request. Validate it before
  consuming the result (`error.UnexpectedResponseId`).
- A JSON-RPC error response is still a response: it must terminate the wait
  and be surfaced as an engine-side log, not ignored.
- Malformed input gets one error response if the ID can be recovered;
  notifications get none.
- Reentrancy is the main deadlock risk. The `handling_test_ping` guard exists
  for this reason. Any new engine entry point that can trigger an exchange
  must use the same guard or a stronger one.

### 5.4 ZigJR-specific gotchas

- `parseRpcRequest` and `parseRpcResponse` are **total parsers**. They return a
  result object with error fields instead of an error union. Always check
  `isRequest()`, `isMissingMethod()`, `hasError()`, and `method.len`.
- `RpcId` is a union: `none` (field absent), `null` (`"id": null`), `num`,
  `str`. `isNotification()` is true for both `none` and `null`. Use
  `RpcId.ofNone()` for messages that should never be answered,
  `RpcId.ofNull()` for an error response whose request ID is unknown, and
  `RpcId.of(i64)` for real requests.
- `makeResponseJson(alloc, id, result_json)` returns `null` for notifications.
  `result_json` is **already serialized JSON**. To return a string, quote it
  first (for example with `std.json.Stringify.valueAlloc`), otherwise the
  response is malformed. `sendEventResponse` shows the correct pattern.
- `parseRpcResponse(...).response()` returns `error.NotSingleRpcResponse` for
  batches and empty parses; the current IPC only accepts a single response.
- ZigJR's composer output is not byte-stable across functions: some writers
  include spaces after `:` and others do not. Parse JSON in tests; do not
  compare raw composer output unless the test is specifically pinning that
  composer's format.
- The in-process `MockListener`/`MockSender` pair exercises ZigJR's
  `RpcDispatcher`/`RequestPipeline`. The production forked channel does not
  use the dispatcher; it uses `Ipc.parseManagerRequest` plus explicit
  response composition. That is intentional: the manual path gives exact
  control over "exactly one response per ID-bearing request" and over the
  framing on a raw file descriptor.

### 5.5 Ownership and lifetimes

- `ParsedRequest`, `ParsedEvent`, `ParsedServerCommand`, and
  `ManagerRequest` own their parsed JSON; `deinit()` releases it. Their
  `value`/`command` slices borrow that storage and become invalid at
  `deinit()`. In loops, use `defer parsed.deinit()` inside the loop body, not
  once outside.
- `Frame.text()` borrows the frame's fixed payload buffer. The buffer is
  reused by the next `readFrame`; copy anything that must outlive it.
- Engine-owned strings (`CCommand.argv` entries, `LogPrint` messages) are only
  valid for the duration of the callback. Do not store them.
- The registered `ConCommand` object has static storage and must outlive
  registration. Never heap-allocate it and never let the engine delete it; the
  destructor slots are no-ops for this reason.

### 5.6 Frame size and error budget

- 4096 bytes covers the current messages comfortably. Log lines are already
  capped at 512 bytes. If a future method needs large payloads, decide between
  raising the frame limit, chunking, or refusing the method; silently
  truncating JSON is not an option. The design note in
  `docs/references/json_ipc.md` already flags this as an open decision.
- `readFrame` stores the payload in a stack `Frame`; raising the limit raises
  per-call stack usage in both processes.

### 5.7 Testing and build wiring

- The useful tests are the ones that use a real `socketpair` and `fork`:
  `forkChild` + `Manager.listenForEvents` catch framing, EOF, response-ID, and
  notification-ordering bugs that a pure in-process mock cannot. Always
  `defer child.finish()` so the child is reaped and the socket is closed.
- The in-process `MockListener`/`MockSender` tests are still useful for
  ZigJR schema/dispatch behavior and are cheap.
- `zig build compile-modules` compiles the Zorcerer library and its test
  target. `build.zig` currently **compiles** the Zorcerer tests but does not
  add their run step to `tests` (the `run_zorcerer_tests` dependency is
  commented out). An agent that needs the Zorcerer test results must run the
  test binary explicitly or restore that step.
- Tests that fork require a host that permits `fork` and `socketpair`; a
  sandbox that denies them will look like a test failure, not a code failure.
- The unit tests pin `CCommand` and `ConCommandObject` offsets. If you change
  either struct, update the tests and re-check the SDK header rather than
  silently changing an offset.

### 5.8 Engine ABI verification checklist

Before trusting the command on a new TF2 build:

1. Confirm the engine answers `VEngineCvar004` from the factory passed to
   `Load`. `registerTestPingCommand` fails the load with `CvarUnavailable`
   otherwise.
2. Confirm the generated `Indexes.ICvar` slots still match the installed
   binary: `AllocateDLLIdentifier`, `RegisterConCommand`,
   `UnregisterConCommand`.
3. Confirm `Indexes.ConCommand` slot 13 is the dispatch override and the
   object layout tests still match the header used by the analyzer.
4. After registration, a useful self-check is `ICvar::FindCommandBase`
   (`Indexes.ICvar.find_command_base`, slot 10) with `"zorcerer"`; a null
   result means the engine did not accept the object into its table. This is
   not implemented yet; add it behind a debug log if registration is
   suspected.
5. Issue `zorcerer ping` from the server console first, then over RCON. If the
   console works and RCON does not, the remaining problem is the RCON command
   path, not the ConCommand registration.
6. Watch for `Unknown command "zorcerer"` (registration missing) versus
   nothing happening (dispatch reached but the exchange failed) versus a
   server crash (vtable/lifetime/ABI mismatch). The distinction is the fastest
   way to localize the failure.

### 5.9 Current limitations / next steps

- The manager's `serverCommand` handler is hard-coded: `testServerCommandReply`
  returns `echo "Pong!"` only for `zorcerer ping`. There is no plugin dispatch
  yet. Do not build a plugin-facing API on top of this handler without
  designing the method allowlist and trust boundary described in
  `docs/references/json_ipc.md`.
- Only one console command (`zorcerer`) exists. It registers at load and
  unregisters at unload; there is no generic registration table yet.
- The reply path depends on `IVEngineServer::ServerCommand` and its captured
  original pointer. If the hook cannot be installed, `load()` refuses to
  continue; there is no alternative reply path.
- The ConCommand ABI is source-derived and has not been exercised on a live
  TF2 server in this work. Treat registration/dispatch as unverified until the
  checklist above passes.
- The JSON-RPC channel is synchronous by design. If future work needs
  concurrent calls (for example, asynchronous plugin requests), add a request
  ID allocator plus a pending-response map, and revisit the fixed IDs 1/2 and
  the single-threaded assumption.

## 6. Useful references

| Topic | File |
|---|---|
| Wire framing, schemas, ZigJR usage | `src/Ipc.zig` |
| Fork, listener, `ServerCommand` detour, ConCommand | `src/Entrypoint.zig` |
| Child listener and hard-coded test handler | `src/PluginManager.zig` |
| Engine/IPC logging | `src/io/Log.zig` |
| Interface versions and vtable indices | `src/codegen_generated/engine_indexes.zig` |
| `ICvar` declaration and slots | `extern/source/source-sdk-2013/src/public/icvar.h` |
| `ConCommand`/`CCommand` layout | `extern/source/source-sdk-2013/src/public/tier1/convar.h` |
| How the SDK loads ICvar from a factory | `extern/source/source-sdk-2013/src/tier1/tier1.cpp` |
| Design constraints and open questions for the API | `docs/references/json_ipc.md` |
| SDK/source provenance and versioning | `docs/references/source-sdk-2013.md` |
