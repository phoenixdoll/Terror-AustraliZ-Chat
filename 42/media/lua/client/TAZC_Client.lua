--[[
================================================================================
    Terror AustraliZ Chat - Client Main
    
    The client-side coordinator for Terror AustraliZ Chat. Receives messages from server,
    manages UI elements (bubbles, typing indicators, chat panel), and integrates
    with the vanilla ISChat system.
    
    RESPONSIBILITIES:
    - Server command handling (ChatMessage, RadioMessage, Typing)
    - Bubble lifecycle management
    - Typing indicator management
    - Chat panel creation and vanilla view suppression
    - Q-shout interception
    - Boredom reduction for RP activity
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_ChatPanel = require("TAZC_ChatPanel")
local TAZC_Bubble = require("TAZC_Bubble")
local TAZC_Input = require("TAZC_Input")
local TAZC_Typing = require("TAZC_Typing")
local TAZC_Anonymity = require("TAZC_Anonymity")
local TAZC_Bio = require("TAZC_Bio")
local TAZC_BabbleHint = require("TAZC_BabbleHint")
local TAZC_LangRegistry = require("TAZC_LangRegistry")
local TAZC_SignGesture = require("TAZC_SignGesture")

local dbg = TAZC_Core.debugger("CLIENT")

-- Helper: Get local player's UI manager index (0 for single player)
local function getPlayerUIIndex()
    local player = getPlayer()
    if player and player.getPlayerNum then
        return player:getPlayerNum() or 0
    end
    return 0
end

local TAZC_Client = {}

-- ============================================================================
-- STATE
-- ============================================================================

-- Active bubbles (keyed by player online ID)
local activeBubbles = {}

-- Active radio bubbles (keyed by "radio_<type>_<position>")
local activeRadioBubbles = {}

-- Active typing indicators (keyed by username)
local activeTyping = {}

-- Chat panel instance
local chatPanel = nil

-- Signing-gesture cooldown tracker (v1). Pure decision logic lives in
-- TAZC_SignGesture.lua; this is its one glue-side instance for the whole
-- client session (see onChatMessage below).
local signGesture = TAZC_SignGesture.new()

-- Flags
local panelCreated = false
local vanillaChatHooked = false
local worldMessageHooked = false
local lastLoggedTab = nil

-- Vanilla tab ID -> our tab ID mapping (memoized on first call).
local vanillaTabMapCache = nil

-- M4/M6: username -> the most-recently-seen modality for that speaker,
-- from a real TAZC_Server-routed delivery (onChatMessage below). Two
-- fallback paths never touch TAZC_Server's language pipeline at all and so
-- have no modality of their own to stamp: Q-shout's floating-callout hook
-- (hookWorldMessage, vanilla's own canned text) and routeVanillaChatLine
-- (a vanilla-parsed chat line reaching MC outside its normal pipeline).
-- This is the closest honest signal either can reach for "is this speaker
-- currently signing" without a server round-trip -- last KNOWN, not a live
-- read; self-corrects on the speaker's next real utterance either way.
local lastKnownModality = {}

-- NOT runtime detection, despite the name this replaced (detectVanillaTabs):
-- B42 chat internals are extremely fragile and detection crashes on some
-- clients, so this is a hardcoded fallback, lazily memoized.
-- Vanilla has 2 tabs: General(1), Admin(2)
-- MC has 2 internal tabs: General(1), Admin(2)
local function vanillaTabMap()
    if vanillaTabMapCache then return vanillaTabMapCache end

    vanillaTabMapCache = {
        [1] = 1,  -- Vanilla General -> our General tab
        [2] = 2,  -- Vanilla Admin -> our Admin tab (passthrough)
    }
    dbg("vanillaTabMap: using 1:1 mapping")

    return vanillaTabMapCache
end

-- ============================================================================
-- PLAYER LOOKUP
-- ============================================================================

local function getPlayerByOnlineId(onlineId)
    local players = getOnlinePlayers()
    if not players then return nil end
    
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p:getOnlineID() == onlineId then
            return p
        end
    end
    return nil
end

local function getPlayerByUsername(username)
    local players = getOnlinePlayers()
    if not players then 
        dbg("getPlayerByUsername: getOnlinePlayers() nil")
        return nil 
    end
    
    dbg("getPlayerByUsername: searching %d players for '%s'", players:size(), tostring(username))
    
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p:getUsername() == username then
            dbg("getPlayerByUsername: FOUND at index %d", i)
            return p
        end
    end
    
    dbg("getPlayerByUsername: NOT FOUND")
    return nil
end

-- ============================================================================
-- LIVE SANDBOX VAR HELPERS
-- Read directly from SandboxVars for settings that need to work mid-game
-- ============================================================================

local function areBubblesEnabled()
    return TAZC_Config.liveSandbox("BubblesEnabled", true) ~= false
end

local function areTypingIndicatorsEnabled()
    return TAZC_Config.liveSandbox("TypingIndicatorsEnabled", true) ~= false
end

-- ============================================================================
-- BUBBLE MANAGEMENT
-- ============================================================================

local function showBubble(player, message, channel, hideAvatar, characterName, isAnonymous, modality)
    if not areBubblesEnabled() then return end
    if not player then
        dbg("showBubble: nil player")
        return
    end

    local id = player:getOnlineID()
    local username = player:getUsername()

    dbg("showBubble: player=%s id=%s msg=%s hideAvatar=%s isAnonymous=%s", username, tostring(id), tostring(message):sub(1, 30), tostring(hideAvatar), tostring(isAnonymous))
    
    -- Remove existing bubble
    if activeBubbles[id] then
        dbg("showBubble: removing existing")
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    -- Remove typing indicator
    if activeTyping[username] then
        dbg("showBubble: removing typing")
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    -- Create new bubble (pass hideAvatar flag and characterName for anonymous
    -- emote handling; isAnonymous gates the custom PNG portrait -- masked
    -- speakers keep the 3D-model fallback, which leaks nothing)
    local bubble = TAZC_Bubble:new(player, message, channel, hideAvatar, characterName, isAnonymous, modality)
    
    if not bubble then
        dbg("showBubble: TAZC_Bubble:new returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showBubble: created")
end

local function showEmoteBubble(player, characterName, action)
    if not areBubblesEnabled() then return end
    if not player then 
        dbg("showEmoteBubble: nil player")
        return 
    end
    
    local id = player:getOnlineID()
    local username = player:getUsername()
    
    dbg("showEmoteBubble: player=%s action=%s", username, tostring(action):sub(1, 30))
    
    if activeBubbles[id] then
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    if activeTyping[username] then
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    local bubble = TAZC_Bubble:newEmote(characterName, action, player)
    
    if not bubble then
        dbg("showEmoteBubble: TAZC_Bubble:newEmote returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showEmoteBubble: created")
end

local function showDoBubble(player, narration)
    if not areBubblesEnabled() then return end
    if not player then 
        dbg("showDoBubble: nil player")
        return 
    end
    
    local id = player:getOnlineID()
    local username = player:getUsername()
    
    dbg("showDoBubble: player=%s narration=%s", username, tostring(narration):sub(1, 30))
    
    if activeBubbles[id] then
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    if activeTyping[username] then
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    local bubble = TAZC_Bubble:newDo(narration, player)
    
    if not bubble then
        dbg("showDoBubble: TAZC_Bubble:newDo returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showDoBubble: created")
end

local function showRadioBubble(msgData)
    if not areBubblesEnabled() then return end
    dbg("showRadioBubble: receiverType=%s isPrivate=%s freq=%s",
        tostring(msgData.receiverType), tostring(msgData.isPrivate), tostring(msgData.frequency))
    
    local target = nil
    local bubbleKey = nil
    
    if msgData.receiverType == "player" then
        local ownerPlayer = getPlayerByUsername(msgData.receiverOwnerId)
        if ownerPlayer then
            target = ownerPlayer
            bubbleKey = "radio_player_" .. ownerPlayer:getOnlineID()
            dbg("showRadioBubble: player target: %s", msgData.receiverOwnerId)
        else
            dbg("showRadioBubble: player not found: %s", tostring(msgData.receiverOwnerId))
            if msgData.receiverPosition then
                target = msgData.receiverPosition
                bubbleKey = "radio_pos_" .. msgData.frequency
            else
                return
            end
        end
    elseif msgData.receiverType == "ground" or msgData.receiverType == "vehicle" then
        if msgData.receiverPosition then
            target = msgData.receiverPosition
            local posKey = math.floor(target.x) .. "_" .. math.floor(target.y)
            bubbleKey = "radio_" .. msgData.receiverType .. "_" .. posKey
            dbg("showRadioBubble: world target at %s", posKey)
        else
            dbg("showRadioBubble: no position")
            return
        end
    else
        dbg("showRadioBubble: unknown receiverType")
        return
    end
    
    if bubbleKey and activeRadioBubbles[bubbleKey] then
        dbg("showRadioBubble: removing existing: %s", bubbleKey)
        activeRadioBubbles[bubbleKey].dead = true
        activeRadioBubbles[bubbleKey]:removeFromUIManager()
        activeRadioBubbles[bubbleKey] = nil
    end
    
    local bubble = TAZC_Bubble:newRadio(
        msgData.message,
        msgData.channel,
        target,
        msgData.isPrivate,
        msgData.volume
    )
    
    if not bubble then
        dbg("showRadioBubble: TAZC_Bubble:newRadio returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    if bubbleKey then
        activeRadioBubbles[bubbleKey] = bubble
        dbg("showRadioBubble: created key=%s", bubbleKey)
    end
end

-- ============================================================================
-- TYPING INDICATOR
-- ============================================================================

local function showTyping(player)
    if not areTypingIndicatorsEnabled() then return end
    if not player then 
        dbg("showTyping: nil player")
        return 
    end
    
    local localPlayer = getPlayer()
    if not localPlayer then 
        dbg("showTyping: no local player")
        return 
    end
    
    local username = player:getUsername()
    
    if player:getOnlineID() == localPlayer:getOnlineID() then 
        dbg("showTyping: ignoring self")
        return 
    end
    
    if activeTyping[username] then
        dbg("showTyping: refreshing %s", username)
        activeTyping[username]:refresh()
    else
        dbg("showTyping: creating %s", username)
        local typing = TAZC_Typing:new(player, 3)
        typing:initialise()
        typing:addToUIManager(getPlayerUIIndex())
        typing:setVisible(true)
        activeTyping[username] = typing
    end
end

-- ============================================================================
-- UI CLEANUP
-- ============================================================================

local function cleanupUI()
    for id, bubble in pairs(activeBubbles) do
        if bubble.dead then
            bubble:removeFromUIManager()
            activeBubbles[id] = nil
        end
    end
    
    for key, bubble in pairs(activeRadioBubbles) do
        if bubble.dead then
            bubble:removeFromUIManager()
            activeRadioBubbles[key] = nil
        end
    end
    
    for username, typing in pairs(activeTyping) do
        if typing.dead then
            typing:removeFromUIManager()
            activeTyping[username] = nil
        end
    end
end

-- ============================================================================
-- BOREDOM REDUCTION
-- ============================================================================

-- Cooldown for boredom reduction requests. With default reductionAmount=100
-- (full cure per message), there's zero gameplay value in firing more than
-- once per window -- you're already at zero boredom. In a 10-person scene
-- without this throttle, one message generated N*(N-1) = 90 server commands.
local BOREDOM_COOLDOWN_MS = 30 * 1000
local lastBoredomRequestMs = 0

--[[
    B42 Boredom Reduction (Server-Authoritative)
    
    Client-side stat changes don't persist in B42 MP - server overwrites them.
    We send a request to the server, which performs the actual stat modification.
    
    Fix for C9 (0.8.0): throttled to once per 30s. Reduces RCP pressure in
    busy RP scenes with no gameplay impact at default reductionAmount.
]]
local function reduceBoredom()
    if not TAZC_Config.Boredom.enabled then return end
    if not isClient() then return end
    
    local now = TAZC_Core.getTimeMs()
    if (now - lastBoredomRequestMs) < BOREDOM_COOLDOWN_MS then
        dbg("reduceBoredom: suppressed (cooldown, %dms since last)", now - lastBoredomRequestMs)
        return
    end
    lastBoredomRequestMs = now
    
    dbg("reduceBoredom: sending request to server")
    sendClientCommand("TAZC", "ReduceBoredom", {})
end

-- ============================================================================
-- MESSAGE HANDLERS
-- ============================================================================

local function onChatMessage(msgData)
    dbg("onChatMessage: username=%s channel=%s msg=%s",
        tostring(msgData.username), tostring(msgData.channel),
        tostring(msgData.message and msgData.message:sub(1,30) or "nil"))
    
    if not msgData then
        dbg("onChatMessage: nil msgData")
        return
    end
    
    -- Get speaker player for anonymity check and bubble display
    local player = getPlayerByUsername(msgData.username)

    -- Signing gesture (v1, presentation-only -- see TAZC_SignGesture.lua's
    -- header for why this echo IS the send seam). Runs before every
    -- early-return below (sight gate, Deaf reception, etc.) on purpose:
    -- this is about the SENDER's own body animating, not about what any
    -- receiver can perceive, so it must not depend on those gates.
    -- Fail-safe: the whole thing is TAZC_Core.safe-wrapped (real pcall) --
    -- a bad emote name or a playEmote error does nothing and never
    -- touches chat.
    TAZC_Core.safe(function()
        local localPlayer = getPlayer()
        local isOwnMessage = localPlayer ~= nil
            and msgData.username == localPlayer:getUsername()
        local emote = signGesture:consider(TAZC_Core.getTimeMs(), {
            channel = msgData.channel,
            modality = msgData.modality,
            isOwnMessage = isOwnMessage,
            enabled = TAZC_Config.SignGesture.enabled,
            cooldownMs = TAZC_Config.SignGesture.cooldownMs,
            gestureDefault = TAZC_Config.SignGesture.gestureDefault,
            gestureYell = TAZC_Config.SignGesture.gestureYell,
        })
        if emote then
            localPlayer:playEmote(emote)
            dbg("onChatMessage: signing gesture '%s' fired (channel=%s)", emote, tostring(msgData.channel))
        end
    end, nil)

    -- Apply anonymity for IC channels (not OOC, admin, etc.)
    local icChannels = {say = true, yell = true, low = true, whisper = true, emote = true, ["do"] = true,
        emoteLong = true, doLong = true}
    if icChannels[msgData.channel] then
        TAZC_Anonymity.anonymizeMessageData(msgData, player)
        if msgData.isAnonymous then
            dbg("onChatMessage: anonymized to '%s'", msgData.characterName)
        end
    end

    -- Sight gate (R-A2) + Deaf reception (R-A6/R-A9). Spoken/whisper/low/
    -- yell only -- emote/do are narration, not speech or signing.
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    if speechChannels[msgData.channel] then
        -- M4/M6: remember every speaker's modality -- see
        -- lastKnownModality's declaration above. msgData.username is the
        -- real login username (anonymizeMessageData above never touches
        -- it, only characterName/isAnonymous/etc.), so this stays keyed
        -- correctly even for a masked/distant speaker.
        if msgData.username then
            lastKnownModality[msgData.username] = msgData.modality
        end

        if msgData.modality == "signed" then
            -- Fail-closed (R-A3): cannot verify sight -> not shown at all.
            if not TAZC_Anonymity.canSee(player) then
                dbg("onChatMessage: signed message suppressed -- no line of sight")
                return
            end
        else
            local deaf = TAZC_Anonymity.deafReception(player)
            if deaf.mode == "nothing" then
                dbg("onChatMessage: spoken message suppressed for a Deaf receiver with no sight")
                return
            elseif deaf.mode == "presence" then
                local who = (msgData.characterName and msgData.characterName ~= "")
                    and msgData.characterName or "A figure"
                msgData.message = who .. "'s lips move"
                msgData.chunks = nil
            elseif deaf.mode == "lipread" then
                local TAZC_Lipread = require("TAZC_Lipread")
                msgData.message = TAZC_Lipread.gapify(msgData.message, msgData.timestamp or 0)
                msgData.chunks = nil  -- gapify works on flat text; stale L2 chunk coloring would desync
            end
            -- "full": not Deaf (or the sandbox has it off) -- unaffected.
        end
    end

    -- Language tag (Unstable). Server marks deliveries with msgData.language
    -- only once the receiver has identified the language (acquired at least
    -- one word in it). Until then, non-comprehenders see babbled text with
    -- no label — they can guess from the phonetic texture (French vs Slavic
    -- vs Turkish sound distinct) but the engine doesn't name it for them.
    -- Prefix here so both the chat panel and the bubble pick it up.
    -- 
    -- Two paths:
    --   1. Flat-string only (msgData.chunks nil): prefix the tag onto
    --      msgData.message; parseColorSegments client-side handles styling.
    --   2. Chunks present (v8.5+): prefix the tag onto msgData.message
    --      (so bubble + flat-string consumers still see it) AND prepend a
    --      matching base chunk (color = nil -> channel tagColor) so the
    --      ChatPanel render path sees the tag in the chunk array too.
    if msgData.language and msgData.language ~= "" then
        local tag = TAZC_LangRegistry.displayName(msgData.language)
        local prefix = "[" .. tag .. "] "
        msgData.message = prefix .. (msgData.message or "")
        if msgData.chunks then
            table.insert(msgData.chunks, 1, { text = prefix })  -- nil color -> channel default
        end
    end
    
    -- Add to chat panel
    if TAZC_ChatPanel and TAZC_ChatPanel.addMessage then
        TAZC_ChatPanel.addMessage(msgData)
        dbg("onChatMessage: added to panel")
    end

    -- One-time first-babble hint.
    --
    -- The mod's one proactive "you're learning" notice (AcquisitionMoment's
    -- firstInLanguage) deliberately never fires for a listener who hasn't
    -- acquired a single word yet -- so a brand-new player's FIRST contact
    -- with the headline babble mechanic explains nothing; it just sounds
    -- broken. This fires exactly once per character, the first time
    -- msgData.babbled is true (TAZC_Server's additive signal for "genuinely
    -- unlabeled babble, for THIS listener") and it isn't the listener's own
    -- speech. TAZC_BabbleHint is the pure, offline-testable decision; the
    -- once-flag persists via the local player's modData -- the same
    -- per-character-stamp idiom TAZC_Server.checkFreshCharacter already uses.
    TAZC_Core.safe(function()
        local localPlayer = getPlayer()
        if not localPlayer then return end
        local localUsername = localPlayer:getUsername()
        local modData = localPlayer:getModData()
        if TAZC_BabbleHint.shouldFire(msgData, localUsername, modData) then
            if TAZC_ChatPanel and TAZC_ChatPanel.addMessage then
                TAZC_ChatPanel.addMessage({
                    channel = "system",
                    characterName = "",
                    message = "You don't recognize that tongue -- yet. "
                        .. "Keep listening; /lang shows what you "
                        .. "understand so far.",
                    timestamp = os.time(),
                    playerColor = {210, 190, 140},
                })
                dbg("onChatMessage: first-babble hint shown")
            end
        end
    end, nil)

    -- Show bubble
    if player and (msgData.channel == "emote" or msgData.channel == "emoteLong") then
        showEmoteBubble(player, msgData.characterName, msgData.message)
    elseif player and (msgData.channel == "do" or msgData.channel == "doLong") then
        showDoBubble(player, msgData.message)
    elseif player then
        local bubbleChannels = {say = true, yell = true, low = true}
        if bubbleChannels[msgData.channel] then
            -- Pass hideAvatar (only for distant speakers), characterName
            -- for anonymous emote handling, and isAnonymous (masked OR
            -- distant) so the bubble never shows a custom portrait for
            -- an anonymized speaker
            showBubble(player, msgData.message, msgData.channel, msgData.isDistant, msgData.characterName, msgData.isAnonymous, msgData.modality)
        end
    end
    
    -- Boredom reduction for hearing others talk (not yourself)
    local boredomChannels = {say = true, yell = true, low = true, whisper = true}
    if boredomChannels[msgData.channel] then
        local localPlayer = getPlayer()
        local localUsername = localPlayer and localPlayer:getUsername()
        
        -- Only reduce boredom when hearing OTHERS, not yourself
        if localUsername and msgData.username ~= localUsername then
            reduceBoredom()
            dbg("onChatMessage: boredom reduction triggered (heard %s)", msgData.username)
        else
            dbg("onChatMessage: skipping boredom reduction (own message)")
        end
    end
    
    dbg("onChatMessage: done")
end

local function onRadioMessage(msgData)
    dbg("onRadioMessage: sender=%s freq=%s receiverType=%s",
        tostring(msgData.senderUsername), tostring(msgData.frequency),
        tostring(msgData.receiverType))
    
    if not msgData then
        dbg("onRadioMessage: nil msgData")
        return
    end
    
    local isSelfEcho = (msgData.receiverType == "self")
    if isSelfEcho then
        dbg("onRadioMessage: self-echo, chat only")
    end

    -- Deaf gate (R-A6/M1): radio is voice-only and disembodied -- there are
    -- no lips to read, so unlike face-to-face speech (which still gets a
    -- presence line or a gappy lipread render depending on sight/distance,
    -- see onChatMessage + TAZC_Anonymity.deafReception) a Deaf receiver gets
    -- NOTHING from radio at all: no chat line, no bubble, no boredom tick.
    -- The speaker's own self-echo is exempt -- this suppresses HEARING
    -- someone else's radio voice, not the courtesy reflection of what the
    -- Deaf player themselves just transmitted.
    if not isSelfEcho
       and TAZC_Config.liveSandbox("DeafTraitEnforced", true) ~= false
       and TAZC_Anonymity.localPlayerIsDeaf() then
        dbg("onRadioMessage: suppressed entirely for a Deaf receiver -- radio has no lips to read")
        return
    end

    -- Language tag (Unstable). Same logic as onChatMessage: server only
    -- sends the tag once the receiver has identified the language.
    -- v8.5.1: when the server sent chunks (chunked radio render with packet
    -- loss applied to chunks), prepend the tag as a base chunk too so the
    -- ChatPanel render path sees the prefix in the chunk array, matching
    -- proximity-chat behaviour.
    if msgData.language and msgData.language ~= "" then
        local tag = TAZC_LangRegistry.displayName(msgData.language)
        local prefix = "[" .. tag .. "] "
        msgData.message = prefix .. (msgData.message or "")
        if msgData.chunks then
            table.insert(msgData.chunks, 1, { text = prefix })
        end
    end
    
    -- Add to chat panel
    if TAZC_ChatPanel and TAZC_ChatPanel.addMessage then
        local panelData = {
            username = msgData.senderUsername,
            characterName = msgData.senderCharacter,
            message = msgData.message,
            chunks = msgData.chunks,  -- v8.5.1: chunked radio render
            channel = "radio",
            originalChannel = msgData.channel,
            frequency = msgData.frequency,
            playerColor = TAZC_Config.ChannelColors.radio or {120, 220, 200}
        }
        -- Radio ignores distance AND mask: a voice on the radio is
        -- recognisable however far the speaker is, and a mask hides your
        -- face, not your voice. The real name the server sent in
        -- panelData.characterName is always shown (see
        -- TAZC_Anonymity.anonymizeRadioMessageData -- reserved for a future
        -- craftable voice-modulator item, not clothing).
        local speaker = getPlayerByUsername(msgData.senderUsername)
        TAZC_Anonymity.anonymizeRadioMessageData(panelData, speaker)
        if panelData.isAnonymous then
            dbg("onRadioMessage: anonymized speaker rendered as '%s'", panelData.characterName)
        end
        TAZC_ChatPanel.addMessage(panelData)
    end
    
    -- Show bubble (skip self-echo)
    if not isSelfEcho then
        local bubbleChannels = {say = true, yell = true, low = true}
        if bubbleChannels[msgData.channel] then
            showRadioBubble(msgData)
        end
    end
    
    -- Radio chat reduces boredom (only when hearing others)
    local localPlayer = getPlayer()
    local localUsername = localPlayer and localPlayer:getUsername()
    if localUsername and msgData.senderUsername ~= localUsername then
        reduceBoredom()
        dbg("onRadioMessage: boredom reduction triggered (heard %s)", msgData.senderUsername)
    else
        dbg("onRadioMessage: skipping boredom reduction (own transmission)")
    end
    
    dbg("onRadioMessage: done")
end

-- ============================================================================
-- COMMAND HANDLERS
-- ============================================================================

local ClientCommands = {}

ClientCommands.ChatMessage = function(args)
    dbg("ClientCommands.ChatMessage")
    if args then onChatMessage(args) end
end

ClientCommands.RadioMessage = function(args)
    dbg("ClientCommands.RadioMessage")
    if args then onRadioMessage(args) end
end

ClientCommands.Typing = function(args)
    if not args then return end
    dbg("ClientCommands.Typing from %s", tostring(args.username))
    local player = getPlayerByUsername(args.username)
    if player then
        showTyping(player)
    end
end

ClientCommands.SystemMessage = function(args)
    if not args or not args.message then return end
    dbg("ClientCommands.SystemMessage: %s", tostring(args.message))

    if not TAZC_ChatPanel or not TAZC_ChatPanel.systemMessage then return end

    -- v8.9.2: forward server-provided chunks if present.
    TAZC_ChatPanel.systemMessage(args.message, { color = args.color, chunks = args.chunks })
end

-- ============================================================================
-- ACQUISITION MOMENTS (v8.16.1)
-- 
-- The reward loop. The server emits AcquisitionMoment payloads whenever a
-- listener acquires new words; the payload carries milestone flags shaped
-- to the 8.17 spec (firstInLanguage, comprehension band crossings). This
-- handler fires quiet, immersive observations at the milestones that
-- matter -- not on every individual word (the per-word honey-gold render
-- bracket carries that signal), but on the moments that mark real shifts
-- in comprehension. The tone is internal observation, not game notification.
-- ============================================================================

ClientCommands.AcquisitionMoment = function(args)
    if not args then return end
    if not TAZC_ChatPanel or not TAZC_ChatPanel.addMessage then return end

    local lang = args.language
    if not lang or lang == "" then return end
    local displayLang = TAZC_LangRegistry.displayName(lang)

    -- Quiet gold -- warm enough to read as positive, muted enough to sit
    -- below the honey-gold per-word reward in visual hierarchy.
    local momentColor = {210, 190, 140}

    -- First acquisition in this language: the moment the noise becomes
    -- speech. Ties to the language-identification gating -- the [Turkish]
    -- tag just appeared in their chat for the first time.
    if args.firstInLanguage then
        TAZC_ChatPanel.addMessage({
            channel = "system",
            characterName = "",
            message = "You've learned your first word of "
                .. displayLang .. ".",
            timestamp = os.time(),
            playerColor = momentColor,
        })
    end

    -- Comprehension band crossings (25%, 50%, 75% of core vocabulary).
    -- Each gets its own message; multiple bands crossing in one batch
    -- (unlikely but possible with teaching) fire sequentially.
    if args.bands then
        local bandMessages = {
            [25] = "You're starting to follow " .. displayLang .. ".",
            [50] = "You follow about half of " .. displayLang .. " now.",
            [75] = "You follow most of " .. displayLang .. " now.",
        }
        for _, band in ipairs(args.bands) do
            local msg = bandMessages[band]
            if msg then
                TAZC_ChatPanel.addMessage({
                    channel = "system",
                    characterName = "",
                    message = msg,
                    timestamp = os.time(),
                    playerColor = momentColor,
                })
            end
        end
    end
end

local function OnServerCommand(module, command, args)
    if module ~= "TAZC" then return end
    
    dbg("OnServerCommand: %s", command)
    
    local handler = ClientCommands[command]
    if handler then
        local ok, err = pcall(handler, args)
        if not ok then
            print(string.format(
                "[TAZC][ERROR] server command '%s' failed: %s",
                tostring(command), tostring(err)))
        end
    else
        dbg("OnServerCommand: unknown command: %s", tostring(command))
    end
end

-- ============================================================================
-- CHAT PANEL SETUP
-- ============================================================================

local function createChatPanel()
    if chatPanel then 
        dbg("createChatPanel: already exists")
        return true
    end
    
    if not ISChat or not ISChat.instance then
        dbg("createChatPanel: ISChat not ready")
        return false
    end
    
    local chat = ISChat.instance
    
    if not chat.panel then
        dbg("createChatPanel: ISChat.panel not found")
        return false
    end
    
    local panelX = 0
    local panelY = chat.panel:getY()
    local panelW = chat.panel:getWidth()
    local panelH = chat.panel:getHeight() - 20
    
    dbg("createChatPanel: at %d,%d size %dx%d", panelX, panelY, panelW, panelH)
    
    chatPanel = TAZC_ChatPanel:new(panelX, panelY + 20, panelW, panelH)
    chatPanel:initialise()
    chatPanel:setAnchorLeft(true)
    chatPanel:setAnchorRight(true)
    chatPanel:setAnchorTop(true)
    chatPanel:setAnchorBottom(true)
    
    chat:addChild(chatPanel)
    chatPanel:setVisible(true)
    chatPanel:bringToTop()
    
    -- Hide vanilla General text panel only, preserve Admin
    -- Admin is typically index 2, General is index 1
    if chat.panel.viewList then
        for i, viewInfo in ipairs(chat.panel.viewList) do
            if viewInfo.view then
                local viewName = viewInfo.name or ""
                -- Check by name OR by index (Admin is usually index 2)
                local isAdminView = (i == 2) or viewName:lower():find("admin") or viewName:lower():find("amministr")
                
                if not isAdminView then
                    dbg("createChatPanel: hiding vanilla view [%d]: %s", i, tostring(viewInfo.name))
                    viewInfo.view:setVisible(false)
                    viewInfo.view:setHeight(0)
                    viewInfo.view:setWidth(0)
                else
                    dbg("createChatPanel: preserving admin view [%d]: %s", i, tostring(viewInfo.name))
                end
            end
        end
    end
    
    if chat.chatText then
        chat.chatText:setVisible(false)
        chat.chatText:setHeight(0)
    end
    
    dbg("createChatPanel: done")
    return true
end

local function suppressVanillaViews()
    if not ISChat or not ISChat.instance or not ISChat.instance.panel then return end
    
    local chat = ISChat.instance
    
    local tabMap = vanillaTabMap()
    
    local mcTabId = 1  -- Default to IC
    if chat.currentTabID then
        if chat.currentTabID ~= lastLoggedTab then
            dbg("tab changed to %d", chat.currentTabID)
            lastLoggedTab = chat.currentTabID
        end
        
        -- Map vanilla tab ID to our internal tab ID
        mcTabId = tabMap and tabMap[chat.currentTabID] or chat.currentTabID
        if mcTabId ~= chat.currentTabID then
            dbg("tab mapped: vanilla %d -> MC %d", chat.currentTabID, mcTabId)
        end
        
        TAZC_ChatPanel.setCurrentTab(mcTabId)
    end
    
    -- Tab routing:
    --   Tab 1 (General) = we handle with our panel (IC + OOC mixed for now)
    --   Tab 2 (Admin) = vanilla handles it, hide our panel
    local isAdminTab = (mcTabId == 2)
    
    if chatPanel then
        chatPanel:setVisible(not isAdminTab)
    end
    
    -- Only suppress vanilla General view, preserve Admin view (index 2)
    local viewList = ISChat.instance.panel.viewList
    if viewList then
        for i, viewInfo in ipairs(viewList) do
            if viewInfo.view then
                -- Check if this is the Admin tab view (index 2 or name contains admin)
                local viewName = viewInfo.name or ""
                local isAdminView = (i == 2) or viewName:lower():find("admin") or viewName:lower():find("amministr")
                
                if not isAdminView then
                    -- Suppress General view (we replace it)
                    if viewInfo.view:isVisible() then
                        viewInfo.view:setVisible(false)
                    end
                    if viewInfo.view:getHeight() > 0 then
                        viewInfo.view:setHeight(0)
                        viewInfo.view:setWidth(0)
                    end
                end
                -- Leave Admin view alone - vanilla handles it
            end
        end
    end
    
    -- Also suppress chatText (legacy?)
    if chat.chatText and chat.chatText:isVisible() and not isAdminTab then
        chat.chatText:setVisible(false)
        chat.chatText:setHeight(0)
    end
end

-- ============================================================================
-- VANILLA CHAT HOOKS
-- ============================================================================

--[[
    Resolve anonymity for a vanilla-parsed chat line (e.g. native Q-shout)
    and route it to MC's panel/bubble. These lines never pass through
    TAZC_Server's own ChatMessage pipeline, so this is their only anonymity
    checkpoint.

    Internal contract: exposed as TAZC_Client._routeVanillaChatLine -- the
    offline test harness has no ISChat to hook through, so tests call this
    directly instead of round-tripping through hookVanillaChat.

    @return boolean true if MC handled the line, false to let vanilla render it
]]
local function routeVanillaChatLine(channel, charName, text)
    -- Admin lines are vanilla's own access-filtered pipeline; never intercept.
    if channel == "admin" then
        dbg("addLineInChat: admin channel, letting vanilla handle")
        return false
    end

    dbg("Routing vanilla to MC: [%s] %s: %s", channel, charName, text:sub(1, 30))

    local speakerPlayer = getPlayerByUsername(charName)
    local panelData = {
        channel = channel,
        characterName = charName,
        username = charName,
        message = text,
        timestamp = os.time(),
        playerColor = TAZC_Config.ChannelColors[channel] or {255, 255, 255},
    }

    if speakerPlayer then
        TAZC_Anonymity.anonymizeMessageData(panelData, speakerPlayer)
    else
        -- Parsed name matched no online player -- can't verify mask/distance
        -- against a real speaker, so fail closed instead of trusting the
        -- raw vanilla string.
        panelData.characterName = TAZC_Anonymity.Config.maskedName
        panelData.isAnonymous = true
        panelData.playerColor = TAZC_Anonymity.Config.anonymousColor
    end

    -- M6 fix: this path never touches TAZC_Server's language pipeline, so
    -- `text` here is always the speaker's TRUE raw content -- it never ran
    -- the signed comprehension ladder (gesture-prose/gloss/fingerspell) or
    -- the sight gate. lastKnownModality (shared with M4's Q-shout fix) is
    -- the closest honest signal available for "is this speaker currently
    -- signing." A speech channel whose last-known speaker modality was
    -- signed fails CLOSED: no verified sight -> nothing at all (matches
    -- onChatMessage's own sight gate, and canSee's self-exemption means a
    -- signer reaching this path about THEMSELVES still sees it fine);
    -- sighted -> a neutral presence line only, never the real content --
    -- showing raw text here would bypass every comprehension/sight rule
    -- the real pipeline enforces.
    local speechChannelsForVanilla = {say = true, yell = true, low = true, whisper = true, shout = true}
    if speechChannelsForVanilla[channel] then
        local knownUsername = charName
        if speakerPlayer then
            local ok, u = pcall(function() return speakerPlayer:getUsername() end)
            if ok and u then knownUsername = u end
        end
        if lastKnownModality[knownUsername] == "signed" then
            if not speakerPlayer or not TAZC_Anonymity.canSee(speakerPlayer) then
                dbg("routeVanillaChatLine: signed line suppressed -- no line of sight")
                return true
            end
            local who = (panelData.characterName and panelData.characterName ~= "")
                and panelData.characterName or "A figure"
            panelData.message = who .. "'s hands move"
            text = panelData.message  -- keep the bubble call below in sync
        end
    end

    TAZC_ChatPanel.addMessage(panelData)

    -- 0.8.16.6 fix (Q-shout piping through radios): a vanilla "[Shout]"/
    -- "[Yell]" line reaching this client is not proof the speaker is
    -- actually nearby. B42's own radio system can relay the exact same
    -- vanilla-formatted line to a player who only heard it because they're
    -- carrying a tuned radio -- Q-shout has no MC-side radio path of its
    -- own (its canned callout text never touches TAZC_Server's pipeline; see
    -- the Q-shout hook above), so this text-only interception point has no
    -- other signal to tell "heard in person" from "picked up on a radio".
    -- Rendering the overhead bubble unconditionally used to show a radio-
    -- relayed shout floating above the RECEIVING player's own head (and,
    -- in png avatar mode, their own portrait), and the game visually
    -- attributed the shout to whoever happened to be carrying the radio.
    --
    -- TAZC_Anonymity.canSee already self-exempts (a shouter always sees
    -- their own callout play back) and fails closed (any pcall error,
    -- missing Z-level match, or a false checkCanSeeClient all resolve to
    -- "not verified"). A verified, same-floor, unobstructed line of sight
    -- is the one thing this interception point can actually confirm --
    -- if a shout's speaker could be heard within normal earshot, radio
    -- relay was never needed to explain how this line arrived, so an
    -- unverifiable speaker can only have reached this client via radio,
    -- and the full-shout-range overhead bubble is suppressed. The panel
    -- line above already carries the real speaker's identity and stays.
    --
    -- 0.8.16.7 CORRECTION: this (channel, charName, text) signature only
    -- ever gets populated by the STRING calling convention below, in
    -- hookVanillaChat's addLineInChat wrapper -- and live-verified against
    -- the shipped game's own media/lua/client/Chat/ISChat.lua, real vanilla
    -- calls addLineInChat with exactly one signature, always an object
    -- (`ISChat.addLineInChat = function(message, tabID)`, using
    -- message:getAuthor()/message:getTextWithPrefix()). The string
    -- convention is dead code against real B42 traffic; this function is
    -- reached in production only by the offline test harness calling
    -- TAZC_Client._routeVanillaChatLine directly, or if some other mod calls
    -- addLineInChat with a bare string. The canSee() gate below is kept as
    -- that defense-in-depth, but it is NOT what protects a live radio-
    -- relayed vanilla Shout -- that protection now lives one level up, in
    -- hookVanillaChat's vanilla-object branch, gated on the object's own
    -- getRadioChannel() (a real, @UsedFromLua, live-verified signal;
    -- see the comment there). That branch never calls this function for a
    -- verified-radio line, by design: this function has no getRadioChannel
    -- to gate on (a parsed "[Shout] Name: text" string carries no such
    -- data), and canSee(speakerPlayer) resolves the CARRIER as visible
    -- for that exact case (a carrier always sees their own radio), which
    -- would misattribute the bubble to them -- the same failure mode a
    -- prior fix here (1f7f4dd) shipped without live traffic ever reaching
    -- it to prove or disprove.
    if (channel == "yell" or channel == "shout") and speakerPlayer then
        if TAZC_Anonymity.canSee(speakerPlayer) then
            -- isAnonymous=true keeps the 3D model and blocks the custom PNG
            -- portrait regardless of the resolved mask state (avatar-half law).
            showBubble(speakerPlayer, text, "yell", false, nil, true)
        else
            dbg("routeVanillaChatLine: %s speaker not verifiably in sight -- likely radio-relayed, suppressing overhead bubble", channel)
        end
    end

    return true
end
TAZC_Client._routeVanillaChatLine = routeVanillaChatLine

local function hookVanillaChat()
    if vanillaChatHooked then return end
    if not ISChat or not ISChat.instance then return end
    
    local original_addLineInChat = ISChat.addLineInChat
    if original_addLineInChat then
        --[[
            Handle multiple calling conventions:
            1. Vanilla: addLineInChat(messageObject, tabID) - messageObject has getAuthor(), getText()
            2. Method call: instance:addLineInChat(stringMessage, tabID)
            3. Other mods: various patterns
            
            We detect by checking the type/shape of the first argument.
        ]]
        ISChat.addLineInChat = function(arg1, arg2, arg3)
            local messageStr, tabID
            local isVanillaMessage = false
            
            -- Detect calling convention
            if type(arg1) == "table" and arg1.getAuthor and arg1.getText then
                -- Vanilla signature: arg1 is a message object
                isVanillaMessage = true
                local msgObj = arg1
                tabID = arg2
                
                -- Extract text from vanilla message object
                messageStr = TAZC_Core.safe(function() 
                    return msgObj:getTextWithPrefix() or msgObj:getText() 
                end, nil)
                
                dbg("INTERCEPTED addLineInChat (vanilla obj): %s", tostring(messageStr and messageStr:sub(1,50) or "nil"))

                -- CORRECTED (live-verified against the shipped B42 jar,
                -- zombie.chat.ChatMessage -- byte-scanned class file, no
                -- javap available): a prior pass here claimed "no channel/
                -- type accessor exists" on this object besides getAuthor/
                -- getText/getTextWithPrefix. That was wrong. ChatMessage is
                -- @UsedFromLua and also exposes getRadioChannel():int --
                -- every constructor stamps it -1, and the ONLY writers are
                -- RadioChat's own broadcast/pack paths (createBroadcastingMessage,
                -- ChatManager.showRadioMessage(text,channel)'s
                -- RadioChat.createMessage+setRadioChannel, RadioChat.unpackMessage).
                -- A non-(-1) value is proof-positive this line arrived over
                -- a tuned radio, independent of getAuthor().
                --
                -- getAuthor() is NOT trustworthy for that same case: traced
                -- end to end (Radio.AddDeviceText -> IsoPlayer.SayRadio ->
                -- IsoGameCharacter.ProcessSay -> ChatManager.showRadioMessage
                -- -> RadioChat.createMessage), the one live path that puts a
                -- radio-relayed vanilla Shout through this hook auto-fills
                -- author from the RECEIVING client's own chatOwner -- i.e.
                -- the carrier who happens to be tuned in, never the original
                -- shouter. Gating the overhead bubble on canSee(getPlayerByUsername(
                -- author)) here would resolve the CARRIER as visible (they're
                -- always in their own line of sight) and render a personal
                -- speech bubble above them -- exactly the misattribution this
                -- fix exists to prevent. getRadioChannel() sidesteps the
                -- question entirely: any verified radio channel routes as a
                -- radio line, full stop, regardless of what author says.
                --
                -- Blind passthrough here used to render ANY non-admin
                -- object line -- including a genuine IC speech line, if one
                -- of TAZC_Input's three onCommandEntered hooks ever misses on
                -- some client build -- with a raw, unmasked identity and no
                -- anonymity pass at all. Fail closed on the one signal we
                -- CAN verify: Admin passes (vanilla's own access-filtered
                -- pipeline, same rule routeVanillaChatLine uses below for
                -- the string convention's "admin" channel); a verified radio
                -- channel routes as a radio line (below); anything else
                -- is suppressed rather than shown unresolved.
                local tabMap = vanillaTabMap()
                local mcTabId = (tabMap and tabID and tabMap[tabID]) or tabID
                if mcTabId == 2 then
                    if original_addLineInChat then
                        return original_addLineInChat(arg1, arg2)
                    end
                    return
                end

                local radioChannel = TAZC_Core.safe(function() return msgObj:getRadioChannel() end, nil)
                if radioChannel ~= nil and radioChannel ~= -1 and messageStr then
                    local localPlayer = getPlayer()
                    if localPlayer then
                        dbg("addLineInChat: vanilla object carries a verified radio channel %s -- routing as a radio line, never a personal bubble",
                            tostring(radioChannel))
                        -- Never resolve/trust an identity here (see above --
                        -- author is unverifiable and, for this exact path,
                        -- actively wrong). Render at the LOCAL player's own
                        -- radio, styled as MC's existing radio bubble/panel
                        -- line (never TAZC_Bubble:new's personal-speech shape),
                        -- and never claim a name for the panel line either.
                        --
                        -- 2026-07-09 investigation (Emily's "foreign speech
                        -- must babble over radio" ruling): `messageStr` here
                        -- is NOT candidate IC free-text. TAZC_Input.send()
                        -- intercepts and swallows every say/yell/low/whisper
                        -- keystroke before it ever reaches vanilla's own
                        -- IsoGameCharacter.Say/ProcessSay -- traced end to
                        -- end above (Radio.AddDeviceText -> IsoPlayer.
                        -- SayRadio -> ProcessSay -> ChatManager.
                        -- showRadioMessage -> RadioChat.createMessage), the
                        -- ONLY live producer of a getRadioChannel()-stamped
                        -- vanilla ChatMessage is the Shout keybind's canned
                        -- callout (getText("IGUI_PlayerText_Callout1/2/3") --
                        -- see hookWorldMessage below), which never touches
                        -- TAZC_Server's language pipeline at all (no speaker,
                        -- no chosen language, same three fixed strings for
                        -- every player). There is no TAZC_Lang barrier to
                        -- fail toward babble on here -- babbling it would
                        -- gibberish a system UI callout with no comprehension
                        -- mechanic that could ever resolve it, permanently,
                        -- for every listener including the shouter. So this
                        -- text is left as-is; it is not a foreign-language
                        -- leak. If a future engine hook ever lets real IC
                        -- text reach this branch, re-run this reasoning.
                        showRadioBubble({
                            message = messageStr,
                            channel = "radio",
                            receiverType = "player",
                            receiverOwnerId = localPlayer:getUsername(),
                            frequency = radioChannel,
                            isPrivate = false,
                        })
                        if TAZC_ChatPanel and TAZC_ChatPanel.addMessage then
                            TAZC_ChatPanel.addMessage({
                                channel = "radio",
                                characterName = TAZC_Anonymity.Config.maskedName,
                                username = TAZC_Anonymity.Config.maskedName,
                                message = messageStr,
                                timestamp = os.time(),
                                isAnonymous = true,
                                frequency = radioChannel,
                                playerColor = TAZC_Config.ChannelColors.radio or {120, 220, 200},
                            })
                        end
                    end
                    return
                end

                dbg("addLineInChat: vanilla object on non-admin tab %s -- suppressed (channel unverifiable)",
                    tostring(tabID))
                return

            elseif type(arg1) == "string" then
                -- Direct string call: addLineInChat("message", tabID)
                messageStr = arg1
                tabID = arg2
                dbg("INTERCEPTED addLineInChat (string): %s", tostring(messageStr and messageStr:sub(1,50) or "nil"))
                
            elseif arg1 == ISChat.instance or (type(arg1) == "table" and arg1.tabCnt) then
                -- Method call: instance:addLineInChat(message, tabID) -> (self, message, tabID)
                messageStr = arg2
                tabID = arg3
                dbg("INTERCEPTED addLineInChat (method): %s", tostring(messageStr and type(messageStr) == "string" and messageStr:sub(1,50) or "nil"))
                
            else
                -- Unknown pattern - pass through
                dbg("INTERCEPTED addLineInChat (unknown pattern, passing through)")
                if original_addLineInChat then
                    return original_addLineInChat(arg1, arg2, arg3)
                end
                return
            end
            
            -- Process string messages for MC routing
            if messageStr and type(messageStr) == "string" then
                local chanMatch, nameMatch, textMatch = messageStr:match("^%[(%w+)%]%s*([^:]+):%s*(.+)$")
                local channel, charName, text
                
                if chanMatch then
                    channel = chanMatch:lower()
                    charName = nameMatch
                    text = textMatch
                else
                    nameMatch, textMatch = messageStr:match("^([^:]+):%s*(.+)$")
                    if nameMatch then
                        channel = "say"
                        charName = nameMatch
                        text = textMatch
                    end
                end
                
                if channel and charName and text then
                    if routeVanillaChatLine(channel, charName, text) then
                        return
                    end
                    if original_addLineInChat then
                        return original_addLineInChat(arg1, arg2, arg3)
                    end
                    return
                end
            end
            
            -- Fall through to original
            if original_addLineInChat then
                return original_addLineInChat(arg1, arg2, arg3)
            end
        end
        dbg("Hooked ISChat.addLineInChat")
    end
    
    vanillaChatHooked = true
    dbg("Vanilla chat hooks installed")
end

-- ============================================================================
-- Q-SHOUT SUPPRESSION
--
-- 0.8.16.6 INVESTIGATION NOTE: "ISWorldMessage" does not exist anywhere in
-- the shipped 0.8.16.6 projectzomboid.jar (23,544 classes, checked by
-- extracting every class file's constant pool -- no class file, and no
-- literal string "ISWorldMessage", anywhere) or in vanilla lua. That means
-- the guard below always takes the `else return end` branch and this
-- entire hook has never actually installed on this build -- it is dead
-- code, the same class of bug as the Deaf-trait crash (an assumed API
-- that plain doesn't exist). It is left in place rather than torn out:
-- its LOGIC (self-echo anonymization, M4/M6 modality stamping) is real,
-- tested unit behaviour that some future correct hook point could still
-- reuse, and this codebase has no live B42 session available to verify
-- what (if anything) the local shouter's own floating-callout view
-- actually needs -- the real, WORKING interception point for a Q-shout
-- (including a native-shout line vanilla itself relays, e.g. over a
-- radio) is routeVanillaChatLine above, via ISChat.addLineInChat's real
-- Events.OnAddMessage delivery, which the 0.8.16.6 bubble-attribution fix
-- there addresses.
-- ============================================================================

local function hookWorldMessage()
    if worldMessageHooked then return end

    if not ISWorldMessage then
        if _G.ISWorldMessage then
            ISWorldMessage = _G.ISWorldMessage
        else
            return
        end
    end
    
    local shoutStrings = {}
    pcall(function()
        table.insert(shoutStrings, getText("IGUI_PlayerText_Callout1"))
        table.insert(shoutStrings, getText("IGUI_PlayerText_Callout2"))
        table.insert(shoutStrings, getText("IGUI_PlayerText_Callout3"))
    end)
    
    if ISWorldMessage.addMessage then
        local original_addMessage = ISWorldMessage.addMessage
        ISWorldMessage.addMessage = function(text, x, y, ...)
            dbg("ISWorldMessage.addMessage: %s", tostring(text))
            
            for _, shout in ipairs(shoutStrings) do
                if text == shout then
                    dbg("SUPPRESSED vanilla shout: %s", text)
                    
                    -- VERIFIED (grep across this codebase): shoutStrings
                    -- above is built from getText("IGUI_PlayerText_Callout
                    -- 1/2/3") only -- vanilla's canned self-shout callout
                    -- set, nothing else is ever compared against `text`
                    -- here. ASSUMED, not live-verified: ISWorldMessage.
                    -- addMessage fires only on the shouter's OWN client
                    -- (vanilla's floating callout text, never a broadcast
                    -- every nearby client also receives through this same
                    -- hook) -- unconfirmed by this codebase's own tests or
                    -- a live B42 check, the same class of gap
                    -- hookVanillaChat's vanilla-object branch discloses for
                    -- its own tabID assumption.
                    local player = getPlayer()
                    if player then
                        local username = TAZC_Core.safe(function() return player:getUsername() end, "Unknown")
                        local charName = TAZC_Bio._getCharacterName(player, username) or username

                        -- This is the LOCAL player's own callout -- run it
                        -- through the same anonymize path every other
                        -- call-site uses. getDisplayName's self-indicator
                        -- branch (speakerUsername == localUsername) is what
                        -- actually fires here: a masked player sees their
                        -- own disguise reflected back ("A Masked Figure"),
                        -- same as it already does for a typed /yell. Without
                        -- this the panel line showed their real name and (in
                        -- png avatar mode) showBubble's missing isAnonymous
                        -- would have rendered their real portrait too.
                        local panelData = {
                            channel = "yell",
                            characterName = charName,
                            username = username,
                            message = text,
                            timestamp = os.time(),
                            playerColor = TAZC_Config.ChannelColors["yell"] or {255, 100, 100},
                            -- M4: this canned callout has no modality of
                            -- its own (vanilla text, never touches
                            -- TAZC_Server's language pipeline) --
                            -- lastKnownModality is the shouter's own
                            -- most-recently-seen modality from a real
                            -- delivered utterance.
                            modality = lastKnownModality[username],
                        }
                        TAZC_Anonymity.anonymizeMessageData(panelData, player)

                        TAZC_ChatPanel.addMessage(panelData)

                        showBubble(player, text, "yell", panelData.isDistant,
                            panelData.characterName, panelData.isAnonymous, panelData.modality)
                    end
                    
                    return
                end
            end
            
            return original_addMessage(text, x, y, ...)
        end
        dbg("Hooked ISWorldMessage.addMessage")
        worldMessageHooked = true
    end
end

-- Internal contract: exposed for the offline harness (M4) -- same reasoning
-- as TAZC_Client._routeVanillaChatLine above. The normal call site is
-- OnTick, which also drives createChatPanel/hookVanillaChat; tests only
-- need the ISWorldMessage.addMessage override installed, so they call this
-- directly instead of standing up the rest of OnTick's UI dependencies.
TAZC_Client._hookWorldMessage = hookWorldMessage

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function OnTick()
    if not panelCreated then
        if createChatPanel() then
            panelCreated = true
        end
    end
    
    hookVanillaChat()
    hookWorldMessage()
    
    if panelCreated then
        suppressVanillaViews()
    end
    
    cleanupUI()
end

local function OnGameStart()
    -- Pull the server's actual sandbox config into TAZC_Config.
    -- TAZC_Config loaded with defaults before SandboxVars was populated; this is
    -- what makes server-configured ranges/toggles actually take effect.
    TAZC_Core.safe(function() TAZC_Config.reloadSandboxVars() end, nil)

    TAZC_Core.printBanner()
    dbg("=== CLIENT MODULE LOADED ===")
end

-- ============================================================================
-- WELCOME MESSAGE INJECTION
-- Vanilla injects ServerWelcomeMessage into ISRichTextPanel which we suppress.
-- We need to grab it and inject into our panel instead.
-- ============================================================================

local pendingWelcomeHandler = nil  -- Holds the OnTick closure while we wait

local function OnConnected()
    dbg("OnConnected fired")

    -- Pick up the server's sandbox config. By the time OnConnected fires, the
    -- sandbox handshake has completed and SandboxVars.TAZC is populated
    -- with server values. This is the most reliable point to refresh TAZC_Config.
    TAZC_Core.safe(function() TAZC_Config.reloadSandboxVars() end, nil)

    -- The chat input box is hooked (and its max length set) before this sync
    -- lands, so re-apply now that the server's MaxMessageLength is in TAZC_Config.
    TAZC_Core.safe(function() TAZC_Input.applyChatBoxMaxLength() end, nil)

    -- If a previous OnConnected already queued a welcome handler that hasn't
    -- fired yet, remove it. Prevents multiple handlers stacking if OnConnected
    -- fires twice in rapid succession (reconnect-in-session). This is the
    -- actual C14 fix; no flag needed -- the queued handler is the state.
    if pendingWelcomeHandler then
        TAZC_Core.safe(function()
            Events.OnTick.Remove(pendingWelcomeHandler)
        end, nil)
        pendingWelcomeHandler = nil
    end

    -- Small delay to ensure our panel exists
    local ticksToWait = 60  -- ~1 second
    local tickCount = 0
    
    local function tryShowWelcome()
        tickCount = tickCount + 1
        if tickCount < ticksToWait then return end
        
        -- Remove this tick handler and clear the pending reference
        Events.OnTick.Remove(tryShowWelcome)
        pendingWelcomeHandler = nil
        
        -- Get the welcome message from server options
        local welcomeText = nil
        TAZC_Core.safe(function()
            local options = ServerOptions.getInstance()
            if options and options.getOptionByName then
                local welcomeOption = options:getOptionByName("ServerWelcomeMessage")
                if welcomeOption and welcomeOption.getValue then
                    welcomeText = welcomeOption:getValue()
                end
            end
        end, nil)
        
        if not welcomeText or welcomeText == "" then
            dbg("OnConnected: no welcome message configured")
            return
        end
        
        dbg("OnConnected: injecting welcome message (%d chars)", #welcomeText)
        
        -- Convert <LINE> tags to newlines for our panel
        -- Convert <RGB:r,g,b> tags (we'll strip them for now, could parse later)
        local cleanText = welcomeText
        cleanText = cleanText:gsub("<LINE>", "\n")
        cleanText = cleanText:gsub("<RGB:[%d,.]+>", "")  -- Strip color tags for now
        cleanText = cleanText:gsub("<[^>]+>", "")  -- Strip any other tags
        
        -- Split by newlines and add each line as a system message
        local lines = {}
        for line in cleanText:gmatch("[^\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                table.insert(lines, trimmed)
            end
        end
        
        -- Add to our chat panel as server/system messages
        if #lines > 0 then
            -- Add a header line
            TAZC_ChatPanel.addMessage({
                channel = "system",
                characterName = "[SERVER]",
                message = "=== Welcome Message ===",
                timestamp = os.time(),
            })
            
            for _, line in ipairs(lines) do
                TAZC_ChatPanel.addMessage({
                    channel = "system",
                    characterName = "[SERVER]", 
                    message = line,
                    timestamp = os.time(),
                })
            end
        end
    end
    
    pendingWelcomeHandler = tryShowWelcome
    Events.OnTick.Add(tryShowWelcome)
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

Events.OnServerCommand.Add(OnServerCommand)
Events.OnTick.Add(OnTick)
Events.OnGameStart.Add(OnGameStart)
Events.OnConnected.Add(OnConnected)

return TAZC_Client
