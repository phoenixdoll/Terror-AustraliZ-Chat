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
local TAZC_Config = require("TAZC_Config")
local TAZC_Radio = require("TAZC_Radio")
local TAZC_Json = require("TAZC_Json")
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

-- ============================================================================
-- DISCORD RADIO BRIDGE
--
-- Folded directly into this file (rather than kept as a separate
-- TAZC_DiscordBridge.lua) after discovering that brand-new files added to
-- this mod were not being picked up by the server's Workshop-update
-- pipeline, while edits to already-known files like this one were. Rather
-- than chase that root cause, the Discord bridge lives inside a file
-- already proven to load reliably.
--
-- File-based bridge between ONE radio frequency (BRIDGE_FREQUENCY below)
-- and an external Discord bot. The bot is a separate, non-Lua process --
-- PZ server Lua cannot open outbound sockets or accept inbound
-- connections, so this module and the bot talk through two plain files
-- instead of any direct call. The bot reaches these files however it's
-- configured to (SFTP, a mounted volume, etc.); this module never talks
-- to Discord's API itself and doesn't need to know how the bot gets to
-- the files.
--
-- Both files live under Zomboid/Lua/TAZC/discordbridge/ on the server,
-- created automatically the first time either side writes to them.
--
-- DIRECTION 1 -- game to Discord (outbound):
-- Registers as a Transmissions listener (above), filters for
-- BRIDGE_FREQUENCY only, and appends one line per transmission to
-- OUTBOX_FILE. transmission.message arrives already packet-loss-degraded
-- -- exactly what an in-game listener on that frequency hears.
--
-- Line format: "<unix-seconds>|<displayName>|<discordMessageId-or-empty>|<message>"
-- discordMessageId is empty for a real in-game transmission; the bot only
-- uses it to delete a Discord message once it's found (see DIRECTION 2).
--
-- DIRECTION 2 -- Discord to game (inbound):
-- A throttled OnTick poll (not every tick -- see POLL_INTERVAL_MS) reads
-- INBOX_FILE for new lines, then clears it. Each line is one Discord
-- message: rejected if it exceeds TAZC_Config.MaxMessageLength, otherwise
-- run through the SAME TAZC_Radio.addPacketLoss corruption every other
-- radio transmission gets, and broadcast to every online player with a
-- working, receiving radio tuned to BRIDGE_FREQUENCY. The echo written
-- back to the outbox (DIRECTION 1's file) carries the original Discord
-- message's id back through unchanged, purely so the bot can delete that
-- original message once it posts the in-character corrupted version --
-- this module never talks to Discord's API and doesn't know what "delete"
-- means, it just round-trips an opaque id string.
--
-- Line format (written by the bot): "<displayName>|<discordMessageId>|<message>"
--
-- SCOPE: inbound broadcast reaches hand/belt/inventory radios
-- (TAZC_Radio.getAllPlayerRadios) and ground/base-station radios within
-- GROUND_RADIO_RANGE of the bridge's assigned origin point (SOURCE_X/Y/Z
-- -- a Discord message has no real in-world position, so it's treated as
-- a physical installation sitting at that fixed point). Vehicle radios
-- are not reached yet.
-- ============================================================================

local dbgDiscord = TAZC_Core.debugger("DISCORDBRIDGE")

local TAZC_DiscordBridge = {}

TAZC_DiscordBridge.BRIDGE_FREQUENCY = 100000

TAZC_DiscordBridge.OUTBOX_FILE = "TAZC/discordbridge/outbox.txt"
TAZC_DiscordBridge.INBOX_FILE  = "TAZC/discordbridge/inbox.txt"

-- Inbox polling cadence in ms. Not every tick -- a file read/write on every
-- one of ~60 ticks/sec would be wasteful for a channel that only needs to
-- feel responsive, not instant.
TAZC_DiscordBridge.POLL_INTERVAL_MS = 3000

-- Display name for EVERY Discord-origin line, in-game. Deliberately the
-- same string as TAZC_Anonymity.Config.radioName (the client-side
-- unresolvable-speaker fallback) -- a Discord message has no character
-- behind it at all, which is the same "nothing to identify" case that
-- fallback exists for. This copy is server-authoritative and independent
-- of that client-side module.
TAZC_DiscordBridge.DISCORD_VOICE_NAME = "A Voice on the Radio"

-- A Discord-origin message has no real in-world position. Treated as if
-- the bridge were a physical radio installation sitting at world origin --
-- lets a ground-placed radio near (0,0,0) pick it up too, same as any
-- other ground radio, rather than only ever reaching carried radios.
TAZC_DiscordBridge.SOURCE_X = 0
TAZC_DiscordBridge.SOURCE_Y = 0
TAZC_DiscordBridge.SOURCE_Z = 0
TAZC_DiscordBridge.GROUND_RADIO_RANGE = 120

local lastPollMs = 0

-- Nil-writer case checked before safeExec's pcall, not raised via error():
-- PZ's Kahlua VM dumps a full stack trace to the DebugLog for every error()
-- call even when pcall catches it, so this expected/recoverable failure
-- shouldn't be routed through it (see TAZC_Persist.lua's writeAll).
local function appendOutbox(line)
    local writer = getFileWriter(TAZC_DiscordBridge.OUTBOX_FILE, true, true)
    if not writer then
        print("[TAZC-DISCORDBRIDGE] WARNING: outbox write failed: getFileWriter returned nil")
        return
    end
    local ok, err = TAZC_Core.safeExec(function()
        writer:writeln(line)
        writer:close()
    end)
    if not ok then
        print(string.format(
            "[TAZC-DISCORDBRIDGE] WARNING: outbox write failed: %s", tostring(err)))
    end
end

-- ============================================================================
-- DIRECTION 1: GAME -> DISCORD (outbound)
-- ============================================================================

local function onDiscordTransmission(transmission)
    if type(transmission) ~= "table" then return end
    if transmission.frequency ~= TAZC_DiscordBridge.BRIDGE_FREQUENCY then return end

    local nowSeconds = math.floor(TAZC_Core.getTimeMs() / 1000)
    -- Empty discordMessageId field -- a real in-game transmission has no
    -- Discord message behind it for the bot to delete.
    local line = string.format("%d|%s||%s",
        nowSeconds,
        cleanField(transmission.characterName or transmission.username),
        cleanField(transmission.message))

    appendOutbox(line)
    dbgDiscord("onDiscordTransmission: relayed to outbox (%d bytes)", #line)
end

Transmissions.addListener("DiscordBridge", onDiscordTransmission)

-- ============================================================================
-- DIRECTION 2: DISCORD -> GAME (inbound)
-- ============================================================================

-- Read every line currently in the inbox, then truncate it. Truncating
-- after a successful read (not before) means a crash between read and
-- clear can at worst replay a line, never silently drop one.
local function drainInbox()
    local lines = {}
    local readOk = TAZC_Core.safeExec(function()
        local reader = getFileReader(TAZC_DiscordBridge.INBOX_FILE, false)
        if not reader then return end
        local l = reader:readLine()
        while l ~= nil do
            if l ~= "" then table.insert(lines, l) end
            l = reader:readLine()
        end
        reader:close()
    end)
    if not readOk or #lines == 0 then return readOk and lines or {} end

    -- Nil-writer case checked before safeExec's pcall, not raised via
    -- error() -- see appendOutbox above for why.
    local inboxWriter = getFileWriter(TAZC_DiscordBridge.INBOX_FILE, true, false)
    if not inboxWriter then
        print("[TAZC-DISCORDBRIDGE] WARNING: inbox clear failed, message(s) may replay: " ..
            "getFileWriter returned nil")
        return lines
    end
    local clearOk, clearErr = TAZC_Core.safeExec(function()
        inboxWriter:close()
    end)
    if not clearOk then
        print(string.format(
            "[TAZC-DISCORDBRIDGE] WARNING: inbox clear failed, message(s) may replay: %s",
            tostring(clearErr)))
    end
    return lines
end

-- "displayName|discordMessageId|message" -- the bot supplies its own
-- displayName (typically the Discord username) so operators can tell
-- speakers apart in dbg output even though every one of them renders
-- in-game as DISCORD_VOICE_NAME. discordMessageId is opaque here -- only
-- round-tripped back to the bot via the outbox echo (see
-- processInboxLine) so it can delete the original Discord message.
local function parseInboxLine(line)
    local displayName, messageId, message = line:match("^([^|]*)|([^|]*)|(.*)$")
    if not message then return nil, nil, nil end
    return displayName, messageId, message
end

-- Send one already-corrupted line to every online player with a working,
-- receiving radio on BRIDGE_FREQUENCY -- both carried (hand/belt/inventory)
-- radios, and now also ground/base-station radios within
-- GROUND_RADIO_RANGE of the bridge's assigned origin point (see the
-- SOURCE_X/Y/Z comment above). A player only ever gets one delivery even
-- if reachable both ways.
local function broadcastToFrequency(degradedMessage)
    local sentCount = 0
    local delivered = {}
    local playersOk, onlinePlayers = pcall(function() return getOnlinePlayers() end)
    if not playersOk or not onlinePlayers then
        print("[TAZC-DISCORDBRIDGE] WARNING: getOnlinePlayers unavailable, broadcast dropped")
        return 0
    end

    local function deliverTo(targetPlayer, radio)
        if delivered[targetPlayer] then return end
        delivered[targetPlayer] = true
        sendServerCommand(targetPlayer, "TAZC", "RadioMessage", {
            senderUsername = "discord",
            senderCharacter = TAZC_DiscordBridge.DISCORD_VOICE_NAME,
            message = degradedMessage,
            chunks = nil,
            language = nil,
            channel = "say",
            frequency = TAZC_DiscordBridge.BRIDGE_FREQUENCY,
            receiverType = radio.source,
            receiverOwnerId = radio.ownerId,
            receiverPosition = radio.position,
            isPrivate = radio.isPrivate,
            volume = radio.volume
        })
        sentCount = sentCount + 1
    end

    -- Carried radios (hand/belt/inventory).
    for i = 0, onlinePlayers:size() - 1 do
        local targetPlayer = onlinePlayers:get(i)
        local radios = TAZC_Radio.getAllPlayerRadios(targetPlayer)
        for _, radio in ipairs(radios) do
            if radio.frequency == TAZC_DiscordBridge.BRIDGE_FREQUENCY
               and TAZC_Radio.canReceive(radio) then
                deliverTo(targetPlayer, radio)
                break  -- one carried radio's worth is enough for this player
            end
        end
    end

    -- Ground/base-station radios near the bridge's assigned origin point.
    -- Reachable players are computed the same way TAZC_Server.routeRadio
    -- scales ground-radio hearing range: whisper-range floor, yell-range
    -- (capped) scaled by the radio's own volume.
    local groundRadios = TAZC_Radio.getGroundRadios(
        TAZC_DiscordBridge.SOURCE_X, TAZC_DiscordBridge.SOURCE_Y,
        TAZC_DiscordBridge.SOURCE_Z, TAZC_DiscordBridge.GROUND_RADIO_RANGE)
    for _, radio in ipairs(groundRadios) do
        if radio.frequency == TAZC_DiscordBridge.BRIDGE_FREQUENCY
           and TAZC_Radio.canReceive(radio) and radio.position then
            local vol = radio.volume or 1.0
            local hearingRange = math.max(TAZC_Config.Ranges.whisper,
                math.min(TAZC_Config.Ranges.yell, 30) * vol)
            for i = 0, onlinePlayers:size() - 1 do
                local targetPlayer = onlinePlayers:get(i)
                if not delivered[targetPlayer] then
                    local okPos, px, py = pcall(function()
                        return targetPlayer:getX(), targetPlayer:getY()
                    end)
                    if okPos then
                        local dist = TAZC_Core.distance2D(
                            px, py, radio.position.x, radio.position.y)
                        if dist <= hearingRange then
                            deliverTo(targetPlayer, radio)
                        end
                    end
                end
            end
        end
    end

    return sentCount
end

local function processInboxLine(line)
    local displayName, discordMessageId, message = parseInboxLine(line)
    if not message or message == "" then
        print("[TAZC-DISCORDBRIDGE] WARNING: malformed inbox line discarded")
        return
    end

    local maxLen = TAZC_Config.MaxMessageLength or 500
    if #message > maxLen then
        print(string.format(
            "[TAZC-DISCORDBRIDGE] WARNING: inbox message from %s exceeds MaxMessageLength (%d > %d), discarded",
            tostring(displayName), #message, maxLen))
        return
    end

    -- Same corruption every real radio transmission gets. weatherMultiplier
    -- fixed at 1.0 (clear weather) -- a Discord-origin voice has no
    -- in-world position for the server's current weather roll to apply to.
    local degraded = TAZC_Radio.addPacketLoss(message, 1.0)

    local sentCount = broadcastToFrequency(degraded)
    dbgDiscord("processInboxLine: %s -> %d receivers", tostring(displayName), sentCount)

    -- Echo the corrupted text back to the outbox so the bot can post the
    -- same "A Voice on the Radio (displayName): <degraded>" confirmation
    -- into Discord that in-game listeners just heard, and delete the
    -- original plain-text Discord message (discordMessageId round-tripped
    -- unchanged from the inbox line -- see parseInboxLine).
    appendOutbox(string.format("%d|%s|%s|%s",
        math.floor(TAZC_Core.getTimeMs() / 1000),
        TAZC_DiscordBridge.DISCORD_VOICE_NAME .. " (" .. tostring(displayName) .. ")",
        cleanField(discordMessageId),
        degraded))
end

local function pollInbox()
    local lines = drainInbox()
    for _, line in ipairs(lines) do
        processInboxLine(line)
    end
end

local function onDiscordBridgeTick()
    local now = TAZC_Core.getTimeMs()
    if now - lastPollMs < TAZC_DiscordBridge.POLL_INTERVAL_MS then return end
    lastPollMs = now
    pollInbox()
end

Events.OnTick.Add(onDiscordBridgeTick)

print("[TAZC-BRIDGE] Discord bridge active (folded into TAZC_Bridge.lua): "
    .. string.format("frequency=%d outbox=%s inbox=%s poll=%dms",
        TAZC_DiscordBridge.BRIDGE_FREQUENCY, TAZC_DiscordBridge.OUTBOX_FILE,
        TAZC_DiscordBridge.INBOX_FILE, TAZC_DiscordBridge.POLL_INTERVAL_MS))

-- ============================================================================
-- SERVER STATUS EXPORT
--
-- RCON has no query commands for in-game date/time or weather (checked
-- directly against the game's own command strings) -- so, for the same
-- reason the Discord radio bridge above talks through plain files instead
-- of a direct call, the server periodically overwrites a snapshot file that
-- an external bot (WhitelistManager's /time and /weather) reaches over
-- SFTP. This is a truncating overwrite, not an append log like
-- outbox.txt/inbox.txt above -- only the latest snapshot ever matters.
-- ============================================================================

local TAZC_Status = {}
TAZC_Bridge.Status = TAZC_Status

TAZC_Status.FILE = "TAZC/discordbridge/status.json"

-- Real seconds, not in-game time, so this stays fresh regardless of the
-- server's time multiplier.
TAZC_Status.WRITE_INTERVAL_MS = 60000

local dbgStatus = TAZC_Core.debugger("STATUS")

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

-- Nil-writer case checked before safeExec's pcall, not raised via error()
-- -- see appendOutbox above for why.
--
-- getFileWriter(path, true, false) (create-if-missing, truncate) reliably
-- returns nil when `path` doesn't exist yet at all -- confirmed live on the
-- real server (2026-08-07 reset): TAZC_Persist's identical truncate-mode
-- call was failing the exact same way for TAZC_Notes_a/b.json, files that
-- had written fine for months before that reset wiped them back to
-- nonexistent. getFileWriter(path, true, true) (append) does NOT have this
-- problem -- appendOutbox's outbox.txt was recreated successfully the same
-- session. So: if the truncating open fails, "seed" the file into
-- existence with one append-mode open/close first (writes nothing), then
-- retry the truncating open once against a now-existing file -- the same
-- state every prior successful write on this server was already in.
local function writeStatusFile(jsonText)
    local writer = getFileWriter(TAZC_Status.FILE, true, false)
    if not writer then
        local seedWriter = getFileWriter(TAZC_Status.FILE, true, true)
        if seedWriter then
            seedWriter:close()
            writer = getFileWriter(TAZC_Status.FILE, true, false)
        end
    end
    if not writer then
        print("[TAZC-STATUS] WARNING: status write failed: getFileWriter returned nil (even after seeding via append mode)")
        return
    end
    local ok, err = TAZC_Core.safeExec(function()
        writer:write(jsonText)
        writer:close()
    end)
    if not ok then
        print(string.format("[TAZC-STATUS] WARNING: status write failed: %s", tostring(err)))
    end
end

-- Pulls one forecast object (from getClimateForecaster():getForecast(n))
-- into a plain table. Wrapped in the caller's pcall -- a forecaster that
-- isn't ready yet (e.g. very early in server boot) is treated as "no
-- forecast available this cycle", not a hard error.
local function forecastToTable(forecast)
    return {
        tempMean = forecast:getTemperature():getTotalMean(),
        tempMin = forecast:getTemperature():getTotalMin(),
        tempMax = forecast:getTemperature():getTotalMax(),
        windMean = forecast:getWindPower():getTotalMean(),
        cloudMean = forecast:getCloudiness():getTotalMean(),
        humidityMean = forecast:getHumidity():getTotalMean(),
        hasFog = forecast:isHasFog() and true or false,
        hasHeavyRain = forecast:isHasHeavyRain() and true or false,
        hasStorm = forecast:isHasStorm() and true or false,
        hasTropicalStorm = forecast:isHasTropicalStorm() and true or false,
        hasBlizzard = forecast:isHasBlizzard() and true or false,
        chanceOnSnow = forecast:isChanceOnSnow() and true or false,
        weatherStartTime = forecast:getWeatherStartTime(),
        weatherEndTime = forecast:getWeatherEndTime(),
        weatherStarts = forecast:isWeatherStarts() and true or false,
    }
end

local function buildStatusPayload()
    local gameTime = getGameTime()
    local clim = getClimateManager()

    -- getTimeOfDay() returns the fraction of the current day elapsed
    -- (0..1) -- the same source SFarmingSystem.lua/season.lua use to derive
    -- the current hour server-side. There's no direct getMinute() on
    -- GameTime, so minutes are derived from the same fraction.
    local totalMinutes = math.floor((gameTime:getTimeOfDay() or 0) * 24 * 60)

    local payload = {
        writtenAt = os.time(),
        day = gameTime:getDay(),
        -- getMonth() is 0-indexed (confirmed by vanilla season.lua indexing
        -- a 12-entry table with getMonth()+1).
        month = MONTH_NAMES[(gameTime:getMonth() or 0) + 1] or "?",
        hour = math.floor(totalMinutes / 60) % 24,
        minute = totalMinutes % 60,
        nightsSurvived = gameTime:getNightsSurvived(),
        season = clim:getSeasonName(),
        current = {
            rain = clim:getPrecipitationIntensity(),
            snow = clim:getSnowStrength(),
            fog = clim:getFogIntensity(),
            wind = clim:getWindPower(),
            thunderstorm = clim:getThunderStorm() and true or false,
        },
    }

    local okForecast, forecast = pcall(function()
        return clim:getClimateForecaster():getForecast(1)
    end)
    if okForecast and forecast then
        local okTable, forecastTable = pcall(forecastToTable, forecast)
        if okTable then
            payload.forecastTomorrow = forecastTable
        else
            dbgStatus("buildStatusPayload: forecastToTable failed: %s", tostring(forecastTable))
        end
    end

    return payload
end

local lastStatusWriteMs = 0

local function onStatusTick()
    local now = TAZC_Core.getTimeMs()
    if now - lastStatusWriteMs < TAZC_Status.WRITE_INTERVAL_MS then return end
    lastStatusWriteMs = now

    local ok, result = pcall(function()
        local payload = buildStatusPayload()
        local encoded = TAZC_Json.encode(payload)
        if not encoded then error("TAZC_Json.encode returned nil") end
        writeStatusFile(encoded)
        return encoded
    end)
    if not ok then
        print(string.format("[TAZC-STATUS] WARNING: status export failed: %s", tostring(result)))
    else
        dbgStatus("onStatusTick: wrote %d bytes to %s", #result, TAZC_Status.FILE)
    end
end

Events.OnTick.Add(onStatusTick)

print("[TAZC-BRIDGE] Server status export active: file=" .. TAZC_Status.FILE
    .. " interval=" .. tostring(TAZC_Status.WRITE_INTERVAL_MS) .. "ms")

return TAZC_Bridge
