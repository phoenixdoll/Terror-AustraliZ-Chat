--[[
================================================================================
    Terror AustraliZ Chat - Discord Radio Bridge

    File-based bridge between ONE radio frequency (BRIDGE_FREQUENCY below)
    and an external Discord bot. The bot is a separate, non-Lua process --
    PZ server Lua cannot open outbound sockets or accept inbound
    connections, so this module and the bot talk through two plain files
    instead of any direct call. The bot reaches these files however it's
    configured to (SFTP, a mounted volume, etc.); this module never talks
    to Discord's API itself and doesn't need to know how the bot gets to
    the files.

    Both files live under Zomboid/Lua/TAZC/discordbridge/ on the server,
    created automatically the first time either side writes to them.

    DIRECTION 1 -- game to Discord (outbound):
    Registers as a TAZC_Bridge.Transmissions listener (the same extension
    point built for Spears' Radio Framework -- see TAZC_Bridge.lua),
    filters for BRIDGE_FREQUENCY only, and appends one line per
    transmission to OUTBOX_FILE. transmission.message arrives from
    TAZC_Bridge already packet-loss-degraded -- exactly what an in-game
    listener on that frequency hears, nothing extra to do here.

    Line format: "<unix-seconds>|<displayName>|<message>"

    DIRECTION 2 -- Discord to game (inbound):
    A throttled OnTick poll (not every tick -- see POLL_INTERVAL_MS) reads
    INBOX_FILE for new lines, then clears it. Each line is one Discord
    message: rejected if it exceeds TAZC_Config.MaxMessageLength, otherwise
    run through the SAME TAZC_Radio.addPacketLoss corruption every other
    radio transmission gets, and broadcast to every online player with a
    working, receiving radio tuned to BRIDGE_FREQUENCY.

    Line format (written by the bot): "<displayName>|<message>"

    SCOPE: inbound broadcast reaches hand/belt/inventory radios
    (TAZC_Radio.getAllPlayerRadios) and ground/base-station radios within
    GROUND_RADIO_RANGE of the bridge's assigned origin point (SOURCE_X/Y/Z
    -- a Discord message has no real in-world position, so it's treated as
    a physical installation sitting at that fixed point). Vehicle radios
    are not reached yet.

    Author: 5tac3 (Terror AustraliZ)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Radio = require("TAZC_Radio")
local TAZC_Bridge = require("TAZC_Bridge")

local dbg = TAZC_Core.debugger("DISCORDBRIDGE")

-- Unconditional (not gated by TAZC_Core.DEBUG, off by default) load-time
-- marker for the silent-no-write investigation: proves this file's
-- top-level code executed at all, independent of any radio event ever
-- happening. Remove once resolved.
print("[TAZC-DISCORDBRIDGE] module loading (top-level code executing)")

local TAZC_DiscordBridge = {}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- 100.0 MHz, same integer-Hz-scaled convention as the rest of TAZC_Radio
-- (98600 = 98.6 MHz).
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

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================

-- Strip control chars and escape the field-separator pipe so a corrupted or
-- hostile field can't forge extra columns for the bot's line parser.
local function cleanField(value)
    local text = tostring(value or ""):gsub("[%c]", " ")
    return text:gsub("|", "/")
end

local function appendOutbox(line)
    local ok, err = TAZC_Core.safeExec(function()
        local writer = getFileWriter(TAZC_DiscordBridge.OUTBOX_FILE, true, true)
        if not writer then error("getFileWriter returned nil") end
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

local function onTransmission(transmission)
    -- Unconditional (not gated by TAZC_Core.DEBUG, which defaults off) --
    -- diagnostic for the silent-no-write investigation. Remove once resolved.
    print(string.format(
        "[TAZC-DISCORDBRIDGE] onTransmission: type=%s frequency=%s (type=%s) configured=%s (type=%s) match=%s",
        type(transmission),
        tostring(transmission and transmission.frequency),
        type(transmission and transmission.frequency),
        tostring(TAZC_DiscordBridge.BRIDGE_FREQUENCY),
        type(TAZC_DiscordBridge.BRIDGE_FREQUENCY),
        tostring(transmission and transmission.frequency == TAZC_DiscordBridge.BRIDGE_FREQUENCY)))

    if type(transmission) ~= "table" then return end
    if transmission.frequency ~= TAZC_DiscordBridge.BRIDGE_FREQUENCY then return end

    print("[TAZC-DISCORDBRIDGE] onTransmission: frequency matched, writing to outbox")

    local nowSeconds = math.floor(TAZC_Core.getTimeMs() / 1000)
    local line = string.format("%d|%s|%s",
        nowSeconds,
        cleanField(transmission.characterName or transmission.username),
        cleanField(transmission.message))

    appendOutbox(line)
    print(string.format("[TAZC-DISCORDBRIDGE] onTransmission: appendOutbox call completed for line (%d bytes)", #line))
end

TAZC_Bridge.Transmissions.addListener("DiscordBridge", onTransmission)

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

    local clearOk, clearErr = TAZC_Core.safeExec(function()
        local writer = getFileWriter(TAZC_DiscordBridge.INBOX_FILE, true, false)
        if not writer then error("getFileWriter returned nil") end
        writer:close()
    end)
    if not clearOk then
        print(string.format(
            "[TAZC-DISCORDBRIDGE] WARNING: inbox clear failed, message(s) may replay: %s",
            tostring(clearErr)))
    end
    return lines
end

-- "displayName|message" -- the bot supplies its own displayName (typically
-- the Discord username) so operators can tell speakers apart in dbg output
-- even though every one of them renders in-game as DISCORD_VOICE_NAME.
local function parseInboxLine(line)
    local displayName, message = line:match("^([^|]*)|(.*)$")
    if not message then return nil, nil end
    return displayName, message
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
    local displayName, message = parseInboxLine(line)
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
    dbg("processInboxLine: %s -> %d receivers", tostring(displayName), sentCount)

    -- Echo the corrupted text back to the outbox so the bot can post the
    -- same "A Voice on the Radio (displayName): <degraded>" confirmation
    -- into Discord that in-game listeners just heard.
    appendOutbox(string.format("%d|%s|%s",
        math.floor(TAZC_Core.getTimeMs() / 1000),
        TAZC_DiscordBridge.DISCORD_VOICE_NAME .. " (" .. tostring(displayName) .. ")",
        degraded))
end

local function pollInbox()
    local lines = drainInbox()
    for _, line in ipairs(lines) do
        processInboxLine(line)
    end
end

local function onTick()
    local now = TAZC_Core.getTimeMs()
    if now - lastPollMs < TAZC_DiscordBridge.POLL_INTERVAL_MS then return end
    lastPollMs = now
    pollInbox()
end

Events.OnTick.Add(onTick)

dbg("Discord bridge active: frequency=%d outbox=%s inbox=%s poll=%dms",
    TAZC_DiscordBridge.BRIDGE_FREQUENCY, TAZC_DiscordBridge.OUTBOX_FILE,
    TAZC_DiscordBridge.INBOX_FILE, TAZC_DiscordBridge.POLL_INTERVAL_MS)

return TAZC_DiscordBridge
