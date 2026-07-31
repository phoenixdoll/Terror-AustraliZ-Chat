--[[
================================================================================
    Terror AustraliZ Chat - Avatar Windows (client UI)

    Two small ISCollapsableWindow panels for the portrait system:

      Upload window ("Chat Portrait") -- reached from right-clicking your
      own character -> "Choose Chat Avatar...". Shows the portrait found in
      the request folder (with a live preview) or warm instructions with
      the exact drop path. Sending is one click; taking a portrait down is
      one more.

      Review window ("Portraits Awaiting a Look-Over") -- moderators only
      (client-side gate is UX; the server re-verifies every verdict).
      Cycles through the pending queue one portrait at a time with
      approve / send-back buttons.

    All engine UI calls are pcall-guarded: a vanilla UI drift may cost the
    window, never the session. Data and network live in TAZC_Avatar; this
    file is presentation only.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_AvatarIO = require("TAZC_AvatarIO")
local TAZC_Avatar = require("TAZC_Avatar")

local dbg = TAZC_Core.debugger("AVATAR")

local TAZC_AvatarWindow = {}

-- ============================================================================
-- SHARED BITS
-- ============================================================================

local PREVIEW_W, PREVIEW_H = 120, 160   -- 60x80 portrait at 2x for legibility
local REPROBE_MS = 3000                 -- upload window folder re-check cadence

-- Nil-is-failure contract; see TAZC_Core.safeGet/safeExec for why that
-- differs from TAZC_Core.safe. Kept under this file's own name since every
-- call site here already uses it.
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then dbg("window safeExec failed: %s", tostring(err)) end
    return ok
end

local function icon(name)
    return TAZC_Core.safe(function()
        return getTexture("media/ui/TAZC/icons/" .. name)
    end, nil)
end

-- Vanilla thumbs-up for approve if B42 still ships it (smoke-test item);
-- the button keeps its text label either way, so a nil icon costs nothing.
local function vanillaThumbUp()
    return TAZC_Core.safe(function()
        return getTexture("media/ui/emotes/thumbup_green.png")
    end, nil)
end

local function setButtonIcon(btn, tex)
    if not btn or not tex then return end
    TAZC_Core.safe(function()
        if btn.setImage then btn:setImage(tex) end
    end, nil)
end

local function displayNameOf(entry)
    local name = ((entry.forename or "") .. " " .. (entry.surname or ""))
        :gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = entry.username or "?" end
    return name
end

-- ============================================================================
-- UPLOAD WINDOW
-- ============================================================================

local UploadWindow = ISCollapsableWindow:derive("TAZC_AvatarUploadWindow")
local uploadInstance = nil

function UploadWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "Chat Portrait"
    o.resizable = false
    o.probe = nil          -- last TAZC_Avatar.probeRequestFile() result
    o.previewTex = nil
    o.lastProbeMs = 0
    return o
end

function UploadWindow:refreshProbe()
    self.lastProbeMs = TAZC_Core.getTimeMs()
    self.probe = TAZC_Avatar.probeRequestFile()
    self.previewTex = nil
    if self.probe then
        -- Preview straight off the dropped file. Reload first: the player
        -- may overwrite avatar.png repeatedly while tuning it, and the
        -- engine caches by name (B42 live-verify).
        local relPath = TAZC_Avatar.getRequestDir() .. "/" .. self.probe.file
        self.previewTex = TAZC_Core.safe(function()
            local tex = getTextureFromSaveDir(relPath, "../Lua")
            if tex then Texture.reload(tex:getName()) end
            return getTextureFromSaveDir(relPath, "../Lua")
        end, nil)
    end
    local status = TAZC_Avatar.getOwnStatus()
    if self.sendButton then
        -- Sendable: a valid file that isn't already up or in the queue.
        local sendable = self.probe ~= nil and self.probe.valid == true
        if sendable and status then
            local c = self.probe.checksum
            if (status.approved and status.approved.checksum == c)
                or (status.pending and status.pending.checksum == c) then
                sendable = false
            end
        end
        self.sendButton:setVisible(sendable)
    end
    if self.removeButton then
        self.removeButton:setVisible(status ~= nil
            and (status.approved ~= nil or status.pending ~= nil))
    end
end

function UploadWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local y = self.height - 32

    self.sendButton = ISButton:new(10, y, 110, 22, "Send it along", self, UploadWindow.onSend)
    self.sendButton:initialise()
    self:addChild(self.sendButton)
    setButtonIcon(self.sendButton, icon("upload.png"))

    self.lookButton = ISButton:new(130, y, 80, 22, "Look again", self, UploadWindow.onLookAgain)
    self.lookButton:initialise()
    self:addChild(self.lookButton)

    self.removeButton = ISButton:new(220, y, 100, 22, "Take mine down", self, UploadWindow.onRemove)
    self.removeButton:initialise()
    self:addChild(self.removeButton)

    self.contentTop = th + 8
    self:refreshProbe()
end

function UploadWindow:onSend()
    if not self.probe or not self.probe.valid or not self.probe.checksum then return end
    -- Duplicate clicks are absorbed by TAZC_Avatar's in-flight guard (and by
    -- the server's own idempotence checks behind it).
    TAZC_Avatar.submitBytes(self.probe.bytes, self.probe.checksum)
end

function UploadWindow:onLookAgain()
    self:refreshProbe()
end

function UploadWindow:onRemove()
    TAZC_Avatar.requestRemove()
end

function UploadWindow:prerender()
    ISCollapsableWindow.prerender(self)
    -- Gentle auto-refresh so a freshly dropped file appears on its own.
    if (TAZC_Core.getTimeMs() - self.lastProbeMs) >= REPROBE_MS then
        safeExec(function() self:refreshProbe() end)
    end
end

function UploadWindow:render()
    ISCollapsableWindow.render(self)
    safeExec(function() self:renderContent() end)
end

function UploadWindow:renderContent()
    local x, y = 12, self.contentTop or 24
    local lineH = getTextManager():getFontHeight(UIFont.Small) + 2

    local function line(text, r, g, b)
        self:drawText(text, x, y, r or 0.9, g or 0.9, b or 0.9, 1, UIFont.Small)
        y = y + lineH
    end

    local probe = self.probe
    if not probe then
        line("Leave a portrait for me here -- a PNG,")
        line(string.format("exactly %d by %d, named avatar.png:",
            TAZC_AvatarIO.WIDTH, TAZC_AvatarIO.HEIGHT))
        y = y + 4
        -- The drop path is work output: plain, unstyled, line-wrapped only.
        line(TAZC_Avatar.getRequestDirDisplay(), 0.7, 0.85, 0.95)
        y = y + 4
        line("Then come back and I'll pass it along.")
        line("(An admin gives every portrait a look-over first.)", 0.7, 0.7, 0.7)
        return
    end

    if not probe.valid then
        line("I found " .. tostring(probe.file) .. ", but it won't fit the frame:")
        line(tostring(probe.reason or "unreadable"), 0.9, 0.6, 0.6)
        y = y + 4
        line(string.format("It needs to be a PNG, exactly %d by %d,",
            TAZC_AvatarIO.WIDTH, TAZC_AvatarIO.HEIGHT))
        line("and under 32 KB. Swap the file and look again.")
        return
    end

    -- Status line derives from what the server has actually accepted, so
    -- it stays truthful across rejections and re-opens of this window.
    local status = TAZC_Avatar.getOwnStatus()
    local c = probe.checksum
    if status and status.approved and status.approved.checksum == c then
        line("This portrait already hangs where you speak.", 0.6, 0.85, 0.6)
    elseif status and status.pending and status.pending.checksum == c then
        line("It's with the keepers -- awaiting a look-over.", 0.6, 0.8, 0.9)
    elseif TAZC_Avatar.isSubmitInFlight(c) then
        line("Off it goes -- someone will look it over soon.", 0.6, 0.85, 0.6)
    else
        line("Here's what I found. Shall I send it along?")
    end
    y = y + 6

    if self.previewTex then
        local px = math.floor((self.width - PREVIEW_W) / 2)
        self:drawTextureScaled(self.previewTex, px, y, PREVIEW_W, PREVIEW_H, 1, 1, 1, 1)
        self:drawRectBorder(px - 1, y - 1, PREVIEW_W + 2, PREVIEW_H + 2, 0.6, 0.6, 0.6, 0.6)
    else
        line("(preview unavailable -- the file itself is fine)", 0.7, 0.7, 0.7)
    end
end

-- ============================================================================
-- REVIEW WINDOW (moderation queue)
-- ============================================================================

local ReviewWindow = ISCollapsableWindow:derive("TAZC_AvatarReviewWindow")
local reviewInstance = nil

function ReviewWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "Portraits Awaiting a Look-Over"
    o.resizable = false
    o.index = 1
    o.acted = {}    -- ["key#checksum"] = true once a verdict was sent
    return o
end

-- The acted table is keyed by key AND checksum: a verdict rules on one
-- particular image, not on the character forever. A resubmission (same
-- key, new checksum) must come back around for a fresh look.
local function actedKeyOf(entry)
    return entry.key .. "#" .. tostring(entry.checksum)
end

-- Pending entries minus the exact images we've already ruled on this
-- session (each stays hidden until the server's Gone confirms the verdict).
function ReviewWindow:queue()
    local list = TAZC_Avatar.getPendingList()
    local live = {}
    local remaining = {}
    for _, entry in ipairs(list) do
        local acted = actedKeyOf(entry)
        live[acted] = true
        if not self.acted[acted] then remaining[#remaining + 1] = entry end
    end
    -- Ruled-on images that have left the pending queue are settled; forget
    -- them so the table stays small over a long session (and so the same
    -- image, if genuinely resubmitted later, gets judged anew).
    local stale = {}
    for acted in pairs(self.acted) do
        if not live[acted] then stale[#stale + 1] = acted end
    end
    for i = 1, #stale do
        self.acted[stale[i]] = nil
    end
    return remaining
end

function ReviewWindow:current()
    local q = self:queue()
    if #q == 0 then return nil, 0 end
    if self.index > #q then self.index = 1 end
    return q[self.index], #q
end

function ReviewWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self.height - 32

    self.approveButton = ISButton:new(10, y, 90, 22, "Hang it up", self, ReviewWindow.onApprove)
    self.approveButton:initialise()
    self:addChild(self.approveButton)
    setButtonIcon(self.approveButton, vanillaThumbUp())

    self.rejectButton = ISButton:new(110, y, 90, 22, "Send it back", self, ReviewWindow.onReject)
    self.rejectButton:initialise()
    self:addChild(self.rejectButton)
    setButtonIcon(self.rejectButton, icon("thumbdown_red.png"))

    self.skipButton = ISButton:new(210, y, 70, 22, "Next", self, ReviewWindow.onSkip)
    self.skipButton:initialise()
    self:addChild(self.skipButton)

    self.contentTop = self:titleBarHeight() + 8
end

function ReviewWindow:onApprove()
    local entry = self:current()
    if not entry then return end
    TAZC_Avatar.sendApprove(entry.key, entry.checksum)
    self.acted[actedKeyOf(entry)] = true
end

function ReviewWindow:onReject()
    local entry = self:current()
    if not entry then return end
    TAZC_Avatar.sendReject(entry.key, entry.checksum)
    self.acted[actedKeyOf(entry)] = true
end

function ReviewWindow:onSkip()
    self.index = self.index + 1
end

function ReviewWindow:render()
    ISCollapsableWindow.render(self)
    safeExec(function() self:renderContent() end)
end

function ReviewWindow:renderContent()
    local x, y = 12, self.contentTop or 24
    local lineH = getTextManager():getFontHeight(UIFont.Small) + 2

    local function line(text, r, g, b)
        self:drawText(text, x, y, r or 0.9, g or 0.9, b or 0.9, 1, UIFont.Small)
        y = y + lineH
    end

    local entry, count = self:current()
    local hasButtons = self.approveButton ~= nil
    if not entry then
        line("Nothing waiting -- the gallery is all caught up.")
        if hasButtons then
            self.approveButton:setVisible(false)
            self.rejectButton:setVisible(false)
            self.skipButton:setVisible(false)
        end
        return
    end
    if hasButtons then
        self.approveButton:setVisible(true)
        self.rejectButton:setVisible(true)
        self.skipButton:setVisible(count > 1)
    end

    line(string.format("Portrait %d of %d", self.index, count), 0.7, 0.7, 0.7)
    -- Plain work output: who this is, exactly as stored.
    line("Player:    " .. tostring(entry.username))
    line("Character: " .. displayNameOf(entry))
    y = y + 6

    local tex = TAZC_Avatar.getPendingTexture(entry.key)
    if tex then
        local px = math.floor((self.width - PREVIEW_W) / 2)
        self:drawTextureScaled(tex, px, y, PREVIEW_W, PREVIEW_H, 1, 1, 1, 1)
        self:drawRectBorder(px - 1, y - 1, PREVIEW_W + 2, PREVIEW_H + 2, 0.6, 0.6, 0.6, 0.6)
    else
        line("(image still on its way -- give it a moment)", 0.7, 0.7, 0.7)
    end
end

-- ============================================================================
-- PUBLIC OPENERS
-- ============================================================================

local function openWindow(existing, Class, w, h)
    if existing then
        safeExec(function()
            existing:setVisible(true)
            existing:bringToTop()
        end)
        return existing
    end
    local win = nil
    safeExec(function()
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        win = Class:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
        win:initialise()
        win:addToUIManager()
        win:setVisible(true)
    end)
    return win
end

function TAZC_AvatarWindow.openUpload()
    uploadInstance = openWindow(uploadInstance, UploadWindow, 340, 340)
    if uploadInstance then
        safeExec(function() uploadInstance:refreshProbe() end)
    end
end

function TAZC_AvatarWindow.openReview()
    reviewInstance = openWindow(reviewInstance, ReviewWindow, 300, 360)
    if reviewInstance then
        reviewInstance.index = 1
    end
end

dbg("=== TAZC_AvatarWindow module loaded ===")

return TAZC_AvatarWindow
