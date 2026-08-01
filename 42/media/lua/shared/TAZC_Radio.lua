--[[
================================================================================
    Terror AustraliZ Chat - Radio Subsystem
    
    Passive broadcast model. Speech near radios with unmuted microphones
    transmits on the radio's frequency.
    
    TRANSMISSION MODEL:
    - No push-to-talk required
    - Radio on + mic unmuted + speech in range = transmission
    
    B42 API NOTES:
    - DeviceData methods stable
    - Frequencies are integers (98600 = 98.6 MHz)
    - Ground radios via IsoGridSquare iteration
    - Vehicle radios via getPartById("Radio")
    - Headphone detection: -1=speaker (public), 0=earbuds, 1=headphones (private)
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Sanitize = require("TAZC_Sanitize")

local dbg = TAZC_Core.debugger("RADIO")

local TAZC_Radio = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- Radio source identifiers (for tracking where a radio state came from)
TAZC_Radio.SOURCE_PLAYER = "player"    -- Carried in hands/belt/inventory
TAZC_Radio.SOURCE_GROUND = "ground"    -- Placed on floor/table
TAZC_Radio.SOURCE_VEHICLE = "vehicle"  -- Built into vehicle dashboard

-- ============================================================================
-- PACKET LOSS / STATIC SIMULATION
-- 
-- The soul of the radio. These aren't decoration -- they make it feel real.
-- The flat-string variant (addPacketLoss) was previously a local in
-- TAZC_Server; in v8.5.1 it moved here so the chunked variant could live
-- alongside, and so the harness can exercise both.
-- 
-- Randomness is injected via opts.rand (function taking n, returning
-- 0..n-1, defaulting to the PZ global ZombRand) so tests can pin the
-- behaviour deterministically without monkey-patching globals at the
-- module level.
-- ============================================================================

TAZC_Radio.STATIC_POPS = {
    '*krrk*', '*pzzt*', '*fzzt*', '*zap*', '*whirr*',
    '*fzzzt*', '*shhhk*', '*wrrrp*', '*bzzzt*', '*chck*',
    '*clnk*', '*tssk*', '*thrum*', '*zzzt*', '*click*',
    '*crackle*', '*hisss*', '*pop*', '*skrrt*', '*whrr*'
}

-- Base corruption rates (weather makes these worse)
TAZC_Radio.LOSS_CHANCE_BASE     = 0.20  -- per-word corruption probability
TAZC_Radio.BOOKEND_STATIC_START = 0.40  -- chance of static before message
TAZC_Radio.BOOKEND_STATIC_END   = 0.50  -- chance of static after message

-- Resolve a random source: explicit opts.rand wins, otherwise the global
-- ZombRand provided by PZ. Tests pass a deterministic function; production
-- gets ZombRand for free.
local function resolveRand(opts)
    if opts and type(opts.rand) == "function" then return opts.rand end
    return ZombRand
end

local function randomStaticPop(rand)
    local pops = TAZC_Radio.STATIC_POPS
    return pops[rand(#pops) + 1]
end

-- Word-level corruption pass. Operates on a single text string in
-- isolation (no bookends, no mid-message static). The TAZC_Sanitize wrap is
-- here because RP/OOC markers should always pass through static intact,
-- regardless of whether we're degrading a whole message or just one chunk.
--
-- Returns:
--   result          the corrupted string
--   eligibleWords    count of non-protected words considered for corruption
--   staticLossWords  count of those words that were fully replaced by a
--                    static pop (as opposed to surviving untouched or
--                    mid-word-cut). Callers use these two counts to know,
--                    explicitly, whether EVERY real word in this text was
--                    statified out -- rather than re-detecting that by
--                    pattern-matching the resulting text's shape, which
--                    can't tell "generated static" from "player text that
--                    happens to look like one bare *marker*".
local function corruptWords(text, weatherMultiplier, rand)
    if not text or text == "" then return text, 0, 0 end

    local lossChance = math.min(TAZC_Radio.LOSS_CHANCE_BASE * weatherMultiplier, 0.60)

    -- Distinct keyTemplate from TAZC_Sanitize's own default ("MCSAN%d"),
    -- following the same per-call-site convention TAZC_Lang ("MCBLEED%d")
    -- and TAZC_Cultural ("MCCULTURAL%d") use (see TAZC_Sanitize's own opts
    -- doc): a placeholder shape traceable to the subsystem that produced
    -- it, distinct from every other concurrently-protected pass.
    local protected, protected_blocks, protected_order = TAZC_Sanitize.protect(text, {
        keyTemplate = "{{PROTECTED%d}}",
    })

    local words = {}
    for word in protected:gmatch("%S+") do
        table.insert(words, word)
    end

    local out = {}
    local eligibleWords = 0
    local staticLossWords = 0
    for _, word in ipairs(words) do
        if protected_blocks[word] then
            table.insert(out, word)
        else
            eligibleWords = eligibleWords + 1
            if #word > 3 and rand(100) < (lossChance * 100) then
                if rand(100) < 70 and #word > 4 then
                    -- Mid-word corruption: "something" -> "some..ing"
                    local startCut = rand(#word - 3) + 1
                    local endCut = startCut + rand(2) + 1
                    if endCut > #word then endCut = #word end
                    local corrupted = word:sub(1, startCut) .. ".." .. word:sub(endCut + 1)
                    table.insert(out, corrupted)
                else
                    -- Word lost to static
                    staticLossWords = staticLossWords + 1
                    table.insert(out, randomStaticPop(rand))
                end
            else
                table.insert(out, word)
            end
        end
    end

    local result = table.concat(out, " ")
    -- Preserve leading/trailing whitespace from the input so per-chunk
    -- callers don't lose the boundary spaces between adjacent base chunks.
    local leadingWS = text:match("^(%s*)") or ""
    local trailingWS = text:match("(%s*)$") or ""
    result = leadingWS .. result .. trailingWS

    result = TAZC_Sanitize.restore(result, protected_blocks, protected_order)
    return result, eligibleWords, staticLossWords
end

-- Byte spans (start, end) of TAZC_Sanitize's protected marker shapes
-- (**mood**, *emote*, ((ooc))) found directly in already-restored text.
-- Used only by the flat addPacketLoss's mid-message splice below: unlike
-- the chunked path (which only ever inserts static as a NEW chunk at a
-- chunk boundary), the flat path picks a raw byte offset into the fully
-- assembled string and could otherwise land inside a marker and split it.
--
-- Sourced directly from TAZC_Sanitize.DEFAULT_PATTERNS/DEFAULT_PATTERN_ORDER
-- (same shapes, same order) rather than a hand-copied pattern list, so a
-- future fourth protected shape added there can't silently miss the clamp
-- logic here. string.find tolerates the capture group in each pattern --
-- {s, e} come from find's own start/end, the capture is simply unused.
--
-- A later pattern skips any match starting inside a span an earlier one
-- already claimed -- mirrors TAZC_Sanitize's own double-before-single
-- precedence so *emote*'s scan can't re-match **mood**'s own delimiters
-- as a spurious empty span.
local function findProtectedSpans(text)
    local spans = {}
    for _, name in ipairs(TAZC_Sanitize.DEFAULT_PATTERN_ORDER) do
        local pat = TAZC_Sanitize.DEFAULT_PATTERNS[name].pattern
        local searchFrom = 1
        while true do
            local s, e = text:find(pat, searchFrom)
            if not s then break end
            local claimed = false
            for _, span in ipairs(spans) do
                if s >= span[1] and s <= span[2] then
                    claimed = true
                    break
                end
            end
            if not claimed then
                table.insert(spans, { s, e })
            end
            searchFrom = e + 1
        end
    end
    return spans
end

-- Nudge a mid-message static insertion point so it never falls strictly
-- inside a protected span (splitting "cra..es *waves warmly*" style
-- text would corrupt a marker). Snaps to just before the span starts.
local function clampInsertPos(pos, spans)
    for _, span in ipairs(spans) do
        if pos >= span[1] and pos < span[2] then
            return math.max(span[1] - 1, 0)
        end
    end
    return pos
end

--[[
    Apply radio packet loss + bookend static to a flat string.
    The legacy TAZC_Server entry point -- preserved with byte-identical
    behaviour for the same inputs and ZombRand seed.

    @param message            string to corrupt
    @param weatherMultiplier  1.0 = clear, up to ~3.0 in heavy weather
    @param opts               optional { rand = function(n) -> 0..n-1 }
    @return                   corrupted string
]]
function TAZC_Radio.addPacketLoss(message, weatherMultiplier, opts)
    weatherMultiplier = weatherMultiplier or 1.0
    local rand = resolveRand(opts)

    local result = corruptWords(message, weatherMultiplier, rand)

    local startChance = math.min(TAZC_Radio.BOOKEND_STATIC_START * weatherMultiplier, 0.85)
    local endChance   = math.min(TAZC_Radio.BOOKEND_STATIC_END   * weatherMultiplier, 0.90)

    if rand(100) < (startChance * 100) then
        result = randomStaticPop(rand) .. " " .. result
    end
    if rand(100) < (endChance * 100) then
        result = result .. " " .. randomStaticPop(rand)
    end

    -- Mid-message static in bad weather. This splices by raw byte offset
    -- into the already-restored string, so (unlike the chunked path's
    -- boundary-only insertion) it could land inside a protected
    -- *emote*/((aside)) marker and split it -- clamp the offset so it
    -- never does.
    if weatherMultiplier >= 2.0 and rand(100) < 40 and #result > 1 then
        local insertPos = rand(#result - 1) + 1
        insertPos = clampInsertPos(insertPos, findProtectedSpans(result))
        result = result:sub(1, insertPos) .. " " ..
                 randomStaticPop(rand) .. " " ..
                 result:sub(insertPos + 1)
    end

    return result
end

--[[
    Chunk-aware packet loss for v8.5+ chunked render output. Walks the
    chunks array, applies word-level corruption per chunk (preserving
    chunk colour and alpha for mid-word cuts, falling back to base
    colour when a chunk's content fully becomes a static pop), then
    inserts bookend / mid-message static as new base-colour chunks.

    @param chunks             v8.5 chunk array, OR nil
    @param weatherMultiplier  1.0 = clear, up to ~3.0 in heavy weather
    @param opts               optional { rand = function(n) -> 0..n-1 }
    @return degradedChunks    new chunk array (input is not mutated)
    @return flatString        assembled text equivalent to the chunks
]]
function TAZC_Radio.addPacketLossToChunks(chunks, weatherMultiplier, opts)
    weatherMultiplier = weatherMultiplier or 1.0
    local rand = resolveRand(opts)

    if not chunks or #chunks == 0 then
        return chunks, ""
    end

    -- Per-chunk word corruption. Preserve colour/alpha for chunks that
    -- survive mid-word cuts; reset colour to nil only when the corruption
    -- pass ITSELF replaced every eligible word in the chunk with a static
    -- pop (staticLossWords == eligibleWords, both > 0) -- tracked
    -- explicitly by corruptWords rather than re-derived by pattern-
    -- matching degradedText's shape. The old shape-match (`^%*[^%*]+%*$`)
    -- couldn't tell a generated-static chunk from an untouched chunk whose
    -- real, uncorrupted content is itself a bare `*emote*` marker -- e.g.
    -- a player writing "*waves warmly*" with zero corruption chance had
    -- that styling stripped for looking like static it never became.
    local out = {}
    for _, chunk in ipairs(chunks) do
        local degradedText, eligibleWords, staticLossWords =
            corruptWords(chunk.text or "", weatherMultiplier, rand)
        local newChunk = { text = degradedText }
        local generatedStatic = eligibleWords > 0 and staticLossWords == eligibleWords
        if generatedStatic then
            -- Every real word in this chunk was statified out by THIS
            -- pass -- leave color/alpha nil so it renders as base text
            -- (channel default), and record that explicitly for callers.
            newChunk.isGeneratedStatic = true
        else
            -- Mid-word survival, untouched text, or protected-only
            -- content -- keep the chunk's style.
            newChunk.color = chunk.color
            newChunk.alpha = chunk.alpha
        end
        table.insert(out, newChunk)
    end

    -- Bookend static -- prepended/appended as base-colour chunks.
    local startChance = math.min(TAZC_Radio.BOOKEND_STATIC_START * weatherMultiplier, 0.85)
    local endChance   = math.min(TAZC_Radio.BOOKEND_STATIC_END   * weatherMultiplier, 0.90)

    if rand(100) < (startChance * 100) then
        table.insert(out, 1, { text = randomStaticPop(rand) .. " " })
    end
    if rand(100) < (endChance * 100) then
        table.insert(out, { text = " " .. randomStaticPop(rand) })
    end

    -- Mid-message static in bad weather: insert at a random chunk boundary.
    if weatherMultiplier >= 2.0 and rand(100) < 40 and #out > 1 then
        local insertAt = rand(#out - 1) + 2  -- between 2 and #out (inclusive)
        table.insert(out, insertAt, { text = " " .. randomStaticPop(rand) .. " " })
    end

    -- Derive the flat string from the degraded chunks.
    local flatBuf = {}
    for _, c in ipairs(out) do
        table.insert(flatBuf, c.text)
    end

    return out, table.concat(flatBuf)
end

-- ============================================================================
-- RADIO STATE BUILDER
-- Normalizes data from player/ground/vehicle radios into a unified shape
-- for routing logic. All the defensive pcall wrapping lives here.
-- ============================================================================

local function buildRadioState(deviceData, source, position, ownerId)
    if not deviceData then return nil end
    
    -- Get frequency - B42 uses integers (98600 = 98.6 MHz)
    local freq = TAZC_Core.safe(function() return deviceData:getChannel() end, nil)
    
    -- NaN/nil guard (B42 bible: val == val catches NaN)
    if not freq or freq ~= freq then return nil end
    
    -- Compound power check: must be turned on AND have power
    local isOn = TAZC_Core.safe(function() return deviceData:getIsTurnedOn() end, false)
    local hasPower = TAZC_Core.safe(function() return (deviceData:getPower() or 0) > 0 end, false)
    
    -- If the radio is "on" but dead battery, it's effectively off
    local effectivelyOn = isOn and hasPower
    
    -- Get transmission capability
    local isTwoWay = TAZC_Core.safe(function() return deviceData:getIsTwoWay() end, false)
    local micMuted = TAZC_Core.safe(function() return deviceData:getMicIsMuted() end, true)
    local transmitRange = TAZC_Core.safe(function() return deviceData:getTransmitRange() or 0 end, 0)
    local volume = TAZC_Core.safe(function() return deviceData:getDeviceVolume() or 1.0 end, 1.0)
    
    -- Headphone detection (B42 API, confirmed against vanilla
    -- ISRadioAction:isValidRemoveHeadphones/isValidAddHeadphones, which
    -- gate on >= 0 and < 0 respectively):
    -- -1 = No headphones (PUBLIC speaker mode)
    --  0 = Earbuds (PRIVATE)
    --  1 = Headphones (PRIVATE)
    -- BUGFIX: previously defaulted missing reads to 0 and tested
    -- `headphoneType > 0`, which misclassified earbuds (0) as public.
    local headphoneType = TAZC_Core.safe(function() return deviceData:getHeadphoneType() or -1 end, -1)
    local isPrivate = headphoneType >= 0
    
    return {
        frequency = freq,
        isTwoWay = isTwoWay == true,
        isOn = effectivelyOn,
        micMuted = micMuted ~= false,  -- nil/error = treat as muted (safe default)
        transmitRange = transmitRange,
        volume = volume,
        headphoneType = headphoneType,
        isPrivate = isPrivate,
        source = source,
        position = position,
        ownerId = ownerId
    }
end

-- ============================================================================
-- PREDICATES
-- Simple boolean checks on radio state
-- ============================================================================

--[[
    Can this radio transmit?
    Requires: powered on, two-way capable, mic not muted
]]
function TAZC_Radio.canEmit(radioState)
    if not radioState then return false end
    return radioState.isOn 
       and radioState.isTwoWay 
       and not radioState.micMuted
end

--[[
    Can this radio receive?
    Just needs to be powered on
]]
function TAZC_Radio.canReceive(radioState)
    if not radioState then return false end
    return radioState.isOn
end

--[[
    Do two radios share a frequency?
    Exact integer match required

    Internal contract: exercised by test_radio_pure. No in-tree production
    caller -- findReceivers below groups emitters by frequency as a table
    key rather than calling this predicate pairwise. Kept on the public API
    as pure predicate logic a caller could reasonably want.
]]
function TAZC_Radio.frequenciesMatch(emitter, receiver)
    if not emitter or not receiver then return false end
    return emitter.frequency == receiver.frequency
end

--[[
    Is receiver within emitter's transmit range?
    @return inRange (boolean), distance (number)
]]
function TAZC_Radio.isInTransmitRange(emitter, receiver)
    if not emitter or not receiver then return false, -1 end
    if not emitter.position or not receiver.position then return false, -1 end

    local distance = TAZC_Core.distance2D(emitter.position.x, emitter.position.y,
        receiver.position.x, receiver.position.y)

    return distance <= emitter.transmitRange, distance
end

-- ============================================================================
-- RADIO DISCOVERY - PLAYER
-- Find radios carried by a player
-- ============================================================================

-- Check if an item is a radio and extract its state
local function tryGetRadioState(item, source, position, ownerId)
    if not item then return nil end
    
    -- Check if method exists before calling (avoids error spam)
    if not item.getDeviceData then return nil end
    
    local deviceData = TAZC_Core.safe(function() return item:getDeviceData() end, nil)
    if not deviceData then return nil end
    
    return buildRadioState(deviceData, source, position, ownerId)
end

--[[
    Get radio from player's hands, belt attachments, or inventory.
    Returns the FIRST radio found (regardless of state).

    NOTE: For emission/reception scans where state matters, prefer
    getAllPlayerRadios() instead. This short-circuit function is kept for
    callers that just want "does this player have any radio on them".

    Delegates to getAllPlayerRadios(player)[1] -- mirrors findEmitters'
    delegation onto findPlayerEmitters below. Equivalent to the old
    hand-rolled priority walk because getAllPlayerRadios scans in the exact
    same order (primary hand, secondary hand, attached/belt items, then
    full inventory) and never reorders or filters by state; its first
    array element is therefore always the same radio this function used to
    return on its first early-return hit.

    Priority order:
    1. Primary hand (most explicit - you're holding it)
    2. Secondary hand
    3. Belt attachments (visible on character)
    4. Inventory (catches belt-equipped when sync fails)

    Internal contract: no in-tree production caller (findPlayerEmitters and
    findReceivers both moved to getAllPlayerRadios below -- see the fix
    notes there and on those two functions themselves); test_radio_pure
    reaches the local buildRadioState() normalization logic through this
    function, since it's the only public entry point that does. Kept on
    the public API as a legitimate first-found convenience query in its
    own right.
]]
function TAZC_Radio.getPlayerRadio(player)
    return TAZC_Radio.getAllPlayerRadios(player)[1]
end

--[[
    Get ALL radios the player has on their person.
    
    Fix for C32/C33 (0.8.0): previously getPlayerRadio returned first-found
    only. If a player was holding a muted/off radio and had a hot-mic radio
    in their bag, the in-hand one was returned and the hot one was ignored -
    so it never transmitted or received, despite being perfectly functional.
    
    Checks hands, attachment slots, and the full inventory. Deduplicates by
    item reference so the same radio isn't returned multiple times if it
    shows up in more than one container query.
    
    @param player IsoPlayer
    @return Array of radioState tables (empty if none found)
]]
function TAZC_Radio.getAllPlayerRadios(player)
    local radios = {}
    if not player then return radios end
    
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    local pos = TAZC_Core.safe(function()
        return {
            x = player:getX(),
            y = player:getY(),
            z = player:getZ()
        }
    end, nil)
    
    -- Track seen items by identity to dedupe. In PZ the same InventoryItem
    -- reference is returned across queries; Lua table-as-set with the
    -- userdata as key works for dedup.
    local seen = {}
    
    local function addIfRadio(item)
        if not item or seen[item] then return end
        seen[item] = true
        local state = tryGetRadioState(item, TAZC_Radio.SOURCE_PLAYER, pos, username)
        if state then
            table.insert(radios, state)
        end
    end
    
    -- Hands
    addIfRadio(TAZC_Core.safe(function() return player:getPrimaryHandItem() end, nil))
    addIfRadio(TAZC_Core.safe(function() return player:getSecondaryHandItem() end, nil))
    
    -- Attached items (belt etc.)
    local attached = TAZC_Core.safe(function() return player:getAttachedItems() end, nil)
    if attached then
        local size = TAZC_Core.safe(function() return attached:size() end, 0)
        for i = 0, size - 1 do
            addIfRadio(TAZC_Core.safe(function() return attached:getItemByIndex(i) end, nil))
        end
    end
    
    -- Full inventory
    local inventory = TAZC_Core.safe(function() return player:getInventory() end, nil)
    if inventory then
        local items = TAZC_Core.safe(function() return inventory:getItems() end, nil)
        if items then
            local size = TAZC_Core.safe(function() return items:size() end, 0)
            for i = 0, size - 1 do
                addIfRadio(TAZC_Core.safe(function() return items:get(i) end, nil))
            end
        end
    end
    
    dbg("getAllPlayerRadios: found %d radios on %s", #radios, tostring(username or "?"))
    return radios
end

-- ============================================================================
-- RADIO DISCOVERY - GROUND
-- Find radios placed in the world via IsoGridSquare iteration
-- ============================================================================

--[[
    Find all ground-placed radios within range of a position
    @param centerX, centerY, centerZ  World coordinates to search around
    @param range                       Search radius in tiles
    @return Array of radioState objects
]]
function TAZC_Radio.getGroundRadios(centerX, centerY, centerZ, range)
    local radios = {}
    local foundPositions = {}  -- Track positions to avoid duplicates
    
    local cell = TAZC_Core.safe(function() return getWorld():getCell() end, nil)
    if not cell then return radios end
    
    -- Iterate squares in range
    for dx = -range, range do
        for dy = -range, range do
            local x, y, z = centerX + dx, centerY + dy, centerZ
            local posKey = x .. "_" .. y .. "_" .. z
            
            local square = TAZC_Core.safe(function() return cell:getGridSquare(x, y, z) end, nil)
            
            if square then
                -- Check objects on this square (furniture, appliances)
                local objects = TAZC_Core.safe(function() return square:getObjects() end, nil)
                
                if objects then
                    local size = TAZC_Core.safe(function() return objects:size() end, 0)
                    
                    for i = 0, size - 1 do
                        local obj = TAZC_Core.safe(function() return objects:get(i) end, nil)
                        
                        -- Only try getDeviceData if method exists
                        if obj and obj.getDeviceData and not foundPositions[posKey] then
                            local deviceData = TAZC_Core.safe(function() return obj:getDeviceData() end, nil)
                            
                            if deviceData then
                                local pos = {x = x, y = y, z = z}
                                local state = buildRadioState(deviceData, TAZC_Radio.SOURCE_GROUND, pos, nil)
                                if state then
                                    table.insert(radios, state)
                                    foundPositions[posKey] = true
                                end
                            end
                        end
                    end
                end
                
                -- Also check world items (dropped radios)
                if not foundPositions[posKey] then
                    local worldItems = TAZC_Core.safe(function() return square:getWorldObjects() end, nil)
                    
                    if worldItems then
                        local size = TAZC_Core.safe(function() return worldItems:size() end, 0)
                        
                        for i = 0, size - 1 do
                            local worldItem = TAZC_Core.safe(function() return worldItems:get(i) end, nil)
                            
                            if worldItem and not foundPositions[posKey] then
                                local item = TAZC_Core.safe(function() return worldItem:getItem() end, nil)
                                
                                local pos = {x = x, y = y, z = z}
                                local state = tryGetRadioState(item, TAZC_Radio.SOURCE_GROUND, pos, nil)
                                if state then
                                    table.insert(radios, state)
                                    foundPositions[posKey] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return radios
end

-- ============================================================================
-- MAIN INTERFACE - EMISSION DISCOVERY
-- Find all radios that would broadcast a player's speech
-- ============================================================================

--[[
    Find all radios that would emit this player's speech (CLIENT-SIDE)
    
    @param player     The speaking player
    @param voiceRange Channel range (whisper=2, say=15, yell=60, etc)
    @return Array of radioState objects that will transmit
]]
function TAZC_Radio.findPlayerEmitters(player, voiceRange)
    local emitters = {}
    
    if not player then return emitters end
    
    local px = TAZC_Core.safe(function() return player:getX() end, 0)
    local py = TAZC_Core.safe(function() return player:getY() end, 0)
    local pz = TAZC_Core.safe(function() return player:getZ() end, 0)
    
    dbg("findPlayerEmitters: player at %d,%d,%d voiceRange=%d", px, py, pz, voiceRange)
    
    -- 1. Carried radios (hands / belt / inventory) - no proximity check.
    --    Every hot-mic radio on your person picks up your voice.
    --    Fix for C32 (0.8.0): scan ALL inventory radios, not just first-found.
    --    Previously a muted radio in hand would mask a hot radio in the bag.
    local carriedRadios = TAZC_Radio.getAllPlayerRadios(player)
    for _, carriedRadio in ipairs(carriedRadios) do
        if TAZC_Radio.canEmit(carriedRadio) then
            dbg("findPlayerEmitters: carried radio on freq %d", carriedRadio.frequency)
            table.insert(emitters, carriedRadio)
        end
    end
    
    -- 2. Ground radios within voice range - area microphone
    --    Speaker's channel (whisper/say/yell) determines pickup range
    --    Radio must be within voice range to "hear" the player
    local groundRadios = TAZC_Radio.getGroundRadios(px, py, pz, voiceRange)
    for _, radio in ipairs(groundRadios) do
        if TAZC_Radio.canEmit(radio) then
            local dist = 0
            if radio.position then
                dist = TAZC_Core.distance2D(px, py, radio.position.x, radio.position.y)
            end
            
            if dist <= voiceRange then
                dbg("findPlayerEmitters: ground radio at dist %.1f on freq %d", dist, radio.frequency)
                table.insert(emitters, radio)
            else
                dbg("findPlayerEmitters: ground radio at dist %.1f OUT OF RANGE (need <= %d)", dist, voiceRange)
            end
        end
    end
    
    -- 3. Vehicle radio if player is IN the vehicle - cabin microphone
    local vehicle = TAZC_Core.safe(function() return player:getVehicle() end, nil)
    
    if vehicle then
        local radioPart = TAZC_Core.safe(function() return vehicle:getPartById("Radio") end, nil)
        
        if radioPart then
            local deviceData = TAZC_Core.safe(function() return radioPart:getDeviceData() end, nil)
            
            if deviceData then
                local vx = TAZC_Core.safe(function() return vehicle:getX() end, 0)
                local vy = TAZC_Core.safe(function() return vehicle:getY() end, 0)
                local vehicleId = TAZC_Core.safe(function() return vehicle:getId() end, nil)
                
                local pos = {x = vx, y = vy, z = pz}
                local radioState = buildRadioState(deviceData, TAZC_Radio.SOURCE_VEHICLE, pos, vehicleId)
                
                if radioState and TAZC_Radio.canEmit(radioState) then
                    dbg("findPlayerEmitters: vehicle radio on freq %d", radioState.frequency)
                    table.insert(emitters, radioState)
                end
            end
        end
    end
    
    dbg("findPlayerEmitters: found %d emitting radios", #emitters)
    return emitters
end

-- ============================================================================
-- MAIN INTERFACE - RECEIVER DISCOVERY (SERVER-SIDE)
-- Find all radios that can receive from given emitters
-- ============================================================================

--[[
    Find all radios that would broadcast a player's speech, grouped by frequency.

    Thin adapter over findPlayerEmitters -- calls that, groups the resulting
    array by frequency. No in-tree consumer (TAZC_Server's routeRadio builds
    its emitter table a different way); kept as an extension-mod surface for
    the grouped shape (e.g. for server-side routing) rather than the flat
    array findPlayerEmitters returns. Whether to keep or delete this is
    queued for Emily's call, not decided here.

    Prior to 0.8.0 this had its own implementation that used getPlayerRadio
    (first-found, missed hot radios in the bag if a muted one was in hand)
    and skipped ground-radio pickup entirely -- both inconsistent with
    findPlayerEmitters. Delegating keeps one source of truth.

    @param player     The speaking player
    @param voiceRange Channel range (whisper=2, say=15, yell=60, etc.)
    @return Table keyed by frequency: { [freq] = {emitter, ...} }
]]
function TAZC_Radio.findEmitters(player, voiceRange)
    local byFreq = {}
    local flat = TAZC_Radio.findPlayerEmitters(player, voiceRange)
    for _, emitter in ipairs(flat) do
        local freq = emitter.frequency
        byFreq[freq] = byFreq[freq] or {}
        table.insert(byFreq[freq], emitter)
    end
    return byFreq
end

--[[
    Find the best radio for a player to receive from given emitters
    
    Returns ONE receiver per frequency (deduped). Priority:
    1. Player's carried radio (most personal)
    2. Vehicle radio (if player is in vehicle)
    3. Closest ground radio
    
    @param player         The receiving player
    @param emittersByFreq Table of emitters keyed by frequency
    @return Table keyed by frequency: { [freq] = { receiverInfo } }
            Note: Each frequency has a single-element array for API compatibility
]]
function TAZC_Radio.findReceivers(player, emittersByFreq)
    local bestReceivers = {}  -- freq -> receiverInfo (single best)
    
    local px = TAZC_Core.safe(function() return player:getX() end, 0)
    local py = TAZC_Core.safe(function() return player:getY() end, 0)
    local pz = TAZC_Core.safe(function() return player:getZ() end, 0)
    
    -- Exclude only the true emitting device: tile + source + frequency (a
    -- freq-blind key wrongly excludes a bystander's radio sharing the tile
    -- on a different frequency). No ownerId: TAZC_Server's emitter table never
    -- sets one, so keying on it would break self-exclusion instead.
    local function emitterKey(pos, source, freq)
        return math.floor(pos.x) .. "_" .. math.floor(pos.y) .. "_" ..
               source .. "_" .. tostring(freq)
    end

    local emitterPositions = {}
    for _, emitterList in pairs(emittersByFreq) do
        for _, emitter in ipairs(emitterList) do
            if emitter.position then
                emitterPositions[emitterKey(emitter.position, emitter.source, emitter.frequency)] = true
            end
        end
    end

    local function isEmitter(radio)
        if not radio.position then return false end
        return emitterPositions[emitterKey(radio.position, radio.source, radio.frequency)]
    end
    
    -- Helper: check if candidate is better than current best
    -- Priority: player (0) > vehicle (1) > ground (2), then by playerDistance
    local function sourcePriority(source)
        if source == "player" then return 0 end
        if source == "vehicle" then return 1 end
        return 2  -- ground
    end
    
    local function isBetterReceiver(candidate, current)
        if not current then return true end
        local candPri = sourcePriority(candidate.radio.source)
        local currPri = sourcePriority(current.radio.source)
        if candPri ~= currPri then return candPri < currPri end
        -- Same priority tier: prefer closer to player
        return candidate.playerDistance < current.playerDistance
    end
    
    -- Helper: try to register a receiver, keeping only the best per frequency
    local function tryRegisterReceiver(radio, playerDistance)
        if not TAZC_Radio.canReceive(radio) then return end
        if isEmitter(radio) then return end
        
        local freq = radio.frequency
        if not emittersByFreq[freq] then return end
        
        for _, emitter in ipairs(emittersByFreq[freq]) do
            local inRange, dist = TAZC_Radio.isInTransmitRange(emitter, radio)
            if inRange then
                local vol = radio.volume or 1.0
                local hearingRange
                if radio.source == "player" then
                    hearingRange = radio.isPrivate and 0 or 
                        math.max(TAZC_Config.Ranges.whisper, TAZC_Config.Ranges.say * vol)
                else
                    hearingRange = math.max(TAZC_Config.Ranges.whisper, TAZC_Config.Ranges.yell * vol)
                end
                
                local candidate = {
                    radio = radio,
                    distance = dist,
                    volume = radio.volume,
                    playerDistance = playerDistance,
                    hearingRange = hearingRange
                }
                
                if isBetterReceiver(candidate, bestReceivers[freq]) then
                    dbg("findReceivers: new best for freq %d: %s at playerDist %.1f", 
                        freq, radio.source, playerDistance)
                    bestReceivers[freq] = candidate
                end
                return  -- Found a valid emitter, done with this radio
            end
        end
    end
    
    -- 1. All of the player's carried radios (highest source priority).
    --    Fix for C33 (0.8.0): previously first-found only, which dropped the
    --    hot receiver in the bag if you had an off radio in hand (mute gates
    --    EMIT only -- canReceive checks isOn alone, so a muted-but-on radio
    --    still receives fine; only an OFF radio in hand could mask it).
    --    tryRegisterReceiver already picks the single best per frequency.
    local carriedRadios = TAZC_Radio.getAllPlayerRadios(player)
    for _, playerRadio in ipairs(carriedRadios) do
        tryRegisterReceiver(playerRadio, 0)
    end
    
    -- 2. Vehicle radio (if player is in vehicle)
    local vehicle = TAZC_Core.safe(function() return player:getVehicle() end, nil)
    if vehicle then
        local radioPart = TAZC_Core.safe(function() return vehicle:getPartById("Radio") end, nil)
        if radioPart then
            local deviceData = TAZC_Core.safe(function() return radioPart:getDeviceData() end, nil)
            if deviceData then
                local vx = TAZC_Core.safe(function() return vehicle:getX() end, 0)
                local vy = TAZC_Core.safe(function() return vehicle:getY() end, 0)
                local vehicleId = TAZC_Core.safe(function() return vehicle:getId() end, nil)
                local pos = {x = vx, y = vy, z = pz}
                local radioState = buildRadioState(deviceData, TAZC_Radio.SOURCE_VEHICLE, pos, vehicleId)
                if radioState then
                    tryRegisterReceiver(radioState, 0)
                end
            end
        end
    end
    
    -- 3. Ground radios (lowest priority, sorted by distance)
    local maxHearingRange = math.min(TAZC_Config.Ranges.yell, 30)
    local groundRadios = TAZC_Radio.getGroundRadios(px, py, pz, maxHearingRange)
    dbg("findReceivers: found %d ground radios within %d tiles", #groundRadios, maxHearingRange)
    
    for _, radio in ipairs(groundRadios) do
        local radioX = radio.position and radio.position.x or px
        local radioY = radio.position and radio.position.y or py
        local playerToRadio = math.sqrt((px - radioX)^2 + (py - radioY)^2)
        
        local vol = radio.volume or 1.0
        local hearingRange = math.max(TAZC_Config.Ranges.whisper, maxHearingRange * vol)
        
        if playerToRadio <= hearingRange then
            tryRegisterReceiver(radio, playerToRadio)
        end
    end
    
    -- Convert to array format for API compatibility (server expects arrays)
    local receivers = {}
    for freq, receiverInfo in pairs(bestReceivers) do
        receivers[freq] = { receiverInfo }
        dbg("findReceivers: final receiver for freq %d: %s", freq, receiverInfo.radio.source)
    end
    
    return receivers
end

-- ============================================================================

-- Internal contract: exposed for test_radio_pure to pin findProtectedSpans'
-- span boundaries directly; not part of the public API.
TAZC_Radio._findProtectedSpans = findProtectedSpans

return TAZC_Radio
