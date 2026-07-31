--[[
================================================================================
    Terror AustraliZ Chat - Radio Extension Bridge

    A stable, server-side extension point for other mods that want to react
    to validated radio transmissions (Discord relays, external logging,
    faction/frequency tooling, etc.) without re-implementing TAZC's own
    radio validation, proximity discovery, or packet-loss simulation.

    WHY THIS EXISTS: a prior attempt at this integration (a separate radio
    framework mod) hooked the vanilla `processSayMessage` global directly.
    That hook never fires under TAZC -- TAZC_Input intercepts chat at the
    ISChat command-entry level and sends straight to the server via its own
    network command, so vanilla's send pipeline (and anything hooked onto
    it) is bypassed entirely for every channel TAZC handles. This module
    replaces that approach: an extension mod should listen HERE, on TAZC's
    own authoritative, server-validated dispatch point, instead of hooking
    a vanilla function TAZC never calls.

    USAGE (from another mod's server-side Lua):

        local TAZC_Bridge = require("TAZC_Bridge")
        TAZC_Bridge.Transmissions.addListener("MyMod", function(transmission)
            -- transmission.frequency, .message, .username, .channel, ...
        end)

    Each registered callback is pcall-protected: a broken listener cannot
    break TAZC's own radio routing or take down another listener.

    Modeled on Spears' Radio Framework's Transmissions listener API
    (SRB.Transmissions), by agreement with its author, so an integration
    written against that shape ports here with minimal changes.

    Author: 5tac3 (Terror AustraliZ)
    Based on MongooseChat by Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local dbg = TAZC_Core.debugger("BRIDGE")

TAZC_Bridge = TAZC_Bridge or {}

-- Print a `[TAZC-BRIDGE]|freq|username|message` stdout line alongside every
-- dispatched transmission, for external tooling that tails the server
-- console/log rather than loading a Lua listener (e.g. a sidecar process).
-- Purely additive to the listener API below; safe to disable if unwanted.
TAZC_Bridge.STDOUT_BRIDGE_ENABLED = true

TAZC_Bridge.Transmissions = TAZC_Bridge.Transmissions or {}
local Transmissions = TAZC_Bridge.Transmissions

-- Survive Lua reloads so integrations don't lose registration mid-session.
Transmissions._listeners = Transmissions._listeners or {}

local function cleanListenerId(listenerId)
    if listenerId == nil then return "" end
    return tostring(listenerId):gsub("^%s+", ""):gsub("%s+$", "")
end

local function cleanField(value)
    -- Strip control chars and the bridge line's own field separator so a
    -- corrupted/hostile message can't forge extra fields on the stdout line.
    local text = tostring(value or ""):gsub("[%c]", " ")
    text = text:gsub("|", "/")
    return text
end

local function listenerCount()
    local count = 0
    for _ in pairs(Transmissions._listeners) do count = count + 1 end
    return count
end

--[[
    Registers or replaces a transmission listener.

    @param listenerId  stable, unique string owned by the integrating mod
                        (e.g. its own mod id -- "SpearsRadioBridge")
    @param callback     function(transmission) -- see dispatch() below for shape
    @return ok (boolean), reason (string)
]]
function Transmissions.addListener(listenerId, callback)
    local id = cleanListenerId(listenerId)
    if id == "" then return false, "invalid_listener_id" end
    if type(callback) ~= "function" then return false, "invalid_callback" end

    local replaced = Transmissions._listeners[id] ~= nil
    Transmissions._listeners[id] = callback

    dbg("%s listener id=%s total=%d", replaced and "REPLACED" or "REGISTERED", id, listenerCount())
    return true, replaced and "replaced" or "registered"
end

function Transmissions.removeListener(listenerId)
    local id = cleanListenerId(listenerId)
    if id == "" then return false, "invalid_listener_id" end
    if Transmissions._listeners[id] == nil then return false, "listener_not_found" end

    Transmissions._listeners[id] = nil
    dbg("REMOVED listener id=%s total=%d", id, listenerCount())
    return true, "removed"
end

function Transmissions.getListenerCount()
    return listenerCount()
end

--[[
    Dispatches one validated transmission to every registered listener, and
    (if enabled) prints the stdout bridge line. Called by TAZC_Server once
    per active frequency, alongside its own Discord-relay log write -- see
    routeRadio in TAZC_Server.lua.

    transmission shape:
        frequency     number, e.g. 100000 (== 100.0 MHz)
        frequencyMHz  number, e.g. 100.0
        message       string -- the SAME text TAZC's own relay log uses:
                      packet-loss-degraded, and for a non-English speaker,
                      already scrubbed to babble/static rather than raw
                      plaintext. This mirrors TAZC's existing rule that
                      foreign-language speech must never leave the server
                      as readable English over any external-facing surface
                      -- listeners here get no more than the relay log does.
        username      string, speaker's account username
        characterName string, speaker's in-fiction character name
        channel       string, "say" | "yell" | "low" | "whisper"
        sourceX/Y/Z   number, speaker position at time of transmission
        timestamp     number, os.time()

    Each callback is individually pcall-guarded -- one broken listener
    can't stop another listener or the transmission's own routing.

    @return invoked (number), failed (number)
]]
function Transmissions.dispatch(transmission)
    if type(transmission) ~= "table" then return 0, 0 end

    -- Snapshot so a callback can add/remove listeners mid-dispatch without
    -- corrupting this iteration.
    local listeners = {}
    for id, callback in pairs(Transmissions._listeners) do
        table.insert(listeners, { id = id, callback = callback })
    end
    table.sort(listeners, function(a, b) return a.id < b.id end)

    local invoked, failed = 0, 0
    for _, listener in ipairs(listeners) do
        invoked = invoked + 1
        local ok, err = pcall(listener.callback, transmission)
        if not ok then
            failed = failed + 1
            print(string.format(
                "[TAZC-BRIDGE] LISTENER_ERROR id=%s error=%s",
                cleanField(listener.id), cleanField(err or "unknown_error")))
        end
    end

    if TAZC_Bridge.STDOUT_BRIDGE_ENABLED then
        print(string.format(
            "[TAZC-BRIDGE]|%d|%s|%s",
            tonumber(transmission.frequency) or 0,
            cleanField(transmission.username),
            cleanField(transmission.message)))
    end

    dbg("DISPATCH frequency=%s listeners=%d failed=%d",
        tostring(transmission.frequency), invoked, failed)

    return invoked, failed
end

return TAZC_Bridge
