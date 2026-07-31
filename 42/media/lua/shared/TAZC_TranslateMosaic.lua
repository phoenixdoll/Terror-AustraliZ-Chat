--[[
================================================================================
    Terror AustraliZ Chat - Mosaic Translation Wrapper (9.0+)
================================================================================
    
    Wraps the lower-level T.translate() with clause-level processing and
    graceful English fallback for any clause the engine can't handle
    cleanly. The output is a mix of Turkish (for clauses that compose)
    and original English (for clauses that don't) -- a mosaic.
    
    Why this layer exists:
        The corpus analysis showed only ~8% of natural chat translates
        fully clean and ~33% half-leaks. Path B (per the architecture
        decision) accepts that natural English chat is too complex for
        100% coverage and instead emits whatever the engine CAN compose,
        passing the rest through as English. The user sees usable Turkish
        where it's available without garbled mid-sentence stitching.
    
    How it works:
        1. Split the input into clauses on sentence-end punctuation
           (. ! ?) and clause separators (, ;).
        2. Process each clause through T.translate.
        3. Per clause, compute coverage = (resolved tokens) / (total tokens).
        4. If coverage >= MOSAIC_THRESHOLD, emit Turkish output.
        5. Else emit the original English clause verbatim.
        6. Reassemble with original separators.
    
    Public API:
        Mosaic.translate(input) -> {
            output      = string,      -- the mosaic
            clauses     = { ... },     -- per-clause results
            coverage    = number,      -- 0..1 across the whole input
            turkish_pct = number,      -- fraction of clauses emitted Turkish
            errors      = { ... },
        }
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local Translate = require("TAZC_Translate")

local Mosaic = {}

-- 9.1.4+ recursion-depth guard. Pattern J recursively calls
-- Mosaic.translate to compose with Pattern G/H (so "I think there are
-- no zombies" -> "Sanırım zombi yok" not "Sanırım zombiler var").
-- The guard prevents infinite recursion via a counter; max depth 3 is
-- generous for naturally-occurring nested matrix verbs ("I think she
-- said that he hopes...") while still finite.
Mosaic._depth = 0
Mosaic._MAX_DEPTH = 3

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

-- Coverage threshold below which we passthrough as English. 0.7 means
-- "at least 70% of tokens in the clause must have resolved to a known
-- role for us to emit Turkish."
-- 9.0+ Mosaic: clause-acceptance threshold. Below this fraction of
-- tokens-resolved, the clause emits as English passthrough. Tuned by
-- corpus experiment: 0.6 admits short clauses with one stuck word
-- ("Güçlü allies" mixed > "strong allies" pure-English for a TR
-- reader) while still rejecting near-passthroughs. Previously 0.7
-- but that was wasting 300+ chat clauses where the engine produced
-- usable output. Lower bound is judgment — go too low and we emit
-- English-with-cosmetic-Turkish, which is worse than passthrough.
Mosaic.MOSAIC_THRESHOLD = 0.6

-- Minimum token count for a clause to be worth processing. Sub-threshold
-- fragments are emitted as English without engine round-trip.
Mosaic.MIN_CLAUSE_TOKENS = 1

-- ---------------------------------------------------------------------------
-- Clause splitter
-- ---------------------------------------------------------------------------

-- Splits an input string into clauses with their following separators.
-- Returns { { text = "...", sep = ",", endOfSentence = false }, ... }
-- The last clause's sep is the sentence-final terminator (or "" if none).
--
-- Strategy:
--   * Strong separators (. ! ?) end the sentence.
--   * Soft separators (, ;) split within a sentence.
--   * Newlines are treated as sentence breaks.
--   * Whitespace around separators is preserved as part of the separator
--     so reassembly produces output indistinguishable from the input
--     spacing-wise.
--
-- Edge cases handled:
--   * Ellipses (... or ..) treated as ONE terminator, not three sentence ends.
--   * Decimal numbers ("3.14") -- v1 punt: any "." not followed by space
--     stays in the clause.
--   * Trailing whitespace: collapsed.
function Mosaic.splitClauses(input)
    local clauses = {}
    if not input or input == "" then return clauses end

    -- 9.0+ Mosaic: semicolon-as-apostrophe normalize. Must happen here,
    -- before clause-splitting on ";", otherwise "i;ve seen you" splits
    -- into two clauses ("i" and "ve seen you") instead of expanding to
    -- "i've seen you" -> "i have seen you". Intra-word `;` (letter-on-
    -- both-sides) is always a typo for apostrophe; legitimate semicolons
    -- have whitespace around them.
    input = input:gsub("(%a);(%a)", "%1'%2")

    -- 9.0+ Mosaic: collapse repeated identical tokens for emphasis. Chat
    -- patterns like "no no no", "ha ha ha", "stop stop stop", "yes yes
    -- yes" repeat a word for emotional emphasis. The semantic content is
    -- one occurrence; the repetition is a register marker. Collapse runs
    -- of 3+ identical tokens to a single token, then insert a comma so
    -- the collapsed interjection becomes its own clause when the
    -- original had no terminator (e.g. "no no no i jacked it" -> "no, i
    -- jacked it"). 2-token repeats are sometimes intentional ("good
    -- good" = "very good") so we're conservative — 3+ only.
    do
        local words = {}
        for w in input:gmatch("%S+") do table.insert(words, w) end
        local collapsed = {}
        local i = 1
        while i <= #words do
            local wl = words[i]:lower():gsub("[%.,!%?;:]+$", "")
            local runLen = 1
            for j = i + 1, #words do
                local wjl = words[j]:lower():gsub("[%.,!%?;:]+$", "")
                if wjl == wl then
                    runLen = runLen + 1
                else
                    break
                end
            end
            if runLen >= 3 then
                local last = words[i + runLen - 1]
                local hasPunct = last:match("[%.,!%?;:]+$")
                if hasPunct then
                    table.insert(collapsed, last)
                else
                    table.insert(collapsed, last .. ",")
                end
                i = i + runLen
            else
                table.insert(collapsed, words[i])
                i = i + 1
            end
        end
        input = table.concat(collapsed, " ")
    end

    -- 9.0+ Mosaic: vocative-split for sentence-final "my X" / "your X"
    -- address patterns. In chat, vocatives ("my son", "my friend", "my
    -- lord", "my brother") often appear at sentence end without a
    -- preceding comma. Without splitting, the engine treats them as a
    -- second NP after the main clause's NP and fails to assign roles
    -- (POSS goes UNKNOWN). Inserting a comma forces a clause boundary
    -- so "my son" translates as a vocative on its own.
    --
    -- Conservative: only fires when (a) the pattern is at the end of
    -- the input (or before terminator), (b) the text before is at least
    -- 5 chars (so we don't disrupt very short utterances), (c) the X
    -- after POSS is a single alphabetic word (not a longer NP).
    do
        -- Lua patterns don't support |-alternation, so iterate POSS words.
        local Lexicon = require("TAZC_TranslateLexicon")
        local POSS_WORDS = {"my", "your", "his", "her", "their", "our"}
        for _, poss in ipairs(POSS_WORDS) do
            -- Match " poss X" at end (possibly with trailing punct)
            local before, x, term = input:match(
                "^(.-)%s+" .. poss .. "%s+(%a+)([%s%.,!%?;:]*)$")
            if before and #before >= 5 and term then
                if before:find("%s") and #x <= 12 then
                    -- Look at the immediately-preceding word: suppress
                    -- the split when its POS shows POSS-NP is a syntactic
                    -- argument, not a vocative.
                    --   VERB     -> POSS-NP is direct object ("I love my son")
                    --   PREP     -> POSS-NP is PP head ("of your own")
                    --   AUX/MODAL -> POSS-NP is predicate ("was my spare")
                    --   DET/POSS -> POSS-NP is genitive ("the my X")
                    --   CONJ     -> POSS-NP continues a coordinated NP
                    --   PRON (after DITRANS-VERB) -> POSS-NP is theme in a
                    --              ditransitive ("Give me my keys" —
                    --              recipient-pron + theme-NP, not vocative).
                    --              8.16.x: tighter than "any PRON" so
                    --              "thank you my friend" still vocative-splits.
                    local DITRANS_BEFORE_PRON = {
                        give=true, bring=true, show=true, tell=true,
                        send=true, hand=true, pass=true, throw=true,
                        sell=true, pay=true, offer=true, lend=true,
                        gave=true, brought=true, showed=true, told=true,
                        sent=true, handed=true, passed=true, threw=true,
                        sold=true, paid=true, offered=true, lent=true,
                        gives=true, brings=true, shows=true, tells=true,
                        sends=true, hands=true, passes=true, throws=true,
                        sells=true, pays=true, offers=true, lends=true,
                    }
                    local lastWord = before:match("(%a+)%s*$")
                    local prevBlocksSplit = false
                    if lastWord then
                        local entries = Lexicon.lookupAll(lastWord:lower()) or {}
                        for _, e in ipairs(entries) do
                            if e.pos == "VERB" or e.pos == "PREP"
                                or e.pos == "AUX" or e.pos == "MODAL"
                                or e.pos == "DET" or e.pos == "POSS"
                                or e.pos == "CONJ" then
                                prevBlocksSplit = true
                                break
                            end
                            if e.pos == "PRON" then
                                -- Check verb-before-PRON. If ditransitive,
                                -- this is a theme NP, not vocative.
                                local rest = before:sub(1,
                                    #before - #lastWord):match("(.-)%s*$")
                                local verbBeforePron = rest
                                    and rest:match("(%a+)%s*$")
                                if verbBeforePron and
                                   DITRANS_BEFORE_PRON[verbBeforePron:lower()] then
                                    prevBlocksSplit = true
                                end
                                break
                            end
                        end
                    end
                    if not prevBlocksSplit then
                        input = before .. ", " .. poss .. " " .. x .. term
                        break  -- one rewrite per input
                    end
                end
            end
        end
    end

    -- Normalize multi-dot terminators to a single token so we don't split
    -- "..." into three boundaries.
    local working = input:gsub("%.%.%.+", "\1ELLIPSIS\1")
    working = working:gsub("%.%.", "\1ELLIPSIS\1")

    -- 9.0+ Mosaic: soft-split on subordinating/coordinating conjunctions
    -- (but / so / because). These mark clause boundaries that the engine
    -- doesn't compose across well, and splitting on them lets each
    -- clause try to translate independently. The conjunction is preserved
    -- in the separator so reassembly looks like the original.
    --
    -- Word-boundary match: " but " not "butter", " so " not "soap",
    -- " because " not "becausefoo". We use \1WORD\1 placeholders to mark
    -- the split points without confusing the per-character scan below.
    local function softSplitConj(s, conj)
        return s:gsub("(%s+)(" .. conj .. ")(%s+)", function(pre, c, post)
            return pre .. "\1CONJ_BREAK\1" .. c .. post
        end)
    end
    -- Words that, when following a conjunction, indicate the clause that
    -- starts is a question/inverted construction (helps decide whether a
    -- given conjunction is a real clause boundary in chat).
    local AUX_INDICATORS = {
        ["did"] = true, ["do"] = true, ["does"] = true,
        ["will"] = true, ["can"] = true, ["could"] = true,
        ["should"] = true, ["would"] = true, ["might"] = true,
        ["may"] = true, ["must"] = true, ["shall"] = true,
        ["have"] = true, ["has"] = true, ["had"] = true,
        ["is"] = true, ["are"] = true, ["was"] = true, ["were"] = true,
        ["am"] = true,
    }
    working = softSplitConj(working, "but")
    -- 9.1.3+: conditional "and" split. "and" is dangerous to split
    -- unconditionally (would split "bread and butter" into pieces).
    -- Only split when "and" is followed by a subject pronoun (I/you/
    -- he/she/it/we/they/there) — that's a strong signal it's connecting
    -- clauses, not noun phrases. Misses cases like "and the X did Y"
    -- but those are rare; preserving NP integrity matters more.
    local function softSplitAnd(s)
        return s:gsub("(%s+)(and)(%s+)(%a+)", function(pre, c, post, nextWord)
            local nw = nextWord:lower()
            if nw == "i" or nw == "you" or nw == "he" or nw == "she"
               or nw == "it" or nw == "we" or nw == "they"
               or nw == "there"
            then
                return pre .. "\1CONJ_BREAK\1" .. c .. post .. nextWord
            end
            return nil  -- preserves original match
        end)
    end
    working = softSplitAnd(working)
    -- 9.0+ Mosaic: 'so' was unconditionally split. But "so" is bimodal:
    --   * CONJ ("X happened, so I did Y") -> real clause boundary
    --   * intensifier ADV ("not so old", "so tired") -> word modifier
    -- The intensifier form is common in chat fragments and must NOT
    -- split. Heuristic: "so" preceded by NEG ("not so X") is always
    -- intensifier. "so" preceded by other ADV/ADJ-zone tokens at
    -- sentence start ("So tired") is also intensifier. Default to
    -- splitting (CONJ reading) but skip these specific patterns.
    local function softSplitSo(s)
        -- Skip cases: "not so X", "so X" at sentence start where X is
        -- an adjective. Conservative: only skip "not so", lean on the
        -- engine to handle the rest correctly.
        return s:gsub("(%s+)(so)(%s+)(%S+)",
            function(pre, c, post, nextWord)
                -- Look at what comes before this match in s for "not"
                local idx_so = s:find(pre .. c .. post .. nextWord, 1, true)
                if idx_so then
                    local before = s:sub(1, idx_so - 1)
                    -- Last word in `before` (case-insensitive)
                    local lastWord = before:match("(%S+)%s*$")
                    if lastWord then
                        local lw = lastWord:lower():gsub("[%.,!%?;:]+$", "")
                        if lw == "not" then
                            -- intensifier, don't split
                            return pre .. c .. post .. nextWord
                        end
                    end
                end
                return pre .. "\1CONJ_BREAK\1" .. c .. post .. nextWord
            end)
    end
    working = softSplitSo(working)
    working = softSplitConj(working, "because")
    working = softSplitConj(working, "cause")  -- chat-speak for "because"
    -- 9.0+: 'or' is bimodal — it's a CLAUSE boundary in cases like
    -- "Do you need X or are you good?" but a WORD coordination in
    -- "ammo or food", "she runs or walks". Default: don't split, so
    -- word/VP coordination keeps working through Pass 2.7. Override:
    -- split when 'or' is immediately followed by an AUX/MODAL/AUX_DO
    -- (the new clause is a question with subject-aux inversion). The
    -- helper below inverts the AUX-guard from the when/if case.
    local function softSplitOrClause(s)
        return s:gsub("(%s+)(or)(%s+)(%S+)",
            function(pre, c, post, nextWord)
                local lc = nextWord:lower():gsub("[%.,!%?;:]+$", "")
                if AUX_INDICATORS[lc] then
                    return pre .. "\1CONJ_BREAK\1" .. c .. post .. nextWord
                end
                return pre .. c .. post .. nextWord
            end)
    end
    working = softSplitOrClause(working)
    -- 9.0+ continued: also split on subordinators "when" and "if". These
    -- introduce temporal/conditional clauses that the engine doesn't
    -- compose across; splitting lets each side try to translate
    -- independently, with the conjunction preserved in the separator.
    --   "I will run when I see them"
    --   -> clause1 "I will run" / sep " when " / clause2 "I see them"
    --   "If you're tired, rest"
    --   -> clause1 "If you're tired" / sep "," / clause2 "rest"
    --
    -- IMPORTANT exclusion: when "when" or "if" is followed by an
    -- auxiliary verb (did/do/will/can/etc.), it's not a subordinator —
    -- it's a WH-interrogative or an embedded question. Splitting here
    -- would strand the WH word in the separator and the engine would
    -- never see it. We check the IMMEDIATELY-NEXT content word and skip
    -- the split if it's auxiliary-shaped.
    local function softSplitConjGuarded(s, conj)
        return s:gsub("(%s+)(" .. conj .. ")(%s+)(%S+)",
            function(pre, c, post, nextWord)
                local lc = nextWord:lower():gsub("[%.,!%?;:]+$", "")
                if AUX_INDICATORS[lc] then
                    -- Interrogative use — leave the string intact.
                    return pre .. c .. post .. nextWord
                end
                return pre .. "\1CONJ_BREAK\1" .. c .. post .. nextWord
            end)
    end
    working = softSplitConjGuarded(working, "when")
    working = softSplitConjGuarded(working, "if")

    local i = 1
    local buf = ""
    local n = #working
    while i <= n do
        local c = working:sub(i, i)
        -- Ellipsis placeholder acts as sentence terminator.
        if working:sub(i, i + 9) == "\1ELLIPSIS\1" then
            if buf:match("%S") then
                table.insert(clauses, {
                    text          = buf:match("^%s*(.-)%s*$"),
                    sep           = "\1ELLIPSIS\1",
                    endOfSentence = true,
                })
                buf = ""
            elseif #clauses > 0 then
                clauses[#clauses].sep = clauses[#clauses].sep .. "\1ELLIPSIS\1"
                clauses[#clauses].endOfSentence = true
            else
                -- Ellipsis with no preceding text — emit as its own clause.
                table.insert(clauses, {
                    text          = "",
                    sep           = "\1ELLIPSIS\1",
                    endOfSentence = true,
                })
            end
            i = i + 10  -- length of \1ELLIPSIS\1
            -- Consume following whitespace as part of the separator
            while i <= n and working:sub(i, i):match("%s") do
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. working:sub(i, i)
                end
                i = i + 1
            end
        -- 9.0+ Mosaic: subordinating/coordinating CONJ_BREAK marker.
        elseif working:sub(i, i + 11) == "\1CONJ_BREAK\1" then
            -- The conjunction word follows the marker; we want to keep it
            -- as part of the separator. Scan forward to find where the
            -- conjunction word ends.
            i = i + 12  -- past \1CONJ_BREAK\1
            local conjStart = i
            while i <= n and not working:sub(i, i):match("%s") do
                i = i + 1
            end
            local conjWord = working:sub(conjStart, i - 1)
            -- Emit the clause-so-far with " {conj} " as its separator.
            -- The separator keeps the conjunction visible in the output.
            local sep = " " .. conjWord
            if buf:match("%S") then
                table.insert(clauses, {
                    text          = buf:match("^%s*(.-)%s*$"),
                    sep           = sep,
                    endOfSentence = false,
                })
                buf = ""
            else
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. sep
                end
            end
            -- Consume the whitespace after the conjunction
            while i <= n and working:sub(i, i):match("%s") do
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. working:sub(i, i)
                end
                i = i + 1
            end
        -- Sentence-end punctuation
        elseif c == "." or c == "!" or c == "?" then
            -- Collect runs of ! and ? together (e.g., "?!", "!!")
            local runStart = i
            while i <= n do
                local cc = working:sub(i, i)
                if cc == "!" or cc == "?" or cc == "." then
                    i = i + 1
                else break end
            end
            local sep = working:sub(runStart, i - 1)
            if buf:match("%S") then
                table.insert(clauses, {
                    text          = buf:match("^%s*(.-)%s*$"),
                    sep           = sep,
                    endOfSentence = true,
                })
                buf = ""
            else
                -- Punctuation with no clause text before it -- attach to
                -- previous clause's separator if any.
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. sep
                    clauses[#clauses].endOfSentence = true
                end
            end
            -- Consume following whitespace as part of the separator
            while i <= n and working:sub(i, i):match("%s") do
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. working:sub(i, i)
                end
                i = i + 1
            end
        elseif c == "," or c == ";" then
            -- Soft boundary within a sentence
            if buf:match("%S") then
                table.insert(clauses, {
                    text          = buf:match("^%s*(.-)%s*$"),
                    sep           = c,
                    endOfSentence = false,
                })
                buf = ""
            else
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. c
                end
            end
            i = i + 1
            -- Consume following whitespace as part of the separator
            while i <= n and working:sub(i, i):match("%s") do
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. working:sub(i, i)
                end
                i = i + 1
            end
        elseif c == "\n" then
            -- Newline as sentence boundary
            if buf:match("%S") then
                table.insert(clauses, {
                    text          = buf:match("^%s*(.-)%s*$"),
                    sep           = "\n",
                    endOfSentence = true,
                })
                buf = ""
            else
                if #clauses > 0 then
                    clauses[#clauses].sep = clauses[#clauses].sep .. "\n"
                end
            end
            i = i + 1
        else
            buf = buf .. c
            i = i + 1
        end
    end

    -- Trailing buffer without terminator
    if buf:match("%S") then
        table.insert(clauses, {
            text          = buf:match("^%s*(.-)%s*$"),
            sep           = "",
            endOfSentence = true,
        })
    end

    -- Restore ellipses
    for _, cl in ipairs(clauses) do
        cl.text = cl.text:gsub("\1ELLIPSIS\1", "...")
        cl.sep  = cl.sep:gsub("\1ELLIPSIS\1", "...")
    end

    -- 9.0+ Mosaic: merge stranded-modal clauses. When an ellipsis (or
    -- comma/semicolon) sits between a modal and its verb — "I'll...
    -- grab something" — the splitter strands the modal in its own
    -- clause where it can't translate. The result is "I'll..." stays
    -- English while "Bir şeyi kap" succeeds. Worse, the modal-future
    -- meaning is lost.
    --
    -- Heuristic: if a clause's text contains only modal-shaped tokens
    -- (pronouns, modals, 'll/'d/'ve contractions, auxes), merge it
    -- INTO the next clause by prepending the text and absorbing its
    -- separator. The MIN-CLAUSE check is the same content-emptiness
    -- signal so we lean on it.
    local STRANDED_TOKEN = {
        ["i"]=true, ["you"]=true, ["he"]=true, ["she"]=true,
        ["we"]=true, ["they"]=true, ["it"]=true,
        -- 'm/'re/'s contractions (i'm/you're/he's/she's/it's etc)
        ["i'm"]=true, ["im"]=true,
        ["you're"]=true, ["youre"]=true,
        ["he's"]=true, ["she's"]=true, ["it's"]=true, ["that's"]=true,
        ["we're"]=true, ["were"]=true,
        ["they're"]=true, ["theyre"]=true,
        ["there's"]=true, ["theres"]=true,
        ["i'll"]=true, ["you'll"]=true, ["he'll"]=true, ["she'll"]=true,
        ["we'll"]=true, ["they'll"]=true, ["it'll"]=true, ["that'll"]=true,
        ["i'd"]=true, ["you'd"]=true, ["he'd"]=true, ["she'd"]=true,
        ["we'd"]=true, ["they'd"]=true,
        ["i've"]=true, ["you've"]=true, ["we've"]=true, ["they've"]=true,
        ["will"]=true, ["would"]=true, ["should"]=true, ["could"]=true,
        ["can"]=true, ["may"]=true, ["might"]=true, ["must"]=true, ["shall"]=true,
        ["is"]=true, ["are"]=true, ["was"]=true, ["were"]=true, ["am"]=true,
        ["have"]=true, ["has"]=true, ["had"]=true,
        ["do"]=true, ["does"]=true, ["did"]=true,
        ["don't"]=true, ["doesn't"]=true, ["didn't"]=true,
        ["dont"]=true, ["doesnt"]=true, ["didnt"]=true,
        ["won't"]=true, ["wouldn't"]=true, ["shouldn't"]=true, ["couldn't"]=true,
        ["can't"]=true, ["mustn't"]=true,
        ["isn't"]=true, ["aren't"]=true, ["wasn't"]=true, ["weren't"]=true,
        ["haven't"]=true, ["hasn't"]=true, ["hadn't"]=true,
        ["not"]=true,
    }
    local function isStranded(text)
        if not text or text == "" then return true end
        local hasContent = false
        for w in text:gmatch("%S+") do
            local lw = w:lower():gsub("[%.,!%?;:'\"]+$", ""):gsub("^[%.,!%?;:'\"]+", "")
            if not STRANDED_TOKEN[lw] then
                hasContent = true
                break
            end
        end
        return not hasContent
    end
    local merged = {}
    local i = 1
    while i <= #clauses do
        local cl = clauses[i]
        if isStranded(cl.text) and i < #clauses then
            -- Merge this clause into the next one. Preserve the sep
            -- text as inline (it captures the ellipsis/comma the user
            -- typed). New clause text = stranded text + sep + next text.
            local nextCl = clauses[i + 1]
            local sep = cl.sep or ""
            -- Sep might be "\1ELLIPSIS\1 " — replace marker if any
            sep = sep:gsub("\1ELLIPSIS\1", "...")
            nextCl.text = cl.text .. sep .. nextCl.text
            -- nextCl keeps its own sep (the separator AFTER the merged pair)
            table.insert(merged, nextCl)
            i = i + 2
        else
            table.insert(merged, cl)
            i = i + 1
        end
    end
    clauses = merged

    return clauses
end

-- ---------------------------------------------------------------------------
-- Word count (for the MIN_CLAUSE_TOKENS check)
-- ---------------------------------------------------------------------------

local function wordCount(text)
    local n = 0
    for _ in text:gmatch("%S+") do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Post-processing helpers for clauses NOT at sentence end
-- ---------------------------------------------------------------------------

-- Inverse of TAZC_Translate's TR_UPPER for the first-letter lowercase pass.
-- Used when a clause sits mid-sentence (after a comma/semicolon) and the
-- engine's per-clause capitalization needs to be reversed.
local TR_LOWER_FIRST = {
    ["\196\176"] = "i",  -- İ -> i
    ["I"]        = "\196\177",  -- I -> ı? No: ambiguous. Default ASCII for ASCII.
    ["\195\135"] = "\195\167",  -- Ç -> ç
    ["\197\158"] = "\197\159",  -- Ş -> ş
    ["\196\158"] = "\196\159",  -- Ğ -> ğ
    ["\195\150"] = "\195\182",  -- Ö -> ö
    ["\195\156"] = "\195\188",  -- Ü -> ü
}

-- For the i/I ambiguity above: ASCII "I" alone is almost always the
-- English pronoun (when it leaks) or a Turkish capital — without context
-- we can't safely down-case. Leave ASCII "I" alone. The rest of the table
-- handles the Turkish-specific cases unambiguously.
TR_LOWER_FIRST["I"] = nil

local function utf8CharLen(b)
    if b < 0x80 then return 1
    elseif b < 0xC0 then return 1  -- malformed; treat as single byte
    elseif b < 0xE0 then return 2
    elseif b < 0xF0 then return 3
    else return 4 end
end

local function lowerFirstChar(s)
    if not s or s == "" then return s end
    local firstByte = s:byte(1)
    local sz = utf8CharLen(firstByte)
    local first = s:sub(1, sz)
    local rest = s:sub(sz + 1)
    local mapped = TR_LOWER_FIRST[first]
    if mapped then return mapped .. rest end
    -- For ASCII letters, use string.lower. Skip "I" (ambiguous).
    if #first == 1 and first ~= "I" then
        return first:lower() .. rest
    end
    return s
end

-- Strip trailing terminator (. ! ?) from a clause output. Used when the
-- clause is NOT at sentence end and we don't want the engine's auto-
-- appended period to interrupt the mid-sentence flow.
local function stripTrailingTerminator(s)
    if not s or s == "" then return s end
    return (s:gsub("[%.%?%!]+$", ""))
end

-- ---------------------------------------------------------------------------
-- Embedded-WH-clause productive rewriter (9.1+).
--
-- The engine's role-assignment pipeline can't currently handle WH-clauses
-- as nominal complements of matrix verbs. The required morphology
-- (-DIK/-ACAK + POSS + ACC) and the structural reordering (Turkish SOV
-- places the nominalized clause before the main verb) are not in the
-- engine's transfer layer.
--
-- Until that engine work lands, this Mosaic-level rewriter handles the
-- most common productive embedded-WH patterns by direct lex lookup and
-- morphology composition. It runs after the whole-sentence phrasebook
-- fast-path and before clause splitting; if no pattern matches, it
-- returns nil and the input flows to the existing engine pipeline.
--
-- Pattern coverage (iterative; add patterns one at a time):
--   * "X (don't|do not) know WH to V"
--     -> "WH-tr V-ACAK-POSS-ACC bil-AOR.NEG-PERS-AGR."
--     Examples: "I don't know what to say" -> "Ne söyleyeceğimi bilmiyorum."
--               "We don't know how to fix this" -> "Nasıl X bilmiyoruz."
-- ---------------------------------------------------------------------------

-- Subject pronoun -> POSS person used on the embedded nominalized verb
-- (matching the matrix subject is the standard reading: "I don't know
-- what (I) to say", "they don't know what (they) to do").
local SUBJ_TO_POSS = {
    ["i"]    = "1sg",
    ["we"]   = "1pl",
    ["they"] = "3pl",
    ["you"]  = "2sg",  -- 2sg by default; "you-plural" disambiguation deferred
}

-- WH-word -> Turkish initial WH-form
local WH_TR = {
    ["what"]  = "Ne",
    ["where"] = "Nereye",   -- destination ("where to go" -> "Nereye gidecegimi")
    ["how"]   = "Nas\196\177l",
    ["when"]  = "Ne zaman",
    ["why"]   = "Neden",
    ["who"]   = "Kimin",
}

-- Conjugated forms of bilmek (know) in the negative present progressive
-- (mat[ches "don't know"). Each form is bil + me-NEG + iyor-PROG + agr.
local BILMIYOR_BY_PERSON = {
    ["1sg"] = "bilmiyorum",
    ["2sg"] = "bilmiyorsun",
    ["3sg"] = "bilmiyor",
    ["1pl"] = "bilmiyoruz",
    ["2pl"] = "bilmiyorsunuz",
    ["3pl"] = "bilmiyorlar",
}

-- Pronoun (embedded clause subject) -> POSS person.
local PRON_TO_POSS = {
    ["i"]    = "1sg",
    ["you"]  = "2sg",
    ["he"]   = "3sg",
    ["she"]  = "3sg",
    ["it"]   = "3sg",
    ["we"]   = "1pl",
    ["they"] = "3pl",
}

-- Conjugated forms of unutmak (forget) in the simple past.
-- Past stem: unut. Voiceless final t -> voiceless assim -> unut + tu = unuttu.
local UNUTTU_BY_PERSON = {
    ["1sg"] = "unuttum",
    ["2sg"] = "unuttun",
    ["3sg"] = "unuttu",
    ["1pl"] = "unuttuk",
    ["2pl"] = "unuttunuz",
    ["3pl"] = "unuttular",
}

-- Pronoun (object) -> Turkish accusative form.
local PRON_TO_ACC = {
    ["me"]   = "beni",
    ["you"]  = "seni",
    ["him"]  = "onu",
    ["her"]  = "onu",
    ["it"]   = "onu",
    ["us"]   = "bizi",
    ["them"] = "onlar\196\177",
}

-- Past-tense yes/no question verb conjugations for "you" (2sg) on the
-- matrix "did you V". Used by Pattern D.
local PAST_QUESTION_YOU = {
    -- "see" past 2sg + question particle
    ["see"]    = "g\195\182rd\195\188n m\195\188",     -- gördün mü
    ["hear"]   = "duydun mu",
    ["notice"] = "fark ettin mi",
    ["know"]   = "biliyor muydun",
}

-- Conjugated forms of "merak etmek" (wonder, curious-do compound) in
-- present progressive, used by Pattern E.
local MERAK_EDIYOR_BY_PERSON = {
    ["1sg"] = "merak ediyorum",
    ["2sg"] = "merak ediyorsun",
    ["3sg"] = "merak ediyor",
    ["1pl"] = "merak ediyoruz",
    ["2pl"] = "merak ediyorsunuz",
    ["3pl"] = "merak ediyorlar",
}

-- Turkish first-letter capitalization. Lua's string:upper only handles
-- ASCII; Turkish-specific lowercase initials (ş/ç/ı/ö/ü/ğ) need their
-- own mapping. Returns the input string with its first letter (whether
-- ASCII or a Turkish-specific UTF-8 char) uppercased.
local TR_FIRST_UPPER = {
    -- ASCII: handled by string:upper for individual characters anyway,
    -- but we list lowercase Turkish UTF-8 sequences -> uppercase counterparts.
    ["\197\159"] = "\197\158",  -- ş -> Ş
    ["\195\167"] = "\195\135",  -- ç -> Ç
    ["\196\177"] = "\196\176",  -- ı -> İ
    ["\195\182"] = "\195\150",  -- ö -> Ö
    ["\195\188"] = "\195\156",  -- ü -> Ü
    ["\196\159"] = "\196\158",  -- ğ -> Ğ
}

local function capitalizeFirstLetter(s)
    if not s or s == "" then return s end
    -- Try Turkish two-byte sequences first
    local twoByte = s:sub(1, 2)
    if TR_FIRST_UPPER[twoByte] then
        return TR_FIRST_UPPER[twoByte] .. s:sub(3)
    end
    -- Special case: ASCII "i" (which Turkish uses for its dotted lowercase i)
    -- must uppercase to "İ" (U+0130, two bytes), not "I" (U+0049).
    -- Lua's string:upper() doesn't know this Turkish convention.
    local firstByte = s:sub(1, 1)
    if firstByte == "i" then
        return "\196\176" .. s:sub(2)
    end
    -- Fall back to ASCII single-byte uppercase
    return firstByte:upper() .. s:sub(2)
end

function Mosaic.tryEmbeddedWHRewrite(input)
    if not input or input == "" then return nil end

    -- Normalize: lowercase, strip terminator, collapse internal whitespace,
    -- trim ends. Preserve the original terminator so we can re-attach it.
    local origTerm = input:match("([%.%?%!]+)%s*$") or ""
    local norm = input:lower()
    norm = norm:gsub("[%.%?%!]+%s*$", "")
    norm = norm:gsub("%s+", " ")
    norm = norm:gsub("^%s+", ""):gsub("%s+$", "")

    local Lexicon    = require("TAZC_TranslateLexicon")
    local Morphology = require("TAZC_TranslateMorphology")

    -- Helper: resolve an English verb surface (possibly inflected -- "thought",
    -- "said", "went") to its VERB lex entry with non-empty tr_stem.
    --
    -- For irregular past forms that conflict with AUX/MODAL entries (e.g.
    -- "did" is do.v past but the lex's lookup returns did.aux first because
    -- the engine needs that for question handling), fall back to a small
    -- irregular-past map and look up by lex id.
    local IRREGULAR_PAST_AS_VERB = {
        ["did"]  = "do.v",
        ["was"]  = "be.v",
        ["were"] = "be.v",
        ["had"]  = "have.v",
    }
    local function lookupVerbStem(surface)
        local all = Lexicon.lookupAll(surface) or {}
        for _, e in ipairs(all) do
            if e.pos == "VERB" and e.tr_stem and e.tr_stem ~= "" then
                return e
            end
        end
        local id = IRREGULAR_PAST_AS_VERB[surface]
        if id then
            for _, e in ipairs(Lexicon.entries or {}) do
                if e.id == id and e.tr_stem and e.tr_stem ~= "" then
                    return e
                end
            end
        end
        return nil
    end

    -- Helper: build a result table from an output string
    local function buildResult(out, patternName)
        if origTerm ~= "" then
            out = out .. origTerm:sub(-1)
        else
            out = out .. "."
        end
        return {
            output      = out,
            clauses     = { { text = input, output = out,
                              kind = "embedded_wh_rewrite" } },
            coverage    = 1,
            turkish_pct = 1,
            errors      = {},
            trace       = { path = "embedded_wh_rewrite",
                            pattern = patternName },
        }
    end

    -- =====================================================================
    -- Pattern A: <SUBJ> (don't|do not|dont) know <WH> to <V>
    -- "I don't know what to say" -> "Ne söyleyeceğimi bilmiyorum."
    -- =====================================================================
    for _, pat in ipairs({
        "^(%w+)%s+don't know%s+(%w+)%s+to%s+(%w+)$",
        "^(%w+)%s+do not know%s+(%w+)%s+to%s+(%w+)$",
        "^(%w+)%s+dont know%s+(%w+)%s+to%s+(%w+)$",
    }) do
        local subj, wh, verb = norm:match(pat)
        if subj then
            local person = SUBJ_TO_POSS[subj]
            local whTr   = WH_TR[wh]
            local entry  = lookupVerbStem(verb)
            if person and whTr and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "future", person = person })
                if ok and nominal then
                    local matrix = BILMIYOR_BY_PERSON[person]
                    return buildResult(
                        whTr .. " " .. nominal .. " " .. matrix,
                        "subj_dont_know_wh_to_v")
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern B: tell me <WH> <PRON> <V>
    -- "Tell me what you think" -> "Ne düşündüğünü söyle."
    -- =====================================================================
    do
        local wh, pron, verb = norm:match("^tell me%s+(%w+)%s+(%w+)%s+(%w+)$")
        if wh and pron and verb then
            local person = PRON_TO_POSS[pron]
            local whTr   = WH_TR[wh]
            local entry  = lookupVerbStem(verb)
            if person and whTr and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "past", person = person })
                if ok and nominal then
                    return buildResult(
                        whTr .. " " .. nominal .. " s\195\182yle",
                        "tell_me_wh_pron_v")
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern C: <SUBJ> forgot to <V> [<PRON> | the <NOUN>]
    -- "I forgot to call" -> "Aramayı unuttum."
    -- "I forgot to call you" -> "Seni aramayı unuttum."
    -- "I forgot to lock the door" -> "Kapıyı kilitlemeyi unuttum."
    -- Uses applyVerbalNounAcc for the gerund object (-mE + Y + ACC).
    -- =====================================================================
    -- Kahlua/Lua 5.1 has no `goto`; `do repeat … until true end` with `break`
    -- is the canonical 5.1 idiom for the same "abandon this pattern, fall
    -- through" early-exit. (The inner `for`-loop break below is unaffected —
    -- the three pattern-abandon breaks all sit outside it.)
    do repeat
        -- No-object variant first
        local subj, verb = norm:match("^(%w+)%s+forgot%s+to%s+(%w+)$")
        local pron, noun
        if not subj then
            -- Pronoun-object variant
            subj, verb, pron = norm:match(
                "^(%w+)%s+forgot%s+to%s+(%w+)%s+(%w+)$")
        end
        if not subj then
            -- the-NOUN variant: "I forgot to lock the door"
            subj, verb, noun = norm:match(
                "^(%w+)%s+forgot%s+to%s+(%w+)%s+the%s+(%w+)$")
        end
        if not subj then
            -- a/an-NOUN variant: "I forgot to buy a book"
            local s, v, art, n = norm:match(
                "^(%w+)%s+forgot%s+to%s+(%w+)%s+(an?)%s+(%w+)$")
            if s then
                subj, verb, noun = s, v, n
            end
        end
        local possessive  -- "my", "your", etc. -- mapped below
        if not subj then
            -- possessive-NOUN variant: "I forgot to charge my phone"
            local s, v, p, n = norm:match(
                "^(%w+)%s+forgot%s+to%s+(%w+)%s+(%w+)%s+(%w+)$")
            local POSS_PRON = {
                ["my"] = "1sg", ["your"] = "2sg", ["his"] = "3sg",
                ["her"] = "3sg", ["our"] = "1pl", ["their"] = "3pl",
            }
            if s and POSS_PRON[p] then
                subj, verb, possessive, noun = s, v, POSS_PRON[p], n
            end
        end
        if subj and verb then
            local matrixPerson = SUBJ_TO_POSS[subj]
            local entry        = lookupVerbStem(verb)
            if matrixPerson and entry then
                -- Object: pronoun, noun, or none
                local objAcc
                if pron then
                    objAcc = PRON_TO_ACC[pron]
                    if not objAcc then
                        break
                    end
                elseif noun then
                    -- Look up the noun's Turkish form, apply POSS (if
                    -- possessive determiner present) and ACC.
                    local nounAll = Lexicon.lookupAll(noun) or {}
                    local nounEntry
                    for _, e in ipairs(nounAll) do
                        if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                            nounEntry = e
                            break
                        end
                    end
                    if not nounEntry then
                        break
                    end
                    local workingNoun = nounEntry.tr
                    -- Apply possessive if present ("my phone" -> "telefonum")
                    if possessive then
                        local possOk, possForm = pcall(
                            Morphology.applyPossessive, workingNoun,
                            possessive,
                            { voicing = nounEntry.tr_final_voicing })
                        if possOk and possForm then
                            workingNoun = possForm
                        end
                    end
                    -- Then apply ACC ("telefonum" -> "telefonumu")
                    local accOk, accForm = pcall(
                        Morphology.applyAccusative, workingNoun,
                        { voicing = (not possessive) and
                                    nounEntry.tr_final_voicing or false })
                    if not accOk or not accForm then
                        break
                    end
                    objAcc = accForm
                end
                local ok, gerundAcc = pcall(Morphology.applyVerbalNounAcc,
                    entry.tr_stem)
                if ok and gerundAcc then
                    local matrix = UNUTTU_BY_PERSON[matrixPerson]
                    if matrix then
                        local out
                        if objAcc then
                            local cap = capitalizeFirstLetter(objAcc)
                            out = cap .. " " .. gerundAcc .. " " .. matrix
                        else
                            local cap = capitalizeFirstLetter(gerundAcc)
                            out = cap .. " " .. matrix
                        end
                        return buildResult(out, "subj_forgot_to_v_obj")
                    end
                end
            end
        end
    until true end

    -- =====================================================================
    -- Pattern D: did you (see|hear|notice) <WH> <V-past>
    -- "Did you see what happened?" -> "Ne olduğunu gördün mü?"
    -- "Did you hear what she said?" -> "Ne söylediğini duydun mu?"
    -- =====================================================================
    do
        -- Two sub-shapes: "did you VM WH VEd" and "did you VM WH PRON VEd"
        -- Sub-shape 1: "did you VM WH VEd" (no embedded subject pronoun;
        -- defaults to 3sg, as in "what happened" / "what broke")
        local vm, wh, ve = norm:match(
            "^did you%s+(%w+)%s+(%w+)%s+(%w+)$")
        if vm and wh and ve then
            -- Disambiguate: PATTERN D only if WH is a real wh-word AND
            -- there's no 5th token (so we know it's "did you SEE WHAT V"
            -- not "did you SEE WHAT PRON V")
            local matrixPhrase = PAST_QUESTION_YOU[vm]
            local whTr         = WH_TR[wh]
            local entry        = lookupVerbStem(ve)
            if matrixPhrase and whTr and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "past", person = "3sg" })
                if ok and nominal then
                    return buildResult(
                        whTr .. " " .. nominal .. " " .. matrixPhrase,
                        "did_you_VM_wh_VEd")
                end
            end
        end
        -- Sub-shape 2: "did you VM WH PRON V" (with embedded subject)
        local vm2, wh2, pron2, ve2 = norm:match(
            "^did you%s+(%w+)%s+(%w+)%s+(%w+)%s+(%w+)$")
        if vm2 and wh2 and pron2 and ve2 then
            local matrixPhrase = PAST_QUESTION_YOU[vm2]
            local whTr         = WH_TR[wh2]
            local person       = PRON_TO_POSS[pron2]
            local entry        = lookupVerbStem(ve2)
            if matrixPhrase and whTr and person and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "past", person = person })
                if ok and nominal then
                    return buildResult(
                        whTr .. " " .. nominal .. " " .. matrixPhrase,
                        "did_you_VM_wh_pron_v")
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern E: <SUBJ> wonder <WH> [<PRON>] <V>
    -- "I wonder what happened" -> "Ne olduğunu merak ediyorum."
    -- "I wonder where they went" -> "Nereye gittiklerini merak ediyorum."
    -- =====================================================================
    do
        -- Sub-shape 1: SUBJ wonder WH PRON V (with explicit pronoun)
        local subj, wh, pron, verb = norm:match(
            "^(%w+)%s+wonder%s+(%w+)%s+(%w+)%s+(%w+)$")
        if subj and wh and pron and verb then
            local matrixPerson = SUBJ_TO_POSS[subj]
            local embedPerson  = PRON_TO_POSS[pron]
            local whTr         = WH_TR[wh]
            local entry        = lookupVerbStem(verb)
            if matrixPerson and embedPerson and whTr and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "past", person = embedPerson })
                local matrix = MERAK_EDIYOR_BY_PERSON[matrixPerson]
                if ok and nominal and matrix then
                    return buildResult(
                        whTr .. " " .. nominal .. " " .. matrix,
                        "subj_wonder_wh_pron_v")
                end
            end
        end
        -- Sub-shape 2: SUBJ wonder WH V-ed (no pronoun, 3sg default)
        local subj2, wh2, verb2 = norm:match(
            "^(%w+)%s+wonder%s+(%w+)%s+(%w+)$")
        if subj2 and wh2 and verb2 then
            local matrixPerson = SUBJ_TO_POSS[subj2]
            local whTr         = WH_TR[wh2]
            local entry        = lookupVerbStem(verb2)
            if matrixPerson and whTr and entry then
                local ok, nominal = pcall(Morphology.applyDikAcakPossAcc,
                    entry.tr_stem, { tense = "past", person = "3sg" })
                local matrix = MERAK_EDIYOR_BY_PERSON[matrixPerson]
                if ok and nominal and matrix then
                    return buildResult(
                        whTr .. " " .. nominal .. " " .. matrix,
                        "subj_wonder_wh_VEd")
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern F: <SUBJ> (have|has) been <V>-ing [all <time>]
    -- "I have been waiting" -> "Bekliyordum."
    -- "I have been working all day" -> "Bütün gün çalışıyordum."
    -- =====================================================================
    do
        -- Time adverbials that map cleanly to Turkish "bütün X" prefix
        local ALL_TIME_TR = {
            ["day"]     = "g\195\188n",      -- gün
            ["night"]   = "gece",
            ["morning"] = "sabah",
            ["evening"] = "ak\197\159am",    -- akşam
            ["week"]    = "hafta",
            ["month"]   = "ay",
            ["year"]    = "y\196\177l",      -- yıl
        }
        -- Helper: strip -ing and undouble final consonant + add back -e if needed
        local function unInging(ving)
            if #ving < 4 then return nil end
            local base = ving:sub(1, -4)
            if #base >= 3 then
                local lastTwo = base:sub(-2)
                if lastTwo:sub(1,1) == lastTwo:sub(2,2)
                   and lastTwo:sub(1,1):match("[bcdfghjklmnpqrstvwxz]")
                then
                    base = base:sub(1, -2)
                end
            end
            return base
        end
        local function findVingEntry(ving)
            local base = unInging(ving)
            if not base then return nil end
            return lookupVerbStem(base) or lookupVerbStem(base .. "e")
        end

        -- Sub-shape 1: SUBJ aux been V-ing (no modifier)
        for _, pat in ipairs({
            "^(%w+)%s+(have)%s+been%s+(%w+ing)$",
            "^(%w+)%s+(has)%s+been%s+(%w+ing)$",
        }) do
            local subj, aux, ving = norm:match(pat)
            if subj and ving then
                local matrixPerson = SUBJ_TO_POSS[subj] or PRON_TO_POSS[subj]
                if matrixPerson then
                    local entry = findVingEntry(ving)
                    if entry then
                        local ok, pp = pcall(
                            Morphology.conjugatePastProgressive,
                            entry.tr_stem, matrixPerson,
                            { intervocalic_voicing =
                                entry.tr_intervocalic_voicing })
                        if ok and pp then
                            return buildResult(
                                capitalizeFirstLetter(pp),
                                "subj_have_been_ving")
                        end
                    end
                end
            end
        end

        -- Sub-shape 2: SUBJ aux been V-ing all <time>
        for _, pat in ipairs({
            "^(%w+)%s+(have)%s+been%s+(%w+ing)%s+all%s+(%w+)$",
            "^(%w+)%s+(has)%s+been%s+(%w+ing)%s+all%s+(%w+)$",
        }) do
            local subj, aux, ving, timeWord = norm:match(pat)
            if subj and ving and timeWord then
                local matrixPerson = SUBJ_TO_POSS[subj] or PRON_TO_POSS[subj]
                local timeTr       = ALL_TIME_TR[timeWord]
                if matrixPerson and timeTr then
                    local entry = findVingEntry(ving)
                    if entry then
                        local ok, pp = pcall(
                            Morphology.conjugatePastProgressive,
                            entry.tr_stem, matrixPerson,
                            { intervocalic_voicing =
                                entry.tr_intervocalic_voicing })
                        if ok and pp then
                            local out = "B\195\188t\195\188n " .. timeTr ..
                                        " " .. pp
                            return buildResult(out,
                                "subj_have_been_ving_all_time")
                        end
                    end
                end
            end
        end

        -- Sub-shape 3: SUBJ aux been V-ing for <duration>
        -- Maps "for hours/minutes/days/weeks" -> "saatlerdir/dakikalardır/..."
        local FOR_DURATION_TR = {
            ["hours"]   = "saatlerdir",
            ["minutes"] = "dakikalard\196\177r",
            ["days"]    = "g\195\188nlerdir",
            ["weeks"]   = "haftalard\196\177r",
            ["months"]  = "aylard\196\177r",
            ["years"]   = "y\196\177llard\196\177r",
        }
        for _, pat in ipairs({
            "^(%w+)%s+(have)%s+been%s+(%w+ing)%s+for%s+(%w+)$",
            "^(%w+)%s+(has)%s+been%s+(%w+ing)%s+for%s+(%w+)$",
        }) do
            local subj, aux, ving, dur = norm:match(pat)
            if subj and ving and dur then
                local matrixPerson = SUBJ_TO_POSS[subj] or PRON_TO_POSS[subj]
                local durTr        = FOR_DURATION_TR[dur]
                if matrixPerson and durTr then
                    local entry = findVingEntry(ving)
                    if entry then
                        local ok, pp = pcall(
                            Morphology.conjugatePastProgressive,
                            entry.tr_stem, matrixPerson,
                            { intervocalic_voicing =
                                entry.tr_intervocalic_voicing })
                        if ok and pp then
                            local out = capitalizeFirstLetter(durTr) ..
                                        " " .. pp
                            return buildResult(out,
                                "subj_have_been_ving_for_duration")
                        end
                    end
                end
            end
        end

        -- Sub-shape 4: SUBJ aux been V-ing since <time>
        -- Maps "since morning/yesterday/etc" -> "sabahtan beri / dünden beri"
        local SINCE_TIME_TR = {
            ["morning"]   = "sabahtan beri",
            ["noon"]      = "\195\182\196\159leden beri",
            ["evening"]   = "ak\197\159amdan beri",
            ["yesterday"] = "d\195\188nden beri",
            ["monday"]    = "pazartesinden beri",
            ["tuesday"]   = "sal\196\177dan beri",
            ["wednesday"] = "\195\167ar\197\159ambadan beri",
            ["thursday"]  = "per\197\159embeden beri",
            ["friday"]    = "cumadan beri",
            ["saturday"]  = "cumartesinden beri",
            ["sunday"]    = "pazardan beri",
        }
        for _, pat in ipairs({
            "^(%w+)%s+(have)%s+been%s+(%w+ing)%s+since%s+(%w+)$",
            "^(%w+)%s+(has)%s+been%s+(%w+ing)%s+since%s+(%w+)$",
        }) do
            local subj, aux, ving, time = norm:match(pat)
            if subj and ving and time then
                local matrixPerson = SUBJ_TO_POSS[subj] or PRON_TO_POSS[subj]
                local timeTr       = SINCE_TIME_TR[time]
                if matrixPerson and timeTr then
                    local entry = findVingEntry(ving)
                    if entry then
                        local ok, pp = pcall(
                            Morphology.conjugatePastProgressive,
                            entry.tr_stem, matrixPerson,
                            { intervocalic_voicing =
                                entry.tr_intervocalic_voicing })
                        if ok and pp then
                            local out = capitalizeFirstLetter(timeTr) ..
                                        " " .. pp
                            return buildResult(out,
                                "subj_have_been_ving_since_time")
                        end
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern G: existential "there is/are [no] X [(in|at|on) [the] Y]"
    -- English: "There are no bullets in the shotgun."
    -- Turkish: "Pompalı tüfekte mermi yok."  -- [Y-LOC] [X-bare] var/yok
    --
    -- The engine produces almost-correct output but in English word order
    -- ([X] [Y-LOC] var/yok) which reads "caveman" to Turkish speakers.
    -- This rewriter composes the natural Turkish [LOC] [SUBJ] var/yok shape.
    -- =====================================================================
    do
        local LOC_ADV_TR = {
            ["here"]       = "burada",
            ["there"]      = "orada",
            ["inside"]     = "i\195\167eride",
            ["outside"]    = "d\196\177\197\159ar\196\177da",
            ["nearby"]     = "yak\196\177nda",
            ["upstairs"]   = "yukar\196\177da",
            ["downstairs"] = "a\197\159a\196\159\196\177da",
        }

        -- Look up a noun: returns the NOUN entry or nil if no noun sense
        local function lookupNounEntry(surface)
            local all = Lexicon.lookupAll(surface) or {}
            for _, e in ipairs(all) do
                if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                    return e
                end
            end
            return nil
        end

        -- Compose the existential output:
        --   loc=nil, negated=false : "X var"
        --   loc=nil, negated=true  : "X yok"
        --   loc=str, negated=false : "Y-LOC X var"
        --   loc=str, negated=true  : "Y-LOC X yok"
        local function composeExistential(subjTr, locTr, negated)
            local copula = negated and "yok" or "var"
            local body
            if locTr then
                body = locTr .. " " .. subjTr .. " " .. copula
            else
                body = subjTr .. " " .. copula
            end
            return capitalizeFirstLetter(body)
        end

        -- Resolve subject (bare noun, no plural — Turkish convention)
        local function resolveSubject(word)
            local entry = lookupNounEntry(word)
            if not entry then return nil end
            return entry.tr  -- bare singular Turkish form
        end

        -- Resolve location: either an adverbial ("here", "outside") or
        -- a noun in locative case. Returns the Turkish form.
        local function resolveLocation(word)
            if LOC_ADV_TR[word] then
                return LOC_ADV_TR[word]
            end
            local entry = lookupNounEntry(word)
            if not entry then return nil end
            local ok, locForm = pcall(Morphology.applyLocative, entry.tr)
            if not ok or not locForm then return nil end
            return locForm
        end

        -- Try sub-shapes most-specific-first. Each match returns a complete
        -- output or falls through to the next pattern.

        -- G6: "there (is|are) no X (in|at|on) [the] Y"
        for _, det in ipairs({ "the%s+", "" }) do
            local subj, loc = norm:match(
                "^there%s+(?:is|are)%s+no%s+(%w+)%s+(?:in|at|on)%s+" ..
                det .. "(%w+)$")
            -- Lua's pattern doesn't support (?:...) so do it manually
        end
        -- Lua patterns don't support non-capturing groups. Match explicitly.
        do
            -- G6 variants: "there is/are no X (in|at|on) the Y"
            for _, pat in ipairs({
                "^there%s+is%s+no%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+is%s+no%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+is%s+no%s+(%w+)%s+on%s+the%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+on%s+the%s+(%w+)$",
                -- "the" optional variant
                "^there%s+is%s+no%s+(%w+)%s+in%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+in%s+(%w+)$",
                "^there%s+is%s+no%s+(%w+)%s+at%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+at%s+(%w+)$",
                "^there%s+is%s+no%s+(%w+)%s+on%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+on%s+(%w+)$",
            }) do
                local subj, loc = norm:match(pat)
                if subj and loc then
                    local subjTr = resolveSubject(subj)
                    local locTr  = resolveLocation(loc)
                    if subjTr and locTr then
                        return buildResult(
                            composeExistential(subjTr, locTr, true),
                            "existential_there_neg_loc")
                    end
                end
            end
        end

        -- G5: "there is/are [a|an|some|the] X (in|at|on) [the] Y" (positive)
        do
            for _, pat in ipairs({
                -- "X is/are in/at/on the Y"
                "^there%s+is%s+a%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+is%s+an%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+is%s+a%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+is%s+an%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+at%s+the%s+(%w+)$",
                "^there%s+is%s+a%s+(%w+)%s+on%s+the%s+(%w+)$",
                "^there%s+is%s+an%s+(%w+)%s+on%s+the%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+on%s+the%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+on%s+the%s+(%w+)$",
                "^there%s+is%s+some%s+(%w+)%s+in%s+the%s+(%w+)$",
                "^there%s+are%s+some%s+(%w+)%s+in%s+the%s+(%w+)$",
                -- "the" optional variant
                "^there%s+is%s+(%w+)%s+in%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+in%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+at%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+at%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+on%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+on%s+(%w+)$",
            }) do
                local subj, loc = norm:match(pat)
                if subj and loc then
                    local subjTr = resolveSubject(subj)
                    local locTr  = resolveLocation(loc)
                    if subjTr and locTr then
                        return buildResult(
                            composeExistential(subjTr, locTr, false),
                            "existential_there_pos_loc")
                    end
                end
            end
        end

        -- G4: "there is/are [no] X <loc-adv>" (adverbial location)
        do
            for _, pat in ipairs({
                "^there%s+is%s+no%s+(%w+)%s+(%w+)$",
                "^there%s+are%s+no%s+(%w+)%s+(%w+)$",
            }) do
                local subj, loc = norm:match(pat)
                if subj and loc and LOC_ADV_TR[loc] then
                    local subjTr = resolveSubject(subj)
                    if subjTr then
                        return buildResult(
                            composeExistential(subjTr, LOC_ADV_TR[loc], true),
                            "existential_there_neg_advloc")
                    end
                end
            end
            for _, pat in ipairs({
                "^there%s+is%s+a%s+(%w+)%s+(%w+)$",
                "^there%s+is%s+an%s+(%w+)%s+(%w+)$",
                "^there%s+is%s+some%s+(%w+)%s+(%w+)$",
                "^there%s+are%s+some%s+(%w+)%s+(%w+)$",
                "^there%s+are%s+(%w+)%s+(%w+)$",
                "^there%s+is%s+(%w+)%s+(%w+)$",
            }) do
                local subj, loc = norm:match(pat)
                if subj and loc and LOC_ADV_TR[loc] then
                    local subjTr = resolveSubject(subj)
                    if subjTr then
                        return buildResult(
                            composeExistential(subjTr, LOC_ADV_TR[loc], false),
                            "existential_there_pos_advloc")
                    end
                end
            end
        end

        -- G3: "there is/are no X" (no location)
        for _, pat in ipairs({
            "^there%s+is%s+no%s+(%w+)$",
            "^there%s+are%s+no%s+(%w+)$",
        }) do
            local subj = norm:match(pat)
            if subj then
                local subjTr = resolveSubject(subj)
                if subjTr then
                    return buildResult(
                        composeExistential(subjTr, nil, true),
                        "existential_there_neg")
                end
            end
        end

        -- G2: "there is/are [a|an|some] X" (no location, positive)
        for _, pat in ipairs({
            "^there%s+is%s+a%s+(%w+)$",
            "^there%s+is%s+an%s+(%w+)$",
            "^there%s+is%s+some%s+(%w+)$",
            "^there%s+are%s+some%s+(%w+)$",
            "^there%s+are%s+(%w+)$",
            "^there%s+is%s+(%w+)$",
        }) do
            local subj = norm:match(pat)
            if subj then
                local subjTr = resolveSubject(subj)
                if subjTr then
                    return buildResult(
                        composeExistential(subjTr, nil, false),
                        "existential_there_pos")
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern H: possessive existential negation
    -- English: "I have no X" / "you have no X" / etc.
    -- Turkish: "X-POSS yok" — same as Pattern G but with possessive marker.
    --
    -- Engine handles positive "I have X" → "X-POSS var" correctly, but
    -- breaks on negative — emits "Hiç X-POSS var" (keeps var instead of
    -- switching to yok). Pattern H fixes this.
    --
    -- "I have no money."  → "Param yok."     (1sg)
    -- "You have no time." → "Zamanın yok."   (2sg)
    -- "We have no food."  → "Yemeğimiz yok." (1pl)
    -- =====================================================================
    do
        local SUBJ_TO_POSS_HAVE = {
            ["i"]    = "1sg",
            ["you"]  = "2sg",
            ["he"]   = "3sg",
            ["she"]  = "3sg",
            ["it"]   = "3sg",
            ["we"]   = "1pl",
            ["they"] = "3pl",
        }

        local function lookupNoun(surface)
            local all = Lexicon.lookupAll(surface) or {}
            for _, e in ipairs(all) do
                if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                    return e
                end
            end
            return nil
        end

        -- "<SUBJ> (have|has|had|don't have|didn't have) [no/any] <NOUN>"
        -- Present forms emit "yok"; past forms emit "yoktu" (past existential)
        local PRESENT_PATTERNS = {
            -- "I have no X" / "you have no X" / etc.
            "^(%w+)%s+have%s+no%s+(%w+)$",
            "^(%w+)%s+has%s+no%s+(%w+)$",
            -- "I don't have any X" / variants
            "^(%w+)%s+don't%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+do%s+not%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+dont%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+doesn't%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+does%s+not%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+doesnt%s+have%s+any%s+(%w+)$",
            -- "I don't have X" (no "any" — still a negation)
            "^(%w+)%s+don't%s+have%s+(%w+)$",
            "^(%w+)%s+do%s+not%s+have%s+(%w+)$",
            "^(%w+)%s+dont%s+have%s+(%w+)$",
            "^(%w+)%s+doesn't%s+have%s+(%w+)$",
            "^(%w+)%s+does%s+not%s+have%s+(%w+)$",
            "^(%w+)%s+doesnt%s+have%s+(%w+)$",
        }
        local PAST_PATTERNS = {
            -- "I had no X" / "she had no X" / etc.
            "^(%w+)%s+had%s+no%s+(%w+)$",
            -- "I didn't have any X" / variants
            "^(%w+)%s+didn't%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+did%s+not%s+have%s+any%s+(%w+)$",
            "^(%w+)%s+didnt%s+have%s+any%s+(%w+)$",
            -- "I didn't have X" (no "any" — still negation)
            "^(%w+)%s+didn't%s+have%s+(%w+)$",
            "^(%w+)%s+did%s+not%s+have%s+(%w+)$",
            "^(%w+)%s+didnt%s+have%s+(%w+)$",
        }
        local function tryPattern(pats, copula)
            for _, pat in ipairs(pats) do
                local subj, noun = norm:match(pat)
                if subj and noun then
                    local poss = SUBJ_TO_POSS_HAVE[subj]
                    local nounEntry = lookupNoun(noun)
                    if poss and nounEntry then
                        local possOk, possForm = pcall(
                            Morphology.applyPossessive, nounEntry.tr, poss,
                            { voicing = nounEntry.tr_final_voicing })
                        if possOk and possForm then
                            local out = capitalizeFirstLetter(possForm) ..
                                        " " .. copula
                            return out
                        end
                    end
                end
            end
            return nil
        end
        local present = tryPattern(PRESENT_PATTERNS, "yok")
        if present then
            return buildResult(present, "possessive_existential_neg")
        end
        local past = tryPattern(PAST_PATTERNS, "yoktu")
        if past then
            return buildResult(past, "possessive_existential_neg_past")
        end
    end

    -- =====================================================================
    -- Pattern J: embedded matrix-verb statement
    -- "I think X" / "I know X" / "I believe X" / "I guess X" / "I hope X"
    -- Engine currently drops the matrix verb (e.g. "I think she is right"
    -- -> "Sağ"). Pattern J recursively translates the embedded clause and
    -- prepends the matrix-verb Turkish equivalent.
    -- =====================================================================
    do
        local MATRIX_VERB_TR = {
            ["think"]   = "San\196\177r\196\177m",     -- Sanırım = I think
            ["know"]    = "Biliyorum",                  -- Biliyorum = I know
            ["believe"] = "\196\176nan\196\177yorum",   -- İnanıyorum = I believe
            ["guess"]   = "San\196\177r\196\177m",     -- guess ~ think
            ["hope"]    = "Umar\196\177m",              -- Umarım = I hope
        }
        for _, mv in ipairs({"think", "know", "believe", "guess", "hope"}) do
            -- "I (mv) [that] <rest>"
            for _, pat in ipairs({
                "^i%s+" .. mv .. "%s+that%s+(.+)$",
                "^i%s+" .. mv .. "%s+(.+)$",
            }) do
                local rest = norm:match(pat)
                if rest and #rest >= 3 then
                    -- Reconstruct a sentence-shaped input. Engine relies
                    -- on terminator for question detection.
                    local restInput = rest
                    if not restInput:match("[%.%?!]$") then
                        restInput = restInput .. "."
                    end
                    -- Capitalize first letter so the engine treats it
                    -- as a fresh sentence with proper subject parsing
                    restInput = restInput:sub(1, 1):upper() .. restInput:sub(2)
                    -- Recursively translate via Mosaic.translate so the
                    -- embedded clause picks up Pattern G/H (existential,
                    -- possessive-negation) etc. Depth guard prevents
                    -- infinite recursion on nested matrix verbs.
                    local subRes
                    if Mosaic._depth < Mosaic._MAX_DEPTH then
                        Mosaic._depth = Mosaic._depth + 1
                        local ok, r = pcall(Mosaic.translate, restInput)
                        Mosaic._depth = Mosaic._depth - 1
                        if ok and r and r.output and r.output ~= "" then
                            subRes = { ok = true, output = r.output }
                        end
                    end
                    -- Fallback to engine if Mosaic recursion was skipped
                    -- or failed
                    if not subRes then
                        subRes = Translate.translate(restInput)
                    end
                    if subRes and subRes.ok and subRes.output
                       and subRes.output ~= "" then
                        local restTr = stripTrailingTerminator(subRes.output)
                        -- Turkish-aware lowercase first letter so it flows
                        -- after the matrix verb. Lua's string:lower() only
                        -- knows ASCII; Turkish uppercase letters need
                        -- explicit two-byte handling.
                        local TR_LOWER_MAP = {
                            ["\196\176"] = "i",          -- İ -> i (dotted)
                            ["\196\177"] = "\196\177",   -- (already lower)
                            ["\196\158"] = "\196\159",   -- Ğ -> ğ
                            ["\195\135"] = "\195\167",   -- Ç -> ç
                            ["\197\158"] = "\197\159",   -- Ş -> ş
                            ["\195\150"] = "\195\182",   -- Ö -> ö
                            ["\195\156"] = "\195\188",   -- Ü -> ü
                        }
                        local twoByte = restTr:sub(1, 2)
                        if TR_LOWER_MAP[twoByte] then
                            restTr = TR_LOWER_MAP[twoByte] .. restTr:sub(3)
                        else
                            -- ASCII single-byte: also handle I -> ı
                            -- (dotless lowercase i in Turkish)
                            local firstChar = restTr:sub(1, 1)
                            if firstChar == "I" then
                                restTr = "\196\177" .. restTr:sub(2)
                            else
                                restTr = firstChar:lower() .. restTr:sub(2)
                            end
                        end
                        local out = MATRIX_VERB_TR[mv] .. " " .. restTr
                        return buildResult(out, "matrix_verb_" .. mv)
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern M: comparatives with "than X"
    -- English: "I am taller than you." / "She is stronger than him."
    -- Turkish: "Senden daha uzunum." (you-ABL more tall-1sg)
    --
    -- Engine produces "Sen den daha uzunum" (ABL separated as " den").
    -- Pattern M attaches the ABL properly via applyAblative + handles
    -- pronoun suppletion (sen->senden, ben->benden, o->ondan, etc.)
    -- =====================================================================
    do
        local SUBJ_TO_COPULAR = {
            ["i"]    = "1sg",
            ["you"]  = "2sg",
            ["he"]   = "3sg",
            ["she"]  = "3sg",
            ["it"]   = "3sg",
            ["we"]   = "1pl",
            ["they"] = "3pl",
            -- Demonstratives + common temporals: 3sg copular
            ["this"]      = "3sg",
            ["that"]      = "3sg",
            ["today"]     = "3sg",
            ["yesterday"] = "3sg",
            ["tomorrow"]  = "3sg",
            ["tonight"]   = "3sg",
        }
        -- Suppletive ABL forms for pronouns + demonstratives (no productive morphology)
        local PRON_ABL = {
            ["i"]    = "benden",   ["me"]   = "benden",
            ["you"]  = "senden",
            ["he"]   = "ondan",    ["him"]  = "ondan",
            ["she"]  = "ondan",    ["her"]  = "ondan",
            ["it"]   = "ondan",
            ["we"]   = "bizden",   ["us"]   = "bizden",
            ["they"] = "onlardan", ["them"] = "onlardan",
            -- Demonstratives — "than this/that" cases
            ["this"] = "bundan",
            ["that"] = "ondan",
        }

        local function lookupCompAdj(surface)
            local all = Lexicon.lookupAll(surface) or {}
            for _, e in ipairs(all) do
                if e.pos == "ADJ" and e.tr and e.tr ~= "" then
                    return e
                end
            end
            return nil
        end

        local function lookupNounEntry(surface)
            local all = Lexicon.lookupAll(surface) or {}
            for _, e in ipairs(all) do
                if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                    return e
                end
            end
            return nil
        end

        -- Pronoun-object form (most common):
        -- "<SUBJ> (am|is|are|was|were) <COMP> than <OBJ-PRON>"
        for _, pat in ipairs({
            "^(%w+)%s+am%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+is%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+are%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+was%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+were%s+(%w+)%s+than%s+(%w+)$",
        }) do
            local subj, comp, obj = norm:match(pat)
            if subj and comp and obj then
                local compEntry = lookupCompAdj(comp)
                local objAbl    = PRON_ABL[obj]
                local copular   = SUBJ_TO_COPULAR[subj]
                if compEntry and objAbl and copular then
                    -- Apply copular suffix to the comparative form.
                    -- The compEntry.tr is "daha X" (e.g. "daha uzun");
                    -- we apply copular to the X part only.
                    local compTr = compEntry.tr  -- "daha uzun"
                    -- Split off "daha " to find the adjective stem
                    local dahaPart, adjStem = compTr:match("^(daha%s+)(.+)$")
                    if dahaPart and adjStem then
                        local copOk, copForm = pcall(
                            Morphology.applyCopular, adjStem, copular)
                        if copOk and copForm then
                            local out = capitalizeFirstLetter(objAbl)
                                        .. " " .. dahaPart .. copForm
                            return buildResult(out,
                                "comparative_than_pron")
                        end
                    end
                end
            end
        end

        -- Noun-object form: "<SUBJ> is/was <COMP> than [the] <NOUN>"
        for _, pat in ipairs({
            "^(%w+)%s+is%s+(%w+)%s+than%s+the%s+(%w+)$",
            "^(%w+)%s+is%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+are%s+(%w+)%s+than%s+the%s+(%w+)$",
            "^(%w+)%s+are%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+was%s+(%w+)%s+than%s+the%s+(%w+)$",
            "^(%w+)%s+was%s+(%w+)%s+than%s+(%w+)$",
            "^(%w+)%s+were%s+(%w+)%s+than%s+the%s+(%w+)$",
            "^(%w+)%s+were%s+(%w+)%s+than%s+(%w+)$",
        }) do
            local subj, comp, obj = norm:match(pat)
            if subj and comp and obj then
                local compEntry = lookupCompAdj(comp)
                local objEntry  = lookupNounEntry(obj)
                local copular   = SUBJ_TO_COPULAR[subj]
                if compEntry and objEntry and copular then
                    local ablOk, objAbl = pcall(
                        Morphology.applyAblative, objEntry.tr)
                    if ablOk and objAbl then
                        local compTr = compEntry.tr
                        local dahaPart, adjStem = compTr:match("^(daha%s+)(.+)$")
                        if dahaPart and adjStem then
                            local copOk, copForm = pcall(
                                Morphology.applyCopular, adjStem, copular)
                            if copOk and copForm then
                                local out = capitalizeFirstLetter(objAbl)
                                            .. " " .. dahaPart .. copForm
                                return buildResult(out,
                                    "comparative_than_noun")
                            end
                        end
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern O: productive apostrophe-s genitive
    -- English: "John's knife is sharp." / "The man's daughter is here."
    -- Turkish: "John'un bıçağı keskin." / "Adamın kızı burada."
    --
    -- Detects "<X>'s <Y> <rest>" at sentence start, builds the Turkish
    -- GEN+POSS3sg noun phrase, recursively translates the rest of the
    -- sentence. Handles proper nouns (apostrophe-separated suffix) vs
    -- common nouns (no apostrophe).
    -- =====================================================================
    do
        -- Match: "X's Y" optionally followed by rest. Also tolerate "X' s"
        -- (curly-quote artifact) and "Xs Y" (apostrophe-less casual chat).
        local x, y, rest = norm:match("^([%a]+)'s%s+([%a]+)(.*)$")
        if x and y then
            local xLower = x:lower()
            local yLower = y:lower()
            -- Skip if X is a function word that can't be a possessor. "there's"
            -- "here's" "where's" "what's" "who's" "how's" "that's" "this's"
            -- are all contractions of "X is" — not possessives. The engine's
            -- contraction expander handles them; Pattern O must not pre-empt.
            local SKIP_POSSESSOR = {
                ["there"] = true, ["here"] = true, ["where"] = true,
                ["what"]  = true, ["who"]  = true, ["how"]   = true,
                ["that"]  = true, ["this"] = true, ["it"]    = true,
                ["he"]    = true, ["she"]  = true, ["one"]   = true,
                ["everyone"] = true, ["someone"] = true,
                ["nobody"] = true, ["nothing"] = true,
                ["something"] = true, ["anyone"] = true,
                ["everything"] = true,
            }
            -- Skip if Y starts with "is/are/was/were/has/have" (these are
            -- contractions like "John's tired" = "John is tired", handled
            -- by the contraction expander upstream — defensive guard).
            local SKIP_HEAD = {
                ["is"]=true, ["are"]=true, ["was"]=true, ["were"]=true,
                ["has"]=true, ["have"]=true, ["been"]=true, ["a"]=true,
                ["an"]=true, ["the"]=true, ["got"]=true, ["going"]=true,
            }
            if not SKIP_POSSESSOR[xLower] and not SKIP_HEAD[yLower] then
                local yEntry = nil
                local yAll = Lexicon.lookupAll(y) or {}
                for _, e in ipairs(yAll) do
                    if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                        yEntry = e
                        break
                    end
                end
                if yEntry then
                    -- Build the possessor (X) in Turkish genitive
                    local xGenForm
                    local xLower = x:lower()
                    -- Check if X is a known common noun in lex
                    local xCommonEntry = nil
                    local xAll = Lexicon.lookupAll(x) or {}
                    for _, e in ipairs(xAll) do
                        if e.pos == "NOUN" and e.tr and e.tr ~= "" then
                            xCommonEntry = e
                            break
                        end
                    end
                    if xCommonEntry then
                        -- Common noun: apply Turkish GEN to the Turkish stem
                        local genOk, genForm = pcall(
                            Morphology.applyGenitive, xCommonEntry.tr)
                        if genOk then xGenForm = genForm end
                    else
                        -- Proper noun: apply Turkish GEN with apostrophe
                        -- For vowel harmony, use the surface form's last vowel
                        local genOk, genForm = pcall(
                            Morphology.applyGenitive, xLower)
                        if genOk and genForm then
                            -- genForm is "johnun" — replace lowercase prefix
                            -- with original-case prefix + apostrophe
                            local suffixLen = #genForm - #xLower
                            if suffixLen > 0 then
                                local suffix = genForm:sub(#xLower + 1)
                                -- Strip n-buffer if applicable (vowel-final stems)
                                xGenForm = x .. "'" .. suffix
                            end
                        end
                    end
                    if xGenForm then
                        -- Build the head (Y) with POSS-3sg
                        local possOk, possForm = pcall(
                            Morphology.applyPossessive, yEntry.tr, "3sg",
                            { voicing = yEntry.tr_final_voicing })
                        if possOk and possForm then
                            local np = xGenForm .. " " .. possForm
                            -- Trim rest. Recursively translate non-empty rest.
                            local restTrimmed = (rest or ""):match("^%s*(.-)%s*$") or ""
                            local fullOut
                            if restTrimmed == "" then
                                fullOut = capitalizeFirstLetter(np)
                            else
                                -- Recursive call to Mosaic.translate with the
                                -- rest. Recursion guard: max depth 3.
                                Mosaic._depth = (Mosaic._depth or 0) + 1
                                local restResult
                                if Mosaic._depth <= 3 then
                                    restResult = Mosaic.translate(restTrimmed)
                                end
                                Mosaic._depth = Mosaic._depth - 1
                                local restOut
                                if restResult and restResult.output then
                                    -- Lowercase the rest's first letter (it'll
                                    -- be capitalized from being a "sentence")
                                    restOut = restResult.output
                                    local firstChar = restOut:sub(1, 1)
                                    if firstChar:upper() == firstChar
                                       and firstChar:lower() ~= firstChar then
                                        restOut = firstChar:lower() ..
                                                  restOut:sub(2)
                                    end
                                end
                                if restOut then
                                    fullOut = capitalizeFirstLetter(np) ..
                                              " " .. restOut
                                else
                                    -- Fallback: leave rest as-is
                                    fullOut = capitalizeFirstLetter(np) ..
                                              " " .. restTrimmed .. "."
                                end
                            end
                            return buildResult(fullOut, "genitive_apostrophe_s")
                        end
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern S: coordinated subject "X and I"
    -- "Alice and I went home" -> "Alice ve ben eve gittik" (1pl verb)
    -- Engine's softSplitAnd wrongly clause-splits on "and I", stranding X.
    -- Pre-process here, before clause splitting, by rewriting to a "we"
    -- subject (engine produces 1pl conjugation) then prepending the
    -- coordinated subject in Turkish.
    --
    -- 8.16.x. Handles X as a single word (proper noun) or simple PRON
    -- (she/he/you). More complex NPs in X are queued.
    -- =====================================================================
    do
        local norm = input:match("^%s*(.-)%s*$") or ""
        local termless = norm:gsub("[%.%?!]+%s*$", "")
        local term = input:match("([%.%?!]+)%s*$") or "."
        -- Match: ^<X> and I <REST>$ (case-insensitive on "and I")
        -- X is a single alphabetic token. REST has at least one verb-ish
        -- content (length check).
        local x, rest = termless:match("^(%a+)%s+[aA][nN][dD]%s+[iI]%s+(.+)$")
        if x and rest and #rest >= 2 then
            local xLower = x:lower()
            -- Skip if X is itself a 1st-person pronoun (would be weird)
            -- or empty.
            if xLower ~= "i" and xLower ~= "we" then
                local Lexicon = require("TAZC_TranslateLexicon")
                local xEntries = Lexicon.lookupAll(xLower) or {}
                -- Determine X's Turkish surface.
                -- - PRON entry: use its tr (sen, o, etc.)
                -- - No PRON entry: treat as proper noun, use input's
                --   original-case form (preserves Alice/John spelling).
                local xTr
                local hasPron = false
                for _, e in ipairs(xEntries) do
                    if e.pos == "PRON" then
                        hasPron = true
                        if e.tr and e.tr ~= "" then xTr = e.tr end
                        break
                    end
                end
                if not hasPron then
                    -- Use input's original-case form of x
                    local origCase = input:match("^%s*(%a+)%s+[aA][nN][dD]%s+[iI]%s+")
                    xTr = origCase or x
                end

                if xTr then
                    -- Recursively translate "we <REST>" via Mosaic so engine
                    -- produces 1pl conjugation.
                    local restInput = "we " .. rest .. term
                    -- Capitalize first letter so engine treats fresh sentence
                    restInput = restInput:sub(1, 1):upper() .. restInput:sub(2)
                    local subRes
                    if Mosaic._depth < Mosaic._MAX_DEPTH then
                        Mosaic._depth = Mosaic._depth + 1
                        local ok, r = pcall(Mosaic.translate, restInput)
                        Mosaic._depth = Mosaic._depth - 1
                        if ok and r and r.output and r.output ~= "" then
                            subRes = r
                        end
                    end
                    if subRes and subRes.output then
                        local restTr = stripTrailingTerminator(subRes.output)
                        -- Lowercase the first letter of restTr so it flows
                        -- after "<X> ve ben ". Turkish-aware (same map as
                        -- Pattern J).
                        local TR_LOWER_MAP = {
                            ["\196\176"] = "i",          -- İ -> i
                            ["\196\177"] = "\196\177",
                            ["\196\158"] = "\196\159",   -- Ğ -> ğ
                            ["\195\135"] = "\195\167",   -- Ç -> ç
                            ["\197\158"] = "\197\159",   -- Ş -> ş
                            ["\195\150"] = "\195\182",   -- Ö -> ö
                            ["\195\156"] = "\195\188",   -- Ü -> ü
                        }
                        local twoByte = restTr:sub(1, 2)
                        if TR_LOWER_MAP[twoByte] then
                            restTr = TR_LOWER_MAP[twoByte] .. restTr:sub(3)
                        else
                            local firstChar = restTr:sub(1, 1)
                            if firstChar == "I" then
                                restTr = "\196\177" .. restTr:sub(2)
                            else
                                restTr = firstChar:lower() .. restTr:sub(2)
                            end
                        end
                        -- Capitalize X's first letter (sentence-initial)
                        local xCap = xTr:sub(1, 1):upper() .. xTr:sub(2)
                        local out = xCap .. " ve ben " .. restTr
                        return buildResult(out, "coord_subj_X_and_i")
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern S2: coordinated subject "X and Y" (both 3rd-person)
    -- "Sarah and Tom came back" -> "Sarah ve Tom geri geldiler" (3pl verb)
    -- Engine handles "X and Y" as one clause but conjugates the verb as 3sg
    -- (picking just one head). Rewrite to "they" so engine produces 3pl,
    -- then prepend "<X-tr> ve <Y-tr> ".
    --
    -- Conservative: X and Y must each be a single alphabetic word; neither
    -- can be "i" (covered by Pattern S) or "we" (already plural).
    -- =====================================================================
    do
        local norm = input:match("^%s*(.-)%s*$") or ""
        local termless = norm:gsub("[%.%?!]+%s*$", "")
        local term = input:match("([%.%?!]+)%s*$") or "."
        -- Match: ^<X> and <Y> <REST>$
        local x, y, rest = termless:match(
            "^(%a+)%s+[aA][nN][dD]%s+(%a+)%s+(.+)$")
        if x and y and rest and #rest >= 2 then
            local xLower = x:lower()
            local yLower = y:lower()
            -- Skip when this would conflict with Pattern S (X and I), or
            -- when X/Y are not subject-suitable.
            local SKIP = { i = true, we = true }
            if not SKIP[xLower] and not SKIP[yLower] then
                local Lexicon = require("TAZC_TranslateLexicon")

                -- Determine each token's Turkish surface (PRON tr or
                -- original case for proper nouns). Also veto if either
                -- looks-up as a non-NOUN/non-PRON (e.g. a VERB), since
                -- "came and left" then would wrongly fire.
                local function asSubjTr(token, lower)
                    local entries = Lexicon.lookupAll(lower) or {}
                    local hasPron, hasNoun = false, false
                    local pronTr, nounTr
                    local hasVerb, hasModal = false, false
                    for _, e in ipairs(entries) do
                        if e.pos == "PRON" then
                            hasPron = true
                            if e.tr and e.tr ~= "" then pronTr = e.tr end
                        elseif e.pos == "NOUN" then
                            hasNoun = true
                            if e.tr and e.tr ~= "" then nounTr = e.tr end
                        elseif e.pos == "VERB" or e.pos == "AUX" then
                            hasVerb = true
                        elseif e.pos == "MODAL" then
                            hasModal = true
                        end
                    end
                    -- Veto when the token has a verb/modal reading and
                    -- no nominal reading at all — "came/left/will/can"
                    -- shouldn't be treated as a coordinated subject.
                    if (hasVerb or hasModal) and not hasPron and not hasNoun then
                        return nil
                    end
                    if hasPron then return pronTr end
                    -- Treat as proper noun: keep original casing
                    return token
                end

                -- Capture original-case forms from input for proper nouns
                local origX = input:match("^%s*(%a+)%s+[aA][nN][dD]")
                local origY = input:match("[aA][nN][dD]%s+(%a+)%s+")
                local xTr = asSubjTr(origX or x, xLower)
                local yTr = asSubjTr(origY or y, yLower)

                if xTr and yTr then
                    -- Recursively translate "they <REST>"
                    local restInput = "they " .. rest .. term
                    restInput = restInput:sub(1, 1):upper() .. restInput:sub(2)
                    local subRes
                    if Mosaic._depth < Mosaic._MAX_DEPTH then
                        Mosaic._depth = Mosaic._depth + 1
                        local ok, r = pcall(Mosaic.translate, restInput)
                        Mosaic._depth = Mosaic._depth - 1
                        if ok and r and r.output and r.output ~= "" then
                            subRes = r
                        end
                    end
                    if subRes and subRes.output then
                        local restTr = stripTrailingTerminator(subRes.output)
                        -- Lowercase first letter of restTr (Turkish-aware)
                        local TR_LOWER_MAP = {
                            ["\196\176"] = "i",
                            ["\196\177"] = "\196\177",
                            ["\196\158"] = "\196\159",
                            ["\195\135"] = "\195\167",
                            ["\197\158"] = "\197\159",
                            ["\195\150"] = "\195\182",
                            ["\195\156"] = "\195\188",
                        }
                        local twoByte = restTr:sub(1, 2)
                        if TR_LOWER_MAP[twoByte] then
                            restTr = TR_LOWER_MAP[twoByte] .. restTr:sub(3)
                        else
                            local firstChar = restTr:sub(1, 1)
                            if firstChar == "I" then
                                restTr = "\196\177" .. restTr:sub(2)
                            else
                                restTr = firstChar:lower() .. restTr:sub(2)
                            end
                        end
                        local xCap = xTr:sub(1, 1):upper() .. xTr:sub(2)
                        local out = xCap .. " ve " .. yTr .. " " .. restTr
                        return buildResult(out, "coord_subj_X_and_Y")
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern R: conditional-clause reorder for main-then-if forms.
    -- English allows "Tell me if you see him" (main + if-clause) or
    -- "If you see him, tell me" (if-clause + main). Turkish strongly
    -- prefers if-clause first. Mosaic handles the if-first form
    -- correctly (Onu görürsen, bana söyle) but the main-first form
    -- produces awkward "Bana söyle eğer onu gördün".
    --
    -- Detect "<MAIN> if <COND>" where MAIN has no internal "if", and
    -- rewrite to "If <COND>, <MAIN>" then recurse via Mosaic. The
    -- recursive call picks up the if-first phrasebook / morphology
    -- path correctly.
    -- =====================================================================
    do
        local norm = input:match("^%s*(.-)%s*$") or ""
        local termless = norm:gsub("[%.%?!]+%s*$", "")
        local term = input:match("([%.%?!]+)%s*$") or "."
        -- Require: ^ <MAIN-without-if> %s if %s <COND> $
        -- Use a guard: MAIN must not contain " if " itself.
        -- Lowercase " if " marker so case is preserved in payload.
        local mainStart, mainEnd, condStart =
            termless:find("^(.-)%s+[iI][fF]%s+(.+)$")
        local main, cond = termless:match("^(.-)%s+[iI][fF]%s+(.+)$")
        if main and cond and #main >= 3 and #cond >= 3 then
            -- Guard: don't fire if MAIN itself starts with "if"
            -- (that's already if-first form).
            local mainLower = main:lower()
            -- Guard: don't fire when MAIN is a fragment/connective.
            -- Inputs like "but if you try" have MAIN="but" which is a
            -- coordinator, not a complete clause. Reordering produces
            -- weird "Eğer denedin, ama" output.
            local mainFirstWord = mainLower:match("^%s*(%w+)") or ""
            local FRAGMENT_HEADS = {
                ["but"] = true, ["and"] = true, ["or"] = true,
                ["so"] = true, ["because"] = true, ["yet"] = true,
            }
            if not mainLower:match("^%s*if%s")
               and not FRAGMENT_HEADS[mainFirstWord] then
                -- Also guard against "I lost my gun, can you help me"
                -- where comma already splits. The Mosaic comma-split
                -- handles that; we only want to fire on no-comma forms
                -- where the main clause and if-clause are uncomma'd.
                -- Heuristic: bail if MAIN contains a comma (let the
                -- comma-split handle it).
                if not main:find(",") then
                    -- Rewrite to if-first form. Capitalize "If" since
                    -- it'll be sentence-initial.
                    local rewritten = "If " .. cond .. ", " .. main .. term
                    if Mosaic._depth < Mosaic._MAX_DEPTH then
                        Mosaic._depth = Mosaic._depth + 1
                        local ok, r = pcall(Mosaic.translate, rewritten)
                        Mosaic._depth = Mosaic._depth - 1
                        if ok and r and r.output and r.output ~= "" then
                            -- Strip trailing terminator; buildResult adds it
                            local restTr = stripTrailingTerminator(r.output)
                            return buildResult(restTr, "cond_reorder")
                        end
                    end
                end
            end
        end
    end

    -- =====================================================================
    -- Pattern L: productive aorist-conditional "If <SUBJ> <VERB> ..."
    -- Generates Turkish aorist-conditional verb form productively, so any
    -- subject/verb combo (not just phrasebook-covered ones) gets the right
    -- "-irse/-irsen/-arsa..." morphology.
    --
    -- Examples:
    --   "If they come, we hide." -> "Gelirseler, saklanırız."
    --   "If he runs, hide."      -> "Koşarsa, saklan."
    --   "If I find it, tell you" -> "Onu bulursam, sana söylerim."
    --
    -- Tries phrasebook first for the if-clause (chat-natural idioms like
    -- "if you need help" → "Yardıma ihtiyacın olursa"), falls back to
    -- productive morphology otherwise.
    --
    -- Only fires when input is shaped "<if> <SUBJ> <VERB> [<OBJ>?] , <REST>".
    -- The comma is required (Pattern R handles no-comma case via reorder).
    -- Subjects: i, you, he, she, it, we, they.
    -- =====================================================================
    do
        local norm = input:match("^%s*(.-)%s*$") or ""
        local lower = norm:lower()
        local termless = lower:gsub("[%.%?!]+%s*$", "")
        local subj, ifClause, consequent =
            termless:match("^if%s+(%w+)%s+(.-),%s*(.+)$")
        if subj and ifClause and consequent then
            local SUBJ_TO_PERSON_FULL = {
                i = "1sg", you = "2sg", he = "3sg", she = "3sg",
                it = "3sg", we = "1pl", they = "3pl",
            }
            local person = SUBJ_TO_PERSON_FULL[subj]
            if person then
                -- Parse "verb" and optional "obj" from ifClause
                local verbWord, objWord = ifClause:match("^(%w+)%s+(%w+)$")
                local justVerb = ifClause:match("^(%w+)$")
                local verb = verbWord or justVerb
                local obj = objWord

                -- Step 1: get condClause Turkish form.
                local condClause
                if verb then
                    -- Try phrasebook for the full if-clause first.
                    local Phrasebook = require("TAZC_TranslatePhrasebook")
                    local pbEntry = Phrasebook.lookup(
                        "if " .. subj .. " " .. ifClause)
                    if pbEntry and pbEntry.tr then
                        condClause = stripTrailingTerminator(pbEntry.tr)
                    else
                        -- Productive: generate aorist-conditional
                        local entry = lookupVerbStem(verb)
                        if entry and entry.tr_stem then
                            local ok, condForm = pcall(
                                Morphology.applyAoristConditional,
                                entry.tr_stem, person)
                            if ok and condForm then
                                -- Translate object if present
                                local objTr
                                if obj then
                                    local OBJ_PRON_TR = {
                                        me = "Beni", you = "Seni",
                                        him = "Onu", her = "Onu",
                                        it = "Onu", us = "Bizi",
                                        them = "Onlar\196\177",
                                    }
                                    if OBJ_PRON_TR[obj] then
                                        objTr = OBJ_PRON_TR[obj]
                                    else
                                        -- Common-noun object: lex → ACC
                                        local entries = Lexicon.lookupAll(obj) or {}
                                        for _, e in ipairs(entries) do
                                            if e.pos == "NOUN" and e.tr then
                                                local accOk, accForm = pcall(
                                                    Morphology.applyAccusative,
                                                    e.tr,
                                                    { voicing = e.tr_final_voicing })
                                                if accOk and accForm then
                                                    objTr = accForm:sub(1,1):upper()
                                                        .. accForm:sub(2)
                                                end
                                                break
                                            end
                                        end
                                    end
                                end
                                if objTr then
                                    condClause = objTr .. " " .. condForm
                                else
                                    condClause = condForm:sub(1,1):upper()
                                        .. condForm:sub(2)
                                end
                            end
                        end
                    end
                end

                -- Step 2: if we got a condClause, assemble the output by
                -- recursively translating the consequent.
                if condClause then
                    local consequentInput = consequent
                    if not consequentInput:match("[%.%?!]$") then
                        consequentInput = consequentInput .. "."
                    end
                    consequentInput = consequentInput:sub(1,1):upper()
                        .. consequentInput:sub(2)
                    local subRes
                    if Mosaic._depth < Mosaic._MAX_DEPTH then
                        Mosaic._depth = Mosaic._depth + 1
                        local ok2, r = pcall(Mosaic.translate, consequentInput)
                        Mosaic._depth = Mosaic._depth - 1
                        if ok2 and r and r.output and r.output ~= "" then
                            subRes = r
                        end
                    end
                    if subRes and subRes.output then
                        local restTr = stripTrailingTerminator(subRes.output)
                        local TR_LOWER_MAP = {
                            ["\196\176"] = "i",
                            ["\196\177"] = "\196\177",
                            ["\196\158"] = "\196\159",
                            ["\195\135"] = "\195\167",
                            ["\197\158"] = "\197\159",
                            ["\195\150"] = "\195\182",
                            ["\195\156"] = "\195\188",
                        }
                        local twoByte = restTr:sub(1, 2)
                        if TR_LOWER_MAP[twoByte] then
                            restTr = TR_LOWER_MAP[twoByte] .. restTr:sub(3)
                        else
                            local firstChar = restTr:sub(1, 1)
                            if firstChar == "I" then
                                restTr = "\196\177" .. restTr:sub(2)
                            else
                                restTr = firstChar:lower() .. restTr:sub(2)
                            end
                        end
                        local out = condClause .. ", " .. restTr
                        return buildResult(out, "aorist_conditional")
                    end
                end
            end
        end
    end

    return nil
end
-- ---------------------------------------------------------------------------

function Mosaic.translate(input)
    if not input or input:match("^%s*$") then
        return {
            output      = "",
            clauses     = {},
            coverage    = 0,
            turkish_pct = 0,
            errors      = { "empty input" },
        }
    end

    -- 9.0+ phrasebook fast-path: try the WHOLE input against the
    -- phrasebook before any clause splitting. Without this, idioms
    -- that span clause boundaries (e.g. "let us know if you need help",
    -- "i don't know what to say") get split apart at the subordinator
    -- and the phrasebook entry never matches. Mirrors the fast-path
    -- in M.translate but at the dispatch layer above clause splitting.
    --
    -- Terminator handling matches Mosaic's existing convention for
    -- engine output: strip the phrasebook's terminator, then re-add
    -- the input's original terminator if it had one. This keeps the
    -- output's terminator faithful to the input regardless of how the
    -- phrasebook entry was written.
    do
        local Phrasebook = require("TAZC_TranslatePhrasebook")
        local pbEntry = Phrasebook.lookup(input)
        if pbEntry then
            local out = stripTrailingTerminator(pbEntry.tr)
            local inputTerm = input:match("([%.%?%!]+)%s*$")
            if inputTerm then
                out = out .. inputTerm:sub(-1)
            end
            return {
                output      = out,
                clauses     = { { text = input, output = out, kind = "phrasebook" } },
                coverage    = 1,
                turkish_pct = 1,
                errors      = {},
                trace       = { path = "phrasebook_whole_sentence", phrasebook_id = pbEntry.id },
            }
        end
    end

    -- 9.1+ embedded-WH-clause productive rewriter. The engine's role
    -- assignment can't currently handle WH-clauses as nominal complements
    -- of matrix verbs (would need -DIK/-ACAK + POSS + ACC nominalizer in
    -- the engine pipeline, plus reordering rules for Turkish SOV).
    -- Instead, we detect productive embedded-WH patterns at the Mosaic
    -- layer and compose the translation directly using the morphology
    -- helpers + lex lookups. Tries pattern by pattern; bails to the
    -- engine if no pattern matches or any piece is missing.
    do
        local rewritten = Mosaic.tryEmbeddedWHRewrite(input)
        if rewritten then
            return rewritten
        end
    end

    local clauses = Mosaic.splitClauses(input)
    local results = {}
    local totalTokens, totalCovered = 0, 0
    local turkishClauseCount, totalClauses = 0, 0
    local outputParts = {}

    for clauseIdx, cl in ipairs(clauses) do
        local tokens = wordCount(cl.text)
        totalClauses = totalClauses + 1
        local isLastClause = (clauseIdx == #clauses)
        -- A clause is "mid-sentence" when its separator is a soft boundary
        -- (comma/semicolon) and we're going to continue with another
        -- clause. Mid-sentence clauses get post-processing: strip the
        -- engine's auto-appended terminator, lowercase first letter.
        local nextIsContinuation = (cl.sep == ","
            or cl.sep:match("^,%s") or cl.sep:match("^;%s?")
            or cl.sep == ";") and not isLastClause
        local isAfterContinuation = (clauseIdx > 1)
            and clauses[clauseIdx - 1]
            and not clauses[clauseIdx - 1].endOfSentence

        if tokens < Mosaic.MIN_CLAUSE_TOKENS then
            -- Too short to be worth processing — passthrough.
            local r = { kind = "passthrough_short", text = cl.text, coverage = 0 }
            table.insert(results, r)
            table.insert(outputParts, cl.text)
        else
            -- 9.0+ bugfix: the splitter put sentence-final terminator (. ? !)
            -- into the sep field, but the engine relies on the terminator to
            -- distinguish question constructions (WH-questions need ?, yes/no
            -- need ?, etc.). Append the terminator back to the clause text
            -- when passing to translate so the engine sees it.
            local clauseTextForEngine = cl.text
            if cl.endOfSentence then
                local termInSep = cl.sep:match("([%.%?%!]+)")
                if termInSep then
                    -- Use just the LAST terminator char (most semantic):
                    -- "?!" => "?", "..." => "."
                    local last = termInSep:sub(-1)
                    clauseTextForEngine = cl.text .. last
                end
            end
            -- 9.1.3+ per-clause productive rewriter. Try Pattern G/H/etc.
            -- against the individual clause text, not just the full input.
            -- This lets multi-clause sentences benefit: "I have no water
            -- but there is water in the bottle" gets the rewriter applied
            -- to each clause separately, producing natural Turkish on both
            -- sides of the conjunction.
            --
            -- Falls back to Translate.translate if no pattern matches.
            local res
            local clauseRewrite = Mosaic.tryEmbeddedWHRewrite(clauseTextForEngine)
            if clauseRewrite then
                res = {
                    ok        = true,
                    output    = stripTrailingTerminator(clauseRewrite.output),
                    trace     = clauseRewrite.trace,
                    errors    = clauseRewrite.errors or {},
                    direction = "en-to-tr",
                    coverage  = 1,
                }
            else
                res = Translate.translate(clauseTextForEngine)
            end
            local clauseCoverage = res.coverage or 0
            -- For phrasebook hits, coverage isn't populated. If the engine
            -- returned non-partial output, treat it as fully covered.
            if (not res.coverage) and res.ok and not res.partial then
                clauseCoverage = 1
            end
            totalTokens = totalTokens + tokens
            totalCovered = totalCovered + math.floor(clauseCoverage * tokens + 0.5)

            -- 9.0+ Mosaic: variable threshold by clause length. Short
            -- clauses (1-3 tokens) get a relaxed threshold (0.5) because
            -- a single unknown drags ratio coverage hard ("strong allies"
            -- at 0.50 is half-known, but the structural unit is just an
            -- ADJ+NOUN). Longer clauses keep 0.6 — they have more room
            -- to absorb a stray leak and the ratio is more meaningful.
            local effectiveThreshold = Mosaic.MOSAIC_THRESHOLD
            if tokens <= 3 then
                effectiveThreshold = 0.5
            end

            if res.ok and res.output and clauseCoverage >= effectiveThreshold then
                local text = res.output
                -- ALWAYS strip the engine's auto-appended terminator. The
                -- splitter already preserved the original input's terminator
                -- as the clause separator, so re-attaching the engine's
                -- terminator on top would double up (e.g. "Yes." -> engine
                -- emits "Evet." + splitter sep "." -> "Evet..").
                text = stripTrailingTerminator(text)
                -- Lowercase first letter if this clause follows a soft
                -- separator from the previous clause (mid-sentence).
                if isAfterContinuation then
                    text = lowerFirstChar(text)
                end
                table.insert(results, {
                    kind     = "turkish",
                    input    = cl.text,
                    text     = text,
                    coverage = clauseCoverage,
                    engine   = res,
                })
                table.insert(outputParts, text)
                turkishClauseCount = turkishClauseCount + 1
            else
                -- Below threshold — pass original English through.
                table.insert(results, {
                    kind     = "english_passthrough",
                    input    = cl.text,
                    text     = cl.text,
                    coverage = clauseCoverage,
                    engine   = res,
                })
                table.insert(outputParts, cl.text)
            end
        end
        -- Append the separator. 9.0+: when the sep contains an English
        -- coordinator/subordinator inserted by the splitter, translate
        -- the conjunction to its Turkish equivalent. The sep also holds
        -- spaces/punctuation that we preserve untouched. "or" is treated
        -- as disjunctive-question "yoksa" because softSplitOrClause only
        -- fires in the AUX-follower context (Q1 or Q2? structure); the
        -- statement-level " ya da " sense never reaches this splitter
        -- path since word-level "or" coordination stays inside the
        -- engine via Pass 2.7.
        local translatedSep = cl.sep
        translatedSep = translatedSep:gsub("(%s)or(%s)",     "%1yoksa%2")
        translatedSep = translatedSep:gsub("(%s)but(%s)",    "%1ama%2")
        translatedSep = translatedSep:gsub("(%s)and(%s)",    "%1ve%2")
        translatedSep = translatedSep:gsub("(%s)because(%s)","%1\195\167\195\188nk\195\188%2")  -- çünkü
        translatedSep = translatedSep:gsub("(%s)cause(%s)",  "%1\195\167\195\188nk\195\188%2")
        translatedSep = translatedSep:gsub("(%s)so(%s)",     "%1yani%2")
        -- 9.0+: subordinators "if" and "when" route through Mosaic's
        -- softSplitConjGuarded so they appear as inter-clause separators.
        -- "if" -> "eğer" (Turkish conditional marker, goes before the
        -- conditional clause). "when" -> "ne zaman" (when, temporal).
        translatedSep = translatedSep:gsub("(%s)if(%s)",     "%1e\195\159er%2")  -- eğer
        translatedSep = translatedSep:gsub("(%s)when(%s)",   "%1ne zaman%2")
        table.insert(outputParts, translatedSep)
    end

    local output = table.concat(outputParts)
    local coverage = (totalTokens > 0) and (totalCovered / totalTokens) or 0
    local turkish_pct = (totalClauses > 0) and (turkishClauseCount / totalClauses) or 0

    return {
        output      = output,
        clauses     = results,
        coverage    = coverage,
        turkish_pct = turkish_pct,
        errors      = {},
    }
end

return Mosaic
