--[[
================================================================================
    Terror AustraliZ Chat - Configuration

    Central configuration for all Terror AustraliZ Chat modules. Shared between
    client and server - changes here affect both.

    CUSTOMIZATION:
    Server operators can configure via Sandbox Options in the game UI.
    For advanced settings not in sandbox, edit values below.
    See docs/ARCHITECTURE.md -- its own preamble explains why the old
    docs/TECHNICAL.md is gone rather than updated.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_Core = require("TAZC_Core")
local dbg = TAZC_Core.debugger("CONFIG")

local TAZC_Config = {}

-- ============================================================================
-- SANDBOX VARIABLE HELPERS
-- Read from SandboxVars when available, fall back to defaults
-- ============================================================================

local function getSandboxVar(name, default)
    if SandboxVars and SandboxVars.TAZC then
        local val = SandboxVars.TAZC[name]
        if val ~= nil then
            return val
        end
    end
    return default
end

--[[
    liveSandbox(name, default): read straight from SandboxVars.TAZC,
    bypassing this module's boot-time cache. MP's sandbox sync completes
    AFTER TAZC_Config's cache is captured at require() time, so a handful of
    client call sites (nameplate LOS mode/hide-own, bubble duration, bubble/
    typing toggles, anonymity, avatar mode) need a value that can be newer
    than the cache mid-session. Same fallback as the cache itself: `default`
    when SandboxVars, .Terror AustraliZ Chat, or the named field isn't there.
]]
TAZC_Config.liveSandbox = getSandboxVar

-- Enum sandbox options arrive as integers starting at 1 (see
-- BubbleAvatarMode below). Map to the string values the code uses;
-- a raw string is accepted too (offline harness / hand-set configs).
-- Anything absent or out of range falls back to the default.
local function getSandboxEnum(name, values, default)
    local val = getSandboxVar(name, nil)
    if type(val) == "number" then
        return values[val] or default
    end
    if type(val) == "string" then
        for _, v in ipairs(values) do
            if v == val then return val end
        end
    end
    return default
end

-- Enum value orders -- must match the sandbox-options definitions.
local DEATH_RESET_VALUES        = { "notify", "auto", "off" }
local ACQUISITION_SPEED_VALUES  = { "slow", "default", "fast" }
local BUBBLE_AVATAR_MODE_VALUES = { "model", "png", "off" }

-- Signing-gesture emote choices. Order matches the SignGestureDefault/
-- SignGestureYell enum options in sandbox-options.txt and their
-- Sandbox_EN.txt option labels -- all three lists must stay in lockstep.
-- Each string is a real vanilla emote name (ISEmoteRadialMenu.lua's
-- defaultMenu), playable via IsoGameCharacter:playEmote(name).
local SIGN_GESTURE_VALUES = {
    "shrug", "wavehi", "thankyou", "comehere", "stop",
    "salute", "surrender", "yes", "no", "thumbsup",
}

-- ============================================================================
-- SANDBOX VARIABLE SPECS
-- Single source of truth for every sandbox-backed TAZC_Config value. Each
-- entry below drives BOTH the boot-time defaults (applied once, near the
-- bottom of this file) and reloadSandboxVars() -- the exact same loop over
-- the exact same list, so the two paths can never drift apart again.
--
--   section    - TAZC_Config sub-table name, or nil for a top-level field
--   field      - key within that section (or within TAZC_Config itself)
--   sandboxKey - name under SandboxVars.TAZC
--   default    - fallback value (offline harness / SandboxVars absent)
--   enumValues - if set, resolved via getSandboxEnum instead of getSandboxVar
--   transform  - optional function(value) -> value, applied after resolution
-- ============================================================================

local SANDBOX_SPECS = {
    -- Proximity speech
    { section = "Ranges", field = "whisper", sandboxKey = "WhisperRange", default = 2 },
    { section = "Ranges", field = "say",     sandboxKey = "SayRange",     default = 15 },
    { section = "Ranges", field = "yell",    sandboxKey = "YellRange",    default = 60 },
    { section = "Ranges", field = "low",     sandboxKey = "LowRange",     default = 6 },

    -- Roleplay channels (derive from say range)
    { section = "Ranges", field = "emote", sandboxKey = "SayRange", default = 15 },
    { section = "Ranges", field = "do",    sandboxKey = "SayRange", default = 15 },

    -- Long-range roleplay channels: /melong and /dolong, same format and
    -- meaning as /me and /do, just carrying as far as a yell so a scene can
    -- be narrated/acted out across a wider area. Derive from yell range.
    { section = "Ranges", field = "emoteLong", sandboxKey = "YellRange", default = 60 },
    { section = "Ranges", field = "doLong",    sandboxKey = "YellRange", default = 60 },

    -- Meta channels (OOC derives from yell)
    { section = "Ranges", field = "ooc", sandboxKey = "YellRange", default = 60 },

    -- Admin event narration (v8.16.2). The storyteller's voice for
    -- long-range roleplay events: always DOUBLE the yell range, derived
    -- from the YellRange sandbox option so it scales with server
    -- configuration automatically -- no sandbox option of its own.
    -- (120 tiles at the default yell of 60.) Admin-gated in TAZC_Server.
    { section = "Ranges", field = "event", sandboxKey = "YellRange", default = 60,
      transform = function(v) return v * 2 end },

    -- Message length. Vanilla PZ caps its own chat box near 250;
    -- Terror AustraliZ Chat owns both the input box (client raises the box's max
    -- length to this) and the send path (server truncates past it), so
    -- this one sandbox value governs the real ceiling. Default 500; admins
    -- may raise it to 2000 for long emotes/narration.
    { section = nil, field = "MaxMessageLength", sandboxKey = "MaxMessageLength", default = 500 },

    -- Language acquisition -- v8.16.1 "Voices" addressedness heuristic.
    { section = "Lang", field = "addressedDistance", sandboxKey = "AddressedDistance", default = 6 },

    -- Language system master toggles
    { section = "Languages", field = "enabled",    sandboxKey = "LanguagesEnabled", default = true },
    { section = "Languages", field = "deathReset", sandboxKey = "LanguagesDeathReset",
      enumValues = DEATH_RESET_VALUES, default = "notify" },
    { section = "Acquisition", field = "speed", sandboxKey = "AcquisitionSpeed",
      enumValues = ACQUISITION_SPEED_VALUES, default = "default" },

    -- ASL (v1): the first per-language toggle, plus the Deaf-trait
    -- enforcement it depends on. Both read LIVE at their point of use
    -- (TAZC_LangCommands' speaking-language gate; TAZC_Anonymity.deafReception)
    -- rather than through the boot-time cache below -- same reasoning as
    -- Anonymity/Bubble: a server operator flipping either mid-session
    -- should take effect without a reconnect.
    { section = nil, field = "ASLEnabled",        sandboxKey = "ASLEnabled",        default = true },
    { section = nil, field = "DeafTraitEnforced",  sandboxKey = "DeafTraitEnforced", default = true },

    -- Speech bubbles
    { section = "Bubble", field = "enabled",  sandboxKey = "BubblesEnabled", default = true },
    { section = "Bubble", field = "duration", sandboxKey = "BubbleDuration", default = 5 },
    { section = "Bubble", field = "avatarMode", sandboxKey = "BubbleAvatarMode",
      enumValues = BUBBLE_AVATAR_MODE_VALUES, default = "model" },

    -- Typing indicators
    { section = "TypingIndicators", field = "enabled", sandboxKey = "TypingIndicatorsEnabled", default = true },

    -- Boredom reduction
    { section = "Boredom", field = "enabled",         sandboxKey = "BoredomReductionEnabled", default = true },
    { section = "Boredom", field = "reductionAmount", sandboxKey = "BoredomReductionAmount", default = 100 },

    -- Zombie attraction
    { section = "ZombieAttraction", field = "enabled", sandboxKey = "ZombieAttractionEnabled", default = true },

    -- Nameplates. visibility: 1 = Always (through walls), 2 = Line of Sight.
    -- Enum sandbox values are integers starting at 1. 2 = LOS is the current default.
    { section = "Nameplate", field = "enabled",    sandboxKey = "NameplatesEnabled", default = true },
    { section = "Nameplate", field = "hideOwn",    sandboxKey = "HideOwnNameplate", default = false },
    { section = "Nameplate", field = "visibility", sandboxKey = "NameplateVisibility", default = 2 },

    -- Anonymity
    { section = "Anonymity", field = "enabled", sandboxKey = "AnonymityEnabled", default = true },

    -- Channel toggles
    { section = "Channels", field = "oocEnabled", sandboxKey = "OOCEnabled", default = true },
    { section = "Channels", field = "allEnabled", sandboxKey = "ALLEnabled", default = true },

    -- Translation echo (8.9.13 ChannelHook). `enabled` is the master switch
    -- for the translator as PLAYERS see it (the /translate command and the
    -- live translation-echo); DEFAULT OFF. `echoEnabled` controls the live
    -- translation-echo specifically and requires `enabled` too; DEFAULT OFF
    -- (design principle: "safe default = babble").
    { section = "Translation", field = "enabled",     sandboxKey = "TranslationEnabled", default = false },
    { section = "Translation", field = "echoEnabled", sandboxKey = "TranslationEchoEnabled", default = false },

    -- Signing gestures (v1). cooldownMs stores the sandbox's seconds value
    -- as milliseconds -- TAZC_SignGesture.consider() works in ms (matches
    -- TAZC_Core.getTimeMs()).
    { section = "SignGesture", field = "enabled", sandboxKey = "SignGestureEnabled", default = true },
    { section = "SignGesture", field = "cooldownMs", sandboxKey = "SignGestureCooldown", default = 5,
      transform = function(v) return v * 1000 end },
    { section = "SignGesture", field = "gestureDefault", sandboxKey = "SignGestureDefault",
      enumValues = SIGN_GESTURE_VALUES, default = "shrug" },
    { section = "SignGesture", field = "gestureYell", sandboxKey = "SignGestureYell",
      enumValues = SIGN_GESTURE_VALUES, default = "surrender" },
}

-- ============================================================================
-- PROXIMITY RANGES
-- Distance in tiles for each chat channel. -1 = global/server-wide.
-- Sandbox-backed fields (whisper, say, yell, low, emote, do, ooc, event) are
-- populated from SANDBOX_SPECS above, applied by applySandboxDefaults() near
-- the bottom of this file. Static, non-sandbox fields only below.
-- ============================================================================

TAZC_Config.Ranges = {
    mood = 0,           -- Internal monologue, self only

    -- Meta channels (OOC derives from yell; see SANDBOX_SPECS above)
    all = -1,           -- Server-wide OOC (global)
    admin = -1,         -- Server-wide admin messages

    -- Group channels. No membership filtering exists yet, so TAZC_Server
    -- REJECTS these in processMessage (with sender feedback) rather than
    -- routing range -1 as a server-wide broadcast. Client prefixes still
    -- map them; entries stay -1 for when filtering lands.
    faction = -1,       -- Faction members only
    safehouse = -1,     -- Safehouse members only

    -- Radio (range handled by transmitter, not this table)
    radio = -1,
}

-- ============================================================================
-- MESSAGE LENGTH
-- MaxMessageLength is fully sandbox-backed; see SANDBOX_SPECS above. No
-- static declaration needed here -- applySandboxDefaults() sets it directly
-- on TAZC_Config.
-- ============================================================================

-- ============================================================================
-- LANGUAGE ACQUISITION (server-side heuristics)
-- addressedDistance is sandbox-backed; see SANDBOX_SPECS above. Proximity
-- speech heard from within this many tiles counts as addressed TO the
-- listener (full exposure weight); further out is overhearing (the
-- eavesdrop weight lives in TAZC_Acquisition). Conversational distance,
-- roughly the "low" speech range: stand with someone and you're in the
-- conversation; catch words across a room and you're eavesdropping.
-- Same-vehicle always counts as addressed regardless of this value.
-- ============================================================================

TAZC_Config.Lang = {}

-- ============================================================================
-- LANGUAGE SYSTEM (master toggles)
-- The RP language / babble system as a whole. Both fields sandbox-backed;
-- see SANDBOX_SPECS above.
--   enabled    - master switch for the language barrier system
--   deathReset - what happens when a brand-new character shows up on a
--                username that still carries language state from a
--                previous life:
--                  "notify" - tell them the old words carried over
--                  "auto"   - reset the carried-over state automatically
--                  "off"    - do nothing
-- ============================================================================

TAZC_Config.Languages = {}

-- speed: "slow" | "default" | "fast" -- sandbox-backed, see SANDBOX_SPECS above.
TAZC_Config.Acquisition = {}

-- ============================================================================
-- CHANNEL COLORS
-- RGB values 0-255 for each channel's text color
-- ============================================================================

TAZC_Config.ChannelColors = {
    -- Proximity speech
    whisper = {180, 180, 180},      -- Gray - quiet, subdued
    say = {255, 255, 255},          -- White - neutral, default
    yell = {255, 200, 50},          -- Yellow/Orange - attention-grabbing
    low = {150, 150, 150},          -- Darker gray - even more subdued

    -- Roleplay channels
    emote = TAZC_Core.Colors.EMOTE_AMBER, -- Soft amber/peach - warm action color
    emoteLong = TAZC_Core.Colors.EMOTE_AMBER, -- Same as /me -- only range differs
    ["do"] = {200, 180, 255},       -- Soft lavender - environmental/narrative
    doLong = {200, 180, 255},       -- Same as /do -- only range differs
    mood = TAZC_Core.Colors.MOOD_PURPLE,  -- Purple/lavender (AE6DB5)
    event = {235, 145, 205},        -- Orchid/rose - admin event narration

    -- Meta channels
    ooc = {100, 200, 255},          -- Light blue - clearly out of character
    all = {150, 220, 255},          -- Brighter blue - global OOC
    admin = {255, 100, 100},        -- Red - important, authority
    system = {255, 220, 100},       -- Gold/yellow - server messages, MOTD

    -- Group channels
    faction = {100, 255, 100},      -- Green - team color
    safehouse = {255, 200, 100},    -- Orange - home/safety color

    -- Radio
    radio = {120, 220, 200},        -- Teal/cyan - electronic/radio feel
}

-- ============================================================================
-- CHANNEL DISPLAY TAGS
-- Text shown before messages in chat panel. Empty string = no tag.
-- Note: "radio" tag is generated dynamically with frequency (e.g., "[98.6 MHz]")
-- ============================================================================

TAZC_Config.ChannelTags = {
    whisper = "[whisper]",
    say = "[say]",
    yell = "[YELL]",
    low = "[low]",
    emote = "",                     -- Format: *Name action*
    emoteLong = "",                 -- Format: *Name action*, same as /me
    ["do"] = "",                    -- Format: just the narration text
    doLong = "",                    -- Format: just the narration text, same as /do
    mood = "",                      -- Format: internal thought
    event = "[Event]",              -- Admin event narration (TAZC_Server scrubs the name)
    ooc = "[OOC]",
    all = "[ALL]",
    admin = "[ADMIN]",
    system = "",                     -- No tag, just "[SERVER]" as charName
    faction = "[faction]",
    safehouse = "[safehouse]",
    radio = "[RADIO]",              -- Fallback; actual tag includes MHz
}

-- ============================================================================
-- RADIO SETTINGS
-- ============================================================================

TAZC_Config.Radio = {
    -- Texture set for radio speech bubbles (see common/media/ui/TAZC/bubble/)
    bubbleStyle = "radio",

    -- Texture set for proximity speech bubbles
    speechBubbleStyle = "simple",
}

-- ============================================================================
-- SPEECH BUBBLE SETTINGS
-- enabled, duration, avatarMode are sandbox-backed; see SANDBOX_SPECS above.
--   avatarMode fills the little portrait box in speech bubbles:
--     "model" - the speaker's 3D character model (current behavior)
--     "png"   - the speaker's admin-approved custom portrait, falling
--               back to the 3D model when they haven't set one (and
--               ALWAYS falling back for masked speakers -- a custom
--               image identifies a player harder than a name)
--     "off"   - no portrait box at all
-- ============================================================================

TAZC_Config.Bubble = {
    -- Bubble background opacity (0.0 - 1.0)
    opacity = 0.9,

    -- Maximum bubble width in pixels before word wrap
    maxWidth = 200,

    -- Fade out duration at end of bubble life (seconds)
    fadeTime = 1.0,

    -- Show Steam avatar in speech bubbles (not emotes/radio)
    showAvatar = true,

    -- Texture set for a SIGNED-modality speech bubble (see
    -- common/media/ui/TAZC/bubble/) -- style resolution gains this
    -- modality case beside TAZC_Config.Radio's per-channel choice above.
    signStyle = "sign",
}

-- ============================================================================
-- TYPING INDICATOR SETTINGS
-- Animated dots above players who are typing.
-- enabled is sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.TypingIndicators = {}

-- ============================================================================
-- CHAT PANEL SETTINGS
-- ============================================================================

TAZC_Config.Panel = {
    -- Maximum messages kept in history buffer (per tab)
    maxMessages = 100,

    -- Wrap-width fallback when the panel reports an unreasonably narrow
    -- width (TAZC_ChatPanel.lua ~669) -- not a panel dimension itself.
    defaultWidth = 400,

    -- Margin around text content
    margin = 8,

    -- Timestamp format (strftime compatible)
    timestampFormat = "[%H:%M]",
}

-- ============================================================================
-- BOREDOM REDUCTION
-- Listening to chat reduces boredom (rewards RP engagement)
-- Both settings sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.Boredom = {}

-- ============================================================================
-- ZOMBIE ATTRACTION
-- Speaking attracts zombies based on channel volume.
-- enabled is sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.ZombieAttraction = {}

-- ============================================================================
-- NAMEPLATE SETTINGS
-- Character name and tagline display above players.
-- All three fields sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.Nameplate = {}

-- ============================================================================
-- ANONYMITY
-- Distance/mask based name hiding for roleplay
-- enabled is sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.Anonymity = {}

-- ============================================================================
-- CHANNEL TOGGLES
-- Enable/disable specific chat channels.
-- Both fields sandbox-backed; see SANDBOX_SPECS above.
-- ============================================================================

TAZC_Config.Channels = {}

-- ============================================================================
-- TRANSLATION ECHO (8.9.13 ChannelHook)
-- OOC English<->Turkish TRANSLATOR feature (separate from the IC RP language /
-- babble system, which is unaffected by these flags). Both fields
-- sandbox-backed; see SANDBOX_SPECS above for defaults and rationale.
-- ============================================================================

TAZC_Config.Translation = {}

-- ============================================================================
-- SIGNING GESTURES (v1)
-- A signed (ASL) message the local player sends plays a hand-gesture emote
-- on their own avatar -- presentation only (MONGOOSECHAT_DESIGN_NOTES.md
-- "SIGNING GESTURES"). All four fields sandbox-backed; see SANDBOX_SPECS
-- above.
--   enabled        - master toggle
--   cooldownMs     - minimum time between fires, in milliseconds
--   gestureDefault - emote name for say/whisper/low (subtle)
--   gestureYell    - emote name for yell / sign-shout (big, emphatic)
-- Decision logic (own-message check, modality, cooldown) lives in the pure
-- shared/TAZC_SignGesture.lua; client/TAZC_Client.lua is the thin glue that
-- calls it and fires the real playEmote().
-- ============================================================================

TAZC_Config.SignGesture = {}

-- ============================================================================
-- SERVER-SIDE LOGGING
-- For MongooseBot integration and audit trails
-- ============================================================================

TAZC_Config.Log = {
    -- Enable/disable file logging
    enabled = true,

    -- Log file directory (relative to Zomboid user folder)
    path = "TAZC/logs/",

    -- Output structured JSON (for bot parsing) vs plain text
    jsonFormat = true,
}

-- ============================================================================
-- SANDBOX VAR RELOAD
-- TAZC_Config is require()'d at startup, BEFORE SandboxVars is populated from
-- the server in MP. applySandboxDefaults() below seeds every sandbox-backed
-- field (SANDBOX_SPECS) with its fallback default at load time.
--
-- To pick up the server's actual sandbox configuration, reloadSandboxVars()
-- must be called after the sandbox sync completes. This happens in:
--   - Server:  Events.OnServerStarted  (see TAZC_Server.lua)
--   - Client:  Events.OnGameStart + Events.OnConnected  (see TAZC_Client.lua)
--
-- It is safe to call multiple times. getSandboxVar gracefully falls back to
-- defaults if SandboxVars.TAZC is not yet populated. Both the
-- initial load and reloadSandboxVars() run the exact same loop over
-- SANDBOX_SPECS, so the two paths cannot drift apart.
-- ============================================================================

local function applySandboxDefaults()
    for _, spec in ipairs(SANDBOX_SPECS) do
        local value
        if spec.enumValues then
            value = getSandboxEnum(spec.sandboxKey, spec.enumValues, spec.default)
        else
            value = getSandboxVar(spec.sandboxKey, spec.default)
        end
        if spec.transform then
            value = spec.transform(value)
        end
        local target = spec.section and TAZC_Config[spec.section] or TAZC_Config
        target[spec.field] = value
    end
end

-- Apply boot-time defaults now (SandboxVars is not yet populated at
-- require() time, so this seeds every sandbox-backed field with its
-- fallback default).
applySandboxDefaults()

function TAZC_Config.reloadSandboxVars()
    applySandboxDefaults()

    dbg("Sandbox vars reloaded: BubbleDuration=%s, SayRange=%s, BubblesEnabled=%s, Anon=%s",
        tostring(TAZC_Config.Bubble.duration),
        tostring(TAZC_Config.Ranges.say),
        tostring(TAZC_Config.Bubble.enabled),
        tostring(TAZC_Config.Anonymity.enabled))
end

-- ============================================================================

dbg("Configuration loaded")

return TAZC_Config
