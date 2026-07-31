--[[
================================================================================
    Terror AustraliZ Chat - Language Command Surface

    Every player/admin-facing /lang subcommand, plus /lex, /comp, /forget,
    and /translate. TAZC_Lang.lua (required below) owns the language-state
    model and the render/babble engine; this module owns everything a
    person types. A handful of TAZC_Lang internals that the engine also
    still uses are reached through leading-underscore exposures on TAZC_Lang
    rather than duplicated here -- see the "Internal contract" comments at
    each one's definition in TAZC_Lang.lua.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Lang = require("TAZC_Lang")
local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_LangRegistry = require("TAZC_LangRegistry")
local TAZC_Acquisition = require("TAZC_Acquisition")
local TAZC_Resolve = require("TAZC_Resolve")

local TAZC_LangCommands = {}

local dbg = TAZC_Core.debugger("LANG")

-- ============================================================================
-- /lang COMMAND
-- 
-- Single command, two access tiers:
--   /lang <language>             -> self-set (any player)
--   /lang "<character>" <lang>   -> admin-set on target character (admin only)
--   /lang <character> <lang>     -> same, unquoted (works for single-word names)
-- 
-- The admin check fires only when a target name is supplied (two-arg form).
-- A non-admin typing the two-arg form gets denied; the one-arg form always
-- works for self-set.
-- 
-- Target resolution: forename or full "Forename Surname" match against the
-- online roster, case-insensitive. Targets must currently be online. (There
-- is no offline-edit path anymore: saves live in generation-stamped A/B slot
-- files. Use the admin commands.)
-- ============================================================================

-- ============================================================================
-- /lang COMMAND DISPATCHER (v8.4)
-- 
-- Subcommands:
--   /lang <language>                      -> self-set speaking (any player)
--   /lang "<character>" <lang>            -> admin set target's speaking
--   /lang <character> <lang>              -> same, unquoted (single-word names)
--   /lang grant <character> <lang>        -> admin grant native (v8.4)
--   /lang revoke <character> <lang>       -> admin revoke native (v8.4)
-- 
-- The dispatcher peeks at the first token. "grant" and "revoke" route to
-- the native-status handlers. Everything else falls through to the existing
-- self-set/admin-set-speaking behaviour.
-- 
-- Target resolution: forename or full "Forename Surname" match against the
-- online roster, case-insensitive. Targets must currently be online. (There
-- is no offline-edit path anymore: saves live in generation-stamped A/B slot
-- files. Use the admin commands.)
-- ============================================================================

local function resolveTargetByName(targetName)
    if not targetName or targetName == "" then return nil, nil end
    local needle = targetName:lower()
    for _, rec in ipairs(TAZC_Lang._onlinePlayerRecords()) do
        if rec.forename then
            local matched = rec.forename:lower() == needle
            if not matched and rec.surname and rec.surname ~= "" then
                matched = (rec.forename .. " " .. rec.surname):lower() == needle
            end
            if matched then
                return rec.username, rec.forename
            end
        end
    end
    return nil, nil
end

-- Common parse for "<target> <language>" with optional quoted target.
-- Returns (target, language) or (nil, nil) on parse failure.
local function parseTargetAndLanguage(argString)
    local target, language = argString:match('^%s*"([^"]+)"%s+(%S+)%s*$')
    if not target then
        target, language = argString:match('^%s*(%S+)%s+(%S+)%s*$')
    end
    return target, language
end

local function sysMsgRed(player, msg)
    sendServerCommand(player, "TAZC", "SystemMessage", {
        message = msg, color = {255, 100, 100}
    })
end
local function sysMsgGreen(player, msg)
    sendServerCommand(player, "TAZC", "SystemMessage", {
        message = msg, color = {100, 255, 100}
    })
end

-- E4 ergonomics (2026-07-08): "name" or "name (prefix)" for one language --
-- the parenthetical is omitted when the language's shortest unique prefix
-- IS its full name (no shortcut shorter than typing the whole thing
-- exists). Shared by unknownLanguageMsg and /lang list's language-reference
-- header so the shortcuts teach themselves wherever a language listing
-- appears.
local function describeLangWithPrefix(lang, pool)
    local prefix = TAZC_LangRegistry.shortestUniquePrefix(lang, pool)
    local display = TAZC_LangRegistry.displayName(lang)
    if prefix == lang then return display end
    return display .. " (" .. prefix .. ")"
end

local function languageListWithPrefixes()
    local pool = TAZC_LangRegistry.listLanguages()
    local parts = {}
    for _, lang in ipairs(pool) do
        parts[#parts + 1] = describeLangWithPrefix(lang, pool)
    end
    return table.concat(parts, ", ")
end

-- The "Unknown language" refusal is identical at every call site (6 of
-- them); single-sourced here rather than each rebuilding the available-
-- languages list.
local function unknownLanguageMsg(player)
    sysMsgRed(player, "Unknown language. Available: " .. languageListWithPrefixes())
end

-- ============================================================================
-- E1 ergonomics (2026-07-08): unique-prefix language resolution
--
-- Resolves a player-typed language token via TAZC_LangRegistry.matchLanguage
-- against every known language, and sends the appropriate kind refusal
-- itself (unknown / ambiguous) so every call site gets identical wording.
-- Returns the resolved lowercase language name on success, or nil (a
-- refusal has already been sent -- caller should just `return`).
--
-- Wherever a language name is accepted from a player: /lang set (both
-- self- and admin-target forms), /forget, /lang grant, /lang revoke.
-- ============================================================================
local function resolveLanguageInput(player, input)
    local kind, result = TAZC_LangRegistry.matchLanguage(input, TAZC_LangRegistry.listLanguages())
    if kind == "exact" or kind == "prefix" then
        return result
    end
    if kind == "ambiguous" then
        local displayNames = {}
        for _, lang in ipairs(result) do
            displayNames[#displayNames + 1] = TAZC_LangRegistry.displayName(lang)
        end
        sysMsgRed(player, input .. " could be: " .. table.concat(displayNames, ", ") .. ".")
        return nil
    end
    unknownLanguageMsg(player)
    return nil
end

-- The admin-gate refusal is identical at every gated command (6 of them);
-- single-sourced here rather than each rebuilding the same three lines.
-- Returns true and does nothing if the player is admin; otherwise sends
-- the refusal and returns false, so callers read `if not requireAdmin(...)
-- then return end`.
local function requireAdmin(player, label)
    if TAZC_Core.isAdmin(player) then return true end
    sysMsgRed(player, "/" .. label .. " is admin-only.")
    return false
end

-- ============================================================================
-- /lang grant <character> <language> (admin-only)
--
-- runGrantNative is the single core for BOTH transports: this chat command
-- (below, after name resolution) and TAZC_Server's GrantLanguage menu
-- command (which already holds the exact username -- no resolution needed,
-- see its own comment). `target` is a raw username; the display name is
-- looked up here via the online roster so neither caller has to carry a
-- forename. Mirrors runResetAll's shape (admin gate lives in the shared
-- core, not in each transport).
-- ============================================================================

function TAZC_LangCommands.runGrantNative(player, target, language)
    if not player or type(target) ~= "string" or target == ""
       or type(language) ~= "string" or language == "" then
        return
    end
    if not requireAdmin(player, "lang grant") then return end

    language = resolveLanguageInput(player, language)
    if not language then return end
    if language == "english" then
        sysMsgRed(player, "English is the universal baseline -- already known by everyone.")
        return
    end

    local display = TAZC_Lang._displayNameForUsername(target)
    local displayLang = TAZC_Lang._describeLang(language)

    local ok, alreadyHad = TAZC_Lang.grantNative(target, language)
    if not ok then
        sysMsgRed(player, "Failed to grant " .. displayLang .. " to " .. display .. ".")
        return
    end

    if alreadyHad then
        sysMsgGreen(player, display .. " already natively speaks " .. displayLang .. ".")
    else
        sysMsgGreen(player, display .. " now natively speaks " .. displayLang .. ".")
    end
    dbg("runGrantNative: %s granted %s (%s) native %s",
        TAZC_Core.safe(function() return player:getUsername() end, "?"),
        target, display, language)
end

function TAZC_LangCommands.handleGrantCommand(player, argString)
    if not player or type(argString) ~= "string" then return end

    local target, language = parseTargetAndLanguage(argString)
    if not target or not language then
        sysMsgRed(player, 'Usage: /lang grant <character> <language>')
        return
    end

    local resolvedUsername = resolveTargetByName(target)
    if not resolvedUsername then
        sysMsgRed(player, "No online character named '" .. target .. "'.")
        return
    end

    TAZC_LangCommands.runGrantNative(player, resolvedUsername, language)
end

-- ============================================================================
-- /lang revoke <character> <language> (admin-only)
--
-- runRevokeNative is grant's twin core -- see the comment above it.
-- ============================================================================

function TAZC_LangCommands.runRevokeNative(player, target, language)
    if not player or type(target) ~= "string" or target == ""
       or type(language) ~= "string" or language == "" then
        return
    end
    if not requireAdmin(player, "lang revoke") then return end

    language = resolveLanguageInput(player, language)
    if not language then return end
    if language == "english" then
        sysMsgRed(player, "English cannot be revoked -- it's the universal baseline.")
        return
    end

    local display = TAZC_Lang._displayNameForUsername(target)
    local displayLang = TAZC_Lang._describeLang(language)

    local ok, hadIt = TAZC_Lang.revokeNative(target, language)
    if not ok then
        sysMsgRed(player, "Failed to revoke " .. displayLang .. " from " .. display .. ".")
        return
    end

    if not hadIt then
        sysMsgGreen(player, display .. " didn't natively speak " .. displayLang .. " to begin with.")
    else
        sysMsgGreen(player, display .. " no longer natively speaks " .. displayLang ..
            " (they may still know vocabulary they've acquired).")
    end
    dbg("runRevokeNative: %s revoked %s (%s) native %s",
        TAZC_Core.safe(function() return player:getUsername() end, "?"),
        target, display, language)
end

function TAZC_LangCommands.handleRevokeCommand(player, argString)
    if not player or type(argString) ~= "string" then return end

    local target, language = parseTargetAndLanguage(argString)
    if not target or not language then
        sysMsgRed(player, 'Usage: /lang revoke <character> <language>')
        return
    end

    local resolvedUsername = resolveTargetByName(target)
    if not resolvedUsername then
        sysMsgRed(player, "No online character named '" .. target .. "'.")
        return
    end

    TAZC_LangCommands.runRevokeNative(player, resolvedUsername, language)
end

-- ============================================================================
-- /lang reset <character> [confirm] (admin-only)
--
-- Composite wipe of a character's linguistic identity: speaking choice,
-- all native grants, and ALL acquired vocabulary. Built for character
-- death / re-roll -- language state is per-username, so without this a
-- player's new character inherits the dead one's languages and weeks of
-- learned words.
--
-- DESTRUCTIVE AND IRREVERSIBLE, so it's two-step and stateless: bare
-- `/lang reset <char>` previews exactly what would be wiped;
-- `/lang reset <char> confirm` executes. No pending-confirmation state
-- to leak or time out -- the confirm token is part of the command.
-- ============================================================================

-- Parse '<target> [confirm]' with optional quoted target. Returns
-- (target, confirmed) or (nil, false) on parse failure.
local function parseResetArgs(argString)
    if type(argString) ~= "string" then return nil, false end
    local target, rest = argString:match('^%s*"([^"]+)"%s*(.*)$')
    if not target then
        target, rest = argString:match('^%s*(%S+)%s*(.*)$')
    end
    if not target or target == "" then return nil, false end
    rest = (rest or ""):match("^%s*(%S*)%s*$") or ""
    if rest == "" then return target, false end
    if rest:lower() == "confirm" then return target, true end
    return nil, false  -- trailing junk that isn't "confirm": refuse, don't guess
end

function TAZC_LangCommands.handleResetCommand(player, argString)
    if not player or type(argString) ~= "string" then return end
    if not requireAdmin(player, "lang reset") then return end

    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang reset <character>  -- preview, then /lang reset <character> confirm')
        return
    end

    local resolvedUsername, resolvedForename = resolveTargetByName(target)
    if not resolvedUsername then
        sysMsgRed(player, "No online character named '" .. target .. "'.")
        return
    end

    -- Build the inventory (used by both preview and the post-wipe report).
    local speaking = TAZC_Lang.getLanguage(resolvedUsername)
    local natives  = {}
    for _, lang in ipairs(TAZC_Lang.getNativeLanguages(resolvedUsername)) do
        if lang ~= "english" then natives[#natives + 1] = TAZC_Lang._describeLang(lang) end
    end
    local acq = TAZC_Acquisition.languagesWithData(resolvedUsername)
    local acqParts = {}
    for _, entry in ipairs(acq) do
        acqParts[#acqParts + 1] = string.format("%s (%d tokens)",
            TAZC_Lang._describeLang(entry.lang), entry.tokens)
    end

    local speakingLine = (speaking == "english")
        and "Speaking: English (baseline)"
        or  ("Speaking: " .. TAZC_Lang._describeLang(speaking))
    local nativeLine = "Native: " ..
        (#natives > 0 and table.concat(natives, ", ") or "none beyond English")
    local acqLine = "Acquired vocabulary: " ..
        (#acqParts > 0 and table.concat(acqParts, ", ") or "none")

    if not confirmed then
        TAZC_Lang._sysMsg(player, "Reset preview for " .. resolvedForename ..
            " (" .. resolvedUsername .. "):")
        TAZC_Lang._sysMsg(player, "  " .. speakingLine)
        TAZC_Lang._sysMsg(player, "  " .. nativeLine)
        TAZC_Lang._sysMsg(player, "  " .. acqLine)
        if speaking == "english" and #natives == 0 and #acqParts == 0 then
            TAZC_Lang._sysMsg(player, "Nothing to wipe -- this character is already at baseline.")
            return
        end
        sysMsgRed(player, "This wipes ALL of the above, irreversibly. " ..
            'To proceed: /lang reset "' .. resolvedForename .. '" confirm')
        return
    end

    local summary = TAZC_Lang.resetUser(resolvedUsername)
    local _, langsWiped = TAZC_Acquisition.forgetUser(resolvedUsername)
    -- Destructive op: persist NOW rather than waiting up to a minute for the
    -- periodic flush. (resetUser already saved the language DB.)
    TAZC_Acquisition.flushNow()

    sysMsgGreen(player, string.format(
        "Reset %s (%s): speaking cleared, %d native grant(s) revoked, " ..
        "acquired vocabulary wiped for %d language(s).",
        resolvedForename, resolvedUsername, #summary.natives, langsWiped))
    dbg("handleResetCommand: %s reset %s (%s): speaking=%s natives=%d acqLangs=%d",
        TAZC_Core.safe(function() return player:getUsername() end, "?"),
        resolvedUsername, resolvedForename,
        tostring(summary.speaking), #summary.natives, langsWiped)
end

-- ============================================================================
-- /lang prune <character> [confirm] (admin-only)
--
-- Surgical cleanup for orphaned native grants: a native-language key that
-- was registered once but has since been renamed or removed from the live
-- registry (TAZC_LangRegistry.isKnownLanguage), left behind on a character's
-- record from before the change -- TAZC_LangRegistry.displayName already
-- marks one honestly wherever it's shown ("Japonic (no longer spoken
-- here)"), but display never deletes on its own. Unlike /lang reset (the
-- composite wipe, which also clears orphans but only as a side effect of
-- clearing EVERYTHING), prune touches ONLY the dead key(s) -- speaking
-- choice, every native grant that's still a real registered language, and
-- all acquired vocabulary are left exactly as they were.
--
-- Same stateless two-step shape as /lang reset: bare preview, `confirm`
-- executes. Reuses parseResetArgs -- identical '<target> [confirm]' shape.
-- ============================================================================

function TAZC_LangCommands.handlePruneCommand(player, argString)
    if not player or type(argString) ~= "string" then return end
    if not requireAdmin(player, "lang prune") then return end

    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang prune <character>  -- preview, then /lang prune <character> confirm')
        return
    end

    local resolvedUsername, resolvedForename = resolveTargetByName(target)
    if not resolvedUsername then
        sysMsgRed(player, "No online character named '" .. target .. "'.")
        return
    end

    local orphans = TAZC_Lang.getOrphanedNatives(resolvedUsername)

    if #orphans == 0 then
        TAZC_Lang._sysMsg(player, resolvedForename .. " (" .. resolvedUsername ..
            ") carries no orphaned native languages -- nothing to prune.")
        return
    end

    if not confirmed then
        TAZC_Lang._sysMsg(player, "Prune preview for " .. resolvedForename ..
            " (" .. resolvedUsername .. "):")
        TAZC_Lang._sysMsg(player, "  Orphaned native(s) -- no longer a registered language: " ..
            table.concat(orphans, ", "))
        TAZC_Lang._sysMsg(player, "  Everything else (speaking choice, other native grants, " ..
            "acquired vocabulary) is left untouched.")
        sysMsgRed(player, "This removes the above native grant(s), irreversibly. " ..
            'To proceed: /lang prune "' .. resolvedForename .. '" confirm')
        return
    end

    local pruned = TAZC_Lang.pruneOrphanedNatives(resolvedUsername)
    sysMsgGreen(player, string.format(
        "Pruned %d orphaned native grant(s) from %s (%s): %s.",
        #pruned, resolvedForename, resolvedUsername, table.concat(pruned, ", ")))

    -- Loud, ALWAYS-ON audit line -- same always-on print class as
    -- runResetAll's [TAZC][WIPE] line: an operator must be able to
    -- answer "who pruned whom, and what was removed" with DEBUG off.
    local adminUsername = TAZC_Core.safe(function() return player:getUsername() end, "?")
    print(string.format(
        "[TAZC][PRUNE] %s pruned orphaned native(s) from %s (%s): %s",
        adminUsername, resolvedForename, resolvedUsername, table.concat(pruned, ", ")))

    dbg("handlePruneCommand: %s pruned %s (%s): %s",
        adminUsername, resolvedUsername, resolvedForename, table.concat(pruned, ", "))
end

-- ============================================================================
-- /lang resetall <username> [confirm] (admin-only) -- the TOTAL wipe
--
-- Everything Terror AustraliZ Chat remembers about one username, across every durable
-- store, in one two-step command:
--
--   TAZC_Languages    (TAZC_Lang.lua)        speaking choice + native grants
--   TAZC_Acquisitions (TAZC_Acquisition)   every heard/acquired word, production
--                                      practice, misheard meanings, teaching
--                                      provenance (voices/firstVoice)
--   TAZC_Taglines     (TAZC_Server)        the bio line -- via a registered wipe
--                                      extension (see below; wired)
--   TAZC_Avatars      (TAZC_AvatarServer)  portrait approvals/pendings -- same
--                                      extension mechanism (wired)
--   TAZC_Hues         (TAZC_Server)        the /hue chosen name color -- same
--                                      extension mechanism (wired)
--
-- WHY USERNAME, NOT FORENAME: /lang reset resolves forenames against the
-- online roster, which is friendly but ambiguous -- two characters can share
-- a forename, and a total wipe pointed at the wrong player is unrecoverable.
-- resetall therefore matches the USERNAME exactly (the stores' own key,
-- case-sensitive), shows the resolved character name in the preview, and
-- works for offline usernames too -- the data outlives the character, so
-- the broom must reach where the roster can't. A typo'd username has no
-- store data behind it and is refused outright, so nothing can be lost to
-- a slip of the finger.
--
-- KNOWN REMAINDER: TAZC_Server's session-local language-identification cache
-- (identifiedLangs) is out of reach from here; a wiped player who stays
-- online keeps seeing language TAGS (not comprehension) until the next
-- server restart. Cosmetic, documented, accepted.
-- ============================================================================

-- The core runner, shared by the /lang resetall chat form and the admin
-- context menu's WipeAll client command. `target` is a raw username string;
-- gate, resolution, preview, and execution all live here (server-side truth).
local function runResetAll(player, target, confirmed)
    if not player or type(target) ~= "string" or target == "" then return end
    if not requireAdmin(player, "lang resetall") then return end

    local targetPlayer = TAZC_Lang._playerByUsername(target)
    local forename = nil
    if targetPlayer then
        forename = TAZC_Core.safe(function()
            local desc = targetPlayer:getDescriptor()
            return desc and desc:getForename() or nil
        end, nil)
    end

    local inv = TAZC_Lang._buildWipeInventory(target)

    -- Nobody online under that exact username AND nothing in any store:
    -- almost certainly a typo. Refusing is what makes exact-match safe.
    if not targetPlayer and inv.empty then
        sysMsgRed(player, "Terror AustraliZ Chat carries nothing under the username '" ..
            target .. "', and no one online matches it exactly. " ..
            "(resetall matches usernames exactly -- /lang list shows them.)")
        return
    end

    local who = forename
        and (forename .. " (" .. target .. ")")
        or  (target .. " (offline right now)")

    if not confirmed then
        TAZC_Lang._sysMsg(player, "Total wipe preview for " .. who .. ":")
        for _, line in ipairs(TAZC_Lang._wipeInventoryLines(inv)) do
            TAZC_Lang._sysMsg(player, "  " .. line)
        end
        if inv.empty then
            TAZC_Lang._sysMsg(player, "Nothing to wipe -- Terror AustraliZ Chat carries nothing for them.")
            return
        end
        sysMsgRed(player, "This erases everything above, irreversibly. " ..
            'To proceed: /lang resetall "' .. target .. '" confirm')
        return
    end

    if inv.empty then
        TAZC_Lang._sysMsg(player, "Nothing to wipe -- Terror AustraliZ Chat already carries nothing for " .. who .. ".")
        return
    end

    -- Execute, store by store.
    TAZC_Lang.resetUser(target)                                -- TAZC_Languages (saves itself)
    local _, langsWiped = TAZC_Acquisition.forgetUser(target)  -- TAZC_Acquisitions
    -- Destructive op: persist NOW rather than waiting up to a minute for
    -- the periodic flush (same rule as /lang reset).
    TAZC_Acquisition.flushNow()
    local extsWiped, extsFailed = {}, {}
    for id, ext in pairs(TAZC_Lang._wipeExtensions) do
        if inv.exts[id] then
            local ok, removed = pcall(ext.clear, target)
            if ok and removed == true then
                extsWiped[#extsWiped + 1] = ext.label:lower()
            else
                -- Held data but didn't confirm the clear: a partial wipe
                -- must never pass silently as a full one.
                extsFailed[#extsFailed + 1] = ext.label:lower()
                if not ok then
                    dbg("runResetAll: extension '%s' clear threw: %s", id, tostring(removed))
                end
            end
        end
    end
    table.sort(extsWiped)
    table.sort(extsFailed)
    TAZC_Lang._traceUsers[target] = nil                                 -- session: trace opt-in

    -- Loud, ALWAYS-ON audit line -- same always-on print class as
    -- TAZC_Persist's corruption warnings. An operator must be able to answer
    -- "who wiped whom, and what was lost" with DEBUG off.
    local adminUsername = TAZC_Core.safe(function() return player:getUsername() end, "?")
    print(string.format("[TAZC][WIPE] %s wiped ALL Terror AustraliZ Chat data for %s: %s%s",
        adminUsername, who, table.concat(TAZC_Lang._wipeInventoryLines(inv), "; "),
        (#extsFailed > 0)
            and (" [NOT cleared: " .. table.concat(extsFailed, ", ") .. "]")
            or ""))

    local extraBits = ""
    if #extsWiped > 0 then
        extraBits = ", " .. table.concat(extsWiped, " erased, ") .. " erased"
    end
    sysMsgGreen(player, string.format(
        "Every trace of %s is gone: language identity cleared, vocabulary wiped " ..
        "for %d language(s)%s.",
        who, langsWiped, extraBits))
    if #extsFailed > 0 then
        sysMsgRed(player, "One part would not let go: " ..
            table.concat(extsFailed, ", ") ..
            " didn't confirm its wipe. Check the server log and try again.")
    end
    dbg("runResetAll: %s wiped %s (langsWiped=%d extsWiped=%d extsFailed=%d)",
        adminUsername, target, langsWiped, #extsWiped, #extsFailed)
end

function TAZC_LangCommands.handleResetAllCommand(player, argString)
    if not player or type(argString) ~= "string" then return end
    -- Same '<target> [confirm]' shape as /lang reset (quoted target
    -- supported; trailing junk that isn't "confirm" is refused, not guessed).
    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang resetall <username>  -- preview, then ' ..
            '/lang resetall <username> confirm. Matches usernames exactly.')
        return
    end
    runResetAll(player, target, confirmed)
end

-- ============================================================================
-- MENU TRANSPORT for the total wipe
--
-- The admin context menu (client/TAZC_LangAdmin) reaches resetall through its
-- own client command on its own module name -- TAZC_Server's dispatch stays
-- untouched (its OnClientCommand listener returns early on foreign module
-- names). The admin gate and every validation live in runResetAll; this
-- listener only shapes the args, exactly as cautiously as TAZC_Server's
-- validString does (C15: malicious clients can send anything).
-- ============================================================================

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "TAZCLang" then return end
    if command ~= "WipeAll" then return end
    if not player or type(args) ~= "table" then return end
    local target = args.target
    if type(target) ~= "string" then return end
    target = target:gsub("[%c]", "")
    if target == "" or #target > 64 then return end
    local ok, err = pcall(runResetAll, player, target, args.confirm == true)
    if not ok then
        print(string.format(
            "[TAZC][ERROR] WipeAll transport '%s' failed: %s",
            tostring(command), tostring(err)))
    end
end)

-- ============================================================================
-- /forget <language> [confirm] (self-serve)
--
-- A player lets go of a language they've been learning: wipes THEIR OWN
-- acquired vocabulary and exposure for that one language, and nothing else.
-- Built for re-rolled characters who inherited an old life's words (see
-- TAZC_Lang.handleFreshCharacter), but open to anyone -- it only ever acts on
-- the caller. Speaking choice and native grants are untouched (those are
-- /lang's to manage).
--
-- DESTRUCTIVE AND IRREVERSIBLE, so it mirrors /lang reset's stateless
-- two-step: bare `/forget <language>` previews what would be lost;
-- `/forget <language> confirm` executes.
-- ============================================================================

-- Parse '<language> [confirm]'. Returns (language, confirmed) or (nil, false).
local function parseForgetArgs(argString)
    if type(argString) ~= "string" then return nil, false end
    local lang, rest = argString:match("^%s*(%S+)%s*(.*)$")
    if not lang or lang == "" then return nil, false end
    rest = (rest or ""):match("^%s*(%S*)%s*$") or ""
    if rest == "" then return lang, false end
    if rest:lower() == "confirm" then return lang, true end
    return nil, false  -- trailing junk that isn't "confirm": refuse, don't guess
end

function TAZC_LangCommands.handleForgetCommand(player, argString)
    if not player then return end
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local lang, confirmed = parseForgetArgs(argString or "")
    if not lang then
        TAZC_Lang._sysMsg(player, "Usage: /forget <language>  -- see what you'd lose, then /forget <language> confirm")
        return
    end

    lang = resolveLanguageInput(player, lang)
    if not lang then return end
    local displayLang = TAZC_Lang._describeLang(lang)
    if lang == "english" then
        sysMsgRed(player, "English is the universal baseline -- it can't be forgotten.")
        return
    end
    if TAZC_Lang.isNative(username, lang) then
        sysMsgRed(player, displayLang .. " is your native tongue -- it isn't yours to forget.")
        return
    end

    -- Inventory: everything tracked for this language, and how much of it
    -- the player has genuinely made their own (acquired).
    local tracked = 0
    for _, entry in ipairs(TAZC_Acquisition.languagesWithData(username)) do
        if entry.lang == lang then tracked = entry.tokens end
    end
    if tracked == 0 then
        TAZC_Lang._sysMsg(player, "You carry nothing of " .. displayLang .. " -- there's nothing to forget.")
        return
    end
    local palette = TAZC_LangRegistry.getPalette(lang)
    local acquiredN = 0
    if palette then
        acquiredN = TAZC_Acquisition.acquiredCountForPalette(username, lang, palette)
    end

    if not confirmed then
        TAZC_Lang._sysMsg(player, string.format(
            "Forgetting %s: %d word(s) you've made your own, %d heard in all -- every one of them would fade.",
            displayLang, acquiredN, tracked))
        sysMsgRed(player, "Gone is gone -- there's no earning them back but the long way. " ..
            "To let " .. displayLang .. " go: /forget " .. lang .. " confirm")
        return
    end

    local wiped = TAZC_Acquisition.forgetLanguage(username, lang)
    -- Destructive op: persist NOW rather than waiting for the periodic
    -- flush (same rule as /lang reset).
    if wiped then TAZC_Acquisition.flushNow() end
    sysMsgGreen(player, displayLang .. " slips away. The words of that life are gone.")
    if TAZC_Lang.getLanguage(username) == lang then
        TAZC_Lang._sysMsg(player, "You're still set to speak it -- /lang english if you'd rather not.")
    end
    dbg("handleForgetCommand: %s forgot %s (wiped=%s, tracked=%d)",
        username, lang, tostring(wiped), tracked)
end

-- ============================================================================
-- /lang list (admin-only)
--
-- Roster overview: every username with language state (speaking and/or
-- native grants), with online forenames marked. Capped to avoid flooding
-- the panel on large databases.
-- ============================================================================

local LIST_MAX_LINES = 60

function TAZC_LangCommands.handleListCommand(player)
    if not player then return end
    if not requireAdmin(player, "lang list") then return end

    -- E4 ergonomics: the language reference (with each name's shortest
    -- unique prefix) heads the roster, so admins running the one command
    -- that surfaces "every language" also see the shortcuts.
    TAZC_Lang._sysMsg(player, "Languages: " .. languageListWithPrefixes())

    -- Online username -> forename map, one roster pass.
    local onlineForename = {}
    for _, rec in ipairs(TAZC_Lang._onlinePlayerRecords()) do
        if rec.username then onlineForename[rec.username] = rec.forename or "?" end
    end

    -- Collect + sort usernames with any language state.
    local usernames = {}
    for username in pairs(TAZC_Lang._langDBUsers()) do
        usernames[#usernames + 1] = username
    end
    table.sort(usernames)

    if #usernames == 0 then
        TAZC_Lang._sysMsg(player, "No language assignments yet -- everyone is at the English baseline.")
        return
    end

    TAZC_Lang._sysMsg(player, string.format("Language assignments (%d):", #usernames))
    for i, username in ipairs(usernames) do
        if i > LIST_MAX_LINES then
            TAZC_Lang._sysMsg(player, string.format("  ...and %d more.",
                #usernames - LIST_MAX_LINES))
            break
        end
        local rec = TAZC_Lang._langDBUsers()[username]
        local speaking = rec.speaking and TAZC_Lang._describeLang(rec.speaking) or "English"
        local natives = {}
        for lang in pairs(rec.native or {}) do natives[#natives + 1] = TAZC_Lang._describeLang(lang) end
        table.sort(natives)
        local nativeStr = (#natives > 0) and (" | native: " .. table.concat(natives, ", ")) or ""
        local onlineStr = onlineForename[username]
            and (" [online: " .. onlineForename[username] .. "]") or ""
        TAZC_Lang._sysMsg(player, string.format("  %s -- speaking %s%s%s",
            username, speaking, nativeStr, onlineStr))
    end
end

-- ============================================================================
-- /lang DISPATCHER ENTRY POINT
--
-- Peeks at first token; routes "grant"/"revoke" to native-status handlers,
-- "reset"/"resetall" to the wipe handlers, "prune" to the orphaned-native
-- cleanup handler, "forget"/"list" likewise, otherwise falls through to the
-- original self-set/admin-set-speaking logic.
-- ============================================================================

function TAZC_LangCommands.handleSetCommand(player, argString)
    if not player or type(argString) ~= "string" then return end

    -- Subcommand routing.
    local firstToken = argString:match("^%s*(%S+)")
    if firstToken then
        local lower = firstToken:lower()
        if lower == "grant" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handleGrantCommand(player, rest)
        elseif lower == "revoke" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handleRevokeCommand(player, rest)
        elseif lower == "reset" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handleResetCommand(player, rest)
        elseif lower == "prune" then
            -- Surgical orphaned-native cleanup: everything else untouched.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handlePruneCommand(player, rest)
        elseif lower == "resetall" then
            -- The total wipe: every store, one username, two steps.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handleResetAllCommand(player, rest)
        elseif lower == "forget" then
            -- Self-serve twin of /forget -- same handler, same two-step.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return TAZC_LangCommands.handleForgetCommand(player, rest)
        elseif lower == "list" then
            return TAZC_LangCommands.handleListCommand(player)
        end
    end

    -- Fall through to the original speaking-language setter.
    local senderUsername = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not senderUsername then return end

    local isAdmin = TAZC_Core.isAdmin(player)

    -- Parse forms, in order of specificity:
    --   '"name" lang' -> two args, quoted target
    --   'name lang'   -> two args, unquoted target
    --   'lang'        -> single arg, self-set
    local target, language = parseTargetAndLanguage(argString)
    if not target and not language then
        language = argString:match('^%s*(%S+)%s*$')
    end

    if not language or language == "" then
        -- Bare /lang: show the character's current status. Players forget
        -- what they've set; the frictionless answer is to just tell them.
        local speaking = TAZC_Lang.getLanguage(senderUsername)
        local speakingLine
        if speaking == "english" then
            speakingLine = "You're speaking English (baseline)."
        else
            local displaySpeaking = TAZC_Lang._describeLang(speaking)
            local fluency = TAZC_Lang.isNative(senderUsername, speaking)
                and "native" or "learner -- your words will come out broken until you've picked up more of the language"
            speakingLine = "You're speaking " .. displaySpeaking .. " (" .. fluency .. ")."
        end
        TAZC_Lang._sysMsg(player, speakingLine, {140, 200, 220})

        local natives = {}
        for _, lang in ipairs(TAZC_Lang.getNativeLanguages(senderUsername)) do
            natives[#natives + 1] = TAZC_Lang._describeLang(lang)
        end
        TAZC_Lang._sysMsg(player, "Native: " .. table.concat(natives, ", ") ..
            ". Use /comp for comprehension estimates.")

        -- E3: previous language (what /ll switches back to), plain and
        -- either way -- always answered, never a silent gap.
        local previous = TAZC_Lang.getPreviousLanguage(senderUsername)
        if previous then
            TAZC_Lang._sysMsg(player, "Previous: " .. TAZC_Lang._describeLang(previous) .. ".")
        else
            TAZC_Lang._sysMsg(player, "Previous: none yet.")
        end

        local usage = isAdmin
            and 'Switch: /lang <language>  OR  /lang "<character>" <language>  OR  /lang grant|revoke|reset|prune <character> ...  OR  /lang resetall <username>  OR  /lang list'
            or  ("Switch: /lang <" .. table.concat(TAZC_LangRegistry.listLanguages(), "|") .. ">")
        TAZC_Lang._sysMsg(player, usage)
        TAZC_Lang._sysMsg(player, "Let a language you've been learning go: /forget <language>")
        -- E3/E2 hint: plain, one line, no flourish -- the shortcuts teach
        -- themselves from here rather than needing to be discovered.
        TAZC_Lang._sysMsg(player, "Tip: /ll switches back to your previous language. " ..
            "@<language> at the start of a message speaks just that one line in " ..
            "another language (e.g. @french bonjour), without changing what you're set to.")
        return
    end

    language = resolveLanguageInput(player, language)
    if not language then return end
    -- ASL toggle (the first per-language one): checked live, not through
    -- the boot-time cache, so a server operator flipping it mid-session
    -- takes effect immediately. ASL stays registered either way -- this
    -- only gates picking it as a speaking language, same "inert, not
    -- unregistered" shape as Terror AustraliZ Chat.LanguagesEnabled above it.
    if language == "asl" and TAZC_Config.liveSandbox("ASLEnabled", true) == false then
        sysMsgRed(player, "ASL is disabled on this server.")
        return
    end

    local targetUsername = senderUsername
    local targetDisplay = nil  -- nil = self

    if target then
        if not isAdmin then
            sysMsgRed(player, "Only admins can assign speaking languages to other characters.")
            return
        end
        local resolvedUsername, resolvedForename = resolveTargetByName(target)
        if not resolvedUsername then
            sysMsgRed(player, "No online character named '" .. target .. "'.")
            return
        end
        targetUsername = resolvedUsername
        targetDisplay = resolvedForename
    end

    TAZC_Lang.setLanguage(targetUsername, language)

    local displayLang = TAZC_Lang._describeLang(language)
    local who = targetDisplay or "Your"
    local nativeNote = ""
    if language ~= "english" and not TAZC_Lang.isNative(targetUsername, language) then
        nativeNote = targetDisplay
            and " (learner -- their words will come out broken until they've picked up more of the language)"
            or  " (learner -- your words will come out broken until you've picked up more of the language)"
    end
    local confirmMsg = targetDisplay
        and (targetDisplay .. " is now speaking " .. displayLang .. nativeNote .. ".")
        or  ("You are now speaking " .. displayLang .. nativeNote .. ".")
    sysMsgGreen(player, confirmMsg)

    dbg("handleSetCommand: %s set %s (%s) speaking -> %s (native=%s)",
        senderUsername, targetUsername, tostring(targetDisplay or "self"), language,
        tostring(TAZC_Lang.isNative(targetUsername, language)))
end

-- ============================================================================
-- /ll (E3 ergonomics, 2026-07-08): toggle back to your previous language
--
-- The alt-tab: most bilingual RP bounces between exactly two languages, and
-- typing "/lang french" every time gets exhausting. /ll re-sets whatever
-- TAZC_Lang.getPreviousLanguage reports -- which TAZC_Lang.setLanguage itself
-- keeps current on every REAL change (see its own comment) -- so calling
-- /ll again immediately swaps back, a genuine two-way toggle with no extra
-- bookkeeping here.
--
-- Self-serve only (no admin-on-target form): this is personal ergonomics,
-- like /forget, not an admin tool. Takes no arguments.
-- ============================================================================

function TAZC_LangCommands.handleToggleLastCommand(player, _argString)
    if not player then return end
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local previous = TAZC_Lang.getPreviousLanguage(username)
    if not previous then
        TAZC_Lang._sysMsg(player, "You don't have a previous language to switch back to yet -- " ..
            "/ll remembers whatever you were speaking before your current language.")
        return
    end

    -- `previous` was only ever recorded by a prior successful setLanguage,
    -- so it's a real registered language -- but a server operator could
    -- have live-disabled it (ASL) since then. Same guard handleSetCommand
    -- applies before calling into TAZC_Lang.setLanguage.
    if not TAZC_Lang.isSelectableLanguage(previous) then
        sysMsgRed(player, TAZC_Lang._describeLang(previous) .. " isn't available right now.")
        return
    end

    TAZC_Lang.setLanguage(username, previous)

    local displayLang = TAZC_Lang._describeLang(previous)
    local nativeNote = ""
    if previous ~= "english" and not TAZC_Lang.isNative(username, previous) then
        nativeNote = " (learner -- your words will come out broken until you've picked up more of the language)"
    end
    sysMsgGreen(player, "Switched back to " .. displayLang .. nativeNote .. ".")

    dbg("handleToggleLastCommand: %s toggled -> %s", username, previous)
end

-- ============================================================================
-- /lex COMMAND
-- 
-- List tokens the player has acquired in a given language (or all languages
-- they have any exposure in, if no arg). For each L2 form, the concept it
-- lexicalizes is recovered via the reverse-lex map, and the primary English
-- alias of that concept is shown as the L1 meaning.
-- 
-- Usage:
--   /lex             -> summary across all languages
--   /lex french      -> detailed list for one language
-- ============================================================================

local function listAcquiredForLang(username, sourceLang)
    local palette = TAZC_LangRegistry.getPalette(sourceLang)
    if not palette then return {}, 0, 0 end

    -- l2_lower -> primary L1 alias -- TAZC_Resolve.reverseLexL1 exists for
    -- exactly this display purpose (same tie-break as reverseLex: sorted
    -- concept ids, first writer wins). reverseLexAll additionally surfaces
    -- every sense a conflated form carries (below).
    local reverseL1 = TAZC_Resolve.reverseLexL1(palette)
    local reverseAll = TAZC_Resolve.reverseLexAll(palette)
    local Concepts = require("TAZC_Concepts")
    local lexSize = 0
    if palette.lex then
        for _ in pairs(palette.lex) do lexSize = lexSize + 1 end
    end

    -- Zipf rank lookup: L2_lower -> rank. Rank is a palette-level fact, not
    -- stored per-exposure, so we resolve it here at query time. Cached on
    -- the palette by getZipfRankMap.
    local rankMap = TAZC_Lang._getZipfRankMap(palette)

    local acquired = {}
    local familyCloseness = TAZC_Acquisition.familyClosenessForLang(sourceLang)
    local all = TAZC_Acquisition.getAllTokens(username, sourceLang)
    for token, exp in pairs(all) do
        -- The explicit acquired flag is the authority here -- the same one
        -- the render and /comp consult. Recomputing the raw probability
        -- used to hide words earned through teaching or form migration
        -- whose count sat below the statistical threshold: a word earned
        -- is a word listed.
        if exp.acquired then
            -- only surface tokens that the current palette actually
            -- lexicalizes through the concept tree. Orphan records (acquired
            -- L2 forms whose concept was removed from the palette, e.g.
            -- v8.x "bonjour" or "danger" on a concept-keyed French palette)
            -- are filtered out rather than displayed as "bonjour (?)" --
            -- the player has no actionable signal from a question mark, and
            -- the record will decay out naturally without disuse-reinforcement.
            local l1 = reverseL1 and reverseL1[token:lower()] or nil
            if l1 then
                -- v8.16.1: conflated forms gloss EVERY sense ("vurmak =
                -- hit / shoot") instead of an arbitrary single concept --
                -- a player who learned the word for both shouldn't see
                -- half of what they know.
                local allIds = reverseAll and reverseAll[token:lower()] or nil
                if allIds and #allIds > 1 then
                    local glosses = {}
                    for _, cid in ipairs(allIds) do
                        local c = Concepts.get(cid)
                        local g = c and c.en and c.en[1] or nil
                        if g then glosses[#glosses + 1] = g end
                    end
                    if #glosses > 1 then
                        l1 = table.concat(glosses, " / ")
                    end
                end
                if l1 then
                    -- Qualitative state for display (fresh/familiar) -- the
                    -- same classifier the render uses. Raw counts aren't
                    -- surfaced to players here.
                    local rank = rankMap and rankMap[token:lower()] or nil
                    local ts = TAZC_Acquisition.tokenState(exp, rank, familyCloseness)
                    -- v8.16.1 "Voices": provenance ride-along for display.
                    local nVoices = 1
                    if type(exp.voices) == "table" and #exp.voices > 0 then
                        nVoices = #exp.voices
                    end
                    -- Misacquisition: show the wrong meaning if active.
                    local displayL1 = l1
                    local misacquired = false
                    if exp.misacquiredAs then
                        local wrongConcept = Concepts.get(exp.misacquiredAs)
                        if wrongConcept and wrongConcept.en and wrongConcept.en[1] then
                            displayL1 = wrongConcept.en[1]
                            misacquired = true
                        end
                    end
                    table.insert(acquired, {
                        l2 = token, l1 = displayL1, state = ts.state,
                        voices = nVoices, firstVoice = exp.firstVoice,
                        lastHeard = exp.lastHeard,
                        misacquired = misacquired,
                    })
                end
            end
        end
    end
    -- Stable display order: by L2 form.
    table.sort(acquired, function(a, b) return a.l2 < b.l2 end)
    return acquired, #acquired, lexSize
end

function TAZC_LangCommands.handleLexCommand(player, argString)
    if not player then return end
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local arg = argString and argString:match("^%s*(%S+)%s*$") or nil

    if arg then
        local lang = arg:lower()
        -- v8.16.1: /lex trace -- toggle the per-utterance acquisition trace.
        -- Admin-only (it reveals raw mechanics numbers). Used to also allow
        -- self-serve under the "test" acquisition profile; that profile was
        -- stripped from the stable cut (AcquisitionTestMode removed this
        -- release, TAZC_Acquisition's PROFILES table now holds only "live"),
        -- so the admin check is the whole gate.
        if lang == "trace" then
            if not requireAdmin(player, "lex trace") then return end
            TAZC_Lang._traceUsers[username] = not TAZC_Lang._traceUsers[username] or nil
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = TAZC_Lang._traceUsers[username]
                    and "Acquisition trace ON -- every utterance you hear reports what registered."
                    or "Acquisition trace off.",
                color = {120, 180, 180},
            })
            return
        end
        if not TAZC_LangRegistry.isKnownLanguage(lang) then
            unknownLanguageMsg(player)
            return
        end
        if lang == "english" then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "English is the baseline -- natively known by everyone.",
                color = {200, 200, 200},
            })
            return
        end

        local displayLang = TAZC_Lang._describeLang(lang)

        -- Native? Short-circuit with a different shape -- no acquisition tracking
        -- for native languages.
        if TAZC_Lang.isNative(username, lang) then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = string.format("%s: you natively speak this -- full fluency, no acquisition tracking.", displayLang),
                color = TAZC_Core.Colors.SOFT_PURPLE,
            })
            return
        end

        local acquired, count, lexSize = listAcquiredForLang(username, lang)

        -- Comprehension percentage (inline -- saves a separate /comp).
        local palette = TAZC_LangRegistry.getPalette(lang)
        local pct = palette
            and TAZC_Acquisition.estimateComprehension(username, lang, palette) or 0

        if count == 0 then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = string.format("%s (learning): no words acquired yet (0 / %d).", displayLang, lexSize),
                color = {200, 200, 200},
            })
            -- Even with no acquisitions, show near-acquisition words if any.
        else
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = string.format(
                    "%s (learning): %d / %d words acquired, ~%d%% comprehension.",
                    displayLang, count, lexSize, pct),
                color = {140, 200, 220},
            })

            -- Fading detection: acquired words past their receptive grace
            -- period are actively decaying. A quiet "[fading]" suffix lets
            -- the player know "use it or lose it" without engine narration.
            local now = os.time()
            local graceSeconds = TAZC_Acquisition.graceDaysReceptive()
                * TAZC_Acquisition.secondsPerDay()

            for _, entry in ipairs(acquired) do
                local voiceBits
                if (entry.voices or 1) >= TAZC_Acquisition.voicesTrackCap() then
                    voiceBits = TAZC_Acquisition.voicesTrackCap() .. "+ voices"
                elseif (entry.voices or 1) == 1 then
                    voiceBits = "1 voice"
                else
                    voiceBits = entry.voices .. " voices"
                end
                if entry.firstVoice then
                    voiceBits = voiceBits .. ", first heard from " .. entry.firstVoice
                end
                local fadeSuffix = ""
                if entry.lastHeard and (now - entry.lastHeard) > graceSeconds then
                    fadeSuffix = "  [fading]"
                end
                local glossSuffix = entry.misacquired and " (?)" or ""
                sendServerCommand(player, "TAZC", "SystemMessage", {
                    message = string.format("  %s = %s%s  (%s; %s)%s",
                        entry.l2, entry.l1, glossSuffix, entry.state, voiceBits, fadeSuffix),
                    color = entry.misacquired and {220, 190, 150}
                        or (fadeSuffix ~= "" and {180, 160, 160} or {200, 200, 200}),
                })
            end
        end

        -- Near-acquisition: words the player is CLOSE to acquiring but
        -- hasn't crossed yet. Shows L2 forms only -- no L1 gloss, because
        -- the player should discover the meaning through exposure, not by
        -- reading /lex. Limited to 5 words, sorted by proximity (closest
        -- to acquisition first). Only shown if any exist.
        if palette then
            local threshold = TAZC_Acquisition.acquisitionThreshold()
            local rankMap = TAZC_Lang._getZipfRankMap(palette)
            local reverse = TAZC_Lang._getReverseLex(palette)
            local familyCloseness = TAZC_Acquisition.familyClosenessForLang(lang)
            local all = TAZC_Acquisition.getAllTokens(username, lang)
            local emerging = {}
            for token, exp in pairs(all) do
                if not exp.acquired and (exp.count or 0) > 0 then
                    local rank = rankMap and rankMap[token:lower()] or nil
                    -- Only show tokens the palette currently lexicalizes.
                    local conceptId = reverse and reverse[token:lower()] or nil
                    if conceptId then
                        local prob = TAZC_Acquisition.comprehensionProb(
                            exp.count or 0, exp.contextBoost or 1.0,
                            rank, familyCloseness)
                        -- Show words at 50%+ of threshold (meaningful proximity).
                        if prob >= threshold * 0.5 then
                            emerging[#emerging + 1] = { l2 = token, prob = prob }
                        end
                    end
                end
            end
            if #emerging > 0 then
                table.sort(emerging, function(a, b) return a.prob > b.prob end)
                local shown = {}
                for i = 1, math.min(5, #emerging) do
                    shown[#shown + 1] = emerging[i].l2
                end
                sendServerCommand(player, "TAZC", "SystemMessage", {
                    message = "  Emerging: " .. table.concat(shown, ", "),
                    color = {210, 190, 140},
                })
            end
        end

        -- Profile marker (test servers) and hint.
        if TAZC_Acquisition.activeProfile() ~= "live" then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "  [" .. TAZC_Acquisition.activeProfile() .. " profile]",
                color = {200, 200, 200},
            })
        end
        return
    end

    -- No arg: layered summary. Native languages first (with cultural-fluency
    -- note), learning languages below with progress.
    local nativeList = TAZC_Lang.getNativeLanguages(username)  -- includes "english"

    sendServerCommand(player, "TAZC", "SystemMessage", {
        message = "Languages:",
        color = {140, 200, 220},
    })

    -- Native section.
    if #nativeList == 1 then
        -- Only English -- common case for new players.
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "  Native: English",
            color = TAZC_Core.Colors.SOFT_PURPLE,
        })
    else
        local nativeDisplay = {}
        for _, lang in ipairs(nativeList) do
            table.insert(nativeDisplay, TAZC_Lang._describeLang(lang))
        end
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "  Native: " .. table.concat(nativeDisplay, ", "),
            color = TAZC_Core.Colors.SOFT_PURPLE,
        })
    end

    -- Learning section.
    local nativeSet = {}
    for _, lang in ipairs(nativeList) do nativeSet[lang] = true end

    local langs = TAZC_LangRegistry.listLanguages()
    local learningLines = {}
    for _, lang in ipairs(langs) do
        if lang ~= "english" and not nativeSet[lang] then
            local _, count, lexSize = listAcquiredForLang(username, lang)
            local displayLang = TAZC_Lang._describeLang(lang)
            if count > 0 or lexSize > 0 then
                table.insert(learningLines, string.format("  %s: %d / %d", displayLang, count, lexSize))
            end
        end
    end

    if #learningLines > 0 then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "  Learning:",
            color = {200, 200, 200},
        })
        for _, line in ipairs(learningLines) do
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = line,
                color = {200, 200, 200},
            })
        end
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Use /lex <language> for the full word list."
                .. (TAZC_Acquisition.activeProfile() ~= "live"
                    and "  [" .. TAZC_Acquisition.activeProfile() .. " profile]" or ""),
            color = {200, 200, 200},
        })
    end

    -- Teaching impact: how many words have YOU been firstVoice for?
    -- Only shown if the player has taught at least one word to someone.
    local taughtWords, taughtLearners = TAZC_Acquisition.teachingImpact(username)
    if taughtWords > 0 then
        local learnersNote = taughtLearners == 1
            and "1 person"
            or (taughtLearners .. " people")
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = string.format(
                "  You've been the first voice for %d word%s, for %s.",
                taughtWords, taughtWords == 1 and "" or "s", learnersNote),
            color = {210, 190, 140},
        })
    end
end

-- ============================================================================
-- /comp COMMAND
-- 
-- Estimate the player's comprehension percentage for one or all languages.
-- Computed from acquired count / dictionary size -- a rough proxy, not a true
-- fluency metric. Useful for the player to gauge progress.
-- 
-- Usage:
--   /comp            -> all non-English languages
--   /comp french     -> single language
-- ============================================================================

function TAZC_LangCommands.handleCompCommand(player, argString)
    if not player then return end
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local arg = argString and argString:match("^%s*(%S+)%s*$") or nil

    local function reportOne(lang)
        local palette = TAZC_LangRegistry.getPalette(lang)
        if not palette then return end
        -- estimateComprehension already returns 0-100 (integer percentage),
        -- not a 0-1 ratio. Don't multiply by 100 again.
        local pct = TAZC_Acquisition.estimateComprehension(username, lang, palette) or 0
        -- v8.16.1: surface the denominator. Expansion waves grow the
        -- dictionary, which mechanically lowers everyone's percentage --
        -- showing "of N words" lets the drop explain itself.
        local _, total = TAZC_Acquisition.acquiredCountForPalette(username, lang, palette)
        local displayLang = TAZC_Lang._describeLang(lang)
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = string.format("  %s: ~%d%% (of %d words)", displayLang, pct, total or 0),
            color = {200, 200, 200},
        })
    end

    if arg then
        local lang = arg:lower()
        if not TAZC_LangRegistry.isKnownLanguage(lang) then
            unknownLanguageMsg(player)
            return
        end
        if lang == "english" then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "English: 100% (baseline).",
                color = {140, 200, 220},
            })
            return
        end
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Estimated comprehension:",
            color = {140, 200, 220},
        })
        reportOne(lang)
        return
    end

    -- No arg: all non-English languages.
    sendServerCommand(player, "TAZC", "SystemMessage", {
        message = "Estimated comprehension:",
        color = {140, 200, 220},
    })
    local langs = TAZC_LangRegistry.listLanguages()
    local anyShown = false
    for _, lang in ipairs(langs) do
        if lang ~= "english" then
            reportOne(lang)
            anyShown = true
        end
    end
    if not anyShown then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "  (no non-English languages registered)",
            color = {200, 200, 200},
        })
    end
end

-- ============================================================================
-- /translate <text>
--
-- Player-facing test surface for TAZC_Translate. Detects whether the input is
-- English or Turkish via TAZC_Translate.detectLanguage, runs the appropriate
-- direction of translation, and displays the result to the speaker only.
-- Other players are NOT exposed to the engine's output by this command --
-- that ambient integration is deferred until coverage is higher.
--
-- This is a TEST SURFACE for the TAZC workshop branch.
-- Testers run it, compare engine output to their intent, and report.
--
-- Output format (system message visible only to the speaker):
--   * Detected direction: en->tr or tr->en
--   * Original input
--   * Engine output (or "engine could not translate" with reasons)
-- ============================================================================

function TAZC_LangCommands.handleTranslateCommand(player, argString)
    if not player then return end

    -- Master toggle: the player-facing translator is OFF until a server opts in
    -- via the TranslationEnabled sandbox var (default off). Development/testing
    -- access to translate and reverse happens via the offline harness directly,
    -- regardless of this flag.
    if not (TAZC_Config and TAZC_Config.Translation and TAZC_Config.Translation.enabled) then
        TAZC_Lang._sysMsg(player, "The translator is currently disabled on this server.")
        return
    end

    -- Trim and validate
    local text = argString and argString:match("^%s*(.-)%s*$") or ""
    if text == "" then
        TAZC_Lang._sysMsg(player, "/translate <text> -- translate English<->Turkish. " ..
            "Direction is auto-detected. Result is visible only to you.")
        return
    end

    local loaded, TAZC_Translate = pcall(require, "TAZC_Translate")
    if not loaded or not TAZC_Translate then
        -- Always-on: the same rule as every other pcall-guarded boundary
        -- (TAZC_Persist's corruption warnings, the WipeAll transport above) --
        -- a missing engine module is an operator-visible bug, never a quiet one.
        print(string.format(
            "[TAZC][ERROR] /translate: TAZC_Translate module unavailable: %s",
            tostring(TAZC_Translate)))
        sysMsgRed(player, "The translator isn't working right now -- let an admin know.")
        return
    end

    local r = TAZC_Translate.translateAuto(text)
    local detected = r.detected_language or "?"
    local arrow = (detected == "tr") and "tr->en" or "en->tr"

    if r.ok and r.output then
        local mainLine = string.format("[%s] %s", arrow, r.output)
        TAZC_Lang._sysMsg(player, mainLine, TAZC_Core.Colors.SOFT_PURPLE)
        TAZC_Lang._sysMsg(player, string.format("  (orig: %s)", text), {150, 150, 150})
        -- Partial translations show diagnostics so the tester knows which
        -- tokens leaked through as English. Dimmed so the gist (the
        -- translation itself) stays the primary signal.
        if r.partial and r.errors and #r.errors > 0 then
            for _, e in ipairs(r.errors) do
                TAZC_Lang._sysMsg(player, "  partial: " .. tostring(e), {180, 180, 180})
            end
        end
    else
        TAZC_Lang._sysMsg(player, string.format("[%s] engine could not translate.", arrow), {255, 180, 100})
        if r.errors and #r.errors > 0 then
            for _, e in ipairs(r.errors) do
                TAZC_Lang._sysMsg(player, "  " .. tostring(e), {180, 180, 180})
            end
        end
    end

    dbg("handleTranslateCommand: %s (%s) ok=%s%s",
        TAZC_Core.safe(function() return player:getUsername() end, "?"),
        arrow, tostring(r.ok), (r.partial and " partial" or ""))
end

return TAZC_LangCommands
