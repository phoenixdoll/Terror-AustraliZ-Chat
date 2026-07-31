--[[
================================================================================
    Terror AustraliZ Chat - Speech Bubble
    
    Renders speech bubbles above players using ISUIElement with direct drawText.
    Supports standard speech, radio, emote, and narration bubble styles.
    
    BUBBLE TYPES:
    - Standard: new(player, message, channel) - Normal proximity speech
    - Radio: newRadio(...) - Radio transmission with distinct style
    - Emote: newEmote(name, action, target) - *Name action* format
    - Do: newDo(narration, target) - Environment narration
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Avatar = require("TAZC_Avatar")
local TAZC_Bio = require("TAZC_Bio")
local TAZC_ChatPanel = require("TAZC_ChatPanel")

local dbg = TAZC_Core.debugger("BUBBLE")

local TAZC_Bubble = ISUIElement:derive("TAZC_Bubble")

-- Read bubble duration live from SandboxVars each time a bubble is created.
local function getLiveBubbleDuration()
    return TAZC_Config.liveSandbox("BubbleDuration", TAZC_Config.Bubble.duration) * 1000
end
-- ============================================================================
-- TEXTURE MANAGEMENT
-- ============================================================================

local texturesByStyle = {}

local function loadTextures(style)
    style = style or "simple"
    
    if texturesByStyle[style] then 
        return texturesByStyle[style] 
    end
    
    dbg("loadTextures: loading style '%s'", style)
    
    local textures = {
        topLeft = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-top-left.png"),
        top = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-top.png"),
        topRight = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-top-right.png"),
        left = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-left.png"),
        center = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-center.png"),
        right = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-right.png"),
        botLeft = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-bot-left.png"),
        bot = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-bot.png"),
        botRight = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-bot-right.png"),
        arrow = getTexture("media/ui/TAZC/bubble/" .. style .. "/bubble-arrow.png"),
    }
    
    texturesByStyle[style] = textures
    dbg("loadTextures: center=%s", tostring(textures.center))
    
    return textures
end

-- ============================================================================
-- POSITIONING
-- ============================================================================

--[[
    Convert world coords to screen position. Thin wrapper over the shared
    projection math (TAZC_Bio._screenPosition -- see TAZC_Bio for why it's
    homed there and not here) that fixes this file's yAdjust constant.
    @param target   Player/IsoObject with getX/Y/Z, or table {x=, y=, z=}
    @param width    Bubble width for centering
    @param height   Bubble height
    @param offsetY  Vertical offset (default BUBBLE_OFFSET_PLAYER)
    @return x, y screen coordinates (or nil if not calculable)
]]
local function getScreenPosition(target, width, height, offsetY)
    offsetY = offsetY or TAZC_Core.Display.BUBBLE_OFFSET_PLAYER
    return TAZC_Bio._screenPosition(target, width, height, offsetY, TAZC_Core.Display.BUBBLE_Y_ADJUST)
end

-- ============================================================================
-- UI ELEMENT METHODS
-- ============================================================================

function TAZC_Bubble:initialise()
    ISUIElement.initialise(self)
end

-- ============================================================================
-- MOUSE PASS-THROUGH
-- Return false to not consume events - allows clicking through bubbles
-- ============================================================================

function TAZC_Bubble:onMouseDown(x, y)
    return false
end

function TAZC_Bubble:onRightMouseDown(x, y)
    return false
end

function TAZC_Bubble:onMouseUp(x, y)
    return false
end

function TAZC_Bubble:onRightMouseUp(x, y)
    return false
end

function TAZC_Bubble:isMouseOver()
    return false
end

function TAZC_Bubble:prerender()
    -- Update position to follow target
    if self.target then
        local x, y = getScreenPosition(self.target, self.width, self.height, self.offsetY)
        if x and y then
            self:setX(x)
            self:setY(y)
        end
    end
end

-- M3(a) fix: resolve the texture set to actually draw with, given a
-- requested style. A missing/broken set (e.g. sign/ failing to load) used
-- to make :render() draw NOTHING at all -- not even the text -- an
-- invisible bubble with real content silently lost. Falls back to the
-- baked-in "simple" style instead, once, quietly logged; only if simple
-- itself is somehow missing is there truly nothing to draw (tex.center
-- nil on return). Split out from :render() so the fallback decision is
-- testable offline without mocking the whole ISUIElement drawing surface.
local function resolveTextures(style)
    local tex = loadTextures(style)
    if tex.center then return tex end
    if style == "simple" then return tex end
    dbg("resolveTextures: style '%s' failed to load (missing textures) -- falling back to 'simple'",
        tostring(style))
    return loadTextures("simple")
end
TAZC_Bubble._resolveTextures = resolveTextures

function TAZC_Bubble:render()
    if self.dead then return end

    local tex = resolveTextures(self.style)
    if not tex.center then return end
    
    -- Calculate alpha based on time remaining
    local now = TAZC_Core.getTimeMs()
    local elapsed = now - self.startTime
    local remaining = self.duration - elapsed
    
    if remaining <= 0 then
        self.dead = true
        return
    end
    
    local fadeMs = TAZC_Config.Bubble.fadeTime * 1000
    local alpha = self.opacity
    if remaining < fadeMs then
        alpha = alpha * (remaining / fadeMs)
    end
    
    -- Draw 9-patch bubble
    local w = self.width
    local h = self.height
    local corner = 10
    
    -- Top row
    self:drawTextureScaled(tex.topLeft, 0, 0, corner, corner, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.top, corner, 0, w - corner * 2, corner, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.topRight, w - corner, 0, corner, corner, alpha, 1, 1, 1)
    
    -- Middle row
    local midH = h - corner * 2
    self:drawTextureScaled(tex.left, 0, corner, corner, midH, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.center, corner, corner, w - corner * 2, midH, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.right, w - corner, corner, corner, midH, alpha, 1, 1, 1)
    
    -- Bottom row
    self:drawTextureScaled(tex.botLeft, 0, h - corner, corner, corner, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.bot, corner, h - corner, w - corner * 2, corner, alpha, 1, 1, 1)
    self:drawTextureScaled(tex.botRight, w - corner, h - corner, corner, corner, alpha, 1, 1, 1)
    
    -- Arrow pointing down (skip for emotes)
    if tex.arrow and not self.hideArrow then
        self:drawTextureScaled(tex.arrow, w / 2 - 3, h - 2, 7, 9, alpha, 1, 1, 1)
    end
    
    -- Avatar: custom PNG portrait when set (and never for anonymized
    -- speakers -- gated at construction), else the 3D character model
    local textOffsetX = 0
    if self.useAvatar and self.player then
        textOffsetX = self.avatarWidth + self.avatarPadding

        if self.avatarTexture then
            -- Element-relative draw, same slot the model occupies; arg
            -- order matches the 9-patch calls above (alpha, then 1,1,1).
            local okDraw = pcall(function()
                self:drawTextureScaled(self.avatarTexture, 2, h - self.avatarHeight - 2,
                    self.avatarWidth, self.avatarHeight, alpha, 1, 1, 1)
            end)
            if not okDraw then
                -- A corrupt/vanished texture degrades to the 3D model
                -- silently -- one dbg line, never an error.
                dbg("render: portrait draw failed; falling back to 3D model")
                self.avatarTexture = nil
            end
        end

        -- Create model on first render
        if not self.avatarTexture and not self.playerModel then
            pcall(function()
                self.playerModel = UI3DModel:new()
                self.playerModel:setWidth(45)
                self.playerModel:setHeight(self.avatarHeight)
                self.playerModel:setCharacter(self.player)
                self.playerModel:setState("idle")
                self.playerModel:setDirection(IsoDirections.SE)
                self.playerModel:setIsometric(false)
                self.playerModel:setAnimate(false)
                self.playerModel:setZoom(17)
                self.playerModel:setYOffset(-0.92)
                dbg("render: created 3D model")
            end)
        end
        
        -- Render the 3D model
        if not self.avatarTexture and self.playerModel then
            local modelX = self:getX() + 2
            local modelY = self:getY() + h - self.avatarHeight - 2
            
            local screenWidth = getCore():getScreenWidth()
            local screenHeight = getCore():getScreenHeight()
            
            if self:getX() < 0 then
                modelX = 2
            elseif self:getX() > screenWidth - w - 2 then
                modelX = 2 + screenWidth - w
            end
            
            if self:getY() < 0 then
                modelY = 0
            elseif self:getY() > screenHeight - h - 2 then
                modelY = screenHeight - self.avatarHeight - 2
            end
            
            self.playerModel:setX(modelX)
            self.playerModel:setY(modelY)
            self.playerModel:render()
        end
    end
    
    -- Draw text lines
    local y = self.padding
    local textAlpha = alpha
    local textManager = getTextManager()
    
    for _, lineData in ipairs(self.lines) do
        local lineWidth = 0
        if lineData.chunks then
            for _, chunk in ipairs(lineData.chunks) do
                lineWidth = lineWidth + textManager:MeasureStringX(self.font, chunk.text)
            end
        elseif type(lineData) == "string" then
            lineWidth = textManager:MeasureStringX(self.font, lineData)
        end
        
        local textAreaWidth = w - textOffsetX
        local x = textOffsetX + (textAreaWidth - lineWidth) / 2
        
        if lineData.chunks then
            for _, chunk in ipairs(lineData.chunks) do
                local cc = chunk.color or self.textColor
                self:drawText(chunk.text, x, y, cc[1]/255, cc[2]/255, cc[3]/255, textAlpha, self.font)
                x = x + textManager:MeasureStringX(self.font, chunk.text)
            end
        elseif type(lineData) == "string" then
            local tc = self.textColor
            self:drawText(lineData, x, y, tc[1]/255, tc[2]/255, tc[3]/255, textAlpha, self.font)
        end
        
        y = y + self.lineHeight
    end
end

-- ============================================================================
-- CONSTRUCTORS
-- ============================================================================

--[[
    Create a standard speech bubble
    @param player        Player object to follow
    @param message       Message text
    @param channel       Channel name (say, yell, whisper, etc)
    @param hideAvatar    Optional: hide the 3D avatar (for distant speakers)
    @param characterName Optional: override character name for emote conversion
    @param isAnonymous   Optional: speaker is anonymized (masked OR distant).
                         Gates the custom PNG portrait -- a masked speaker
                         keeps the 3D-model fallback (it shows the masked
                         in-world appearance, which leaks nothing; a custom
                         portrait would fingerprint the player instantly).
    @param modality      Optional: "signed" picks the sign/ bubble skin
                         instead of the per-channel speech style.
    @return TAZC_Bubble instance or nil
]]
function TAZC_Bubble:new(player, message, channel, hideAvatar, characterName, isAnonymous, modality)
    dbg("new: creating for '%s' hideAvatar=%s isAnonymous=%s",
        tostring(message and message:sub(1, 30) or "nil"), tostring(hideAvatar), tostring(isAnonymous))
    
    if not message or message == "" then
        dbg("new: empty message")
        return nil
    end
    
    local font = UIFont.Medium
    local maxWidth = TAZC_Config.Bubble.maxWidth
    local padding = 12
    local lineHeight = getTextManager():getFontHeight(font) + 2
    
    -- Avatar dimensions (hide for distant speakers, and entirely when the
    -- sandbox mode is "off")
    local avatarWidth = 0
    local avatarHeight = 60
    local avatarPadding = 4
    local avatarMode = TAZC_Config.Bubble.avatarMode or "model"
    local useAvatar = TAZC_Config.Bubble.showAvatar ~= false and not hideAvatar
        and avatarMode ~= "off"

    -- Custom PNG portrait ("png" mode only; 3D model is the fallback).
    -- ANONYMITY LAW: never for an anonymized speaker -- see the isAnonymous
    -- doc above. getTextureForPlayer is nil-safe and never errors.
    local avatarTexture = nil
    if useAvatar and avatarMode == "png" and not isAnonymous then
        avatarTexture = TAZC_Avatar.getTextureForPlayer(player)
    end

    if useAvatar then
        -- The 60x80 portrait scales exactly into 45x60 (3:4); the 3D model
        -- keeps its established 30px slot.
        avatarWidth = avatarTexture and 45 or 30
    end
    
    local textAreaWidth = maxWidth - padding * 2
    if useAvatar then
        textAreaWidth = textAreaWidth - avatarWidth - avatarPadding
    end
    
    local baseColor = TAZC_Config.ChannelColors[channel] or {255, 255, 255}
    local emoteColor = TAZC_Config.ChannelColors.emote or {255, 190, 128}
    local moodColor = TAZC_Config.ChannelColors.mood or {180, 180, 200}
    
    -- Speech channels get smart asterisk handling
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    local isSpeech = speechChannels[channel]
    
    local segments, isPureEmote = TAZC_Core.parseColorSegments(message, baseColor, isSpeech, emoteColor, moodColor)
    
    -- Pure emote in speech -> convert to emote bubble
    if isSpeech and isPureEmote then
        local emoteContent = message:match("^%s*%*(.-)%*%s*$") or message
        -- Use passed characterName if provided (for anonymity), otherwise look up from player
        local displayName = characterName
        if not displayName then
            local username = player:getUsername()
            displayName = TAZC_Bio._getCharacterName(player, username) or username
        end
        dbg("new: pure emote, converting with name '%s'", displayName)
        return TAZC_Bubble:newEmote(displayName, emoteContent, player)
    end
    
    local wrappedLines = TAZC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    dbg("new: %d lines", #wrappedLines)
    
    if #wrappedLines == 0 then
        dbg("new: no lines")
        return nil
    end
    
    -- Calculate dimensions
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local baseWidth = math.min(textWidth + padding * 2, maxWidth - avatarWidth - avatarPadding)
    local width = baseWidth
    if useAvatar then
        width = width + avatarWidth + avatarPadding
    end
    
    local textHeight = #wrappedLines * lineHeight + padding * 2
    local height = math.max(textHeight, avatarHeight + padding)
    
    local x, y = getScreenPosition(player, width, height, TAZC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then 
        dbg("new: no position")
        x, y = 0, 0 
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = player
    o.offsetY = TAZC_Core.Display.BUBBLE_OFFSET_PLAYER
    -- Style resolution gains a modality case beside the per-channel choice
    -- (same pattern as the radio/speech split below): signed speech gets
    -- its own 9-slice skin instead of "simple".
    o.style = (modality == "signed") and TAZC_Config.Bubble.signStyle or TAZC_Config.Radio.speechBubbleStyle
    o.message = message
    o.channel = channel or "say"
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    o.opacity = TAZC_Config.Bubble.opacity
    o.startTime = TAZC_Core.getTimeMs()
    o.dead = false

    o.useAvatar = useAvatar
    o.avatarWidth = avatarWidth
    o.avatarHeight = avatarHeight
    o.avatarPadding = avatarPadding
    o.player = player
    o.playerModel = nil
    o.avatarTexture = avatarTexture
    
    dbg("new: created, duration=%dms", o.duration)
    
    return o
end

--[[
    Create a radio speech bubble
    @param message   Message text (may include static)
    @param channel   Original speech channel
    @param target    Player or {x,y,z} position
    @param isPrivate Headphone flag on the routed radio message. The server
                     already delivered this message to only the one
                     receiver it resolved for the frequency (see
                     TAZC_Server.processMessage's routeRadio stage) -- there's
                     no separate owner-only gate to apply here. Kept only
                     for the dbg line below.
    @param volume    Radio volume (affects opacity)
    @return TAZC_Bubble instance or nil
]]
function TAZC_Bubble:newRadio(message, channel, target, isPrivate, volume)
    dbg("newRadio: creating for '%s'", tostring(message and message:sub(1, 30) or "nil"))
    
    if not message or message == "" then
        dbg("newRadio: empty message")
        return nil
    end
    
    local font = UIFont.Medium
    local maxWidth = TAZC_Config.Bubble.maxWidth
    local padding = 12
    local lineHeight = getTextManager():getFontHeight(font) + 2
    local textAreaWidth = maxWidth - padding * 2
    
    -- Radio color: slight blue shift from channel color
    local baseChannelColor = TAZC_Config.ChannelColors[channel] or {255, 255, 255}
    local baseColor = {
        math.floor(baseChannelColor[1] * 0.8),
        math.floor(baseChannelColor[2] * 0.9),
        math.floor(baseChannelColor[3] * 1.0)
    }
    
    local emoteColor = TAZC_Config.ChannelColors.emote or {255, 190, 128}
    local moodColor = TAZC_Config.ChannelColors.mood or {180, 180, 200}
    local segments, _ = TAZC_Core.parseColorSegments(message, baseColor, true, emoteColor, moodColor)
    local wrappedLines = TAZC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    dbg("newRadio: %d lines", #wrappedLines)
    
    if #wrappedLines == 0 then
        dbg("newRadio: no lines")
        return nil
    end
    
    -- Calculate dimensions
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local width = math.min(textWidth + padding * 2, maxWidth)
    local height = #wrappedLines * lineHeight + padding * 2
    
    -- Determine offset based on target type
    local offsetY = TAZC_Core.Display.BUBBLE_OFFSET_PLAYER
    if type(target) == "table" and target.x then
        offsetY = TAZC_Core.Display.BUBBLE_OFFSET_GROUND
    end
    
    local x, y = getScreenPosition(target, width, height, offsetY)
    if not x then 
        dbg("newRadio: no position")
        x, y = 0, 0 
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = offsetY
    o.style = TAZC_Config.Radio.bubbleStyle
    o.message = message
    o.channel = channel or "say"
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    
    volume = volume or 1.0
    o.opacity = TAZC_Config.Bubble.opacity * math.max(0.5, volume)
    
    o.startTime = TAZC_Core.getTimeMs()
    o.dead = false
    
    dbg("newRadio: created, isPrivate=%s, offsetY=%d", tostring(isPrivate or false), offsetY)
    
    return o
end

--[[
    Create an emote/action bubble
    @param characterName  Character name
    @param action         Action text
    @param target         Player to follow
    @return TAZC_Bubble instance or nil
]]
function TAZC_Bubble:newEmote(characterName, action, target)
    dbg("newEmote: %s - %s", tostring(characterName), tostring(action and action:sub(1, 30) or "nil"))
    
    if not action or action == "" then
        dbg("newEmote: empty action")
        return nil
    end
    
    local displayMessage = "*" .. (characterName or "Someone") .. " " .. action .. "*"
    
    local font = UIFont.Medium
    local maxWidth = TAZC_Config.Bubble.maxWidth
    local padding = 12
    local lineHeight = getTextManager():getFontHeight(font) + 2
    local textAreaWidth = maxWidth - padding * 2
    
    -- Single-color word-wrap: shared core, see TAZC_ChatPanel._wrapWords.
    local lines = TAZC_ChatPanel._wrapWords(displayMessage, font, textAreaWidth)
    dbg("newEmote: %d lines", #lines)
    
    if #lines == 0 then
        dbg("newEmote: no lines")
        return nil
    end
    
    local textWidth = 0
    for _, line in ipairs(lines) do
        local w = getTextManager():MeasureStringX(font, line)
        if w > textWidth then textWidth = w end
    end
    
    local width = math.min(textWidth + padding * 2, maxWidth)
    local height = #lines * lineHeight + padding * 2
    
    local x, y = getScreenPosition(target, width, height, TAZC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then 
        dbg("newEmote: no position")
        x, y = 0, 0 
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = TAZC_Core.Display.BUBBLE_OFFSET_PLAYER
    o.style = TAZC_Config.Radio.speechBubbleStyle
    o.message = displayMessage
    o.channel = "emote"
    o.isEmote = true
    o.hideArrow = true
    o.textColor = TAZC_Config.ChannelColors.emote or {255, 190, 128}
    o.lines = lines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = 3000
    o.opacity = TAZC_Config.Bubble.opacity
    o.startTime = TAZC_Core.getTimeMs()
    o.dead = false
    o.useAvatar = false
    o.avatarWidth = 0

    dbg("newEmote: created")
    
    return o
end

--[[
    Create a do/narration bubble
    @param narration  Narration text
    @param target     Player to follow
    @return TAZC_Bubble instance or nil
]]
function TAZC_Bubble:newDo(narration, target)
    dbg("newDo: %s", tostring(narration and narration:sub(1, 30) or "nil"))
    
    if not narration or narration == "" then
        dbg("newDo: empty narration")
        return nil
    end
    
    local font = UIFont.Medium
    local maxWidth = TAZC_Config.Bubble.maxWidth
    local padding = 12
    local lineHeight = getTextManager():getFontHeight(font) + 2
    local textAreaWidth = maxWidth - padding * 2
    
    local baseColor = TAZC_Config.ChannelColors["do"] or {200, 180, 255}
    local emoteColor = TAZC_Config.ChannelColors.emote or {255, 190, 128}
    local moodColor = TAZC_Config.ChannelColors.mood or {180, 180, 200}
    
    local segments = TAZC_Core.parseColorSegments(narration, baseColor, false, emoteColor, moodColor)
    local wrappedLines = TAZC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    dbg("newDo: %d lines", #wrappedLines)
    
    if #wrappedLines == 0 then
        dbg("newDo: no lines")
        return nil
    end
    
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local width = math.min(textWidth + padding * 2, maxWidth)
    local height = #wrappedLines * lineHeight + padding * 2
    
    local x, y = getScreenPosition(target, width, height, TAZC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then 
        dbg("newDo: no position")
        x, y = 0, 0 
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = TAZC_Core.Display.BUBBLE_OFFSET_PLAYER
    o.style = TAZC_Config.Radio.speechBubbleStyle
    o.message = narration
    o.channel = "do"
    o.isEmote = true
    o.hideArrow = true
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = 4000
    o.opacity = TAZC_Config.Bubble.opacity
    o.startTime = TAZC_Core.getTimeMs()
    o.dead = false
    o.useAvatar = false
    o.avatarWidth = 0

    dbg("newDo: created")
    
    return o
end

-- ============================================================================

return TAZC_Bubble
