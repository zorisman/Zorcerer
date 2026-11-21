pub const Iface = enum(c_int) {
    /// `CreateInterface` success code returned through its optional out-parameter.
    ok,
    /// `CreateInterface` failure code returned through its optional out-parameter.
    failed,
};
