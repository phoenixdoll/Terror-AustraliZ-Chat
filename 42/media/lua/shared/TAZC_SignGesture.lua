--[[
================================================================================
    Terror AustraliZ Chat - Signing Gesture (pure cooldown/gating logic)

    A signed (ASL) message the LOCAL player just sent plays a hand-gesture
    emote on their own avatar -- presentation only, no gameplay reads it
    (see MONGOOSECHAT_DESIGN_NOTES.md "SIGNING GESTURES"). This module is
    the pure decision -- own-message check, modality check, channel-based
    gesture choice, config gating, and cooldown -- pulled out of
    TAZC_Client.lua's onChatMessage the same way TAZC_InputHistory.lua was
    pulled out of TAZC_Input.lua: the actual `character:playEmote()` call (a
    real IsoPlayer object, live-verify only) stays in that thin glue;
    everything decidable from plain values lives here, offline-testable.

    DETECTION SEAM (why this fires from onChatMessage, not TAZC_Input.send):
    the client has no pre-send cache of its own currently-selected
    language/modality -- TAZC_Server.lua computes msgData.modality from the
    speaker's persisted language state and stamps it once, unconditionally,
    onto every ChatMessage (TAZC_Server.lua's routeProximity, ~line 1419).
    The sender receives their OWN message back through the exact same
    "TAZC"."ChatMessage" server command every other receiver gets
    (TAZC_Client.lua's onChatMessage) -- msgData.username == the local
    player's username identifies it as an echo of what was just sent, the
    same self-check the boredom-reduction skip in that function already
    uses. That echo is therefore the real send seam: authoritative
    modality, no client-side guessing, and it lands the same tick as the
    send.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local TAZC_SignGesture = {}
TAZC_SignGesture.__index = TAZC_SignGesture

-- Signed speech channels only. emote/do/mood/ooc/etc. are narration or
-- meta chat, never signing -- and channels outside this set have no
-- modality concept at all (TAZC_Server never stamps one).
local SPEECH_CHANNELS = { say = true, whisper = true, low = true, yell = true }

--[[
    TAZC_SignGesture.new() -> tracker

    One tracker instance covers the local player for the whole client
    session -- there is only ever one local avatar to animate, so a single
    lastFireMs clock is all the state this needs.
]]
function TAZC_SignGesture.new()
    local self = setmetatable({}, TAZC_SignGesture)
    self.lastFireMs = -math.huge
    return self
end

--[[
    consider(nowMs, opts) -> emoteName, or nil (don't fire)

    opts:
      channel         - msgData.channel
      modality        - msgData.modality ("signed", or nil/anything else)
      isOwnMessage    - true only for the sender's own echoed message
      enabled         - config master toggle (sandbox SignGestureEnabled)
      cooldownMs      - minimum time between fires, read live each call so
                         a sandbox change takes effect without a relog
      gestureDefault  - emote name for say/whisper/low ("subtle" signing)
      gestureYell     - emote name for yell (sign-shout, "big" signing)

    Pure: reads/writes only this tracker's own lastFireMs, no game state
    touched. Every gate is independent; all must pass for a fire. On a
    real fire, lastFireMs advances to nowMs so the next call inside the
    cooldown window returns nil -- callers don't need to track cooldown
    themselves.
]]
function TAZC_SignGesture:consider(nowMs, opts)
    opts = opts or {}

    if not opts.enabled then return nil end
    if not opts.isOwnMessage then return nil end
    if opts.modality ~= "signed" then return nil end
    if not SPEECH_CHANNELS[opts.channel] then return nil end

    local cooldownMs = opts.cooldownMs or 5000
    if (nowMs - self.lastFireMs) < cooldownMs then return nil end

    local emote = (opts.channel == "yell") and opts.gestureYell or opts.gestureDefault
    if not emote or emote == "" then return nil end

    self.lastFireMs = nowMs
    return emote
end

return TAZC_SignGesture
