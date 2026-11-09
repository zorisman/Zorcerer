pub const Identifiers = enum(i64) {
    /// Request ID that is unknown for the Entrypoint.
    unknown = 0,
    /// Request ID used by `sendEvent`.
    ///
    /// The Entrypoint sends callback events synchronously, one at a time, so a
    /// fixed positive ID is sufficient and lets the listener match the response.
    event_request_id = 1,

    /// Request ID the plugin-manager child uses for game queries.
    ///
    /// Queries are synchronous and strictly one at a time, and the parent is
    /// always blocked on the child's readiness or event response while a query is
    /// in flight, so a single fixed positive ID is sufficient.
    query_request_id = 100,

    /// Request ID the plugin-manager child uses for filesystem requests.
    ///
    /// File requests are synchronous and strictly one at a time: the child blocks
    /// until the engine process answers, and the parent is already listening while
    /// it waits for readiness, an event response, or the shutdown answer.
    file_request_id = 101,

    /// Request ID the plugin-manager child uses for engine command requests.
    ///
    /// Commands are synchronous and strictly one at a time: the child blocks until
    /// the engine process has accepted the command, and the parent is already
    /// listening while it waits for readiness, an event response, or the shutdown
    /// answer. Keeping the ID distinct from `event_request_id`,
    /// `query_request_id`, `file_request_id`, and `shutdown_request_id` prevents a
    /// reply from satisfying the wrong exchange.
    server_command_request_id = 102,

    /// Request ID the engine process uses to ask the plugin-manager child to
    /// unload its plugins and stop serving the channel.
    shutdown_request_id = 200,
};
