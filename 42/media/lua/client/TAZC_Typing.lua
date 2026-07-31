--[[
================================================================================
    Terror AustraliZ Chat - Typing Indicator
    
    Animated dots above player head when typing.
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Bio = require("TAZC_Bio")

local dbg = TAZC_Core.debugger("TYPING")

local TAZC_Typing = ISUIElement:derive("TAZC_Typing")

-- ============================================================================
-- TEXTURE MANAGEMENT
-- ============================================================================

local textures = nil

local function loadTextures()
    if textures then return textures end
    
    dbg("Loading typing textures")
    
    textures = {
        getTexture("media/ui/TAZC/typing-dots/typing-dots-1.png"),
        getTexture("media/ui/TAZC/typing-dots/typing-dots-2.png"),
        getTexture("media/ui/TAZC/typing-dots/typing-dots-3.png"),
    }
    
    dbg("Loaded: tex[1]=%s tex[2]=%s tex[3]=%s", 
        tostring(textures[1]), tostring(textures[2]), tostring(textures[3]))
    
    return textures
end

-- ============================================================================
-- POSITIONING
-- ============================================================================

-- Get screen position above player's head. Thin wrapper over the shared
-- projection math (TAZC_Bio._screenPosition) -- height=0 because the typing
-- indicator anchors by its own top edge, not above the target like a
-- bubble/nameplate, and TYPING_OFFSET_Y stands in for the fixed yAdjust
-- nudge those use.
local function getScreenPosition(player)
    return TAZC_Bio._screenPosition(player, TAZC_Core.Display.TYPING_WIDTH, 0,
        TAZC_Core.Display.BUBBLE_OFFSET_PLAYER, TAZC_Core.Display.TYPING_OFFSET_Y)
end

-- ============================================================================
-- UI ELEMENT METHODS
-- ============================================================================

function TAZC_Typing:initialise()
    ISUIElement.initialise(self)
end

-- =============================================================================
-- MOUSE PASSTHROUGH
-- Typing indicators must not intercept clicks
-- =============================================================================
function TAZC_Typing:onMouseDown(x, y)
    return false
end

function TAZC_Typing:onMouseUp(x, y)
    return false
end

function TAZC_Typing:onRightMouseDown(x, y)
    return false
end

function TAZC_Typing:onRightMouseUp(x, y)
    return false
end

function TAZC_Typing:isMouseOver()
    return false
end

function TAZC_Typing:prerender()
    -- Update position to follow player
    if self.player then
        local x, y = getScreenPosition(self.player)
        if x and y then
            self:setX(x)
            self:setY(y)
        end
    end
end

function TAZC_Typing:render()
    if self.dead then return end
    
    local tex = loadTextures()
    if not tex[1] then return end
    
    local now = TAZC_Core.getTimeMs()
    
    -- Check timeout
    if now - self.startTime > self.timeout then
        self.dead = true
        return
    end
    
    -- Animate dots (cycle through 3 frames)
    local elapsed = now - self.lastStepTime
    if elapsed >= self.stepTime then
        self.lastStepTime = now
        self.step = (self.step % 3) + 1
    end
    
    -- Draw current frame
    self:drawTexture(tex[self.step], 0, 0, 1, 1, 1, 1)
end

-- ============================================================================
-- PUBLIC INTERFACE
-- ============================================================================

--[[
    Refresh the timeout (called when new typing packet arrives)
    Keeps the indicator visible while player continues typing
]]
function TAZC_Typing:refresh()
    self.startTime = TAZC_Core.getTimeMs()
end

--[[
    Create a new typing indicator
    
    @param player  The player who is typing
    @param timeout Seconds before indicator disappears (default 3)
    @return TAZC_Typing instance
]]
function TAZC_Typing:new(player, timeout)
    local x, y = getScreenPosition(player)
    if not x then x, y = 0, 0 end
    
    local o = ISUIElement:new(x, y, TAZC_Core.Display.TYPING_WIDTH, TAZC_Core.Display.TYPING_HEIGHT)
    setmetatable(o, self)
    self.__index = self
    
    local now = TAZC_Core.getTimeMs()
    
    o.player = player
    o.startTime = now
    o.lastStepTime = now
    o.stepTime = 250      -- Animation speed (ms per frame)
    o.step = 1
    o.timeout = (timeout or 3) * 1000
    o.dead = false
    
    return o
end

-- ============================================================================

return TAZC_Typing
