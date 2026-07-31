--[[
================================================================================
    Terror AustraliZ Chat - Player Identity (Client): nameplates, bio, and notes

    Owns everything client-side about a player's identity beyond the chat
    line itself:
      - Custom nameplate rendering: replaces vanilla player nameplates,
        character name + tagline as one anchored unit, with distance fade
        and LOS-gated visibility (TAZC_NameplatePanel).
      - Tagline / character-sheet description CRUD: local cache, the
        request/save round trip to the server's Bio*/Desc* commands, and
        the BioData/DescData/BioSyncAll sync handlers that populate it.
      - Personal notes: your own private remarks about another player
        (Note* commands) -- nobody else ever sees them.
      - The right-click "Character Sheet" context-menu entry that opens
        TAZC_CharacterSheet, and the fresh-character wipe that keeps a
        re-rolled character from wearing a dead one's bio.
      - Shared helpers other client modules require this file for:
        _getCharacterName (cached, sanitized name-building),
        _findClickedPlayer (context-menu click resolution), and
        _screenPosition (world-to-screen projection) -- each carries its
        own Internal-contract comment at its definition.

    REQUIRES SERVER CONFIG:
    Set DisplayUserName=false in your server INI to disable vanilla names.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Anonymity = require("TAZC_Anonymity")

local dbg = TAZC_Core.debugger("BIO")

local TAZC_Bio = {}

-- ============================================================================
-- CONFIGURATION (can be moved to TAZC_Config later)
-- ============================================================================

local NAMEPLATE_CONFIG = {
    -- Font settings
    nameFont = UIFont.Small,
    taglineFont = UIFont.Small,
    
    -- Colors (RGBA 0-1)
    nameColor = {1.0, 1.0, 1.0, 1.0},           -- White
    taglineColor = {0.85, 0.85, 1.0, 1.0},      -- Brighter blue, full opacity
    shadowColor = {0, 0, 0, 0.7},               -- Darker shadow for contrast
    
    -- Positioning - below action bar, bubbles render above
    offsetY = 110,
    yAdjust = TAZC_Core.Display.BUBBLE_Y_ADJUST,
    lineSpacing = 2,                             -- Pixels between name and tagline
    
    -- Limits
    maxTaglineLength = 80,
    
    -- Visibility
    maxDistance = 15,                            -- Tiles - don't render nameplates beyond this
    fadeStartDistance = 12,                      -- Start fading at this distance
}

-- This is the tagline limit TAZC_Bio.saveTagline actually enforces (below);
-- exposed so TAZC_CharacterSheet's tagline entry box caps input at the same
-- number instead of keeping its own separate literal that could drift.
TAZC_Bio.MAX_TAGLINE_LENGTH = NAMEPLATE_CONFIG.maxTaglineLength

-- LOS nameplate visibility constants
local LOS_CHECK_INTERVAL_MS = 200              -- Throttle checkCanSeeClient calls (ms)
local LOS_GRACE_MS = 1500                      -- Grace period before hiding after LOS lost
local LOS_FADE_MS = 500                        -- Fade duration at tail end of grace period

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

-- Cache of username -> tagline
local bioCache = {}

-- Cache of username -> character-sheet description (longer free text, shown on
-- the sheet rather than the nameplate)
local descCache = {}
local MAX_DESCRIPTION_LENGTH = 500

-- This is the description limit sanitizeDescription actually enforces
-- (below); exposed so TAZC_CharacterSheet's description (and private-notes)
-- entry boxes cap input at the same number instead of keeping their own
-- separate literal that could drift.
TAZC_Bio.MAX_DESCRIPTION_LENGTH = MAX_DESCRIPTION_LENGTH

-- Cache of target-username -> MY private note about them (only I ever see it)
local noteCache = {}

-- Cache of username -> {forename, surname} (to avoid descriptor calls every frame)
local nameCache = {}

-- Track active nameplate panels
local activeNameplates = {}  -- username -> panel

-- Fresh-character bio probe (see TAZC_Bio.clearTaglineForFreshCharacter):
-- the BioData reply tells us whether the previous character actually had
-- a tagline worth telling the player about.
local pendingFreshBioNotice = nil  -- {username, expiresAt}
local FRESH_BIO_NOTICE_WINDOW_MS = 30000  -- Give the reply 30 seconds

-- ============================================================================
-- SAFETY UTILITIES
-- ============================================================================

-- Nil-is-failure contract; see TAZC_Core.safeGet/safeExec for why that
-- differs from TAZC_Core.safe. Kept under this file's own names since every
-- call site here already uses them.
local safeGet = TAZC_Core.safeGet
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then
        dbg("safeExec failed: %s", tostring(err))
    end
    return ok
end

local function sanitizeString(str)
    if not str or type(str) ~= "string" then
        return ""
    end
    str = str:gsub("[%c]", "")  -- Remove all control chars
    str = str:match("^%s*(.-)%s*$") or ""
    return str
end

-- ============================================================================
-- NAME UTILITIES
-- ============================================================================

--[[
    Get character name from player descriptor.
    Caches result to avoid repeated descriptor access.
]]
local function getCharacterName(player, username)
    if not player or not username then return nil end
    
    -- Check cache first
    if nameCache[username] then
        return nameCache[username]
    end
    
    local name = safeGet(function()
        local desc = player:getDescriptor()
        if not desc then return nil end
        
        local forename = desc:getForename() or ""
        local surname = desc:getSurname() or ""
        
        -- Strip any legacy tagline from surname (in case of old data)
        if surname:find("\n") then
            surname = surname:match("^([^\n]*)") or surname
        end
        
        forename = sanitizeString(forename)
        surname = sanitizeString(surname)
        
        if surname == "" then
            return forename
        elseif forename == "" then
            return surname
        else
            return forename .. " " .. surname
        end
    end, nil)
    
    if name and name ~= "" then
        nameCache[username] = name
        return name
    end
    
    return nil
end

-- Internal contract: getCharacterName is the one cached, sanitizeString-
-- cleaned name builder in the mod -- TAZC_Client (vanilla-shout conversion),
-- TAZC_Bubble (pure-emote fallback), TAZC_CharacterSheet (sheet title), and
-- TAZC_LangAdmin (context-menu target label) all call this instead of
-- re-reading the descriptor themselves, so a single fix to sanitization or
-- the legacy-tagline-in-surname strip covers everyone.
TAZC_Bio._getCharacterName = getCharacterName

-- ============================================================================
-- COORDINATE TRANSFORMATION
-- ============================================================================

--[[
    Shared screen-space projection: world position -> UI element top-left,
    centered horizontally and anchored above the target by its bottom edge.
    IsoUtils + live zoom + centering is identical for the nameplate, every
    speech bubble, and the typing indicator; only what each draws
    (width/height) and how far above the target it floats (offsetY, plus a
    flat yAdjust nudge) differ, so those are parameters.

    Internal contract: also called by TAZC_Bubble and TAZC_Typing (through
    TAZC_Bio._screenPosition) instead of each keeping its own copy of this
    math. Homed here rather than in TAZC_Bubble (the fuller original) because
    TAZC_Bubble requires TAZC_Bio for _getCharacterName -- the reverse
    dependency would cycle.

    @param target   Object with getX/getY/getZ, OR a table {x=, y=, z=}
    @param width    Element width, for horizontal centering
    @param height   Element height, subtracted so the element sits ABOVE
                    the target (pass 0 to skip that, e.g. the typing
                    indicator, which anchors differently)
    @param offsetY  Extra world-scaled vertical lift, divided by zoom
    @param yAdjust  Flat screen-pixel nudge, NOT divided by zoom
    @return x, y screen coordinates, or nil, nil if not calculable
]]
local function screenPosition(target, width, height, offsetY, yAdjust)
    if not target then return nil, nil end

    local localPlayer = getPlayer()
    if not localPlayer then return nil, nil end

    if not IsoUtils then return nil, nil end

    -- Get world coordinates (a plain {x=,y=,z=} table, or an object with
    -- getX/getY/getZ -- TAZC_Bubble's radio bubbles pass ground positions)
    local wx, wy, wz
    if type(target) == "table" and target.x then
        wx, wy, wz = target.x, target.y, target.z or 0
    elseif target.getX then
        wx = safeGet(function() return target:getX() end, nil)
        wy = safeGet(function() return target:getY() end, nil)
        wz = safeGet(function() return target:getZ() end, nil)
    else
        return nil, nil
    end

    if not wx or not wy or not wz then return nil, nil end

    -- Project to screen space
    local x = IsoUtils.XToScreenExact(wx, wy, wz, 0)
    local y = IsoUtils.YToScreenExact(wx, wy, wz, 0)

    -- Get zoom
    local playerNum = safeGet(function() return localPlayer:getPlayerNum() end, 0)
    local zoom = safeGet(function() return getCore():getZoom(playerNum) end, 1)
    if not zoom or zoom <= 0 then zoom = 1 end

    -- Apply zoom scaling
    x = x / zoom - width / 2
    y = y / zoom - height - (offsetY / zoom) - yAdjust

    return x, y
end
TAZC_Bio._screenPosition = screenPosition

--[[
    Calculate distance between two players in tiles
]]
local function getDistance(player1, player2)
    if not player1 or not player2 then return 9999 end
    
    local x1 = safeGet(function() return player1:getX() end, 0)
    local y1 = safeGet(function() return player1:getY() end, 0)
    local x2 = safeGet(function() return player2:getX() end, 0)
    local y2 = safeGet(function() return player2:getY() end, 0)

    return TAZC_Core.distance2D(x1, y1, x2, y2)
end

-- ============================================================================
-- NAMEPLATE PANEL
-- ============================================================================

local TAZC_NameplatePanel = ISPanel:derive("TAZC_NameplatePanel")

function TAZC_NameplatePanel:initialise()
    ISPanel.initialise(self)
end

-- =============================================================================
-- MOUSE PASSTHROUGH
-- Nameplates must not intercept clicks - players need to interact with the world
-- =============================================================================
function TAZC_NameplatePanel:onMouseDown(x, y)
    return false  -- Pass through to world
end

function TAZC_NameplatePanel:onMouseUp(x, y)
    return false
end

function TAZC_NameplatePanel:onRightMouseDown(x, y)
    return false
end

function TAZC_NameplatePanel:onRightMouseUp(x, y)
    return false
end

function TAZC_NameplatePanel:onMouseMove(dx, dy)
    return false
end

function TAZC_NameplatePanel:onMouseMoveOutside(dx, dy)
    return false
end

function TAZC_NameplatePanel:isMouseOver()
    return false  -- Never report as hovered
end

function TAZC_NameplatePanel:prerender()
    -- Update position each frame to follow player
    if not self.player then return end
    
    local localPlayer = getPlayer()
    if not localPlayer then return end
    
    -- Check if player still exists and is alive
    local isAlive = safeGet(function() return self.player:isAlive() end, false)
    if not isAlive then
        self.shouldRemove = true
        return
    end
    
    -- Check if player is invisible (ghost mode, admin invisibility, etc.)
    local isInvisible = safeGet(function() return self.player:isInvisible() end, false)
    if isInvisible then
        self.currentAlpha = 0
        return
    end
    
    -- Check if the game is hiding this player (HidePlayersBehindYou setting)
    -- Players hidden by the engine won't have valid screen positions or will be
    -- flagged as not-to-be-drawn
    local shouldHide = safeGet(function() 
        -- Check if player is being rendered by the game engine
        -- getPlayerSprite returns nil for hidden players in some cases
        if self.player.getPlayerSprite then
            local sprite = self.player:getPlayerSprite()
            if not sprite then return true end
        end
        -- Check if player is in a different cell (can't see across cells)
        local localCell = localPlayer:getCell()
        local otherCell = self.player:getCell()
        if localCell and otherCell and localCell ~= otherCell then
            return true
        end
        return false
    end, false)
    
    if shouldHide then
        self.currentAlpha = 0
        return
    end
    
    -- Calculate distance-based alpha
    local distance = getDistance(localPlayer, self.player)
    if distance > NAMEPLATE_CONFIG.maxDistance then
        self.currentAlpha = 0
        return
    elseif distance > NAMEPLATE_CONFIG.fadeStartDistance then
        local fadeRange = NAMEPLATE_CONFIG.maxDistance - NAMEPLATE_CONFIG.fadeStartDistance
        local fadeProgress = (distance - NAMEPLATE_CONFIG.fadeStartDistance) / fadeRange
        self.currentAlpha = 1 - fadeProgress
    else
        self.currentAlpha = 1
    end
    
    -- LOS visibility check (Line of Sight mode)
    -- Skip for own player (you can always see your own nameplate)
    local visMode = TAZC_Config.liveSandbox("NameplateVisibility", TAZC_Config.Nameplate.visibility)

    if visMode == 2 and not self.isOwnPlayer then
        local now = TAZC_Core.getTimeMs()
        
        -- Throttled LOS check (don't call checkCanSeeClient every frame)
        if (now - self.losLastCheck) >= LOS_CHECK_INTERVAL_MS then
            self.losLastCheck = now
            local losOk, canSee = pcall(function()
                return localPlayer:checkCanSeeClient(self.player)
            end)
            
            if losOk then
                if canSee then
                    -- Visible: clear grace period
                    self.losVisible = true
                    self.losGraceStart = nil
                else
                    -- Not visible: start grace period if just lost LOS
                    if self.losVisible then
                        self.losGraceStart = now
                    end
                    self.losVisible = false
                end
            end
            -- On pcall failure: keep previous state (don't flicker on API error)
        end
        
        -- Apply LOS alpha modulation
        if not self.losVisible and self.losGraceStart then
            local elapsed = TAZC_Core.getTimeMs() - self.losGraceStart
            if elapsed >= LOS_GRACE_MS then
                -- Grace expired: fully hidden
                self.currentAlpha = 0
                return
            elseif elapsed >= (LOS_GRACE_MS - LOS_FADE_MS) then
                -- In fade zone at tail of grace period
                local fadeElapsed = elapsed - (LOS_GRACE_MS - LOS_FADE_MS)
                local fadeProgress = fadeElapsed / LOS_FADE_MS
                self.currentAlpha = self.currentAlpha * (1 - fadeProgress)
            end
            -- else: within grace but before fade zone, show at current alpha
        end
    end
    
    -- Check anonymity (masked or too far to recognize)
    -- getDisplayName handles self-indicator for masked local player
    local speakerUsername = safeGet(function() return self.player:getUsername() end, "")
    
    -- Call getDisplayName directly with pcall to capture both return values
    local displayName, isAnonymous = self.realCharacterName, false
    local ok, name, anon = pcall(function()
        return TAZC_Anonymity.getDisplayName(
            self.player, 
            speakerUsername, 
            self.realCharacterName
        )
    end)
    if ok then
        displayName = name or self.realCharacterName
        isAnonymous = anon or false
    end
    
    self.characterName = displayName
    self.isAnonymous = isAnonymous
    -- Hide tagline when anonymous
    self.tagline = isAnonymous and "" or self.realTagline
    
    -- Update position - if we can't get a screen position, player is likely hidden
    local x, y = screenPosition(self.player, self.width, self.height,
        NAMEPLATE_CONFIG.offsetY, NAMEPLATE_CONFIG.yAdjust)
    if x and y then
        self:setX(x)
        self:setY(y)
    else
        -- No valid screen position means player isn't being rendered
        self.currentAlpha = 0
    end
end

function TAZC_NameplatePanel:render()
    if self.currentAlpha <= 0 then return end
    
    local alpha = self.currentAlpha
    local yOffset = 0
    
    -- Draw name (centered)
    if self.characterName and self.characterName ~= "" then
        local nameWidth = getTextManager():MeasureStringX(NAMEPLATE_CONFIG.nameFont, self.characterName)
        local nameX = (self.width - nameWidth) / 2
        
        -- Shadow
        self:drawText(
            self.characterName,
            nameX + 1, yOffset + 1,
            NAMEPLATE_CONFIG.shadowColor[1],
            NAMEPLATE_CONFIG.shadowColor[2],
            NAMEPLATE_CONFIG.shadowColor[3],
            NAMEPLATE_CONFIG.shadowColor[4] * alpha,
            NAMEPLATE_CONFIG.nameFont
        )
        
        -- Name
        self:drawText(
            self.characterName,
            nameX, yOffset,
            NAMEPLATE_CONFIG.nameColor[1],
            NAMEPLATE_CONFIG.nameColor[2],
            NAMEPLATE_CONFIG.nameColor[3],
            NAMEPLATE_CONFIG.nameColor[4] * alpha,
            NAMEPLATE_CONFIG.nameFont
        )
        
        yOffset = yOffset + self.nameHeight + NAMEPLATE_CONFIG.lineSpacing
    end
    
    -- Draw tagline (centered)
    if self.tagline and self.tagline ~= "" then
        local taglineWidth = getTextManager():MeasureStringX(NAMEPLATE_CONFIG.taglineFont, self.tagline)
        local taglineX = (self.width - taglineWidth) / 2
        
        -- Shadow
        self:drawText(
            self.tagline,
            taglineX + 1, yOffset + 1,
            NAMEPLATE_CONFIG.shadowColor[1],
            NAMEPLATE_CONFIG.shadowColor[2],
            NAMEPLATE_CONFIG.shadowColor[3],
            NAMEPLATE_CONFIG.shadowColor[4] * alpha,
            NAMEPLATE_CONFIG.taglineFont
        )
        
        -- Tagline
        self:drawText(
            self.tagline,
            taglineX, yOffset,
            NAMEPLATE_CONFIG.taglineColor[1],
            NAMEPLATE_CONFIG.taglineColor[2],
            NAMEPLATE_CONFIG.taglineColor[3],
            NAMEPLATE_CONFIG.taglineColor[4] * alpha,
            NAMEPLATE_CONFIG.taglineFont
        )
    end
end

function TAZC_NameplatePanel:new(player, characterName, tagline)
    local textManager = getTextManager()
    
    -- Calculate dimensions for real name
    local nameWidth = 0
    local nameHeight = 0
    local taglineWidth = 0
    local taglineHeight = 0
    
    if characterName and characterName ~= "" then
        nameWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, characterName)
        nameHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.nameFont)
    end
    
    if tagline and tagline ~= "" then
        taglineWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.taglineFont, tagline)
        taglineHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.taglineFont)
    end
    
    -- Also calculate width for anonymity labels (use widest possible)
    local maskedWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, TAZC_Anonymity.Config.maskedName)
    local distantWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, TAZC_Anonymity.Config.distantName)
    local maxNameWidth = math.max(nameWidth, maskedWidth, distantWidth)
    
    local width = math.max(maxNameWidth, taglineWidth) + 20  -- Padding
    local height = nameHeight + taglineHeight + NAMEPLATE_CONFIG.lineSpacing + 4
    
    local o = ISPanel:new(0, 0, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    -- Store real values
    o.realCharacterName = characterName
    o.realTagline = tagline
    -- Display values (updated in prerender based on anonymity)
    o.characterName = characterName
    o.tagline = tagline
    o.isAnonymous = false
    
    o.nameHeight = nameHeight
    o.taglineHeight = taglineHeight
    o.currentAlpha = 1
    o.shouldRemove = false
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor = {r=0, g=0, b=0, a=0}
    
    -- LOS visibility tracking
    o.losVisible = true              -- Assume visible on creation
    o.losLastCheck = 0               -- Last LOS check timestamp
    o.losGraceStart = nil            -- When LOS was lost (nil = has LOS)
    o.isOwnPlayer = false            -- Set by showNameplate()
    
    return o
end

-- ============================================================================
-- NAMEPLATE MANAGEMENT
-- ============================================================================

local function showNameplate(player, username)
    if not player or not username then return end
    
    local characterName = getCharacterName(player, username)
    local tagline = bioCache[username] or ""
    
    -- Skip if no name to display
    if (not characterName or characterName == "") and tagline == "" then
        return
    end
    
    -- Check if we need to update existing panel
    local existing = activeNameplates[username]
    if existing then
        -- Compare against real values (not anonymity-modified display values)
        if existing.realCharacterName == characterName and existing.realTagline == tagline then
            return  -- No change needed
        end
        -- Data changed, remove old panel
        existing:removeFromUIManager()
        activeNameplates[username] = nil
    end
    
    -- Get local player index for UIManager (0 for single player)
    local playerIndex = 0
    local localPlayer = getPlayer()
    if localPlayer and localPlayer.getPlayerNum then
        playerIndex = localPlayer:getPlayerNum() or 0
    end
    
    -- Determine if this is the local player's own nameplate
    local localUsername = safeGet(function() return localPlayer:getUsername() end, "")
    
    -- Create new panel
    local panel = TAZC_NameplatePanel:new(player, characterName, tagline)
    panel.isOwnPlayer = (username == localUsername)
    panel:initialise()
    panel:addToUIManager(playerIndex)
    activeNameplates[username] = panel
    
    dbg("showNameplate: %s = '%s' / '%s'", username, characterName or "", tagline)
end

local function hideNameplate(username)
    if activeNameplates[username] then
        activeNameplates[username]:removeFromUIManager()
        activeNameplates[username] = nil
        dbg("hideNameplate: %s", username)
    end
end

-- ============================================================================
-- UPDATE LOOP
-- ============================================================================

-- Track when we last requested a full sync (in ticks)
local ticksSinceSync = 999 -- Start high so we sync immediately
local SYNC_REQUEST_TICKS = 300 -- About 10 seconds at 30fps

local function updateNameplates()
    local localPlayer = getPlayer()
    if not localPlayer then return end

    local nameplatesEnabled = TAZC_Config.liveSandbox("NameplatesEnabled", true)

    if not nameplatesEnabled then
        -- Remove all active nameplates
        for username, panel in pairs(activeNameplates) do
            panel:removeFromUIManager()
        end
        activeNameplates = {}
        return
    end
    
    local players = getOnlinePlayers()
    if not players then return end
    
    local count = safeGet(function() return players:size() end, 0)
    local seenUsernames = {}
    local missingData = false
    
    local localUsername = safeGet(function() return localPlayer:getUsername() end, nil)
    
    ticksSinceSync = ticksSinceSync + 1
    
    for i = 0, count - 1 do
        local player = safeGet(function() return players:get(i) end, nil)
        
        if player then
            local isAlive = safeGet(function() return player:isAlive() end, false)
            local username = safeGet(function() return player:getUsername() end, nil)
            
            if username then
                seenUsernames[username] = true
                
                -- Check if we're missing tagline data for this player
                if bioCache[username] == nil then
                    missingData = true
                end
                
                local isOwnPlayer = (username == localUsername)
                local hideOwnEnabled = TAZC_Config.liveSandbox("HideOwnNameplate", false)
                local shouldHideOwn = hideOwnEnabled and isOwnPlayer
                
                -- Respect game's visibility system (HidePlayersBehindYou etc)
                -- Don't show nameplates for players the game considers not visible
                -- BUT: staff (admin/mod/GM) often have IsVisibleToPlayer=false even when visible
                local isVisibleToLocal = true
                if not isOwnPlayer then
                    -- Check if player has elevated access (admin, mod, GM, observer)
                    local accessLevel = safeGet(function() return player:getAccessLevel() end, "None")
                    local isStaff = accessLevel and accessLevel ~= "None" and accessLevel ~= ""
                    
                    if isStaff then
                        -- Skip the IsVisibleToPlayer check for staff (unreliable for
                        -- them per the note above); this doesn't bypass real
                        -- invisibility, though -- TAZC_NameplatePanel:prerender()
                        -- independently calls player:isInvisible() every frame and
                        -- zeroes alpha when true, so a truly ghosted/invisible
                        -- staff member's plate still hides regardless of this flag.
                        isVisibleToLocal = true
                    else
                        -- Regular players: respect HidePlayersBehindYou setting
                        isVisibleToLocal = safeGet(function() return player.IsVisibleToPlayer end, true)
                        if isVisibleToLocal == nil then isVisibleToLocal = true end
                    end
                end
                
                if isAlive and not shouldHideOwn and isVisibleToLocal then
                    showNameplate(player, username)
                else
                    hideNameplate(username)
                end
            end
        end
    end
    
    -- If we're missing data and haven't requested recently, request now
    if missingData and isClient() and ticksSinceSync > SYNC_REQUEST_TICKS then
        ticksSinceSync = 0
        safeExec(function()
            sendClientCommand("TAZC", "BioSyncAll", {})
        end)
        dbg("updateNameplates: requested sync (missing data)")
    end
    
    -- Remove nameplates for players no longer online
    for username, panel in pairs(activeNameplates) do
        if not seenUsernames[username] or panel.shouldRemove then
            hideNameplate(username)
        end
    end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function TAZC_Bio.getTagline(username)
    if not username then return nil end
    return bioCache[username]
end

function TAZC_Bio.requestTagline(username)
    if not isClient() then return end
    if not username or username == "" then return end
    
    safeExec(function()
        sendClientCommand("TAZC", "BioLoad", {username = username})
    end)
    dbg("requestTagline: requested %s", username)
end

function TAZC_Bio.requestAllTaglines()
    if not isClient() then return end
    
    safeExec(function()
        sendClientCommand("TAZC", "BioSyncAll", {})
    end)
    dbg("requestAllTaglines: requested full sync")
end

function TAZC_Bio.saveTagline(tagline)
    if not isClient() then return end
    
    local player = getPlayer()
    if not player then return end
    
    tagline = sanitizeString(tagline or "")
    tagline = tagline:sub(1, NAMEPLATE_CONFIG.maxTaglineLength)
    
    local sendSuccess = safeExec(function()
        sendClientCommand("TAZC", "BioSave", {tagline = tagline})
    end)
    
    if not sendSuccess then
        dbg("saveTagline: failed to send to server")
        return
    end
    
    -- Update local cache immediately
    local username = safeGet(function() return player:getUsername() end, nil)
    if username then
        bioCache[username] = tagline
        -- Force nameplate refresh
        hideNameplate(username)
        dbg("saveTagline: cached locally for %s", username)
    end
    
    -- Feedback to player
    safeExec(function()
        if tagline ~= "" then
            player:addLineChatElement("Tagline set: " .. tagline, 0.5, 1, 0.5)
        else
            player:addLineChatElement("Tagline cleared.", 0.7, 0.7, 0.7)
        end
    end)
    
    dbg("saveTagline: '%s'", tagline)
end

-- ============================================================================
-- CHARACTER-SHEET DESCRIPTION
-- A longer free-text description shown on the character sheet (not the
-- nameplate). Parallel to the tagline API above, over the Desc* commands.
-- Multi-line: newlines are preserved end to end (client, server, TAZC_Json).
-- ============================================================================

-- Strip control chars but keep newlines, trim the ends, cap length. The server
-- re-sanitizes identically; this keeps the local cache honest on save.
local function sanitizeDescription(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:match("^%s*(.-)%s*$") or ""
    return text:sub(1, MAX_DESCRIPTION_LENGTH)
end

function TAZC_Bio.getDescription(username)
    if not username then return nil end
    return descCache[username]
end

function TAZC_Bio.requestDescription(username)
    if not isClient() then return end
    if not username or username == "" then return end
    safeExec(function()
        sendClientCommand("TAZC", "DescLoad", {username = username})
    end)
    dbg("requestDescription: requested %s", username)
end

function TAZC_Bio.saveDescription(text)
    if not isClient() then return end

    local player = getPlayer()
    if not player then return end

    text = sanitizeDescription(text or "")

    local sendSuccess = safeExec(function()
        sendClientCommand("TAZC", "DescSave", {description = text})
    end)
    if not sendSuccess then
        dbg("saveDescription: failed to send to server")
        return
    end

    local username = safeGet(function() return player:getUsername() end, nil)
    if username then
        descCache[username] = text
    end

    safeExec(function()
        if text ~= "" then
            player:addLineChatElement("Description saved.", 0.5, 1, 0.5)
        else
            player:addLineChatElement("Description cleared.", 0.7, 0.7, 0.7)
        end
    end)

    dbg("saveDescription: %d chars", #text)
end

-- ============================================================================
-- PERSONAL NOTES (private remarks about ANOTHER player -- only you ever see
-- them). noteCache is keyed by target username = my note about them. Rides the
-- Note* commands, which the server keys strictly to the authenticated sender.
-- ============================================================================

function TAZC_Bio.getNote(targetUsername)
    if not targetUsername then return nil end
    return noteCache[targetUsername]
end

function TAZC_Bio.requestNote(targetUsername)
    if not isClient() then return end
    if not targetUsername or targetUsername == "" then return end
    safeExec(function()
        sendClientCommand("TAZC", "NoteLoad", {target = targetUsername})
    end)
end

function TAZC_Bio.saveNote(targetUsername, text)
    if not isClient() then return end
    if not targetUsername or targetUsername == "" then return end
    local player = getPlayer()
    if not player then return end

    text = sanitizeDescription(text or "")   -- same rules (multi-line, capped)

    local ok = safeExec(function()
        sendClientCommand("TAZC", "NoteSave", {target = targetUsername, note = text})
    end)
    if not ok then return end

    noteCache[targetUsername] = text
    safeExec(function()
        player:addLineChatElement(text ~= "" and "Note saved." or "Note cleared.", 0.5, 1, 0.5)
    end)
end

--[[
    Clear the tagline when a fresh character is created.

    Taglines are keyed by username server-side, so without this a re-rolled
    character walks around wearing the dead character's bio -- visible to
    everyone but the owner. Called from TAZC_ChatPanel's OnCreatePlayer
    detection (the same hook that wipes stale chat history).

    A fresh character has survived zero hours; an existing character
    relogging has already accrued time, so their tagline is left alone.

    @param player IsoPlayer the freshly created player object
]]
function TAZC_Bio.clearTaglineForFreshCharacter(player)
    if not isClient() then return end
    if not player then return end

    local hours = safeGet(function() return player:getHoursSurvived() end, nil)
    if hours == nil or hours > 0 then return end

    local username = safeGet(function() return player:getUsername() end, nil)
    if not username then return end

    -- Ask for the tagline as it stands BEFORE the clear below; the BioData
    -- reply tells us whether there's anything to tell the player about.
    -- Send order matters: the server answers BioLoad before it processes
    -- the clear.
    pendingFreshBioNotice = {
        username = username,
        expiresAt = TAZC_Core.getTimeMs() + FRESH_BIO_NOTICE_WINDOW_MS,
    }
    safeExec(function()
        sendClientCommand("TAZC", "BioLoad", {username = username})
    end)

    -- Clear via the existing BioSave path. Harmless no-op if the previous
    -- character (or a first-ever character) had no tagline.
    safeExec(function()
        sendClientCommand("TAZC", "BioSave", {tagline = ""})
    end)

    bioCache[username] = ""
    hideNameplate(username)

    -- Descriptions are keyed by username too, so without this a re-rolled
    -- character would wear the dead character's description on the sheet.
    -- Clear it the same way the tagline is cleared just above.
    safeExec(function()
        sendClientCommand("TAZC", "DescSave", {description = ""})
    end)
    descCache[username] = ""

    -- A new character is a new person: reset this identity's whole note graph
    -- (my notes about others AND everyone's notes about me). Server keys it to
    -- the sender, so this only ever resets me.
    safeExec(function()
        sendClientCommand("TAZC", "NoteClearAbout", {})
    end)
    for k in pairs(noteCache) do noteCache[k] = nil end

    dbg("clearTaglineForFreshCharacter: cleared tagline + description + notes for %s", username)
end

-- ============================================================================
-- CONTEXT MENU
-- ============================================================================

local function onViewBio(player)
    -- Open the character sheet: editable for your own character, read-only and
    -- anonymity-gated for anyone else. Lazy require keeps the sheet module off
    -- TAZC_Bio's load-order path.
    local ok, TAZC_CharacterSheet = pcall(require, "TAZC_CharacterSheet")
    if ok and TAZC_CharacterSheet then
        safeExec(function() TAZC_CharacterSheet.open(player) end)
    else
        dbg("onViewBio: TAZC_CharacterSheet unavailable")
    end
end

-- Find an IsoPlayer under the cursor: walks worldObjects -> square ->
-- movingObjects, returning the first IsoPlayer found.
--
-- Internal contract: shared with TAZC_Avatar and TAZC_LangAdmin's own
-- context-menu handlers, which mirrored this exact resolution before
-- converging on it -- a click can only ever resolve one way.
local function findClickedPlayer(worldObjects)
    for _, worldObj in ipairs(worldObjects or {}) do
        local square = safeGet(function() return worldObj:getSquare() end, nil)
        if square then
            local movingObjects = safeGet(function() return square:getMovingObjects() end, nil)
            if movingObjects then
                local objCount = safeGet(function() return movingObjects:size() end, 0)
                for j = 0, objCount - 1 do
                    local obj = safeGet(function() return movingObjects:get(j) end, nil)
                    if obj and instanceof(obj, "IsoPlayer") then
                        return obj
                    end
                end
            end
        end
    end
    return nil
end
TAZC_Bio._findClickedPlayer = findClickedPlayer

local function onContextMenu(player, context, worldObjects, test)
    if test then return true end

    local playerObj = safeGet(function() return getSpecificPlayer(player) end, nil)
    if not playerObj then return end

    local clickedPlayer = findClickedPlayer(worldObjects)

    if clickedPlayer then
        local username = safeGet(function() return clickedPlayer:getUsername() end, nil)
        if username then
            TAZC_Bio.requestTagline(username)
            TAZC_Bio.requestDescription(username)

            safeExec(function()
                if clickedPlayer == playerObj then
                    context:addOption("Character Sheet", clickedPlayer, onViewBio)
                else
                    context:addOption("View Character Sheet", clickedPlayer, onViewBio)
                end
            end)
        end
    end
end

-- ============================================================================
-- SERVER COMMAND HANDLERS
-- ============================================================================

local function onServerCommand(module, command, args)
    if module ~= "TAZC" then return end
    if not args then return end
    
    if command == "BioUpdate" then
        if args.username then
            local tagline = sanitizeString(args.tagline or "")
            bioCache[args.username] = tagline
            -- Force nameplate refresh for this player
            hideNameplate(args.username)
            dbg("BioUpdate: %s = '%s'", args.username, tagline)
        end
        
    elseif command == "BioData" then
        if args.username then
            local tagline = sanitizeString(args.tagline or "")

            -- Expire a stale fresh-character probe (reply never came in time)
            if pendingFreshBioNotice and TAZC_Core.getTimeMs() > pendingFreshBioNotice.expiresAt then
                pendingFreshBioNotice = nil
            end

            if pendingFreshBioNotice and args.username == pendingFreshBioNotice.username then
                -- Reply to the fresh-character probe: this is the tagline as
                -- it stood before clearTaglineForFreshCharacter wiped it.
                -- Don't cache the stale value -- just tell the player if
                -- their new character was still wearing the old bio.
                pendingFreshBioNotice = nil
                if tagline ~= "" then
                    local localPlayer = getPlayer()
                    if localPlayer then
                        safeExec(function()
                            localPlayer:addLineChatElement("Your bio still described your previous character -- it's been cleared. /bio to write a new one.", 0.7, 0.7, 0.7)
                        end)
                    end
                end
                dbg("BioData: fresh-character probe for %s (had tagline=%s)",
                    args.username, tostring(tagline ~= ""))
            else
                bioCache[args.username] = tagline
                dbg("BioData: %s = '%s'", args.username, tagline)
            end
        end
        
    elseif command == "BioSyncAll" then
        if args.bios and type(args.bios) == "table" then
            local syncCount = 0
            for username, tagline in pairs(args.bios) do
                if username and type(username) == "string" then
                    bioCache[username] = sanitizeString(tagline or "")
                    syncCount = syncCount + 1
                end
            end
            
            -- Mark all visible players as synced (empty string if no tagline)
            local players = getOnlinePlayers()
            if players then
                local count = safeGet(function() return players:size() end, 0)
                for i = 0, count - 1 do
                    local player = safeGet(function() return players:get(i) end, nil)
                    if player then
                        local username = safeGet(function() return player:getUsername() end, nil)
                        if username and bioCache[username] == nil then
                            bioCache[username] = ""
                        end
                    end
                end
            end
            
            dbg("BioSyncAll: received %d bios", syncCount)
        end

        -- Descriptions ride the same full-sync payload (additive field).
        if args.descriptions and type(args.descriptions) == "table" then
            for username, desc in pairs(args.descriptions) do
                if type(username) == "string" then
                    descCache[username] = sanitizeDescription(desc or "")
                end
            end
        end

    elseif command == "DescUpdate" then
        if args.username then
            descCache[args.username] = sanitizeDescription(args.description or "")
            dbg("DescUpdate: %s (%d chars)", args.username, #descCache[args.username])
        end

    elseif command == "DescData" then
        if args.username then
            descCache[args.username] = sanitizeDescription(args.description or "")
            dbg("DescData: %s (%d chars)", args.username, #descCache[args.username])
        end

    elseif command == "NoteData" then
        if args.target then
            noteCache[args.target] = sanitizeDescription(args.note or "")
        end

    elseif command == "NoteAboutCleared" then
        if args.target then
            noteCache[args.target] = nil
        end
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function OnGameStart()
    dbg("OnGameStart: requesting tagline sync")
    TAZC_Bio.requestAllTaglines()
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

safeExec(function() Events.OnServerCommand.Add(onServerCommand) end)
safeExec(function() Events.OnFillWorldObjectContextMenu.Add(onContextMenu) end)
safeExec(function() Events.OnGameStart.Add(OnGameStart) end)

-- Update nameplates each tick
safeExec(function() Events.OnTick.Add(updateNameplates) end)

dbg("=== TAZC_Bio module loaded (Player Identity: nameplates, bio, notes) ===")

return TAZC_Bio
