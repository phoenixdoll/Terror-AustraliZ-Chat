--[[
================================================================================
    Terror AustraliZ Chat - Core Module
    
    Single source of truth for version, debug configuration, and shared
    utilities used across client/server/shared modules.
    
    ARCHITECTURE NOTE:
    This module is loaded by require() before any other TAZC_* module.
    All cross-cutting concerns live here to avoid duplication.
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = {}

-- ============================================================================
-- VERSION
-- CANONICAL source of truth for Terror AustraliZ Chat's version.
-- At release time, propagate this value to:
--   - mod.info (modversion line)
--   - 42/mod.info (modversion line -- Build 42 manifest; easy to miss)
--   - README.md (Version: line)
--   - CHANGELOG.md (close [Unreleased] and tag with the new version)
-- ============================================================================

TAZC_Core.VERSION = "0.8.16.8"
TAZC_Core.VERSION_NAME = "Babel"
TAZC_Core.BUILD_DATE = "2026-07-07"

-- ============================================================================
-- DEBUG CONFIGURATION
-- ============================================================================

-- Master debug toggle. Off for releases; on for development sessions only.
-- When this is true, per-module flags in DEBUG_MODULES are consulted; when
-- false, all dbg() calls short-circuit at the top of TAZC_Core.debugger.
TAZC_Core.DEBUG = false

-- Per-module debug flags (only checked if DEBUG is true).
--
-- Registration contract: every TAZC_Core.debugger("X") caller needs its "X" key
-- present here, or dbg() is a silent, permanent no-op for that module no
-- matter what DEBUG is set to. Either add the key here when a module starts
-- calling TAZC_Core.debugger(), or have the module self-register at load time
-- the way TAZC_AvatarIO.lua does at its own top: an `if
-- TAZC_Core.DEBUG_MODULES.AVATAR == nil then ... end` guard right after its
-- require block (shared by TAZC_AvatarIO, TAZC_Avatar, TAZC_AvatarServer,
-- TAZC_AvatarWindow, so none of them owns the shared hotspot below).
TAZC_Core.DEBUG_MODULES = {
    CONFIG    = true,  -- TAZC_Config.lua
    RADIO     = true,  -- TAZC_Radio.lua
    SERVER    = true,  -- TAZC_Server.lua
    CLIENT    = true,  -- TAZC_Client.lua
    BUBBLE    = true,  -- TAZC_Bubble.lua
    PANEL     = true,  -- TAZC_ChatPanel.lua
    INPUT     = true,  -- TAZC_Input.lua
    INPUTHIST = true,  -- TAZC_InputHistory.lua
    TYPING    = true,  -- TAZC_Typing.lua
    BIO       = true,  -- TAZC_Bio.lua
    ANON      = true,  -- TAZC_Anonymity.lua
    LANG      = true,  -- TAZC_Lang.lua (server, language assignment + render)
    LANG_ACQ  = true,  -- TAZC_Acquisition.lua (per-user vocabulary exposure)
    PERSIST   = true,  -- TAZC_Persist.lua (A/B crash-safe save layer)
    SHEET     = true,  -- TAZC_CharacterSheet.lua
    CULTURAL  = true,  -- TAZC_Cultural.lua
    TEACHING  = true,  -- TAZC_Teaching.lua
    LANGADMIN = true,  -- TAZC_LangAdmin.lua
}

-- ============================================================================
-- SERVER-INTERCEPTED SLASH COMMANDS
-- The command words TAZC_Server.lua's SLASH_HANDLERS answers server-side --
-- not an ordinary channel prefix. TAZC_Input.lua's isMCServerCommand must
-- forward exactly these, or a client never reaches the server at all
-- (vanilla silently swallows an unrecognized "/" command). Single source
-- for both sides: client and server run in separate Lua states and never
-- share memory, so this array -- not a runtime handoff -- is what actually
-- holds across that boundary. Order matches TAZC_Server's SLASH_HANDLER_IMPLS
-- positionally; see that table's own comment.
-- ============================================================================
TAZC_Core.SERVER_SLASH_COMMANDS = { "/lang", "/lex", "/comp", "/forget", "/hue", "/translate", "/ll" }

--[[
    Conditional debug logger
    
    Usage:
        local dbg = TAZC_Core.debugger("RADIO")
        dbg("found %d emitters", count)
    
    Returns a function that only prints when DEBUG is enabled for that module.
    Supports string.format style arguments.
]]
function TAZC_Core.debugger(moduleName)
    return function(fmt, ...)
        if not TAZC_Core.DEBUG then return end
        if not TAZC_Core.DEBUG_MODULES[moduleName] then return end
        
        local msg = fmt
        if select("#", ...) > 0 then
            msg = string.format(fmt, ...)
        end
        
        print(string.format("Terror AustraliZ Chat [%s v%s]: %s", 
            moduleName, TAZC_Core.VERSION, tostring(msg)))
    end
end

-- ============================================================================
-- DISPLAY CONSTANTS
-- Named values for magic numbers used in positioning/rendering
-- ============================================================================

TAZC_Core.Display = {
    -- Vertical offset from world position to above-head bubble anchor
    -- This accounts for character sprite height at default zoom
    BUBBLE_OFFSET_PLAYER = 160,
    
    -- Vertical offset for ground-placed objects (radios on tables, etc.)
    BUBBLE_OFFSET_GROUND = 60,
    
    -- Additional Y adjustment after zoom calculation
    BUBBLE_Y_ADJUST = 21,
    
    -- Typing indicator positioning (relative to bubble position)
    TYPING_OFFSET_Y = 27,
    TYPING_WIDTH = 20,
    TYPING_HEIGHT = 6,
}

-- ============================================================================
-- COLOR CONVENTIONS
-- Named RGB triples for cross-module use. The L2 family is the v8.x
-- language-acquisition convention: SOFT_PURPLE marks acquired/comprehended
-- L2 content wherever it appears (chat bracket, /lex output, future gradient
-- render). When a partial-comprehension treatment lands in v8.5 phase 2, it
-- reuses SOFT_PURPLE at a lower alpha -- same family, less presence.
-- ============================================================================

TAZC_Core.Colors = {
    -- L2 acquisition family -- the v8.5 four-state render palette.
    -- ACQUIRED_FRESH: honey-gold "reward" for a freshly-learned word (full
    -- alpha once familiar; 0.25-0.75 anticipation alpha while still fresh).
    -- ACQUIRED_FAMILIAR: soft purple "settled aside" for words consolidated
    -- into baseline knowledge (0.85 alpha); also /lex's Native: color.
    -- INHERITED_GREY (v8.6): desaturated purple for cultural content a
    -- non-native can see but never acquire (0.65 alpha -- less present than
    -- peak anticipation, since unreachable ranks below approaching).
    ACQUIRED_FRESH    = {225, 195, 110},  -- honey-gold reward
    ACQUIRED_FAMILIAR = {180, 160, 210},  -- soft purple aside
    INHERITED_GREY    = {165, 155, 180},  -- v8.6 cultural / inherited

    -- Inline markup colors -- single source for parseColorSegments' defaults
    -- and TAZC_Config.ChannelColors' emote/mood entries.
    EMOTE_AMBER = {255, 190, 128},  -- *emote* asterisks
    MOOD_PURPLE = {174, 109, 181},  -- **mood** double-asterisks
}

-- True alias, not a second literal: shares ACQUIRED_FAMILIAR's actual table
-- (back-compat name for /lex's Native: line and any legacy reader).
TAZC_Core.Colors.SOFT_PURPLE = TAZC_Core.Colors.ACQUIRED_FAMILIAR

-- ============================================================================
-- SHARED UTILITIES
-- ============================================================================

--[[
    Parse text into colored segments for rendering
    
    Supports two inline styles:
    - *single asterisks* = emote color (actions, gestures)
    - **double asterisks** = mood color (internal thoughts, observations)
    
    @param text           The text to parse
    @param baseColor      {r, g, b} color for non-styled text (0-255)
    @param stripAsterisks If true and text has mixed content, remove markers but keep color
    @param emoteColor     Optional override for emote color (default soft amber)
    @param moodColor      Optional override for mood color (default purple/lavender)
    
    @return segments      Array of {text=, color=} chunks
    @return isPureStyled  True if entire text is a single *emote* or **mood**
    
    Example:
        parseColorSegments("Hello **thinking** and *waves*", {255,255,255}, true)
        => {{text="Hello ", color={255,255,255}}, 
            {text="thinking", color={174,109,181}},  -- mood, asterisks stripped
            {text=" and ", color={255,255,255}},
            {text="waves", color={255,190,128}}}     -- emote, asterisks stripped
]]
function TAZC_Core.parseColorSegments(text, baseColor, stripAsterisks, emoteColor, moodColor)
    local segments = {}
    emoteColor = emoteColor or TAZC_Core.Colors.EMOTE_AMBER
    moodColor = moodColor or TAZC_Core.Colors.MOOD_PURPLE
    
    if not text or text == "" then
        return segments, false
    end
    
    -- Check if pure styled (entire text is *something* or **something**)
    local trimmed = text:match("^%s*(.-)%s*$") or text
    local isPureEmote = trimmed:match("^%*[^*]+%*$") ~= nil
    local isPureMood = trimmed:match("^%*%*(.-)%*%*$") ~= nil and not trimmed:match("^%*%*.*%*%*.*%*%*$")
    local isPureStyled = isPureEmote or isPureMood
    
    -- Check if there's any non-styled content
    local hasNonStyled = false
    local testText = text:gsub("%*%*(.-)%*%*", ""):gsub("%*([^*]-)%*", "")
    if testText:match("%S") then hasNonStyled = true end
    
    -- Decide whether to strip asterisks
    local shouldStrip = stripAsterisks and hasNonStyled and not isPureStyled
    
    local pos = 1
    while pos <= #text do
        -- Check for double asterisk first (mood)
        if text:sub(pos, pos + 1) == "**" then
            -- Find closing **
            local searchPos = pos + 2
            local closePos = nil
            while searchPos <= #text - 1 do
                if text:sub(searchPos, searchPos + 1) == "**" then
                    closePos = searchPos
                    break
                end
                searchPos = searchPos + 1
            end
            
            if closePos then
                local content = text:sub(pos + 2, closePos - 1)
                if shouldStrip then
                    table.insert(segments, { text = content, color = moodColor })
                else
                    table.insert(segments, { text = "**" .. content .. "**", color = moodColor })
                end
                pos = closePos + 2
            else
                -- No closing ** - treat rest as normal text
                table.insert(segments, { text = text:sub(pos), color = baseColor })
                break
            end
        -- Check for single asterisk (emote)
        elseif text:sub(pos, pos) == "*" then
            -- Find closing * (but not **)
            local searchPos = pos + 1
            local closePos = nil
            while searchPos <= #text do
                if text:sub(searchPos, searchPos) == "*" then
                    -- Make sure it's not the start of **
                    if text:sub(searchPos, searchPos + 1) ~= "**" then
                        closePos = searchPos
                        break
                    else
                        -- Skip past the ** entirely
                        searchPos = searchPos + 2
                    end
                else
                    searchPos = searchPos + 1
                end
            end
            
            if closePos then
                local content = text:sub(pos + 1, closePos - 1)
                if shouldStrip then
                    table.insert(segments, { text = content, color = emoteColor })
                else
                    table.insert(segments, { text = "*" .. content .. "*", color = emoteColor })
                end
                pos = closePos + 1
            else
                -- No closing * - treat rest as normal text
                table.insert(segments, { text = text:sub(pos), color = baseColor })
                break
            end
        else
            -- Regular text - find next asterisk
            local nextAsterisk = text:find("%*", pos)
            if nextAsterisk then
                if nextAsterisk > pos then
                    table.insert(segments, { text = text:sub(pos, nextAsterisk - 1), color = baseColor })
                end
                pos = nextAsterisk
            else
                -- No more asterisks - rest is normal text
                if pos <= #text then
                    table.insert(segments, { text = text:sub(pos), color = baseColor })
                end
                break
            end
        end
    end
    
    return segments, isPureStyled
end

--[[
    Consolidate adjacent same-color chunks into single chunks
    
    Used after word-wrapping to minimize draw calls.
    
    @param words  Array of {text=, color=} where each is a single word
    @return       Array of {text=, color=} with adjacent same-color merged
]]
function TAZC_Core.consolidateChunks(words)
    if #words == 0 then 
        return {{text = "", color = {255, 255, 255}}} 
    end
    
    local chunks = {}
    local currentChunk = {text = words[1].text, color = words[1].color, alpha = words[1].alpha}
    
    for i = 2, #words do
        local word = words[i]
        -- Same color AND same alpha? Append to current chunk.
        -- Treat nil alpha as 1 for comparison (default render alpha).
        local sameColor = word.color[1] == currentChunk.color[1] and 
                          word.color[2] == currentChunk.color[2] and 
                          word.color[3] == currentChunk.color[3]
        local sameAlpha = (word.alpha or 1) == (currentChunk.alpha or 1)
        if sameColor and sameAlpha then
            currentChunk.text = currentChunk.text .. " " .. word.text
        else
            -- Different color or alpha - start new chunk (with leading space)
            table.insert(chunks, currentChunk)
            currentChunk = {text = " " .. word.text, color = word.color, alpha = word.alpha}
        end
    end
    
    table.insert(chunks, currentChunk)
    return chunks
end

--[[
    Get current time in milliseconds

    Wrapper around PZ's Calendar API for consistent time access.

    BUGFIX: Build 42.19 dedicated servers do not reliably expose the Java
    Calendar class to Lua, so a bare Calendar.getInstance() call can error
    on that build. Falls back to getTimestampMs() (B42.19's own vanilla
    chat-surface clock) and finally os.time()*1000 (older/leaner sandboxes;
    seconds resolution only) before giving up. Every source is validated
    (non-nil, non-NaN, finite, >= 0) so a corrupt read can't silently
    poison timestamps used for decay math, persistence, or cache expiry.
]]
function TAZC_Core.getTimeMs()
    local ok, milliseconds = pcall(function()
        return Calendar.getInstance():getTimeInMillis()
    end)
    if ok and type(milliseconds) == "number"
        and milliseconds == milliseconds
        and milliseconds ~= math.huge
        and milliseconds ~= -math.huge
        and milliseconds >= 0
    then
        return milliseconds
    end

    if type(getTimestampMs) == "function" then
        ok, milliseconds = pcall(getTimestampMs)
        if ok and type(milliseconds) == "number"
            and milliseconds == milliseconds
            and milliseconds ~= math.huge
            and milliseconds ~= -math.huge
            and milliseconds >= 0
        then
            return milliseconds
        end
    end

    if os and type(os.time) == "function" then
        local seconds
        ok, seconds = pcall(os.time)
        if ok and type(seconds) == "number"
            and seconds == seconds
            and seconds ~= math.huge
            and seconds ~= -math.huge
            and seconds >= 0
        then
            return math.floor(seconds * 1000)
        end
    end

    error("runtime clock unavailable")
end

--[[
    Safe wrapper for potentially failing operations
    
    @param fn       Function to call
    @param default  Value to return on error
    @return         Result of fn() or default
]]
function TAZC_Core.safe(fn, default)
    local ok, result = pcall(fn)
    if ok then return result end
    return default
end

--[[
    Nil-is-failure sibling of TAZC_Core.safe.

    TAZC_Core.safe treats a successful nil as a valid result and returns it
    unchanged. safeGet doesn't: a call that runs without error but hands
    back nil still falls back to `default`, same as an outright pcall
    failure. For a client UI reading engine getters, "the call errored" and
    "the call quietly returned nothing" both mean the same thing --
    nothing to show -- so callers that can't and needn't tell those apart
    get one substitution rule instead of two.

    @param fn       Function to call
    @param default  Value to return on error OR on a successful nil
    @return         Result of fn(), or default
]]
function TAZC_Core.safeGet(fn, default)
    local ok, result = pcall(fn)
    if ok and result ~= nil then return result end
    return default
end

--[[
    safeExec: run fn() purely for its side effect and report whether it
    succeeded. The nil-is-failure sibling of TAZC_Core.safe for calls with no
    meaningful return value (a sendClientCommand, an Events.*.Add). Returns
    the pcall error too, same order pcall itself uses, so a caller that
    wants to log what actually went wrong still can.

    @param fn  Function to call
    @return    ok (true/false), err (pcall's error value when ok is false)
]]
function TAZC_Core.safeExec(fn)
    local ok, err = pcall(fn)
    return ok, err
end

--[[
    Server-side admin gate check

    Returns true iff the player's access level reads back exactly "admin".
    Wraps the getAccessLevel() call in TAZC_Core.safe so a read failure
    defaults to "none" (non-admin) rather than erroring -- the same
    pcall-guarded shape every server-side admin gate re-implemented before
    this helper existed. No message sending, no other behavior -- callers
    own their own refusal text.

    @param player  IsoPlayer to check
    @return        true iff access level == "admin"
]]
function TAZC_Core.isAdmin(player)
    local accessLevel = TAZC_Core.safe(function() return player:getAccessLevel() end, "none")
    -- PZ access levels aren't reliably lowercase ("Admin" observed); normalize
    -- like TAZC_AvatarServer/TAZC_LangAdmin do.
    return tostring(accessLevel):lower() == "admin"
end

--[[
    Pure 2D Euclidean distance between two coordinate pairs.

    The one formula five call sites (TAZC_Server, TAZC_Anonymity, TAZC_Bio,
    TAZC_Radio x2) computed inline before this dedup. Each site keeps its OWN
    coordinate-fetch safety net (pcall / safeGet / TAZC_Core.safe, with
    differing nil-distance defaults) -- only the dx/dy/sqrt arithmetic
    itself is shared here.

    @param x1, y1  First point
    @param x2, y2  Second point
    @return        Straight-line distance (tiles)
]]
function TAZC_Core.distance2D(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

--[[
    Count entries in a table (works for non-array tables)
    
    @param t  Table to count
    @return   Number of entries
]]
function TAZC_Core.tableSize(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--[[
    isEmpty: test whether a table has no keys.
    
    Idiomatic Lua is `next(t) == nil`, but PZ's Kahlua VM doesn't expose the
    global `next` function -- it only exposes the iterator protocol via pairs().
    Calling `next(t)` directly results in "Object tried to call nil" because
    the `next` identifier resolves to nil in the sandbox.
    
    This helper uses a one-shot pairs() loop with an early return, giving the
    same answer as `next(t) == nil` without depending on the missing global.
    
    Cheaper than tableSize() when you only need emptiness: O(1) on non-empty,
    where tableSize is always O(n).
]]
function TAZC_Core.isEmpty(t)
    if not t then return true end
    for _ in pairs(t) do return false end
    return true
end

-- ============================================================================
-- MODULE INFO (for debugging/about screens)
-- ============================================================================

function TAZC_Core.getVersionString()
    return string.format("Terror AustraliZ Chat v%s (%s)", TAZC_Core.VERSION, TAZC_Core.VERSION_NAME)
end

function TAZC_Core.printBanner()
    print("================================================================================")
    print("  " .. TAZC_Core.getVersionString())
    print("  Build: " .. TAZC_Core.BUILD_DATE)
    print("  Debug: " .. (TAZC_Core.DEBUG and "ENABLED" or "disabled"))
    print("================================================================================")
end

return TAZC_Core
