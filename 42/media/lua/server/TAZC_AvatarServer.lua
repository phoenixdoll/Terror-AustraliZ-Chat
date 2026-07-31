--[[
================================================================================
    Terror AustraliZ Chat - Avatar Server (authoritative)

    Server side of the custom speech-bubble portrait system. Owns:
      - upload intake (chunked RequestPut) with full re-validation -- byte
        cap, PNG signature, EXACT 60x80 dimensions, checksum match. The
        client validates too, but only for instant feedback; the truth
        lives here. Never trust the client.
      - the approval queue: uploads land as "pending"; an admin/moderator
        approves or rejects. BOTH ops re-check getAccessLevel() SERVER-side
        (the reference implementation this design studied gated approval in
        client UI only -- any client could forge a self-approval packet).
      - persistence: ONE TAZC_Persist A/B store ("TAZC_Avatars"), avatars kept
        as base64 inside the JSON payload. No loose binary files server-side,
        no ModData, crash-safe by construction.
      - distribution: event-driven, not a polling pump. Clients report what
        they hold (Manifest) on join; the server diffs and queues only what
        changed. Approval/rejection push deltas to everyone online. A small
        FIFO drained a few commands per tick keeps chunk bursts gentle.

    Network module name: "TAZCAvatar" -- own OnClientCommand
    listener; TAZC_Server's dispatch is untouched (it early-returns on any
    other module name, so the two coexist cleanly).

    Wire commands (client -> server):
      Manifest   { avatars = {key->checksum}, pending = {key->checksum} }
      RequestPut { seq, total, b64, checksum, forename, surname }
      Approve    { key, checksum }        (admin/moderator only)
      Reject     { key, checksum }        (admin/moderator only)
      Remove     { }                      (clears the sender's own portraits)

    (server -> client, module "TAZCAvatar"):
      AvatarPut  { key, checksum, seq, total, b64, pending,
                   username, forename, surname }
      AvatarGone { key, pending }
    Player feedback rides the existing "TAZC" SystemMessage command.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_AvatarIO = require("TAZC_AvatarIO")
local TAZC_Persist = require("TAZC_Persist")

local dbg = TAZC_Core.debugger("AVATAR")

local TAZC_AvatarServer = {}

-- ============================================================================
-- TUNING
-- ============================================================================

local UPLOAD_COOLDOWN_MS   = 30 * 1000  -- min gap between completed uploads
local MANIFEST_COOLDOWN_MS = 10 * 1000  -- min gap between manifest diffs
local ASSEMBLY_STALE_MS    = 120 * 1000 -- abandon a half-received upload
local DRAIN_PER_TICK       = 4          -- outbound commands per tick
local QUEUE_CAP            = 4000       -- hard bound on the outbound FIFO
local NAME_MAX             = 50         -- forename/surname length cap

-- ============================================================================
-- PERSISTENCE
-- One A/B store. Payload shape:
--   { approved = { key -> {b64, checksum, username, forename, surname,
--                          approvedBy, approvedAt} },
--     pending  = { key -> {b64, checksum, username, forename, surname,
--                          requestedAt} } }
-- Mutations are rare (uploads/approvals), so save immediately on change,
-- same policy as the bio store.
-- ============================================================================

-- BEHAVIOR NOTE: forename/surname are now type-checked here like every
-- other field. A persisted record whose forename or surname is missing or
-- not a string now fails validation -- the whole generation is rejected on
-- load (TAZC_Persist falls back to the other slot, or to "start empty" if
-- both are bad; see TAZC_Persist's corruption policy). Under normal
-- operation this never fires: RequestPut always writes both as strings
-- (cleanName(...) or ""). It only bites pre-existing/hand-edited data
-- that predates this check or was tampered with -- exactly the kind of
-- persisted garbage b64/checksum/username were already guarding against.
local function validRecordMap(m)
    if m == nil then return true end
    if type(m) ~= "table" then return false end
    for key, rec in pairs(m) do
        if type(key) ~= "string" or type(rec) ~= "table"
            or type(rec.b64) ~= "string" or type(rec.checksum) ~= "number"
            or type(rec.username) ~= "string"
            or type(rec.forename) ~= "string" or type(rec.surname) ~= "string" then
            return false
        end
    end
    return true
end

local store = TAZC_Persist.open({
    name     = "TAZC_Avatars",
    validate = function(d)
        return type(d) == "table"
            and validRecordMap(d.approved) and validRecordMap(d.pending)
    end,
})

local DB = { approved = {}, pending = {} }
local loaded = false

local function ensureLoaded()
    if loaded then return end
    loaded = true
    local data = store:load()
    if data then
        DB.approved = type(data.approved) == "table" and data.approved or {}
        DB.pending  = type(data.pending) == "table" and data.pending or {}
    end
    dbg("store loaded: %d approved, %d pending",
        TAZC_Core.tableSize(DB.approved), TAZC_Core.tableSize(DB.pending))
end

local function saveDB()
    if not store:save({ approved = DB.approved, pending = DB.pending }) then
        dbg("store save failed (see PERSIST warnings)")
        return false
    end
    return true
end

-- ============================================================================
-- SESSION STATE (not persisted)
-- ============================================================================

local uploads = {}        -- [username] = {asm, forename, surname, startedAt}
local uploadCooldown = {} -- [username] = ms timestamp of last completed upload
local manifestLast = {}   -- [username] = ms timestamp of last manifest diff

-- Outbound FIFO with explicit head/tail cursors. Never use '#' on it:
-- drained slots are nil'd, and '#' is undefined on arrays with holes.
local sendQueue = {}
local queueHead = 1
local queueTail = 0

-- ============================================================================
-- SESSION-STATE PRUNING
-- The three tables above are keyed by username and never naturally shrink
-- -- an entry is only ever overwritten by that SAME username's next
-- request, never removed. Over server uptime, with renamed/retired/one-
-- and-done usernames, they grow without bound.
--
-- Each entry stops mattering the moment its own window elapses -- the only
-- reads are age checks (`now - stamp < COOLDOWN`, or the equivalent stale-
-- assembly check already in RequestPut). Once that window has passed, the
-- entry can never again gate anything, so a coarse periodic sweep that
-- drops entries past their own window changes nothing observable: it just
-- reclaims the memory sooner than "wait for that username's next request"
-- (which, for a username that never returns, is never).
-- ============================================================================

local SESSION_PRUNE_INTERVAL_MS = 5 * 60 * 1000  -- how often the sweep runs
local lastPruneAt = 0

local function pruneSessionState(now)
    for username, up in pairs(uploads) do
        if (now - up.startedAt) > ASSEMBLY_STALE_MS then
            uploads[username] = nil
        end
    end
    for username, stamp in pairs(uploadCooldown) do
        if (now - stamp) >= UPLOAD_COOLDOWN_MS then
            uploadCooldown[username] = nil
        end
    end
    for username, stamp in pairs(manifestLast) do
        if (now - stamp) >= MANIFEST_COOLDOWN_MS then
            manifestLast[username] = nil
        end
    end
end

-- ============================================================================
-- SMALL HELPERS
-- ============================================================================

local function nowMs()
    return TAZC_Core.safe(TAZC_Core.getTimeMs, 0)
end

local function getUsername(player)
    return TAZC_Core.safe(function() return player:getUsername() end, nil)
end

-- Server-side authority gate. Exact access-level strings on a B42 dedicated
-- server are a live-verify item; lower-cased compare keeps us safe across
-- the B41 "Admin"/"Moderator" vs B42 casing question.
local function isModerator(player)
    local accessLevel = TAZC_Core.safe(function() return player:getAccessLevel() end, "none")
    accessLevel = tostring(accessLevel or "none"):lower()
    return accessLevel == "admin" or accessLevel == "moderator"
end

-- Clean a client-supplied display-name field (control chars stripped,
-- length capped). Empty is allowed -- descriptors can have blank surnames.
local function cleanName(val)
    if type(val) ~= "string" then return nil end
    val = val:gsub("[%c]", "")
    return val:sub(1, NAME_MAX)
end

-- Warm player feedback via the existing Terror AustraliZ Chat SystemMessage pipe.
local function tellPlayer(player, message, color)
    if not player then return end
    TAZC_Core.safe(function()
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = message, color = color or {200, 200, 200},
        })
    end, nil)
end

local function forEachOnlinePlayer(fn)
    local players = TAZC_Core.safe(function() return getOnlinePlayers() end, nil)
    if not players then return end
    local count = TAZC_Core.safe(function() return players:size() end, 0)
    for i = 0, count - 1 do
        local p = TAZC_Core.safe(function() return players:get(i) end, nil)
        if p then fn(p) end
    end
end

local function findOnlinePlayer(username)
    local found = nil
    forEachOnlinePlayer(function(p)
        if not found and getUsername(p) == username then found = p end
    end)
    return found
end

-- ============================================================================
-- OUTBOUND QUEUE
-- Chunked sends are queued and drained a few per tick so a join-time sync
-- of a dozen avatars never bursts dozens of ~4 KB commands in one frame.
-- ============================================================================

local function queueLen()
    return queueTail - queueHead + 1
end

local function queueSend(player, command, args)
    if queueLen() >= QUEUE_CAP then
        dbg("send queue full (%d); dropping %s", queueLen(), tostring(command))
        return
    end
    queueTail = queueTail + 1
    sendQueue[queueTail] = { player = player, command = command, args = args }
end

local function drainQueue(maxCommands)
    local n = maxCommands or DRAIN_PER_TICK
    while n > 0 and queueHead <= queueTail do
        local item = sendQueue[queueHead]
        sendQueue[queueHead] = nil
        queueHead = queueHead + 1
        -- pcall'd: the target may have disconnected since queueing.
        local ok, err = pcall(function()
            sendServerCommand(item.player, "TAZCAvatar", item.command, item.args)
        end)
        if not ok then
            dbg("queued send failed (player gone?): %s", tostring(err))
        end
        n = n - 1
    end
    if queueHead > queueTail then
        -- Fully drained: reset the cursors so they don't grow without bound.
        sendQueue = {}
        queueHead = 1
        queueTail = 0
    end
end

-- Queue one avatar record to one player as AvatarPut chunks.
local function queueAvatarTo(player, key, rec, pending)
    local chunks = TAZC_AvatarIO.splitB64(rec.b64)
    if not chunks then
        dbg("queueAvatarTo: record for '%s' has no payload", key)
        return
    end
    for seq = 1, #chunks do
        queueSend(player, "AvatarPut", {
            key = key, checksum = rec.checksum,
            seq = seq, total = #chunks, b64 = chunks[seq],
            pending = pending and true or false,
            username = rec.username, forename = rec.forename, surname = rec.surname,
        })
    end
end

local function queueGoneTo(player, key, pending)
    queueSend(player, "AvatarGone", { key = key, pending = pending and true or false })
end

-- ============================================================================
-- COMMAND HANDLERS
-- ============================================================================

local ServerCommands = {}

--[[
    Manifest: the client reports every avatar it has cached (approved and
    pending maps of key->checksum). Diff against the store and queue only
    what changed; tell it to drop what no longer exists. Pending records
    travel only to moderators and to their own owner -- that server-side
    filter is the real privacy gate on unapproved images.
]]
ServerCommands.Manifest = function(player, args)
    local username = getUsername(player)
    if not username then return end
    if type(args) ~= "table" then
        dbg("Manifest: malformed args from %s; ignoring", username)
        return
    end

    -- Cooldown: a manifest triggers a full diff and possibly a large queue
    -- of sends; a client spamming empty manifests must not amplify.
    local now = nowMs()
    if manifestLast[username] and (now - manifestLast[username]) < MANIFEST_COOLDOWN_MS then
        dbg("Manifest: cooldown for %s", username)
        return
    end
    manifestLast[username] = now

    local clientApproved = TAZC_AvatarIO.cleanManifest(args.avatars)
    local clientPending  = TAZC_AvatarIO.cleanManifest(args.pending)
    local mod = isModerator(player)

    -- Approved avatars: everyone gets them.
    local approvedSums = {}
    for key, rec in pairs(DB.approved) do approvedSums[key] = rec.checksum end
    local toSend, toDrop = TAZC_AvatarIO.manifestDiff(approvedSums, clientApproved)
    for _, key in ipairs(toSend) do
        queueAvatarTo(player, key, DB.approved[key], false)
    end
    for _, key in ipairs(toDrop) do
        queueGoneTo(player, key, false)
    end

    -- Pending avatars: only what this player is entitled to see.
    local pendingSums = {}
    for key, rec in pairs(DB.pending) do
        if mod or rec.username == username then
            pendingSums[key] = rec.checksum
        end
    end
    local pToSend, pToDrop = TAZC_AvatarIO.manifestDiff(pendingSums, clientPending)
    for _, key in ipairs(pToSend) do
        queueAvatarTo(player, key, DB.pending[key], true)
    end
    for _, key in ipairs(pToDrop) do
        queueGoneTo(player, key, true)
    end

    dbg("Manifest from %s (mod=%s): +%d approved, -%d, +%d pending, -%d",
        username, tostring(mod), #toSend, #toDrop, #pToSend, #pToDrop)
end

--[[
    RequestPut: one chunk of an upload. Reassembled per-player with strict
    caps; on completion the payload is decoded and fully re-validated, then
    stored as pending and pushed to the moderators (and echoed to the owner
    so they can see their own portrait while it waits).
]]
ServerCommands.RequestPut = function(player, args)
    local username = getUsername(player)
    if not username then return end
    if type(args) ~= "table" then
        dbg("RequestPut: malformed args from %s", username)
        return
    end

    -- Field validation before anything touches state.
    local seq, total = args.seq, args.total
    local b64, checksum = args.b64, args.checksum
    if type(seq) ~= "number" or type(total) ~= "number"
        or type(b64) ~= "string" or type(checksum) ~= "number" then
        dbg("RequestPut: bad field types from %s", username)
        return
    end
    local forename = cleanName(args.forename) or ""
    local surname  = cleanName(args.surname) or ""

    local now = nowMs()
    if uploadCooldown[username] and (now - uploadCooldown[username]) < UPLOAD_COOLDOWN_MS then
        -- Warm-word only the first chunk of an attempt; the rest go quietly.
        if seq == 1 then
            tellPlayer(player, "One portrait at a time -- give the last one a moment to settle.")
        end
        return
    end

    -- Reassembly buffer: one per player. A mismatched checksum/total means
    -- a new attempt (or a broken client) -- start over. Stale buffers are
    -- abandoned rather than trusted.
    local up = uploads[username]
    if up and (now - up.startedAt) > ASSEMBLY_STALE_MS then up = nil end
    if up and (up.asm.checksum ~= checksum or up.asm.total ~= total) then up = nil end
    if not up then
        local asm, reason = TAZC_AvatarIO.newAssembly(total, checksum)
        if not asm then
            dbg("RequestPut: rejected assembly from %s (%s)", username, tostring(reason))
            tellPlayer(player, "That portrait didn't survive the trip -- try sending it again.")
            return
        end
        up = { asm = asm, forename = forename, surname = surname, startedAt = now }
        uploads[username] = up
    end

    local ok, reason = TAZC_AvatarIO.addChunk(up.asm, seq, b64)
    if not ok then
        dbg("RequestPut: chunk rejected from %s (%s)", username, tostring(reason))
        return
    end
    if not TAZC_AvatarIO.assemblyComplete(up.asm) then return end

    -- Complete: decode and re-validate everything. The client already
    -- checked, but the client is not the authority.
    uploads[username] = nil
    local fullB64 = TAZC_AvatarIO.joinAssembly(up.asm)
    local bytes = fullB64 and TAZC_AvatarIO.b64decode(fullB64) or nil
    if not bytes then
        dbg("RequestPut: undecodable payload from %s", username)
        tellPlayer(player, "That portrait didn't survive the trip -- try sending it again.")
        return
    end
    if TAZC_AvatarIO.checksum(bytes) ~= checksum then
        dbg("RequestPut: checksum mismatch from %s", username)
        tellPlayer(player, "That portrait didn't survive the trip -- try sending it again.")
        return
    end
    local valid, why = TAZC_AvatarIO.validatePortrait(bytes)
    if not valid then
        dbg("RequestPut: invalid portrait from %s (%s)", username, tostring(why))
        tellPlayer(player, "That portrait doesn't quite fit the frame -- it needs to be a 60 by 80 PNG, and not too heavy.")
        return
    end

    local key = TAZC_AvatarIO.makeKey(username, up.forename, up.surname)

    -- Idempotence: identical resubmits are answered, not re-queued.
    if DB.approved[key] and DB.approved[key].checksum == checksum then
        tellPlayer(player, "That portrait already hangs where you speak.")
        return
    end
    if DB.pending[key] and DB.pending[key].checksum == checksum then
        tellPlayer(player, "That portrait is already waiting for a look-over.")
        return
    end

    -- One pending slot per key: a new upload replaces the old request.
    DB.pending[key] = {
        b64 = fullB64, checksum = checksum,
        username = username, forename = up.forename, surname = up.surname,
        requestedAt = os.time(),
    }
    saveDB()
    uploadCooldown[username] = now

    -- Push the pending image to every online moderator, and echo it to the
    -- owner (they alone see their own unapproved portrait in their bubble).
    forEachOnlinePlayer(function(p)
        local pName = getUsername(p)
        if isModerator(p) or pName == username then
            queueAvatarTo(p, key, DB.pending[key], true)
        end
    end)

    tellPlayer(player, "Your portrait is on its way. Someone will look it over soon.", {140, 200, 220})
    dbg("RequestPut: pending '%s' stored (%d bytes, checksum %d)", key, #bytes, checksum)
end

-- Shared plumbing for Approve/Reject: authority gate + stale-request guard.
-- Returns key, rec on success; nil after telling the sender why.
local function takePendingForModeration(player, args, verb)
    if not isModerator(player) then
        -- SERVER-side gate -- the client hides these buttons from
        -- non-moderators, but that check is UX only.
        dbg("%s: refused for non-moderator %s", verb, tostring(getUsername(player)))
        tellPlayer(player, "Portrait review is for moderators.", {255, 100, 100})
        return nil
    end
    if type(args) ~= "table" or type(args.key) ~= "string"
        or type(args.checksum) ~= "number" then
        dbg("%s: malformed args", verb)
        return nil
    end
    local rec = DB.pending[args.key]
    if not rec or rec.checksum ~= args.checksum then
        -- Stale click: someone else already processed it, or a new upload
        -- replaced the one on screen.
        tellPlayer(player, "That portrait isn't in the queue any more.")
        return nil
    end
    return args.key, rec
end

ServerCommands.Approve = function(player, args)
    local key, rec = takePendingForModeration(player, args, "Approve")
    if not key then return end

    DB.pending[key] = nil
    DB.approved[key] = {
        b64 = rec.b64, checksum = rec.checksum,
        username = rec.username, forename = rec.forename, surname = rec.surname,
        approvedBy = getUsername(player) or "?",
        approvedAt = os.time(),
    }
    saveDB()

    -- Everyone: drop any pending copy they hold, then take the approved one.
    -- FIFO order per player guarantees the Gone lands before the Put.
    forEachOnlinePlayer(function(p)
        queueGoneTo(p, key, true)
        queueAvatarTo(p, key, DB.approved[key], false)
    end)

    local owner = findOnlinePlayer(rec.username)
    if owner then
        tellPlayer(owner, "Your portrait now hangs where you speak.", {140, 220, 140})
    end
    tellPlayer(player, "Approved -- the portrait is up.", {140, 220, 140})
    dbg("Approve: '%s' approved by %s", key, tostring(getUsername(player)))
end

ServerCommands.Reject = function(player, args)
    local key, rec = takePendingForModeration(player, args, "Reject")
    if not key then return end

    DB.pending[key] = nil
    saveDB()

    forEachOnlinePlayer(function(p)
        queueGoneTo(p, key, true)
    end)

    local owner = findOnlinePlayer(rec.username)
    if owner then
        tellPlayer(owner, "Your portrait came back from its look-over -- perhaps another would suit better.")
    end
    tellPlayer(player, "Sent back.", {200, 200, 200})
    dbg("Reject: '%s' rejected by %s", key, tostring(getUsername(player)))
end

--[[
    Remove: a player takes down their own portraits (every key belonging to
    their username -- old characters' portraits included). No moderation
    gate: it's their own image.
]]
ServerCommands.Remove = function(player, args)
    local username = getUsername(player)
    if not username then return end

    local removed = {}
    for key, rec in pairs(DB.approved) do
        if rec.username == username then removed[#removed + 1] = { key = key, pending = false } end
    end
    for key, rec in pairs(DB.pending) do
        if rec.username == username then removed[#removed + 1] = { key = key, pending = true } end
    end
    if #removed == 0 then
        tellPlayer(player, "There's no portrait of yours to take down.")
        return
    end

    for _, entry in ipairs(removed) do
        if entry.pending then DB.pending[entry.key] = nil
        else DB.approved[entry.key] = nil end
    end
    saveDB()

    forEachOnlinePlayer(function(p)
        for _, entry in ipairs(removed) do
            queueGoneTo(p, entry.key, entry.pending)
        end
    end)

    tellPlayer(player, "Your portrait has been taken down.")
    dbg("Remove: %d record(s) removed for %s", #removed, username)
end

-- ============================================================================
-- EVENT HOOKS
-- ============================================================================

local function OnClientCommand(module, command, player, args)
    if module ~= "TAZCAvatar" then return end
    if not player then return end
    ensureLoaded()

    dbg("OnClientCommand: %s from %s", tostring(command),
        tostring(getUsername(player)))

    local handler = ServerCommands[command]
    if handler then
        local ok, err = pcall(handler, player, args)
        if not ok then
            print(string.format(
                "[TAZC][ERROR] client command '%s' failed: %s",
                tostring(command), tostring(err)))
        end
    else
        dbg("OnClientCommand: unknown command: %s", tostring(command))
    end

    -- Opportunistic pump: guarantees queue progress even if the server's
    -- OnTick cadence misbehaves (B42 live-verify item) -- any incoming
    -- avatar traffic keeps the outbound side moving.
    drainQueue(DRAIN_PER_TICK)
end

local function OnTick()
    local now = nowMs()
    if now - lastPruneAt >= SESSION_PRUNE_INTERVAL_MS then
        lastPruneAt = now
        pruneSessionState(now)
    end
    if queueHead > queueTail then return end   -- nothing queued: zero work
    drainQueue(DRAIN_PER_TICK)
end

local function OnServerStarted()
    ensureLoaded()
end

Events.OnClientCommand.Add(OnClientCommand)
Events.OnTick.Add(OnTick)
Events.OnServerStarted.Add(OnServerStarted)

-- Internal contract: exposed for the offline harness (dispatch-guard tests).
TAZC_AvatarServer._ServerCommands = ServerCommands

-- ============================================================================
-- /lang resetall WIPE EXTENSION
-- The portrait store holds per-player data, so it joins the /lang resetall
-- total wipe (see TAZC_Lang.registerWipeExtension for the contract; the bio
-- and hue registrations in TAZC_Server are its siblings). inventory feeds the
-- preview; clear sweeps every record under the username -- approved and
-- pending, old characters' keys included -- persists, and pushes the same
-- AvatarGone the Remove command sends, so online clients drop the image
-- right away. The require is pcall-guarded: if TAZC_Lang isn't loadable here
-- (load order), portraits simply stay out of resetall's reach -- a dbg
-- line, never an error.
-- ============================================================================

local okLang, TAZC_Lang = pcall(require, "TAZC_Lang")
if okLang and type(TAZC_Lang) == "table"
    and type(TAZC_Lang.registerWipeExtension) == "function" then
    TAZC_Lang.registerWipeExtension("avatars", {
        label = "Chat portrait",
        inventory = function(username)
            ensureLoaded()
            local approved, pending = false, false
            for _, rec in pairs(DB.approved) do
                if rec.username == username then approved = true end
            end
            for _, rec in pairs(DB.pending) do
                if rec.username == username then pending = true end
            end
            if approved and pending then
                return "an approved portrait, plus one awaiting review"
            elseif approved then
                return "an approved portrait"
            elseif pending then
                return "a portrait awaiting review"
            end
            return nil
        end,
        clear = function(username)
            ensureLoaded()
            -- Same sweep as the Remove command: every key under the
            -- username, approved and pending alike.
            local removed = {}
            for key, rec in pairs(DB.approved) do
                if rec.username == username then
                    removed[#removed + 1] = { key = key, pending = false }
                end
            end
            for key, rec in pairs(DB.pending) do
                if rec.username == username then
                    removed[#removed + 1] = { key = key, pending = true }
                end
            end
            if #removed == 0 then return false end
            for _, entry in ipairs(removed) do
                if entry.pending then DB.pending[entry.key] = nil
                else DB.approved[entry.key] = nil end
            end
            saveDB()
            forEachOnlinePlayer(function(p)
                for _, entry in ipairs(removed) do
                    queueGoneTo(p, entry.key, entry.pending)
                end
            end)
            dbg("wipe extension: %d portrait record(s) removed for %s",
                #removed, username)
            return true
        end,
    })
else
    dbg("TAZC_Lang.registerWipeExtension unavailable; portraits stay out of /lang resetall's reach")
end

-- ============================================================================
-- OFFLINE-RIG SURFACE
-- The listeners above register into the void under devtools/tests_offline
-- (pz_stubs Events are no-ops), so the rig drives the module through these.
-- They are the same functions the events call -- no test-only logic.
-- ============================================================================

TAZC_AvatarServer.handleClientCommand = OnClientCommand
TAZC_AvatarServer.drainQueue = drainQueue

-- Shallow snapshot for assertions: key -> checksum maps + queue depth.
function TAZC_AvatarServer.snapshot()
    ensureLoaded()
    local approved, pending = {}, {}
    for key, rec in pairs(DB.approved) do approved[key] = rec.checksum end
    for key, rec in pairs(DB.pending) do pending[key] = rec.checksum end
    return { approved = approved, pending = pending, queued = queueLen() }
end

-- Internal contract: exposed for the offline harness (session-state pruning
-- tests) -- table sizes only. Pruning is otherwise invisible through any
-- public API: every entry it removes had already stopped mattering to any
-- real caller, so there's no player-facing surface to observe "did the
-- sweep actually reclaim it" other than peeking at the table directly.
function TAZC_AvatarServer._sessionStateSizes()
    return {
        uploads = TAZC_Core.tableSize(uploads),
        uploadCooldown = TAZC_Core.tableSize(uploadCooldown),
        manifestLast = TAZC_Core.tableSize(manifestLast),
    }
end

dbg("=== TAZC_AvatarServer module loaded ===")

return TAZC_AvatarServer
