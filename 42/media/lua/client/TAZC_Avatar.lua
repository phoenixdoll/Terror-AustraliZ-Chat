--[[
================================================================================
    Terror AustraliZ Chat - Avatar Client Manager

    Client side of the custom speech-bubble portrait system: cache, network,
    textures, and the context-menu entry points. The window UI lives in
    TAZC_AvatarWindow; the pure logic in TAZC_AvatarIO; the authority in
    TAZC_AvatarServer.

    HOW A PORTRAIT GETS IN (there is no file picker in PZ Lua):
    the player drops a 60x80 PNG into a request folder this module
    pre-creates under Zomboid/Lua --
        TAZC/avatars/<server>/request/avatar.png
    -- then right-clicks their own character -> "Choose Chat Avatar...".
    (Context-menu registration follows TAZC_Bio's OnFillWorldObjectContextMenu
    pattern; a /avatar command may follow in a later pass.)

    RECEIVING: approved portraits arrive as chunked AvatarPut commands,
    are byte-written as PNGs under TAZC/avatars/<server>/ and loaded
    with getTextureFromSaveDir. A small JSON manifest remembers what we hold
    so the join-time Manifest handshake only pulls what changed. The
    manifest is a disposable cache -- deliberately NOT A/B (corruption just
    means "start empty and re-sync"); TAZC_Persist's crash-safety is reserved
    for the server's irreplaceable store.

    ANONYMITY LAW (headline mechanic): this module only stores and serves
    textures. The render gate lives in TAZC_Bubble -- a masked or distant
    speaker never shows a custom portrait, because a portrait fingerprints
    a player harder than a name. Unapproved (pending) portraits are served
    only for the local player's own key.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Json = require("TAZC_Json")
local TAZC_AvatarIO = require("TAZC_AvatarIO")
local TAZC_Bio = require("TAZC_Bio")

local dbg = TAZC_Core.debugger("AVATAR")

local TAZC_Avatar = {}

-- ============================================================================
-- SMALL SAFETY HELPERS -- nil-is-failure contract; see TAZC_Core.safeGet/
-- safeExec for why that differs from TAZC_Core.safe. Kept under this file's
-- own names since every call site here already uses them.
-- ============================================================================

local safeGet = TAZC_Core.safeGet
local function safeExec(fn)
    local ok, err = TAZC_Core.safeExec(fn)
    if not ok then dbg("safeExec failed: %s", tostring(err)) end
    return ok
end

-- ============================================================================
-- STATE
-- ============================================================================

local state = {
    loaded = false,
    serverKey = nil,          -- sanitized per-server cache folder name
    approved = {},            -- [key] = {file, checksum, username, forename, surname}
    pending = {},             -- [key] = same shape (own + moderator copies)
    inbox = {},               -- [key] = reassembly for incoming AvatarPut
    textures = {},            -- [file] = Texture (render cache)
    requestDirMade = false,
    lastSubmitChecksum = nil, -- client-side duplicate-send guard (time-limited)
    lastSubmitAtMs = 0,       -- when that guard was armed
}

local MANIFEST_VERSION = 1

-- How long one Send suppresses an identical resend. Long enough to absorb
-- double-clicks and the chunk burst; short enough that an upload the server
-- silently dropped (its post-upload cooldown, transit corruption) can be
-- sent again without a relog. Genuine duplicates that slip through after
-- expiry are absorbed by the server's own idempotence checks.
local SUBMIT_GUARD_MS = 45 * 1000

local function submitGuardActive(checksum)
    if state.lastSubmitChecksum == nil then return false end
    if state.lastSubmitChecksum ~= checksum then return false end
    return (TAZC_Core.getTimeMs() - state.lastSubmitAtMs) < SUBMIT_GUARD_MS
end

-- ============================================================================
-- PATHS
-- All paths are relative to Zomboid/Lua (that is what the PZ file API and
-- getTextureFromSaveDir(path, '../Lua') both key on).
-- ============================================================================

local function getServerKey()
    if state.serverKey then return state.serverKey end
    -- B41/B42: getServerIP() on a client -- live-verify; fall back to a
    -- shared "default" folder if absent (SP, or API drift).
    local ip = TAZC_Core.safe(function() return getServerIP() end, nil)
    state.serverKey = TAZC_AvatarIO.sanitizeName(ip or "default")
    return state.serverKey
end

local function baseDir()
    return "TAZC/avatars/" .. getServerKey()
end

local function manifestPath()
    return baseDir() .. "/manifest.json"
end

function TAZC_Avatar.getRequestDir()
    return baseDir() .. "/request"
end

-- Human-readable absolute-ish path for the upload window's instructions.
function TAZC_Avatar.getRequestDirDisplay()
    return "Zomboid/Lua/" .. TAZC_Avatar.getRequestDir() .. "/"
end

-- ============================================================================
-- FILE IO
-- Binary byte IO (getFileInput/getFileOutput) is a B41/B42 divergence risk:
-- the rest of the mod only uses the text reader/writer (TAZC_Persist). Every
-- call is pcall-guarded; if the API is absent the feature degrades to the
-- 3D-model fallback instead of erroring. See the smoke-test list.
-- ============================================================================

--[[
    Read a whole file as a byte table, capped at maxBytes+1 (one over the
    cap is enough to know it's oversized -- never slurp megabytes of a
    hostile file into RAM).
    @return bytes|nil, overflowed
]]
local function readBytesFile(relPath, maxBytes)
    local fileIn = TAZC_Core.safe(function() return getFileInput(relPath) end, nil)
    if not fileIn then return nil, false end

    local bytes = {}
    local overflow = false

    -- Preferred: a clean bounded loop via the Java stream's available()
    -- (reflective call -- B42 live-verify). Only trusted when positive: a
    -- spurious 0 from some stream impls must not misreport a real file as
    -- missing, so 0/nil falls through to the EOF loop.
    local avail = TAZC_Core.safe(function() return fileIn:available() end, nil)
    if type(avail) == "number" and avail > 0 then
        local limit = avail
        if limit > maxBytes then
            limit = maxBytes + 1
            overflow = true
        end
        pcall(function()
            for _ = 1, limit do
                bytes[#bytes + 1] = fileIn:readUnsignedByte()
            end
        end)
    else
        -- EOF loop: readUnsignedByte at end-of-file either returns nil
        -- (Kahlua swallows the Java EOFException) or throws -- the pcall
        -- treats either as end-of-data. B41/B42 semantics: live-verify.
        pcall(function()
            while true do
                local b = fileIn:readUnsignedByte()
                if type(b) ~= "number" then break end
                bytes[#bytes + 1] = b
                if #bytes > maxBytes then
                    overflow = true
                    break
                end
            end
        end)
    end

    TAZC_Core.safe(function() endFileInput() end, nil)
    if #bytes == 0 then return nil, false end
    return bytes, overflow
end

-- Write a byte table as a file. Returns true on apparent success.
local function writeBytesFile(relPath, bytes)
    local out = TAZC_Core.safe(function() return getFileOutput(relPath) end, nil)
    if not out then
        dbg("writeBytesFile: getFileOutput('%s') unavailable", relPath)
        return false
    end
    local ok = pcall(function()
        for i = 1, #bytes do
            out:writeByte(bytes[i])
        end
    end)
    TAZC_Core.safe(function() endFileOutput() end, nil)
    if not ok then dbg("writeBytesFile: write failed for '%s'", relPath) end
    return ok
end

-- PZ Lua has no file delete; truncating to zero bytes is the closest thing
-- (a zero-byte PNG can never load as a texture, so it is inert).
local function truncateFile(relPath)
    TAZC_Core.safe(function()
        getFileOutput(relPath)
        endFileOutput()
    end, nil)
end

-- Text-file helpers for the manifest (same pcall shape as TAZC_Persist's).
local function readTextFile(relPath)
    local ok, content = pcall(function()
        local reader = getFileReader(relPath, false)
        if not reader then return nil end
        local parts = {}
        local line = reader:readLine()
        while line ~= nil do
            parts[#parts + 1] = line
            line = reader:readLine()
        end
        reader:close()
        return table.concat(parts, "\n")
    end)
    if not ok then return nil end
    return content
end

local function writeTextFile(relPath, content)
    return safeExec(function()
        local writer = getFileWriter(relPath, true, false)
        if not writer then error("getFileWriter returned nil") end
        writer:write(content)
        writer:close()
    end)
end

-- ============================================================================
-- MANIFEST (disposable local cache index)
-- ============================================================================

local function sanitizeEntryMap(raw)
    local clean = {}
    if type(raw) ~= "table" then return clean end
    for key, e in pairs(raw) do
        if type(key) == "string" and type(e) == "table"
            and type(e.file) == "string" and type(e.checksum) == "number"
            and type(e.username) == "string" then
            clean[key] = {
                file = e.file, checksum = e.checksum,
                username = e.username,
                forename = type(e.forename) == "string" and e.forename or "",
                surname = type(e.surname) == "string" and e.surname or "",
            }
        end
    end
    return clean
end

local function saveManifest()
    local ok, encoded = pcall(TAZC_Json.encode, {
        mcAvatarManifest = MANIFEST_VERSION,
        approved = state.approved,
        pending = state.pending,
    })
    if not ok or not encoded then
        dbg("saveManifest: encode failed")
        return
    end
    if not writeTextFile(manifestPath(), encoded) then
        dbg("saveManifest: write failed (cache only; will re-sync)")
    end
end

local function ensureLoaded()
    if state.loaded then return end
    state.loaded = true
    local raw = readTextFile(manifestPath())
    if raw and raw ~= "" then
        local parsed = TAZC_Json.decode(raw)
        if type(parsed) == "table" and parsed.mcAvatarManifest == MANIFEST_VERSION then
            state.approved = sanitizeEntryMap(parsed.approved)
            state.pending = sanitizeEntryMap(parsed.pending)
        else
            dbg("ensureLoaded: manifest unreadable; starting empty (self-healing)")
        end
    end
    dbg("ensureLoaded: %d approved, %d pending cached",
        TAZC_Core.tableSize(state.approved), TAZC_Core.tableSize(state.pending))
end

-- ============================================================================
-- LOCAL PLAYER IDENTITY
-- ============================================================================

local function getLocalUsername()
    local player = getPlayer()
    if not player then return nil end
    return safeGet(function() return player:getUsername() end, nil)
end

-- Extract (username, forename, surname) from a player object; the same
-- descriptor fields the uploader sends, so keys match on both ends.
local function identityOf(player)
    if not player then return nil end
    local username = safeGet(function() return player:getUsername() end, nil)
    if not username then return nil end
    local forename, surname = "", ""
    pcall(function()
        local desc = player:getDescriptor()
        if desc then
            forename = desc:getForename() or ""
            surname = desc:getSurname() or ""
        end
    end)
    return username, forename, surname
end

function TAZC_Avatar.getOwnKey()
    local username, forename, surname = identityOf(getPlayer())
    if not username then return nil end
    return TAZC_AvatarIO.makeKey(username, forename, surname)
end

-- ============================================================================
-- TEXTURES
-- ============================================================================

local function loadTexture(file)
    if state.textures[file] then return state.textures[file] end
    -- Architecturally parked, not just unverified: getTextureFromSaveDir
    -- only ever reads from Zomboid/Saves/... (rejects '..'), but this
    -- file's own writers (getFileOutput/getFileWriter, see baseDir() below)
    -- root at Zomboid/Lua/... and reject '..' too -- no bridge, no
    -- bytes-to-texture API either way. That needs a TIS Java-side change;
    -- nothing in Lua can fix it. See docs/ARCHITECTURE.md's Engine-wall
    -- note for the full case.
    local tex = TAZC_Core.safe(function()
        return getTextureFromSaveDir(baseDir() .. "/" .. file, "../Lua")
    end, nil)
    if tex then state.textures[file] = tex end
    return tex
end

-- Bust the render + engine caches for a file whose content changed.
local function forgetTexture(file)
    local tex = state.textures[file]
    state.textures[file] = nil
    if tex then
        -- B41/B42: Texture.reload(name) busts the engine texture cache when
        -- a file changes under the same name -- live-verify.
        TAZC_Core.safe(function() Texture.reload(tex:getName()) end, nil)
    end
end

--[[
    PUBLIC: texture for a speaker, or nil. This is what TAZC_Bubble calls.
    Approved portraits show for everyone; a pending portrait shows only
    when it belongs to the local player (their own preview). Entries whose
    file no longer loads are pruned (self-healing cache).
]]
function TAZC_Avatar.getTextureFor(username, forename, surname)
    ensureLoaded()
    if not username then return nil end
    local key = TAZC_AvatarIO.makeKey(username, forename or "", surname or "")

    local entry = nil
    local fromPending = false
    local pendingEntry = state.pending[key]
    if pendingEntry and username == getLocalUsername() then
        entry = pendingEntry       -- own preview outranks the approved copy
        fromPending = true
    else
        entry = state.approved[key]
    end
    if not entry then return nil end

    local tex = loadTexture(entry.file)
    if not tex then
        dbg("getTextureFor: '%s' failed to load; pruning cache entry", entry.file)
        if fromPending then state.pending[key] = nil
        else state.approved[key] = nil end
        saveManifest()
        return nil
    end
    return tex
end

--[[
    PUBLIC: convenience wrapper for TAZC_Bubble -- pulls the speaker's
    identity off the player object itself. Never errors; nil means
    "no portrait, use the 3D model".
]]
function TAZC_Avatar.getTextureForPlayer(player)
    local username, forename, surname = identityOf(player)
    if not username then return nil end
    return TAZC_Avatar.getTextureFor(username, forename, surname)
end

-- Window-only accessor: a pending texture regardless of ownership, for the
-- moderation queue. NEVER call this from bubble/nameplate render paths --
-- the ownership gate in getTextureFor is part of the approval mechanic.
function TAZC_Avatar.getPendingTexture(key)
    ensureLoaded()
    local entry = state.pending[key]
    if not entry then return nil end
    return loadTexture(entry.file)
end

-- Pending queue for the moderation window (no image bytes, just metadata).
function TAZC_Avatar.getPendingList()
    ensureLoaded()
    local list = {}
    for key, e in pairs(state.pending) do
        list[#list + 1] = {
            key = key, checksum = e.checksum,
            username = e.username, forename = e.forename, surname = e.surname,
        }
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

-- Own-portrait status for the upload window.
function TAZC_Avatar.getOwnStatus()
    ensureLoaded()
    local key = TAZC_Avatar.getOwnKey()
    if not key then return nil end
    return {
        key = key,
        approved = state.approved[key],
        pending = state.pending[key],
    }
end

-- ============================================================================
-- INCOMING (server -> client)
-- ============================================================================

local function onAvatarPut(args)
    if type(args) ~= "table" then return end
    local key = args.key
    if type(key) ~= "string" or key == "" or #key > 160 then return end
    if type(args.checksum) ~= "number" or type(args.seq) ~= "number"
        or type(args.total) ~= "number" or type(args.b64) ~= "string" then
        dbg("AvatarPut: malformed packet dropped")
        return
    end
    local username = type(args.username) == "string" and args.username or ""
    if username == "" then return end
    local pending = args.pending == true

    -- Reassemble. A mismatched total/checksum on the same key means a new
    -- transfer superseded this one -- start over.
    local inboxKey = key .. (pending and "|P" or "|A")
    local asm = state.inbox[inboxKey]
    if asm and (asm.checksum ~= args.checksum or asm.total ~= args.total) then
        asm = nil
    end
    if not asm then
        local newAsm, reason = TAZC_AvatarIO.newAssembly(args.total, args.checksum)
        if not newAsm then
            dbg("AvatarPut: bad assembly for '%s' (%s)", key, tostring(reason))
            return
        end
        asm = newAsm
        state.inbox[inboxKey] = asm
    end
    local ok, reason = TAZC_AvatarIO.addChunk(asm, args.seq, args.b64)
    if not ok then
        dbg("AvatarPut: chunk rejected for '%s' (%s)", key, tostring(reason))
        return
    end
    if not TAZC_AvatarIO.assemblyComplete(asm) then return end
    state.inbox[inboxKey] = nil

    -- Decode + verify + validate. The server already validated, but a
    -- corrupt avatar must degrade to the 3D model silently, never error.
    local b64 = TAZC_AvatarIO.joinAssembly(asm)
    local bytes = b64 and TAZC_AvatarIO.b64decode(b64) or nil
    if not bytes or TAZC_AvatarIO.checksum(bytes) ~= args.checksum then
        dbg("AvatarPut: corrupt payload for '%s'; dropped", key)
        return
    end
    local valid, why = TAZC_AvatarIO.validatePortrait(bytes)
    if not valid then
        dbg("AvatarPut: invalid portrait for '%s' (%s); dropped", key, tostring(why))
        return
    end

    -- Byte-write the PNG (checksum-named: new content = new file name).
    local file = TAZC_AvatarIO.cacheFileName(username, args.checksum, pending)
    if not writeBytesFile(baseDir() .. "/" .. file, bytes) then
        dbg("AvatarPut: could not write '%s'; portrait dropped", file)
        return
    end

    local map = pending and state.pending or state.approved
    local old = map[key]
    if old and old.file ~= file then
        -- Superseded image: retire the old file so litter stays zero-byte.
        forgetTexture(old.file)
        truncateFile(baseDir() .. "/" .. old.file)
    end
    map[key] = {
        file = file, checksum = args.checksum,
        username = username,
        forename = type(args.forename) == "string" and args.forename or "",
        surname = type(args.surname) == "string" and args.surname or "",
    }
    forgetTexture(file)
    saveManifest()
    dbg("AvatarPut: stored %s portrait for '%s' (%d bytes)",
        pending and "pending" or "approved", key, #bytes)
end

local function onAvatarGone(args)
    if type(args) ~= "table" or type(args.key) ~= "string" then return end
    local map = (args.pending == true) and state.pending or state.approved
    local entry = map[args.key]
    if not entry then return end
    map[args.key] = nil
    forgetTexture(entry.file)
    truncateFile(baseDir() .. "/" .. entry.file)
    saveManifest()
    -- If our own pending portrait came back (rejected), re-arm the submit
    -- guard so the player can send the same file again after a chat with
    -- the moderators.
    if args.pending == true and entry.username == getLocalUsername()
        and state.lastSubmitChecksum == entry.checksum then
        state.lastSubmitChecksum = nil
    end
    dbg("AvatarGone: dropped %s portrait for '%s'",
        args.pending and "pending" or "approved", args.key)
end

local function onServerCommand(module, command, args)
    if module ~= "TAZCAvatar" then return end
    ensureLoaded()
    if command == "AvatarPut" then
        onAvatarPut(args)
    elseif command == "AvatarGone" then
        onAvatarGone(args)
    else
        dbg("onServerCommand: unknown command: %s", tostring(command))
    end
end

-- ============================================================================
-- OUTGOING (client -> server)
-- ============================================================================

local function sendManifest()
    if not isClient() then return end
    ensureLoaded()
    local approvedSums, pendingSums = {}, {}
    for key, e in pairs(state.approved) do approvedSums[key] = e.checksum end
    for key, e in pairs(state.pending) do pendingSums[key] = e.checksum end
    safeExec(function()
        sendClientCommand("TAZCAvatar", "Manifest", {
            avatars = approvedSums, pending = pendingSums,
        })
    end)
    dbg("sendManifest: reported %d approved, %d pending",
        TAZC_Core.tableSize(approvedSums), TAZC_Core.tableSize(pendingSums))
end

--[[
    PUBLIC (window): submit validated portrait bytes to the server.
    @return true if the chunks went out, false with the window showing why.
]]
function TAZC_Avatar.submitBytes(bytes, checksum)
    if not isClient() then return false end
    if type(bytes) ~= "table" or type(checksum) ~= "number" then return false end
    if submitGuardActive(checksum) then
        dbg("submitBytes: identical resubmit suppressed")
        return true   -- already on its way; don't double-send
    end

    local b64 = TAZC_AvatarIO.b64encode(bytes)
    if not b64 then return false end
    local chunks = TAZC_AvatarIO.splitB64(b64)
    if not chunks or #chunks > TAZC_AvatarIO.MAX_CHUNKS then return false end

    local player = getPlayer()
    local _, forename, surname = identityOf(player)
    if not player then return false end

    -- A max-size portrait is ~11 chunks of ~4 KB. Sent back-to-back; the
    -- practical burst ceiling is a live-verify item (typical portraits are
    -- 2-4 chunks).
    for seq = 1, #chunks do
        local ok = safeExec(function()
            sendClientCommand("TAZCAvatar", "RequestPut", {
                seq = seq, total = #chunks, b64 = chunks[seq],
                checksum = checksum,
                forename = forename, surname = surname,
            })
        end)
        if not ok then return false end
    end
    state.lastSubmitChecksum = checksum
    state.lastSubmitAtMs = TAZC_Core.getTimeMs()
    dbg("submitBytes: sent %d chunk(s), checksum %d", #chunks, checksum)
    return true
end

-- PUBLIC (window): is this exact image already on its way to the server?
-- Time-limited on purpose: past the guard window we'd rather resend than
-- strand a player whose upload the server quietly dropped.
function TAZC_Avatar.isSubmitInFlight(checksum)
    return submitGuardActive(checksum)
end

-- PUBLIC (window): ask the server to take down every portrait of ours.
function TAZC_Avatar.requestRemove()
    if not isClient() then return end
    state.lastSubmitChecksum = nil
    safeExec(function()
        sendClientCommand("TAZCAvatar", "Remove", {})
    end)
end

-- PUBLIC (window): moderation verdicts. The server re-checks authority.
function TAZC_Avatar.sendApprove(key, checksum)
    if not isClient() then return end
    safeExec(function()
        sendClientCommand("TAZCAvatar", "Approve", { key = key, checksum = checksum })
    end)
end

function TAZC_Avatar.sendReject(key, checksum)
    if not isClient() then return end
    safeExec(function()
        sendClientCommand("TAZCAvatar", "Reject", { key = key, checksum = checksum })
    end)
end

-- ============================================================================
-- REQUEST FOLDER (upload intake)
-- ============================================================================

--[[
    Force-create the request directory. The PZ Lua API has no mkdir; writing
    a file creates the intermediate directories as a side effect (the
    junk-file trick -- B42 live-verify), so we leave a friendly note there.
]]
function TAZC_Avatar.ensureRequestDir()
    if state.requestDirMade then return end
    state.requestDirMade = true
    local notePath = TAZC_Avatar.getRequestDir() .. "/leave_your_portrait_here.txt"
    TAZC_Core.safe(function()
        local out = getFileOutput(notePath)
        if out then
            -- Plain ASCII note for whoever browses the folder.
            local msg = "Drop a 60x80 PNG named avatar.png in this folder, " ..
                "then right-click your character in game -> Choose Chat Avatar."
            for i = 1, #msg do
                out:writeByte(msg:byte(i))
            end
        end
        endFileOutput()
    end, nil)
    dbg("ensureRequestDir: %s", TAZC_Avatar.getRequestDir())
end

--[[
    PUBLIC (window): probe the request folder for a dropped portrait.
    Probes avatar.png first, then <username>.png as a courtesy.
    @return { bytes, checksum, file, valid, reason } or nil if nothing found
]]
function TAZC_Avatar.probeRequestFile()
    TAZC_Avatar.ensureRequestDir()
    local names = { "avatar.png" }
    local username = getLocalUsername()
    if username then
        names[#names + 1] = TAZC_AvatarIO.sanitizeName(username) .. ".png"
    end

    for _, name in ipairs(names) do
        local relPath = TAZC_Avatar.getRequestDir() .. "/" .. name
        local bytes, overflow = readBytesFile(relPath, TAZC_AvatarIO.MAX_BYTES)
        if bytes then
            local result = { file = name, bytes = bytes }
            if overflow then
                result.valid = false
                result.reason = "too large"
            else
                local valid, why = TAZC_AvatarIO.validatePortrait(bytes)
                result.valid = valid and true or false
                result.reason = why
                if valid then
                    result.checksum = TAZC_AvatarIO.checksum(bytes)
                end
            end
            return result
        end
    end
    return nil
end

-- ============================================================================
-- CONTEXT MENU
-- Registration mirrors TAZC_Bio.onContextMenu (OnFillWorldObjectContextMenu,
-- resolve the clicked IsoPlayer via square -> movingObjects). Entries only
-- appear when the player right-clicks their OWN character, so world clicks
-- stay uncluttered. The moderation entry's access check here is UX only;
-- the server re-verifies every verdict.
-- ============================================================================

local function isPngAvatarModeOn()
    local mode = TAZC_Config.liveSandbox("BubbleAvatarMode", "model")
    if type(mode) == "number" then return mode == 2 end
    return mode == "png"
end

local function onChooseAvatar()
    -- Lazy require, pcall-guarded: TAZC_AvatarWindow requires this module at
    -- its top, so a top-level require here would be a cycle. By click time
    -- the window module is long since loaded and cached.
    safeExec(function()
        local TAZC_AvatarWindow = require("TAZC_AvatarWindow")
        TAZC_AvatarWindow.openUpload()
    end)
end

local function onReviewAvatars()
    safeExec(function()
        local TAZC_AvatarWindow = require("TAZC_AvatarWindow")
        TAZC_AvatarWindow.openReview()
    end)
end

local findClickedPlayer = TAZC_Bio._findClickedPlayer

local function onContextMenu(playerIndex, context, worldObjects, test)
    if test then return true end
    if not isClient() then return end
    if not isPngAvatarModeOn() then return end

    local selfPlayer = safeGet(function() return getSpecificPlayer(playerIndex) end, nil)
    if not selfPlayer then return end

    local clickedPlayer = findClickedPlayer(worldObjects)
    if not clickedPlayer or clickedPlayer ~= selfPlayer then return end

    safeExec(function()
        context:addOption("Choose Chat Avatar...", nil, onChooseAvatar)
    end)

    -- Moderation queue entry (UX-only gate; server is authoritative).
    local accessLevel = safeGet(function() return selfPlayer:getAccessLevel() end, "None")
    accessLevel = tostring(accessLevel or "None"):lower()
    if accessLevel == "admin" or accessLevel == "moderator" then
        safeExec(function()
            context:addOption("Review Chat Avatars...", nil, onReviewAvatars)
        end)
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function OnGameStart()
    if not isClient() then return end
    ensureLoaded()
    TAZC_Avatar.ensureRequestDir()
    sendManifest()
end

local function OnConnected()
    if not isClient() then return end
    -- Reconnect-in-session: re-run the handshake (server tolerates
    -- duplicates via its manifest cooldown).
    sendManifest()
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

safeExec(function() Events.OnServerCommand.Add(onServerCommand) end)
safeExec(function() Events.OnFillWorldObjectContextMenu.Add(onContextMenu) end)
safeExec(function() Events.OnGameStart.Add(OnGameStart) end)
safeExec(function() Events.OnConnected.Add(OnConnected) end)

dbg("=== TAZC_Avatar module loaded ===")

return TAZC_Avatar
