//! Small C-ABI contract shared by Zorcerer and its dynamically loaded plugins.

pub const abi_version: u32 = 1;

pub const CreateInterfaceFn = *const fn (
    name: [*:0]const u8,
    return_code: ?*c_int,
) callconv(.c) ?*anyopaque;

/// Context passed to plugin `load()`. `struct_size` permits future extension
/// without making a newer core pass an unexpectedly short structure to a plugin.
pub const Context = extern struct {
    abi_version: u32,
    struct_size: usize,
    engine: *anyopaque,
    interface_factory: CreateInterfaceFn,
};
