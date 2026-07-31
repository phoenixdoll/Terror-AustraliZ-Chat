--[[
================================================================================
    Terror AustraliZ Chat -- Crash-Safe Persistence Layer (A/B generation slots)

    THE PROBLEM THIS SOLVES
    -----------------------
    PZ's Lua sandbox exposes getFileWriter/getFileReader but no rename and
    no delete, so a classic atomic write (write tmp, fsync, rename over the
    target) is impossible. Writing a save file in place means a crash
    mid-write truncates the ONLY copy; on the next boot the decode fails
    and the loader "starts empty" -- for the acquisition DB that is weeks
    of accumulated player vocabulary silently wiped.

    THE SCHEME
    ----------
    Two slot files per store: <name>_a.json and <name>_b.json. Writes
    alternate between them, each wrapped in an envelope carrying a
    monotonically increasing generation counter:

        { "mcPersist": 1, "gen": N, "savedAt": <epoch>, "data": <payload> }

    The loader reads both slots and returns the payload of the highest
    valid generation. A torn write can corrupt at most the slot being
    written; the other slot still holds the previous good generation, so
    the worst case is losing one flush interval -- the same exposure the
    dirty-flag design already accepts -- instead of everything.

    Each write is read back and byte-compared against what was intended
    (catches disk-full truncation and silent write failures). On verify
    failure the slot pointer does not advance, so the next flush retries
    over the same bad slot and the good slot is never touched.

    LEGACY MIGRATION
    ----------------
    Stores created before this layer used a single <legacyFile>. If
    neither slot exists, the loader falls back to it. The legacy file is
    never written again -- it survives intact as a pre-migration snapshot.

    CORRUPTION POLICY
    -----------------
    Corruption events print ALWAYS-ON console warnings (not dbg) -- a
    server operator must see them with DEBUG off. If BOTH slots are
    corrupt, writes are pinned to slot A for the rest of the session so
    slot B is preserved for post-mortem inspection (we cannot copy or
    rename it aside, so not overwriting it is the best forensics we get).

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Json = require("TAZC_Json")

local TAZC_Persist = {}

local dbg = TAZC_Core.debugger("PERSIST")

local ENVELOPE_MARK = 1  -- bump only if the envelope shape itself changes

local function warn(fmt, ...)
    -- Always-on, never in the happy path: corruption (bad slot data), IO
    -- failure (a read/write call erroring), or a caller-contract violation
    -- (save() before load(), a non-table payload, a throwing validate) --
    -- three categories, never boot/runtime log noise.
    print("[TAZC][PERSIST] WARNING: " .. string.format(fmt, ...))
end

-- ----------------------------------------------------------------------------
-- Raw file helpers (pcall-wrapped around the PZ file API)
-- ----------------------------------------------------------------------------

-- Read entire file as a string. Returns nil if absent/unreadable, "" if empty.
local function readAll(fileName)
    local ok, content = pcall(function()
        local reader = getFileReader(fileName, false)
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
    if not ok then
        warn("read of '%s' threw: %s", fileName, tostring(content))
        return nil
    end
    return content
end

-- Write a string to a file (truncating). Returns true on apparent success.
local function writeAll(fileName, content)
    local ok, err = TAZC_Core.safeExec(function()
        local writer = getFileWriter(fileName, true, false)
        if not writer then error("getFileWriter returned nil") end
        writer:write(content)
        writer:close()
    end)
    if not ok then
        warn("write of '%s' failed: %s", fileName, tostring(err))
        return false
    end
    return true
end

-- ----------------------------------------------------------------------------
-- Envelope handling
-- ----------------------------------------------------------------------------

-- Decode a slot's raw text into a validated envelope.
-- Returns envelope table on success; nil, reason on failure.
local function decodeEnvelope(raw, validate)
    if raw == nil or raw == "" then return nil, "empty" end
    local ok, parsed = pcall(TAZC_Json.decode, raw)
    if not ok then return nil, "decode error: " .. tostring(parsed) end
    if type(parsed) ~= "table" then return nil, "not a table" end
    if parsed.mcPersist ~= ENVELOPE_MARK then return nil, "missing/unknown envelope mark" end
    if type(parsed.gen) ~= "number" then return nil, "missing generation" end
    if type(parsed.data) ~= "table" then return nil, "missing data" end
    if validate then
        -- pcall'd: a throwing validate is treated the same as one that
        -- returns false, not left to crash the loader (see spec.validate's
        -- own contract note in TAZC_Persist.open below).
        local vOk, vResult = pcall(validate, parsed.data)
        if not vOk then return nil, "validate threw: " .. tostring(vResult) end
        if not vResult then return nil, "payload failed validation" end
    end
    return parsed
end

-- ----------------------------------------------------------------------------
-- Store object
-- ----------------------------------------------------------------------------

local Store = {}
Store.__index = Store

--[[
    TAZC_Persist.open(spec) -> store

    spec = {
        name       = "TAZC_Acquisitions",        -- REQUIRED. Slots become
                                               -- <name>_a.json / <name>_b.json
        legacyFile = "TAZC_Acquisitions.json",   -- optional pre-A/B single file,
                                               -- read-only migration fallback
        validate   = function(data) ... end,   -- optional payload sanity check
                                               -- (beyond "decodes to a table").
                                               -- May throw; decodeEnvelope
                                               -- pcall-guards the call and
                                               -- treats a throw the same as
                                               -- returning false.
    }
]]
function TAZC_Persist.open(spec)
    assert(type(spec) == "table" and type(spec.name) == "string" and spec.name ~= "",
        "TAZC_Persist.open: spec.name (string) is required")
    local self = setmetatable({}, Store)
    self.name      = spec.name
    self.slotFiles = { a = spec.name .. "_a.json", b = spec.name .. "_b.json" }
    self.legacy    = spec.legacyFile
    self.validate  = spec.validate
    self.lastGen   = 0        -- highest generation known good
    self.nextSlot  = "a"      -- slot the next save() targets
    self.pinned    = false    -- true => never alternate (forensic preservation)
    self.loaded    = false
    return self
end

--[[
    store:load() -> data|nil, source

    Reads both slots (and the legacy file if both slots are absent), returns
    the payload of the highest valid generation. `source` is one of:
        "a" | "b"           -- normal A/B load
        "legacy"            -- first boot after migration (slots not yet written)
        "legacy-recovery"   -- EITHER slot corrupt (corrupt.a or corrupt.b);
                            -- stale pre-migration snapshot recovered instead
                            -- of starting empty
        nil                 -- nothing loadable; caller starts empty

    Also positions the write cursor (generation counter + target slot) so a
    subsequent save() lands on the slot NOT holding the data just loaded.
]]
function Store:load()
    self.loaded = true

    local raw = {
        a = readAll(self.slotFiles.a),
        b = readAll(self.slotFiles.b),
    }
    local env, reason = {}, {}
    for slot, text in pairs(raw) do
        env[slot], reason[slot] = decodeEnvelope(text, self.validate)
    end

    -- Slot-corruption reporting: non-empty content that failed to decode is
    -- a real corruption event, not a fresh file.
    local corrupt = {}
    for _, slot in ipairs({ "a", "b" }) do
        if not env[slot] and raw[slot] ~= nil and raw[slot] ~= "" then
            corrupt[slot] = true
            warn("store '%s': slot %s ('%s') is unreadable (%s).",
                self.name, slot:upper(), self.slotFiles[slot], tostring(reason[slot]))
        end
    end

    -- Pick the winner.
    local winner = nil
    if env.a and env.b then
        -- Equal generations should not occur (writes alternate); prefer A
        -- deterministically if it somehow does.
        winner = (env.b.gen > env.a.gen) and "b" or "a"
        if env.a.gen == env.b.gen then
            dbg("store '%s': equal generations in both slots (%d); preferring A",
                self.name, env.a.gen)
        end
    elseif env.a then
        winner = "a"
    elseif env.b then
        winner = "b"
    end

    if winner then
        self.lastGen  = env[winner].gen
        self.nextSlot = (winner == "a") and "b" or "a"
        if corrupt.a or corrupt.b then
            warn("store '%s': recovered generation %d from slot %s; " ..
                 "the corrupt slot will be overwritten by the next save.",
                self.name, self.lastGen, winner:upper())
        end
        dbg("store '%s': loaded gen %d from slot %s", self.name, self.lastGen, winner:upper())
        return env[winner].data, winner
    end

    -- No valid slot. If both were corrupt, pin writes to A and preserve B.
    if corrupt.a and corrupt.b then
        self.pinned   = true
        self.nextSlot = "a"
        warn("store '%s': BOTH slots are corrupt. Writes are pinned to slot A " ..
             "for this session; slot B ('%s') is preserved for inspection. " ..
             "Check your backups before relying on newly accumulated data.",
            self.name, self.slotFiles.b)
    end

    -- Legacy fallback: pre-A/B single file. Two flavours:
    --   - clean first boot after upgrading (no slots at all)  -> "legacy"
    --   - disaster recovery (slots existed but both corrupt)  -> "legacy-recovery"
    if self.legacy then
        local legacyRaw = readAll(self.legacy)
        if legacyRaw ~= nil and legacyRaw ~= "" then
            local ok, parsed = pcall(TAZC_Json.decode, legacyRaw)
            if ok and type(parsed) == "table"
                  and (not self.validate or self.validate(parsed)) then
                local source = (corrupt.a or corrupt.b) and "legacy-recovery" or "legacy"
                if source == "legacy-recovery" then
                    warn("store '%s': falling back to legacy file '%s' -- this is a " ..
                         "PRE-MIGRATION snapshot and may be stale.",
                        self.name, self.legacy)
                else
                    dbg("store '%s': migrating from legacy file '%s' " ..
                        "(left intact as a pre-migration snapshot)", self.name, self.legacy)
                end
                -- lastGen stays as-is (0 on clean migration); first save writes
                -- the next generation into the A/B scheme.
                return parsed, source
            elseif corrupt.a or corrupt.b then
                warn("store '%s': legacy file '%s' is also unreadable; starting empty.",
                    self.name, self.legacy)
            end
        end
    end

    if corrupt.a or corrupt.b then
        warn("store '%s': no recoverable data found; starting empty.", self.name)
    else
        dbg("store '%s': no save data found; starting fresh", self.name)
    end
    return nil, nil
end

--[[
    store:save(data) -> ok

    Encodes `data` in a generation envelope, writes it to the current target
    slot, reads it back, and byte-compares. Only on a verified write does the
    generation advance and the target slot alternate. On any failure the
    cursor stays put: the next save retries the same slot and the other
    slot's last good generation remains untouched.
]]
function Store:save(data)
    if type(data) ~= "table" then
        warn("store '%s': save() called with %s; refusing.", self.name, type(data))
        return false
    end
    if not self.loaded then
        -- Saving before load() would start at gen 1 and could lose a higher
        -- generation already on disk to the verify-retry path. Refuse loudly:
        -- this is a programming error, not a runtime condition.
        warn("store '%s': save() before load(); refusing to risk on-disk data.", self.name)
        return false
    end

    local gen = self.lastGen + 1
    local okEncode, encoded = pcall(TAZC_Json.encode, {
        mcPersist = ENVELOPE_MARK,
        gen       = gen,
        savedAt   = os.time(),
        data      = data,
    })
    if not okEncode then
        warn("store '%s': encode failed: %s", self.name, tostring(encoded))
        return false
    end

    local target = self.slotFiles[self.nextSlot]
    if not writeAll(target, encoded) then
        return false  -- writeAll already warned; cursor unchanged => retry same slot
    end

    -- Read-back verification. readLine strips newline characters, and JSON
    -- string values escape \n as \\n, so TAZC_Json output round-trips exactly.
    local readBack = readAll(target)
    if readBack ~= encoded then
        warn("store '%s': read-back verify FAILED for slot %s ('%s') -- " ..
             "written %d chars, read %s. Slot pointer not advanced; " ..
             "the other slot still holds generation %d.",
            self.name, self.nextSlot:upper(), target, #encoded,
            readBack and ("%d chars"):format(#readBack) or "nothing",
            self.lastGen)
        return false
    end

    self.lastGen = gen
    if not self.pinned then
        self.nextSlot = (self.nextSlot == "a") and "b" or "a"
    end
    dbg("store '%s': wrote gen %d to '%s' (verified, %d chars)",
        self.name, gen, target, #encoded)
    return true
end

return TAZC_Persist
