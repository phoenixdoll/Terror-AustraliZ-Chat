--[[ ==========================================================================
    TAZC_LangAdmin.lua -- client-side admin context menu for native-language
    assignment. (v8.4 "Native Speakers")
    
    Right-clicking another player as an admin opens a "Languages >" submenu.
    Each registered non-English language gets two entries:
        Grant Native:  <Language>
        Revoke Native: <Language>
    
    The client doesn't track each player's native set -- it doesn't need to.
    Sending a redundant grant (player already has it) or a revoke for a
    language they don't have is harmless: the server reports the no-op state
    in the confirmation SystemMessage, and the admin sees what actually
    happened.
    
    Server is authoritative on:
      - the admin gate (client-side check is UX only; never trust the client)
      - the language-validity check
      - the actual mutation of TAZC_Lang's native set
    
    Sends ClientCommand "GrantLanguage" / "RevokeLanguage" to TAZC_Server's
    ServerCommands dispatch. Args: { target = <username>, language = <id> }.

    Also hosts the TOTAL WIPE entry ("Wipe ALL Their Terror AustraliZ Chat Data..."),
    which talks to TAZC_Lang's own listener on module "TAZCLang"
    (command "WipeAll") and is guarded by a type-their-username dialog --
    see the Total wipe section below.
========================================================================== ]]

local TAZC_Core         = require("TAZC_Core")
local TAZC_LangRegistry = require("TAZC_LangRegistry")
local TAZC_Bio          = require("TAZC_Bio")

local dbg = TAZC_Core.debugger("LANGADMIN")

-- Nil-is-failure contract; see TAZC_Core.safeGet/safeExec for why that
-- differs from TAZC_Core.safe. Kept under this file's own names since every
-- call site here already uses them.
local safeGet = TAZC_Core.safeGet
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then dbg("safeExec error: %s", tostring(err)) end
    return ok
end

-- Local, client-only line into the chat panel (no server round trip).
-- Lazy require mirrors TAZC_Input's pattern; if the panel isn't up yet the
-- line is dropped silently -- feedback here is a courtesy, never load-bearing.
local function localLine(message, color)
    safeExec(function()
        local TAZC_ChatPanel = require("TAZC_ChatPanel")
        if TAZC_ChatPanel and TAZC_ChatPanel.systemMessage then
            TAZC_ChatPanel.systemMessage(message, { color = color })
        end
    end)
end

-- Action callbacks. The first arg passed by the context menu is the
-- argument we registered with addOption -- we pack target+lang into a table.
local function onGrant(arg)
    if not arg or type(arg) ~= "table" then return end
    safeExec(function()
        sendClientCommand("TAZC", "GrantLanguage", {
            target   = arg.target,
            language = arg.language,
        })
    end)
end

local function onRevoke(arg)
    if not arg or type(arg) ~= "table" then return end
    safeExec(function()
        sendClientCommand("TAZC", "RevokeLanguage", {
            target   = arg.target,
            language = arg.language,
        })
    end)
end

-- ----------------------------------------------------------------------------
-- Total wipe (/lang resetall from the context menu)
--
-- The disaster this dialog is designed against is an irreversible wipe landing
-- on the WRONG player -- an exact-match refusal guards against two players
-- sharing a forename, or a mistyped/misremembered one. Three defenses:
--   1. The target comes from the clicked IsoPlayer's own getUsername() --
--      exact store key, no forename guessing.
--   2. The dialog shows the resolved CHARACTER name next to the username, so
--      the admin confirms a person, not a string.
--   3. Confirming requires TYPING the username exactly -- a click is too
--      cheap for something this permanent. Mismatch = nothing happens.
-- The wipe itself goes over "TAZCLang"/"WipeAll" (TAZC_Lang's own
-- OnClientCommand listener); the server re-checks the admin gate and prints
-- the store-by-store preview/report back as SystemMessages.
-- ----------------------------------------------------------------------------

local function onWipeAllDialogClick(arg, button)
    if not arg or type(arg) ~= "table" or not button then return end
    local internal = safeGet(function() return button.internal end, nil)
    if internal ~= "OK" then return end
    local typed = safeGet(function() return button.parent.entry:getText() end, nil)
    if type(typed) ~= "string" then typed = "" end
    typed = typed:match("^%s*(.-)%s*$") or ""
    if typed ~= arg.target then
        localLine("That doesn't match " .. arg.display .. "'s username exactly -- " ..
            "nothing was touched.", {255, 200, 100})
        return
    end
    safeExec(function()
        sendClientCommand("TAZCLang", "WipeAll", {
            target  = arg.target,
            confirm = true,
        })
    end)
end

local function onWipeAll(arg)
    if not arg or type(arg) ~= "table" then return end
    -- Preview first: the server prints the store-by-store cost of the wipe
    -- into the admin's chat, so it's on screen while the dialog is up.
    safeExec(function()
        sendClientCommand("TAZCLang", "WipeAll", {
            target  = arg.target,
            confirm = false,
        })
    end)
    if not ISTextBox then
        -- No dialog class available: fall back to the chat command, which
        -- carries the same two-step protection.
        localLine('No dialog available here -- use: /lang resetall "' ..
            arg.target .. '" and read the preview before confirming.', {255, 200, 100})
        return
    end
    safeExec(function()
        local w, h = 460, 130
        local screenW = safeGet(function() return getCore():getScreenWidth() end, 1280)
        local screenH = safeGet(function() return getCore():getScreenHeight() end, 720)
        local prompt = "Erase everything Terror AustraliZ Chat remembers about " ..
            arg.display .. "? This cannot be undone. " ..
            "Type their username (" .. arg.target .. ") to confirm."
        -- Vanilla ISTextBox invokes onclick(self.target, button, ...), so the
        -- packed arg table rides in the `target` slot.
        local modal = ISTextBox:new((screenW - w) / 2, (screenH - h) / 2, w, h,
            prompt, "", arg, onWipeAllDialogClick, arg.playerIndex)
        modal:initialise()
        modal:addToUIManager()
    end)
end

-- Find an IsoPlayer under the cursor. Shared with TAZC_Bio.onContextMenu's
-- own resolution -- walks worldObjects -> square -> movingObjects.
local findClickedPlayer = TAZC_Bio._findClickedPlayer

local function onContextMenu(playerIndex, context, worldObjects, test)
    if test then return true end

    local self = safeGet(function() return getSpecificPlayer(playerIndex) end, nil)
    if not self then return end

    -- Admin gate (UX only -- server validates again). PZ access levels
    -- aren't reliably lowercase (this file's own fallback default above is
    -- capitalized "None"); normalize before comparing, same as
    -- TAZC_AvatarServer's and TAZC_Avatar's own admin gates.
    local accessLevel = safeGet(function() return self:getAccessLevel() end, "None")
    accessLevel = tostring(accessLevel or "None"):lower()
    if accessLevel ~= "admin" then return end

    local clickedPlayer = findClickedPlayer(worldObjects)
    if not clickedPlayer then return end

    local targetUsername = safeGet(function() return clickedPlayer:getUsername() end, nil)
    if not targetUsername then return end

    -- Targeting yourself works too -- useful for testing or self-promotion.
    local targetDisplay = safeGet(function()
        return TAZC_Bio._getCharacterName(clickedPlayer, targetUsername)
    end, targetUsername)

    -- Top-level "Languages >" entry.
    local langs = TAZC_LangRegistry.listLanguages() or {}
    -- Filter out English (universal baseline, not assignable).
    local assignable = {}
    for _, lang in ipairs(langs) do
        if lang ~= "english" then table.insert(assignable, lang) end
    end
    if #assignable == 0 then return end  -- nothing to assign

    safeExec(function()
        local topOption = context:addOption("Languages (" .. targetDisplay .. ")", nil, nil)
        local subMenu = ISContextMenu:getNew(context)
        context:addSubMenu(topOption, subMenu)

        -- For each language, add Grant + Revoke. No checkmark state because
        -- the client doesn't track it -- admins can read confirmation chat.
        for _, lang in ipairs(assignable) do
            local displayLang = TAZC_LangRegistry.displayName(lang)
            subMenu:addOption("Grant Native: " .. displayLang,
                { target = targetUsername, language = lang }, onGrant)
            subMenu:addOption("Revoke Native: " .. displayLang,
                { target = targetUsername, language = lang }, onRevoke)
        end

        -- The total wipe, deliberately LAST -- past every grant/revoke pair
        -- and behind a type-their-username dialog (see onWipeAll above).
        subMenu:addOption("Wipe ALL Their Terror AustraliZ Chat Data...", {
            target      = targetUsername,
            display     = targetDisplay,
            playerIndex = playerIndex,
        }, onWipeAll)
    end)
end

safeExec(function() Events.OnFillWorldObjectContextMenu.Add(onContextMenu) end)

return { onContextMenu = onContextMenu }
