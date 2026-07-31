--[[
================================================================================
    Terror AustraliZ Chat - Anonymity System
    
    Determines whether a speaker should be anonymous based on distance and
    face-covering clothing. Supports roleplay scenarios where players may
    not recognize distant speakers or masked individuals.
    
    RULES:
    - Within recognition range + unmasked -> Real name
    - Within recognition range + masked -> "A Masked Figure"
    - Beyond recognition range -> "Someone"
    - Mask state unverifiable (data not synced, or an errored check) ->
      "A Masked Figure" (fails closed, never leaks the real name)

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")

local dbg = TAZC_Core.debugger("ANON")

local TAZC_Anonymity = {}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

TAZC_Anonymity.Config = {
    -- Distance in tiles within which players can recognize each other.
    -- This is a fallback; actual runtime value is read from TAZC_Config.Ranges.say
    -- (see getDisplayName). Anonymity tracks SayRange on the principle that if
    -- you can hear someone, you can recognize them.
    recognitionRange = 15,
    
    -- Display names for anonymous speakers
    distantName = "Someone",
    maskedName = "A Masked Figure",

    -- Radio speaker whose player object isn't available client-side
    -- (different cell, disconnected mid-broadcast). We can't check mask or
    -- distance, so the line gets a neutral voice instead of the real name.
    radioName = "A Voice on the Radio",

    -- Chat-panel name color for anonymous speakers. Overrides the speaker's
    -- signature color -- regulars can read a color at a glance, which would
    -- un-mask the mask.
    anonymousColor = {180, 180, 180},
    
    -- Body locations that hide identity (mouth/full face coverage).
    --
    -- B42 fix (0.8.16.6): wornItem:getLocation() returns a real
    -- zombie.scripting.objects.ItemBodyLocation object (confirmed
    -- @UsedFromLua and extracted from the shipped jar, the same method the
    -- Deaf-trait fix used) -- vanilla lua NEVER compares it to a string; it
    -- always compares by `==` against the ItemBodyLocation global's own
    -- fields (e.g. ISInventoryPaneContextMenu.lua:
    -- `wornItem:getLocation() == ItemBodyLocation.SWEATER_HAT`). These
    -- names are field names on that global, resolved at check time --
    -- NOT the lowercase "base:mask"/"base:fullhat" strings from clothing
    -- item scripts' own BodyLocation= key (that key only exists at the
    -- item-script level; the runtime object never stringifies back to it).
    identityHidingSlots = {
        "MASK",       -- Bandanas, surgical masks, shemagh (face mode)
        "FULL_HAT",   -- Balaclavas, full-face helmets, NBC masks
    },
    
    -- Specific items that hide identity even if not in standard slots
    -- Use full item type e.g. "Base.Hat_GasMask"
    alsoHidesIdentity = {
        "Base.Hat_GasMask",
    },
    
    -- Items that should NOT hide identity despite being in identity-hiding slots
    -- (empty by default, but available for server customization)
    neverHidesIdentity = {
        -- "Base.Hat_SurgicalMask_Blue",  -- Example: medical masks don't hide identity
    },
}

-- ============================================================================
-- MASK CACHE
-- Using OnClothingUpdated event for efficient mask detection per Gem's research.
-- Polling getWornItems() every frame is expensive; cache invalidates on change.
-- ============================================================================

-- Cache: key = player OnlineID, value = { isMasked = bool, timestamp = number }
TAZC_Anonymity.MaskCache = {}

-- Cache expiry in milliseconds (fallback if event doesn't fire)
TAZC_Anonymity.CACHE_EXPIRY_MS = 5000

--[[
    Update mask cache for a player. Called from OnClothingUpdated hook.
    @param player IsoGameCharacter
]]
function TAZC_Anonymity.updateMaskCache(player)
    if not player then return end
    
    local ok, onlineID = pcall(function() return player:getOnlineID() end)
    if not ok or not onlineID then return end
    
    -- Force a fresh mask check
    local isMasked, isReliable = TAZC_Anonymity.checkMaskDirect(player)
    
    -- Only cache if reliable (clothing event should always have data, but be safe)
    if isReliable then
        TAZC_Anonymity.MaskCache[onlineID] = {
            isMasked = isMasked,
            timestamp = getTimestampMs()
        }
        dbg("updateMaskCache: player %s (ID=%d) -> masked=%s", 
            tostring(player:getUsername()), onlineID, tostring(isMasked))
    else
        dbg("updateMaskCache: player %s (ID=%d) -> unreliable, not caching", 
            tostring(player:getUsername()), onlineID)
    end
end

--[[
    Get cached mask status, or check directly if cache miss/stale.
    Only caches reliable results - if clothing data hasn't synced yet, keeps re-checking.
    @param player IsoPlayer
    @return boolean
]]
function TAZC_Anonymity.isMasked(player)
    if not player then return false end
    
    local ok, onlineID = pcall(function() return player:getOnlineID() end)
    if not ok or not onlineID then 
        -- Can't get ID, fall back to direct check (don't cache)
        local isMasked, _ = TAZC_Anonymity.checkMaskDirect(player)
        return isMasked
    end
    
    local cached = TAZC_Anonymity.MaskCache[onlineID]
    local now = getTimestampMs()
    
    -- Use cache if fresh
    if cached and (now - cached.timestamp) < TAZC_Anonymity.CACHE_EXPIRY_MS then
        dbg("isMasked: using cached value for ID=%d -> %s", onlineID, tostring(cached.isMasked))
        return cached.isMasked
    end
    
    -- Cache miss or stale - check directly
    local isMasked, isReliable = TAZC_Anonymity.checkMaskDirect(player)
    
    -- Only cache if the result is reliable (we had actual clothing data)
    if isReliable then
        TAZC_Anonymity.MaskCache[onlineID] = {
            isMasked = isMasked,
            timestamp = now
        }
        dbg("isMasked: cached reliable result for ID=%d -> %s", onlineID, tostring(isMasked))
    else
        dbg("isMasked: unreliable result for ID=%d (data not synced?), not caching", onlineID)
    end
    
    return isMasked
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Calculate distance between two players in tiles
local function getDistanceBetween(player1, player2)
    if not player1 or not player2 then return 999 end
    
    local ok, distance = pcall(function()
        local x1, y1 = player1:getX(), player1:getY()
        local x2, y2 = player2:getX(), player2:getY()
        return TAZC_Core.distance2D(x1, y1, x2, y2)
    end)
    
    if not ok then return 999 end
    return distance
end

-- Check if item type is in the exception list
local function isInList(itemType, list)
    for _, entry in ipairs(list) do
        if entry == itemType then
            return true
        end
    end
    return false
end

-- ============================================================================
-- MASK DETECTION
-- ============================================================================

--[[
    Direct check if a player is wearing something that hides their identity.
    Called by the caching wrapper isMasked() - do not call directly.

    B42: iterates WornItems by index (avoids the unstable BodyLocations
    global); each entry's getLocation() gives the slot, getItem() the item.

    0.8.16.6 fix -- root cause (cobra report: players showed as masked while
    wearing nothing): getLocation() returns a real
    zombie.scripting.objects.ItemBodyLocation object, not a string (verified
    against the shipped jar and vanilla lua's own usage -- same extraction
    method as the Deaf-trait fix). The old code stringified it
    (tostring(bodyLocation)) and compared against the lowercase
    "base:mask"/"base:fullhat" script keys; that comparison could never
    genuinely match (those keys only exist in the item SCRIPT definition,
    not the runtime object), and calling tostring() on the raw object was
    never proven safe on real Kahlua. tostring() ran unguarded (only
    getLocation()/getItem() themselves were individually pcall-wrapped),
    so any failure there escaped the per-item loop and tripped this
    function's OUTER pcall below -- which used to fail CLOSED (masked) for
    ANY player wearing ANY clothing at all, i.e. everyone. Fixed by
    comparing bodyLocation directly (`==`, object identity) against the
    real ItemBodyLocation global's own fields, the exact idiom vanilla lua
    uses everywhere (e.g. ISInventoryPaneContextMenu.lua:
    wornItem:getLocation() == ItemBodyLocation.SWEATER_HAT) -- no
    stringification anywhere in the hot path.

    Emily's ruling: anonymity is presentation, not security. Every
    unreliable read below (nil container, unsynced size=0, an errored Java
    call) now fails OPEN -- reports NOT masked (the honest name shows) --
    instead of the previous fail-closed default. A read stays uncached
    (reliable=false) whenever it's not backed by genuine data, so a
    following call keeps re-checking and self-heals to the true state
    (masked or not) the moment real data lands, same self-healing shape as
    before, just the opposite starting guess.

    @param player IsoPlayer to check
    @return boolean true if identity is hidden (only ever true on a verified read)
    @return boolean true if the read was reliable (false = fail-open guess, don't cache)
]]
function TAZC_Anonymity.checkMaskDirect(player)
    if not player then return false, true end  -- No player = reliably not masked

    -- Wrap all Java calls in pcall for safety
    local ok, result, reliable = pcall(function()
        -- Get worn items container - this is always available on a valid player
        local wornItems = player:getWornItems()
        dbg("checkMaskDirect: wornItems=%s (type=%s) for %s",
            tostring(wornItems), type(wornItems), tostring(player:getUsername() or "?"))
        if not wornItems then return false, false end  -- Can't get data: fail open

        -- Resolve the configured slot NAMES (see Config.identityHidingSlots)
        -- against the real ItemBodyLocation global's own fields -- a name
        -- with no matching field (typo, or the global itself unavailable)
        -- is skipped rather than erroring.
        local hidingSlots = {}
        if ItemBodyLocation then
            for _, slotName in ipairs(TAZC_Anonymity.Config.identityHidingSlots) do
                local slotObj = ItemBodyLocation[slotName]
                if slotObj then
                    hidingSlots[slotObj] = true
                end
            end
        end

        local size = wornItems:size()
        dbg("checkMaskDirect: checking %d worn items for player %s", size,
            tostring(player:getUsername() or "?"))

        -- B42: remote players may report size=0 before clothing has synced --
        -- unverifiable, so fail open (not masked) instead of hiding an
        -- honest, unmasked name behind a guess; re-checked every call
        -- (reliable=false) until real data lands.
        if size == 0 then
            dbg("checkMaskDirect: wornItems empty for %s -> unreliable, showing honest name until synced",
                tostring(player:getUsername() or "?"))
            return false, false
        end

        for i = 0, size - 1 do
            local wornItem = wornItems:get(i)  -- B42: Returns WornItem wrapper, not InventoryItem
            if wornItem then
                -- WornItem is a tuple: getLocation() for slot, getItem() for the actual item
                local locOk, bodyLocation = pcall(function() return wornItem:getLocation() end)
                local itemOk, actualItem = pcall(function() return wornItem:getItem() end)

                bodyLocation = locOk and bodyLocation or nil

                -- Get item type from the inner InventoryItem
                local itemType = nil
                if itemOk and actualItem then
                    local typeOk, iType = pcall(function() return actualItem:getFullType() end)
                    itemType = typeOk and iType or nil
                end

                dbg("  [%d] %s @ slot present=%s", i, tostring(itemType or "nil"), tostring(bodyLocation ~= nil))

                -- Check 1: Is item in an identity-hiding slot? Object-identity
                -- compare against the real ItemBodyLocation field (see the
                -- function doc above) -- never stringified.
                local slotMatch = bodyLocation and hidingSlots[bodyLocation]
                if slotMatch then
                    -- Check if this specific item is exempt
                    if not isInList(itemType, TAZC_Anonymity.Config.neverHidesIdentity) then
                        dbg("checkMaskDirect: player %s has %s in a hiding slot -> MASKED",
                            tostring(player:getUsername()), tostring(itemType))
                        return true, true  -- Masked, reliable
                    end
                end

                -- Check 2: Is item in the alsoHidesIdentity exception list?
                if isInList(itemType, TAZC_Anonymity.Config.alsoHidesIdentity) then
                    dbg("checkMaskDirect: player %s has exception item %s -> MASKED",
                        tostring(player:getUsername()), tostring(itemType))
                    return true, true  -- Masked, reliable
                end
            end
        end

        dbg("checkMaskDirect: player %s has no identity-hiding items -> NOT MASKED",
            tostring(player:getUsername() or "?"))
        return false, true  -- Not masked, reliable (we had data to check)
    end)

    if not ok then
        dbg("checkMaskDirect: error checking player -- failing OPEN (honest name, uncached): %s", tostring(result))
        return false, false  -- Errored check: fail open (presentation, not security)
    end

    return result, reliable
end

-- ============================================================================
-- MAIN API
-- ============================================================================

--[[
    Get the display name for a speaker from the local player's perspective.
    
    @param speakerPlayer IsoPlayer who is speaking (can be nil if not found)
    @param speakerUsername string username of the speaker
    @param realCharacterName string the speaker's actual character name
    @return string the name to display
    @return boolean true if the speaker is anonymous
    @return boolean true if the speaker is distant (beyond recognition range)
]]
function TAZC_Anonymity.getDisplayName(speakerPlayer, speakerUsername, realCharacterName)
    local localPlayer = getPlayer()
    if not localPlayer then
        return realCharacterName, false, false
    end
    
    -- Check if anonymity system is enabled in sandbox settings
    if TAZC_Config.liveSandbox("AnonymityEnabled", true) == false then
        return realCharacterName, false, false
    end
    
    -- Speaking about yourself?
    local ok, localUsername = pcall(function() return localPlayer:getUsername() end)
    localUsername = ok and localUsername or ""
    if speakerUsername == localUsername then
        -- Self-indicator: if local player is masked, show them as masked to themselves
        -- This lets players know their disguise is working in chat too
        if TAZC_Anonymity.isMasked(localPlayer) then
            return TAZC_Anonymity.Config.maskedName, true, false  -- name, isAnonymous, isDistant
        end
        return realCharacterName, false, false
    end
    
    -- Can't find the speaker player object -- no mask or distance to check
    -- against. Investigated (wave-3): getDisplayName's other two callers
    -- (TAZC_Bio's nameplate loop, TAZC_CharacterSheet.open) both guard for and
    -- only ever pass an already-resolved player object, never nil -- this
    -- branch exists solely for TAZC_Client.onChatMessage's
    -- getPlayerByUsername(msgData.username) lookup, which CAN be nil for a
    -- genuine remote speaker (within the server's own say/yell range, just
    -- not yet streamed to this client). That is an unverified remote
    -- identity, so fail closed here exactly like routeVanillaChatLine's own
    -- unresolvable-speaker branch does, instead of trusting the raw name.
    if not speakerPlayer then
        dbg("getDisplayName: no player object for %s, failing closed to masked", speakerUsername)
        return TAZC_Anonymity.Config.maskedName, true, false
    end
    
    -- Check if player is visible (game's native visibility system)
    -- B42: Use checkCanSeeClient() which handles depth buffer, vision cones, 
    -- ghost mode, and faction visibility. IsVisibleToPlayer is deprecated.
    local visOk, canSee = pcall(function() 
        return localPlayer:checkCanSeeClient(speakerPlayer)
    end)
    dbg("getDisplayName: %s visibility check: visOk=%s, canSee=%s (type=%s)",
        speakerUsername, tostring(visOk), tostring(canSee), type(canSee))
    -- Not visible, OR the visibility check itself errored: either way we
    -- can't confirm the speaker is recognizable, so both resolve anonymous.
    -- An errored read fails closed here exactly like checkMaskDirect's own
    -- errored Java calls do, rather than falling through to the distance/
    -- mask checks below on a visibility state we never actually verified.
    if not visOk or canSee == false then
        dbg("getDisplayName: %s is not visible to local player -> '%s'", 
            speakerUsername, TAZC_Anonymity.Config.distantName)
        return TAZC_Anonymity.Config.distantName, true, true
    end
    
    -- Check z-level (different floors = can't recognize)
    local zOk1, localZ = pcall(function() return localPlayer:getZ() end)
    local zOk2, speakerZ = pcall(function() return speakerPlayer:getZ() end)
    localZ = zOk1 and localZ or 0
    speakerZ = zOk2 and speakerZ or 0
    if math.floor(localZ) ~= math.floor(speakerZ) then
        dbg("getDisplayName: %s is on different floor (z=%d vs %d) -> '%s'", 
            speakerUsername, math.floor(speakerZ), math.floor(localZ), TAZC_Anonymity.Config.distantName)
        return TAZC_Anonymity.Config.distantName, true, true
    end
    
    -- Calculate distance
    local distance = getDistanceBetween(localPlayer, speakerPlayer)

    -- Recognition range tracks SayRange. If you can hear someone, you can
    -- recognize them. Falls back to the fixed 15-tile default if TAZC_Config
    -- hasn't been populated yet (pre-sandbox-sync).
    local recognitionRange = TAZC_Config.Ranges.say or TAZC_Anonymity.Config.recognitionRange
    local inRange = distance <= recognitionRange
    
    dbg("getDisplayName: %s at distance %.1f (range=%d, inRange=%s)",
        speakerUsername, distance, recognitionRange, tostring(inRange))
    
    -- Beyond recognition range = "Someone"
    if not inRange then
        dbg("getDisplayName: %s is distant -> '%s'", 
            speakerUsername, TAZC_Anonymity.Config.distantName)
        return TAZC_Anonymity.Config.distantName, true, true  -- name, isAnonymous, isDistant
    end
    
    -- Within range but masked = "A Masked Figure"
    if TAZC_Anonymity.isMasked(speakerPlayer) then
        dbg("getDisplayName: %s is masked -> '%s'", 
            speakerUsername, TAZC_Anonymity.Config.maskedName)
        return TAZC_Anonymity.Config.maskedName, true, false  -- name, isAnonymous, isDistant
    end
    
    -- Within range and unmasked = real name
    dbg("getDisplayName: %s is recognizable -> '%s'",
        speakerUsername, realCharacterName)
    return realCharacterName, false, false  -- name, isAnonymous, isDistant
end

-- ============================================================================
-- SIGHT (R-A2/R-A3/R-A6/R-A9) -- signed-modality display gate + the Deaf
-- reception ladder. Reuses the exact LOS + z-level primitive getDisplayName
-- already runs (checkCanSeeClient + the z-floor compare), pulled out here
-- so a caller that needs a plain "can I see them" boolean -- not a full
-- name resolution -- doesn't re-derive the pcall/fail-closed dance.
--
-- TRUST NOTE (R-A3): this is a CLIENT-side read, the only place the
-- checkCanSeeClient primitive exists -- the exact same documented tamper
-- class as every mask/distance check elsewhere in this module. A modified
-- client could lie about what it can see. Server-side range gating
-- (routeProximity's existing channel ranges) is the only enforcement that
-- can't be spoofed; sight is a display-layer refinement on top of it, not
-- a security boundary.
-- ============================================================================

--[[
    Can the local player currently see `otherPlayer`? Fails CLOSED (false)
    on no local player, no otherPlayer, an errored Java call, or a
    different floor -- "cannot verify" always means "not shown", never
    "shown by default."
    @return boolean
]]
function TAZC_Anonymity.canSee(otherPlayer)
    if not otherPlayer then return false end
    local localPlayer = getPlayer()
    if not localPlayer then return false end

    -- M5 fix: self-exemption, same precedent as getDisplayName's own
    -- explicit self-case above ("Speaking about yourself?") -- a signer
    -- must always see their own signs. checkCanSeeClient is built to
    -- answer "can I see THAT OTHER player"; whether it behaves sanely when
    -- asked about yourself is untested (LIVE-VERIFICATION-NEEDED on
    -- cobra). Comparing usernames sidesteps the question rather than
    -- trusting an edge case of a primitive built for someone else. An
    -- errored username read falls through to the normal check below.
    local selfOk, isSelf = pcall(function()
        return otherPlayer:getUsername() == localPlayer:getUsername()
    end)
    if selfOk and isSelf then return true end

    local visOk, canSee = pcall(function()
        return localPlayer:checkCanSeeClient(otherPlayer)
    end)
    if not visOk or canSee ~= true then return false end

    local zOk1, localZ = pcall(function() return localPlayer:getZ() end)
    local zOk2, otherZ = pcall(function() return otherPlayer:getZ() end)
    if not zOk1 or not zOk2 then return false end
    return math.floor(localZ) == math.floor(otherZ)
end

--[[
    Is the LOCAL player Deaf (base:deaf trait, R-A6)? LIVE-VERIFIED
    (cobra incident, 0.8.16.6): the prior accessor --
    `player:getTraits():contains("Deaf")` -- crashed on real Kahlua
    (getTraits() is not a real instance method PZ exposes for a
    membership check; it doesn't appear anywhere in vanilla lua) and the
    resulting error escaped this function's own pcall, propagating all
    the way up through deafReception/onChatMessage to the visible client
    error every hearing player saw as a "..." bubble.

    The real, vanilla-proven idiom is `character:hasTrait(CharacterTrait.X)`
    -- used dozens of times across vanilla lua (ISBuildAction, ISHandcraft-
    Action, ISVehicleMenu, forageSystem, ISCraftAction, ...) with NO extra
    guarding, meaning the engine treats it as always-safe to call. Verified
    directly against the shipped projectzomboid.jar:
    zombie.scripting.objects.CharacterTrait carries a DEAF field whose
    string value is "Deaf" -- the exact same PascalCase pattern as
    HANDY -> "Handy". `CharacterTrait.DEAF` is used as the primary idiom;
    the raw string "Deaf" is a fallback only for the (should-never-happen)
    case where the CharacterTrait global itself isn't available.

    Fails to `false` (NOT Deaf) on ANY error: a broken read must never
    silently mute a hearing player's ordinary chat.
    @return boolean
]]
function TAZC_Anonymity.localPlayerIsDeaf()
    local ok, isDeaf = pcall(function()
        local p = getPlayer()
        if not p then return false end
        local traitType = (CharacterTrait and CharacterTrait.DEAF) or "Deaf"
        return p:hasTrait(traitType) == true
    end)
    if not ok then
        dbg("localPlayerIsDeaf: trait check errored, treating as NOT deaf: %s", tostring(isDeaf))
        return false
    end
    return isDeaf == true
end

--[[
    How should a Deaf local player perceive a SPOKEN message from
    `speakerPlayer`? Returns { mode = "full"|"nothing"|"presence"|"lipread" }:
      "full"     -- not Deaf, or the sandbox has the trait's enforcement off
                    -- unaffected, normal spoken-language rendering applies.
      "nothing"  -- Deaf and no sight of the speaker at all (no LOS, wrong
                    floor, through a wall) -- speech through walls is nothing.
      "presence" -- Deaf, sight confirmed, but beyond conversational range
                    (AddressedDistance) -- real lipreading dies with distance.
      "lipread"  -- Deaf, sight confirmed, within conversational range --
                    caller gaps the message (see shared/TAZC_Lipread.lua).
    Never "improvable to full" -- lipreading stays lossy at any distance
    inside range; this ladder has no state that climbs toward comprehension.

    OUTER SAFETY NET (0.8.16.6, cobra incident): the whole ladder runs
    inside its own pcall. Each step below (localPlayerIsDeaf, canSee,
    the distance read) already fails closed/open internally, but this
    outer guard is belt-and-suspenders -- if ANY of them ever lets an
    error escape their own pcall for a reason not yet seen, that error
    must still resolve to "full" here, never leave a hearing player's
    spoken message muffled or dropped because a Deaf-check hiccuped.
]]
function TAZC_Anonymity.deafReception(speakerPlayer)
    local ok, result = pcall(function()
        if TAZC_Config.liveSandbox("DeafTraitEnforced", true) == false then
            return { mode = "full" }
        end
        if not TAZC_Anonymity.localPlayerIsDeaf() then
            return { mode = "full" }
        end
        if not TAZC_Anonymity.canSee(speakerPlayer) then
            return { mode = "nothing" }
        end
        local localPlayer = getPlayer()
        local distance = getDistanceBetween(localPlayer, speakerPlayer)
        local addressedDistance = (TAZC_Config.Lang and TAZC_Config.Lang.addressedDistance) or 6
        if distance <= addressedDistance then
            return { mode = "lipread" }
        end
        return { mode = "presence" }
    end)
    if not ok then
        dbg("deafReception: errored, failing OPEN to 'full': %s", tostring(result))
        return { mode = "full" }
    end
    return result
end

--[[
    Convenience function to transform message data in place.
    Modifies msgData.characterName if the speaker should be anonymous.
    
    @param msgData table with username, characterName fields
    @param speakerPlayer IsoPlayer who is speaking (optional, will lookup if nil)
    @return boolean true if the name was anonymized
]]
function TAZC_Anonymity.anonymizeMessageData(msgData, speakerPlayer)
    if not msgData or not msgData.username then return false end
    
    local displayName, isAnonymous, isDistant = TAZC_Anonymity.getDisplayName(
        speakerPlayer,
        msgData.username,
        msgData.characterName or msgData.username
    )
    
    if isAnonymous then
        msgData.characterName = displayName
        msgData.isAnonymous = true
        msgData.isDistant = isDistant  -- true = hide avatar, false = masked but visible
        -- Neutralize the signature name color too (masked and distant alike):
        -- keeping it would let regulars identify masks at a glance.
        msgData.playerColor = TAZC_Anonymity.Config.anonymousColor
    end

    return isAnonymous
end

--[[
    Radio variant of anonymizeMessageData.

    DESIGN DECISION (0.8.16.3): radio ignores DISTANCE but still honours the
    MASK. A voice on the radio is recognisable however far the speaker is, so
    the "Someone" (past recognition range) and "A Voice on the Radio"
    (cross-cell) anonymisations do NOT apply -- the real name the server sent
    is shown. But a MASK is a deliberate act of anonymity: someone
    roleplaying a hidden identity shouldn't be outed just because their hot
    mic reaches a listener past a wall or sightline. So a masked speaker
    still renders as "A Masked Figure" on the radio line, exactly as they do
    in proximity chat.

    The mask can only be checked when the speaker's player object is loaded on
    this client -- which is precisely the nearby / in-sightline case the mask
    is meant to protect. A genuinely cross-cell speaker (no player object)
    can't be seen at all, so there's no meta-reveal to guard against and the
    real name is shown.

    @param msgData table with username, characterName fields
    @param speakerPlayer IsoPlayer who is speaking (nil if not loaded here)
    @return boolean true if the name was anonymised (masked speaker only)
]]
function TAZC_Anonymity.anonymizeRadioMessageData(msgData, speakerPlayer)
    if not msgData or not msgData.username then return false end

    -- Anonymity disabled server-wide: real names everywhere, radio included.
    if TAZC_Config.liveSandbox("AnonymityEnabled", true) == false then
        return false
    end

    -- Mask honoured, distance ignored. Same field contract as the proximity
    -- masked branch (name + neutral colour, avatar kept) so a masked radio
    -- line looks identical to a masked proximity line.
    if speakerPlayer and TAZC_Anonymity.isMasked(speakerPlayer) then
        dbg("anonymizeRadioMessageData: %s is masked -> '%s'",
            tostring(msgData.username), TAZC_Anonymity.Config.maskedName)
        msgData.characterName = TAZC_Anonymity.Config.maskedName
        msgData.isAnonymous = true
        msgData.isDistant = false  -- masked, but a real person, not a distant blur
        msgData.playerColor = TAZC_Anonymity.Config.anonymousColor
        return true
    end

    -- Unmasked, or cross-cell (can't check the mask, but out of sightline
    -- anyway): show the real name the server put in msgData.characterName.
    return false
end

-- ============================================================================
-- EVENT HOOKS
-- ============================================================================

--[[
    Hook OnClothingUpdated to keep mask cache fresh.
    This fires whenever any character's clothing changes (equip, unequip, dirty/bloody).
    Much more efficient than polling getWornItems() every frame.
]]
local function onClothingUpdated(character)
    if not character then return end
    
    -- Update cache for this character
    TAZC_Anonymity.updateMaskCache(character)
end

-- Register the hook
Events.OnClothingUpdated.Add(onClothingUpdated)
dbg("OnClothingUpdated hook registered for mask cache")

return TAZC_Anonymity
