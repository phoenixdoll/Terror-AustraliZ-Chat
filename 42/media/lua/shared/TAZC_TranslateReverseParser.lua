-- ============================================================================
-- TAZC_TranslateReverseParser -- Turkish morphological analyzer.
--
-- Implements TRANSLATOR_SPEC.md section 14.2: longest-suffix-match with
-- backtracking. For each Turkish surface token, attempt to decompose it
-- into a stem plus a suffix chain such that the stem matches a lexicon
-- entry. The chain encodes tense, aspect, person/number, case, and
-- plurality.
--
-- Algorithm (per-token):
--   1. Try the whole token as a bare lemma (lexicon hit).
--   2. Try recognized inflection patterns in priority order:
--      a. Verb: present progressive (-iyor + PERSON)
--      b. Verb: past tense (-DI + PERSON)
--      c. Verb: aorist negative (-mE-PERSON merged)
--      d. Noun: plural + accusative (-lEr-I)
--      e. Noun: plural only (-lEr)
--      f. Noun: accusative only (-I with optional unvoicing)
--      g. Copular predicate: ADJ/NOUN + person/number suffix
--   3. Verify vowel harmony of any suffix chain found.
--   4. Return analysis with morpheme glosses, or nil.
--
-- Sentence-level reconstruction (parseSentence):
--   - Per-token morphological analysis as above.
--   - Identify the head verb (or copular predicate) from the analyzed tokens.
--   - Recover the subject: if explicit (a SUBJECT_NOUN token), use it;
--     otherwise infer from the verb's person/number agreement.
--   - Identify objects (accusative-marked = definite; bare = indefinite).
--   - Generate English using SVO word order with appropriate articles,
--     auxiliaries, and morphology.
--
-- Asymmetric quality: per spec design philosophy, Turkish-to-English need
-- not be polished. The goal is comprehensible English that a reader can
-- understand even if the prose is awkward. Article selection ("a" vs "the"
-- vs nothing) is rule-based and may not match natural English in every case.
-- ============================================================================

local Lexicon = require("TAZC_TranslateLexicon")

local M = {}
M.VERSION = "0.1"

-- ---------------------------------------------------------------------------
-- Vowel sets (mirror morphology module for harmony classification)
-- ---------------------------------------------------------------------------

local FRONT_UNROUNDED = { ["e"] = true, ["i"] = true }
local FRONT_ROUNDED   = { ["\195\182"] = true, ["\195\188"] = true }  -- ö, ü
local BACK_UNROUNDED  = { ["a"] = true, ["\196\177"] = true }         -- a, ı
local BACK_ROUNDED    = { ["o"] = true, ["u"] = true }

local function isVowel(c)
    return FRONT_UNROUNDED[c] or FRONT_ROUNDED[c]
        or BACK_UNROUNDED[c] or BACK_ROUNDED[c]
end

-- ---------------------------------------------------------------------------
-- UTF-8 helpers
-- ---------------------------------------------------------------------------

-- Shared UTF-8 helpers. See TAZC_StringUtils.lua for the rationale behind the
-- VM-portable iteration; the same module is used by TAZC_Translate and
-- TAZC_TranslateMorphology.
local Str = require("TAZC_StringUtils")
local utf8chars = Str.utf8chars
local utf8len   = Str.utf8len
local lastChar  = Str.lastChar
local dropLast  = Str.dropLast

local function endsWith(s, suffix)
    if #suffix > #s then return false end
    return s:sub(-#suffix) == suffix
end

-- ---------------------------------------------------------------------------
-- Turkish-aware case folding. Lua's :lower() only handles ASCII; for Turkish
-- we need to map capitals to their lowercase forms with the correct
-- dotted/dotless asymmetry:
--   İ (U+0130, dotted capital I) -> i (dotted)
--   I (U+0049, ASCII capital I)  -> ı (dotless)
-- ---------------------------------------------------------------------------

local TR_LOWER = {
    ["\196\176"] = "i",       -- İ -> i
    ["I"]        = "\196\177",-- I -> ı  (note: this differs from ASCII lower)
    ["\195\135"] = "\195\167",-- Ç -> ç
    ["\197\158"] = "\197\159",-- Ş -> ş
    ["\196\158"] = "\196\159",-- Ğ -> ğ
    ["\195\150"] = "\195\182",-- Ö -> ö
    ["\195\156"] = "\195\188",-- Ü -> ü
}

local function lowerTurkish(s)
    local out = {}
    for ch in utf8chars(s) do
        table.insert(out, TR_LOWER[ch] or ch:lower())
    end
    return table.concat(out)
end

M.lowerTurkish = lowerTurkish

local function lookupTr(stem)
    if not stem or stem == "" then return nil end
    -- Use lazy lookup so users can type "icmek" for "içmek", "ogretmen"
    -- for "öğretmen", etc. The lazy flag is tracked so callers can mark
    -- the trace, but the lookup behaviour is the same -- find the entry
    -- if it exists, however the diacritics are typed.
    local entry, lazy = Lexicon.lookupTurkishLazy(stem)
    if entry then
        -- Annotate when the match was lazy (diacritic-stripped) so the
        -- reverse parser's confidence scoring can downgrade
        return entry, lazy
    end
    return nil, false
end

-- ---------------------------------------------------------------------------
-- Unvoicing: reverse the t->d / k->soft-g / p->b / ç->c map. Used when
-- looking up a stem that may have been voiced under intervocalic position.
-- ---------------------------------------------------------------------------

local UNVOICE = {
    ["d"] = "t",
    ["\196\159"] = "k",  -- soft g -> k
    ["b"] = "p",
    ["c"] = "\195\167",  -- c -> ç
}

local function tryUnvoice(stem)
    local last = lastChar(stem)
    local mapped = UNVOICE[last]
    if not mapped then return nil end
    return dropLast(stem) .. mapped
end

-- Lookup with both literal and unvoiced fallback. Returns the entry and
-- a flag indicating whether unvoicing was applied.
local function lookupTrWithUnvoice(stem)
    local entry = lookupTr(stem)
    if entry then return entry, false end
    local unvoiced = tryUnvoice(stem)
    if unvoiced then
        entry = lookupTr(unvoiced)
        if entry then return entry, true end
    end
    return nil, false
end

-- Verb-stem-only lookup. After stripping verb morphology (-iyor, -DI,
-- aorist), callers expect to find a VERB entry by tr_stem. The general
-- lookupTr is surface-first, which picks up adjectives like "aç" before
-- their homonymous verb stems (open.v has tr_stem="aç" too). Routing
-- through Lexicon.lookupTurkishVerbStemLazy returns only verb entries.
local function lookupTrVerb(stem)
    if not stem or stem == "" then return nil end
    local entry, lazy = Lexicon.lookupTurkishVerbStemLazy(stem)
    if entry then return entry, lazy end
    return nil, false
end

local function lookupTrVerbWithUnvoice(stem)
    local entry = lookupTrVerb(stem)
    if entry then return entry, false end
    local unvoiced = tryUnvoice(stem)
    if unvoiced then
        entry = lookupTrVerb(unvoiced)
        if entry then return entry, true end
    end
    return nil, false
end

-- ---------------------------------------------------------------------------
-- Suffix patterns (priority-ordered longest-first within each family)
-- ---------------------------------------------------------------------------

-- Present-progressive personal endings (after -iyor). The "-yor" suffix
-- always presents a back-rounded "o" to the next suffix, so the personal
-- endings are uniform (no harmony variation in this position).
local PROG_PERSON_ENDINGS = {
    { form = "sunuz", person = 2, number = "pl" },
    { form = "lar",   person = 3, number = "pl" },
    { form = "sun",   person = 2, number = "sg" },
    { form = "um",    person = 1, number = "sg" },
    { form = "uz",    person = 1, number = "pl" },
    { form = "",      person = 3, number = "sg" },  -- bare = 3sg
}

-- Past-tense personal endings (after -DI buffer). Harmony-sensitive:
-- 2pl and 3pl have four variants matching the buffer vowel.
local PAST_PERSON_ENDINGS = {
    { form = "niz",   person = 2, number = "pl" },
    { form = "n\196\177z", person = 2, number = "pl" },
    { form = "nuz",   person = 2, number = "pl" },
    { form = "n\195\188z", person = 2, number = "pl" },
    { form = "ler",   person = 3, number = "pl" },
    { form = "lar",   person = 3, number = "pl" },
    { form = "m",     person = 1, number = "sg" },
    { form = "n",     person = 2, number = "sg" },
    { form = "k",     person = 1, number = "pl" },
    { form = "",      person = 3, number = "sg" },
}

-- Aorist negative full endings (stem-attaching, no buffer).
local AORIST_NEG_ENDINGS = {
    { form = "mezsiniz", person = 2, number = "pl" },
    { form = "maz\196\177n\196\177z", person = 2, number = "pl" },
    { form = "meyiz",  person = 1, number = "pl" },
    { form = "may\196\177z", person = 1, number = "pl" },
    { form = "mezler", person = 3, number = "pl" },
    { form = "mazlar", person = 3, number = "pl" },
    { form = "mezsin", person = 2, number = "sg" },
    { form = "mazs\196\177n", person = 2, number = "sg" },
    { form = "mem",    person = 1, number = "sg" },
    { form = "mam",    person = 1, number = "sg" },
    { form = "mez",    person = 3, number = "sg" },
    { form = "maz",    person = 3, number = "sg" },
}

-- Copular endings (4-way harmony). The first letter may be 's' (consonant)
-- or a vowel; when on a vowel-final predicate, a y-buffer is inserted that
-- we must also strip.
local COPULAR_ENDINGS = {
    -- 2pl (longest first)
    { form = "siniz", person = 2, number = "pl" },
    { form = "s\196\177n\196\177z", person = 2, number = "pl" },
    { form = "sunuz", person = 2, number = "pl" },
    { form = "s\195\188n\195\188z", person = 2, number = "pl" },
    -- 3pl
    { form = "lar",   person = 3, number = "pl" },
    { form = "ler",   person = 3, number = "pl" },
    -- 2sg
    { form = "sin",   person = 2, number = "sg" },
    { form = "s\196\177n", person = 2, number = "sg" },
    { form = "sun",   person = 2, number = "sg" },
    { form = "s\195\188n", person = 2, number = "sg" },
    -- 1sg
    { form = "im",    person = 1, number = "sg" },
    { form = "\196\177m", person = 1, number = "sg" },
    { form = "um",    person = 1, number = "sg" },
    { form = "\195\188m", person = 1, number = "sg" },
    -- 1pl
    { form = "iz",    person = 1, number = "pl" },
    { form = "\196\177z", person = 1, number = "pl" },
    { form = "uz",    person = 1, number = "pl" },
    { form = "\195\188z", person = 1, number = "pl" },
}

-- Plural marker (2-way harmony)
local PLURAL_FORMS = { "lar", "ler" }

-- Accusative marker (4-way harmony)
local ACCUSATIVE_FORMS = { "i", "\196\177", "u", "\195\188" }  -- i, ı, u, ü

-- ---------------------------------------------------------------------------
-- Per-analyzer functions. Each returns analysis table or nil.
-- ---------------------------------------------------------------------------

local function tryBareLemma(token)
    local entry = lookupTr(token)
    if entry then
        local kind = "BARE_" .. entry.pos
        return {
            lemma_entry = entry,
            features = { kind = kind },
            morphemes = { { surface = token, gloss = "LEMMA(" .. entry.id .. ")" } },
            confidence = "high",
        }
    end
    return nil
end

local function tryPresentProgressive(token)
    -- Strip personal ending
    for _, p in ipairs(PROG_PERSON_ENDINGS) do
        if (p.form == "" or endsWith(token, p.form)) then
            local afterPerson = (p.form == "") and token or token:sub(1, -#p.form - 1)
            -- Strip -iyor (or -üyor variant for front-rounded harmony class)
            local yorVariants = { "iyor", "\196\177yor", "uyor", "\195\188yor" }
            for _, yor in ipairs(yorVariants) do
                if endsWith(afterPerson, yor) then
                    local stem = afterPerson:sub(1, -#yor - 1)
                    if stem ~= "" then
                        -- Try lookup as-is
                        local entry, voiced = lookupTrVerbWithUnvoice(stem)
                        if entry and entry.pos == "VERB" then
                            return {
                                lemma_entry = entry,
                                features = {
                                    kind = "VERB", tense = "PRESENT_PROGRESSIVE",
                                    person = p.person, number = p.number,
                                    voiced = voiced,
                                },
                                morphemes = {
                                    { surface = entry.tr_stem, gloss = "STEM(" .. entry.id .. ")" },
                                    { surface = yor, gloss = "PROG" },
                                    { surface = (p.form == "" and "(0)" or p.form),
                                      gloss = string.upper(p.number) .. "." .. p.person .. "P" },
                                },
                                confidence = "high",
                            }
                        end

                        -- Also try lookup after restoring a vowel that was deleted
                        -- by the stem-final-vowel deletion rule: for vowel-final
                        -- original stems like "ye", the suffix attaches as
                        -- y+iyor=yiyor. To recover, try appending plausible vowels.
                        for _, v in ipairs({ "e", "a", "i", "o", "u",
                                              "\195\182", "\195\188", "\196\177" }) do
                            local restored = stem .. v
                            local restoredEntry = lookupTrVerb(restored)
                            if restoredEntry and restoredEntry.pos == "VERB" then
                                return {
                                    lemma_entry = restoredEntry,
                                    features = {
                                        kind = "VERB", tense = "PRESENT_PROGRESSIVE",
                                        person = p.person, number = p.number,
                                        vowel_restored = v,
                                    },
                                    morphemes = {
                                        { surface = restoredEntry.tr_stem,
                                          gloss = "STEM(" .. restoredEntry.id .. ", final-vowel-deleted)" },
                                        { surface = yor, gloss = "PROG" },
                                        { surface = (p.form == "" and "(0)" or p.form),
                                          gloss = string.upper(p.number) .. "." .. p.person .. "P" },
                                    },
                                    confidence = "medium",  -- restored, not exact
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function tryPast(token)
    -- Try each personal ending (longest first)
    for _, p in ipairs(PAST_PERSON_ENDINGS) do
        if (p.form == "" or endsWith(token, p.form)) then
            local afterPerson = (p.form == "") and token or token:sub(1, -#p.form - 1)
            -- Strip -DI buffer (di/dı/du/dü or ti/tı/tu/tü)
            local pastSuffixes = {
                "di", "d\196\177", "du", "d\195\188",
                "ti", "t\196\177", "tu", "t\195\188",
            }
            for _, sfx in ipairs(pastSuffixes) do
                if endsWith(afterPerson, sfx) then
                    local stem = afterPerson:sub(1, -#sfx - 1)
                    if stem ~= "" then
                        local entry, voiced = lookupTrVerbWithUnvoice(stem)
                        if entry and entry.pos == "VERB" then
                            return {
                                lemma_entry = entry,
                                features = {
                                    kind = "VERB", tense = "PAST",
                                    person = p.person, number = p.number,
                                    voiced = voiced,
                                },
                                morphemes = {
                                    { surface = entry.tr_stem, gloss = "STEM(" .. entry.id .. ")" },
                                    { surface = sfx, gloss = "PAST" },
                                    { surface = (p.form == "" and "(0)" or p.form),
                                      gloss = string.upper(p.number) .. "." .. p.person .. "P" },
                                },
                                confidence = "high",
                            }
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function tryAoristNegative(token)
    for _, e in ipairs(AORIST_NEG_ENDINGS) do
        if endsWith(token, e.form) then
            local stem = token:sub(1, -#e.form - 1)
            if stem ~= "" then
                local entry = lookupTrVerb(stem)
                if entry and entry.pos == "VERB" then
                    return {
                        lemma_entry = entry,
                        features = {
                            kind = "VERB", tense = "AORIST_NEGATIVE",
                            person = e.person, number = e.number,
                        },
                        morphemes = {
                            { surface = entry.tr_stem, gloss = "STEM(" .. entry.id .. ")" },
                            { surface = e.form,
                              gloss = "AOR.NEG." .. string.upper(e.number) .. "." .. e.person .. "P" },
                        },
                        confidence = "high",
                    }
                end
            end
        end
    end
    return nil
end

-- Noun analysis: handle plural + accusative chain, plural only, accusative
-- only, and bare. Each can have voicing applied to the stem.
local function tryNoun(token)
    -- Try plural + accusative chain: STEM + lar/ler + I
    for _, pl in ipairs(PLURAL_FORMS) do
        for _, acc in ipairs(ACCUSATIVE_FORMS) do
            local chain = pl .. acc
            if endsWith(token, chain) then
                local stem = token:sub(1, -#chain - 1)
                if stem ~= "" then
                    local entry, voiced = lookupTrWithUnvoice(stem)
                    if entry and entry.pos == "NOUN" then
                        return {
                            lemma_entry = entry,
                            features = {
                                kind = "NOUN", isPlural = true, definite = true,
                                voiced = voiced,
                            },
                            morphemes = {
                                { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                                { surface = pl, gloss = "PL" },
                                { surface = acc, gloss = "ACC" },
                            },
                            confidence = "high",
                        }
                    end
                end
            end
        end
    end

    -- Try plural only: STEM + lar/ler
    for _, pl in ipairs(PLURAL_FORMS) do
        if endsWith(token, pl) then
            local stem = token:sub(1, -#pl - 1)
            if stem ~= "" then
                local entry, voiced = lookupTrWithUnvoice(stem)
                if entry and entry.pos == "NOUN" then
                    return {
                        lemma_entry = entry,
                        features = {
                            kind = "NOUN", isPlural = true, definite = false,
                            voiced = voiced,
                        },
                        morphemes = {
                            { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                            { surface = pl, gloss = "PL" },
                        },
                        confidence = "high",
                    }
                end
            end
        end
    end

    -- Try accusative only: STEM + I (with possible voicing of stem-final consonant)
    -- OR STEM(vowel-final) + y + I (y-buffer for vowel-final stems like "su" -> "suyu")
    for _, acc in ipairs(ACCUSATIVE_FORMS) do
        if endsWith(token, acc) then
            local stem = token:sub(1, -#acc - 1)
            if stem ~= "" then
                -- First try stem as-is
                local entry, voiced = lookupTrWithUnvoice(stem)
                if entry and entry.pos == "NOUN" then
                    return {
                        lemma_entry = entry,
                        features = {
                            kind = "NOUN", isPlural = false, definite = true,
                            voiced = voiced,
                        },
                        morphemes = {
                            { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                            { surface = acc, gloss = "ACC" },
                        },
                        confidence = "high",
                    }
                end
                -- Try y-buffer: stem ends in 'y' that was inserted between
                -- vowel-final stem and vowel-initial suffix
                if endsWith(stem, "y") then
                    local stemNoY = dropLast(stem)
                    local lastBefore = lastChar(stemNoY)
                    if lastBefore and isVowel(lastBefore) then
                        entry = lookupTr(stemNoY)
                        if entry and entry.pos == "NOUN" then
                            return {
                                lemma_entry = entry,
                                features = {
                                    kind = "NOUN", isPlural = false, definite = true,
                                },
                                morphemes = {
                                    { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                                    { surface = "y", gloss = "Y-BUFFER" },
                                    { surface = acc, gloss = "ACC" },
                                },
                                confidence = "high",
                            }
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- Copular predicate analysis: ADJ or NOUN + person/number suffix
local function tryCopular(token)
    for _, e in ipairs(COPULAR_ENDINGS) do
        if endsWith(token, e.form) then
            local stem = token:sub(1, -#e.form - 1)
            if stem ~= "" then
                -- Y-buffer is inserted before vowel-initial endings on
                -- vowel-final predicates. Check if stem ends in y followed
                -- by previous vowel-final form.
                local stemNoBuffer = stem
                if endsWith(stem, "y") then
                    local before = dropLast(stem)
                    local lastBefore = lastChar(before)
                    if lastBefore and isVowel(lastBefore) then
                        stemNoBuffer = before  -- strip the y-buffer too
                    end
                end

                -- Special case: stem is "değil", the Turkish negation particle.
                -- This indicates a negated copular construction. The actual
                -- predicate (ADJ/NOUN) is in the PRECEDING token, handled at
                -- the sentence-reconstruction level. Here we just mark this
                -- token as the negator carrying the agreement suffix.
                if stemNoBuffer == "de\196\159il" then
                    return {
                        lemma_entry = nil,  -- not a regular lexicon hit
                        features = {
                            kind = "NEG_COPULAR",
                            person = e.person, number = e.number,
                        },
                        morphemes = {
                            { surface = "de\196\159il", gloss = "NEG.COP" },
                            { surface = e.form,
                              gloss = "COP." .. string.upper(e.number) .. "." .. e.person .. "P" },
                        },
                        confidence = "high",
                    }
                end

                local entry = lookupTr(stemNoBuffer)
                if entry and (entry.pos == "ADJ" or entry.pos == "NOUN") then
                    return {
                        lemma_entry = entry,
                        features = {
                            kind = "COPULAR",
                            predicate_pos = entry.pos,
                            person = e.person, number = e.number,
                        },
                        morphemes = {
                            { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                            { surface = e.form,
                              gloss = "COP." .. string.upper(e.number) .. "." .. e.person .. "P" },
                        },
                        confidence = "high",
                    }
                end
            end
        end
    end

    -- Also handle bare "değil" with no copular suffix (3sg, zero suffix case).
    -- e.g., "Hasta değil." = "She is not sick."
    if token == "de\196\159il" then
        return {
            lemma_entry = nil,
            features = {
                kind = "NEG_COPULAR",
                person = 3, number = "sg",
            },
            morphemes = {
                { surface = "de\196\159il", gloss = "NEG.COP" },
                { surface = "\195\152",      gloss = "COP.SG.3P (zero)" },
            },
            confidence = "high",
        }
    end

    return nil
end

-- Possessive suffix patterns (longest-first per person). Each entry has the
-- forms to strip when the stem ends in a consonant (afterC) and when the
-- stem ends in a vowel (afterV). The 4-way harmony variants are listed
-- explicitly so longest-match-first works correctly.
local POSSESSIVE_SUFFIXES = {
    -- 1pl (longest): VmVz / mVz
    { form = "imiz",          person = 1, number = "pl", afterC = true },
    { form = "\196\177m\196\177z", person = 1, number = "pl", afterC = true },
    { form = "umuz",          person = 1, number = "pl", afterC = true },
    { form = "\195\188m\195\188z", person = 1, number = "pl", afterC = true },
    { form = "miz",           person = 1, number = "pl", afterC = false },
    { form = "m\196\177z",    person = 1, number = "pl", afterC = false },
    { form = "muz",           person = 1, number = "pl", afterC = false },
    { form = "m\195\188z",    person = 1, number = "pl", afterC = false },
    -- 2pl
    { form = "iniz",          person = 2, number = "pl", afterC = true },
    { form = "\196\177n\196\177z", person = 2, number = "pl", afterC = true },
    { form = "unuz",          person = 2, number = "pl", afterC = true },
    { form = "\195\188n\195\188z", person = 2, number = "pl", afterC = true },
    { form = "niz",           person = 2, number = "pl", afterC = false },
    { form = "n\196\177z",    person = 2, number = "pl", afterC = false },
    { form = "nuz",           person = 2, number = "pl", afterC = false },
    { form = "n\195\188z",    person = 2, number = "pl", afterC = false },
    -- 3pl: -ları / -leri (back/front)
    { form = "lar\196\177",   person = 3, number = "pl", afterC = "any" },
    { form = "leri",          person = 3, number = "pl", afterC = "any" },
    -- 3sg vowel-final: -sV
    { form = "si",            person = 3, number = "sg", afterC = false },
    { form = "s\196\177",     person = 3, number = "sg", afterC = false },
    { form = "su",            person = 3, number = "sg", afterC = false },
    { form = "s\195\188",     person = 3, number = "sg", afterC = false },
    -- 1sg: -V-m / -m
    { form = "im",            person = 1, number = "sg", afterC = true },
    { form = "\196\177m",     person = 1, number = "sg", afterC = true },
    { form = "um",            person = 1, number = "sg", afterC = true },
    { form = "\195\188m",     person = 1, number = "sg", afterC = true },
    { form = "m",             person = 1, number = "sg", afterC = false },
    -- 2sg: -V-n / -n
    { form = "in",            person = 2, number = "sg", afterC = true },
    { form = "\196\177n",     person = 2, number = "sg", afterC = true },
    { form = "un",            person = 2, number = "sg", afterC = true },
    { form = "\195\188n",     person = 2, number = "sg", afterC = true },
    { form = "n",             person = 2, number = "sg", afterC = false },
    -- 3sg consonant-final: -V (overlaps with accusative; sentence-level
    -- disambiguation picks possessive when var/yok is present)
    { form = "i",             person = 3, number = "sg", afterC = true },
    { form = "\196\177",      person = 3, number = "sg", afterC = true },
    { form = "u",             person = 3, number = "sg", afterC = true },
    { form = "\195\188",      person = 3, number = "sg", afterC = true },
}

local function tryPossessive(token)
    for _, s in ipairs(POSSESSIVE_SUFFIXES) do
        if endsWith(token, s.form) then
            local stem = token:sub(1, -#s.form - 1)
            if stem ~= "" then
                -- Determine if stem ends in vowel (relevant for afterC check)
                local stemLast = lastChar(stem)
                local stemVowelFinal = isVowel(stemLast)

                -- For afterC = true entries, only match if stem is consonant-final
                -- For afterC = false entries, only match if stem is vowel-final
                -- For afterC = "any" entries, match either
                if s.afterC == "any"
                    or (s.afterC == true and not stemVowelFinal)
                    or (s.afterC == false and stemVowelFinal) then
                    local entry, voiced = lookupTrWithUnvoice(stem)
                    if entry and entry.pos == "NOUN" then
                        return {
                            lemma_entry = entry,
                            features = {
                                kind = "POSSESSED_NOUN",
                                person = s.person, number = s.number,
                                voiced = voiced,
                            },
                            morphemes = {
                                { surface = entry.tr, gloss = "STEM(" .. entry.id .. ")" },
                                { surface = s.form,
                                  gloss = "POSS." .. string.upper(s.number) .. "." .. s.person .. "P" },
                            },
                            confidence = "medium",
                        }
                    end
                end
            end
        end
    end
    return nil
end

local function tryExistentialParticle(token)
    if token == "var" then
        return {
            lemma_entry = nil,
            features = { kind = "EXIS_PARTICLE", negated = false },
            morphemes = { { surface = "var", gloss = "EXIS" } },
            confidence = "high",
        }
    elseif token == "yok" then
        return {
            lemma_entry = nil,
            features = { kind = "EXIS_PARTICLE", negated = true },
            morphemes = { { surface = "yok", gloss = "EXIS.NEG" } },
            confidence = "high",
        }
    end
    return nil
end

-- "bir" is the Turkish indefinite/cardinal marker. It's not in the
-- lexicon (it's a function word, not a content word) but appears in
-- both forward output and reverse-direction input. Treat as a soft
-- recognised token that contributes no semantic content but doesn't
-- fail the parse.
local function tryIndefMarker(token)
    if token == "bir" then
        return {
            lemma_entry = nil,
            features = { kind = "INDEF_MARKER" },
            morphemes = { { surface = "bir", gloss = "INDEF" } },
            confidence = "high",
        }
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Top-level per-token analyzer
-- ---------------------------------------------------------------------------

function M.analyzeToken(token, opts)
    if not token or token == "" then return nil end
    opts = opts or {}
    token = lowerTurkish(token)

    -- Try analyzers in priority order. Bare lemma first because it's the
    -- fastest and unambiguous when it succeeds. Existential particle is
    -- checked early since "var" / "yok" are single-token recognisable.
    --
    -- Context-sensitive ordering:
    --   - existential_context = true  -> possessive wins over copular
    --     (because in an existential, "Doktorum" -> "my doctor" not
    --      "I am a doctor")
    --   - default                     -> copular wins over possessive
    --     (standalone "Doktorum" reads as "I am a doctor")
    local analyses
    if opts.existential_context then
        analyses = {
            tryExistentialParticle,
            tryIndefMarker,
            tryBareLemma,
            tryPresentProgressive,
            tryPast,
            tryAoristNegative,
            tryNoun,
            tryPossessive,
            tryCopular,
        }
    else
        analyses = {
            tryExistentialParticle,
            tryIndefMarker,
            tryBareLemma,
            tryPresentProgressive,
            tryPast,
            tryAoristNegative,
            tryNoun,
            tryCopular,
            tryPossessive,  -- after copular in default context
        }
    end
    for _, fn in ipairs(analyses) do
        local result = fn(token)
        if result then return result end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Tokenize Turkish input. Splits on whitespace, strips trailing terminator.
-- ---------------------------------------------------------------------------

local function tokenize(text)
    -- Strip trailing terminator
    local terminator = text:match("[%.%?!]$") or ""
    local body = (terminator == "") and text or text:sub(1, -2)
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    local tokens = {}
    for word in body:gmatch("%S+") do
        table.insert(tokens, word)
    end
    return tokens, terminator
end

-- ---------------------------------------------------------------------------
-- Pronoun reconstruction from verb agreement.
-- ---------------------------------------------------------------------------

local PRONOUN_FROM_AGREEMENT = {
    [1] = { sg = "I",   pl = "We" },
    [2] = { sg = "you", pl = "you" },
    [3] = { sg = "she", pl = "they" },  -- default to she for 3sg; could be he/it
}

-- ---------------------------------------------------------------------------
-- English generation from a list of analyzed tokens.
--
-- Strategy: identify the predicate (verb or copular), recover the implicit
-- subject from agreement or use an explicit subject noun, place objects
-- before the verb in source-language order is irrelevant -- English wants
-- SVO. Articles for nouns are derived from the accusative/plural features.
-- ---------------------------------------------------------------------------

local function englishVerbForm(lemma_entry, tense, person, number)
    local lemma = lemma_entry.en
    local pn = tostring(person) .. number

    if tense == "PRESENT_PROGRESSIVE" then
        local aux
        if pn == "1sg" then aux = "am"
        elseif pn == "3sg" then aux = "is"
        else aux = "are" end
        -- Find the -ing form from aliases
        local ing = lemma .. "ing"
        for _, alias in ipairs(lemma_entry.en_aliases or {}) do
            if alias:sub(-3) == "ing" then ing = alias; break end
        end
        return aux .. " " .. ing
    elseif tense == "PAST" then
        -- Prefer the entry's explicit en_past (canonical past form). Falls
        -- back to searching IRREGULAR_PAST_FORMS map, then to regular -ed.
        if lemma_entry.en_past then return lemma_entry.en_past end
        local pastMap = Lexicon.IRREGULAR_PAST_FORMS or {}
        for pastForm, presLemma in pairs(pastMap) do
            if presLemma == lemma then return pastForm end
        end
        return lemma .. "ed"
    elseif tense == "AORIST_NEGATIVE" then
        local aux = (pn == "3sg") and "does" or "do"
        return aux .. " not " .. lemma
    end
    return lemma
end

local function englishNounForm(lemma_entry, isPlural, definite, isMass)
    local lemma = lemma_entry.en
    if isPlural then
        local plural
        if lemma_entry.en_plurals and #lemma_entry.en_plurals > 0 then
            plural = lemma_entry.en_plurals[1]
        else
            plural = lemma .. "s"
        end
        if definite then return "the " .. plural end
        return plural  -- bare plural -> "books" not "a books"
    end
    if definite then return "the " .. lemma end
    if isMass then return lemma end  -- mass nouns: no "a"
    return "a " .. lemma
end

local function capitalizeFirst(s)
    if s == "" then return s end
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- ---------------------------------------------------------------------------
-- Sentence-level reconstruction.
--
-- Subject/object disambiguation:
--   1. Find the predicate (verb or copular).
--   2. If verb is transitive (subcat includes "transitive"):
--      - Nouns are objects (definite = accusative-marked, indefinite = bare).
--      - Subject is reconstructed from verb agreement (pronoun-drop).
--   3. If verb is intransitive:
--      - Nouns are subjects (Turkish nominal subjects take 3sg agreement).
--      - No objects.
--   4. If predicate is copular:
--      - The ADJ/NOUN bearing the copular suffix is the predicate.
--      - Subject is reconstructed from agreement.
--      - Any additional nouns are subjects (e.g., "Yemek lezzetli" = "The food is delicious").
-- ---------------------------------------------------------------------------

local function isTransitive(lemma_entry)
    if not lemma_entry or not lemma_entry.subcat then return false end
    for _, s in ipairs(lemma_entry.subcat) do
        if s == "transitive" then return true end
    end
    return false
end

local function generateEnglish(analyzedTokens, terminator)
    local predicate
    local negCopular  -- NEG_COPULAR token if present (negated copular)
    local nouns = {}
    local bareProns = {}
    local possessedNouns = {}
    local existParticle    -- var or yok
    local indefMarker      -- bir present?
    for _, a in ipairs(analyzedTokens) do
        local f = a.analysis.features
        if f.kind == "VERB" or f.kind == "COPULAR" then
            predicate = a
        elseif f.kind == "NEG_COPULAR" then
            negCopular = a
        elseif f.kind == "EXIS_PARTICLE" then
            existParticle = a
        elseif f.kind == "INDEF_MARKER" then
            indefMarker = a
        elseif f.kind == "NOUN" or f.kind == "BARE_NOUN" then
            table.insert(nouns, a)
        elseif f.kind == "BARE_PRON" then
            table.insert(bareProns, a)
        elseif f.kind == "POSSESSED_NOUN" then
            table.insert(possessedNouns, a)
        end
    end

    -- Existential reconstruction: var or yok present.
    -- Sub-patterns:
    --   1. EXISTENTIAL_HAVE: possessed noun present -> "X has/doesn't have Y"
    --   2. EXISTENTIAL_BARE: bare nouns only -> "There is/are X" / "no X"
    --
    -- Sentence-level reinterpretation: in existential context, a noun
    -- analyzed as accusative-definite (-i) is more likely a 3sg possessive
    -- (since accusative -i and possessive 3sg -i are homophonous).
    if existParticle then
        for i, n in ipairs(nouns) do
            local nf = n.analysis.features
            if nf.definite and not nf.isPlural then
                n.analysis.features = {
                    kind = "POSSESSED_NOUN",
                    person = 3, number = "sg",
                    voiced = nf.voiced,
                }
                table.insert(possessedNouns, n)
                nouns[i] = nil
            end
        end
        local compact = {}
        for _, n in ipairs(nouns) do
            if n then table.insert(compact, n) end
        end
        nouns = compact

        local negated = existParticle.analysis.features.negated
        if #possessedNouns > 0 then
            local pn = possessedNouns[1]
            local pf = pn.analysis.features
            local pron = (PRONOUN_FROM_AGREEMENT[pf.person] or PRONOUN_FROM_AGREEMENT[3])[pf.number] or "she"
            local subjectStr = capitalizeFirst(pron)
            local haveAux
            if pf.person == 3 and pf.number == "sg" then
                haveAux = negated and "does not have" or "has"
            else
                haveAux = negated and "do not have" or "have"
            end
            local le = pn.analysis.lemma_entry
            local objStr = le.en_mass and le.en or ("a " .. le.en)
            return subjectStr .. " " .. haveAux .. " " .. objStr
                .. (terminator or "."), nil
        else
            local n = nouns[1]
            if not n then
                return nil, "existential particle with no noun"
            end
            local nf = n.analysis.features
            local le = n.analysis.lemma_entry
            local subjectStr = "There"
            if nf.isPlural then
                local pluralForm = (le.en_plurals and le.en_plurals[1])
                    or (le.en .. "s")
                local cop = negated and "are no" or "are"
                return subjectStr .. " " .. cop .. " " .. pluralForm
                    .. (terminator or "."), nil
            elseif le.en_mass then
                local cop = negated and "is no" or "is"
                return subjectStr .. " " .. cop .. " " .. le.en
                    .. (terminator or "."), nil
            else
                if negated then
                    return subjectStr .. " is no " .. le.en
                        .. (terminator or "."), nil
                end
                return subjectStr .. " is a " .. le.en
                    .. (terminator or "."), nil
            end
        end
    end

    -- Zero-suffix copular detection: when input is [BARE_PRON, BARE_NOUN]
    -- with no verb or explicit copular, Turkish reads it as "PRON is a NOUN"
    -- (the 3sg copular suffix is zero). Synthesize a copular predicate.
    if not predicate and not negCopular
        and #bareProns == 1 and #nouns == 1 then
        local pron = bareProns[1]
        local noun = nouns[1]
        -- Build synthetic copular predicate using the noun as predicate_pos=NOUN
        predicate = {
            surface = pron.surface .. " " .. noun.surface,
            analysis = {
                lemma_entry = noun.analysis.lemma_entry,
                features = {
                    kind = "COPULAR",
                    predicate_pos = "NOUN",
                    person = pron.analysis.lemma_entry.person or 3,
                    number = pron.analysis.lemma_entry.number or "sg",
                },
            },
        }
        -- Remove the noun and pronoun from nouns/bareProns so they
        -- aren't double-used.
        for j, n in ipairs(nouns) do
            if n == noun then table.remove(nouns, j); break end
        end
    end

    -- Negated copular composition. Look for the pattern:
    --   token[i] = bare ADJ or NOUN
    --   token[i+1] = NEG_COPULAR (carries person/number)
    -- If present, treat them as a single copular-negated predicate.
    if negCopular then
        for i, a in ipairs(analyzedTokens) do
            if a == negCopular and i > 1 then
                local prev = analyzedTokens[i - 1]
                if prev and prev.analysis and prev.analysis.lemma_entry then
                    local prevPos = prev.analysis.lemma_entry.pos
                    if prevPos == "ADJ" or prevPos == "NOUN" then
                        -- Construct a synthetic predicate combining the two
                        predicate = {
                            surface = prev.surface .. " " .. negCopular.surface,
                            analysis = {
                                lemma_entry = prev.analysis.lemma_entry,
                                features = {
                                    kind = "COPULAR",
                                    predicate_pos = prevPos,
                                    person = negCopular.analysis.features.person,
                                    number = negCopular.analysis.features.number,
                                    negated = true,
                                },
                            },
                        }
                        -- Remove the predicate noun from the nouns list so it
                        -- isn't double-counted as a subject or object.
                        for j, n in ipairs(nouns) do
                            if n == prev then table.remove(nouns, j); break end
                        end
                    end
                end
            end
        end
    end

    if not predicate then
        return nil, "no predicate identified"
    end

    local f = predicate.analysis.features
    local lemma_entry = predicate.analysis.lemma_entry

    -- Classify nouns: subject vs object based on predicate type and verb subcat.
    local subjectNoun
    local objectNouns = {}

    if f.kind == "VERB" then
        local verbIsTrans = isTransitive(lemma_entry)
        for _, n in ipairs(nouns) do
            local nf = n.analysis.features
            if verbIsTrans then
                -- All nouns are objects (subject is dropped pronoun, or
                -- explicit pronoun which we don't currently have in input).
                table.insert(objectNouns, n)
            else
                -- Intransitive verb: noun is subject
                if not subjectNoun then
                    subjectNoun = n
                else
                    -- Multiple subjects shouldn't happen in v3; second one
                    -- treated as adjunct (current PoC skips this)
                    table.insert(objectNouns, n)
                end
            end
        end
    elseif f.kind == "COPULAR" then
        -- Copular: any noun in the input is a subject (e.g., "Yemek lezzetli")
        for _, n in ipairs(nouns) do
            if not subjectNoun then subjectNoun = n
            else table.insert(objectNouns, n) end
        end
    end

    local parts = {}

    -- Subject
    if subjectNoun then
        local sf = subjectNoun.analysis.features
        local sle = subjectNoun.analysis.lemma_entry
        local form = englishNounForm(sle, sf.isPlural, true, sle.en_mass)
        table.insert(parts, capitalizeFirst(form))
    else
        local p = f.person or 3
        local n = f.number or "sg"
        local pron = (PRONOUN_FROM_AGREEMENT[p] or PRONOUN_FROM_AGREEMENT[3])[n] or "she"
        table.insert(parts, capitalizeFirst(pron))
    end

    -- Verb or copular
    if f.kind == "VERB" then
        -- Subject-verb agreement for English: if subject is an explicit
        -- plural noun, the verb takes plural agreement even though the
        -- Turkish verb was 3sg.
        local effPerson, effNumber = f.person, f.number
        if subjectNoun then
            local sf = subjectNoun.analysis.features
            effPerson = 3
            effNumber = sf.isPlural and "pl" or "sg"
        end
        table.insert(parts, englishVerbForm(lemma_entry, f.tense, effPerson, effNumber))
    elseif f.kind == "COPULAR" then
        local effPerson, effNumber = f.person, f.number
        if subjectNoun then
            local sf = subjectNoun.analysis.features
            effPerson = 3
            effNumber = sf.isPlural and "pl" or "sg"
        end
        local copAux
        if effPerson == 1 and effNumber == "sg" then copAux = "am"
        elseif effPerson == 3 and effNumber == "sg" then copAux = "is"
        else copAux = "are" end
        local negation = f.negated and " not " or " "
        if f.predicate_pos == "ADJ" then
            table.insert(parts, copAux .. negation .. lemma_entry.en)
        elseif f.predicate_pos == "NOUN" then
            -- Plural copular agreement implies a plural predicate noun in
            -- English: "Arkadaşız" (1pl) -> "We are friends", not "a friend".
            if effNumber == "pl" then
                local pluralForm = (lemma_entry.en_plurals
                    and lemma_entry.en_plurals[1])
                    or (lemma_entry.en .. "s")
                table.insert(parts, copAux .. negation .. pluralForm)
            else
                table.insert(parts, copAux .. negation .. "a " .. lemma_entry.en)
            end
        end
    end

    -- Objects
    for _, o in ipairs(objectNouns) do
        local of = o.analysis.features
        local ole = o.analysis.lemma_entry
        local form = englishNounForm(ole, of.isPlural, of.definite, ole.en_mass)
        table.insert(parts, form)
    end

    return table.concat(parts, " ") .. (terminator or "."), nil
end

-- ---------------------------------------------------------------------------
-- Sentence-level public entrypoint
-- ---------------------------------------------------------------------------

function M.parseSentence(text)
    if type(text) ~= "string" or text == "" then
        return { ok = false, errors = {"empty input"} }
    end

    local tokens, terminator = tokenize(text)
    if #tokens == 0 then
        return { ok = false, errors = {"no tokens after tokenize"} }
    end

    -- Pre-scan for the existential particle so per-token analysis can
    -- disambiguate ambiguous suffixes correctly. "Doktorum" alone reads
    -- as "I am a doctor" (copular), but "Doktorum var" reads as
    -- "I have a doctor" (possessive + existential). The flag flips the
    -- priority of tryPossessive vs tryCopular in analyzeToken.
    local existentialContext = false
    for _, tok in ipairs(tokens) do
        local lower = lowerTurkish(tok)
        if lower == "var" or lower == "yok" then
            existentialContext = true; break
        end
    end

    -- Analyze each token
    local analyzedTokens = {}
    local errors = {}
    for i, tok in ipairs(tokens) do
        local analysis = M.analyzeToken(tok, { existential_context = existentialContext })
        if analysis then
            table.insert(analyzedTokens, {
                surface = tok, position = i, analysis = analysis,
            })
            -- Promote BARE_NOUN kind to NOUN-like for downstream use
            if analysis.features.kind == "BARE_NOUN" then
                analysis.features.isPlural = false
                analysis.features.definite = false
            end
        else
            table.insert(errors, "could not analyze token: '" .. tok .. "'")
        end
    end

    if #errors > 0 then
        return {
            ok = false,
            errors = errors,
            analyzedTokens = analyzedTokens,
            terminator = terminator,
        }
    end

    -- Generate English
    local english, genErr = generateEnglish(analyzedTokens, terminator)
    if not english then
        return {
            ok = false,
            errors = { genErr or "english generation failed" },
            analyzedTokens = analyzedTokens,
            terminator = terminator,
        }
    end

    return {
        ok = true,
        output = english,
        analyzedTokens = analyzedTokens,
        terminator = terminator,
    }
end

return M
