/// Result values of `PLUGIN_RESULT`, the C enum returned by callbacks such as
/// `ClientCommand`.
///
/// The SDK declares the enum with an `int` representation, so the Entrypoint
/// uses `c_int` for the callback return type and these constants for the
/// values. Returning `plugin_stop` from `ClientCommand` keeps the game DLL from
/// processing the command again.
pub const PluginStates = enum(c_int) {
    @"continue",
    /// Run the game DLL function but use this plugin's return value instead.
    override,
    /// Do not run the game DLL function at all.
    stop,
};
