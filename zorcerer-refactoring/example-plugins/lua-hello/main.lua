-- Example Lua plugin for Zorcerer.
--
-- Install this directory as:
--
--     tf/addons/zorcerer/plugins/lua-hello/main.lua
--
-- The directory name becomes zostd.plugin_id(). A Lua-only plugin needs no
-- manifest: the manager loads every plugins/<dir>/main.lua it finds.
--
-- The script demonstrates the current Lua surface:
--
--   * zostd.log/version/plugin_id
--   * plugin:// reads and writes through the manager's filesystem service
--   * read-only game queries
--   * server_command, which is forwarded to the engine over IPC
--   * client_print, available while handling a client console command
--   * lifecycle event callbacks registered with zostd.on
--
-- server_command only reports that the Entrypoint handed the command to the
-- engine; it cannot report whether the engine recognized or executed it.
-- client_print only reports that the message reached IVEngineServer::ClientPrintf.

local id = zostd.plugin_id()
local report_path = "plugin://hello.txt"

--- Formats and sends one log line through the plugin manager.
-- @param message Value converted with tostring and prefixed with the plugin id.
local function log(message)
    zostd.log("lua-hello: " .. tostring(message))
end

--- Logs a snapshot of the server and the hostname cvar.
-- Query failures are logged instead of raised so the example keeps running on
-- a host without an engine query channel.
-- @return The server-info table, or nil when the query failed.
local function logServerInfo()
    local info, info_error = zostd.game.server_info()
    if not info then
        log("server info unavailable: " .. tostring(info_error))
        return nil
    end

    log(string.format(
        "map=%s entities=%d dedicated=%s uptime=%.1fs",
        tostring(info.map_name),
        info.entity_count,
        tostring(info.dedicated),
        info.server_time))

    local hostname = zostd.game.server_cvar("hostname")
    if hostname then
        log("hostname=" .. hostname.text)
    end
    return info
end

--- Writes, reads back, and logs the plugin's report file.
local function demonstrateFiles()
    local wrote, write_error = zostd.write_file(report_path, "hello from zlua\n")
    if not wrote then
        log("write failed: " .. tostring(write_error))
        return
    end

    local data, read_error = zostd.read_file(report_path)
    if not data then
        log("read failed: " .. tostring(read_error))
        return
    end

    local trimmed = data:gsub("\n", "")
    log("report read back: " .. trimmed)
end

--- Sends one engine command and one deliberately invalid command.
local function demonstrateCommands()
    local accepted, command_error = zostd.server_command("echo lua-hello on_load")
    if not accepted then
        log("server command rejected: " .. tostring(command_error))
    end

    -- Commands must be a single line; this one is rejected before it reaches
    -- the engine, and the error name is safe to log.
    local _, multiline_error = zostd.server_command("echo one\necho two")
    log("multiline command rejected: " .. tostring(multiline_error))
end

zostd.on("on_load", function()
    log("loaded as " .. id .. " (api " .. tostring(zostd.version()) .. ")")
    demonstrateFiles()
    logServerInfo()
    demonstrateCommands()
end)

zostd.on("on_runtime_entered", function()
    log("manager entered the runtime")
end)

zostd.on("levelInit", function(event, payload)
    log(event .. " payload=" .. tostring(payload))
    logServerInfo()
end)

zostd.on("serverActivate", function(event, payload)
    log(event .. " payload=" .. tostring(payload))
end)

zostd.on("levelShutdown", function(event, payload)
    log(event .. " payload=" .. tostring(payload))
end)

zostd.on("pause", function()
    log("pause")
end)

zostd.on("unpause", function()
    log("unpause")
end)

-- Answers the client console command "zlua ping". The payload is the full
-- command line as typed; extra whitespace is ignored and the match is
-- case-insensitive. A successful print also suppresses the game DLL's
-- unknown-command handling.
zostd.on("clientCommand", function(event, payload)
    local command = tostring(payload or ""):match("^%s*(.-)%s*$"):lower()
    if command ~= "zlua ping" then
        return
    end

    local sent, send_error = zostd.client_print("Pong!")
    if sent then
        log("replied to zlua ping")
    else
        log("zlua ping reply failed: " .. tostring(send_error))
    end
end)

zostd.on("on_unload", function()
    log("unloading")
end)
