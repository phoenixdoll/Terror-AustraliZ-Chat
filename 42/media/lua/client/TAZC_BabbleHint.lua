--[[
================================================================================
    Terror AustraliZ Chat - Babble First-Contact Hint

    Pure decision logic for the one-time "you're hearing babble" onboarding
    hint (see TAZC_Client.onChatMessage for where this gets wired to the real
    chat panel + player modData). Deliberately has NO top-level PZ API calls
    and NO requires of UI-deriving modules, so -- unlike TAZC_Client itself --
    it loads under the offline test harness (devtools/tests_offline).

    THE SIGNAL: TAZC_Server additively sets msgData.babbled = true exactly when
    an utterance carried a real language (the speaker wasn't speaking
    English) AND this specific listener wasn't given the language tag (not
    native, hasn't identified it yet) -- i.e. genuinely unlabeled babble for
    THIS receiver. It is never set on the speaker's own echo. See TAZC_Server's
    sendChatToReceiver for the additive flag itself.

    THE ONCE-FLAG: consumeOnce() takes an injected store table (the real
    caller passes the local player's getModData() table -- the same
    per-character-stamp idiom TAZC_Server's checkFreshCharacter already uses
    for the fresh-character notice) so the once-logic is testable without
    touching any PZ API.
================================================================================
]]

local TAZC_BabbleHint = {}

-- Key written into the per-character modData table once the hint has fired.
TAZC_BabbleHint.MARKER = "TAZC_BabbleHintSeen"

--[[
    Does this incoming message qualify as a first-contact babble moment for
    localUsername? Pure predicate, no state touched.

    @param msgData        the (per-receiver) message table the client got
    @param localUsername  the local player's username
    @return boolean
]]
function TAZC_BabbleHint.isQualifyingBabble(msgData, localUsername)
    if type(msgData) ~= "table" then return false end
    if not msgData.babbled then return false end
    if localUsername and msgData.username == localUsername then return false end
    return true
end

--[[
    Once-per-character consumption against an injected store (shaped like
    player:getModData() -- a plain table). Returns true (and marks the store
    consumed) the FIRST time it is called against a fresh store; false on
    every subsequent call with the same store.

    A non-table store (modData unavailable this tick) fails toward NOT
    firing, matching TAZC_Server.checkFreshCharacter's own fail-toward-silence
    rule for the same class of per-character stamp.

    @param store table|nil
    @return boolean
]]
function TAZC_BabbleHint.consumeOnce(store)
    if type(store) ~= "table" then return false end
    if store[TAZC_BabbleHint.MARKER] then return false end
    store[TAZC_BabbleHint.MARKER] = true
    return true
end

--[[
    The single entry point the client wires in: true exactly once per
    character, on the first qualifying babbled message; false every other
    time (including every non-babble message, every message that's the
    listener's own speech, and every subsequent babbled message).

    @param msgData        the (per-receiver) message table the client got
    @param localUsername  the local player's username
    @param store           table|nil, the per-character once-flag store
    @return boolean
]]
function TAZC_BabbleHint.shouldFire(msgData, localUsername, store)
    if not TAZC_BabbleHint.isQualifyingBabble(msgData, localUsername) then
        return false
    end
    return TAZC_BabbleHint.consumeOnce(store)
end

return TAZC_BabbleHint
