--[[
================================================================================
    Terror AustraliZ Chat - Server Handler
    
    Server-side message processing. Receives chat messages from clients,
    calculates proximity, routes to players in range, handles radio
    transmission with weather-based signal degradation.
    
    RESPONSIBILITIES:
    - Proximity calculation for all chat channels
    - Radio receiver discovery and message routing
    - Weather interference calculation
    - Zombie attraction sound generation
    - Message logging
    - Slash-command dispatch (/lang, /lex, /comp, /forget, /hue, /translate)
    - /tell target resolution
    - Bio/tagline storage
    - Description (character sheet) storage
    - Personal notes storage
    - Name color (/hue) storage
    - Admin language grant/revoke (GrantLanguage/RevokeLanguage)
    - Boredom reduction (ReduceBoredom)
    - Fresh-character detection (carried-over language state on a new body)

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local TAZC_Config = require("TAZC_Config")
local TAZC_Radio = require("TAZC_Radio")
local TAZC_Sanitize = require("TAZC_Sanitize")
local TAZC_Lang = require("TAZC_Lang")
local TAZC_LangCommands = require("TAZC_LangCommands")
local TAZC_LangRegistry = require("TAZC_LangRegistry")
local TAZC_Acquisition = require("TAZC_Acquisition")
local TAZC_Persist = require("TAZC_Persist")
local TAZC_Bridge = require("TAZC_Bridge")

local dbg = TAZC_Core.debugger("SERVER")

local TAZC_Server = {}

-- ============================================================================
-- LANGUAGE IDENTIFICATION CACHE
-- A listener who has never acquired a word in a language doesn't know what
-- language they're hearing -- they see babble with no [Turkish] tag. Once
-- any word crosses the acquisition threshold, they've identified the
-- language and the tag appears for the rest of the session. Cache avoids
-- scanning the token table on every message; reset on server restart
-- (after restart, identification requires at least one currently-acquired
-- word). Natives always identify (they know their own language by
-- definition). Design note: identification is permanent -- even if a
-- player later forgets all their words, they still recognise the language
-- when they hear it, the same way a human who has forgotten their high-
-- school French still knows French when they hear it.
-- ============================================================================
local identifiedLangs = {}   -- [username] = { [lang] = true }

local function hasIdentifiedLanguage(username, lang)
    if not username or not lang then return false end
    local userCache = identifiedLangs[username]
    if userCache and userCache[lang] then return true end
    if TAZC_Acquisition.hasAcquiredAny(username, lang) then
        if not identifiedLangs[username] then
            identifiedLangs[username] = {}
        end
        identifiedLangs[username][lang] = true
        return true
    end
    return false
end

-- ============================================================================
-- ARG VALIDATION HELPERS
-- Malicious/broken clients can send anything in the args table. All reads
-- from args.* should be type-validated before use (C15 hardening in 0.8.0).
-- ============================================================================

-- Returns a clean string from an args field, or nil if not a non-empty string.
-- Strips control characters to prevent log/UI injection.
local function validString(val, maxLen)
    if type(val) ~= "string" then return nil end
    if val == "" then return nil end
    -- Strip control chars (newlines, tabs, etc.) -- taglines and usernames
    -- never legitimately contain them, and they corrupt log lines.
    val = val:gsub("[%c]", "")
    if maxLen and #val > maxLen then
        val = val:sub(1, maxLen)
    end
    if val == "" then return nil end
    return val
end

-- ============================================================================
-- PER-PLAYER STORE FACTORY
-- Bio, Description, Notes, and Hue below each open an TAZC_Persist A/B store,
-- keep an in-memory cache, save/load through the same disk idiom, and join
-- the /lang resetall wipe. makeStore() carries that shared shape. What
-- genuinely differs per store -- Notes' two-level [viewer][target] keys,
-- each store's own load-time value validation, and the wipe-extension
-- inventory/clear + broadcast (push vs. none) -- stays out of the factory,
-- as spec fields or as code written per store below.
--
-- spec = {
--     persistName = "TAZC_Taglines",   -- required; TAZC_Persist.open's name
--     legacyFile  = SAVE_FILE,       -- optional pre-A/B migration fallback
--     field       = "taglines",      -- key inside the persisted {field=...} table
--     label       = "Bio",           -- feeds dbg lines ("<label> storage: ...")
--     cleanEntry  = function(raw) ... end,
--         -- Validates/cleans ONE raw persisted value for a flat
--         -- [username] -> value store; return nil to drop a corrupt entry.
--         -- Ignored when loadFromDisk is supplied.
--     loadFromDisk = function(store) ... end,
--         -- OPTIONAL full override, for a store whose key shape isn't flat
--         -- (Notes' two-level notes[viewer][target]).
-- }
-- returns { store = <TAZC_Persist store>, db = { [field] = {} }, saveToDisk = fn }
local function makeStore(spec)
    local store = TAZC_Persist.open({
        name       = spec.persistName,
        legacyFile = spec.legacyFile,
        validate   = function(d)
            return type(d) == "table"
                and (d[spec.field] == nil or type(d[spec.field]) == "table")
        end,
    })

    local db = { [spec.field] = {} }

    local function saveToDisk()
        -- store:save() is internally pcall-wrapped, read-back verified, and
        -- warns loudly on failure.
        if not store:save({ [spec.field] = db[spec.field] }) then
            dbg("%s storage: save failed (see PERSIST warnings)", spec.label)
            return false
        end
        dbg("%s storage: saved %d to disk", spec.label, TAZC_Core.tableSize(db[spec.field]))
        return true
    end

    local function defaultLoadFromDisk()
        local data, source = store:load()
        if not data or type(data[spec.field]) ~= "table" then
            dbg("%s storage: no save data found, starting fresh", spec.label)
            return {}
        end
        -- Sanitize on the way in: a corrupt or hand-edited file should not
        -- poison the runtime cache.
        local clean = {}
        for key, raw in pairs(data[spec.field]) do
            if type(key) == "string" then
                local v = spec.cleanEntry(raw)
                if v ~= nil then clean[key] = v end
            end
        end
        dbg("%s storage: loaded %d from disk (source: %s)",
            spec.label, TAZC_Core.tableSize(clean), tostring(source))
        return clean
    end

    local loadFromDisk = spec.loadFromDisk or defaultLoadFromDisk

    Events.OnServerStarted.Add(function()
        db[spec.field] = loadFromDisk(store)
        dbg("%s storage: initialized with %d", spec.label, TAZC_Core.tableSize(db[spec.field]))
    end)

    return { store = store, db = db, saveToDisk = saveToDisk }
end

-- Shared cleanEntry for the two flat string stores (bio/description): the
-- persisted value must be a string, or the entry is dropped.
local function cleanStringEntry(v)
    if type(v) == "string" then return v end
    return nil
end

-- Broadcast the SAME args to every online player -- the shape the bio/
-- description save+clear paths and the notes wipe below all need after a
-- store change lands, so every client's cache stays in sync.
local function broadcastToAll(command, args)
    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then return end
    for i = 0, onlinePlayers:size() - 1 do
        sendServerCommand(onlinePlayers:get(i), "TAZC", command, args)
    end
end

-- ============================================================================
-- BIO/TAGLINE STORAGE
-- Uses direct file I/O for B42 persistence (nuclear option). Global ModData
-- and player:getModData() are both unreliable in B42 MP. We write JSON
-- directly to Zomboid/Lua/TAZC/TAZC_Taglines_{a,b}.json (see
-- TAZC_Persist.lua for the crash-safety rationale).
-- ============================================================================

local BIO_MAX_LENGTH = 80
local SAVE_FILE = "TAZC_Taglines.json"  -- legacy pre-A/B single file (read-only)

-- The legacy single file is the migration fallback and is never written
-- again. It was written by a hand-rolled encoder, but its output is valid
-- JSON ({"taglines":{...}}), so TAZC_Persist's TAZC_Json-based legacy path
-- decodes it directly. The hand-rolled codec (added in 0.7.9.5, pre-TAZC_Json)
-- is retired with this change.
local TAZC_BioDB, saveTaglinesToDisk
do
    local s = makeStore({
        persistName = "TAZC_Taglines",
        legacyFile  = SAVE_FILE,
        field       = "taglines",
        label       = "Bio",
        cleanEntry  = cleanStringEntry,
    })
    TAZC_BioDB = s.db
    saveTaglinesToDisk = s.saveToDisk
end

-- The tagline store holds per-player data, so it joins the /lang resetall
-- total wipe (see TAZC_Lang.registerWipeExtension for the contract; the hue
-- registration below is its sibling). inventory feeds the preview a short
-- quote of the line; clear wipes, persists, and sends the same BioUpdate
-- broadcast BioSave sends on an ordinary change, so every online client's
-- cached copy empties out right away.
TAZC_Lang.registerWipeExtension("bio", {
    label = "Bio tagline",
    inventory = function(username)
        local tagline = TAZC_BioDB.taglines[username]
        if not tagline or tagline == "" then return nil end
        if #tagline > 40 then
            tagline = tagline:sub(1, 40) .. "..."
        end
        return '"' .. tagline .. '"'
    end,
    clear = function(username)
        if TAZC_BioDB.taglines[username] == nil then return false end
        TAZC_BioDB.taglines[username] = nil
        saveTaglinesToDisk()
        -- Same broadcast as BioSave: online clients replace their cached
        -- tagline with the empty one and refresh the nameplate.
        broadcastToAll("BioUpdate", { username = username, tagline = "" })
        return true
    end,
})

-- ============================================================================
-- DESCRIPTION / CHARACTER-SHEET STORAGE
-- A longer free-text description shown on the character sheet (right-click ->
-- Character Sheet). Parallel to the tagline store above, but in its own A/B
-- file so a description bug can never touch the proven tagline store. It joins
-- the /lang resetall wipe the same way. Multi-line: TAZC_Json escapes newlines,
-- so paragraphs round-trip through persistence intact.
-- ============================================================================

local TAZC_Desc = makeStore({
    persistName = "TAZC_Descriptions",
    field       = "descriptions",
    label       = "Description",
    cleanEntry  = cleanStringEntry,
})
TAZC_Desc.max = 500

-- Strip control chars but KEEP newlines (the description is multi-line), trim
-- the ends, and cap length. The client sanitizes identically before sending.
function TAZC_Desc.sanitize(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:gsub("^%s*(.-)%s*$", "%1")
    return text:sub(1, TAZC_Desc.max)
end

-- Descriptions are per-player data, so they join the /lang resetall total wipe
-- exactly as the tagline and hue stores do.
TAZC_Lang.registerWipeExtension("description", {
    label = "Character-sheet description",
    inventory = function(username)
        local desc = TAZC_Desc.db.descriptions[username]
        if not desc or desc == "" then return nil end
        desc = desc:gsub("\n", " ")
        if #desc > 40 then desc = desc:sub(1, 40) .. "..." end
        return '"' .. desc .. '"'
    end,
    clear = function(username)
        if TAZC_Desc.db.descriptions[username] == nil then return false end
        TAZC_Desc.db.descriptions[username] = nil
        TAZC_Desc.saveToDisk()
        broadcastToAll("DescUpdate", { username = username, description = "" })
        return true
    end,
})

-- ============================================================================
-- PERSONAL NOTES STORAGE (private per-viewer remarks about other players)
-- notes[viewerUsername][targetUsername] = free text. STRICTLY private: the
-- server only ever sends a viewer their OWN notes, always keyed off the
-- authenticated sender username (never a client-supplied viewer field), so no
-- player can read or forge another's notes. Same A/B store idiom as the
-- tagline / description stores, but two-level keys don't fit makeStore's flat
-- cleanEntry shape, so Notes supplies its own loadFromDisk override.
-- ============================================================================

local TAZC_Notes = makeStore({
    persistName  = "TAZC_Notes",
    field        = "notes",
    label        = "Notes",
    loadFromDisk = function(store)
        local data = store:load()
        if not data or type(data.notes) ~= "table" then return {} end
        local notes = {}
        for viewer, targets in pairs(data.notes) do
            if type(viewer) == "string" and type(targets) == "table" then
                local clean = {}
                for target, text in pairs(targets) do
                    if type(target) == "string" and type(text) == "string" then
                        clean[target] = text
                    end
                end
                notes[viewer] = clean
            end
        end
        return notes
    end,
})
TAZC_Notes.max = 500

-- Keep newlines, strip other control chars, trim, cap. (Same as descriptions.)
function TAZC_Notes.sanitize(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:gsub("^%s*(.-)%s*$", "%1")
    return text:sub(1, TAZC_Notes.max)
end

-- Broadcast that every viewer's note ABOUT `target` is gone, so open sheets and
-- caches drop it right away.
local function broadcastNoteAboutCleared(target)
    broadcastToAll("NoteAboutCleared", { target = target })
end

-- /lang resetall wipes everything about a username: BOTH the notes they wrote
-- about others AND everyone's notes about them.
TAZC_Lang.registerWipeExtension("notes", {
    label = "Personal notes",
    inventory = function(username)
        local n = 0
        local mine = TAZC_Notes.db.notes[username]
        if mine then n = n + TAZC_Core.tableSize(mine) end
        for _, targets in pairs(TAZC_Notes.db.notes) do
            if targets[username] then n = n + 1 end
        end
        if n == 0 then return nil end
        return n .. " note(s)"
    end,
    clear = function(username)
        local changed = false
        if TAZC_Notes.db.notes[username] ~= nil then
            TAZC_Notes.db.notes[username] = nil
            changed = true
        end
        for _, targets in pairs(TAZC_Notes.db.notes) do
            if targets[username] ~= nil then
                targets[username] = nil
                changed = true
            end
        end
        if changed then
            TAZC_Notes.saveToDisk()
            broadcastNoteAboutCleared(username)
        end
        return changed
    end,
})

-- ============================================================================
-- NAME COLOR (/hue) STORAGE
-- Per-username chosen chat-name color, {r, g, b} 0-255. Same direct file
-- I/O rationale, same A/B crash-safe idiom, and same save cadence (write
-- through on every change) as the tagline store above. Consumed by
-- getPlayerColor below, so a chosen color flows everywhere playerColor
-- already flows with no other call-site changes.
-- ============================================================================

-- One color component: an INTEGER in 0-255. The floor check matters: a
-- hand-edited or corrupt slot file could carry 100.5, which %d formatting
-- downstream does not tolerate on every VM. NaN fails the equality, inf
-- fails the range.
local function validHueComponent(v)
    return type(v) == "number" and v >= 0 and v <= 255
        and v == math.floor(v)
end

local TAZC_HueDB, saveHuesToDisk
do
    local s = makeStore({
        persistName = "TAZC_Hues",
        field       = "hues",
        label       = "Hue",
        cleanEntry  = function(raw)
            if type(raw) == "table"
               and validHueComponent(raw[1])
               and validHueComponent(raw[2])
               and validHueComponent(raw[3]) then
                return { raw[1], raw[2], raw[3] }
            end
            return nil
        end,
    })
    TAZC_HueDB = s.db
    saveHuesToDisk = s.saveToDisk
end

-- ============================================================================
-- RADIO STATIC SIMULATION
-- 
-- Moved to TAZC_Radio in v8.5.1 so the chunked variant could live alongside
-- and so the harness can exercise both. Access via TAZC_Radio.addPacketLoss
-- (flat string) and TAZC_Radio.addPacketLossToChunks (v8.5+ chunks). The
-- STATIC_POPS array and base rates also live on TAZC_Radio.
-- ============================================================================

-- ============================================================================
-- WEATHER INTERFERENCE
-- Bad weather = worse radio. Blizzards are brutal.
-- ============================================================================

--[[
    Calculate weather-based interference multiplier
    @return number 1.0 (clear) to 3.0 (terrible conditions)
]]
local function getWeatherInterference()
    local multiplier = 1.0
    
    local climate = TAZC_Core.safe(function() return getClimateManager() end, nil)
    if not climate then return multiplier end
    
    -- B42 compatible weather queries - check method exists before calling
    local wind = 0
    local rain = 0
    local fog = 0
    local temp = 10
    local thunder = false
    
    if climate.getWindIntensity then
        wind = TAZC_Core.safe(function() return climate:getWindIntensity() or 0 end, 0)
    end
    if climate.getRainIntensity then
        rain = TAZC_Core.safe(function() return climate:getRainIntensity() or 0 end, 0)
    end
    if climate.getFogIntensity then
        fog = TAZC_Core.safe(function() return climate:getFogIntensity() or 0 end, 0)
    end
    if climate.getTemperature then
        temp = TAZC_Core.safe(function() return climate:getTemperature() or 10 end, 10)
    end
    -- isThunderStorming may not exist in B42 - check first
    if climate.isThunderStorming then
        thunder = TAZC_Core.safe(function() return climate:isThunderStorming() end, false)
    elseif climate.getIsThunderStorming then
        thunder = TAZC_Core.safe(function() return climate:getIsThunderStorming() end, false)
    end
    
    local isFreezing = temp < 0
    
    -- Wind interference (antenna sway, signal scatter)
    if wind > 0.7 then
        multiplier = multiplier + 0.8      -- High wind: +80%
    elseif wind > 0.5 then
        multiplier = multiplier + 0.4      -- Moderate wind: +40%
    elseif wind > 0.3 then
        multiplier = multiplier + 0.2      -- Light wind: +20%
    end
    
    -- Precipitation interference
    if rain > 0.7 then
        multiplier = multiplier + 0.6      -- Heavy rain/snow: +60%
    elseif rain > 0.4 then
        multiplier = multiplier + 0.3      -- Moderate: +30%
    end
    
    -- Thunderstorm (electrical interference)
    if thunder then
        multiplier = multiplier + 1.0      -- Thunder: +100% (doubles base)
    end
    
    -- Blizzard detection (freezing + wind + precipitation/fog)
    if isFreezing and wind > 0.4 and (rain > 0.2 or fog > 0.4) then
        multiplier = multiplier + 0.5      -- Blizzard bonus: +50% on top
    end
    
    -- Fog (signal absorption in moisture)
    if fog > 0.6 then
        multiplier = multiplier + 0.3      -- Dense fog: +30%
    end
    
    -- Cap at 3x to keep messages somewhat readable
    return math.min(multiplier, 3.0)
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Calculate distance between two players (2D, tile-based)
local function getDistance(player1, player2)
    return TAZC_Core.safe(function()
        return TAZC_Core.distance2D(player1:getX(), player1:getY(),
            player2:getX(), player2:getY())
    end, 999)
end

-- Check if two players are in the same vehicle
local function inSameVehicle(player1, player2)
    local v1 = TAZC_Core.safe(function() return player1:getVehicle() end, nil)
    local v2 = TAZC_Core.safe(function() return player2:getVehicle() end, nil)
    if v1 and v2 then
        local id1 = TAZC_Core.safe(function() return v1:getId() end, nil)
        local id2 = TAZC_Core.safe(function() return v2:getId() end, nil)
        return id1 and id2 and id1 == id2
    end
    return false
end

-- Get player's character name
local function getCharacterName(player)
    if not player then return "Unknown" end
    
    local desc = TAZC_Core.safe(function() return player:getDescriptor() end, nil)
    if desc then
        local first = TAZC_Core.safe(function() return desc:getForename() or "" end, "")
        local last = TAZC_Core.safe(function() return desc:getSurname() or "" end, "")
        -- Strip tagline from surname (we append it with \n for display)
        local lastClean = last:match("^([^\n]*)") or last
        local name = first .. " " .. lastClean
        name = name:match("^%s*(.-)%s*$")
        if name and name ~= "" then
            return name
        end
    end
    return TAZC_Core.safe(function() return player:getUsername() end, "Unknown") or "Unknown"
end

-- Generate a color for a player based on their username. A /hue choice
-- (see the hue storage above and the /hue handler below) takes precedence;
-- the deterministic hash is the default everyone starts with and /hue reset
-- returns to. Returned as a fresh table so downstream msgData mutation can
-- never reach back into the store.
local function getPlayerColor(player)
    local name = TAZC_Core.safe(function() return player:getUsername() end, "unknown") or "unknown"
    local chosen = TAZC_HueDB.hues[name]
    if chosen then
        return { chosen[1], chosen[2], chosen[3] }
    end
    local hash = 0
    for i = 1, #name do
        hash = hash + string.byte(name, i)
    end
    return {
        150 + (hash % 105),
        150 + ((hash * 3) % 105),
        150 + ((hash * 7) % 105)
    }
end

-- ============================================================================
-- /HUE -- PLAYER-CHOSEN NAME COLOR
--
--   /hue                 -> show the current color (hex + r,g,b) and usage
--   /hue #RRGGBB         -> set (hash optional, case-insensitive)
--   /hue r,g,b           -> set (0-255, spaces around commas tolerated)
--   /hue reset           -> back to the default per-username hash color
--
-- Validation is AUTHORITATIVE here regardless of any client-side niceties
-- (same truth-lives-on-the-server pattern as /event and GrantLanguage).
-- The chosen color lands in the store getPlayerColor consults, so it flows
-- everywhere playerColor already flows -- and the client anonymity pass
-- still overwrites playerColor AFTER this server stamp, so a masked or
-- distant speaker's chosen shade never identifies them.
-- ============================================================================

-- Hex digit tables, built once. Kahlua-safe on purpose: no reliance on
-- tonumber's base argument or string.format's %X, neither of which the
-- codebase uses anywhere else.
local HEX_VAL = {}
do
    local digits = "0123456789abcdef"
    for i = 1, 16 do
        local d = digits:sub(i, i)
        HEX_VAL[d] = i - 1
        HEX_VAL[d:upper()] = i - 1
    end
end
local HEX_CHR = "0123456789ABCDEF"

local function byteToHex(n)
    local hi = math.floor(n / 16)
    local lo = n - hi * 16
    return HEX_CHR:sub(hi + 1, hi + 1) .. HEX_CHR:sub(lo + 1, lo + 1)
end

-- "#C86450 (200,100,80)" -- the shape every /hue feedback line uses.
local function describeHue(c)
    return string.format("#%s%s%s (%d,%d,%d)",
        byteToHex(c[1]), byteToHex(c[2]), byteToHex(c[3]), c[1], c[2], c[3])
end

--[[
    Parse a /hue color argument (already trimmed).
    @return {r, g, b} on success; nil on malformed input; nil, "range" when
            the shape was right but a component fell outside 0-255.
]]
local function parseHueColor(arg)
    -- Hex form: exactly six characters after an optional '#'. Validated
    -- through HEX_VAL rather than a %x pattern so a near-miss ("banana")
    -- falls through to the r,g,b parse and then to the usage line.
    local hex = arg:match("^#?(......)$")
    if hex then
        local comps = {}
        for i = 1, 6, 2 do
            local hi = HEX_VAL[hex:sub(i, i)]
            local lo = HEX_VAL[hex:sub(i + 1, i + 1)]
            if not hi or not lo then
                comps = nil
                break
            end
            comps[#comps + 1] = hi * 16 + lo
        end
        if comps then return comps end
    end

    -- r,g,b form: bare digit runs (no signs, no decimals), commas required,
    -- spaces around them tolerated.
    local r, g, b = arg:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
    if not r then return nil end
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if r > 255 or g > 255 or b > 255 then return nil, "range" end
    return { r, g, b }
end

-- READABILITY GUARD. The chat panel is dark, so a name color must clear a
-- minimum relative luminance (0.299r + 0.587g + 0.114b) of 60 on the 0-255
-- scale (~24%). 60 keeps saturated jewel tones (crimson 200,30,30 = ~81)
-- while cutting shades that genuinely vanish against the night (pure blue
-- 0,0,255 = ~29). Compared x1000 in integers so the boundary is exact --
-- no float drift at exactly 60.
local HUE_MIN_LUMINANCE = 60

local function hueLuminanceOk(c)
    return (299 * c[1] + 587 * c[2] + 114 * c[3]) >= HUE_MIN_LUMINANCE * 1000
end

local HUE_USAGE = "Usage: /hue #RRGGBB or /hue r,g,b (0-255) -- " ..
    "/hue reset returns your natural shade."

local function handleHueCommand(player, argString)
    if not player then return end
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local arg = type(argString) == "string"
        and argString:match("^%s*(.-)%s*$") or ""

    -- Bare /hue: show the current color and how to change it.
    if arg == "" then
        local current = getPlayerColor(player)
        local origin = TAZC_HueDB.hues[username]
            and "a shade you chose" or "your natural shade"
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Your name speaks in " .. describeHue(current) ..
                " -- " .. origin .. ".",
            color = current,
        })
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = HUE_USAGE,
            color = {200, 200, 200},
        })
        return
    end

    -- /hue reset: back to the per-username hash default.
    if arg:lower() == "reset" then
        if TAZC_HueDB.hues[username] == nil then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "Your name already speaks in its natural shade.",
                color = {200, 200, 200},
            })
            return
        end
        TAZC_HueDB.hues[username] = nil
        saveHuesToDisk()
        local natural = getPlayerColor(player)
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Your name returns to its natural shade -- " ..
                describeHue(natural) .. ".",
            color = natural,
        })
        dbg("handleHueCommand: %s reset to hash color", username)
        return
    end

    local color, why = parseHueColor(arg)
    if not color then
        if why == "range" then
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "Color values run 0 to 255 -- that one is out of range.",
                color = {255, 100, 100},
            })
        else
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "Couldn't read that color. " .. HUE_USAGE,
                color = {255, 100, 100},
            })
        end
        return
    end

    if not hueLuminanceOk(color) then
        -- REJECT, never silently clamp.
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "That would vanish against the night -- try something brighter.",
            color = {255, 100, 100},
        })
        return
    end

    TAZC_HueDB.hues[username] = { color[1], color[2], color[3] }
    saveHuesToDisk()
    -- Success echoes the color back in-world: the line itself is rendered
    -- in the shade just chosen (it passed the readability guard).
    sendServerCommand(player, "TAZC", "SystemMessage", {
        message = "Your name now speaks in this shade -- " ..
            describeHue(color) .. ".",
        color = { color[1], color[2], color[3] },
    })
    dbg("handleHueCommand: %s -> %s", username, describeHue(color))
end

-- The hue store holds per-player data, so it joins the /lang resetall
-- total wipe (see TAZC_Lang.registerWipeExtension for the contract; the bio
-- registration above is its sibling). inventory feeds the preview; clear
-- wipes, persists, and lets the next server stamp fall back to the hash
-- color on its own.
TAZC_Lang.registerWipeExtension("hue", {
    label = "Name color",
    inventory = function(username)
        local hue = TAZC_HueDB.hues[username]
        if not hue then return nil end
        return "their chosen shade, " .. describeHue(hue)
    end,
    clear = function(username)
        if TAZC_HueDB.hues[username] == nil then return false end
        TAZC_HueDB.hues[username] = nil
        saveHuesToDisk()
        return true
    end,
})

-- ============================================================================
-- MESSAGE DATA BUILDING
-- ============================================================================

local function buildMessageData(player, channel, message)
    local steamId = nil
    if getSteamIDFromUsername then
        steamId = TAZC_Core.safe(function() 
            return getSteamIDFromUsername(player:getUsername()) 
        end, nil)
    end
    
    return {
        timestamp = os.time(),
        channel = channel,
        steamId = steamId or "unknown",
        username = TAZC_Core.safe(function() return player:getUsername() end, "unknown"),
        characterName = getCharacterName(player),
        playerColor = getPlayerColor(player),
        message = message,
        coords = {
            x = TAZC_Core.safe(function() return player:getX() end, 0),
            y = TAZC_Core.safe(function() return player:getY() end, 0),
            z = TAZC_Core.safe(function() return player:getZ() end, 0)
        }
    }
end

-- ============================================================================
-- LOGGING
-- ============================================================================

local function logMessage(msgData)
    if not TAZC_Config.Log.enabled then return end
    
    local serverName = TAZC_Core.safe(function() return getServerName() end, "unknown") or "unknown"
    local date = os.date("%Y-%m-%d")
    local logPath = TAZC_Config.Log.path .. serverName .. "/chat-" .. date .. ".log"
    
    local logLine
    if TAZC_Config.Log.jsonFormat then
        local escapedMsg = msgData.message
            :gsub('\\', '\\\\')
            :gsub('"', '\\"')
            :gsub('\n', '\\n')
            :gsub('\r', '\\r')
            :gsub('\t', '\\t')
        
        logLine = string.format(
            '{"ts":%d,"ch":"%s","steam":"%s","user":"%s","char":"%s","msg":"%s","x":%.1f,"y":%.1f,"z":%.1f}',
            msgData.timestamp,
            msgData.channel,
            tostring(msgData.steamId),
            msgData.username,
            msgData.characterName,
            escapedMsg,
            msgData.coords.x,
            msgData.coords.y,
            msgData.coords.z
        )
    else
        local time = os.date("%H:%M:%S", msgData.timestamp)
        logLine = string.format(
            "%s [%s] %s (%s): %s",
            time,
            msgData.channel,
            msgData.username,
            msgData.characterName,
            msgData.message
        )
    end
    
    -- Guarded: an unprotected getFileWriter/writeln/close that throws would
    -- unwind straight out of buildAndLog, aborting the WHOLE pipeline before
    -- routeProximity/routeRadio ever run -- a bad log write would silently
    -- drop the message for every receiver, not just fail the log. Caught
    -- here, warned once, message keeps routing.
    local ok, err = pcall(function()
        local file = getFileWriter(logPath, true, true)
        if file then
            file:writeln(logLine)
            file:close()
        end
    end)
    if not ok then
        print(string.format(
            "[TAZC][SERVER] WARNING: logMessage failed to write %s: %s",
            logPath, tostring(err)))
    end
end

local function logRadioMessage(msgData, frequency, degradedMessage)
    if not TAZC_Config.Log.enabled then return end
    
    local serverName = TAZC_Core.safe(function() return getServerName() end, "unknown") or "unknown"
    local date = os.date("%Y-%m-%d")
    local logPath = TAZC_Config.Log.path .. serverName .. "/radio-" .. date .. ".log"
    
    local time = os.date("%H:%M:%S", msgData.timestamp)
    local freqStr = string.format("%.2f", frequency / 1000)
    local messageToLog = degradedMessage or msgData.message
    
    local logLine = string.format(
        "%s [%s] %s (%s)[%sHz]: %s",
        time,
        msgData.channel,
        msgData.characterName,
        msgData.username,
        freqStr,
        messageToLog
    )
    
    -- Guarded for the same reason as logMessage above: a throwing writer
    -- must not abort routeRadio before it can send to any receiver.
    local ok, err = pcall(function()
        local file = getFileWriter(logPath, true, true)
        if file then
            file:writeln(logLine)
            file:close()
        end
    end)
    if not ok then
        print(string.format(
            "[TAZC][SERVER] WARNING: logRadioMessage failed to write %s: %s",
            logPath, tostring(err)))
    else
        dbg("logRadioMessage: wrote to %s", logPath)
    end
end

-- Sidecar radio log for the Discord relay only. radio-*.log stays CLEAN so the
-- AI narrator can quote 100MHz verbatim and 350-400MHz linking codes match
-- exactly; this file instead carries the packet-loss corruption the
-- transmission actually produced, so the bridge relays the REAL in-game static
-- rather than inventing its own (which never matched what players saw in-game).
-- Each line is the standard radio line with the DEGRADED text, then a TAB and
-- the CLEAN text, so the bridge still has an uncorrupted copy for linking
-- verification. Both fields are control-char-stripped so the TAB delimiter and
-- the bridge's line-based parse stay unambiguous (see the note by the strip).
local function logRadioRelay(msgData, frequency, degradedMessage, cleanMessage)
    if not TAZC_Config.Log.enabled then return end

    local serverName = TAZC_Core.safe(function() return getServerName() end, "unknown") or "unknown"
    local date = os.date("%Y-%m-%d")
    local logPath = TAZC_Config.Log.path .. serverName .. "/radio-relay-" .. date .. ".log"

    local time = os.date("%H:%M:%S", msgData.timestamp)
    local freqStr = string.format("%.2f", frequency / 1000)
    -- Strip control chars from BOTH fields. corruptWords collapses INTERIOR
    -- whitespace to single spaces, but re-prepends the message's ORIGINAL
    -- leading/trailing whitespace (TAZC_Radio.corruptWords) -- which for a
    -- tampered/pasted client could be a TAB (breaking the delimiter) or a
    -- newline (breaking the bridge's line-based parse). Radio text never
    -- legitimately carries edge control chars, so this is invisible in the
    -- happy path and keeps the line unambiguous either way.
    local degraded = (degradedMessage or msgData.message or ""):gsub("[%c]", "")
    local clean = (cleanMessage or msgData.message or ""):gsub("[%c]", "")

    local logLine = string.format(
        "%s [%s] %s (%s)[%sHz]: %s\t%s",
        time,
        msgData.channel,
        msgData.characterName,
        msgData.username,
        freqStr,
        degraded,
        clean
    )

    -- Guarded for the same reason as logRadioMessage: a throwing writer must
    -- not abort routeRadio before it can send to any receiver.
    local ok, err = pcall(function()
        local file = getFileWriter(logPath, true, true)
        if file then
            file:writeln(logLine)
            file:close()
        end
    end)
    if not ok then
        print(string.format(
            "[TAZC][SERVER] WARNING: logRadioRelay failed to write %s: %s",
            logPath, tostring(err)))
    else
        dbg("logRadioRelay: wrote to %s", logPath)
    end
end

-- ============================================================================
-- MAIN MESSAGE PROCESSING
-- ============================================================================

-- ============================================================================
-- /TELL TARGET RESOLUTION
-- Fuzzy-match a name query against online players' forenames within say
-- range. Exact case-insensitive match wins outright; prefix match needs a
-- unique winner. Returns (player, forename) on success, (nil, errString)
-- on failure.
-- ============================================================================
local function resolveTellTarget(speaker, nameQuery)
    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then return nil, "No online players." end

    local queryLower = nameQuery:lower()
    local sayRange = TAZC_Config.Ranges.say or 15
    local candidates = {}

    for i = 0, onlinePlayers:size() - 1 do
        local target = onlinePlayers:get(i)
        local targetId = TAZC_Core.safe(function() return target:getOnlineID() end, -2)
        local speakerId = TAZC_Core.safe(function() return speaker:getOnlineID() end, -1)
        if targetId ~= speakerId then
            local distance = getDistance(speaker, target)
            local sameVehicle = inSameVehicle(speaker, target)
            if distance <= sayRange or sameVehicle then
                local forename = TAZC_Core.safe(
                    function() return target:getForename() end, nil)
                if forename and forename ~= "" then
                    local forenameLower = forename:lower()
                    if forenameLower == queryLower then
                        return target, forename  -- exact match wins
                    elseif forenameLower:sub(1, #queryLower) == queryLower then
                        candidates[#candidates + 1] = {
                            player = target, name = forename }
                    end
                end
            end
        end
    end

    if #candidates == 1 then
        return candidates[1].player, candidates[1].name
    elseif #candidates > 1 then
        local names = {}
        for _, c in ipairs(candidates) do names[#names + 1] = c.name end
        return nil, "Did you mean: " .. table.concat(names, ", ") .. "?"
    end
    return nil, "You don't see anyone named '" .. nameQuery .. "' nearby."
end

-- ============================================================================
-- SLASH COMMAND DISPATCH
-- Maps a lower-cased command word (e.g. "/lang") to the handler that
-- services it. Each handler is a function(player, argString), called with
-- the same two arguments and given the same "return right after" treatment
-- the old per-command if-block gave it.
--
-- The KEY LIST is single-sourced from TAZC_Core.SERVER_SLASH_COMMANDS (shared
-- dir) -- TAZC_Input.lua's isMCServerCommand consumes the exact same array for
-- its client-side forward check, so the two can never hand-drift apart
-- again (see that constant's own comment). SLASH_HANDLER_IMPLS below
-- supplies the handler for each entry, IN THE SAME ORDER: the pairing is
-- positional by design, since the handler bodies themselves can't live in
-- TAZC_Core -- TAZC_LangCommands and handleHueCommand are server-only.
--
-- The five TAZC_LangCommands-owned handlers are wrapped in closures rather
-- than captured directly, to preserve late binding: TAZC_LangCommands.handleX
-- is looked up on the TAZC_LangCommands table at CALL time, exactly as the
-- old inline `TAZC_LangCommands.handleXCommand(...)` did. TAZC_LangCommands.lua
-- defines these as `function TAZC_LangCommands.foo(...)` at module load, so
-- in practice they're already attached by the time this file's
-- `require("TAZC_LangCommands")` returns -- but the ladder never depended on
-- that, and this table doesn't either: a closure re-reads the field on
-- every call, so it still picks up a reattached/replaced handler
-- (hot-reload, test monkey-patch) even after this table is built.
-- handleHueCommand is a plain local function defined earlier in this file
-- and never reassigned, so it's referenced directly.
local SLASH_HANDLER_IMPLS = {
    -- /lang <language>             -> self-set (any player)
    -- /lang "<character>" <lang>   -> admin-set on target character (admin only)
    -- /lang <character> <lang>     -> same, unquoted (single-word names)
    -- Parsing lives in TAZC_LangCommands.handleSetCommand; we just forward argString.
    function(player, argString) return TAZC_LangCommands.handleSetCommand(player, argString) end,

    -- /lex             -> summary across all non-English languages
    -- /lex <language>  -> detailed list with L1 meanings
    function(player, argString) return TAZC_LangCommands.handleLexCommand(player, argString) end,

    -- /comp            -> all non-English languages
    -- /comp <language> -> single language
    function(player, argString) return TAZC_LangCommands.handleCompCommand(player, argString) end,

    -- /forget <language>          -> preview what would be lost
    -- /forget <language> confirm  -> let the language go
    function(player, argString) return TAZC_LangCommands.handleForgetCommand(player, argString) end,

    -- /hue                    -> show current color + usage
    -- /hue #RRGGBB | r,g,b    -> set (validated authoritatively in handleHueCommand)
    -- /hue reset              -> back to the per-username hash color
    handleHueCommand,

    -- /translate (v8.9.2 -- unstable branch test surface): detects English
    -- vs Turkish and runs TAZC_Translate, displaying the result to the
    -- speaker only. Self-display dev/test command; the ambient /lang
    -- integration (translation substituting for babble) is deferred until
    -- the engine's corpus coverage is higher.
    function(player, argString) return TAZC_LangCommands.handleTranslateCommand(player, argString) end,

    -- /ll (E3 ergonomics, 2026-07-08): toggle back to whatever language you
    -- were speaking immediately before your current one. Self-serve, no
    -- arguments.
    function(player, argString) return TAZC_LangCommands.handleToggleLastCommand(player, argString) end,
}

-- Built from TAZC_Core.SERVER_SLASH_COMMANDS, not retyped: this table's key
-- SET is the single source TAZC_Input.isMCServerCommand also reads.
local SLASH_HANDLERS = {}
for i, cmd in ipairs(TAZC_Core.SERVER_SLASH_COMMANDS) do
    SLASH_HANDLERS[cmd] = SLASH_HANDLER_IMPLS[i]
end

-- Type-validates player/args and the raw message: nil checks, channel
-- default, message-type/empty reject, MaxMessageLength trim+notify.
-- Establishes ctx.player/args/channel/message/lowerCmd; nil = already-rejected.
local function validateEnvelope(player, args)
    if not player or not args then
        dbg("processMessage: nil player or args")
        return nil
    end

    -- Type-validate client-provided fields. A malicious or broken client could
    -- send non-strings, tables, etc. Reject anything that doesn't look sane.
    local channel = args.channel
    if type(channel) ~= "string" or channel == "" then
        channel = "say"
    end

    local message = args.message
    if type(message) ~= "string" then
        dbg("processMessage: non-string message rejected (type=%s)", type(message))
        return nil
    end

    if message == "" then
        dbg("processMessage: empty message, ignoring")
        return nil
    end

    -- Cap message length (C47). Trim, then tell the sender -- a silent trim
    -- reads as the tail of the message never arriving. Sandbox-configurable
    -- (Terror AustraliZ Chat.MaxMessageLength, default 500, admins may raise to 2000).
    -- Read fresh from config, not a module-load snapshot: the admin value only
    -- lands after OnServerStarted's sandbox reload. The client raises its input
    -- box to match, so this cap normally only bites a tampered client.
    local maxLen = TAZC_Config.MaxMessageLength
    if #message > maxLen then
        dbg("processMessage: message truncated from %d to %d chars", #message, maxLen)
        message = message:sub(1, maxLen)
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Message trimmed to " .. maxLen .. " characters.",
            color = {255, 220, 100}
        })
    end

    -- lowerCmd feeds dispatchSlashCommand's SLASH_HANDLERS lookup below.
    local lowerCmd = message:lower()

    return {
        player = player,
        args = args,
        channel = channel,
        message = message,
        lowerCmd = lowerCmd,
    }
end

-- Slash-command dispatch (see SLASH_HANDLERS above). Extracts the command
-- word -- everything up to the first space, or the whole message if
-- there's none -- from ctx.lowerCmd and looks it up. A bare command
-- ("/hue") and a command plus a space ("/hue reset") both match; anything
-- else glued onto the command word ("/huex") does not, and falls through
-- to normal chat handling untouched. Returns true when a handler ran
-- (processMessage returns right after, exactly as the old inline dispatch did).
local function dispatchSlashCommand(ctx)
    local spaceIdx = ctx.lowerCmd:find(" ", 1, true)
    local cmdWord = spaceIdx and ctx.lowerCmd:sub(1, spaceIdx - 1) or ctx.lowerCmd
    local handler = SLASH_HANDLERS[cmdWord]
    if handler then
        local argString = (ctx.lowerCmd == cmdWord) and "" or ctx.message:sub(#cmdWord + 2)
        handler(ctx.player, argString)
        return true
    end
    return false
end

-- Channel range lookup/fallback, admin-channel reject, faction/safehouse
-- reject, OOC-disabled, ALL-disabled, and the /event admin gate. Same
-- rejects, same notifications, same returns as today; nil = rejected
-- (any notification already sent).
local function gateChannel(ctx)
    local player = ctx.player
    local channel = ctx.channel

    dbg("processMessage: %s [%s]: %s",
        TAZC_Core.safe(function() return player:getUsername() end, "?"),
        channel,
        tostring(ctx.message))

    -- Validate channel
    local range = TAZC_Config.Ranges[channel]
    if not range then
        channel = "say"
        range = TAZC_Config.Ranges.say
    end

    -- Admin channel is vanilla's territory. As of 0.8.0 TAZC_Input doesn't
    -- intercept /admin, and we don't route admin through our pipeline -
    -- vanilla's admin broadcast handles access-level filtering correctly
    -- and renders to the Admin tab. If admin still arrives here (older
    -- client, out-of-band tool), reject it rather than broadcast to all.
    if channel == "admin" then
        dbg("processMessage: admin channel rejected (vanilla owns admin routing)")
        return nil
    end

    -- Group channels aren't wired up yet. faction/safehouse carry range -1
    -- (global) but no membership filtering exists, so routing them would
    -- broadcast to the entire server. Reject with feedback until filtering
    -- lands (see TAZC_Config.Ranges).
    if channel == "faction" or channel == "safehouse" then
        dbg("processMessage: %s channel rejected (no membership filtering yet)", channel)
        local label = (channel == "faction") and "Faction" or "Safehouse"
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = label .. " chat isn't wired up yet -- your message wasn't sent.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- Check if OOC is disabled
    if channel == "ooc" and not TAZC_Config.Channels.oocEnabled then
        dbg("processMessage: OOC disabled, rejecting message")
        -- Notify sender that OOC is disabled
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "OOC chat is disabled on this server.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- Check if ALL is disabled
    if channel == "all" and not TAZC_Config.Channels.allEnabled then
        dbg("processMessage: ALL disabled, rejecting message")
        -- Notify sender that ALL is disabled
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Server-wide chat (/all) is disabled on this server.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- /event is the storyteller's channel (v8.16.2): long-range narration
    -- for admin-run roleplay events (double yell range, see TAZC_Config).
    -- Admin-gated HERE, server-side -- the client's own check only shapes
    -- UX (same pattern as GrantLanguage below; the truth lives on the
    -- server, whatever the client sent).
    if channel == "event" then
        if not TAZC_Core.isAdmin(player) then
            local accessLevel = TAZC_Core.safe(function() return player:getAccessLevel() end, "none")
            dbg("processMessage: /event rejected (access=%s)", tostring(accessLevel))
            sendServerCommand(player, "TAZC", "SystemMessage", {
                message = "The event voice belongs to the server's storytellers -- /event is for admins.",
                color = {255, 100, 100}
            })
            return nil
        end
    end

    ctx.channel = channel
    ctx.range = range
    return ctx
end

-- /tell target resolution: resolves the first word as a player name, strips
-- it, and rewrites the channel to say (only when ctx.channel == "tell").
-- Sets ctx.tellTargetUsername/tellTargetForename so routeProximity can
-- prefix "(to X)" / "(to you)". No-op passthrough for every other channel;
-- nil (after sending the usage/err notice) on failure.
local function resolveTell(ctx)
    if ctx.channel ~= "tell" then
        return ctx
    end

    local player = ctx.player
    local nameQuery, rest = ctx.message:match("^(%S+)%s+(.+)$")
    if not nameQuery or not rest or rest == "" then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Usage: /tell <name> <message>  (or /t <name> <message>)",
            color = {255, 100, 100},
        })
        return nil
    end
    local targetPlayer, err = resolveTellTarget(player, nameQuery)
    if not targetPlayer then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = err,
            color = {255, 100, 100},
        })
        return nil
    end
    ctx.tellTargetUsername = TAZC_Core.safe(
        function() return targetPlayer:getUsername() end, nil)
    ctx.tellTargetForename = TAZC_Core.safe(
        function() return targetPlayer:getForename() end, nameQuery)
    ctx.channel = "say"
    ctx.range = TAZC_Config.Ranges.say
    ctx.message = rest
    dbg("processMessage: /tell resolved '%s' -> %s (%s)",
        nameQuery, ctx.tellTargetForename, tostring(ctx.tellTargetUsername))
    return ctx
end

-- ============================================================================
-- ONE-SHOT LANGUAGE PREFIX ("@<prefix> ...", E2 ergonomics, 2026-07-08)
--
-- A speech message beginning "@<prefix> " speaks THAT ONE utterance in the
-- resolved language without touching the speaker's persisted /lang choice.
-- Resolution reuses E1's matcher (TAZC_LangRegistry.matchLanguage) against the
-- languages the speaker is currently allowed to select at all -- the exact
-- gate TAZC_LangCommands.handleSetCommand enforces via TAZC_Lang.isSelectableLanguage
-- (known language, ASL's live toggle respected).
--
-- CRITICAL FAIL-OPEN, by law: any resolution failure -- no match, an
-- AMBIGUOUS prefix, or a language the speaker isn't currently allowed to
-- pick -- must leave ctx.message COMPLETELY UNTOUCHED, including the
-- literal "@token". This is deliberate speech, not an admin command that
-- can afford a clarifying refusal: interrupting live chat with a "did you
-- mean" system message for a guessed wrong prefix would itself be a form of
-- eating the player's turn, so ambiguity fails open exactly like no-match
-- does -- silently, as ordinary speech in whatever language is already set.
-- Only a clean, UNIQUE resolution strips the marker and sets ctx.oneShotLang.
--
-- Scoped to TAZC_Lang.isSpeechChannel (say/whisper/yell/low) -- the same
-- "physical fact of the channel" scoping checkSignedHands already uses,
-- independent of the LanguagesEnabled master switch (shouldTransformChannel
-- would swallow ASL's hands gate along with it; isSpeechChannel does not).
-- Runs AFTER resolveTell so a /tell's target name is already stripped from
-- ctx.message, and BEFORE checkSignedHands so a one-shot "@asl" faces the
-- same hands-full gate a persisted ASL speaker does.
-- ============================================================================

local ONE_SHOT_LANG_PATTERN = "^@(%S+)%s+(.+)$"

local function resolveOneShotLanguage(ctx)
    if not TAZC_Lang.isSpeechChannel(ctx.channel) then return ctx end

    local token, rest = ctx.message:match(ONE_SHOT_LANG_PATTERN)
    if not token or not rest or rest == "" then return ctx end

    local pool = {}
    for _, lang in ipairs(TAZC_LangRegistry.listLanguages()) do
        if TAZC_Lang.isSelectableLanguage(lang) then pool[#pool + 1] = lang end
    end

    local kind, resolved = TAZC_LangRegistry.matchLanguage(token, pool)
    if kind ~= "exact" and kind ~= "prefix" then
        -- No match, or ambiguous: fail open, ctx.message untouched.
        return ctx
    end

    ctx.oneShotLang = resolved
    ctx.message = rest
    dbg("processMessage: one-shot language '@%s' -> %s (for this message only)", token, resolved)
    return ctx
end

-- buildMessageData call, roll-flag passthrough, disk logging (skipping
-- 'mood' -- private monologue never hits the log), and the /event identity
-- scrub applied to the outbound copy (the disk log above keeps the real
-- admin identity). Sets ctx.msgData.
local function buildAndLog(ctx)
    local channel = ctx.channel
    -- Build message data
    local msgData = buildMessageData(ctx.player, channel, ctx.message)

    -- Pass through roll flags if present
    if ctx.args.isRoll then
        msgData.isRoll = true
        msgData.rollTotal = ctx.args.rollTotal
        msgData.isCrit = ctx.args.isCrit or false
        msgData.isFumble = ctx.args.isFumble or false
    end

    -- Log to disk -- but not private channels.
    -- 'mood' (/you) is internal monologue, self-only, never transmitted to
    -- other players. Logging it to disk is a privacy leak. Skip.
    if channel ~= "mood" then
        logMessage(msgData)
        dbg("processMessage: logged to file")
    else
        dbg("processMessage: skipped logging private mood message")
    end

    -- /event identity scrub (v8.16.2). The log above keeps the real admin
    -- identity for the audit trail; the copy players receive carries none
    -- of it. Event narration is the world speaking, not a character --
    -- and the narrator may be standing masked among the players they're
    -- narrating to, so no name, colour, or position may ride along
    -- (anonymity is a headline mechanic; see TAZC_Anonymity).
    if channel == "event" then
        msgData.characterName = ""
        msgData.username = ""
        msgData.steamId = "unknown"
        msgData.playerColor = TAZC_Config.ChannelColors.event or {235, 145, 205}
        msgData.coords = { x = 0, y = 0, z = 0 }
        dbg("processMessage: /event identity scrubbed from outbound copy")
    end

    ctx.msgData = msgData
    return ctx
end

-- The pcall'd zombie-attraction sound emission: speech attracts zombies
-- based on channel (roughly 2/3 of hearing range), gated on the sandbox
-- option.
local function emitZombieSound(ctx)
    local channel = ctx.channel
    if TAZC_Config.ZombieAttraction.enabled then
        local player = ctx.player
        -- Scale attraction to channel range (roughly 2/3 of hearing range)
        local attractionRanges = {
            whisper = math.floor(TAZC_Config.Ranges.whisper * 0.66),
            low = math.floor(TAZC_Config.Ranges.low * 0.5),
            say = math.floor(TAZC_Config.Ranges.say * 0.66),
            yell = TAZC_Config.Ranges.yell,  -- Full range for yelling
            event = 0,  -- Storytelling, not in-world sound: draws nothing
        }

        local soundRadius = attractionRanges[channel]
        if soundRadius and soundRadius > 0 then
            local ok, err = pcall(function()
                -- Use nil as first arg to create environmental sound that attracts zombies
                addSound(nil, player:getX(), player:getY(), player:getZ(), soundRadius, soundRadius)
            end)
            if not ok then
                print("[TAZC][SERVER] WARNING: zombie attraction addSound failed: "
                    .. tostring(err))
            end
            dbg("processMessage: zombie attraction radius=%d for channel=%s", soundRadius, channel)
        end
    end
    return ctx
end

-- The online-players fetch, mood self-only early return, per-receiver
-- language render (sendChatToReceiver, stage-local), and the main
-- self/global/distance loop. Returns false when routing already
-- terminated here (no online players, or a self-only mood message) so
-- processMessage knows not to go on to radio routing; true otherwise.
local function routeProximity(ctx)
    local player = ctx.player
    local channel = ctx.channel
    local range = ctx.range
    local msgData = ctx.msgData
    local tellTargetUsername = ctx.tellTargetUsername
    local tellTargetForename = ctx.tellTargetForename

    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then
        dbg("processMessage: getOnlinePlayers() returned nil!")
        return false
    end
    ctx.onlinePlayers = onlinePlayers

    dbg("processMessage: routing to %d online players, range=%d", onlinePlayers:size(), range)

    -- Mood is self-only
    if channel == "mood" then
        sendServerCommand(player, "TAZC", "ChatMessage", msgData)
        dbg("processMessage: mood sent to SELF only")
        return false
    end

    local isGlobal = (range == -1)
    local sentCount = 0
    local playerId = TAZC_Core.safe(function() return player:getOnlineID() end, -2)

    -- Language transform: applies to IC speech channels only.
    -- Per-receiver render: each receiver gets babble or clean+tag based on
    -- whether they share the speaker's language. Shallow-copy msgData per
    -- receiver so the base msgData (for logging) stays clean.
    local doBabble = TAZC_Lang.shouldTransformChannel(channel)
    local speakerUsername = msgData.username

    -- M2 fix: ASLEnabled going dormant mid-session (TAZC_Lang.isDormantSigned)
    -- forces the SAME clean pass-through LanguagesEnabled=false gives every
    -- language -- an already-ASL speaker's palette has no phonology pools
    -- to fall back to the ordinary babble engine with, so "treat as their
    -- normal speech" means skip the transform pipeline entirely for them,
    -- not reroute them into a render path that would crash or misrender.
    -- E2: a one-shot override to a DIFFERENT language must not be caught by
    -- a dormant-ASL check that's really about the speaker's PERSISTED
    -- language -- ctx.oneShotLang takes precedence, same rule as everywhere
    -- else in this pipeline.
    if doBabble and TAZC_Lang.isDormantSigned(ctx.oneShotLang or TAZC_Lang.getLanguage(speakerUsername)) then
        doBabble = false
    end
    ctx.doBabble = doBabble

    -- Modality (v1: ASL). A speaker property, not a per-receiver one --
    -- everyone who perceives the message at all perceives the SAME
    -- modality, unlike the [LanguageName] tag below (gated on the receiver
    -- having identified the language). Stamped unconditionally so the
    -- client can pick "signs"-flavored framing (R-A2/verb framing) even
    -- for a receiver who doesn't know ASL from any other signed tongue yet.
    --
    -- B3 fix: stamped directly onto msgData (not just the sendChatToReceiver
    -- per-receiver copy below), because msgData ITSELF is what goes out,
    -- unchanged, whenever doBabble is false -- including
    -- Terror AustraliZ Chat.LanguagesEnabled=false, which used to leave a signed
    -- message with no modality field at all. Without it the client's sight
    -- gate (TAZC_Client.lua onChatMessage, keyed on msgData.modality ==
    -- "signed") silently never fired: signed lines displayed through walls,
    -- at full comprehension, master switch or not. The sight/hands gates
    -- are physical facts about signing, not features the babble/
    -- translation engine gets to switch off.
    -- E2: a one-shot override (ctx.oneShotLang) stands in for the
    -- persisted language for modality purposes too -- a one-shot "@asl"
    -- message really is signed, for everyone who perceives it.
    local speakerModality = TAZC_Lang.isSignedLanguage(ctx.oneShotLang or TAZC_Lang.getLanguage(speakerUsername))
        and "signed" or nil
    msgData.modality = speakerModality

    -- 8.9.13 ChannelHook: translation echo. Run the source message
    -- through the engine once; broadcast the same translated line to
    -- every receiver as a SystemMessage in muted gray. The label is
    -- "[Translation: <direction>]" per spec. Skipped for channels not
    -- eligible (mood, emote, do, system messages) and when the engine
    -- produces no usable output (avoids spamming chat with "engine
    -- could not translate" lines for every utterance).
    local translationLine = nil
    if TAZC_Config.Translation.enabled and TAZC_Config.Translation.echoEnabled
       and TAZC_Lang.shouldTranslateChannel(channel) then
        -- Late-bound require: this subsystem is deliberately isolated and
        -- off by default, so a broken/absent module must not affect chat.
        local tLoaded, TAZC_Translate = pcall(require, "TAZC_Translate")
        if tLoaded and TAZC_Translate then
            local rOk, r = pcall(TAZC_Translate.translateAuto, ctx.message)
            if not rOk then
                print(string.format(
                    "[TAZC][ERROR] translate-echo: TAZC_Translate.translateAuto failed: %s",
                    tostring(r)))
            elseif r and r.ok and r.output and r.output ~= "" then
                local detected = r.detected_language or "?"
                local arrow = (detected == "tr") and "tr->en" or "en->tr"
                translationLine = string.format("[Translation: %s] %s", arrow, r.output)
            end
        else
            -- Always-on: same rule as the /translate command's sibling
            -- load-failure line (TAZC_LangCommands.lua) -- a missing/broken
            -- engine module is operator-visible, never silent.
            print(string.format(
                "[TAZC][ERROR] translate-echo: TAZC_Translate module unavailable: %s",
                tostring(TAZC_Translate)))
        end
    end

    -- v8.16.1 "Voices": `addressed` is the proximity addressedness heuristic
    -- (within conversational distance / same vehicle = addressed; edge of
    -- earshot = overheard, reduced acquisition weight). nil = parity.
    local function sendChatToReceiver(targetPlayer, targetUsername, addressed)
        if not doBabble then
            sendServerCommand(targetPlayer, "TAZC", "ChatMessage", msgData)
        else
            local rendered, langTag, chunks
            if targetUsername == speakerUsername then
                -- Speaker: their own language tag (they understand themselves),
                -- plus the production-pass echo of what they actually managed
                -- to say -- a learner hears their own broken speech, so
                -- fluency growth is felt. Falls back to the clean typed text
                -- on any failure. No chunks: the speaker's comprehension
                -- stays clean, no L2 styling needed.
                rendered = ctx.message
                -- Guarded here (unlike renderForReceiver below, which
                -- already pcall's its own risky inner call and fails
                -- closed internally): speakerEcho's evalUtterance has no
                -- such guard of its own, so this is the only net under it.
                -- E2: ctx.oneShotLang (nil outside a one-shot message) rides
                -- along as speakerEcho's overrideLang.
                local okEcho, echo = pcall(TAZC_Lang.speakerEcho, ctx.message,
                    speakerUsername, msgData.timestamp, ctx.oneShotLang)
                if okEcho then
                    if echo then rendered = echo end
                else
                    print(string.format(
                        "[TAZC][ERROR] processMessage: speakerEcho failed: %s",
                        tostring(echo)))
                end
                langTag = ctx.oneShotLang or TAZC_Lang.getLanguage(speakerUsername)
                if langTag == "english" then langTag = nil end
                chunks = nil
            else
                rendered, langTag, chunks = TAZC_Lang.renderForReceiver(
                    speakerUsername, targetUsername, ctx.message, msgData.timestamp,
                    { addressed = addressed, overrideLang = ctx.oneShotLang })
            end
            local perReceiver = {}
            for k, v in pairs(msgData) do perReceiver[k] = v end
            perReceiver.message = rendered
            -- modality is already on msgData (stamped above) and carried
            -- through by the copy loop; no separate assignment needed here.
            -- Language identification: the [Turkish] tag only appears once
            -- the listener knows what language they're hearing. Speakers
            -- always know their own language; natives identify by definition;
            -- other listeners must have acquired at least one word first.
            -- Until then, they just see babble with no label.
            if langTag then
                if targetUsername == speakerUsername then
                    perReceiver.language = langTag
                elseif TAZC_Lang.isNative(targetUsername, langTag)
                       or hasIdentifiedLanguage(targetUsername, langTag) then
                    perReceiver.language = langTag
                end
            end
            -- Additive signal for the client's one-time first-babble hint.
            -- True exactly when this utterance carried a real language (langTag
            -- set -- the speaker wasn't speaking English) AND this specific
            -- listener didn't get the tag above (not native, hasn't
            -- identified it yet) -- i.e. genuinely unlabeled babble for THIS
            -- receiver. Never true for the speaker's own echo (that branch
            -- always sets perReceiver.language whenever langTag is set) or
            -- for English speech (langTag nil). Nothing else reads this
            -- field; existing wire behavior is unchanged.
            if langTag and not perReceiver.language then
                perReceiver.babbled = true
            end
            if chunks then perReceiver.chunks = chunks end
            -- /tell display prefix: speaker sees "(to Marta)", target sees
            -- "(to you)", others see the message plain. Applied after
            -- language rendering so the prefix is always in English.
            if tellTargetForename then
                if targetUsername == speakerUsername then
                    perReceiver.message = "(to " .. tellTargetForename .. ") "
                        .. perReceiver.message
                elseif targetUsername == tellTargetUsername then
                    perReceiver.message = "(to you) " .. perReceiver.message
                end
            end
            sendServerCommand(targetPlayer, "TAZC", "ChatMessage", perReceiver)
        end

        -- Translation echo follows the original message. Same line for
        -- every receiver in this v1; per-receiver direction-aware rendering
        -- (Turkish-only listeners see only Turkish prominently, etc.) is
        -- v2 work after we know which behaviors testers actually want.
        if translationLine then
            sendServerCommand(targetPlayer, "TAZC", "SystemMessage", {
                message = translationLine,
                color   = {150, 150, 150},
            })
        end
    end

    for i = 0, onlinePlayers:size() - 1 do
        local targetPlayer = onlinePlayers:get(i)
        local targetId = TAZC_Core.safe(function() return targetPlayer:getOnlineID() end, -1)
        local targetUsername = TAZC_Core.safe(function() return targetPlayer:getUsername() end, nil)

        -- Always send to self
        if targetId == playerId then
            sendChatToReceiver(targetPlayer, targetUsername)
            sentCount = sentCount + 1
            dbg("processMessage: sent to SELF")
        elseif isGlobal then
            sendChatToReceiver(targetPlayer, targetUsername)
            sentCount = sentCount + 1
        else
            local distance = getDistance(player, targetPlayer)
            local sameVehicle = inSameVehicle(player, targetPlayer)
            local inRange = distance <= range or sameVehicle

            if inRange then
                -- Addressedness: /tell gives explicit addressed to the target
                -- and overheard to everyone else. Without /tell, the distance
                -- heuristic applies (conversational distance = addressed).
                local addressed
                if tellTargetUsername then
                    addressed = (targetUsername == tellTargetUsername)
                else
                    local addressedDist = (TAZC_Config.Lang
                        and TAZC_Config.Lang.addressedDistance) or 6
                    addressed = sameVehicle or (distance <= addressedDist)
                end
                sendChatToReceiver(targetPlayer, targetUsername, addressed)
                sentCount = sentCount + 1
                dbg("processMessage: sent to %s (dist=%.1f, addressed=%s)",
                    TAZC_Core.safe(function() return targetPlayer:getUsername() end, "?"),
                    distance, tostring(addressed))
            end
        end
    end
    dbg("processMessage: proximity complete, sent to %d players", sentCount)

    return true
end

-- Only for say/yell/low/whisper; skipped (with a dbg note) for every other
-- channel -- same channel set and skip behavior as today. Builds the
-- emitter table (INCLUDING THE LEGACY radioFrequency FALLBACK VERBATIM --
-- deliberately pinned by a test in its current dead-in-practice form),
-- applies weather interference, logs and self-echoes, then renders+degrades
-- per receiver.
local function routeRadio(ctx)
    local player = ctx.player
    local channel = ctx.channel
    local message = ctx.message
    local msgData = ctx.msgData
    local onlinePlayers = ctx.onlinePlayers
    local doBabble = ctx.doBabble
    local speakerUsername = msgData.username

    -- Computed authoritatively here (server always has the real speaking
    -- player object) and carried on the wire as senderIsFemale so a
    -- receiving client can render "a masculine/feminine voice" for a
    -- cross-cell speaker it can't resolve to a local player object at all
    -- -- see TAZC_Anonymity.anonymizeRadioMessageData. nil (not a boolean)
    -- if the read itself failed, so the client can fall back safely.
    local senderIsFemaleOk, senderIsFemale = pcall(function() return player:isFemale() end)
    if not senderIsFemaleOk or type(senderIsFemale) ~= "boolean" then
        senderIsFemale = nil
    end

    -- Emotes never transmit as themselves -- an action isn't sound. But a
    -- speaker can carry a quoted line of actual dialogue over the radio from
    -- inside an emote (`/me scratches nose. "This is a message I want on the
    -- radio."`): pull just that quoted speech out and route it exactly like
    -- a /say from here down (packet loss, language barrier, relay, bridge --
    -- every one of them, since it IS the character's own spoken words, not a
    -- pretend voice). The plain narration and any **mood** aside are never
    -- radio content; extractQuoted() only looks inside "...". No quotes in
    -- the message means no radio attempt at all, same as an emote today.
    local EMOTE_RADIO_CHANNELS = {emote = true, emoteLong = true}
    local radioChannels = {say = true, yell = true, low = true, whisper = true}
    if EMOTE_RADIO_CHANNELS[channel] then
        local quotedSpeech = TAZC_Sanitize.extractQuoted(message)
        if not quotedSpeech then
            dbg("processMessage: skipping radio (emote has no quoted speech)")
            return
        end
        message = quotedSpeech
        channel = "say"
    elseif not radioChannels[channel] then
        dbg("processMessage: skipping radio (non-IC channel)")
        return
    end

    -- Build emitter table from client-provided data.
    -- Shape-validate each entry: malicious or broken clients can send anything,
    -- and downstream code (findReceivers, position-keying, arithmetic on freq)
    -- assumes numeric freq / positions. C15 hardening pattern.
    local VALID_EMITTER_SOURCES = { player = true, ground = true, vehicle = true }
    local emitters = {}
    local clientEmitters = ctx.args.radioEmitters

    if type(clientEmitters) == "table" and #clientEmitters > 0 then
        for _, e in ipairs(clientEmitters) do
            if type(e) == "table" and type(e.frequency) == "number" and e.frequency == e.frequency then
                local freq = e.frequency
                local source = VALID_EMITTER_SOURCES[e.source] and e.source or "player"
                local transmitRange = type(e.transmitRange) == "number" and e.transmitRange or 0

                -- Validate position: must be a table with numeric x and y
                local position = nil
                if type(e.position) == "table"
                   and type(e.position.x) == "number" and e.position.x == e.position.x
                   and type(e.position.y) == "number" and e.position.y == e.position.y then
                    position = {
                        x = e.position.x,
                        y = e.position.y,
                        z = type(e.position.z) == "number" and e.position.z == e.position.z and e.position.z or 0,
                    }
                end

                dbg("processMessage: client reports emitter on freq %d source=%s", freq, source)
                emitters[freq] = emitters[freq] or {}
                table.insert(emitters[freq], {
                    frequency = freq,
                    source = source,
                    position = position,
                    transmitRange = transmitRange,
                })
            else
                dbg("processMessage: rejected malformed radioEmitter entry")
            end
        end
    else
        -- Legacy single-frequency format
        local clientRadioFreq = ctx.args.radioFrequency
        if type(clientRadioFreq) == "number" and clientRadioFreq == clientRadioFreq then
            dbg("processMessage: client reports active radio on freq %d (legacy)", clientRadioFreq)
            emitters[clientRadioFreq] = {{ frequency = clientRadioFreq, source = "player" }}
        else
            dbg("processMessage: client has no active radios")
        end
    end

    -- Count emitters
    local emitterCount = 0
    for _ in pairs(emitters) do
        emitterCount = emitterCount + 1
    end

    if emitterCount == 0 then
        dbg("processMessage: no radio emitters found")
        return
    end

    -- Signed modality doesn't transmit (spec ruling): a radio carries
    -- sound, not sight. Only checked once we know the player is actually
    -- broadcasting -- an ASL speaker with no radio on them should never
    -- see this line. E2: a one-shot "@asl" override is signed too.
    if TAZC_Lang.isSignedLanguage(ctx.oneShotLang or TAZC_Lang.getLanguage(speakerUsername)) then
        dbg("processMessage: skipping radio (signed modality doesn't transmit)")
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Signing doesn't carry over the radio.",
            color = {255, 100, 100},
        })
        return
    end

    dbg("processMessage: found emitters on %d frequencies", emitterCount)

    -- Weather interference
    local weatherMultiplier = getWeatherInterference()
    if weatherMultiplier > 1.0 then
        dbg("Weather interference: %.1fx", weatherMultiplier)
    end

    -- Language transform applies to IC speech channels (same channels as
    -- proximity above). Radio * babble order: babble first, then packet
    -- loss -- per the locked design. Since babble is per-receiver, packet
    -- loss now runs per-receiver too (was per-frequency in stable).
    -- Speaker's own tag (so self-echo and same-language listeners see it).
    -- E2: a one-shot override takes precedence, same as everywhere else.
    local speakerOwnLangTag = ctx.oneShotLang or TAZC_Lang.getLanguage(speakerUsername)
    if speakerOwnLangTag == "english" then speakerOwnLangTag = nil end

    -- Roll radio packet loss ONCE per transmission, not per receiver. Every
    -- clear-text listener, the speaker's own self-echo, and the Discord relay
    -- share this single corruption, so one transmission reads identically
    -- everywhere it is witnessed. (Babble listeners still degrade per-receiver
    -- below: their text is unique to them, so there is nothing for a shared
    -- roll to share.) This is the "one static per broadcast" model -- radio
    -- packet loss is a property of the transmission, not of each listener.
    local canonicalStatic = TAZC_Radio.addPacketLoss(message, weatherMultiplier)

    -- Log radio transmissions with the ORIGINAL (pre-babble) message. Logs
    -- preserve intent; per-receiver renders are an ephemeral display layer.
    -- The Discord relay sidecar (logRadioRelay) is written AFTER routing --
    -- see the end of this function -- so its babble render's packet-loss roll
    -- can't perturb the per-receiver ZombRand sequence.
    for freq, _ in pairs(emitters) do
        logRadioMessage(msgData, freq, message)
        dbg("[RADIO_TX] [%.2fHz] %s (%s) [%s]: %s",
            freq / 1000,
            msgData.characterName,
            msgData.username,
            msgData.channel,
            message
        )
    end

    -- Self-echo (sender sees their transmission, clean + their own language tag).
    -- Shares the canonical roll so the speaker sees exactly what clear-text
    -- listeners and the Discord relay see.
    for freq, _ in pairs(emitters) do
        local selfDegraded = canonicalStatic
        local radioMsgData = {
            senderUsername = msgData.username,
            senderCharacter = msgData.characterName,
            senderIsFemale = senderIsFemale,
            message = selfDegraded,
            language = speakerOwnLangTag,
            channel = channel,
            frequency = freq,
            receiverType = "self",
            receiverOwnerId = msgData.username,
            receiverPosition = nil,
            isPrivate = true,
            volume = 0
        }
        sendServerCommand(player, "TAZC", "RadioMessage", radioMsgData)
        dbg("processMessage: sent self-echo on %d", freq)
    end

    -- Route to receivers (skip sender - they already got self-echo)
    local radioSentCount = 0
    local radioSoundEmitted = {}
    local senderOnlineId = TAZC_Core.safe(function() return player:getOnlineID() end, -1)

    for i = 0, onlinePlayers:size() - 1 do
        local targetPlayer = onlinePlayers:get(i)
        local targetOnlineId = TAZC_Core.safe(function() return targetPlayer:getOnlineID() end, -2)

        -- Skip sender - they already received self-echo above
        if targetOnlineId == senderOnlineId then
            dbg("processMessage: skipping sender for radio routing (already got self-echo)")
        else
            local receivers = TAZC_Radio.findReceivers(targetPlayer, emitters)
            local targetUsername = TAZC_Core.safe(function() return targetPlayer:getUsername() end, nil)

            for freq, receiverList in pairs(receivers) do
                for _, receiverInfo in ipairs(receiverList) do
                    local radio = receiverInfo.radio

                    -- Per-receiver render: babble or clean+tag, then packet loss.
                    -- v8.5.1: capture chunks from renderForReceiver and run the
                    -- chunk-aware degradation path when present, so the L2
                    -- gradient render lands on the radio too. The flat string
                    -- on the wire is derived from the degraded chunks so the
                    -- two stay positionally consistent.
                    -- v8.16.1: no opts -- radio carries no address signal, so
                    -- acquisition stays at parity weight (addressed = nil)
                    -- rather than penalizing legitimate radio conversation.
                    --
                    -- 2026-07-09 fix (foreign speech over radio must fail
                    -- TOWARD babble, never toward clear text): this used to
                    -- gate the render call on `targetUsername` being truthy
                    -- and send the RAW, un-rendered `message` whenever a
                    -- listener's username couldn't be resolved (a
                    -- getUsername() failure caught by TAZC_Core.safe) --
                    -- exactly the "can't resolve the listener's
                    -- comprehension" case, and it was failing OPEN (clear
                    -- text) instead of closed (babble). routeProximity next
                    -- door has no such special case -- it calls
                    -- renderForReceiver unconditionally and lets a nil
                    -- receiverUsername fall through TAZC_Lang.isNative(nil, ..)
                    -- = false, which the render pipeline already treats as
                    -- "non-native listener" (plain babble, no dictionary
                    -- bleed/acquisition bookkeeping, since those are
                    -- separately guarded on `receiverUsername` inside
                    -- renderWithLangs). Radio now does the same: doBabble
                    -- alone gates the render call, so an unresolved listener
                    -- gets the same fail-toward-indecipherable treatment as
                    -- every other non-comprehending listener, never the
                    -- speaker's plaintext.
                    local rendered, langTag, chunks
                    if doBabble then
                        rendered, langTag, chunks = TAZC_Lang.renderForReceiver(
                            speakerUsername, targetUsername, message, msgData.timestamp,
                            { overrideLang = ctx.oneShotLang })
                    else
                        rendered = message
                        langTag = nil
                        chunks = nil
                    end

                    local degraded, degradedChunks
                    if chunks then
                        -- Babble render: the listener's text is unique to them,
                        -- so packet loss is necessarily rolled per-receiver.
                        degradedChunks, degraded = TAZC_Radio.addPacketLossToChunks(
                            chunks, weatherMultiplier)
                    elseif rendered == message then
                        -- Clear-text listener hears the speaker's exact words:
                        -- reuse the ONE canonical roll so in-game and the
                        -- Discord relay show byte-identical static.
                        degraded = canonicalStatic
                        degradedChunks = nil
                    else
                        degraded = TAZC_Radio.addPacketLoss(rendered, weatherMultiplier)
                        degradedChunks = nil
                    end

                    -- Language identification gate (same logic as proximity):
                    -- only reveal the language name once the listener knows
                    -- what language they're hearing.
                    local radioLangTag = nil
                    if langTag and targetUsername then
                        if TAZC_Lang.isNative(targetUsername, langTag)
                           or hasIdentifiedLanguage(targetUsername, langTag) then
                            radioLangTag = langTag
                        end
                    end

                    local radioMsgData = {
                        senderUsername = msgData.username,
                        senderCharacter = msgData.characterName,
                        senderIsFemale = senderIsFemale,
                        message = degraded,
                        chunks = degradedChunks,
                        language = radioLangTag,
                        channel = channel,
                        frequency = freq,
                        receiverType = radio.source,
                        receiverOwnerId = radio.ownerId,
                        receiverPosition = radio.position,
                        isPrivate = radio.isPrivate,
                        volume = radio.volume
                    }

                    sendServerCommand(targetPlayer, "TAZC", "RadioMessage", radioMsgData)
                    radioSentCount = radioSentCount + 1
                    dbg("processMessage: sent radio to %s via %s on %d",
                        TAZC_Core.safe(function() return targetPlayer:getUsername() end, "?"),
                        radio.source, freq)

                    -- Zombie attraction from public radios
                    if not radio.isPrivate then
                        local soundX, soundY, soundZ
                        local posKey

                        if radio.source == "player" then
                            soundX = TAZC_Core.safe(function() return targetPlayer:getX() end, nil)
                            soundY = TAZC_Core.safe(function() return targetPlayer:getY() end, nil)
                            soundZ = TAZC_Core.safe(function() return targetPlayer:getZ() end, nil)
                            posKey = "player_" .. TAZC_Core.safe(function() return targetPlayer:getOnlineID() end, 0)
                        elseif radio.position then
                            soundX = radio.position.x
                            soundY = radio.position.y
                            soundZ = radio.position.z or 0
                            posKey = math.floor(soundX) .. "_" .. math.floor(soundY)
                        end

                        if posKey and soundX and not radioSoundEmitted[posKey] then
                            radioSoundEmitted[posKey] = true

                            local vol = radio.volume or 1.0
                            local hearingRange = receiverInfo.hearingRange or (TAZC_Config.Ranges.yell * vol)
                            local soundRadius = math.floor(hearingRange * 0.7)

                            if soundRadius > 0 then
                                local ok, err = pcall(function()
                                    addSound(nil, soundX, soundY, soundZ, soundRadius, vol)
                                end)
                                if not ok then
                                    print("[TAZC][SERVER] WARNING: radio zombie attraction addSound failed: "
                                        .. tostring(err))
                                end
                                dbg("processMessage: radio zombie sound at %s radius=%d", posKey, soundRadius)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Discord relay sidecar. Written AFTER per-receiver routing on purpose:
    -- the relay's babble render + packet loss draws ZombRand, and rolling it
    -- here (rather than before the receiver loop) keeps every in-game
    -- receiver's corruption byte-identical to what it would be without the
    -- relay -- the relay is a pure output side-effect, not a gameplay roll.
    --
    -- The relay is the LAST stage before Discord, and a Discord reader can
    -- never be assumed to speak the language -- so foreign speech must never
    -- arrive there as readable English (Emily's ruling, 2026-07-13: "if it
    -- arrives to Discord it should not be English"). observerBabble
    -- full-babbles the whole utterance in the speaker's palette -- a boundary
    -- guarantee independent of the speaker's fluency, so a learner's
    -- English-fallback words can't leak; only *emote*/((OOC)) markers survive.
    -- Gated on the speaker's own non-English tag alone (NOT the per-receiver
    -- doBabble flag): a non-English line is scrubbed of English before Discord
    -- even with the language barrier's master switch off. observerBabble
    -- returns nil for English -- the relay then keeps the shared canonical
    -- static, byte-identical to every clear-text witness; for a non-English
    -- language whose palette can't load it also returns nil and we redact to
    -- static rather than leak plaintext. The clean copy after the TAB stays
    -- the pre-babble message so 350-400MHz linking codes still verify exactly.
    local relayDegraded = canonicalStatic
    if speakerOwnLangTag then
        local ok, babbled = pcall(TAZC_Lang.observerBabble, message,
            speakerUsername, msgData.timestamp, ctx.oneShotLang)
        if ok and type(babbled) == "string" and babbled ~= "" then
            relayDegraded = TAZC_Radio.addPacketLoss(babbled, weatherMultiplier)
        else
            relayDegraded = (message:gsub("%S+", "*static*"))
        end
    end
    -- Extension bridge dispatch (TAZC_Bridge): same per-frequency loop and
    -- the same already-safety-scrubbed relayDegraded text as the relay log
    -- above -- external listeners see no more than the Discord relay does.
    local senderX = TAZC_Core.safe(function() return player:getX() end, nil)
    local senderY = TAZC_Core.safe(function() return player:getY() end, nil)
    local senderZ = TAZC_Core.safe(function() return player:getZ() end, nil)

    for freq, _ in pairs(emitters) do
        logRadioRelay(msgData, freq, relayDegraded, message)

        local dispatchOk, dispatchErr = pcall(TAZC_Bridge.Transmissions.dispatch, {
            frequency = freq,
            frequencyMHz = freq / 1000,
            message = relayDegraded,
            username = msgData.username,
            characterName = msgData.characterName,
            channel = channel,
            sourceX = senderX,
            sourceY = senderY,
            sourceZ = senderZ,
            timestamp = msgData.timestamp,
        })
        if not dispatchOk then
            print(string.format(
                "[TAZC][SERVER] WARNING: TAZC_Bridge dispatch failed for freq %s: %s",
                tostring(freq), tostring(dispatchErr)))
        end
    end

    dbg("processMessage: radio complete, sent %d radio messages", radioSentCount)
end

-- Hands gate (R-A7): ASL needs a free hand. Server-reliable accessors --
-- getPrimaryHandItem/getSecondaryHandItem, the same pair TAZC_Radio's own
-- hand scan already trusts server-side (shared/TAZC_Radio.lua ~523-524).
-- Belt/attached items are NOT consulted (documented flaky server-side
-- there too). Checked once, before the message is even built/logged, so a
-- blocked line never reaches anyone -- not even the speaker's own echo.
--
-- B3 fix: gated on isSpeechChannel (channel-set only), NOT
-- shouldTransformChannel -- that also folds in Terror AustraliZ Chat.LanguagesEnabled,
-- and whether you physically have a free hand to sign with has nothing to
-- do with whether the babble/translation engine is switched on. Under
-- LanguagesEnabled=false this gate used to no-op entirely, letting a
-- hands-full signer "speak" with both hands full.
local function checkSignedHands(ctx)
    if not TAZC_Lang.isSpeechChannel(ctx.channel) then return ctx end
    local player = ctx.player
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    -- E2 one-shot override (ctx.oneShotLang), when present, stands in for
    -- the persisted language here too -- a one-shot "@asl ..." must face
    -- the SAME hands-full physical gate a persisted ASL speaker does.
    local effectiveLang = ctx.oneShotLang or TAZC_Lang.getLanguage(username)
    if not TAZC_Lang.isSignedLanguage(effectiveLang) then return ctx end

    local primary = TAZC_Core.safe(function() return player:getPrimaryHandItem() end, nil)
    local secondary = TAZC_Core.safe(function() return player:getSecondaryHandItem() end, nil)

    -- M8: a two-handed weapon (shotgun, sledgehammer, ...) may occupy only
    -- the primary slot while functionally locking up both hands -- whether
    -- getSecondaryHandItem() also reflects that (returning the same item)
    -- or reads nil (primary alone, off-hand technically "empty" but
    -- unusable) is unconfirmed. LIVE-VERIFICATION-NEEDED (cobra), same
    -- class of gap as the Deaf trait accessor (TAZC_Anonymity.
    -- localPlayerIsDeaf) -- until then this wraps defensively: if the
    -- primary item exposes isTwoHandWeapon(), a true reading is treated as
    -- "no free hand" even when secondary alone reads nil. An errored or
    -- absent read falls through to the plain primary+secondary check
    -- below, same fail-safe direction as every other hand/trait accessor
    -- in this codebase (never silently WIDENS what counts as "hands free").
    local primaryIsTwoHanded = primary ~= nil and TAZC_Core.safe(function()
        return primary.isTwoHandWeapon ~= nil and primary:isTwoHandWeapon() == true
    end, false)

    if (primary and secondary) or primaryIsTwoHanded then
        dbg("processMessage: signed message blocked -- both hands full")
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "Your hands are full \226\128\148 nothing can be said with them.",
            color = {255, 100, 100},
        })
        return nil
    end
    return ctx
end

-- Thin pipeline: validate -> command? -> gate? -> tell -> one-shot lang ->
-- hands? -> build/log -> sound -> route (proximity always; radio
-- additionally for IC channels).
local function processMessage(player, args)
    local ctx = validateEnvelope(player, args)
    if not ctx then return end

    if dispatchSlashCommand(ctx) then return end

    ctx = gateChannel(ctx)
    if not ctx then return end

    ctx = resolveTell(ctx)
    if not ctx then return end

    ctx = resolveOneShotLanguage(ctx)

    ctx = checkSignedHands(ctx)
    if not ctx then return end

    ctx = buildAndLog(ctx)
    ctx = emitZombieSound(ctx)

    if routeProximity(ctx) then
        routeRadio(ctx)
    end
end

-- ============================================================================
-- COMMAND HANDLERS
-- ============================================================================

local ServerCommands = {}

ServerCommands.ChatMessage = function(player, args)
    processMessage(player, args)
end

ServerCommands.Typing = function(player, args)
    if not player or type(args) ~= "table" then 
        dbg("Typing: nil player or non-table args")
        return 
    end
    
    -- Validate channel is a known string; fall back to "say" if not
    local channel = type(args.channel) == "string" and args.channel or "say"
    local range = TAZC_Config.Ranges[channel] or TAZC_Config.Ranges.say
    
    dbg("Typing: %s [%s]", 
        TAZC_Core.safe(function() return player:getUsername() end, "?"), channel)
    
    local typingData = {
        username = TAZC_Core.safe(function() return player:getUsername() end, "unknown"),
        channel = channel,
    }
    
    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then return end
    
    local isGlobal = (range == -1)
    local playerId = TAZC_Core.safe(function() return player:getOnlineID() end, -1)
    
    for i = 0, onlinePlayers:size() - 1 do
        local targetPlayer = onlinePlayers:get(i)
        local targetId = TAZC_Core.safe(function() return targetPlayer:getOnlineID() end, -2)
        
        if targetId ~= playerId then
            if isGlobal then
                sendServerCommand(targetPlayer, "TAZC", "Typing", typingData)
            else
                local distance = getDistance(player, targetPlayer)
                if distance <= range or inSameVehicle(player, targetPlayer) then
                    sendServerCommand(targetPlayer, "TAZC", "Typing", typingData)
                end
            end
        end
    end
end

-- ============================================================================
-- BIO/TAGLINE COMMANDS
-- ============================================================================

ServerCommands.BioSave = function(player, args)
    if not player or type(args) ~= "table" then return end
    
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end
    
    -- Allow empty tagline (clears it), but reject non-string. Control chars
    -- stripped to prevent save-file corruption (fix hardening from 0.7.9.5).
    local tagline = ""
    if args.tagline ~= nil then
        if type(args.tagline) ~= "string" then
            dbg("BioSave: non-string tagline rejected (type=%s)", type(args.tagline))
            return
        end
        tagline = args.tagline:gsub("[%c]", ""):sub(1, BIO_MAX_LENGTH)
    end
    
    -- Store in memory cache
    TAZC_BioDB.taglines[username] = tagline
    dbg("BioSave: %s = '%s'", username, tagline)
    
    -- Write directly to disk
    saveTaglinesToDisk()
    
    -- Broadcast to all online players so they update their caches
    broadcastToAll("BioUpdate", { username = username, tagline = tagline })
end

ServerCommands.BioLoad = function(player, args)
    if not player or type(args) ~= "table" then return end
    
    local targetUsername = validString(args.username, 64)
    if not targetUsername then return end
    
    local tagline = TAZC_BioDB.taglines[targetUsername] or ""
    
    sendServerCommand(player, "TAZC", "BioData", {
        username = targetUsername,
        tagline = tagline
    })
    dbg("BioLoad: sent %s's tagline to %s", targetUsername, 
        TAZC_Core.safe(function() return player:getUsername() end, "?"))
end

ServerCommands.BioSyncAll = function(player, args)
    if not player then return end

    -- Send all taglines AND descriptions to the requesting player in one sync.
    -- descriptions is an additive field; older clients simply ignore it.
    sendServerCommand(player, "TAZC", "BioSyncAll", {
        bios = TAZC_BioDB.taglines,
        descriptions = TAZC_Desc.db.descriptions
    })
    dbg("BioSyncAll: sent %d bios / %d descriptions to %s",
        TAZC_Core.tableSize(TAZC_BioDB.taglines), TAZC_Core.tableSize(TAZC_Desc.db.descriptions),
        TAZC_Core.safe(function() return player:getUsername() end, "?"))
end

-- ============================================================================
-- NAME (real rename) -- broadcast-only relay
-- Unlike Bio/Desc above, TAZC owns no store for this: forename/surname are
-- real vanilla descriptor fields the client already applied to its own
-- character and pushed via sendPlayerStatsChange() before this command ever
-- arrives (see TAZC_Bio.saveName). This ping carries no name data on
-- purpose -- every other client just drops its cached copy of this
-- username's name and re-reads the (by then engine-synced) descriptor
-- itself. Nothing to validate or persist here.
-- ============================================================================

ServerCommands.NameSave = function(player, args)
    if not player then return end

    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    dbg("NameSave: %s renamed, broadcasting refresh", username)
    broadcastToAll("NameUpdate", { username = username })
end

-- ============================================================================
-- DESCRIPTION / CHARACTER-SHEET COMMANDS
-- Parallel to the Bio commands above; server-authoritative, broadcast on save.
-- ============================================================================

ServerCommands.DescSave = function(player, args)
    if not player or type(args) ~= "table" then return end

    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    -- Allow empty (clears it); reject non-string. sanitize keeps newlines and
    -- caps length.
    local description = ""
    if args.description ~= nil then
        if type(args.description) ~= "string" then
            dbg("DescSave: non-string description rejected (type=%s)", type(args.description))
            return
        end
        description = TAZC_Desc.sanitize(args.description)
    end

    TAZC_Desc.db.descriptions[username] = description
    dbg("DescSave: %s = %d chars", username, #description)
    TAZC_Desc.saveToDisk()

    -- Broadcast so every online client updates its cache.
    broadcastToAll("DescUpdate", { username = username, description = description })
end

ServerCommands.DescLoad = function(player, args)
    if not player or type(args) ~= "table" then return end

    local targetUsername = validString(args.username, 64)
    if not targetUsername then return end

    local description = TAZC_Desc.db.descriptions[targetUsername] or ""

    sendServerCommand(player, "TAZC", "DescData", {
        username = targetUsername,
        description = description
    })
    dbg("DescLoad: sent %s's description to %s", targetUsername,
        TAZC_Core.safe(function() return player:getUsername() end, "?"))
end

-- ============================================================================
-- PERSONAL NOTES COMMANDS
-- Private. The viewer is ALWAYS the authenticated sender username, never a
-- field from the client -- so a player can only ever read or write their own
-- notes, and NoteData only ever flows back to the author.
-- ============================================================================

ServerCommands.NoteSave = function(player, args)
    if not player or type(args) ~= "table" then return end
    local viewer = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not viewer then return end
    local target = validString(args.target, 64)
    if not target then return end

    local note = ""
    if args.note ~= nil then
        if type(args.note) ~= "string" then return end
        note = TAZC_Notes.sanitize(args.note)
    end

    local mine = TAZC_Notes.db.notes[viewer]
    if note == "" then
        if mine then mine[target] = nil end
    else
        if not mine then mine = {}; TAZC_Notes.db.notes[viewer] = mine end
        mine[target] = note
    end
    TAZC_Notes.saveToDisk()
    dbg("NoteSave: %s about %s (%d chars)", viewer, target, #note)
    -- Confirm to the author only (private).
    sendServerCommand(player, "TAZC", "NoteData", { target = target, note = note })
end

ServerCommands.NoteLoad = function(player, args)
    if not player or type(args) ~= "table" then return end
    local viewer = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not viewer then return end
    local target = validString(args.target, 64)
    if not target then return end

    local mine = TAZC_Notes.db.notes[viewer]
    local note = (mine and mine[target]) or ""
    sendServerCommand(player, "TAZC", "NoteData", { target = target, note = note })
end

-- Sent by a client that detects its own fresh character: a new character is a
-- new person, so wipe this identity's whole note graph -- the notes they wrote
-- about others AND everyone's notes about them. Keyed off the sender, so a
-- client can only ever reset ITSELF.
ServerCommands.NoteClearAbout = function(player, args)
    if not player then return end
    local target = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not target then return end

    local changed = false
    if TAZC_Notes.db.notes[target] ~= nil then
        TAZC_Notes.db.notes[target] = nil          -- their outgoing dossier
        changed = true
    end
    for _, targets in pairs(TAZC_Notes.db.notes) do -- everyone's notes about them
        if targets[target] ~= nil then
            targets[target] = nil
            changed = true
        end
    end
    if changed then
        TAZC_Notes.saveToDisk()
        broadcastNoteAboutCleared(target)
        dbg("NoteClearAbout: reset note graph for %s (fresh character)", target)
    end
end

--[[
    Server-authoritative boredom reduction.
    Client sends request when hearing others talk; server modifies the stat.
    
    Supports both B42 API (CharacterStat.BOREDOM) and B41 fallback (getBoredom/setBoredom).
    B42: Stats:get/set(CharacterStat.BOREDOM) with 0.0-1.0 scale
    B41: Stats:getBoredom()/setBoredom() with 0.0-1.0 scale
]]
ServerCommands.ReduceBoredom = function(player, args)
    if not player then return end
    if not TAZC_Config.Boredom.enabled then return end
    
    local stats = TAZC_Core.safe(function() return player:getStats() end, nil)
    if not stats then
        dbg("ReduceBoredom: no stats for player")
        return
    end
    
    -- Calculate reduction (config is 0-100, convert to 0.0-1.0)
    local reductionPercent = TAZC_Config.Boredom.reductionAmount or 100
    local reduction = reductionPercent / 100
    
    -- Try B42 API first (CharacterStat.BOREDOM)
    local CharacterStat = CharacterStat or _G.CharacterStat
    if CharacterStat and CharacterStat.BOREDOM then
        local current = TAZC_Core.safe(function() return stats:get(CharacterStat.BOREDOM) end, nil)
        if current then
            local newVal = math.max(0, current - reduction)
            TAZC_Core.safe(function() stats:set(CharacterStat.BOREDOM, newVal) end, nil)
            dbg("ReduceBoredom (B42): %s %.3f -> %.3f (-%d%%)",
                TAZC_Core.safe(function() return player:getUsername() end, "?"),
                current, newVal, reductionPercent)
            return
        end
    end
    
    -- Fallback to B41 API (getBoredom/setBoredom)
    if stats.getBoredom and stats.setBoredom then
        local current = TAZC_Core.safe(function() return stats:getBoredom() end, nil)
        if current then
            local newVal = math.max(0, current - reduction)
            TAZC_Core.safe(function() stats:setBoredom(newVal) end, nil)
            dbg("ReduceBoredom (B41): %s %.3f -> %.3f (-%d%%)",
                TAZC_Core.safe(function() return player:getUsername() end, "?"),
                current, newVal, reductionPercent)
            return
        end
    end
    
    dbg("ReduceBoredom: no compatible API found")
end

--[[
    ServerCommands.GrantLanguage / ServerCommands.RevokeLanguage (v8.4)

    Client->server commands fired by the right-click context menu's
    "Languages >" submenu. Both forward to TAZC_LangCommands' shared
    runGrantNative/runRevokeNative cores -- the same admin gate, language
    validation, and response text as the /lang grant|revoke chat command,
    single-sourced (the two transports had drifted otherwise). This
    listener's own job is arg-shape defense only (C15: a malicious client
    can send anything).

    args:
      target   = string (username -- NOT forename; client sends the
                 IsoPlayer:getUsername() directly so no resolution needed)
      language = string (lowercase language id)
]]
ServerCommands.GrantLanguage = function(player, args)
    if not player or type(args) ~= "table" then return end
    local target   = args.target
    local language = args.language
    if type(target) ~= "string" or target == "" or type(language) ~= "string" or language == "" then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "GrantLanguage: missing target or language.",
            color = {255, 100, 100},
        })
        return
    end
    TAZC_LangCommands.runGrantNative(player, target, language)
end

ServerCommands.RevokeLanguage = function(player, args)
    if not player or type(args) ~= "table" then return end
    local target   = args.target
    local language = args.language
    if type(target) ~= "string" or target == "" or type(language) ~= "string" or language == "" then
        sendServerCommand(player, "TAZC", "SystemMessage", {
            message = "RevokeLanguage: missing target or language.",
            color = {255, 100, 100},
        })
        return
    end
    TAZC_LangCommands.runRevokeNative(player, target, language)
end

-- ============================================================================
-- FRESH-CHARACTER DETECTION (v8.16.2)
-- Language state is keyed by username, so it survives character death: a
-- re-rolled character walks in carrying everything the dead one earned.
-- When a brand-new character shows up on a username that still carries
-- language state, TAZC_Lang.handleFreshCharacter applies the policy
-- (TAZC_Config.Languages.deathReset: notify / auto / off).
--
-- Detection runs on every client command (one getHoursSurvived call on the
-- fast path -- same cost class as the getUsername in OnClientCommand's dbg
-- line). A character under FRESH_HOURS_WINDOW game-hours survived is
-- brand-new; a merely-reconnecting living character always has more, so a
-- living character can NEVER trip this. Two guards keep it from firing
-- twice for the same character: a session memo (re-armed only once the
-- character is seen past the window, i.e. effectively by the username's
-- NEXT character) and a per-character getModData stamp. B42 MP modData
-- persists unreliably (see the bio storage note above), but losing the
-- stamp only risks a repeat on a still-fresh character -- the hours gate
-- holds regardless.
-- ============================================================================

-- Brand-new means under this many game-hours survived. Wide enough to catch
-- the gap between spawn and the character's first client command (fresh
-- joins ping BioSyncAll at OnGameStart; mid-session respawns ping on their
-- first hear/type/say), narrow enough that an established character can
-- never trip it.
local FRESH_HOURS_WINDOW = 0.5

local FRESH_MARKER = "TAZC_FreshHandled"

local freshHandled = {}   -- [username] = true once the current character has
                          -- been through the full check this session

-- Any language state worth handling? A speaking choice, a native grant
-- beyond the english baseline, or any acquisition data (partial progress
-- included -- the same inventory /lang reset previews).
local function hasLanguageState(username)
    if TAZC_Lang.getLanguage(username) ~= "english" then return true end
    if #TAZC_Lang.getNativeLanguages(username) > 1 then return true end
    return #TAZC_Acquisition.languagesWithData(username) > 0
end

local function checkFreshCharacter(player)
    local username = TAZC_Core.safe(function() return player:getUsername() end, nil)
    if not username then return end

    local hours = TAZC_Core.safe(function() return player:getHoursSurvived() end, nil)
    if type(hours) ~= "number" then return end
    if hours >= FRESH_HOURS_WINDOW then
        -- Established character: nothing to do. Re-arm the memo so this
        -- username's NEXT character (mid-session death -> re-roll) is seen.
        freshHandled[username] = nil
        return
    end

    if freshHandled[username] then return end

    -- Per-character stamp: never fire twice for the same character, even
    -- across a reconnect. Missing modData = fail toward silence and retry
    -- on a later command (memo only sticks once modData is readable).
    local modData = TAZC_Core.safe(function() return player:getModData() end, nil)
    if type(modData) ~= "table" then return end
    freshHandled[username] = true
    if modData[FRESH_MARKER] then return end
    modData[FRESH_MARKER] = true

    if not hasLanguageState(username) then
        dbg("checkFreshCharacter: %s is fresh but carries no language state", username)
        return
    end

    dbg("checkFreshCharacter: fresh character for %s (%.2f hours survived), handing to TAZC_Lang",
        username, hours)
    -- handleFreshCharacter's own inner pcall only narrates to dbg, which is
    -- DEBUG-gated -- with debug off, an uncaught error here would otherwise
    -- vanish at every layer.
    local ok, err = pcall(TAZC_Lang.handleFreshCharacter, player)
    if not ok then
        print(string.format(
            "[TAZC][ERROR] handleFreshCharacter failed for '%s': %s",
            tostring(username), tostring(err)))
    end
end

-- ============================================================================
-- EVENT HOOKS
-- ============================================================================

local function OnClientCommand(module, command, player, args)
    if module ~= "TAZC" then return end

    dbg("OnClientCommand: %s from %s", command,
        TAZC_Core.safe(function() return player:getUsername() end, "nil"))

    -- Fresh-character detection: any command from a brand-new character on
    -- a username with carried-over language state hands off to TAZC_Lang.
    if player then checkFreshCharacter(player) end

    local handler = ServerCommands[command]
    if handler then
        local ok, err = pcall(handler, player, args)
        if not ok then
            print(string.format(
                "[TAZC][ERROR] client command '%s' failed: %s",
                tostring(command), tostring(err)))
        end
    else
        dbg("OnClientCommand: Unknown command: %s", tostring(command))
    end
end

local function OnServerStarted()
    -- Pull server's actual sandbox config into TAZC_Config.
    -- Before this, TAZC_Config holds the default fallbacks (module load precedes
    -- sandbox var population). Every ZombieAttraction/Boredom/OOC/range check
    -- in processMessage reads TAZC_Config, so reloading here is what makes
    -- admin-configured sandbox settings actually take effect.
    TAZC_Core.safe(function() TAZC_Config.reloadSandboxVars() end, nil)

    TAZC_Core.printBanner()
    dbg("=== SERVER MODULE LOADED ===")
    dbg("Ranges: whisper=%d, say=%d, yell=%d, low=%d", 
        TAZC_Config.Ranges.whisper, TAZC_Config.Ranges.say, TAZC_Config.Ranges.yell, TAZC_Config.Ranges.low)

    -- v8.16.1: acquisition profile. TAZC_Acquisition is engine-independent and
    -- can't read sandbox vars itself, so the server side pins the profile.
    TAZC_Acquisition.setProfile("live")

    -- v8.16.2: learning-speed knob (AcquisitionSpeed sandbox option),
    -- layered over the profile -- same injection rationale as above.
    local speed = (TAZC_Config.Acquisition and TAZC_Config.Acquisition.speed)
        or "default"
    TAZC_Acquisition.setSpeed(speed)
end

Events.OnClientCommand.Add(OnClientCommand)
Events.OnServerStarted.Add(OnServerStarted)

-- Internal contract: exposed for the offline harness (dispatch-guard tests).
TAZC_Server._ServerCommands = ServerCommands

-- Internal contract: exposed for the offline harness -- pins that this
-- table's actual key set agrees with TAZC_Core.SERVER_SLASH_COMMANDS, the
-- same array TAZC_Input.isMCServerCommand's forward check consumes.
TAZC_Server._SlashHandlers = SLASH_HANDLERS

-- ============================================================================
-- ACQUISITION ENGINE WIRING (composition root)
-- ============================================================================
-- TAZC_Acquisition is engine-pure -- no PZ globals, no Events access of its
-- own (docs/ARCHITECTURE.md, "Engine purity"). Its boot-time load/migrate
-- and its periodic disk flush are therefore registered HERE rather than
-- inside the engine, the same injection pattern as TAZC_Acquisition.setProfile/
-- setSpeed above and TAZC_Lang's setExposureTraceSink/setLapseNoticeSink: the
-- engine exposes named functions, the composition root decides when they run.
--
-- Ordering note: this fires after this file's own OnServerStarted (which
-- only reloads sandbox vars and pins the acquisition profile/speed --
-- neither reads nor writes the acquisition DB) and after the per-store
-- OnServerStarted hooks above (each an independent store keyed by
-- username, none of which touch acquisition data). No handler here depends
-- on another's having already run, so registering last is safe.
Events.OnServerStarted.Add(TAZC_Acquisition.onServerStarted)
Events.EveryOneMinute.Add(TAZC_Acquisition.onEveryOneMinute)

return TAZC_Server
