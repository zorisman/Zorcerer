//! Module-root facade for source files in the `zorcerer` module.
//!
//! Zig reserves the import name `root` for the compilation root, and in test
//! builds that root is the generated test runner rather than `src/root.zig`.
//! This module is therefore the stable root-relative entry point used by
//! production and test builds alike:
//!
//! ```zig
//! const root = @import("zroot");
//! const fs = root.io.filesystem;
//! ```
//!
//! It only re-exports `zorcerer`; the import cycle between the two modules is
//! intentional and keeps a single instance of every declaration and global.

const zorcerer = @import("zorcerer");

/// Plugin ABI declarations (src/core/plugin/PluginContext.zig).
pub const abi = zorcerer.abi;

/// IPC transport and message-schema modules (see `zorcerer.ipc`).
pub const ipc = zorcerer.ipc;

/// Logging and filesystem facilities.
pub const io = zorcerer.io;

/// Generated engine indexes.
pub const codegen = zorcerer.codegen;

/// Core manager, entrypoint, and service modules.
pub const core = zorcerer.core;
