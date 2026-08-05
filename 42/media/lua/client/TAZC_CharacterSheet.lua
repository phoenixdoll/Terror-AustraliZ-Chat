--[[
================================================================================
    Terror AustraliZ Chat - Character Sheet (client UI)

    A right-click "Character Sheet" window: a full-body 3D view of the
    character on the left, and their name, tagline, and a longer
    description / history on the right.

      - YOUR OWN sheet is EDITABLE: set your tagline (still also settable with
        /bio) and write a description. One Save writes both.
      - SOMEONE ELSE'S sheet is READ-ONLY and honours the anonymity system --
        a masked or unrecognised person shows only their anonymous shell, never
        a real name, tagline, or description. The 3D body still shows for anyone
        you can actually see (a masked figure shows their masked in-world
        appearance -- it leaks nothing you can't already see standing in front
        of you, exactly like the speech-bubble portrait); it's hidden only for
        a distant / out-of-sight person.

    The model uses the same UI3DModel:setCharacter recipe the speech bubbles
    already rely on. Data + network live in TAZC_Bio (the Desc* commands); this
    file is presentation only, and every engine call is pcall-guarded -- a
    vanilla UI drift costs the window, never the session.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Bio = require("TAZC_Bio")
local TAZC_Anonymity = require("TAZC_Anonymity")
local TAZC_ChatPanel = require("TAZC_ChatPanel")

local dbg = TAZC_Core.debugger("SHEET")

local TAZC_CharacterSheet = {}

-- Tagline/description caps single-sourced from TAZC_Bio (the file that
-- actually enforces them, in saveTagline/sanitizeDescription) -- kept here
-- as a second literal, they'd only be able to drift out of sync.
local PAD = 12

-- Window + model framing. The two model knobs (zoom / y-offset) are the ones
-- to tune by eye: higher zoom = closer, lower = more of the body in frame.
local WIN_W, WIN_H = 420, 470
local MODEL_W = 150
-- Full-body framing, taken from Spongie's Character Customisation zoom table:
-- zoom 0 / yOffset -0.5 is the fully zoomed-OUT whole-body view. (Its most
-- zoomed-IN level is zoom 18 / yOffset -0.875, ~ the speech-bubble bust.)
local MODEL_ZOOM = 0
local MODEL_YOFFSET = -0.5
local BG_ALPHA = 0.55   -- window background opacity (semi-transparent)

-- Nil-is-failure contract; see TAZC_Core.safeGet/safeExec for why that
-- differs from TAZC_Core.safe. Kept under this file's own names since every
-- call site here already uses them.
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then dbg("sheet safeExec failed: %s", tostring(err)) end
    return ok
end

local safeGet = TAZC_Core.safeGet

-- Split a string into paragraphs on newline boundaries (no pattern magic, so
-- it's Kahlua-safe and stable on any byte content).
local function splitParagraphs(text)
    local out, acc = {}, ""
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "\n" then
            out[#out + 1] = acc
            acc = ""
        else
            acc = acc .. ch
        end
    end
    out[#out + 1] = acc
    return out
end

-- Greedy word-wrap: honour existing line breaks, then wrap each paragraph to
-- the available pixel width via TAZC_ChatPanel's shared wrap core (the same
-- glyph-overhang-corrected loop TAZC_Bubble uses) -- this file only adds the
-- paragraph split on top. An empty paragraph maps to one blank line, which
-- is exactly what the shared core already returns for an empty string.
local function wrapText(text, font, maxWidth)
    local lines = {}
    for _, paragraph in ipairs(splitParagraphs(text)) do
        for _, ln in ipairs(TAZC_ChatPanel._wrapWords(paragraph, font, maxWidth)) do
            lines[#lines + 1] = ln
        end
    end
    return lines
end

-- Internal contract: wrapText is otherwise only called from renderContent(),
-- which needs a live ISCollapsableWindow to exercise -- exposed so the
-- offline harness can pin the paragraph-split + shared-wrap-core behavior
-- directly.
TAZC_CharacterSheet._wrapText = wrapText

-- Static per-breed portrait for a dog sheet, borrowed directly from
-- CompanionDogs' own shipped art (media/textures/CDPortrait_<breedKey>.png)
-- rather than the 3D model -- even with the right anim set bound, that came
-- out visibly distorted (a human-rig model panel isn't built for an animal
-- skeleton). PZ merges every loaded mod's media folder into one lookup
-- space, so this resolves fine as long as CompanionDogs is present, which
-- it must be for a dog sheet to exist at all. Falls back to CompanionDogs'
-- own generic paw icon, same as its Kennel UI does for the same case.
local dogPortraitCache = {}
local function dogPortraitTexture(dog)
    local CD = _G.CompanionDogs
    if not CD then return nil end
    local breedKey = safeGet(function() return CD.getBreed(dog) end, nil) or "default"
    local tex = dogPortraitCache[breedKey]
    if tex == nil then
        tex = getTexture("media/textures/CDPortrait_" .. breedKey .. ".png")
            or getTexture("media/textures/CDDogPaw_48.png")
            or false
        dogPortraitCache[breedKey] = tex
    end
    return tex or nil
end

-- ============================================================================
-- WINDOW
-- ============================================================================

local Sheet = ISCollapsableWindow:derive("TAZC_CharacterSheetWindow")
local instance = nil

function Sheet:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "Character Sheet"
    o.resizable = false
    o.targetPlayer = nil
    o.targetUsername = nil
    o.realName = nil
    o.editable = false
    o.isDog = false
    o.breedName = nil
    -- Semi-transparent body so the game shows through behind the card.
    o.backgroundColor = { r = 0.05, g = 0.05, b = 0.08, a = BG_ALPHA }
    return o
end

function Sheet:createChildren()
    ISCollapsableWindow.createChildren(self)

    local tm = getTextManager()
    local lineH = tm:getFontHeight(UIFont.Small) + 2
    local medH = tm:getFontHeight(UIFont.Medium)
    self.contentTop = self:titleBarHeight() + 8
    self.modelH = self.height - self.contentTop - PAD

    -- Full-body character model on the left. ISUI3DModel is the vanilla
    -- panel wrapper -- the same approach Spongie's Character Customisation
    -- uses on this B42 build: addChild it, then configure. Anonymity is
    -- enforced per frame by toggling its visibility in render.
    --
    -- Dogs skip the 3D model entirely: even with the right anim set bound,
    -- it came out visibly broken/distorted (a human-rig model panel isn't
    -- built for an animal skeleton). A static per-breed portrait image
    -- goes in the same slot instead -- see dogPortraitTexture above.
    if not self.isDog then
        safeExec(function()
            self.model = ISUI3DModel:new(PAD, self.contentTop, MODEL_W, self.modelH)
            self.model.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
            self.model.borderColor = { r = 1, g = 1, b = 1, a = 0 }
            self:addChild(self.model)
            self.model:setCharacter(self.targetPlayer)
            self.model:setDirection(IsoDirections.S)
            self.model:setState("idle")
            self.model:setIsometric(false)
            self.model:setDoRandomExtAnimations(false)
            self.model:setZoom(MODEL_ZOOM)
            self.model:setYOffset(MODEL_YOFFSET)
        end)
    else
        self.dogPortrait = dogPortraitTexture(self.targetPlayer)
    end

    if self.isDog then
        -- Same left-portrait / right-column layout as a player sheet, just
        -- with a static image in the slot instead of a live 3D model.
        self.rx = PAD + MODEL_W + 14
        self.rw = self.width - self.rx - PAD
        self.nameY = self.contentTop

        -- Dog sheet: no tagline/description (dogs don't have one), no
        -- anonymity gate (not part of the human masking system) -- just
        -- the name/breed up top and a private-notes box filling the rest.
        local saveY = self.height - 30
        local notesTop = self.nameY + medH + 8 + lineH + 8
        local notesH = math.max(60, saveY - 8 - notesTop)
        local notesY = saveY - 8 - notesH
        self.notesLabelY = notesY - lineH - 2

        self.initialNote = TAZC_Bio.getNote(self.targetUsername) or ""
        self.lastSetNote = self.initialNote

        self.notesEntry = ISTextEntryBox:new(self.initialNote, self.rx, notesY, self.rw, notesH)
        self.notesEntry:initialise()
        self.notesEntry:instantiate()
        self.notesEntry:setMultipleLine(true)
        self.notesEntry:setMaxTextLength(TAZC_Bio.MAX_DESCRIPTION_LENGTH)
        self:addChild(self.notesEntry)

        self.notesSaveButton = ISButton:new(self.rx + self.rw - 60, saveY, 60, 22, "Save", self, Sheet.onSaveNote)
        self.notesSaveButton:initialise()
        self:addChild(self.notesSaveButton)
        return
    end

    -- Right column geometry (shared by the two human-player modes below).
    self.rx = PAD + MODEL_W + 14
    self.rw = self.width - self.rx - PAD
    self.nameY = self.contentTop
    self.taglineLabelY = self.nameY + medH + 8

    if not self.editable then
        -- Read-only sheet of another player. The ONE editable thing is your
        -- PRIVATE notes about them, bottom-anchored so the description fills the
        -- space above. Nobody else ever sees these.
        local saveY = self.height - 30
        local notesH = 74
        local notesY = saveY - 8 - notesH
        self.notesLabelY = notesY - lineH - 2
        self.descBottomY = self.notesLabelY - 6

        self.initialNote = TAZC_Bio.getNote(self.targetUsername) or ""
        self.lastSetNote = self.initialNote

        self.notesEntry = ISTextEntryBox:new(self.initialNote, self.rx, notesY, self.rw, notesH)
        self.notesEntry:initialise()
        self.notesEntry:instantiate()
        self.notesEntry:setMultipleLine(true)
        self.notesEntry:setMaxTextLength(TAZC_Bio.MAX_DESCRIPTION_LENGTH)
        self:addChild(self.notesEntry)

        self.notesSaveButton = ISButton:new(self.rx + self.rw - 60, saveY, 60, 22, "Save", self, Sheet.onSaveNote)
        self.notesSaveButton:initialise()
        self:addChild(self.notesSaveButton)
        return
    end

    -- Editable: tagline + description entries in the right column.
    local taglineEntryY = self.taglineLabelY + lineH + 2
    self.descLabelY = taglineEntryY + 24 + 12
    local descEntryY = self.descLabelY + lineH + 2
    local saveY = self.height - 34
    local descEntryH = math.max(60, saveY - 10 - descEntryY)

    -- Prefill from cache, remembering what we prefilled: onSave only writes a
    -- field the player actually changed, so a cold-cache open can't clobber.
    local curTagline = TAZC_Bio.getTagline(self.targetUsername) or ""
    local curDesc    = TAZC_Bio.getDescription(self.targetUsername) or ""
    self.initialTagline = curTagline
    self.initialDesc    = curDesc

    self.taglineEntry = ISTextEntryBox:new(curTagline, self.rx, taglineEntryY, self.rw, 22)
    self.taglineEntry:initialise()
    self.taglineEntry:instantiate()
    self.taglineEntry:setMaxTextLength(TAZC_Bio.MAX_TAGLINE_LENGTH)
    self:addChild(self.taglineEntry)

    self.descEntry = ISTextEntryBox:new(curDesc, self.rx, descEntryY, self.rw, descEntryH)
    self.descEntry:initialise()
    self.descEntry:instantiate()
    self.descEntry:setMultipleLine(true)
    self.descEntry:setMaxTextLength(TAZC_Bio.MAX_DESCRIPTION_LENGTH)
    self:addChild(self.descEntry)

    self.saveButton = ISButton:new(self.rx, saveY, 100, 24, "Save", self, Sheet.onSave)
    self.saveButton:initialise()
    self:addChild(self.saveButton)
end

function Sheet:onSave()
    if not self.editable then return end
    local tagline = safeGet(function() return self.taglineEntry:getText() end, self.initialTagline or "")
    local desc    = safeGet(function() return self.descEntry:getText() end, self.initialDesc or "")
    -- Only write fields the player actually changed (see createChildren note).
    if tagline ~= (self.initialTagline or "") then TAZC_Bio.saveTagline(tagline) end
    if desc ~= (self.initialDesc or "") then TAZC_Bio.saveDescription(desc) end
    safeExec(function() self:removeFromUIManager() end)
    if instance == self then instance = nil end
end

function Sheet:onSaveNote()
    if self.editable or not self.notesEntry then return end
    local text = safeGet(function() return self.notesEntry:getText() end, self.initialNote or "")
    if text ~= (self.initialNote or "") then
        TAZC_Bio.saveNote(self.targetUsername, text)
        self.initialNote = text
        self.lastSetNote = text
    end
end

-- Keep the notes box synced to the fetched note until the player edits it (the
-- NoteLoad reply lands a few frames after the window opens).
function Sheet:prerender()
    ISCollapsableWindow.prerender(self)
    if self.editable or not self.notesEntry or self.noteDirtied then return end
    local cached = TAZC_Bio.getNote(self.targetUsername)
    if cached == nil then return end
    local cur = safeGet(function() return self.notesEntry:getText() end, self.lastSetNote or "")
    if cur == (self.lastSetNote or "") then
        if cached ~= cur then
            safeExec(function() self.notesEntry:setText(cached) end)
            self.lastSetNote = cached
            self.initialNote = cached
        end
    else
        self.noteDirtied = true
    end
end

function Sheet:render()
    ISCollapsableWindow.render(self)
    safeExec(function() self:renderContent() end)
end

function Sheet:renderContent()
    local tm = getTextManager()
    local lineH = tm:getFontHeight(UIFont.Small) + 2
    local medH = tm:getFontHeight(UIFont.Medium)

    if self.isDog then
        local slotX, slotY, slotW, slotH = PAD, self.contentTop, MODEL_W, self.modelH
        self:drawRect(slotX, slotY, slotW, slotH, 0.35, 0, 0, 0)
        self:drawRectBorder(slotX, slotY, slotW, slotH, 0.5, 0.5, 0.5, 0.55)
        if self.dogPortrait then
            -- Aspect-preserving: the slot is tall and narrow (matches the
            -- old full-body model panel), but a breed portrait is closer to
            -- square -- a plain scaled draw would stretch it noticeably.
            safeExec(function()
                self:drawTextureScaledAspect(self.dogPortrait, slotX, slotY, slotW, slotH, 1, 1, 1, 1)
            end)
        end

        local rx = self.rx
        local y = self.contentTop
        local hasName = self.realName and self.realName ~= ""
        self:drawText(hasName and self.realName or (self.breedName or "A Dog"), rx, y, 1, 1, 1, 1, UIFont.Medium)
        y = y + medH + 8

        if hasName and self.breedName then
            self:drawText(self.breedName, rx, y, 0.75, 0.78, 0.9, 1, UIFont.Small)
        end

        if self.notesLabelY then
            self:drawText("Personal notes (only you see this)", rx, self.notesLabelY,
                0.75, 0.78, 0.9, 1, UIFont.Small)
        end
        return
    end

    -- Anonymity resolution (others only). Runs every frame, so if they mask up
    -- or walk out of sight while the window is open, the card updates live.
    --
    -- BUGFIX: defaults now start ANONYMOUS/DISTANT before the check runs
    -- (was: self.realName/false/false). The old defaults meant a `getDisplayName`
    -- call that succeeded (ok == true) but returned a nil/false-ish name or
    -- flag -- not an error, just an ambiguous result -- fell through
    -- `nm or self.realName` and `anon or false`, silently leaking the real
    -- name instead of failing closed. Only an explicit, verified result now
    -- overrides the safe default.
    local displayName, isAnon, isDistant
    if self.editable then
        displayName, isAnon, isDistant = self.realName, false, false
    else
        displayName = (TAZC_Anonymity.Config and TAZC_Anonymity.Config.distantName) or "Someone"
        isAnon, isDistant = true, true
        local ok, nm, anon, dist = pcall(function()
            return TAZC_Anonymity.getDisplayName(self.targetPlayer, self.targetUsername, self.realName)
        end)
        if ok then
            displayName = nm or displayName
            isAnon = anon ~= false
            isDistant = dist ~= false
        end
        -- else: fail closed on the pre-set anonymous/distant defaults above.
    end

    -- Portrait slot on the left: darkened panel + border. The model is an
    -- addChild'd ISUI3DModel that renders itself into this slot.
    local slotX, slotY, slotW, slotH = PAD, self.contentTop, MODEL_W, self.modelH
    self:drawRect(slotX, slotY, slotW, slotH, 0.35, 0, 0, 0)
    self:drawRectBorder(slotX, slotY, slotW, slotH, 0.5, 0.5, 0.5, 0.55)

    -- Show the body unless the person is distant/out-of-sight (leak guard).
    local showModel = self.editable or not isDistant
    if self.model then
        safeExec(function() self.model:setVisible(showModel) end)
    end
    if not showModel then
        self:drawText("(not in sight)", slotX + 10, slotY + math.floor(slotH / 2),
            0.6, 0.6, 0.6, 1, UIFont.Small)
    end

    -- Right column.
    local rx = self.rx
    local y = self.contentTop
    self:drawText(displayName or "", rx, y, 1, 1, 1, 1, UIFont.Medium)
    y = y + medH + 8

    if self.editable then
        self:drawText("Tagline", rx, self.taglineLabelY, 0.75, 0.78, 0.9, 1, UIFont.Small)
        self:drawText("Description", rx, self.descLabelY, 0.75, 0.78, 0.9, 1, UIFont.Small)
        return
    end

    -- Personal-notes controls exist only on the read-only sheet; show them only
    -- when you recognise the person (gated exactly like their identity).
    local recognised = not isAnon
    if self.notesEntry then safeExec(function() self.notesEntry:setVisible(recognised) end) end
    if self.notesSaveButton then safeExec(function() self.notesSaveButton:setVisible(recognised) end) end

    if isAnon then
        self:drawText("You don't recognise this person.", rx, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
        return
    end

    local tagline = TAZC_Bio.getTagline(self.targetUsername) or ""
    if tagline ~= "" then
        self:drawText(tagline, rx, y, 0.85, 0.85, 1.0, 1, UIFont.Small)
        y = y + lineH
    end
    y = y + 6
    self:drawRect(rx, y, self.rw, 1, 0.5, 0.5, 0.55, 0.55)
    y = y + 8

    local desc = TAZC_Bio.getDescription(self.targetUsername) or ""
    if desc == "" then
        self:drawText("(no description written)", rx, y, 0.6, 0.6, 0.6, 1, UIFont.Small)
    else
        local bottom = self.descBottomY or (self.height - PAD)
        for _, ln in ipairs(wrapText(desc, UIFont.Small, self.rw)) do
            if y > bottom then break end   -- don't run into the notes box
            self:drawText(ln, rx, y, 0.9, 0.9, 0.9, 1, UIFont.Small)
            y = y + lineH
        end
    end

    -- Personal notes header, just above the (bottom-anchored) notes box.
    if self.notesLabelY then
        self:drawText("Personal notes (only you see this)", rx, self.notesLabelY,
            0.75, 0.78, 0.9, 1, UIFont.Small)
    end
end

-- ============================================================================
-- PUBLIC OPENER
-- ============================================================================

function TAZC_CharacterSheet.open(targetPlayer)
    if not targetPlayer then return end
    local localPlayer = getPlayer()
    if not localPlayer then return end

    local isDog = safeGet(function() return instanceof(targetPlayer, "IsoAnimal") end, false)

    local noteKey, editable, realName, breedName
    if isDog then
        -- Pets (currently: CompanionDogs) never have an account username --
        -- key notes off the engine's own per-animal ID instead, which is
        -- stable across copyFrom and save/load (unlike CompanionDogs' own
        -- ModData uid, which copyFrom wipes).
        local animalId = safeGet(function() return targetPlayer:getAnimalID() end, nil)
        if not animalId then return end
        noteKey = "dog:" .. tostring(animalId)
        editable = false

        local CD = _G.CompanionDogs
        if CD then
            realName = safeGet(function() return CD.data(targetPlayer).name end, nil)
            breedName = safeGet(function() return CD.breedNoun(targetPlayer) end, nil)
        end
        TAZC_Bio.requestNote(noteKey)   -- my private note about this dog
    else
        local username = safeGet(function() return targetPlayer:getUsername() end, nil)
        if not username then return end
        local localUsername = safeGet(function() return localPlayer:getUsername() end, "")

        -- Refresh from the server so the sheet shows current data.
        TAZC_Bio.requestTagline(username)
        TAZC_Bio.requestDescription(username)
        if username ~= localUsername then
            TAZC_Bio.requestNote(username)   -- my private note about them
        end

        noteKey = username
        editable = (username == localUsername)
        -- BUGFIX: was `or username` -- on a failed character-name lookup this
        -- fell back to the raw ACCOUNT username, not the character's in-fiction
        -- name. Account identity is transport-layer, never a public display
        -- name; a neutral "Someone" fallback matches the fail-closed default
        -- the anonymity resolution above already uses.
        realName = TAZC_Bio._getCharacterName(targetPlayer, username)
            or (TAZC_Anonymity.Config and TAZC_Anonymity.Config.distantName) or "Someone"
    end

    -- Single reusable window.
    if instance then
        safeExec(function() instance:removeFromUIManager() end)
        instance = nil
    end

    local sw = safeGet(function() return getCore():getScreenWidth() end, 1024)
    local sh = safeGet(function() return getCore():getScreenHeight() end, 768)

    local win = Sheet:new(math.floor((sw - WIN_W) / 2), math.floor((sh - WIN_H) / 2), WIN_W, WIN_H)
    win.targetPlayer = targetPlayer
    win.targetUsername = noteKey
    win.isDog = isDog
    win.realName = realName
    win.breedName = breedName
    win.editable = editable

    local ok = safeExec(function()
        win:initialise()
        win:addToUIManager()
        win:setVisible(true)
        win:bringToTop()
    end)
    if ok then instance = win end
    dbg("open: %s (editable=%s, isDog=%s)", tostring(noteKey), tostring(win.editable), tostring(isDog))
end

dbg("=== TAZC_CharacterSheet module loaded ===")

return TAZC_CharacterSheet
