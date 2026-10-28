# Switching the current IPC JSON schema to zigjr

## Verified findings

Current IPC contract (HEAD `2d727d5`):

| Location | Role |
|---|---|
| `src/Ipc.zig:164-247` | Custom schema: `{"operation":"stderr","message":"..."}` and `{"event":"X"}`; parsing/serialization through `std.json` directly |
| `src/Ipc.zig:71-162` | Transport framing: `0xA5 + u32 length + JSON payload`, `max_payload_len = 4096` |
| `src/Entrypoint.zig:295-352` | Parent handles every frame as a `Request`; child sends a `stderr` request as its readiness report |
| `src/Entrypoint.zig:603-655` | Parent sends `{"event":"X"}`, then blocks reading exactly one reply |
| `src/PluginManager.zig:365-421` | Child listens for events, answers every frame with `{"operation":"stderr","message":"Event is X"}` |
| `build.zig:98-103,160` | `zjr` module is already declared and imported into the `zorcerer` module |
| `src/Ipc.zig:15` | `@import("zjr")` exists only as an **uncommitted** working-tree change |

Dependency state: `extern/zigjr` is pinned to `b4f2e1d`, `build.zig.zon` declares version `1.9.0`, minimum Zig `0.15.1`. The project uses Zig `0.16.0`.

Compatibility check with the installed Zig 0.16.0:

- Importing the library through its current root `extern/zigjr/src/zigjr.zig` fails to compile:
  - `@Type` removed: `src/rpc/dispatcher.zig:193`, `src/rpc/json_call.zig:259`
  - `detectLeaks()` now returns `usize`: `src/streaming/BufReader.zig`, `src/streaming/DupWriter.zig`
  - `std.fs.File` removed: `src/streaming/DupWriter.zig:64`, `src/streaming/stream.zig:103`
- The **core subset** — `jsonrpc/request.zig`, `response.zig`, `message.zig`, `composer.zig`, `errors.zig` — compiles and works on Zig 0.16.0. I verified compose → parse round-trips, strict parsing, writer-based composition, and error responses through a wrapper module.

So the main blocker is not JSON-RPC itself, but importing the whole zigjr root. The IPC only needs the core subset.

## Recommended path: adopt zigjr core only

### 1. Dependency and module wiring

Do **not** point the `zjr` module at `zigjr.zig` yet. Add a small parent-repo adapter, e.g. `extern/zigjr_core.zig`, that re-exports only:

```zig
jsonrpc/request.zig
jsonrpc/response.zig
jsonrpc/message.zig
jsonrpc/composer.zig
jsonrpc/errors.zig
```

It must **not** re-export `JsonStr`, `RequestDispatcher`, `RpcDispatcher`, `pipeline`, `stream`, `logger`, or `DispatchCtx`, and must not include the `test {}` block from `zigjr.zig`; those pull in `json_call.zig`/`dispatcher.zig` and their `@Type` uses.

Change `build.zig` to:

```zig
.root_source_file = b.path("extern/zigjr_core.zig"),
```

Keep the submodule pinned and unchanged. This also avoids a submodule commit for a library that upstream will presumably port to 0.16.

Alternative, larger path: patch zigjr for 0.16 (`@Type` → `@Struct`/`@Pointer`, `std.builtin.Type.StructField` changes, `detectLeaks`, `std.fs.File` → `std.Io`) and then use `RpcDispatcher`/`RequestPipeline`. That is not required for this schema switch and has much wider blast radius.

### 2. Define the JSON-RPC mapping

| Old message | New message |
|---|---|
| child → parent readiness/log | notification `log`, params `{"message":"..."}` (no `id`) |
| parent → child event | request `event`, params `{"event":"pause"}`, numeric `id` |
| child → parent event reply | JSON-RPC response with result `"Event is pause"` |
| invalid event/params | error response `-32602 InvalidParams` |
| malformed/empty frame | error response `-32700 ParseError`, `id: null` |
| unknown method | error response `-32601 MethodNotFound` |

Keep the existing `0xA5` framing and `max_payload_len`; JSON-RPC 2.0 has no framing of its own, and zigjr's stream module is not usable on 0.16 anyway.

### 3. Rewrite `src/Ipc.zig`

- Remove `Operation`, `Request`, `EventMessage`, `parseRequest`, `stringify`, `sendRequest`, `parseEvent`, `encodeEvent`, `sendEvent`, `eventResponseText`, `sendEventResponse`.
- Keep `Frame`, `readFrame`, `writeFrame`, `max_payload_len`.
- Add:
  - `pub const method_log = "log"; pub const method_event = "event";`
  - `LogParams = struct { message: []const u8 }`, `EventParams = struct { event: Event }`
  - `Message` union over `zjr.RpcRequestResult` / `zjr.RpcResponseResult` with `deinit`.
  - `parseMessage()` implemented as `parseRpcRequest` + `isMissingMethod()` fallback, rather than `zjr.parseRpcMessage()`: the latter detects requests by substring `"method":`, which misclassifies legal JSON such as `"method" : "event"`.
  - `sendLog(fd, message)`, `sendEvent(fd, id, event)`, `sendEventResult(fd, id, text)`, `sendError(fd, id, code, message)`.
  - Param validation/extraction helpers returning `?Event` / `?[]const u8`; reject non-object params, wrong value types, and unknown param keys.
- Compose with `zjr.composer.writeRequest*` / `writeResponseJson` / `writeErrorResponseJson` into `std.Io.Writer.fixed`, preserving the allocation-free send path. `writeRequest` is also acceptable but allocates params JSON per call.
- Guard response composition: `writeResponseJson` is `unreachable` for `.none`/`.null` IDs; reply only to `.num`/`.str`, and send an `InvalidRequest` error for `.null`.

### 4. Rewrite `src/Entrypoint.zig`

- `handleRequest` → `handleMessage`:
  - Request `log` notification: print `params.message`.
  - Response: on error, print the error message; otherwise print the string result.
  - Unknown request method: log rather than reply (parent is not the server here).
- `jsonListener`: parse via `Ipc.parseMessage`, not `parseRequest`.
- `pluginManagerChild` / `testReportChild`: use `Ipc.sendLog`.
- `sendManagerEvent`: allocate a monotonic event `id`, call `Ipc.sendEvent(fd, id, event)`, then `jsonListener` to consume the response. Verify the response ID with `RpcId.eql`.
- Update the module header (`src/Entrypoint.zig:24-31`) which currently documents the old schema.

### 5. Rewrite `src/PluginManager.zig:365-421`

- Parse incoming messages as requests.
- Check `req.hasError()` and answer with `composer.writeErrorResponseJson(req.err().req_id, req.err().code, req.err().err_msg)`.
- Dispatch `event`: validate params, then send result `"Event is X"`.
- Unknown method → `MethodNotFound`; bad params/unknown event → `InvalidParams`.
- Notifications (no `id`) get no reply; numeric/string IDs get exactly one response.
- Replace `respondInvalidEvent` with a general `respondError`.
- Update the doc comment at `src/PluginManager.zig:348-362`.

### 6. Update tests

The exact-byte assertions in `src/Entrypoint.zig:371-500` will change because zigjr's composer emits spaces (`{"jsonrpc": "2.0", ...}`). Prefer semantic assertions (`parseMessage` + field checks) over byte equality.

Tests to replace/adjust:

- "child payload matches the serialized request" → assert a `log` notification with the right message.
- "listener schema decodes the stderr operation" → assert request method/params.
- "listener schema rejects an unknown operation" → unknown method is now valid JSON-RPC at parse time, rejected by the manager with `MethodNotFound`; move the assertion to the fork-level test.
- "listener schema rejects an unknown field" → if strict top-level parsing is kept, use `parseRpcRequestOwned` with an owned duplicate and `ParseOptions{}`; otherwise change this to an unknown **params** key.
- "event JSON matches the schema" → method `event`, object params, round-trip.
- "event schema rejects an unknown callback" → valid envelope, `InvalidParams` error response.
- "manager answers every Entrypoint event with the stderr schema" → assert response result `"Event is X"`.
- "manager answers an unknown event" → expect `-32602` error, not a log request.
- Add a mixed-whitespace classification test if `parseMessage` is used.

### 7. Documentation and verification

- Update `docs/Architecture.md` ("responds with JSONs") to mention JSON-RPC 2.0.
- Add a doc comment to the adapter explaining why it exists and that it must stay limited to the core subset until zigjr supports Zig 0.16.
- Verify with:
  - `zig build compile-modules`
  - `zig build -Dskip-analyze tests`
  - `zig build -Dskip-analyze` (avoid the analyzer regenerating `config/engine_data.toml` during an unrelated change)
- The project build and tests were **not** run during this analysis, so those remain unverified.

## Decisions to confirm

1. Adapter over the core subset (recommended) vs. porting full zigjr to Zig 0.16.
2. Keep the existing binary framing (recommended) vs. adopting zigjr stream framing.
3. Method naming: `log`/`event` vs. namespaced `ipc.log`/`ipc.event`.
4. Unknown top-level JSON-RPC fields: lenient (zigjr default) vs. strict (requires owned duplicate + `parseRpcRequestOwned`).

The analysis was read-only; no project files were modified. The original working tree contains an uncommitted `@import("zjr")` in `src/Ipc.zig`; implementation should start from `HEAD` in a dedicated task worktree rather than depend on it.

Suggested commits:

```text
build: expose zigjr JSON-RPC core on Zig 0.16
refactor: switch IPC payloads to JSON-RPC 2.0 via zigjr
```
