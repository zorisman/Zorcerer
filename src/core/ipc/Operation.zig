/// Operations the Entrypoint's JSON-RPC listener understands.
pub const OperationTypes = enum {
    /// Write `message` to the parent's log sink.
    stderr,
    /// Report that the plugin-manager child finished its load attempt.
    ///
    /// The message is the child's readiness text. The Entrypoint treats its
    /// expected readiness text as success and any other text as a startup
    /// failure.
    ready,
};
