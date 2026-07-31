--[[
================================================================================
    Terror AustraliZ Chat - Chat Input Handler
    
    Intercepts vanilla chat input and routes messages through Terror AustraliZ Chat.
    Handles command prefix parsing, channel selection, and typing indicators.
    
    KEYBOARD HANDLING:
    - Enter/Toggle Chat: Focus chat input
    - Slash: Focus chat with "/" prefix for commands
    - Escape: Unfocus chat (B42 fix included)
    - Q (Shout): Intercepted for visual suppression
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Radio = require("TAZC_Radio")
local TAZC_InputHistory = require("TAZC_InputHistory")

local dbg = TAZC_Core.debugger("INPUT")

-- Nil-is-failure contract; see TAZC_Core.safeGet/safeExec for why that
-- differs from TAZC_Core.safe. Kept under this file's own name since every
-- call site here already uses it.
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then dbg("safeExec failed: %s", tostring(err)) end
    return ok
end

local TAZC_Input = {}

-- ============================================================================
-- STATE
-- ============================================================================

-- Current default channel (used when no prefix specified)
TAZC_Input.channel = "say"

-- Typing broadcast throttle
local lastTypingBroadcast = 0
local TYPING_THROTTLE_MS = 1000

-- Hook state
local isHooked = false
local pendingUnfocus = false
local lastMessageSentTime = 0  -- Cooldown to prevent Enter from reopening chat after send
local ENTER_COOLDOWN_MS = 200  -- Ignore Enter for this long after sending

-- Command history: a per-session ring of SENT messages (~50 deep, no
-- duplicates-in-a-row). Session-memory only -- NOT persisted, fresh every
-- login. Cycle/dedup/cap logic lives in TAZC_InputHistory.lua (pure,
-- offline-testable); this module is thin glue over it.
local inputHistory = TAZC_InputHistory.new()

-- ============================================================================
-- COMMAND PREFIX PARSING
-- ============================================================================

-- Map of command prefixes to channel names.
-- NOTE: /admin is INTENTIONALLY NOT HERE (as of 0.8.0). Vanilla PZ has its own
-- admin chat pipeline with built-in access-level filtering on the server side
-- and a vanilla-rendered Admin tab. We let those prefixes fall through to the
-- engine so admin messages stay access-controlled and stay in the Admin tab.
local PREFIXES = {
    {"/whisper ", "whisper"},
    {"/w ", "whisper"},
    {"/say ", "say"}, 
    {"/s ", "say"},
    {"/yell ", "yell"},
    {"/y ", "yell"},
    {"/me ", "emote"},
    {"/em ", "emote"},
    {"/e ", "emote"},
    {"/do ", "do"},
    {"/melong ", "emoteLong"},
    {"/dolong ", "doLong"},
    {"/event ", "event"},
    {"/you ", "mood"},
    {"/ooc ", "ooc"},
    {"/o ", "ooc"},
    {"/all ", "all"},
    {"/low ", "low"},
    {"/l ", "low"},
    {"/tell ", "tell"},
    {"/t ", "tell"},
    {"/faction ", "faction"},
    {"/f ", "faction"},
    {"/safehouse ", "safehouse"},
    {"/sh ", "safehouse"},
    {"/bio ", "bio"},
    {"/tagline ", "bio"},
    {"/roll ", "roll"},
    {"/r ", "roll"},
}

-- E2 ergonomics (2026-07-08): the one-shot "@<language> message" prefix is
-- deliberately NOT a PREFIXES entry and never will be -- "@" isn't a
-- channel switch, it's a per-message language override. A message that
-- starts with "@" and isn't otherwise a "/" command falls straight through
-- parsePrefix (no match) to the plain-text branch below and is forwarded to
-- the server byte-for-byte, exactly like ordinary chat text; TAZC_Server.lua's
-- resolveOneShotLanguage does the actual parsing/resolution/fail-open
-- server-side (it alone knows which languages the speaker can select).
-- Never add "@" here.

--[[
    Parse command prefix from message text
    @param text  Raw input text
    @return channel (or nil), message (text after prefix)
]]
local function parsePrefix(text)
    local lower = text:lower()
    for _, p in ipairs(PREFIXES) do
        if lower:sub(1, #p[1]) == p[1] then
            return p[2], text:sub(#p[1] + 1)
        end
    end
    return nil, text
end

-- ============================================================================
-- DICE ROLLING
-- ============================================================================

--[[
    Parse dice notation like "4d10+4", "2d6", "d20-2", "3d8"
    @param notation  String like "4d10+4"
    @return count, sides, modifier (or nil if invalid)
]]
local function parseDice(notation)
    if not notation then return nil end
    
    -- Trim and lowercase
    local s = notation:gsub("%s+", ""):lower()
    
    -- Pattern: optional count, 'd', sides, optional modifier
    -- Examples: "4d10+4", "d20", "2d6-1", "3d8"
    local count, sides, modSign, modVal = s:match("^(%d*)d(%d+)([%+%-]?)(%d*)$")
    
    if not sides then return nil end
    
    count = tonumber(count) or 1
    sides = tonumber(sides)
    modSign = modSign or "+"
    modVal = tonumber(modVal) or 0
    
    if modSign == "-" then modVal = -modVal end
    
    -- Sanity limits
    if count < 1 then count = 1 end
    if count > 100 then count = 100 end
    if sides < 2 then sides = 2 end
    if sides > 1000 then sides = 1000 end
    
    return count, sides, modVal
end

--[[
    Roll dice and format result
    @param notation  String like "4d10+4"
    @return formatted result string, total value, isCrit, isFumble
]]
local function rollDice(notation)
    local count, sides, modifier = parseDice(notation)
    
    if not count then
        return nil, nil, false, false
    end
    
    -- Roll the dice
    local rolls = {}
    local total = 0
    for i = 1, count do
        local roll = ZombRand(sides) + 1  -- ZombRand(n) returns 0 to n-1
        table.insert(rolls, roll)
        total = total + roll
    end
    
    -- Detect natural 1 and natural 20 (only for single d20)
    local isCrit = false
    local isFumble = false
    if count == 1 and sides == 20 then
        if rolls[1] == 20 then
            isCrit = true
            dbg("rollDice: NAT 20!")
        elseif rolls[1] == 1 then
            isFumble = true
            dbg("rollDice: NAT 1!")
        end
    end
    
    total = total + modifier
    
    -- Format modifier string
    local modStr = ""
    if modifier > 0 then
        modStr = "+" .. modifier
    elseif modifier < 0 then
        modStr = tostring(modifier)
    end
    
    -- Format rolls string - truncate if more than 5 dice
    local rollsStr
    if count <= 5 then
        rollsStr = "[" .. table.concat(rolls, ", ") .. "]"
    else
        -- Show first 5 + how many more
        local firstFive = {rolls[1], rolls[2], rolls[3], rolls[4], rolls[5]}
        local remaining = count - 5
        rollsStr = "[" .. table.concat(firstFive, ", ") .. ", ... +" .. remaining .. " more]"
    end
    
    -- Format: "4d10+4: [3, 7, 2, 9] + 4 = 25"
    local diceStr = count .. "d" .. sides .. modStr
    
    local resultStr
    if modifier ~= 0 then
        local modDisplayStr = modifier > 0 and (" + " .. modifier) or (" - " .. math.abs(modifier))
        resultStr = string.format("%s: %s%s = %d", diceStr, rollsStr, modDisplayStr, total)
    else
        resultStr = string.format("%s: %s = %d", diceStr, rollsStr, total)
    end
    
    -- Add crit/fumble indicator to message
    if isCrit then
        resultStr = resultStr .. " - NAT 20!"
    elseif isFumble then
        resultStr = resultStr .. " - NAT 1!"
    end
    
    return resultStr, total, isCrit, isFumble
end

-- ============================================================================
-- LOCAL FEEDBACK
-- Client-only system lines in the chat panel -- no server round-trip.
-- Mirrors the render shape of ClientCommands.SystemMessage in TAZC_Client.
-- ============================================================================

--[[
    Print a system line only this client sees
    @param message  Line text
    @param color    {r, g, b} 0-255 (optional, defaults to neutral grey)
]]
local function localSysMsg(message, color)
    local TAZC_ChatPanel = require("TAZC_ChatPanel")
    if not TAZC_ChatPanel or not TAZC_ChatPanel.systemMessage then return end
    TAZC_ChatPanel.systemMessage(message, { color = color })
end

--[[
    Local player's access level, lowercased ("admin", "moderator", ...).
    Returns nil when it can't be read positively -- callers must treat nil
    as UNKNOWN, not as denial. Client-side only: every admin surface is
    re-gated server-side; this merely shapes local UX (usage lines, /mc
    help extras, sparing non-admins a round-trip).
]]
local function localAccessLevel()
    local player = getPlayer()
    if not player then return nil end
    local level = TAZC_Core.safe(function() return player:getAccessLevel() end, nil)
    if type(level) ~= "string" or level == "" then return nil end
    return level:lower()
end

-- Bare command -> one-line usage. PREFIXES entries only match
-- "<command> <text>", so bare forms ("/roll", "/tell") would otherwise fall
-- through to vanilla as unknown commands while /lang and /lex answer
-- helpfully. Aliases share one line via the builder below.
local BARE_USAGE = {}
local function addUsage(names, line)
    for _, name in ipairs(names) do
        BARE_USAGE[name] = line
    end
end
addUsage({"/whisper", "/w"}, "Usage: /whisper <message>  (or /w) -- heard only right beside you.")
addUsage({"/say", "/s"}, "Usage: /say <message>  (or /s) -- a normal speaking voice.")
addUsage({"/yell", "/y"}, "Usage: /yell <message>  (or /y) -- a shout that carries.")
addUsage({"/low", "/l"}, "Usage: /low <message>  (or /l) -- kept low, for those close by.")
addUsage({"/me", "/em", "/e"}, "Usage: /me <action>  (or /em, /e) -- an action, shown as *Name waves*.")
addUsage({"/do"}, "Usage: /do <text> -- narrate the scene for everyone nearby.")
addUsage({"/melong"}, "Usage: /melong <action> -- same as /me, but seen at yell range.")
addUsage({"/dolong"}, "Usage: /dolong <text> -- same as /do, but heard at yell range.")
addUsage({"/event"}, "Usage: /event <narration> -- storyteller's narration that carries far (admins).")
addUsage({"/you"}, "Usage: /you <feeling> -- a private note of how you're feeling; only you see it.")
addUsage({"/ooc", "/o"}, "Usage: /ooc <message>  (or /o) -- out-of-character, heard nearby.")
addUsage({"/all"}, "Usage: /all <message> -- out-of-character, the whole server hears.")
addUsage({"/tell", "/t"}, "Usage: /tell <name> <message>  (or /t <name> <message>)")
addUsage({"/faction", "/f"}, "Usage: /faction <message>  (or /f)")
addUsage({"/safehouse", "/sh"}, "Usage: /safehouse <message>  (or /sh)")
addUsage({"/roll", "/r"}, "Usage: /roll 2d6  (or /r) -- also d20, 4d10+4. The result lands in OOC.")
-- /hue normally rides through isMCServerCommand to the server (which knows
-- the current color and answers bare /hue with it); this line is the local
-- fallback should that route ever be unavailable.
addUsage({"/hue"}, "Usage: /hue #RRGGBB or /hue r,g,b (0-255) -- the color your name speaks in; /hue reset for your natural shade.")

-- /mc help: the player-facing command list. Player commands only -- the
-- admin surfaces (/lang grant, etc.) stay out of it. Staff
-- see one extra /event line, appended at print time in handleLocalCommand.
local TAZC_HELP = {
    "Terror AustraliZ Chat commands:",
    "  /whisper /low /say /yell <message> -- quiet through loud (or /w /l /s /y)",
    "  /me <action> -- an action, shown as *Name waves* (or /em, /e)",
    "  /do <text> -- narrate the scene for everyone nearby",
    "  /melong /dolong -- same as /me and /do, but heard/seen at yell range",
    "  /you <feeling> -- a private note of how you're feeling; only you see it",
    "  /tell <name> <message> -- address someone directly (or /t)",
    "  /roll 2d6 -- roll dice; the result lands in OOC (or /r)",
    "  /bio <text> -- the line shown under your name (or /tagline)",
    "  /hue #RRGGBB or /hue r,g,b -- the color your name speaks in (/hue reset to undo)",
    "  /ooc <message> -- out-of-character, heard nearby (or /o)",
    "  /all <message> -- out-of-character, the whole server hears",
    "  /lang -- your languages; /lex -- words you've picked up; /comp -- how much you follow",
    "  /forget -- start your character's languages over",
    "  /ll -- switch back to your previous language; @<language> at the start of a " ..
        "message speaks just that line in another (e.g. @french bonjour)",
}

--[[
    Answer bare command forms and /mc locally
    @param text  Raw input text (starts with "/", unknown to parsePrefix)
    @return true if handled (feedback printed), false to fall through
]]
local function handleLocalCommand(text)
    local cmd = text:lower():match("^%s*(.-)%s*$")

    -- /mc, /mc help: command discovery
    if cmd == "/mc" or cmd == "/mc help" then
        for _, line in ipairs(TAZC_HELP) do
            localSysMsg(line)
        end
        -- Staff-only extra (cosmetic gate -- the server owns the real one).
        local level = localAccessLevel()
        if level and level ~= "none" then
            localSysMsg("  /event <narration> -- narrate an event, heard at double yell range (admin)")
        end
        dbg("handleLocalCommand: printed /mc help")
        return true
    end

    -- Bare /bio (or /tagline): open your own character sheet -- the familiar old
    -- verb now opens the fuller editor (tagline + description + your full body).
    -- /bio <text> still quick-sets the tagline (handled in send()).
    if cmd == "/bio" or cmd == "/tagline" then
        local player = getPlayer()
        if player then
            local ok, TAZC_CharacterSheet = pcall(require, "TAZC_CharacterSheet")
            if ok and TAZC_CharacterSheet then
                TAZC_CharacterSheet.open(player)
            else
                localSysMsg("Usage: /bio <text> -- the line shown under your name.")
            end
        end
        dbg("handleLocalCommand: bare /bio -> character sheet")
        return true
    end

    local usage = BARE_USAGE[cmd]
    if usage then
        localSysMsg(usage)
        dbg("handleLocalCommand: usage for %s", cmd)
        return true
    end

    return false
end

-- ============================================================================
-- SEND MESSAGE
-- ============================================================================

--[[
    Process chat input and send to server
    @param text  Raw input text (may include command prefix)
]]
function TAZC_Input.send(text)
    if not text or text == "" then
        dbg("send: empty text")
        return
    end
    if not isClient() then
        dbg("send: not client")
        return
    end

    -- Add to command history (commands like /lang included -- see
    -- TAZC_InputHistory.lua header; only text that actually reaches send()
    -- counts as "sent")
    inputHistory:add(text)
    
    -- Parse any command prefix
    local channel, message = parsePrefix(text)
    
    -- Use current channel if no prefix
    if not channel then
        channel = TAZC_Input.channel
    end
    
    dbg("send: [%s] %s", channel, message:sub(1, 30))
    
    -- Special handling for bio/tagline command
    if channel == "bio" then
        local TAZC_Bio = require("TAZC_Bio")
        TAZC_Bio.saveTagline(message)
        return
    end
    
    -- Special handling for dice roll command
    -- Rolls dice and sends result to OOC channel
    if channel == "roll" then
        -- Check if OOC is enabled (rolls go to OOC)
        if not TAZC_Config.Channels.oocEnabled then
            dbg("send: roll blocked - OOC disabled")
            localSysMsg("Dice rolls go out over OOC, and OOC chat is disabled on this server.", {255, 100, 100})
            return
        end
        local resultStr, total, isCrit, isFumble = rollDice(message)
        if resultStr then
            -- Send as OOC with special roll flag for coloring
            sendClientCommand("TAZC", "ChatMessage", {
                channel = "ooc",
                message = resultStr,
                isRoll = true,
                rollTotal = total,
                isCrit = isCrit,
                isFumble = isFumble,
                radioEmitters = {},
            })
            dbg("send: dice roll -> %s (crit=%s, fumble=%s)", resultStr, tostring(isCrit), tostring(isFumble))
        else
            -- Invalid notation - show local usage instead of eating the input
            dbg("send: invalid dice notation '%s'", message)
            localSysMsg("Couldn't read that roll -- try /roll 2d6 or /roll d20+3.", {255, 100, 100})
        end
        return
    end
    
    -- Special handling for /event (admin narration, v8.16.2). The access
    -- check here is UX only -- it spares non-admins a round-trip and
    -- answers them kindly; the authoritative gate lives in TAZC_Server's
    -- processMessage. Fail-open: when the level can't be read (nil), send
    -- anyway and let the server decide. Sent with no radio emitters --
    -- narration is storytelling, not sound, so no hot mic picks it up.
    if channel == "event" then
        if localAccessLevel() == "none" then
            dbg("send: /event blocked locally (no staff access)")
            localSysMsg("The event voice belongs to the server's storytellers -- /event is for admins.")
            return
        end
        sendClientCommand("TAZC", "ChatMessage", {
            channel = "event",
            message = message,
            radioEmitters = {},
        })
        dbg("send: /event narration sent (%d chars)", #message)
        return
    end

    -- OOC/ALL sandbox gates are server-side only (v8.16.2). TAZC_Server's
    -- processMessage rejects a disabled channel and answers the sender with
    -- a friendly SystemMessage; a client-side early return here would
    -- swallow the message with no feedback at all.

    -- Find all radios that would emit this speech
    local radioEmitters = {}
    local player = getPlayer()
    if player then
        local voiceRange = TAZC_Config.Ranges[channel] or TAZC_Config.Ranges.say
        local emitters = TAZC_Radio.findPlayerEmitters(player, voiceRange)
        
        -- Serialize emitter data for server
        for _, e in ipairs(emitters) do
            table.insert(radioEmitters, {
                frequency = e.frequency,
                source = e.source,
                position = e.position,
                transmitRange = e.transmitRange,
            })
            dbg("send: emitter on freq %d source=%s", e.frequency, e.source)
        end
        
        if #radioEmitters == 0 then
            dbg("send: no active radio emitters")
        end
    end
    
    -- Send to server
    sendClientCommand("TAZC", "ChatMessage", {
        channel = channel,
        message = message,
        radioEmitters = radioEmitters,
    })
    
    dbg("send: sendClientCommand called")
end

-- ============================================================================
-- TYPING INDICATOR
-- ============================================================================

local function broadcastTyping()
    if not isClient() then return end
    
    local now = TAZC_Core.getTimeMs()
    if now - lastTypingBroadcast < TYPING_THROTTLE_MS then return end
    
    lastTypingBroadcast = now
    
    dbg("broadcastTyping: sending typing packet")
    
    sendClientCommand("TAZC", "Typing", {
        channel = TAZC_Input.channel,
    })
end

-- ============================================================================
-- ISCHAT HOOKS
-- ============================================================================

--[[
    Lift the vanilla chat input box past its native ~250-char ceiling to the
    configured MaxMessageLength. Terror AustraliZ Chat reads straight from this box
    (interceptCommand) and sends through its own server path, so this setter is
    what actually lets players TYPE longer; the server cap only backstops a
    tampered client.

    Safe to call repeatedly and before the box exists (guarded -> no-ops). Read
    live from TAZC_Config so it reflects whatever value is current, which is why
    TAZC_Client re-calls it after the OnConnected sandbox sync -- the box is
    hooked before the server's configured value arrives in MP.
]]
function TAZC_Input.applyChatBoxMaxLength()
    if ISChat and ISChat.instance and ISChat.instance.textEntry
       and ISChat.instance.textEntry.setMaxTextLength then
        ISChat.instance.textEntry:setMaxTextLength(TAZC_Config.MaxMessageLength)
        dbg("applyChatBoxMaxLength: chat box max length set to %d", TAZC_Config.MaxMessageLength)
    end
end

local function hookISChat()
    if not ISChat or not ISChat.instance then 
        dbg("hookISChat: ISChat.instance not found")
        return 
    end
    
    dbg("hookISChat: ISChat.instance exists")
    
    -- Store original handlers
    local original_textEntry_onCommandEntered = nil
    local original_ISChat_onCommandEntered = nil

    -- Server-side intercepted commands that aren't channel prefixes -- they
    -- start with `/` but parsePrefix doesn't know them (it's channels only),
    -- and vanilla doesn't know them either. TAZC_Server.processMessage handles
    -- them server-side after they arrive as a normal ChatMessage. Without
    -- this check the conditional in interceptCommand drops them to vanilla,
    -- vanilla silently discards them, and the server never sees the input.
    -- Single-sourced from TAZC_Core.SERVER_SLASH_COMMANDS -- see that
    -- constant's own comment; TAZC_Server's SLASH_HANDLERS keys are built
    -- from the exact same array, so the two can't hand-drift apart.
    local function isMCServerCommand(text)
        if not text or text:sub(1, 1) ~= "/" then return false end
        local lower = text:lower()
        local spaceIdx = lower:find(" ", 1, true)
        local cmdWord = spaceIdx and lower:sub(1, spaceIdx - 1) or lower
        for _, cmd in ipairs(TAZC_Core.SERVER_SLASH_COMMANDS) do
            if cmdWord == cmd then return true end
        end
        return false
    end

    -- Core intercept function - returns true if we handled it
    local function interceptCommand(chatInstance)
        local text = chatInstance.textEntry:getText()
        dbg("interceptCommand: text = %s", tostring(text))
        
        if text and text ~= "" then
            local channel, _ = parsePrefix(text)
            
            -- Route through Terror AustraliZ Chat if it's our channel prefix, a
            -- server-intercepted MC command, or plain text. Unknown `/` prefixes
            -- still fall through to vanilla.
            if channel or not text:match("^/") or isMCServerCommand(text) then
                dbg("interceptCommand: routing through Terror AustraliZ Chat [%s]", tostring(channel))
                TAZC_Input.send(text)
                chatInstance.textEntry:setText("")
                pendingUnfocus = true
                lastMessageSentTime = TAZC_Core.getTimeMs()
                return true  -- We handled it
            elseif handleLocalCommand(text) then
                -- Bare command form ("/roll", "/tell") or /mc help: answered
                -- locally with a usage line, nothing to send.
                dbg("interceptCommand: handled locally (bare command)")
                chatInstance.textEntry:setText("")
                pendingUnfocus = true
                lastMessageSentTime = TAZC_Core.getTimeMs()
                return true  -- We handled it
            else
                dbg("interceptCommand: passing to vanilla (unrecognized / prefix)")
            end
        end
        
        return false  -- Let vanilla handle it
    end
    
    -- ========================================
    -- Hook ISChat:onCommandEntered (class-level)
    -- This fires FIRST in vanilla when Enter is pressed
    -- ========================================
    if ISChat.onCommandEntered then
        original_ISChat_onCommandEntered = ISChat.onCommandEntered
        dbg("hookISChat: found ISChat.onCommandEntered, hooking")
        
        ISChat.onCommandEntered = function(self)
            dbg("ISChat.onCommandEntered: FIRED!")
            
            -- Try to intercept
            if interceptCommand(self) then
                dbg("ISChat.onCommandEntered: intercepted by Terror AustraliZ Chat")
                return  -- Don't call vanilla
            end
            
            -- Fall through to vanilla
            if original_ISChat_onCommandEntered then
                dbg("ISChat.onCommandEntered: calling original")
                original_ISChat_onCommandEntered(self)
            end
            
            pendingUnfocus = true
            lastMessageSentTime = TAZC_Core.getTimeMs()
        end
    else
        dbg("hookISChat: ISChat.onCommandEntered not found (instance-based?)")
    end
    
    -- ========================================
    -- Hook instance.onCommandEntered (instance-level) 
    -- Some versions use this instead of class-level
    -- ========================================
    if ISChat.instance.onCommandEntered and not original_ISChat_onCommandEntered then
        local original_instance_onCommandEntered = ISChat.instance.onCommandEntered
        dbg("hookISChat: found ISChat.instance.onCommandEntered, hooking")
        
        ISChat.instance.onCommandEntered = function(self)
            dbg("ISChat.instance.onCommandEntered: FIRED!")
            
            if interceptCommand(self) then
                dbg("ISChat.instance.onCommandEntered: intercepted")
                return
            end
            
            if original_instance_onCommandEntered then
                original_instance_onCommandEntered(self)
            end
            
            pendingUnfocus = true
            lastMessageSentTime = TAZC_Core.getTimeMs()
        end
    end
    
    -- ========================================
    -- Hook textEntry.onCommandEntered (deepest level)
    -- Backup hook in case the above don't catch it
    -- ========================================
    if ISChat.instance.textEntry then
        -- Raise the vanilla chat box past its native ~250 ceiling. See
        -- TAZC_Input.applyChatBoxMaxLength -- re-applied after the sandbox sync
        -- (TAZC_Client OnConnected), since this hook runs before that lands.
        TAZC_Input.applyChatBoxMaxLength()

        original_textEntry_onCommandEntered = ISChat.instance.textEntry.onCommandEntered
        dbg("hookISChat: original textEntry.onCommandEntered = %s", tostring(original_textEntry_onCommandEntered))

        ISChat.instance.textEntry.onCommandEntered = function()
            dbg("textEntry.onCommandEntered: FIRED!")
            
            if interceptCommand(ISChat.instance) then
                dbg("textEntry.onCommandEntered: intercepted")
                return
            end
            
            if original_textEntry_onCommandEntered then
                dbg("textEntry.onCommandEntered: calling original")
                original_textEntry_onCommandEntered()
            end
            
            pendingUnfocus = true
            lastMessageSentTime = TAZC_Core.getTimeMs()
        end
        dbg("hookISChat: hooked textEntry.onCommandEntered")
    else
        dbg("hookISChat: ERROR - textEntry not found!")
    end
    
    -- Hook onTextChange for typing indicator
    if ISChat.instance.textEntry then
        dbg("hookISChat: hooking onTextChange for typing")
        local textEntry = ISChat.instance.textEntry
        local original_onTextChange = textEntry.onTextChange
        
        textEntry.onTextChange = function(self)
            if original_onTextChange then
                original_onTextChange(self)
            end
            
            local text = self:getText()
            if text and text ~= "" then
                local channel, _ = parsePrefix(text)
                -- Event narration composes in silence: typing dots over one
                -- head would point every onlooker at the narrator the server
                -- keeps nameless (see TAZC_Server's /event identity scrub).
                if (channel and channel ~= "event") or not text:match("^/") then
                    broadcastTyping()
                end
            end
        end
        
        -- ========================================
        -- Hook textEntry.onPressUp / onPressDown for command history, and
        -- onOtherKey for Ctrl-A select-all.
        --
        -- CORRECTED 2026-07-08 (live-test bug): a focused ISTextEntryBox has
        -- NO "onKeyStart" callback in this engine at all -- that name only
        -- exists as the global Events.OnKeyStartPressed event (see
        -- ISUIHandler.lua/ISVehicleMenu.lua/ISWorldMap.lua's
        -- onKeyStartPressed handlers in vanilla), never as a per-widget
        -- method any Java code invokes. The previous hook here
        -- (`textEntry.onKeyStart = function(self, key) ... end`, shipped
        -- since 0.7.9.4) set a table field nothing ever called -- silently
        -- dead from day one, which is exactly why it never threw and never
        -- worked: Up/Down, Ctrl-A, and the Escape-reset branch it carried
        -- all lived inside a function the engine never invokes.
        --
        -- The real seam: vanilla's OWN ISChat (Chat/ISChat.lua) wires its
        -- built-in chat-log recall through two dedicated per-instance
        -- callbacks Java calls directly on a focused textEntry --
        -- `onPressUp` (Up arrow) and `onPressDown` (Down arrow) -- see
        -- ISChat:initialise() (`self.textEntry.onPressUp = ISChat.onPressUp`
        -- etc.) and ISChat:onPressUp/onPressDown's own log-cycling body.
        -- Left/Right/Home/caret movement stay purely native (no Lua hook
        -- either side ever sees them). Escape already works today via the
        -- separate, real ISChat.instance.onKeyPress override below (a
        -- genuine, widely-used per-window seam -- see e.g.
        -- ISVehicleSeatUI:onKeyPress, TileGeometryEditor:onKeyPress in
        -- vanilla), which already calls inputHistory:reset(); the dead
        -- onKeyStart Escape branch was redundant even before it was inert.
        -- ========================================

        -- REPLACED, not chained -- deliberately. The originals here are
        -- vanilla's own ISChat.onPressUp/onPressDown, which cycle
        -- chatText.log -- a log only ISChat:logChatCommand populates, and
        -- MC's interceptCommand returns before vanilla's onCommandEntered
        -- can ever reach it, so under Terror AustraliZ Chat that log is permanently
        -- empty. Against an empty log the vanilla originals aren't neutral:
        -- onPressDown's else-branch calls setText("") -- so falling through
        -- on "not browsing" would WIPE an in-progress draft on a stray Down
        -- press. onPressUp's empty-log path happens to no-op, but both are
        -- replaced outright for the same reason: MC owns recall on this box,
        -- and a nil from the ring means "leave the box exactly as it is".
        textEntry.onPressUp = function(self)
            local historyText = inputHistory:up(self:getText())
            if historyText then
                dbg("HISTORY UP: set '%s'", historyText:sub(1, 30))
                self:setText(historyText)
            end
        end

        textEntry.onPressDown = function(self)
            local historyText = inputHistory:down()
            if historyText ~= nil then
                dbg("HISTORY DOWN: set '%s'", historyText:sub(1, 30))
                self:setText(historyText)
            end
        end
        dbg("hookISChat: hooked textEntry.onPressUp/onPressDown for command history")

        -- CTRL-A - select all input text (real widget selection --
        -- selectAll() -> javaObject:selectAll(), the same call ISComboBox's
        -- editor and the debug teleport UI already use). Wired over
        -- onOtherKey, the one per-textEntry key seam vanilla's own ISChat
        -- demonstrably uses live today (ISChat.onOtherKey checks
        -- Keyboard.KEY_ESCAPE the same way) -- chained so that existing
        -- Escape-unfocus behavior survives underneath. isCtrlKeyDown() is
        -- the same vanilla engine global ISInventoryPane uses for its own
        -- Ctrl-A select-all. GLFW_KEY_A = 65.
        local KEY_A = (Keyboard and Keyboard.KEY_A) or 65
        local original_textEntry_onOtherKey = textEntry.onOtherKey
        textEntry.onOtherKey = function(self, key)
            if key == KEY_A and isCtrlKeyDown and isCtrlKeyDown() then
                dbg("CTRL-A: select-all")
                if self.selectAll then
                    safeExec(function() self:selectAll() end)
                end
                return
            end
            if original_textEntry_onOtherKey then
                return original_textEntry_onOtherKey(self, key)
            end
        end
        dbg("hookISChat: hooked textEntry.onOtherKey for Ctrl-A select-all")
    end
    
    -- ========================================
    -- B42 ESCAPE KEY FIX
    -- Override unfocus entirely - vanilla is broken
    -- ========================================
    ISChat.instance.unfocus = function(self)
        dbg("unfocus: OVERRIDE - forcing complete unfocus")
        
        if self.textEntry then
            safeExec(function() self.textEntry:setText("") end)
            safeExec(function() self.textEntry:setEditable(false) end)
            if self.textEntry.unfocus then
                safeExec(function() self.textEntry:unfocus() end)
            end
        end

        self.focused = false

        if self.textEntry and self.textEntry.onFocusLost then
            safeExec(function() self.textEntry:onFocusLost() end)
        end

        if ISUIElement and ISUIElement.setKeyboardFocus then
            safeExec(function() ISUIElement.setKeyboardFocus(nil) end)
        end

        if UIManager and UIManager.setModalWindow then
            safeExec(function() UIManager.setModalWindow(nil) end)
        end
        
        dbg("unfocus: complete, focused=%s", tostring(self.focused))
    end
    dbg("hookISChat: replaced unfocus")
    
    -- ========================================
    -- KEY HANDLER (ESCAPE + HISTORY)
    -- ========================================
    local original_onKeyPress = ISChat.instance.onKeyPress
    ISChat.instance.onKeyPress = function(self, key)
        -- Escape key - use Keyboard constant for B42 GLFW
        if key == Keyboard.KEY_ESCAPE and self.focused then
            dbg("onKeyPress: ESCAPE - unfocusing")
            inputHistory:reset()
            self:unfocus()
            return true
        end
        
        -- History navigation is handled at textEntry.onPressUp/onPressDown level
        
        if original_onKeyPress then
            return original_onKeyPress(self, key)
        end
    end
    dbg("hookISChat: hooked onKeyPress")
    
    dbg("hookISChat: === HOOKS INSTALLED ===")
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function OnGameStart()
    dbg("OnGameStart: called")
    if ISChat and ISChat.instance then
        dbg("OnGameStart: hooking now")
        hookISChat()
        isHooked = true
    else
        dbg("OnGameStart: ISChat not ready, will try on tick")
    end
end

local function OnTick()
    -- Delayed hook if not done at game start
    if not isHooked and ISChat and ISChat.instance then
        dbg("OnTick: hooking now")
        hookISChat()
        isHooked = true
    end
    
    -- Process delayed unfocus
    if pendingUnfocus and ISChat and ISChat.instance then
        dbg("OnTick: processing pendingUnfocus")
        safeExec(function()
            ISChat.instance:unfocus()
        end)
        pendingUnfocus = false
    end
end

local function OnKeyPressed(key)
    if not ISChat or not ISChat.instance then return end
    
    -- Escape backup handler
    if key == 1 and ISChat.instance.focused then
        dbg("OnKeyPressed: ESCAPE backup - scheduling unfocus")
        pendingUnfocus = true
        return
    end
    
    -- Don't intercept if already focused
    if ISChat.instance.focused then return end
    
    -- Don't intercept in main menu
    if MainScreen and MainScreen.instance and MainScreen.instance:isVisible() then return end
    
    local player = getPlayer()
    if not player then return end
    
    -- Chat toggle keys
    local toggleKey = getCore():getKey("Toggle chat")
    local altToggleKey = getCore():getKey("Alt toggle chat")
    
    -- Cooldown check for Enter - prevents reopening immediately after send
    if key == 28 then  -- 28 = Enter
        local now = TAZC_Core.getTimeMs()
        if (now - lastMessageSentTime) < ENTER_COOLDOWN_MS then
            dbg("OnKeyPressed: Enter ignored (cooldown)")
            return
        end
    end
    
    if key == toggleKey or key == altToggleKey or key == 28 then  -- 28 = Enter
        ISChat.instance:focus()
        return
    end
    
    -- Slash key - open with "/" prefix
    if key == 53 then  -- KEY_SLASH
        ISChat.instance:focus()
        if ISChat.instance.textEntry then
            ISChat.instance.textEntry:setText("/")
        end
        return
    end
    
    -- Q-Shout: diagnostic tripwire only -- confirms the keybind fired while
    -- chat was unfocused. This branch doesn't consume the key or suppress
    -- anything; the real suppression is TAZC_Client's hookWorldMessage
    -- (its ISWorldMessage.addMessage override intercepts the resulting
    -- vanilla floating-text callout and reroutes it into MC's own panel).
    local shoutKey = getCore():getKey("Shout")
    if key == shoutKey then
        if not ISChat.instance.focused then
            dbg("Q-SHOUT: observed (suppression handled in TAZC_Client)")
        end
    end
end

local function OnKeyKeepPressed(key)
    if key == 1 and ISChat and ISChat.instance and ISChat.instance.focused then
        dbg("OnKeyKeepPressed: ESCAPE held - scheduling unfocus")
        pendingUnfocus = true
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

Events.OnGameStart.Add(OnGameStart)
Events.OnTick.Add(OnTick)
Events.OnKeyPressed.Add(OnKeyPressed)
Events.OnKeyKeepPressed.Add(OnKeyKeepPressed)

dbg("=== TAZC_Input module loaded ===")

return TAZC_Input
