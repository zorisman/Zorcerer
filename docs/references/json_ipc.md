# JSON IPC design decision

## Revised decision

**Yes to generated schemas — but not from `engine_indexes.zig`, and not as raw JSON Schema.** With arbitrary-language plugins, the machine-readable contract becomes genuinely valuable. The right move is:

> One curated, typed **engine-API declaration** → generate (a) Zig validation/dispatch metadata for Manager + Entrypoint, (b) an **OpenRPC document** with embedded JSON Schema for plugin authors, tests, and external tooling.

`engine_indexes.zig` stays what it is: the ABI slot/version table. It is an input to the binding, not the API definition.

## Why the requirement changes the answer

Your flow makes the schema useful for three distinct consumers:

1. **Plugin authors in other languages** need a static, versioned description of methods, params, results, and errors.
2. **Plugin Manager** needs to reject malformed requests early.
3. **Tests/tooling** need valid and invalid examples.

But it also exposes two facts that rule out “generate schemas from the vtable dump”:

- Vtable entries have **no signatures** today (the analyzer emits only `Class::Method = slot`).
- Most vtable methods are **not a sane public API**. `CBaseEntity` alone has ~195 slots and `CBasePlayer` ~460, with raw pointers, out-params, and internal game logic. A 1:1 schema of that surface would be enormous, unstable, and dangerous.

So the contract must be a **designed semantic API** (`entity.getHealth`, `engine.serverCommand`), not a serialization of C++ virtual functions. Each semantic method is explicitly bound to one or more vtable slots in the Entrypoint.

## Recommended layering

```
SDK headers ──analyzer──▶ engine_indexes.zig          (ABI: slot indices, interface versions)
                                  │
                                  ▼
                    engine API declaration           (semantic: method, params, result,
                     (Zig comptime or TOML)           safety class, version, slot binding)
                                  │
                     ┌────────────┴─────────────┐
                     ▼                          ▼
        generated Zig types + table      OpenRPC + JSON Schema
        (used by Manager/Entrypoint)     (used by plugin authors/tooling)
```

- **`engine_indexes.zig`**: unchanged responsibility.
- **API declaration**: the single source of truth. I recommend Zig comptime structs because both runtime sides are Zig, and slot references can be compile-time checked against `Indexes.*`.
- **Generated artifacts**: Zig metadata for runtime; OpenRPC/JSON Schema for everyone else.

## Why OpenRPC, not standalone JSON Schema

JSON Schema describes *values*. Your contract is *JSON-RPC 2.0 methods*. OpenRPC is the standard document for exactly that: method names, param names/requiredness/schemas, result schemas, and error codes, with reusable `$defs`-style components. It also gives you a natural place for:

- `info.version` for the API revision
- per-method extension fields for safety classification and required plugin capabilities
- engine interface version compatibility metadata from `engine_indexes.zig`

You can still emit standalone JSON Schema files for individual types if authors prefer, but OpenRPC should be the published spec.

## What the declaration should contain

Per method:

- **Logical name** (namespaced, e.g. `engine.serverCommand`, `entity.getHealth`)
- **Params and result types** using a small explicit wire-type set:
  - integers/floats/bools/strings
  - `Vector`/`QAngle` as objects or fixed arrays
  - **entity handles** (indices), never raw pointers
  - opaque interface handles for things that cannot cross the fork boundary
  - bounded arrays/byte buffers
- **Safety class**: `safe`, `unsafe` (with reason), `denied`
- **Required capabilities/permissions** (to enforce per-plugin policy)
- **Binding metadata**: interface + `Indexes.<Class>.<method>` slot(s)
- **Error codes** specific to the method
- **API revision / minimum engine version**

The **binding itself** (marshalling into C++ types, handle resolution, out-param copy-back) should be explicit Entrypoint code, at least initially. Generate it only for simple scalar methods; require a manual adapter for anything involving pointers, out-params, or engine-owned memory. Default deny for unbound methods.

## Validation and the trust boundary

Your three-stage validation is right, but one important correction:

> The Plugin Manager shares an address space with the plugins (they are dlopen’d into the child). A malicious or compromised plugin can bypass the Manager entirely, or corrupt it.

Therefore:

- **Manager-side validation**: early rejection, good logs, developer UX. Use the generated Zig types.
- **Entrypoint-side validation**: the actual security boundary. It must independently enforce the method allowlist, safety class, permissions, argument ranges, and payload limits. Never trust “the Manager already checked.”
- **JSON Schema is not the security layer.** It validates shape. Safety classification, capability checks, entity-handle ownership, and dangerous-argument inspection must be policy data plus code in the Entrypoint.

Map your flow:

| Case | Where it is caught | Response |
|---|---|---|
| Malformed JSON-RPC / unknown method | Manager (and again in Entrypoint) | `InvalidRequest` / `MethodNotFound`, log, skip |
| Wrong param types/ranges | Manager, then Entrypoint | `InvalidParams`, log with plugin id, skip |
| Known method but unsafe/unauthorized | Manager (UX), **Entrypoint (enforced)** | custom error code, malware-warning log, skip |
| Valid and allowed | Manager forwards, Entrypoint executes | normal JSON result back |

## Practical recommendations

1. **Start with a hand-written Zig declaration** for 3–5 methods, plus a small generator that reflects params/results into OpenRPC + JSON Schema. This validates the design before building a large generator.
2. **Do not auto-expose vtable wildcards.** The analyzer’s `*` queries are great for discovery, not for the public API.
3. **Use the analyzer for drift checks**, not schema definition: verify that a declared binding’s slot still exists and its header signature is still compatible. Fail the build on drift.
4. **Publish a conformance corpus**: generated valid/invalid JSON examples per method. Any-language SDKs and the Manager’s tests use the same corpus.
5. **Version the API separately from the engine index**: include both the API revision and the `engine_indexes` interface version in the handshake, so a plugin can discover what the running server supports.
6. **Revisit the 4096-byte frame limit** before promising arrays/strings to external languages. Either raise it for engine calls or define chunked/binary frames; JSON Schema alone won’t solve payload size.
7. **Document nullability and units** in the schema (e.g. `Vector` units, tick vs seconds, entity handle validity). Cross-language authors will otherwise guess.

## Bottom line

Generate schemas — yes. Derive them from `engine_indexes.zig` — no. Publish OpenRPC + JSON Schema generated from a curated, safety-annotated engine-API declaration; use the same declaration to generate the Zig runtime table. Keep the vtable index table as an internal ABI input, and keep the actual engine invocation explicit and allowlisted in the Entrypoint.
