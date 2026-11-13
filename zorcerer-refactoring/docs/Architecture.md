# Zorcerer Architecture

## Workflow
1. Entrypoint - socket creation, fork process for plugin manager
2. Plugin manager - socket creation, plugin managing
   1. ZLua - Lua runtime that comes with Zorcerer

## Entrypoint
Valve's plugin system calls some functions to inject a plugin inside its engine. This is where Zorcerer's entrypoint is. The entrypoint simply creates a socket and a child process, where the plugin manager lives.

**About the socket and the child process**
The socket listens and responds with JSONs. I chose this format because it exists for, like, 20 years? And everyone used it in so many ways that it became extremely fast when performing serialization and deserialization. So the entrypoint, and the plugin manager speak with each other, using JSON format.

## Plugin manager
Managing dynamic libraries (.so format at the moment) that export the next functions:
- load(ctx: *PluginContext)
- unload(ctx: *PluginContext)

Plugin loading consists of these steps:
1. Reading every manifest.toml recursively inside ./zorcerer/plugins/ directory
2. Deserializing manifests into Zig structures
3. Calculating dependency graph
4. Using the graph, load plugins.
5. Runtime

## Zorcerer standard library
Remember the times, when you were writing SourceMod plugin and had to git submodule the entire internet, just to make an addon for a plugin? Or if you were creating a plugin, for, let's say, TF2, and had to load submodules too, because SourceMod does not come with unified interfaces?

I hope we can forget about these times. There will be a module called "zostd". I haven't figured out yet, how can I create such module that can not only be included in Zig, but in pretty much every language. Probably make all functions extern, or manually mangle the extern functions. I will work on it later!

## ZLua
This is just the LuaJIT runtime that comes with Zorcerer. That's where its names comes from: Zig + Lua = ZLua. It uses zostd to speak with the plugin manager.

## Breaking updates
I try to prevent breaking plugins after updates as far as I guess how to do it. Currently, the Magnum Opus of preventing the breaks is the C++ code analyzer. Check build/analyzers/ files. They read raw_data.toml, containing what we want to analyze inside the SDK, and send those queries to the analyzer over standard input. LLVM analyzes the Source SDK headers and reports the resolved values, including VTable indexes, on standard output. The Zig adapter consumes that output directly and passes it to EngineIndexesGenerator, which writes src/codegen_generated/engine_indexes.zig; no intermediate .toml file is produced.

There's some other, not-fully implemented things that also run in runtime.

Summing up:
1. C++ headers analyzer + Zig codegen
2. Runtime VTable index checker
3. Runtime engine version resolver (As of 2026-10-25, it's deleted, but it will come back after I rethink how it works!)
