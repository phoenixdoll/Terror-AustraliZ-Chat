--[[
================================================================================
    Terror AustraliZ Chat - Chat Panel
    
    Custom chat display using ISPanel with direct drawText rendering.
    Pre-computes display lines and caches them per tab for performance.
    
    ARCHITECTURE:
    - Messages are added via TAZC_ChatPanel.addMessage(msgData)
    - Each message is immediately converted to display lines
    - Display lines are cached per tab (General, Admin)
    - Scroll offset tracked per tab
    - Rendering draws from pre-computed cache
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Bio = require("TAZC_Bio")

local dbg = TAZC_Core.debugger("PANEL")

local TAZC_ChatPanel = ISPanel:derive("TAZC_ChatPanel")

-- Verb framing for signed modality (spec: "signs:" not "says:"). This
-- codebase's actual display convention IS the bracketed channel tag (there
-- is no literal "says:"/"whispers:" text anywhere), so the signing verb
-- lives there: a modality case beside the per-channel tag lookup, same
-- shape as TAZC_Config.Radio's style-by-channel pattern. Whisper/low/yell
-- carry the channel's own size/register (small close / guarded / big
-- emphatic signing); radio never reaches here (blocked server-side).
local SIGNED_CHANNEL_TAGS = {
    whisper = "[small signing]",
    low     = "[guarded signing]",
    say     = "[signs]",
    yell    = "[big signing]",
}

-- ============================================================================
-- STATE
-- ============================================================================

-- Display line storage (pre-computed, per tab)
-- Tab 1 = General (IC + OOC combined for now), Tab 2 = Admin (vanilla passthrough)
-- DEFERRED (Kialae, 2026-07-06): a proper, separate OOC tab needs a custom
-- tab injected into vanilla ISChat -- real UI work, not a docs-pass fix.
-- Until then Tab 1 stays the IC+OOC combination below; no functional gap,
-- just a coarser tab split than the long-term design wants.
local displayLinesByTab = {
    [1] = {},  -- General (IC + OOC) - say, whisper, yell, emote, ooc, all, etc.
    [2] = {},  -- Admin (vanilla passthrough, not used by us)
}
local scrollOffsetByTab = {[1]=0, [2]=0}
local maxMessages = TAZC_Config.Panel.maxMessages
local messageCountByTab = {[1]=0, [2]=0}

-- Raw message storage (for rewrap on resize)
local rawMessagesByTab = {
    [1] = {},  -- General
    [2] = {},  -- Admin
}

-- Track panel width for rewrap on resize
local lastPanelWidth = 0

-- =============================================================================
-- B42 TEXT RENDERING CONSTANTS
-- Based on analysis of B42 rendering pipeline constraints.
-- =============================================================================
-- MeasureStringX returns "advance width" (logical), not "bounding box" (visual).
-- Glyphs can extend 3-5px past their measured width (Right Side Bearing).
local GLYPH_BUFFER = 8

-- ISChat enforces internal borders that clip child content.
-- Standard B42 window borders are 6-12px. We use 12px to be safe.
local PARENT_BORDER_PADDING = 12

-- Scrollbar width (drawn at width-6, we give 8px clearance)
local SCROLLBAR_WIDTH = 8

-- Total safe padding from right edge
local WRAP_PADDING = SCROLLBAR_WIDTH + GLYPH_BUFFER + PARENT_BORDER_PADDING  -- Total: 28px

-- =============================================================================
-- SAFE TEXT MEASUREMENT
-- The "Space Hack" - append space to measurement to reserve overflow room.
-- =============================================================================
local function safeMeasureText(font, text)
    local tm = getTextManager()
    -- Measure with appended space to reserve room for glyph overhang
    return tm:MeasureStringX(font, text .. " ")
end

-- Internal contract: shared with TAZC_Bubble, which wraps text with the same
-- glyph-overhang hazard and needs this exact correction, not its own copy.
TAZC_ChatPanel._safeMeasureText = safeMeasureText

-- Channel to tab mapping
-- =============================================================================
-- TAB ROUTING
-- Maps channel names to tab indices:
--   Tab 1 = General - our panel renders this (all MC-managed channels)
--   Tab 2 = Admin   - vanilla passthrough (we do NOT render this)
-- 
-- Admin channel is intentionally NOT handled by Terror AustraliZ Chat as of 0.8.0.
-- Vanilla PZ has its own admin pipeline with access-level filtering; TAZC_Input
-- doesn't intercept /admin, and the addLineInChat hook lets admin vanilla
-- messages fall through to the original handler so vanilla's Admin tab
-- renders them. The entry below exists as a containment measure: if an admin
-- message somehow reaches our addMessage (out-of-band tool, older client),
-- route it to Tab 2 where our panel doesn't render it -- never to General.
-- =============================================================================
local channelToTab = {
    -- IC channels (Tab 1)
    say = 1,
    whisper = 1,
    yell = 1,
    low = 1,
    emote = 1,
    ["do"] = 1,
    emoteLong = 1,
    doLong = 1,
    mood = 1,
    me = 1,
    pm = 1,
    general = 1,
    radio = 1,
    faction = 1,
    safehouse = 1,
    
    -- OOC channels (Tab 1)
    ooc = 1,
    all = 1,
    system = 1,  -- Server messages, MOTD
    
    -- Admin (Tab 2 -- containment only, vanilla handles admin properly)
    admin = 2,
}

-- Current active tab
local currentTab = 1

-- Message ID counter
local nextMsgId = 1

-- ============================================================================
-- TEXT UTILITIES
-- ============================================================================

local function formatTime(timestamp)
    return os.date(TAZC_Config.Panel.timestampFormat, timestamp)
end

--[[
    Word wrap text to fit within maxWidth (single color version)
    @param text      Text to wrap
    @param font      UIFont to measure with
    @param maxWidth  Maximum line width in pixels
    @return Array of line strings
]]
local function wrapText(text, font, maxWidth)
    if not text or text == "" then return {""} end
    if maxWidth < 50 then maxWidth = 200 end
    
    local textManager = getTextManager()
    local lines = {}
    local currentLine = ""
    
    for word in text:gmatch("%S+") do
        local testLine = currentLine == "" and word or (currentLine .. " " .. word)
        -- Use safeMeasureText to account for glyph overhang (Space Hack)
        local testWidth = safeMeasureText(font, testLine)
        
        if testWidth > maxWidth and currentLine ~= "" then
            table.insert(lines, currentLine)
            currentLine = word
        else
            currentLine = testLine
        end
    end
    
    if currentLine ~= "" then
        table.insert(lines, currentLine)
    end
    
    if #lines == 0 then
        table.insert(lines, "")
    end

    return lines
end

-- Internal contract: shared with TAZC_Bubble (single-color emote/do bubbles)
-- and TAZC_CharacterSheet (per-paragraph description wrapping) -- this is the
-- one word-wrap loop; each caller supplies its own font/maxWidth, and
-- CharacterSheet layers its own paragraph split on top.
TAZC_ChatPanel._wrapWords = wrapText

--[[
    Word wrap with color segments preserved
    @param segments  Array of {text, color} from TAZC_Core.parseColorSegments
    @param font      UIFont to measure with
    @param maxWidth  Maximum line width in pixels
    @return Array of {chunks = [{text, color}, ...]} per line
]]
local function wrapTextWithColors(segments, font, maxWidth)
    if not segments or #segments == 0 then 
        return {{chunks = {{text = "", color = {255,255,255}}}}}
    end
    if maxWidth < 50 then maxWidth = 200 end
    
    local textManager = getTextManager()
    
    -- Flatten segments into words with color tags
    local words = {}
    for _, seg in ipairs(segments) do
        for word in seg.text:gmatch("%S+") do
            table.insert(words, {text = word, color = seg.color})
        end
    end
    
    if #words == 0 then
        return {{chunks = {{text = "", color = segments[1] and segments[1].color or {255,255,255}}}}}
    end
    
    -- Wrap words into lines
    local lines = {}
    local currentLineWords = {}
    local currentWidth = 0
    local spaceWidth = textManager:MeasureStringX(font, " ")
    
    for _, word in ipairs(words) do
        -- Use safeMeasureText for glyph overhang (Space Hack)
        local wordWidth = safeMeasureText(font, word.text)
        local neededWidth = wordWidth
        if #currentLineWords > 0 then
            neededWidth = neededWidth + spaceWidth
        end
        
        if currentWidth + neededWidth > maxWidth and #currentLineWords > 0 then
            -- Finish current line - consolidate same-color adjacent words
            table.insert(lines, {chunks = TAZC_Core.consolidateChunks(currentLineWords)})
            currentLineWords = {}
            currentWidth = 0
        end
        
        table.insert(currentLineWords, word)
        currentWidth = currentWidth + neededWidth
    end
    
    -- Don't forget last line
    if #currentLineWords > 0 then
        table.insert(lines, {chunks = TAZC_Core.consolidateChunks(currentLineWords)})
    end
    
    if #lines == 0 then
        table.insert(lines, {chunks = {{text = "", color = {255,255,255}}}})
    end
    
    return lines
end

-- Internal contract: shared with TAZC_Bubble (multi-segment colored speech/do
-- bubbles need the exact same wrap-then-consolidate behavior, not their own
-- copy) -- this is the one color-segment word-wrap loop, same pattern as
-- the _wrapWords exposure above.
TAZC_ChatPanel._wrapTextWithColors = wrapTextWithColors

-- ============================================================================
-- DISPLAY LINE COMPUTATION
-- ============================================================================

--[[
    Shared shape for the three narration-style channels below (emote, do,
    mood): a single wrapped block with no visible tag or name (isEmote
    blanks both at render) -- only the text each channel builds differs.
    NOT used for event/dice-roll/standard: each of those carries a real
    difference this shape doesn't fit (event's extra tag-width term,
    dice-roll's colored chunks, standard's real name + chunks).
]]
local function narrationLines(text, msg, tagColor, font, textManager, panelWidth, margin)
    local timeStr = formatTime(msg.timestamp) .. " "

    local prefixWidth = textManager:MeasureStringX(font, timeStr)
    local availableWidth = panelWidth - margin * 2 - prefixWidth - WRAP_PADDING
    if availableWidth < 50 then availableWidth = 200 end

    local wrappedLines = wrapText(text, font, availableWidth)

    local displayLines = {}
    for lineIdx, lineText in ipairs(wrappedLines) do
        table.insert(displayLines, {
            isFirstLine = (lineIdx == 1),
            isEmote = true,
            text = lineText,
            tagColor = tagColor,
            tag = "",
            timeStr = timeStr,
            nameStr = "",
            prefixWidth = prefixWidth,
            playerColor = msg.playerColor,
            msgId = msg.msgId,
        })
    end

    return displayLines
end

--[[
    Compute display lines for a single message
    Handles different formats: standard, emote, do, mood, radio
]]
local function computeMessageLines(msg, panelWidth, margin)
    local textManager = getTextManager()
    local font = UIFont.Medium
    
    local tagColor = TAZC_Config.ChannelColors[msg.channel] or {200, 200, 200}
    local tag = TAZC_Config.ChannelTags[msg.channel] or "[" .. msg.channel .. "]"

    -- Signed modality (R-A1/verb framing): swap the tag, never the body --
    -- so a user *emote* inside a signed message round-trips untouched.
    if msg.modality == "signed" then
        tag = SIGNED_CHANNEL_TAGS[msg.channel] or tag
    end

    -- Radio messages: show frequency + original volume tag
    if msg.channel == "radio" and msg.frequency then
        local mhz = msg.frequency / 1000
        local volumeTag = ""
        if msg.originalChannel then
            volumeTag = " " .. (TAZC_Config.ChannelTags[msg.originalChannel] or "[" .. msg.originalChannel .. "]")
        end
        tag = string.format("[%.1fMHz]%s", mhz, volumeTag)
        tagColor = TAZC_Config.ChannelColors.radio or {120, 220, 200}
    end
    
    -- ========================================
    -- EMOTE FORMAT: *CharacterName action*
    -- ========================================
    if msg.channel == "emote" or msg.channel == "emoteLong" then
        local emoteText = "*" .. msg.characterName .. " " .. msg.message .. "*"
        return narrationLines(emoteText, msg, tagColor, font, textManager, panelWidth, margin)
    end

    -- ========================================
    -- DO FORMAT: Environment narration
    -- ========================================
    if msg.channel == "do" or msg.channel == "doLong" then
        return narrationLines(msg.message, msg, tagColor, font, textManager, panelWidth, margin)
    end

    -- ========================================
    -- EVENT FORMAT: Admin event narration (v8.16.2)
    -- Styled like /do -- no speaker, no colon -- but keeping the [Event]
    -- tag out front. The server scrubs the narrator's identity (name,
    -- color, coords), so only the tag and the words remain.
    -- ========================================
    if msg.channel == "event" then
        local timeStr = formatTime(msg.timestamp) .. " "

        local prefixWidth = textManager:MeasureStringX(font, timeStr)
            + textManager:MeasureStringX(font, tag .. " ")
        local availableWidth = panelWidth - margin * 2 - prefixWidth - WRAP_PADDING
        if availableWidth < 50 then availableWidth = 200 end

        local wrappedLines = wrapText(msg.message, font, availableWidth)

        local displayLines = {}
        for lineIdx, lineText in ipairs(wrappedLines) do
            table.insert(displayLines, {
                isFirstLine = (lineIdx == 1),
                text = lineText,
                tagColor = tagColor,
                tag = tag,
                timeStr = timeStr,
                nameStr = "",
                prefixWidth = prefixWidth,
                playerColor = msg.playerColor,
                msgId = msg.msgId,
            })
        end

        return displayLines
    end

    -- ========================================
    -- MOOD FORMAT: Internal monologue
    -- ========================================
    if msg.channel == "mood" then
        local moodText = "You " .. msg.message
        return narrationLines(moodText, msg, tagColor, font, textManager, panelWidth, margin)
    end
    
    -- ========================================
    -- DICE ROLL FORMAT: Colorful roll result
    -- Format: "4d10+4: [3, 7, 2, 9] + 4 = 25"
    -- ========================================
    if msg.isRoll then
        local timeStr = formatTime(msg.timestamp) .. " "
        local nameStr = msg.characterName .. " "
        
        -- Parse the roll result string to colorize parts
        -- Expected: "XdY+Z: [rolls] + mod = total" or "XdY+Z: [rolls] + mod = total - NAT XX!"
        local mainPart, critIndicator = msg.message:match("^(.+)%s*%-%s*(NAT%s*%d+!)$")
        if not mainPart then
            mainPart = msg.message
            critIndicator = nil
        end
        
        local diceNotation, rollsStr, modPart = mainPart:match("^([^:]+):%s*(%[[^%]]+%])(.*)=%s*$")
        -- rollTotal is stored at message-build time (server-verified); no need
        -- to re-derive it from the formatted string.
        local total = msg.rollTotal

        -- Colors for different parts
        local rollsColor = {150, 220, 255}     -- Light blue for individual rolls
        local totalColor = {255, 215, 0}       -- Gold for total
        local modColor = {180, 180, 180}       -- Gray for modifier
        local diceColor = {200, 160, 255}      -- Purple for dice notation
        local textColor = tagColor             -- OOC tag color for "rolls"
        local critColor = {50, 255, 50}        -- Bright green for NAT 20
        local fumbleColor = {255, 80, 80}      -- Bright red for NAT 1
        
        -- Override total color based on crit/fumble
        if msg.isCrit then
            totalColor = critColor
        elseif msg.isFumble then
            totalColor = fumbleColor
        end
        
        local chunks = {}
        
        if diceNotation and rollsStr then
            -- "rolls " text
            table.insert(chunks, {text = "rolls ", color = textColor})
            -- Dice notation (4d10+4)
            table.insert(chunks, {text = diceNotation .. ": ", color = diceColor})
            -- Individual rolls [3, 7, 2, 9]
            table.insert(chunks, {text = rollsStr, color = rollsColor})
            -- Modifier part (+ 4 or - 2)
            if modPart and modPart ~= "" then
                table.insert(chunks, {text = modPart, color = modColor})
            end
            -- = and total
            table.insert(chunks, {text = "= ", color = textColor})
            table.insert(chunks, {text = tostring(total), color = totalColor})
            
            -- Crit/fumble indicator
            if critIndicator then
                local indicatorColor = msg.isCrit and critColor or fumbleColor
                table.insert(chunks, {text = " - " .. critIndicator, color = indicatorColor})
            end
        else
            -- Fallback: just use text color
            table.insert(chunks, {text = "rolls " .. msg.message, color = textColor})
        end
        
        -- Calculate prefix width
        local prefixWidth = textManager:MeasureStringX(font, timeStr)
            + textManager:MeasureStringX(font, tag .. " ")
            + textManager:MeasureStringX(font, nameStr)
        
        local availableWidth = panelWidth - margin * 2 - prefixWidth - WRAP_PADDING
        if availableWidth < 50 then availableWidth = 200 end
        
        -- Wrap with color preservation
        local wrappedLines = wrapTextWithColors(chunks, font, availableWidth)
        
        local displayLines = {}
        for lineIdx, lineData in ipairs(wrappedLines) do
            table.insert(displayLines, {
                isFirstLine = (lineIdx == 1),
                chunks = lineData.chunks,
                tagColor = tagColor,
                tag = tag,
                timeStr = timeStr,
                nameStr = nameStr,
                prefixWidth = prefixWidth,
                playerColor = msg.playerColor,
                msgId = msg.msgId,
                isRoll = true,
            })
        end
        
        return displayLines
    end
    
    -- ========================================
    -- STANDARD FORMAT: [tag] Name: message
    -- ========================================
    local timeStr = formatTime(msg.timestamp) .. " "
    -- /event narration arrives identity-scrubbed (characterName == "");
    -- an empty name must not leave an orphaned ": " on the line.
    local nameStr = ""
    if msg.characterName and msg.characterName ~= "" then
        nameStr = msg.characterName .. ": "
    end
    
    -- Speech channels get smart asterisk handling
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    local isSpeech = speechChannels[msg.channel]
    
    -- Parse message into colored segments.
    --
    -- Two paths:
    --   v8.5+ chunks path: server provided pre-segmented render chunks (e.g.
    --   for L2-acquired words in soft purple). Walk them; for each chunk
    --   resolve nil-color to channel tagColor, then run parseColorSegments
    --   on the chunk's text to handle any embedded *emote* / **mood** markup
    --   within. Concatenate the resulting sub-segments into a final segments
    --   list. Pure-emote detection is skipped on this path -- a message with
    --   L2 substitutions isn't a pure emote.
    --
    --   Flat-string path (v8.4 behaviour, still used for English / radio /
    --   any non-L2 speech): single parseColorSegments call on msg.message.
    local emoteColor = TAZC_Config.ChannelColors.emote or {255, 190, 128}
    local moodColor = TAZC_Config.ChannelColors.mood or {180, 180, 200}
    local segments, isPureEmote

    if msg.chunks and #msg.chunks > 0 then
        segments = {}
        for _, chunk in ipairs(msg.chunks) do
            local baseColor = chunk.color or tagColor
            local subSegments = TAZC_Core.parseColorSegments(
                chunk.text, baseColor, isSpeech, emoteColor, moodColor)
            for _, sub in ipairs(subSegments) do
                -- Carry the chunk's alpha through to sub-segments so phase 2's
                -- partial-state whispered chunks render correctly even when
                -- they contain (highly unlikely but possible) asterisk markup.
                if chunk.alpha then sub.alpha = chunk.alpha end
                table.insert(segments, sub)
            end
        end
        isPureEmote = false
    else
        segments, isPureEmote = TAZC_Core.parseColorSegments(
            msg.message, tagColor, isSpeech, emoteColor, moodColor)
    end
    
    -- Pure emote in speech channel -> convert to emote format
    if isSpeech and isPureEmote then
        local emoteContent = msg.message:match("^%s*%*(.-)%*%s*$") or msg.message
        local emoteText = "*" .. msg.characterName .. " " .. emoteContent .. "*"
        
        local emotePrefixWidth = textManager:MeasureStringX(font, timeStr)
        local availableWidth = panelWidth - margin * 2 - emotePrefixWidth - WRAP_PADDING
        if availableWidth < 50 then availableWidth = 200 end
        
        local wrappedLines = wrapText(emoteText, font, availableWidth)
        local displayLines = {}
        for lineIdx, lineText in ipairs(wrappedLines) do
            table.insert(displayLines, {
                isFirstLine = (lineIdx == 1),
                isEmote = true,
                text = lineText,
                tagColor = emoteColor,
                tag = "",
                timeStr = timeStr,
                nameStr = "",
                prefixWidth = emotePrefixWidth,
                playerColor = msg.playerColor,
                msgId = msg.msgId,
            })
        end
        return displayLines
    end
    
    -- Calculate prefix width (piece by piece to match render path)
    local prefixWidth = textManager:MeasureStringX(font, timeStr)
        + textManager:MeasureStringX(font, tag .. " ")
        + textManager:MeasureStringX(font, nameStr)
    
    local availableWidth = panelWidth - margin * 2 - prefixWidth - WRAP_PADDING
    if availableWidth < 50 then availableWidth = 200 end
    
    -- Wrap with color preservation
    local wrappedLines = wrapTextWithColors(segments, font, availableWidth)
    
    -- Build display line objects
    local displayLines = {}
    for lineIdx, lineData in ipairs(wrappedLines) do
        table.insert(displayLines, {
            isFirstLine = (lineIdx == 1),
            chunks = lineData.chunks,
            tagColor = tagColor,
            tag = tag,
            timeStr = timeStr,
            nameStr = nameStr,
            prefixWidth = prefixWidth,
            playerColor = msg.playerColor,
            msgId = msg.msgId,
        })
    end
    
    return displayLines
end

-- Internal contract: addMessage never returns the display lines it
-- computes (rendering-only API), so the offline harness has no other way
-- to inspect computeMessageLines' per-channel output directly.
TAZC_ChatPanel._computeMessageLines = computeMessageLines

-- Test-only accessor (B1 fix): lets the offline harness drive the REAL
-- addMessage(msgData) path -- the same 13(+)-field whitelist that builds
-- the internal msg table from server msgData -- and then inspect what it
-- actually cached, instead of hand-building a msg table that skips
-- whichever fields addMessage silently drops. Never used by game code.
TAZC_ChatPanel._getDisplayLines = function(tabId)
    return displayLinesByTab[tabId or 1]
end

-- ============================================================================
-- PUBLIC INTERFACE
-- ============================================================================

function TAZC_ChatPanel.setCurrentTab(tabId)
    if tabId >= 1 and tabId <= 2 then
        currentTab = tabId
    end
end

function TAZC_ChatPanel.getCurrentTab()
    return currentTab
end

--[[
    Add a message to the chat panel
    Pre-computes display lines immediately

    Internal contract: characterName/playerColor arrive already anonymized --
    TAZC_Anonymity applies masking/distance in the caller before this is ever
    called; addMessage itself only renders, never masks.

    @param msgData  Message data table with:
        - channel: Channel name
        - username: Player username
        - characterName: In-game character name
        - message: Message text
        - playerColor: {r, g, b} color
        - timestamp: Unix timestamp (optional)
        - frequency: Radio frequency (optional, for radio messages)
        - originalChannel: Original speech channel (optional, for radio)
]]
function TAZC_ChatPanel.addMessage(msgData)
    if not msgData then return end
    
    local channel = msgData.channel or "say"
    local tabId = channelToTab[channel] or 1
    
    -- Assign unique ID
    local msgId = nextMsgId
    nextMsgId = nextMsgId + 1
    
    local msg = {
        msgId = msgId,
        timestamp = msgData.timestamp or os.time(),
        channel = channel,
        originalChannel = msgData.originalChannel,
        username = msgData.username or "Unknown",
        characterName = msgData.characterName or msgData.username,
        playerColor = msgData.playerColor or {255, 255, 255},
        message = msgData.message or "",
        chunks = msgData.chunks,  -- v8.5: server-provided render chunks (nil -> flat-string path)
        modality = msgData.modality,  -- B1 fix: signed verb-framing tag swap needs this through the real path
        frequency = msgData.frequency,
        isRoll = msgData.isRoll or false,
        rollTotal = msgData.rollTotal,
        isCrit = msgData.isCrit or false,
        isFumble = msgData.isFumble or false,
    }
    
    -- Helper to add to a specific tab
    local function addToTab(tid)
        if not displayLinesByTab[tid] then
            displayLinesByTab[tid] = {}
            scrollOffsetByTab[tid] = 0
            messageCountByTab[tid] = 0
        end
        if not rawMessagesByTab[tid] then
            rawMessagesByTab[tid] = {}
        end
        
        -- Store raw message for rewrap
        table.insert(rawMessagesByTab[tid], msg)
        
        local panelWidth = lastPanelWidth
        if panelWidth < 100 then panelWidth = TAZC_Config.Panel.defaultWidth end
        local margin = TAZC_Config.Panel.margin
        
        local newLines = computeMessageLines(msg, panelWidth, margin)
        for _, line in ipairs(newLines) do
            table.insert(displayLinesByTab[tid], line)
        end
        
        messageCountByTab[tid] = messageCountByTab[tid] + 1
        
        -- Trim old messages (both raw and display)
        while messageCountByTab[tid] > maxMessages do
            local lines = displayLinesByTab[tid]
            local rawMsgs = rawMessagesByTab[tid]
            if #lines > 0 then
                local oldestMsgId = lines[1].msgId
                while #lines > 0 and lines[1].msgId == oldestMsgId do
                    table.remove(lines, 1)
                end
                -- Also remove from raw storage
                if #rawMsgs > 0 and rawMsgs[1].msgId == oldestMsgId then
                    table.remove(rawMsgs, 1)
                end
                messageCountByTab[tid] = messageCountByTab[tid] - 1
            else
                break
            end
        end
    end
    
    -- Add to primary tab
    addToTab(tabId)
    
    -- Auto-scroll to bottom if near bottom
    if TAZC_ChatPanel.instance and tabId == currentTab then
        local currentScroll = scrollOffsetByTab[tabId] or 0
        if currentScroll < TAZC_ChatPanel.instance.lineHeight * 2 then
            scrollOffsetByTab[tabId] = 0
        end
    end
end

--[[
    Build and add a "[TAZC]" system line -- the one shared shape
    behind TAZC_Input's local command feedback, TAZC_LangAdmin's admin-menu
    feedback, and TAZC_Client's server-forwarded SystemMessage handler.

    @param message  Line text
    @param opts      Optional { color = {r,g,b}, chunks = server render chunks }
]]
function TAZC_ChatPanel.systemMessage(message, opts)
    opts = opts or {}
    TAZC_ChatPanel.addMessage({
        channel = "system",
        characterName = "[TAZC]",
        message = message,
        chunks = opts.chunks,
        timestamp = os.time(),
        playerColor = opts.color or {200, 200, 200},
    })
end

--[[
    Rewrap all messages for a new panel width
    Called when panel is resized
]]
local function rewrapAllMessages(panelWidth)
    local margin = TAZC_Config.Panel.margin
    
    for tid, rawMsgs in pairs(rawMessagesByTab) do
        displayLinesByTab[tid] = {}
        for _, msg in ipairs(rawMsgs) do
            local newLines = computeMessageLines(msg, panelWidth, margin)
            for _, line in ipairs(newLines) do
                table.insert(displayLinesByTab[tid], line)
            end
        end
    end
    
    dbg("rewrapAllMessages: rewrapped for width %d", panelWidth)
end

-- ============================================================================
-- UI ELEMENT METHODS
-- ============================================================================

function TAZC_ChatPanel:initialise()
    ISUIElement.initialise(self)
    TAZC_ChatPanel.instance = self
    lastPanelWidth = self.width
end

function TAZC_ChatPanel:getLineCount()
    return #(displayLinesByTab[currentTab] or {})
end

function TAZC_ChatPanel:getMaxScroll()
    local lineCount = self:getLineCount()
    local contentHeight = lineCount * self.lineHeight
    local viewHeight = self.height - self.margin * 2
    return math.max(0, contentHeight - viewHeight)
end

function TAZC_ChatPanel:onMouseWheel(del)
    if not scrollOffsetByTab[currentTab] then
        scrollOffsetByTab[currentTab] = 0
    end
    
    local maxScroll = self:getMaxScroll()
    local scrollOffset = scrollOffsetByTab[currentTab]
    scrollOffset = scrollOffset - del * self.lineHeight * 3
    scrollOffset = math.max(0, math.min(scrollOffset, maxScroll))
    scrollOffsetByTab[currentTab] = scrollOffset
    return true
end

function TAZC_ChatPanel:prerender()
    ISPanel.prerender(self)
    
    -- Check for resize and rewrap if needed
    if math.abs(self.width - lastPanelWidth) > 20 then
        lastPanelWidth = self.width
        rewrapAllMessages(self.width)
    end
end

function TAZC_ChatPanel:render()
    local lineHeight = self.lineHeight
    local margin = self.margin
    local textManager = getTextManager()
    local font = UIFont.Medium
    
    -- DISABLED: Stencil was clipping text at edge

    local displayLines = displayLinesByTab[currentTab] or {}
    local scrollOffset = scrollOffsetByTab[currentTab] or 0
    local viewHeight = self.height - margin * 2
    local totalLines = #displayLines
    
    local visibleCount = math.floor(viewHeight / lineHeight)
    
    -- Calculate visible range (scrollOffset 0 = newest at bottom)
    local lastVisibleIdx = totalLines - math.floor(scrollOffset / lineHeight)
    local firstVisibleIdx = math.max(1, lastVisibleIdx - visibleCount)
    
    local baseY = self.height - margin - lineHeight
    
    -- Draw from newest (bottom) to oldest (top)
    for i = lastVisibleIdx, firstVisibleIdx, -1 do
        local line = displayLines[i]
        if line then
            local linesFromBottom = lastVisibleIdx - i
            local y = baseY - (linesFromBottom * lineHeight) + (scrollOffset % lineHeight)
            
            if y >= margin - lineHeight and y < self.height - margin + lineHeight then
                local x = margin
                
                if line.isFirstLine then
                    -- Timestamp (gray)
                    self:drawText(line.timeStr, x, y, 0.5, 0.5, 0.5, 0.8, font)
                    x = x + textManager:MeasureStringX(font, line.timeStr)
                    
                    if not line.isEmote then
                        -- Channel tag
                        local tc = line.tagColor
                        self:drawText(line.tag .. " ", x, y, tc[1]/255, tc[2]/255, tc[3]/255, 0.9, font)
                        x = x + textManager:MeasureStringX(font, line.tag .. " ")
                        
                        -- Player name
                        local pc = line.playerColor
                        self:drawText(line.nameStr, x, y, pc[1]/255, pc[2]/255, pc[3]/255, 1, font)
                        x = x + textManager:MeasureStringX(font, line.nameStr)
                    end
                else
                    -- Continuation indent
                    x = margin + line.prefixWidth
                end
                
                -- Message text
                if line.chunks then
                    for _, chunk in ipairs(line.chunks) do
                        local cc = chunk.color or line.tagColor
                        local ca = chunk.alpha or 1
                        self:drawText(chunk.text, x, y, cc[1]/255, cc[2]/255, cc[3]/255, ca, font)
                        x = x + textManager:MeasureStringX(font, chunk.text)
                    end
                elseif line.text then
                    local tc = line.tagColor
                    self:drawText(line.text, x, y, tc[1]/255, tc[2]/255, tc[3]/255, 1, font)
                end
            end
        end
    end
    
    -- Scrollbar
    local totalHeight = totalLines * lineHeight
    local maxScroll = math.max(0, totalHeight - viewHeight)
    if maxScroll > 0 then
        local barHeight = math.max(20, (viewHeight / totalHeight) * viewHeight)
        local scrollRatio = scrollOffset / maxScroll
        local barY = margin + (1 - scrollRatio) * (viewHeight - barHeight)
        self:drawRect(self.width - 6, barY, 4, barHeight, 0.5, 0.5, 0.5, 0.5)
    end
end

function TAZC_ChatPanel:new(x, y, width, height)
    dbg("new: creating panel at %d,%d size %dx%d", x, y, width, height)
    
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.background = true
    o.backgroundColor = {r=0, g=0, b=0, a=0.6}
    o.borderColor = {r=0.3, g=0.3, b=0.3, a=0.5}
    
    o.font = UIFont.Medium
    o.lineHeight = getTextManager():getFontHeight(UIFont.Medium) + 2
    o.margin = TAZC_Config.Panel.margin
    
    lastPanelWidth = width
    
    return o
end

-- ============================================================================
-- MESSAGE CLEARING
-- ============================================================================

--[[
    Clear all chat messages from all tabs.
    Called when a new character is created to prevent seeing old history.
]]
function TAZC_ChatPanel.clearAllMessages()
    -- Clear all tab data (tab 1 = General, tab 2 = Admin)
    for tid = 1, 2 do
        displayLinesByTab[tid] = {}
        rawMessagesByTab[tid] = {}
        scrollOffsetByTab[tid] = 0
        messageCountByTab[tid] = 0
    end
end

-- Clear chat history when a new character is created
-- This prevents new characters from seeing messages from before they existed
local function onCreatePlayer(playerIndex, player)
    TAZC_ChatPanel.clearAllMessages()
    -- Same fresh-character moment: a re-rolled character must not keep the
    -- dead character's bio tagline either. TAZC_Bio owns the check + clear.
    TAZC_Bio.clearTaglineForFreshCharacter(player)
end

Events.OnCreatePlayer.Add(onCreatePlayer)

-- ============================================================================

return TAZC_ChatPanel
