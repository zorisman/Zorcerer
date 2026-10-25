# Zorcerer Architecture

## Workflow
1. Entrypoint - socket creation, fork process for plugin manager
2. Plugin manager - socket creation, plugin managing
   1. ZLua - Lua runtime that comes with Zorcerer

## Entrypoint
Valve's plugin system calls some functions to inject a plugin inside its engine. This is where Zorcerer's entrypoint is. The entrypoint simply creates a socket and a child process, where the plugin manager lives.

**Why don't create the Plugin Manager inside the engine?**
Since plugins are just dynamic libraries, this means that they can call any code, including system calls and other unsafe operations. Inside a child process, plugins still can create unsafe calls, but the risk is lower - it can't do much to the engine inside a small forked process.

**About the socket and the child process**
The socket listens and responds with JSONs. I chose this format because it exists for, like, 20 years? And everyone used it in so many ways that it became extremely fast when performing serialization and deserialization. So the entrypoint, and the plugin manager speak with each other, using JSON format.

## Plugin manager
Managing dynamic libraries (.so format at the moment) that export the next functions:
- load(ctx: *PluginContext)
- unload(ctx: *PluginContext)
Maybe there should be more functions, but I'll try to create Zorcerer as minimalistic as possible.

Plugin loading consists of these steps:
1. Reading every manifest.toml recursively inside ./zorcerer/plugins/ directory
2. Deserializing manifests into Zig structures
3. Calculating dependency graph
4. Using the graph, load plugins.

## Zorcerer standard library
Remember the times, when you were writing SourceMod plugin and had to git submodule the entire internet, just to make an addon for a plugin? Or if you were creating a plugin, for, let's say, TF2, and had to load submodules too, because SourceMod does not come with unified interfaces?

I hope we can forget about these times. There will be a module called "zostd". I haven't figured out yet, how can I create such module that can not only be included in Zig, but in pretty much every language. Probably make all functions extern, or manually mangle the extern functions. I will work on it later!

## ZLua
I hate SourcePawn. I hate it from the bottom of my heart. I worked on Source plugins before. THIS TRASH IS WHY I CREATE ZORCERER. I HATE SOURCEPAWN SO MUCH!!!!!!

I won't rant any further on the reasons, but trust me - I had enough. Instead of this bad language, the default one will be Lua. Small, blazingly fast - the perfection for scripting language!

- Why not TypeScript/JavaScript?

Because JavaScript runtimes are heavy.

- Why not Lisp?

(question (Are '(statement-p (you serious))))

Even if I don't implement these two, and much more runtimes that I didn't mention, you are always free to do it. You know that the plugin manager is kinda the plugin too? It just has more privileges.

# Other

## About breaking updates
I try to prevent breaking plugins after updates as far as I guess how to do it. Currently, the Magnum Opus of preventing the breaks is the C++ code analyzer. Check build/analyzers/ files. They read raw_data.toml, containing, what do we want to analyze inside the SDK, then LLVM analyze the Source SDK headers, generates .toml file that contains all the values, including VTable indexes, and codegens it into .zig format.

There's some other, not-fully implemented things that also run in runtime.

Summing up:
1. C++ headers analyzer + Zig codegen
2. Runtime VTable index checker
3. Runtime engine version resolver (As of 2026-10-25, it's deleted, but it will come back after I rethink how it works!)

## About the AI slop
Yes, yes I know that AI is bad, etc. etc.

But let's be realistic. **They are much better at writing code than we, humans**. Still, they are extremely bad in creating algorithms and architecture. So I study, and already use math to give them a direction how to write the code. For example, see the commit **ce9cbe9f72f29f2620d3cdc905c00a598f8ad285**. That was the day I learned about mathematical logic. As I found out, it is nearly perfect for creating tests, and I will continue my experiments with agentic programming, using math in prompt creation.

As I write this document, yes, I extremely slop the project. Why? Because I need a working prototype. I need to see, whether my idea is viable? And if I see that it can work out, my vision on the Zorcerer can go much further. So one day, I promise that I will review before committing to the main branches. And I hope that day comes very soon.

Will I write the code manually? Hell no. Except for something small. Writing code manually became routine work. If you are against it, then I'll remind you: remember when the Assembly guys told that high-level languages are making us stupid, and the programs unsafe? And where we are now? The history repeats itself. I just don't miss the train of progress. But who is right? We will see when Zorcerer becomes something more than a prototype.

AI agents are not programmers. They are tools.
