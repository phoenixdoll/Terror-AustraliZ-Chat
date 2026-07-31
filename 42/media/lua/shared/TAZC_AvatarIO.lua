--[[
================================================================================
    Terror AustraliZ Chat - Avatar IO (pure logic)

    Engine-free helpers for the speech-bubble portrait system: base64 codec
    (Kahlua-safe, pure arithmetic, no bitwise ops); rolling checksum (change
    detection only, NOT cryptographic); PNG validation without a parser
    (signature + IHDR read at fixed offsets, so the SERVER can enforce exact
    dimensions rather than trust the client); chunked split/join + reassembly
    (one PNG per sendClientCommand risks the packet budget; ~4 KB chunks
    don't); manifest diff (only changed avatars travel); key/filename hygiene
    (raw RP names never touch a file path). Deterministic; runs under the
    offline rig (devtools/tests_offline).

    Lineage: follows TICS (Total Immersive Chat System) by JohnGood (MIT) --
    re-engineered with server-side re-validation, chunked transfer, and A/B
    persistence. Thanks, John.

    Author: Kialae (Mongoose Server). License: MIT.
================================================================================
]]

local TAZC_Core = require("TAZC_Core")

-- Self-registers the debug flag so operators can toggle it without editing TAZC_Core.
if TAZC_Core.DEBUG_MODULES.AVATAR == nil then
    TAZC_Core.DEBUG_MODULES.AVATAR = true
end

local TAZC_AvatarIO = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- 60x80: TICS-ecosystem compatible, and scales exactly into the bubble's
-- 60px-high avatar slot (45x60 on screen, same 3:4 ratio).
TAZC_AvatarIO.WIDTH  = 60
TAZC_AvatarIO.HEIGHT = 80

-- A typical 60x80 PNG is 4-12 KB; 32 KB is generous headroom while still
-- capping what a hostile client can make the server hold/persist/broadcast.
TAZC_AvatarIO.MAX_BYTES = 32768

-- Smallest possible PNG that carries an IHDR: 8 signature + 4 length +
-- 4 "IHDR" + 13 data + 4 CRC.
TAZC_AvatarIO.MIN_BYTES = 33

-- Base64 characters per network chunk (~3 KB of image per chunk).
TAZC_AvatarIO.CHUNK_B64 = 4096

-- Derived ceiling: claiming more chunks than a max-size image needs is hostile or broken.
TAZC_AvatarIO.MAX_CHUNKS = math.ceil(
    (math.ceil(TAZC_AvatarIO.MAX_BYTES / 3) * 4) / TAZC_AvatarIO.CHUNK_B64)

-- ============================================================================
-- BASE64 (byte table <-> string)
-- Pure multiply/divide/mod arithmetic -- no bitwise ops (Kahlua target).
-- ============================================================================

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_ENC = {}  -- [0..63] -> char
local B64_DEC = {}  -- char -> 0..63
for i = 1, 64 do
    local c = B64_ALPHABET:sub(i, i)
    B64_ENC[i - 1] = c
    B64_DEC[c] = i - 1
end

--[[
    Encode a byte table (array of 0..255 numbers) as a base64 string.
    Returns nil, reason on malformed input.
]]
function TAZC_AvatarIO.b64encode(bytes)
    if type(bytes) ~= "table" then return nil, "not a byte table" end
    local function okByte(b)
        return type(b) == "number" and b >= 0 and b <= 255 and b == math.floor(b)
    end
    local out = {}
    local n = #bytes
    local i = 1
    while i <= n do
        local b1 = bytes[i]
        local b2 = bytes[i + 1]
        local b3 = bytes[i + 2]
        if not okByte(b1) or (b2 ~= nil and not okByte(b2))
            or (b3 ~= nil and not okByte(b3)) then
            return nil, "bad byte at " .. i
        end
        local v = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
        local c1 = math.floor(v / 262144)        -- v / 64^3
        local c2 = math.floor(v / 4096) % 64
        local c3 = math.floor(v / 64) % 64
        local c4 = v % 64
        if b3 ~= nil then
            out[#out + 1] = B64_ENC[c1] .. B64_ENC[c2] .. B64_ENC[c3] .. B64_ENC[c4]
        elseif b2 ~= nil then
            out[#out + 1] = B64_ENC[c1] .. B64_ENC[c2] .. B64_ENC[c3] .. "="
        else
            out[#out + 1] = B64_ENC[c1] .. B64_ENC[c2] .. "=="
        end
        i = i + 3
    end
    return table.concat(out)
end

--[[
    Decode base64 to a byte table. Strict: length % 4 == 0, '=' only as
    trailing padding, alphabet-only otherwise. Returns nil, reason on
    anything malformed -- callers treat nil as "corrupt, discard".
]]
function TAZC_AvatarIO.b64decode(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local n = #str
    if n % 4 ~= 0 then return nil, "bad length" end

    local bytes = {}
    local i = 1
    while i <= n do
        local q1 = str:sub(i, i)
        local q2 = str:sub(i + 1, i + 1)
        local q3 = str:sub(i + 2, i + 2)
        local q4 = str:sub(i + 3, i + 3)
        local d1, d2 = B64_DEC[q1], B64_DEC[q2]
        if not d1 or not d2 then return nil, "bad character" end

        local isLast = (i + 3 == n)
        if q3 == "=" then
            -- "xx==" -- one byte; must be the final quartet and q4 must pad too
            if not isLast or q4 ~= "=" then return nil, "bad padding" end
            local v = d1 * 262144 + d2 * 4096
            bytes[#bytes + 1] = math.floor(v / 65536)
        elseif q4 == "=" then
            -- "xxx=" -- two bytes; must be the final quartet
            if not isLast then return nil, "bad padding" end
            local d3 = B64_DEC[q3]
            if not d3 then return nil, "bad character" end
            local v = d1 * 262144 + d2 * 4096 + d3 * 64
            bytes[#bytes + 1] = math.floor(v / 65536)
            bytes[#bytes + 1] = math.floor(v / 256) % 256
        else
            local d3, d4 = B64_DEC[q3], B64_DEC[q4]
            if not d3 or not d4 then return nil, "bad character" end
            local v = d1 * 262144 + d2 * 4096 + d3 * 64 + d4
            bytes[#bytes + 1] = math.floor(v / 65536)
            bytes[#bytes + 1] = math.floor(v / 256) % 256
            bytes[#bytes + 1] = v % 256
        end
        i = i + 4
    end
    return bytes
end

-- ============================================================================
-- CHECKSUM
-- ============================================================================

--[[
    Rolling checksum over a byte table: sum = (sum * 31 + byte) % 2^31-1.
    Change detection only. Replaces the TICS CRC32 + bit32-emulation stack
    with something Kahlua-native and dependency-free.
]]
function TAZC_AvatarIO.checksum(bytes)
    if type(bytes) ~= "table" then return nil end
    local sum = 0
    for i = 1, #bytes do
        local b = bytes[i]
        if type(b) ~= "number" then return nil end
        sum = (sum * 31 + b) % 2147483647
    end
    return sum
end

-- ============================================================================
-- PNG VALIDATION (no parser)
-- ============================================================================

local PNG_SIGNATURE = { 137, 80, 78, 71, 13, 10, 26, 10 }
local IHDR_TAG      = { 73, 72, 68, 82 }   -- "IHDR" at bytes 13..16

--[[
    Read width/height from a PNG byte table.
    Layout: 8 signature bytes, 4 chunk-length bytes, "IHDR", then width
    (bytes 17-20) and height (bytes 21-24), both big-endian.
    @return width, height  or  nil, reason
]]
function TAZC_AvatarIO.pngDimensions(bytes)
    if type(bytes) ~= "table" or #bytes < TAZC_AvatarIO.MIN_BYTES then
        return nil, "too short to be a PNG"
    end
    for i = 1, 8 do
        if bytes[i] ~= PNG_SIGNATURE[i] then return nil, "not a PNG" end
    end
    for i = 1, 4 do
        if bytes[12 + i] ~= IHDR_TAG[i] then return nil, "missing IHDR" end
    end
    local w = ((bytes[17] * 256 + bytes[18]) * 256 + bytes[19]) * 256 + bytes[20]
    local h = ((bytes[21] * 256 + bytes[22]) * 256 + bytes[23]) * 256 + bytes[24]
    return w, h
end

--[[
    Full portrait validation: byte cap, PNG signature, exact dimensions.
    Used identically by the uploading client (instant feedback) and the
    server (authority -- never trust the client).
    @return true  or  false, reason (short, for dbg; the caller words the
            player-facing line)
]]
function TAZC_AvatarIO.validatePortrait(bytes)
    if type(bytes) ~= "table" then return false, "no data" end
    local n = #bytes
    if n < TAZC_AvatarIO.MIN_BYTES then return false, "too small" end
    if n > TAZC_AvatarIO.MAX_BYTES then return false, "too large" end
    local w, h = TAZC_AvatarIO.pngDimensions(bytes)
    if not w then return false, h end   -- h carries the reason
    if w ~= TAZC_AvatarIO.WIDTH or h ~= TAZC_AvatarIO.HEIGHT then
        return false, string.format("wrong dimensions (%dx%d)", w, h)
    end
    return true
end

-- ============================================================================
-- CHUNKING (network transfer)
-- ============================================================================

--[[
    Split a base64 string into CHUNK_B64-sized pieces.
    @return array of strings (at least one entry), or nil on bad input
]]
function TAZC_AvatarIO.splitB64(b64)
    if type(b64) ~= "string" or b64 == "" then return nil end
    local chunks = {}
    local pos = 1
    while pos <= #b64 do
        chunks[#chunks + 1] = b64:sub(pos, pos + TAZC_AvatarIO.CHUNK_B64 - 1)
        pos = pos + TAZC_AvatarIO.CHUNK_B64
    end
    return chunks
end

--[[
    Reassembly state for one incoming chunked transfer.
    `total` and `checksum` come from the first chunk seen; every later
    chunk must agree (the caller resets the assembly if they don't).
]]
function TAZC_AvatarIO.newAssembly(total, checksum)
    if type(total) ~= "number" or total ~= math.floor(total)
        or total < 1 or total > TAZC_AvatarIO.MAX_CHUNKS then
        return nil, "bad total"
    end
    if type(checksum) ~= "number" then return nil, "bad checksum" end
    return { total = total, checksum = checksum, parts = {}, received = 0 }
end

--[[
    Feed one chunk into an assembly.
    @return true on accept; false, reason on reject (duplicates and
            out-of-range sequence numbers are rejects, not errors)
]]
function TAZC_AvatarIO.addChunk(asm, seq, b64)
    if type(asm) ~= "table" or type(asm.total) ~= "number" then
        return false, "no assembly"
    end
    if type(seq) ~= "number" or seq ~= math.floor(seq)
        or seq < 1 or seq > asm.total then
        return false, "bad seq"
    end
    if type(b64) ~= "string" or b64 == "" or #b64 > TAZC_AvatarIO.CHUNK_B64 then
        return false, "bad chunk"
    end
    if asm.parts[seq] then
        return false, "duplicate"
    end
    asm.parts[seq] = b64
    asm.received = asm.received + 1
    return true
end

function TAZC_AvatarIO.assemblyComplete(asm)
    return type(asm) == "table" and type(asm.received) == "number"
        and type(asm.total) == "number" and asm.received >= asm.total
end

--[[
    Join a complete assembly back into one base64 string.
    @return string  or  nil, reason
]]
function TAZC_AvatarIO.joinAssembly(asm)
    if not TAZC_AvatarIO.assemblyComplete(asm) then return nil, "incomplete" end
    local parts = {}
    for i = 1, asm.total do
        if type(asm.parts[i]) ~= "string" then return nil, "missing chunk " .. i end
        parts[i] = asm.parts[i]
    end
    return table.concat(parts)
end

-- ============================================================================
-- MANIFEST DIFF
-- ============================================================================

--[[
    Compare what the server holds against what a client reports having.
    @param serverMap  {key -> checksum} authoritative
    @param clientMap  {key -> checksum} as reported (may be nil/partial)
    @return toSend  array of keys the client is missing or holds stale
    @return toDrop  array of keys the client holds that no longer exist
]]
function TAZC_AvatarIO.manifestDiff(serverMap, clientMap)
    serverMap = type(serverMap) == "table" and serverMap or {}
    clientMap = type(clientMap) == "table" and clientMap or {}
    local toSend, toDrop = {}, {}
    for key, sum in pairs(serverMap) do
        if clientMap[key] ~= sum then toSend[#toSend + 1] = key end
    end
    for key in pairs(clientMap) do
        if serverMap[key] == nil then toDrop[#toDrop + 1] = key end
    end
    return toSend, toDrop
end

--[[
    Reduce a raw client-reported manifest table into a clean {string key ->
    number checksum} map. Anything else in it is silently dropped -- a
    malformed manifest must never poison server state (the TICS bug #5
    lesson: their validator printed an error but FORGOT the return, and a
    nil manifest then blew up the distribution pump every 500 ms).
]]
function TAZC_AvatarIO.cleanManifest(raw)
    local clean = {}
    if type(raw) ~= "table" then return clean end
    for key, sum in pairs(raw) do
        if type(key) == "string" and key ~= "" and #key <= 160
            and type(sum) == "number" then
            clean[key] = sum
        end
    end
    return clean
end

-- ============================================================================
-- KEYS AND FILENAMES
-- ============================================================================

-- '|' is the key separator; strip it from parts so a crafted name can't fake another identity's key.
local function keyPart(s)
    return (tostring(s or "")):gsub("|", "/")
end

--[[
    Identity key for one character: username|forename|surname.
    Unambiguous (unlike underscore-joined names, where underscores in the
    parts collide) and never used as a file path.
]]
function TAZC_AvatarIO.makeKey(username, forename, surname)
    return keyPart(username) .. "|" .. keyPart(forename) .. "|" .. keyPart(surname)
end

--[[
    Filesystem-safe stem: ASCII [A-Za-z0-9_-] only, capped, never empty.
    RP names carry spaces, apostrophes, and escaped diacritics -- none of
    that may reach a file path.
]]
function TAZC_AvatarIO.sanitizeName(s)
    local clean = (tostring(s or "")):gsub("[^%w%-_]", "_"):sub(1, 32)
    if clean == "" then clean = "player" end
    return clean
end

--[[
    Cache filename for one avatar: sanitized username + checksum (+ pending
    marker). Embedding the checksum means new content gets a new name, so
    a stale engine texture cache can never show the old image under it.
]]
function TAZC_AvatarIO.cacheFileName(username, checksum, pending)
    return TAZC_AvatarIO.sanitizeName(username)
        .. "_" .. string.format("%d", tonumber(checksum) or 0)
        .. (pending and "_p" or "")
        .. ".png"
end

-- ============================================================================

return TAZC_AvatarIO
