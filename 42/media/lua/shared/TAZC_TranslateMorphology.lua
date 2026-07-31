-- ============================================================================
-- TAZC_TranslateMorphology -- Turkish morphology helpers for the v1 PoC.
--
-- Handles the two morphological operations corpus.011-019 require:
--   1. Present progressive verb conjugation: stem + -iyor + person/number
--   2. Accusative case marker on definite objects: noun + harmony-i (with
--      voicing assimilation on final consonants where applicable)
--
-- All vowel harmony goes through the same classifier the babble engine uses
-- in v8.9.2. Front vowels: e, i, oe, ue. Back vowels: a, dotless-i, o, u.
-- ============================================================================

local M = {}

-- Shared UTF-8 helpers. See TAZC_StringUtils.lua for the rationale behind the
-- VM-portable iteration; the same module is used by TAZC_Translate and
-- TAZC_TranslateReverseParser.
local Str = require("TAZC_StringUtils")
local utf8chars = Str.utf8chars
local utf8len   = Str.utf8len

-- Vowel sets, ASCII-keyed for clean Lua matching against UTF-8 codepoints.
local FRONT = { e = true, i = true, ["\195\182"] = true, ["\195\188"] = true }
local BACK  = { a = true, ["\196\177"] = true, o = true, u = true }

-- ---------------------------------------------------------------------------
-- Vowel harmony classification. Returns "front", "back", or "neutral".
-- ---------------------------------------------------------------------------

local function lastVowelClass(stem)
    local lastClass = "neutral"
    for ch in utf8chars(stem) do
        if FRONT[ch] then lastClass = "front"
        elseif BACK[ch] then lastClass = "back" end
    end
    return lastClass
end

M.lastVowelClass = lastVowelClass

-- ---------------------------------------------------------------------------
-- Present progressive (-iyor) suffix selection.
--
-- Turkish present progressive: stem + buffer-vowel + -yor + person ending.
-- The buffer vowel is determined by the stem's last vowel under four-way
-- harmony (front/back x rounded/unrounded), but for the v1 PoC we use the
-- simpler two-way distinction:
--    last vowel front + unrounded: -iyor   (e.g. yapiyor -- wait that's back)
--
-- Actual rule (correct):
--    Stem ends in front unrounded vowel (e, i): -iyor      (gel- -> geliyor)
--    Stem ends in front rounded vowel (oe, ue): -uyor      (gör- -> görüyor) [we use -uyor with front rounded]
--    Stem ends in back unrounded vowel (a, dotless-i): -iyor with back vowel (yap- -> yapiyor [iiyor->iyor by deletion])
--    Stem ends in back rounded vowel (o, u): -uyor         (oku- -> okuyor)
--
-- For our corpus subset the simpler two-way approximation works because
-- the verbs we cover end in front-unrounded or back-unrounded vowels or in
-- back-rounded "u/o". We pick the buffer-vowel based on four classes but
-- keep the logic readable.
-- ---------------------------------------------------------------------------

-- Detailed harmony for buffer vowel selection. Returns one of i/dotless-i/u/oe-equivalent
local function bufferVowel(stem)
    -- Find last vowel character with detailed class
    local lastVowel
    for ch in utf8chars(stem) do
        if FRONT[ch] or BACK[ch] then lastVowel = ch end
    end
    if not lastVowel then return "i" end
    -- Four-way mapping for the present progressive buffer vowel
    if lastVowel == "a" or lastVowel == "\196\177" then return "\196\177" end  -- back unrounded -> dotless-i
    if lastVowel == "e" or lastVowel == "i"        then return "i"          end  -- front unrounded -> i
    if lastVowel == "o" or lastVowel == "u"        then return "u"          end  -- back rounded -> u
    if lastVowel == "\195\182" or lastVowel == "\195\188" then return "\195\188" end  -- front rounded -> ue
    return "i"
end

M.bufferVowel = bufferVowel

-- ---------------------------------------------------------------------------
-- Past tense conjugation.
--
-- Turkish past (simple/definite): stem + -di/-ti + person/number ending.
-- Initial consonant is "d" by default but assimilates to "t" when the stem
-- ends in a voiceless consonant (k, p, t, c-cedilla, s, sh, f, h). Buffer
-- vowel under four-way harmony picks -i/-dotless-i/-u/-ue. Person endings
-- attach after the suffix; 2pl and 3pl have harmony-sensitive variants.
--
-- Examples:
--   ic-  + ti + m   -> ictim       (I drank)         [voiceless stem -> t]
--   oku- + du + k   -> okuduk      (we read)
--   gel- + di       -> geldi       (he/she came)     [3sg = bare]
--   yap- + ti + niz -> yaptiniz    (you-pl did)
-- ---------------------------------------------------------------------------

local VOICELESS_FINALS = {
    ["k"] = true, ["p"] = true, ["t"] = true,
    ["\195\167"] = true, ["s"] = true, ["\197\159"] = true,
    ["f"] = true, ["h"] = true,
}

local function pastSuffixInitial(stem)
    local last
    for ch in utf8chars(stem) do last = ch end
    if VOICELESS_FINALS[last] then return "t" end
    return "d"
end

M.pastSuffixInitial = pastSuffixInitial

local PAST_PERSON_ENDINGS_BY_VOWEL = {
    ["i"]        = { ["1sg"] = "m", ["2sg"] = "n", ["3sg"] = "", ["1pl"] = "k", ["2pl"] = "niz", ["3pl"] = "ler" },
    ["\196\177"] = { ["1sg"] = "m", ["2sg"] = "n", ["3sg"] = "", ["1pl"] = "k", ["2pl"] = "n\196\177z", ["3pl"] = "lar" },
    ["u"]        = { ["1sg"] = "m", ["2sg"] = "n", ["3sg"] = "", ["1pl"] = "k", ["2pl"] = "nuz", ["3pl"] = "lar" },
    ["\195\188"] = { ["1sg"] = "m", ["2sg"] = "n", ["3sg"] = "", ["1pl"] = "k", ["2pl"] = "n\195\188z", ["3pl"] = "ler" },
}

function M.conjugatePast(stem, personNumber)
    local d = pastSuffixInitial(stem)
    local v = bufferVowel(stem)
    local endings = PAST_PERSON_ENDINGS_BY_VOWEL[v] or PAST_PERSON_ENDINGS_BY_VOWEL["i"]
    local ending = endings[personNumber]
    if not ending then
        error("unknown person/number for past: " .. tostring(personNumber))
    end
    local form = stem .. d .. v .. ending
    local morphemes = {
        { surface = stem, gloss = "STEM" },
        { surface = d .. v, gloss = "PAST(" .. (d == "t" and "assimilated voiceless" or "voiced") .. ")" },
        { surface = (ending == "" and "\195\152" or ending),
          gloss = "AGR(" .. personNumber:upper() .. ")" },
    }
    return form, morphemes
end

-- 9.0+ Mosaic: negated past tense (-medi/-madı + person).
-- Morphology: stem + NEG (-me/-ma, harmony) + di/dı (PAST after vowel
-- so always voiced) + person ending. The NEG suffix's -e/-a determines
-- the vowel class for the past suffix and downstream agreement: -me-
-- (front, suffix vowel "i") for front-harmony stems, -ma- (back, suffix
-- vowel "ı") for back-harmony stems.
--   1sg: gör-me-di-m  -> görmedim  (I didn't see)
--   3sg: yap-ma-dı     -> yapmadı   (s/he didn't do)
-- After the NEG suffix the stem-final is always a vowel (-e/-a), so:
--   * past consonant is always "d" (no voiceless assimilation)
--   * person endings use the vowel-class table for "i" (front) or "ı" (back)
function M.conjugatePastNegative(stem, personNumber)
    local cls = lastVowelClass(stem)
    local neg = (cls == "back") and "ma" or "me"
    local vowel = (cls == "back") and "\196\177" or "i"  -- ı or i
    local endings = PAST_PERSON_ENDINGS_BY_VOWEL[vowel] or PAST_PERSON_ENDINGS_BY_VOWEL["i"]
    local ending = endings[personNumber]
    if not ending then
        error("unknown person/number for past-negative: " .. tostring(personNumber))
    end
    -- After NEG suffix ends in vowel, PAST is always "-di/-dı" (voiced)
    local d = "d"
    local form = stem .. neg .. d .. vowel .. ending
    local morphemes = {
        { surface = stem, gloss = "STEM" },
        { surface = neg, gloss = "NEG(" .. cls .. ")" },
        { surface = d .. vowel, gloss = "PAST" },
        { surface = (ending == "" and "\195\152" or ending),
          gloss = "AGR(" .. personNumber:upper() .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Aorist negation conjugation.
--
-- The aorist is Turkish's general/habitual tense, used for statements of
-- routine ("I drink coffee"), facts, characteristic properties, and (in
-- the negative form) the simple English "do not VERB" construction.
--
-- Aorist negative morphology:
--   1sg : stem + -mem / -mam        (e.g., icmem  = I don't drink)
--   2sg : stem + -mezsin / -mazsin
--   3sg : stem + -mez   / -maz      (e.g., icmez  = she doesn't drink)
--   1pl : stem + -meyiz / -mayiz
--   2pl : stem + -mezsiniz / -mazsiniz
--   3pl : stem + -mezler / -mazlar
--
-- Harmony class of the stem's last vowel selects the front (-me-/-mez-)
-- vs back (-ma-/-maz-) variant. Stems ending in a vowel still attach -mE-
-- without a buffer (the -m- is consonantal so no vowel collision arises).
-- ---------------------------------------------------------------------------

local AORIST_NEG_ENDINGS_FRONT = {
    ["1sg"] = "mem",     ["2sg"] = "mezsin",   ["3sg"] = "mez",
    ["1pl"] = "meyiz",   ["2pl"] = "mezsiniz", ["3pl"] = "mezler",
}
local AORIST_NEG_ENDINGS_BACK = {
    ["1sg"] = "mam",     ["2sg"] = "mazs\196\177n",   ["3sg"] = "maz",
    ["1pl"] = "may\196\177z",   ["2pl"] = "mazs\196\177n\196\177z", ["3pl"] = "mazlar",
}

function M.conjugateAoristNegative(stem, personNumber)
    local cls = lastVowelClass(stem)
    local endings = (cls == "back") and AORIST_NEG_ENDINGS_BACK or AORIST_NEG_ENDINGS_FRONT
    local ending = endings[personNumber]
    if not ending then
        error("unknown person/number for aorist negative: " .. tostring(personNumber))
    end
    local form = stem .. ending
    local morphemes = {
        { surface = stem, gloss = "STEM" },
        { surface = ending,
          gloss = "AOR.NEG(" .. (cls or "front") .. ").AGR(" .. personNumber:upper() .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Negated 2sg imperative.
--
-- Turkish negated imperative for "you" (2sg) is the verb stem plus the
-- harmony-matched negation suffix -ma / -me:
--   koş + ma   = koşma   (don't run)
--   yap + ma   = yapma   (don't do)
--   gel + me   = gelme   (don't come)
--   git + me   = gitme   (don't go)
--   gör + me   = görme   (don't see)
--
-- No person/number agreement: this is exclusively 2sg ("you, singular,
-- don't"). The 2pl form (-mayın / -meyin) is also imperative-negated
-- but more formal; chat overwhelmingly uses 2sg.
-- ---------------------------------------------------------------------------

function M.applyImperativeNeg(stem)
    local cls = lastVowelClass(stem)
    local suffix = (cls == "back") and "ma" or "me"
    local form = stem .. suffix
    local morphemes = {
        { surface = stem,   gloss = "STEM" },
        { surface = suffix, gloss = "IMP.NEG.2SG(" .. (cls or "front") .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- First-person plural hortative ("let's") — 8.10.3+
--
-- Turkish 1pl hortative for "let us X" is the verb stem plus harmony-matched
-- -alım / -elim:
--   koş + alım = koşalım  (let us run)
--   gel + elim = gelelim  (let us come)
--   yap + alım = yapalım  (let us do)
--   git + elim = gidelim  (let us go; intervocalic t→d voicing on stem)
--   gör + elim = görelim  (let us see)
--
-- This is the standard cohortative/hortative used for proposals and
-- group commands. Polite alternatives ("hadi gidelim" with the
-- interjection "hadi") aren't represented here; v1 emits just the verb
-- form which works on its own.
-- ---------------------------------------------------------------------------

function M.applyHortative1pl(stem, opts)
    opts = opts or {}
    local cls = lastVowelClass(stem)
    local suffix = (cls == "back") and "al\196\177m" or "elim"
    -- Stem-side intervocalic voicing (git -> gid before vowel-initial suffix).
    -- The suffix starts with a vowel, so we apply this voicing.
    local workingStem = stem
    if opts.intervocalic_voicing then
        workingStem = M.applyIntervocalicVoicing(stem)
    end
    local form = workingStem .. suffix
    local morphemes = {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(voiced)" or "STEM" },
        { surface = suffix,      gloss = "HORT.1PL(" .. (cls or "front") .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- First-person singular hortative ("let me") — 9.0+
--
-- Turkish 1sg hortative for "let me X" / "may I X" is stem + harmony-matched
-- -ayım / -eyim (sometimes spelled -ayim / -eyim in modern Turkish):
--   gör + eyim = göreyim          (let me see)
--   yap + ayım = yapayım          (let me do)
--   git + eyim = gideyim          (let me go; intervocalic voicing t->d)
--   düşün + eyim = düşüneyim      (let me think)
--   dene + y + eyim = deneyeyim   (let me try; y-buffer after vowel)
--
-- Sister form to applyHortative1pl above. v1 hortative pattern coverage:
--   1sg ("let me X"):  here
--   1pl ("let us X"):  applyHortative1pl
--   Other persons (let him, let them) deferred; Turkish jussive ("-sin")
--   would need own helper.
-- ---------------------------------------------------------------------------

function M.applyHortative1sg(stem, opts)
    opts = opts or {}
    local cls = lastVowelClass(stem)
    local suffix = (cls == "back") and "ay\196\177m" or "eyim"
    -- Intervocalic voicing on vowel-initial suffix: git -> gid + eyim
    local workingStem = stem
    if opts.intervocalic_voicing then
        workingStem = M.applyIntervocalicVoicing(stem)
    end
    -- Y-buffer if stem ends in a vowel (dene + eyim -> deneyeyim)
    local lastChar
    for ch in utf8chars(workingStem) do lastChar = ch end
    if lastChar and (FRONT[lastChar] or BACK[lastChar]) then
        suffix = "y" .. suffix
    end
    local form = workingStem .. suffix
    local morphemes = {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(voiced)" or "STEM" },
        { surface = suffix,      gloss = "HORT.1SG(" .. (cls or "front") .. ")" },
    }
    return form, morphemes
end

-- Set of voiceless consonants that trigger the voiceless variant of
-- locative/ablative (-te/-ta/-ten/-tan vs -de/-da/-den/-dan).
local VOICELESS_FINAL = {
    p = true, t = true, k = true,
    ["\195\167"] = true,  -- ç
    s = true,
    ["\197\159"] = true,  -- ş
    f = true,
    h = true,
}

local function endsVoiceless(stem)
    if stem == "" then return false end
    -- Check last UTF-8 character (Turkish ç/ş are 2-byte sequences).
    local lastBytes = stem:sub(-2)
    if VOICELESS_FINAL[lastBytes] then return true end
    return VOICELESS_FINAL[stem:sub(-1)] or false
end

local function stemEndsInVowelLocal(stem)
    if stem == "" then return false end
    local last
    for ch in utf8chars(stem) do last = ch end
    return (FRONT[last] or BACK[last]) ~= nil
end

-- ---------------------------------------------------------------------------
-- Aorist-conditional conjugation (8.16.x+).
--
-- Turkish aorist + conditional combine to form productive "if X (verbs)"
-- clauses: stem + AORIST + CONDITIONAL + PERSON.
--
--   gör + ür + se + n   = görürsen   (if you see)
--   gel + ir + se + ler = gelirseler (if they come)
--   bul + ur + sa + m   = bulursam   (if I find)
--   yap + ar + sa + n   = yaparsan   (if you do)
--   iste + r + se + n   = istersen   (if you want) — vowel-final stem
--
-- Aorist suffix selection:
--   * vowel-final stem        -> -r
--   * mono-syllabic, in EXCN  -> -ır/-ir/-ur/-ür (harmony-matched)
--   * mono-syllabic, default  -> -ar / -er       (back / front)
--   * poly-syllabic, consonant-final -> -ır/-ir/-ur/-ür
--
-- Conditional + person endings combine into a fused affix per person:
--   1sg: -sem / -sam     2sg: -sen / -san    3sg: -se / -sa
--   1pl: -sek / -sak     2pl: -seniz/-saniz  3pl: -seler/-salar
-- ---------------------------------------------------------------------------

-- Monosyllabic consonant-ending verbs that take -Ir aorist (not -Ar).
-- These are high-frequency exception verbs.
local MONOSYLLABIC_AORIST_IR = {
    ["al"]   = true,  -- take
    ["bil"]  = true,  -- know
    ["bul"]  = true,  -- find
    ["dur"]  = true,  -- stop
    ["gel"]  = true,  -- come
    ["g\195\182r"]  = true,  -- see (gör)
    ["kal"]  = true,  -- stay
    ["ol"]   = true,  -- be/become
    ["sal"]  = true,  -- release
    ["san"]  = true,  -- suppose
    ["var"]  = true,  -- arrive
    ["ver"]  = true,  -- give
    ["vur"]  = true,  -- hit
    ["yen"]  = true,  -- defeat
    ["\195\182l"] = true,  -- die (öl)
    ["\195\182r"] = true,  -- weave (ör)
    ["den"]  = true,  -- try
    ["in"]   = true,  -- descend
}

local function countVowels(stem)
    local count = 0
    for ch in utf8chars(stem) do
        if FRONT[ch] or BACK[ch] then count = count + 1 end
    end
    return count
end

local AOR_COND_PERSON = {
    front = {
        ["1sg"] = "sem",  ["2sg"] = "sen",  ["3sg"] = "se",
        ["1pl"] = "sek",  ["2pl"] = "seniz", ["3pl"] = "seler",
    },
    back = {
        ["1sg"] = "sam",  ["2sg"] = "san",  ["3sg"] = "sa",
        ["1pl"] = "sak",  ["2pl"] = "san\196\177z", ["3pl"] = "salar",
    },
}

local function selectAoristSuffix(stem)
    if stemEndsInVowelLocal(stem) then return "r" end
    local cls = lastVowelClass(stem) or "front"
    local stemLower = stem:lower()
    local syllables = countVowels(stem)
    if syllables == 1 then
        if MONOSYLLABIC_AORIST_IR[stemLower] then
            return bufferVowel(stem) .. "r"
        else
            return (cls == "back") and "ar" or "er"
        end
    end
    return bufferVowel(stem) .. "r"
end

function M.applyAoristConditional(stem, personNumber)
    local aoristSuffix = selectAoristSuffix(stem)
    local cls = lastVowelClass(stem) or "front"
    -- Voicing: when aorist starts with a vowel and stem ends in a
    -- voiceless consonant, the consonant voices.
    --   git + er -> gider (t→d)
    --   et  + er -> eder
    -- For chat translator scope, the most common cases are git/et
    -- (high-frequency irregulars). Polysyllabic stems ending in t/p/k/ç
    -- also voice but are rarer; we cover them with a generic map.
    local workingStem = stem
    if aoristSuffix ~= "r" then  -- aorist starts with a vowel
        local stemLower = stem:lower()
        local VOICING_MONO = {
            ["git"] = "gid",  -- go → gid
            ["et"]  = "ed",   -- do/be aux → ed
            ["tat"] = "tad",  -- taste
            ["k\195\188t"] = "k\195\188d",  -- decline
        }
        if VOICING_MONO[stemLower] then
            workingStem = VOICING_MONO[stemLower]
        else
            -- Polysyllabic stems ending in voiceless consonant voice.
            local syllables = countVowels(stem)
            if syllables > 1 then
                local last
                for ch in utf8chars(stem) do last = ch end
                local LOCAL_VOICING = {
                    ["t"] = "d", ["p"] = "b",
                    ["k"] = "\196\159",  -- k → ğ
                    ["\195\167"] = "c",  -- ç → c
                }
                if LOCAL_VOICING[last] then
                    -- Drop last char (UTF-8 safe: t/p/k are 1-byte, ç is 2-byte)
                    local lastByteLen = #last
                    workingStem = stem:sub(1, #stem - lastByteLen) .. LOCAL_VOICING[last]
                end
            end
        end
    end
    -- Determine harmony class for the conditional+person suffix from the
    -- aorist vowel. Vowel-only suffix "r" inherits stem's class.
    -- Otherwise look at the FIRST char of the suffix (the vowel).
    local condClass
    if aoristSuffix == "r" then
        condClass = cls
    else
        local aoristVowel
        for ch in utf8chars(aoristSuffix) do aoristVowel = ch; break end
        if BACK[aoristVowel] then
            condClass = "back"
        else
            condClass = "front"
        end
    end
    local personSuffix = AOR_COND_PERSON[condClass][personNumber]
    if not personSuffix then
        error("unknown person/number for aorist-conditional: " .. tostring(personNumber))
    end
    local form = workingStem .. aoristSuffix .. personSuffix
    local morphemes = {
        { surface = workingStem,
          gloss = (workingStem ~= stem) and "STEM(voiced)" or "STEM" },
        { surface = aoristSuffix, gloss = "AOR(" .. cls .. ")" },
        { surface = personSuffix,
          gloss = "COND.AGR(" .. personNumber:upper() .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Case-marking suffixes (8.10.2+): locative, dative, ablative, comitative.
--
-- Turkish marks prepositional relationships as case suffixes on the noun
-- rather than as separate words. Each case has its own harmony pattern
-- and voicing rule:
--
--   LOCATIVE  "-de/-da/-te/-ta"     (at, in, on)   — voiceless after p,t,k,ç,s,ş,f,h
--   DATIVE    "-e/-a"               (to, toward)   — y-buffer after vowel; k→ğ on stem
--   ABLATIVE  "-den/-dan/-ten/-tan" (from)         — same voicing as locative
--   COMITATIVE "-le/-la"            (with)         — y-buffer after vowel
--
-- Examples:
--   ev   + de  = evde      (at home)
--   üs   + te  = üste      (at base; voiceless -s triggers -te)
--   ev   + e   = eve       (to home)
--   mutfak -> mutfağ + a   = mutfağa  (to kitchen, k→ğ)
--   ev   + den = evden     (from home)
--   silah + la = silahla   (with the gun)
--   araba + yla = arabayla  (with the car; y-buffer after vowel)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Pronoun n-buffer (9.0+).
--
-- The 3rd-person pronouns "o" (it/he/she), "bu" (this), "şu" (that), and
-- "kim" (who) take an inserted /n/ before case suffixes. This is a
-- specific Turkish morphological rule that produces:
--   o + da    -> "onda"   (on it), NOT "oda" (which means "room")
--   o + a     -> "ona"    (to it/him/her), NOT "oa"
--   o + dan   -> "ondan"  (from it)
--   bu + da   -> "bunda"  (in this)
--   şu + nun  -> "şunun"  (this-GEN)
--   kim + e   -> "kime"   (to whom), kim doesn't take n-buffer in dative
--                actually but does in genitive/etc. Conservative: include kim.
--
-- Without the buffer, "o + da" surfaces as "oda" which is a different
-- Turkish word ("room"). Critical fix for pronoun case marking.
-- ---------------------------------------------------------------------------

local PRONOUN_N_BUFFER = {
    o   = true,
    bu  = true,
    ["\197\159u"] = true,  -- "şu"
    -- kim taking n-buffer varies by case; we omit it to be safe.
}

-- 9.0+ Mosaic: suppletive pronoun case forms. Turkish personal pronouns
-- have irregular case forms that don't follow the regular harmony+suffix
-- pattern when applied to the lex's accusative stem (beni/seni/onu/etc).
-- This table covers the irregular forms; the applyXxx case functions
-- check it first before falling through to the regular morphology.
--
-- Keys: stem (typically the accusative form as stored in lex).
-- Values: { dat, loc, abl, com, gen } for each case.
local PRONOUN_CASE_OVERRIDE = {
    -- 1sg: ben/beni
    ["ben"]    = { dat="bana", loc="bende",  abl="benden",  com="benimle",  gen="benim" },
    ["beni"]   = { dat="bana", loc="bende",  abl="benden",  com="benimle",  gen="benim" },
    -- 2sg: sen/seni
    ["sen"]    = { dat="sana", loc="sende",  abl="senden",  com="seninle",  gen="senin" },
    ["seni"]   = { dat="sana", loc="sende",  abl="senden",  com="seninle",  gen="senin" },
    -- 3sg: o/onu (with n-buffer)
    ["o"]      = { dat="ona",  loc="onda",   abl="ondan",   com="onunla",   gen="onun" },
    ["onu"]    = { dat="ona",  loc="onda",   abl="ondan",   com="onunla",   gen="onun" },
    -- 1pl: biz/bizi
    ["biz"]    = { dat="bize", loc="bizde",  abl="bizden",  com="bizimle",  gen="bizim" },
    ["bizi"]   = { dat="bize", loc="bizde",  abl="bizden",  com="bizimle",  gen="bizim" },
    -- 2pl: siz/sizi
    ["siz"]    = { dat="size", loc="sizde",  abl="sizden",  com="sizinle",  gen="sizin" },
    ["sizi"]   = { dat="size", loc="sizde",  abl="sizden",  com="sizinle",  gen="sizin" },
    -- 3pl: onlar/onları (no n-buffer for the plural)
    ["onlar"]  = { dat="onlara", loc="onlarda", abl="onlardan", com="onlarla", gen="onlar\196\177n" },
    ["onlar\196\177"] = { dat="onlara", loc="onlarda", abl="onlardan", com="onlarla", gen="onlar\196\177n" },
}

local function lookupPronounCase(stem, caseTag)
    local row = PRONOUN_CASE_OVERRIDE[stem]
    if row then return row[caseTag] end
    return nil
end

local function applyPronounNBuffer(stem)
    if PRONOUN_N_BUFFER[stem] then
        return stem .. "n"
    end
    return stem
end

function M.applyLocative(stem, opts)
    opts = opts or {}
    local override = lookupPronounCase(stem, "loc")
    if override then
        return override, {
            { surface = override:sub(1, -3), gloss = "STEM(suppletive-PRON)" },
            { surface = override:sub(-2),    gloss = "LOC(irregular)" },
        }
    end
    local workingStem = applyPronounNBuffer(stem)
    local cls = lastVowelClass(workingStem)
    local voiceless = endsVoiceless(workingStem)
    local suffix
    if cls == "back" then
        suffix = voiceless and "ta" or "da"
    else
        suffix = voiceless and "te" or "de"
    end
    -- 8.16.x: n-buffer after POSS-3sg/3pl. Turkish case suffixes after
    -- 3rd-person possessive use a pronominal -n- buffer. "tabancası" + LOC
    -- = "tabancasında" (not "tabancasıda").
    if opts.afterPossessive3 then
        return workingStem .. "n" .. suffix, {
            { surface = workingStem, gloss = "STEM(+POSS)" },
            { surface = "n", gloss = "N-BUFFER(post-POSS-3)" },
            { surface = suffix, gloss = "LOC(" .. (cls or "front") .. ")" },
        }
    end
    return workingStem .. suffix, {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(+n)" or "STEM" },
        { surface = suffix, gloss = "LOC(" .. (cls or "front") .. (voiceless and ",-voice" or "") .. ")" },
    }
end

function M.applyDative(stem, opts)
    opts = opts or {}
    local override = lookupPronounCase(stem, "dat")
    if override then
        return override, {
            { surface = override:sub(1, -2), gloss = "STEM(suppletive-PRON)" },
            { surface = override:sub(-1),    gloss = "DAT(irregular)" },
        }
    end
    local workingStem = applyPronounNBuffer(stem)
    local cls = lastVowelClass(workingStem)
    -- Proper nouns don't undergo k→ğ softening (preserve spelling).
    if not opts.isProperNoun and workingStem:sub(-1) == "k" then
        workingStem = workingStem:sub(1, -2) .. "\196\159"  -- k -> ğ
    end
    local suffix = (cls == "back") and "a" or "e"
    -- 8.16.x: n-buffer after POSS-3sg/3pl (replaces y-buffer).
    -- "tabancası" + DAT = "tabancasına" (not "tabancasıya").
    if opts.afterPossessive3 then
        return workingStem .. "n" .. suffix, {
            { surface = workingStem, gloss = "STEM(+POSS)" },
            { surface = "n", gloss = "N-BUFFER(post-POSS-3)" },
            { surface = suffix, gloss = "DAT(" .. (cls or "front") .. ")" },
        }
    end
    if stemEndsInVowelLocal(workingStem) then
        suffix = "y" .. suffix
    end
    return workingStem .. suffix, {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(+buffer)" or "STEM" },
        { surface = suffix,      gloss = "DAT(" .. (cls or "front") .. ")" },
    }
end

function M.applyAblative(stem, opts)
    opts = opts or {}
    local override = lookupPronounCase(stem, "abl")
    if override then
        return override, {
            { surface = override:sub(1, -4), gloss = "STEM(suppletive-PRON)" },
            { surface = override:sub(-3),    gloss = "ABL(irregular)" },
        }
    end
    local workingStem = applyPronounNBuffer(stem)
    local cls = lastVowelClass(workingStem)
    local voiceless = endsVoiceless(workingStem)
    local suffix
    if cls == "back" then
        suffix = voiceless and "tan" or "dan"
    else
        suffix = voiceless and "ten" or "den"
    end
    -- 8.16.x: n-buffer after POSS-3sg/3pl.
    -- "tabancası" + ABL = "tabancasından" (not "tabancasıdan").
    if opts.afterPossessive3 then
        return workingStem .. "n" .. suffix, {
            { surface = workingStem, gloss = "STEM(+POSS)" },
            { surface = "n", gloss = "N-BUFFER(post-POSS-3)" },
            { surface = suffix, gloss = "ABL(" .. (cls or "front") .. ")" },
        }
    end
    return workingStem .. suffix, {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(+n)" or "STEM" },
        { surface = suffix, gloss = "ABL(" .. (cls or "front") .. (voiceless and ",-voice" or "") .. ")" },
    }
end

function M.applyComitative(stem)
    local override = lookupPronounCase(stem, "com")
    if override then
        return override, {
            { surface = override:sub(1, -3), gloss = "STEM(suppletive-PRON)" },
            { surface = override:sub(-2),    gloss = "COM(irregular)" },
        }
    end
    local workingStem = applyPronounNBuffer(stem)
    local cls = lastVowelClass(workingStem)
    local suffix = (cls == "back") and "la" or "le"
    if stemEndsInVowelLocal(workingStem) then
        suffix = "y" .. suffix
    end
    return workingStem .. suffix, {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(+n)" or "STEM" },
        { surface = suffix,      gloss = "COM(" .. (cls or "front") .. ")" },
    }
end

-- 9.0+ Mosaic: genitive case for "X of Y" -> "Y-GEN X-3SG.POSS"
-- ("People of the River" -> "Nehrin halkı"). The genitive suffix has
-- four-way vowel harmony AND a vowel-final n-buffer:
--   consonant-final: stem + (back) -ın/-un / (front) -in/-ün
--   vowel-final:     stem + n + (back) -ın/-un / (front) -in/-ün
-- Examples:
--   nehir (river)   + GEN -> nehrin       (consonant-final, drops vowel)
--   dünya (world)   + GEN -> dünyanın     (vowel-final, n-buffer)
--   ev (house)      + GEN -> evin         (consonant-final)
--   köpek (dog)     + GEN -> köpeğin      (k -> ğ then -in)
--   araba (car)     + GEN -> arabanın     (vowel-final, n-buffer)
-- The pronoun n-buffer (o/bu/şu -> on/bun/şun) also fires here for
-- pronouns appearing as the genitive modifier ("the side of it").
function M.applyGenitive(stem, opts)
    opts = opts or {}
    local workingStem = applyPronounNBuffer(stem)
    local cls = lastVowelClass(workingStem)
    local rounded = false  -- four-way harmony: i/ı/u/ü based on last vowel
    -- Determine harmony class for the genitive vowel
    local lastV = nil
    for ch_start = #workingStem, 1, -1 do
        local ch = workingStem:sub(ch_start, ch_start)
        if ch:match("[aeiou\196\177\195\182\195\188\195\162\195\174]") or ch == "\195" then
            -- ASCII vowel found, or start of UTF-8 char
            if ch == "\195" then
                local nxt = workingStem:sub(ch_start + 1, ch_start + 1)
                lastV = nxt
            else
                lastV = ch
            end
            break
        end
    end
    -- Rounded vowels: o, ö, u, ü
    if lastV == "o" or lastV == "u"
        or lastV == "\182" or lastV == "\188" then  -- ö (\195\182), ü (\195\188)
        rounded = true
    end
    -- k -> ğ softening at consonant-final stem (same as dative).
    -- Proper nouns DON'T undergo k→ğ softening in Turkish writing
    -- (proper-noun spelling is preserved: "İzmir'in" not "İzmiğin").
    if not opts.isProperNoun and workingStem:sub(-1) == "k" then
        workingStem = workingStem:sub(1, -2) .. "\196\159"  -- ğ
    end
    local vowel
    if cls == "back" then
        vowel = rounded and "u" or "\196\177"  -- u / ı
    else
        vowel = rounded and "\195\188" or "i"  -- ü / i
    end
    local suffix
    if stemEndsInVowelLocal(workingStem) then
        suffix = "n" .. vowel .. "n"
    else
        suffix = vowel .. "n"
    end
    -- 8.16.x: proper nouns take apostrophe before the case suffix.
    -- "John" + GEN → "John'un", not "Johnun". Real Turkish writing
    -- convention separates the suffix from the proper noun stem.
    local separator = ""
    if opts.isProperNoun then
        separator = "'"
    end
    return workingStem .. separator .. suffix, {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(+morph)" or "STEM" },
        { surface = (separator ~= "" and separator or "") .. suffix,
          gloss = "GEN(" .. (cls or "front") .. (rounded and ",round" or "")
                  .. (opts.isProperNoun and ",proper" or "") .. ")" },
    }
end

-- ---------------------------------------------------------------------------
-- Plural noun marker.
--
-- Turkish plurals use -ler / -lar under two-way harmony (front vs back).
-- The vowel in -lEr is harmony-sensitive, but the consonant l is stable.
-- The plural attaches BEFORE the case suffix when both apply:
--   film + ler        = filmler        (movies)
--   kitap + lar       = kitaplar       (books)
--   film + ler + i    = filmleri       (the movies, accusative)
--   kitap + lar + i   = kitapları      (the books, accusative)
--
-- Returns the plural stem; callers chain accusative on top if needed.
-- ---------------------------------------------------------------------------

function M.applyPlural(stem)
    local cls = lastVowelClass(stem)
    local suffix = (cls == "back") and "lar" or "ler"
    return stem .. suffix, {
        { surface = stem, gloss = "STEM" },
        { surface = suffix, gloss = "PL(" .. (cls or "front") .. ")" },
    }
end

-- ---------------------------------------------------------------------------
-- Copular suffix on adjective/noun predicates.
--
-- Turkish "to be" is not a separate verb in present-tense copular sentences;
-- instead, person/number agreement attaches directly to the predicate
-- (adjective or noun). The suffix harmonises with the predicate's last vowel
-- under four-way harmony.
--
-- Personal endings (4-way harmony, after consonant-final predicate):
--   1sg : -im  / -ım  / -um  / -üm     (yorgunum  = I am tired)
--   2sg : -sin / -sın / -sun / -sün    (mutlusun  = you are happy)
--   3sg : ""                            (yorgun    = he/she is tired)
--   1pl : -iz  / -ız  / -uz  / -üz     (arkadaşız = we are friends)
--   2pl : -siniz / -sınız / -sunuz / -sünüz
--   3pl : -ler / -lar                  (yorgunlar = they are tired)
--
-- When the predicate ends in a vowel, a y-buffer is inserted before the
-- 1sg/1pl/2sg/2pl vowel-initial endings: mutlu + y + um = mutluyum.
-- 3sg never appears (zero suffix) and 3pl attaches with no buffer.
-- ---------------------------------------------------------------------------

local COPULAR_ENDINGS_BY_VOWEL = {
    ["i"]        = { ["1sg"] = "im",  ["2sg"] = "sin",  ["3sg"] = "",  ["1pl"] = "iz",  ["2pl"] = "siniz",  ["3pl"] = "ler" },
    ["\196\177"] = { ["1sg"] = "\196\177m",  ["2sg"] = "s\196\177n",  ["3sg"] = "",  ["1pl"] = "\196\177z",  ["2pl"] = "s\196\177n\196\177z",  ["3pl"] = "lar" },
    ["u"]        = { ["1sg"] = "um",  ["2sg"] = "sun",  ["3sg"] = "",  ["1pl"] = "uz",  ["2pl"] = "sunuz",  ["3pl"] = "lar" },
    ["\195\188"] = { ["1sg"] = "\195\188m",  ["2sg"] = "s\195\188n",  ["3sg"] = "",  ["1pl"] = "\195\188z",  ["2pl"] = "s\195\188n\195\188z",  ["3pl"] = "ler" },
}

function M.applyCopular(stem, personNumber)
    local cls = lastVowelClass(stem)
    local v = bufferVowel(stem)
    local endings = COPULAR_ENDINGS_BY_VOWEL[v] or COPULAR_ENDINGS_BY_VOWEL["i"]
    local ending = endings[personNumber]
    if not ending then
        error("unknown person/number for copular: " .. tostring(personNumber))
    end
    if ending == "" then
        return stem, {
            { surface = stem, gloss = "STEM" },
            { surface = "\195\152", gloss = "COP.AGR(3SG zero)" },
        }
    end

    local last
    for ch in utf8chars(stem) do last = ch end
    local stemEndsInVowel = (FRONT[last] or BACK[last]) ~= nil
    local endingStartsWithVowel = (
        ending:sub(1, 1) == "i" or ending:sub(1, 1) == "u"
        or ending:sub(1, 2) == "\196\177"
        or ending:sub(1, 2) == "\195\188"
    )

    if stemEndsInVowel and endingStartsWithVowel then
        return stem .. "y" .. ending, {
            { surface = stem, gloss = "STEM" },
            { surface = "y", gloss = "Y-BUFFER" },
            { surface = ending, gloss = "COP.AGR(" .. personNumber:upper() .. ")" },
        }
    end
    return stem .. ending, {
        { surface = stem, gloss = "STEM" },
        { surface = ending, gloss = "COP.AGR(" .. personNumber:upper() .. ")" },
    }
end

-- Present progressive personal endings. 3sg is bare; the others append the
-- harmony-appropriate person/number suffix. Person/number is keyed as a
-- "{person}{number}" string for clean dispatch from the analyzer.
--
-- Personal endings AFTER the -yor:
--   1sg : -um    2sg : -sun    3sg : ""     1pl : -uz    2pl : -sunuz    3pl : -lar
--
-- All endings here are post-yor, and -yor's last vowel "o" is back rounded,
-- so the harmony class for what follows is back rounded -> -u/-uz/-sun/-sunuz/-um.
local PERSON_ENDINGS_AFTER_YOR = {
    ["1sg"] = "um",
    ["2sg"] = "sun",
    ["3sg"] = "",
    ["1pl"] = "uz",
    ["2pl"] = "sunuz",
    ["3pl"] = "lar",
}

-- ---------------------------------------------------------------------------
-- Intervocalic voicing. Some Turkish verbs lexically mark for voicing the
-- stem-final voiceless consonant when followed by a vowel-initial suffix:
--   git (go)  + iyor  -> gidiyor    (t -> d)
--   et (do)   + iyor  -> ediyor     (t -> d)
-- Others resist: bit (finish), iç (drink), yap (do/make) keep their final
-- consonant in present progressive. Marked per-entry via the lexicon's
-- tr_intervocalic_voicing flag, NOT as a universal rule.
-- ---------------------------------------------------------------------------

local INTERVOCALIC_VOICING = {
    ["t"] = "d",
    ["k"] = "\196\159",  -- soft g
    ["p"] = "b",
    ["\195\167"] = "c",  -- c-cedilla -> c
}

local function applyIntervocalicVoicing(stem)
    local last
    for ch in utf8chars(stem) do last = ch end
    local mapped = INTERVOCALIC_VOICING[last]
    if not mapped then return stem end
    -- Drop last char and append voiced equivalent
    local count = 0
    for _ in utf8chars(stem) do count = count + 1 end
    local i = 0
    local out = {}
    for ch in utf8chars(stem) do
        i = i + 1
        if i < count then table.insert(out, ch) end
    end
    return table.concat(out) .. mapped
end

M.applyIntervocalicVoicing = applyIntervocalicVoicing

-- Conjugate a verb stem in present progressive for a given person/number.
-- Opts:
--   intervocalic_voicing = true  -- apply t->d / k->g / p->b / c-cedilla->c
--                                   when stem ends in voiceless consonant
--                                   (lexically marked verbs only)
function M.conjugatePresProg(stem, personNumber, opts)
    opts = opts or {}
    local ending = PERSON_ENDINGS_AFTER_YOR[personNumber]
    if not ending then
        error("unknown person/number: " .. tostring(personNumber))
    end

    local lastChar
    for ch in utf8chars(stem) do lastChar = ch end
    local stemEndsInVowel = (FRONT[lastChar] or BACK[lastChar]) ~= nil

    local workingStem
    local stemNote  -- annotation for the trace
    if stemEndsInVowel then
        local count = 0
        for _ in utf8chars(stem) do count = count + 1 end
        local i = 0
        local without = {}
        for ch in utf8chars(stem) do
            i = i + 1
            if i < count then table.insert(without, ch) end
        end
        workingStem = table.concat(without)
        stemNote = "STEM(final vowel deleted)"
    elseif opts.intervocalic_voicing then
        workingStem = applyIntervocalicVoicing(stem)
        stemNote = (workingStem ~= stem) and "STEM(voiced)" or "STEM"
    else
        workingStem = stem
        stemNote = "STEM"
    end

    local buffer = bufferVowel(workingStem)
    local form = workingStem .. buffer .. "yor" .. ending

    local morphemes = {
        { surface = workingStem, gloss = stemNote },
        { surface = buffer, gloss = "BUFFER(harmony)" },
        { surface = "yor", gloss = "PROG" },
        { surface = (ending == "" and "\195\152" or ending),
          gloss = "AGR(" .. personNumber:upper() .. ")" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Past progressive conjugation (9.1+).
--
-- Form: stem + bufferV + "yor" + "du" + person.
-- The past suffix is invariant -du after -yor because "yor" ends in the
-- back-rounded vowel /o/, which selects -du in past-tense harmony.
-- The 3pl form deviates: the -lar(/-ler) plural marker comes BEFORE the
-- past, yielding V-iyorlar-dı rather than V-iyor-du-lar (which is also
-- acceptable but less natural in this aspect/tense combination).
--
-- Examples:
--   bekle + 1sg -> bekliyordum   (I was waiting / I have been waiting)
--   çalış + 3sg -> çalışıyordu   (s/he was working)
--   oyna  + 1pl -> oynuyorduk    (we were playing -- with vowel deletion)
--   git   + 3pl -> gidiyorlardı  (they were going -- intervocalic voicing)
--
-- Used by the Mosaic-level perfect-progressive rewriter ("I have been
-- V-ing") since the English perfect-progressive most naturally maps to
-- Turkish past progressive in chat context.
-- ---------------------------------------------------------------------------

local PERSON_ENDINGS_AFTER_YORDU = {
    ["1sg"] = "m",      -- yordum
    ["2sg"] = "n",      -- yordun
    ["3sg"] = "",       -- yordu
    ["1pl"] = "k",      -- yorduk
    ["2pl"] = "nuz",    -- yordunuz
}

function M.conjugatePastProgressive(stem, personNumber, opts)
    opts = opts or {}

    local lastChar
    for ch in utf8chars(stem) do lastChar = ch end
    local stemEndsInVowel = (FRONT[lastChar] or BACK[lastChar]) ~= nil

    local workingStem
    local stemNote
    if stemEndsInVowel then
        local count = 0
        for _ in utf8chars(stem) do count = count + 1 end
        local i = 0
        local without = {}
        for ch in utf8chars(stem) do
            i = i + 1
            if i < count then table.insert(without, ch) end
        end
        workingStem = table.concat(without)
        stemNote = "STEM(final vowel deleted)"
    elseif opts.intervocalic_voicing then
        workingStem = applyIntervocalicVoicing(stem)
        stemNote = (workingStem ~= stem) and "STEM(voiced)" or "STEM"
    else
        workingStem = stem
        stemNote = "STEM"
    end

    local buffer = bufferVowel(workingStem)

    local form, morphemes
    if personNumber == "3pl" then
        -- Special 3pl shape: -lar comes BEFORE past. After the frozen
        -- -yor suffix (ending in back-rounded "o"), subsequent harmony
        -- is always back, so 3pl is invariably "yorlardı" regardless
        -- of the stem's front/back class.
        form = workingStem .. buffer .. "yorlard\196\177"
        morphemes = {
            { surface = workingStem, gloss = stemNote },
            { surface = buffer, gloss = "BUFFER(harmony)" },
            { surface = "yor", gloss = "PROG" },
            { surface = "lar", gloss = "PL(3PL)" },
            { surface = "d\196\177", gloss = "PAST" },
        }
    else
        local ending = PERSON_ENDINGS_AFTER_YORDU[personNumber]
        if not ending then
            error("unknown person/number for past-progressive: " ..
                  tostring(personNumber))
        end
        form = workingStem .. buffer .. "yordu" .. ending
        morphemes = {
            { surface = workingStem, gloss = stemNote },
            { surface = buffer, gloss = "BUFFER(harmony)" },
            { surface = "yor", gloss = "PROG" },
            { surface = "du", gloss = "PAST" },
            { surface = (ending == "" and "\195\152" or ending),
              gloss = "AGR(" .. personNumber:upper() .. ")" },
        }
    end
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Accusative case marker on definite objects.
--
-- The accusative suffix is -i/-dotless-i/-u/-ue under four-way harmony.
-- Voicing assimilation on stem-final voiceless consonants: when -i attaches
-- to a stem ending in k/p/t, the consonant voices to gh/b/d. For our PoC:
--    ekmek -> ekmegi    (k -> gh under accusative)
--    kitap -> kitabi    (p -> b)
--
-- Returns the surface form, e.g. applyAccusative("su") -> "suyu"
-- (note the y-buffer between vowels), applyAccusative("ekmek", {voicing=true})
-- -> "ekmegi".
-- ---------------------------------------------------------------------------

-- Four-way accusative vowel selection by last stem vowel.
local function accVowel(stem)
    local lastVowel
    for ch in utf8chars(stem) do
        if FRONT[ch] or BACK[ch] then lastVowel = ch end
    end
    if not lastVowel then return "i" end
    if lastVowel == "a" or lastVowel == "\196\177" then return "\196\177" end
    if lastVowel == "e" or lastVowel == "i"        then return "i"          end
    if lastVowel == "o" or lastVowel == "u"        then return "u"          end
    if lastVowel == "\195\182" or lastVowel == "\195\188" then return "\195\188" end
    return "i"
end

M.accVowel = accVowel

-- Voicing map for stem-final consonants under vowel-initial suffix attach.
local VOICING_MAP = {
    k = "\196\159",  -- k -> soft g (gh)
    p = "b",
    t = "d",
    ["\195\167"] = "c",     -- voiceless palatal -> voiced
}

local lastChar = Str.lastChar
local function dropLastChar(s) return Str.dropLast(s, 1) end

function M.applyAccusative(stem, opts)
    opts = opts or {}
    local vowel = accVowel(stem)

    -- 8.16.x: n-buffer after POSS-3sg/3pl. Turkish case suffixes after the
    -- 3rd-person possessive (-ı/-i/-u/-ü, or -ları/-leri) use a pronominal
    -- -n- buffer instead of the standard vowel y-buffer. "tabancası" + ACC
    -- = "tabancasını" (not "tabancasıyı"). This rule extends to 3sg pronoun
    -- "o" + ACC = "onu" (no buffer at all, irregular).
    if opts.afterPossessive3 then
        return stem .. "n" .. vowel, {
            { surface = stem, gloss = "STEM(+POSS)" },
            { surface = "n", gloss = "N-BUFFER(post-POSS-3)" },
            { surface = vowel, gloss = "ACC" },
        }
    end

    -- Y-buffer when stem ends in a vowel (su + u -> suyu, not "suu")
    local lc = lastChar(stem)
    if FRONT[lc] or BACK[lc] then
        return stem .. "y" .. vowel, {
            { surface = stem, gloss = "STEM" },
            { surface = "y", gloss = "Y-BUFFER" },
            { surface = vowel, gloss = "ACC" },
        }
    end

    -- Voicing on stem-final consonant (ekmek -> ekmegi)
    if opts.voicing and VOICING_MAP[lc] then
        return dropLastChar(stem) .. VOICING_MAP[lc] .. vowel, {
            { surface = dropLastChar(stem) .. VOICING_MAP[lc], gloss = "STEM(voiced)" },
            { surface = vowel, gloss = "ACC" },
        }
    end

    -- Otherwise plain attach
    return stem .. vowel, {
        { surface = stem, gloss = "STEM" },
        { surface = vowel, gloss = "ACC" },
    }
end

-- ---------------------------------------------------------------------------
-- Possessive suffix on a noun stem.
--
-- Marks the noun as possessed by a person/number. Used for both bare
-- possessives ("my house" -> "evim") and the existential-have construction
-- ("I have a car" -> "Bir arabam var" = "a car-of-mine exists").
--
-- Suffix shapes, by person + whether the stem ends in vowel (V) or
-- consonant (C). All vowels harmonise (4-way: i/ı/u/ü).
--
--   1sg  C: -V-m   V: -m       evim,    arabam
--   2sg  C: -V-n   V: -n       evin,    araban
--   3sg  C: -V     V: -s-V     evi,     arabası
--   1pl  C: -V-m-V-z V: -m-V-z evimiz,  arabamız
--   2pl  C: -V-n-V-z V: -n-V-z eviniz,  arabanız
--   3pl  C: -ları/-leri V: same   evleri, arabaları
--
-- Voicing on the stem-final consonant applies for 1sg/2sg/3sg/1pl/2pl
-- (because the buffer vowel makes the stem-final consonant intervocalic).
-- 3pl doesn't trigger voicing because the suffix is consonant-initial (-l).
-- ---------------------------------------------------------------------------

local POSSESSIVE_TEMPLATES = {
    -- For each personNumber, two cases: after-consonant (C) and after-vowel (V).
    -- The suffix templates use 'V' as a placeholder for the harmonised buffer
    -- vowel and the harmony decision is made at expand time.
    ["1sg"] = { afterC = "V" .. "m",       afterV = "m" },
    ["2sg"] = { afterC = "V" .. "n",       afterV = "n" },
    ["3sg"] = { afterC = "V",              afterV = "sV" },
    ["1pl"] = { afterC = "VmVz",           afterV = "mVz" },
    ["2pl"] = { afterC = "VnVz",           afterV = "nVz" },
    -- 3pl: -ları (back) / -leri (front); we'll handle this case specially
    ["3pl"] = { afterC = "PL3",            afterV = "PL3" },
}

-- Irregular vowel-final stems that take y-buffer for possessive/case
-- suffixes instead of the standard vowel-deletion rule. Mostly
-- monosyllabic stems where deletion would leave too little:
--   su  (water) + 1sg = suyum   (not sum)
--   ne  (what)  + 1sg = neyim   (not nem)
local IRREGULAR_Y_BUFFER_STEMS = {
    ["su"] = true,
    ["ne"] = true,
}

function M.applyPossessive(stem, personNumber, opts)
    opts = opts or {}
    local template = POSSESSIVE_TEMPLATES[personNumber]
    if not template then
        error("unknown person/number for possessive: " .. tostring(personNumber))
    end

    local last
    for ch in utf8chars(stem) do last = ch end
    local vowelFinal = (FRONT[last] or BACK[last]) ~= nil

    -- Irregular y-buffer stems (su, ne, ...): append y and treat as
    -- consonant-final. Harmony is computed on the original vowel.
    local irregularY = vowelFinal and IRREGULAR_Y_BUFFER_STEMS[stem]
    if irregularY then
        vowelFinal = false  -- now treat as consonant-final
    end

    -- 3pl special: -ları / -leri (no harmony beyond two-way)
    -- Note: -lar/-ler suffix starts with consonant, so y-buffer is NOT
    -- needed even for irregular-y-buffer stems (su + 3pl = suları, not suyları)
    --
    -- 8.16.x: when the stem is already pluralized (ends in -lar/-ler),
    -- POSS-3pl just adds the harmonic vowel buffer (-ı/-i), NOT the full
    -- -ları/-leri suffix. "odalar" + POSS-3pl = "odaları" (not
    -- "odalarları"). Turkish doesn't double-pluralize.
    if personNumber == "3pl" then
        local cls = lastVowelClass(stem)
        local stemEndsInPL = (stem:sub(-3) == "lar") or (stem:sub(-3) == "ler")
        local suffix
        if stemEndsInPL then
            -- Stem is already plural; just add harmonic vowel
            suffix = (cls == "back") and "\196\177" or "i"
        else
            suffix = (cls == "back") and "lar\196\177" or "leri"
        end
        return stem .. suffix, {
            { surface = stem, gloss = "STEM" },
            { surface = suffix,
              gloss = stemEndsInPL and "POSS.3PL(post-PL)" or "POSS.3PL" },
        }
    end

    -- Apply voicing for vowel-initial possessive on consonant-final stem
    local workingStem = irregularY and (stem .. "y") or stem
    local voiced = false
    if not irregularY and not vowelFinal and opts.voicing and VOICING_MAP[last] then
        workingStem = dropLastChar(stem) .. VOICING_MAP[last]
        voiced = true
    end

    -- Expand the template with the harmonised buffer vowel
    local buffer = bufferVowel(workingStem)
    local raw = vowelFinal and template.afterV or template.afterC
    local expanded = raw:gsub("V", buffer)

    return workingStem .. expanded, {
        { surface = workingStem,
          gloss = irregularY and "STEM(+y-irregular)" or
                  (voiced and "STEM(voiced)" or "STEM") },
        { surface = expanded,
          gloss = "POSS." .. personNumber:upper() },
    }
end

-- ---------------------------------------------------------------------------
-- Modal verb morphology (8.9.17+).
--
-- Turkish modals are NOT standalone words: they attach as suffixes to the
-- verb stem, then take person/number agreement. Where English says "I can
-- run", Turkish says "koşabilirim" -- one word. Where English says "I
-- will run", Turkish says "koşacağım". Etc.
--
-- This helper handles the four most common modal categories:
--
--   ability/possibility:  can, may       -> stem + (e)bil + ir + person
--                                          (back: -abilir / front: -ebilir)
--   future:               will           -> stem + (e)cek + person
--                                          (back: -acak / front: -ecek)
--                                          with intervocalic voicing k -> g
--                                          before vowel-initial person ending
--   necessity:            should, must   -> stem + (m)alI + person
--                                          (back: -malI / front: -meli)
--
-- Each modal has:
--   * suffix_back / suffix_front : the modal suffix with two harmony shapes
--   * aorist                     : true if -(I)r marker required after suffix
--                                  (only -bil-based modals; "I can/may")
--   * voicing                    : true if intervocalic k->g applies before
--                                  vowel-initial person endings (only -cek/-cak)
--   * person_endings (or .._back/.._front) : the agreement endings to append
--
-- All endings start with the buffer "y" where needed, baked into the
-- ending text itself for cleanliness.
--
-- The y-buffer between a vowel-ending stem and a vowel-initial modal
-- suffix is inserted dynamically (koş + abilir vs bekle + yabilir... wait,
-- bekle is front, so bekle + yebilir = bekleyebilir).
--
-- Could (past ability), would (conditional), and might (weak ability) are
-- deferred to a later ship: their morphology adds another tense layer
-- (-di for past, -se for conditional) on top of the modal suffix, and
-- their semantics are ambiguous enough that v1 would mistranslate as
-- often as it would help.
-- ---------------------------------------------------------------------------

local MODAL_DATA = {
    -- can / may (ability, possibility): -ebilir / -abilir
    -- Negated: stem + (e/a)mez/maz + person (aorist negative).
    --   "koşamam" (I can't run), "gelemem" (I can't come)
    can = {
        suffix_back  = "abil",
        suffix_front = "ebil",
        aorist       = true,    -- adds -ir after the modal suffix
        voicing      = false,
        -- After -bilir, last vowel is "i" (front, unrounded), so person
        -- endings are I-type front. SAME for both -abilir and -ebilir
        -- because the aorist -ir is what governs the next harmony step.
        person_endings = {
            ["1sg"] = "im",
            ["2sg"] = "sin",
            ["3sg"] = "",
            ["1pl"] = "iz",
            ["2pl"] = "siniz",
            ["3pl"] = "ler",
        },
        -- NEGATED forms (8.9.22+): aorist negative.
        --   koş + amam = koşamam (I can't run)
        --   koş + amaz = koşamaz (he can't run)
        --   gel + emem = gelemem (I can't come)
        neg_suffix_back  = "amaz",       -- stem + amaz + person (back stems)
        neg_suffix_front = "emez",       -- stem + emez + person (front stems)
        -- After -amaz/-emez (last vowel a/e), person endings are mostly:
        -- 1sg has special form (drops "z" + "m"), others append normally.
        neg_person_endings_back = {
            ["1sg"] = "_AM_",   -- special: replace amaz with amam
            ["2sg"] = "s\196\177n",
            ["3sg"] = "",
            ["1pl"] = "_AYIZ_", -- special: replace amaz with amayız
            ["2pl"] = "s\196\177n\196\177z",
            ["3pl"] = "lar",
        },
        neg_person_endings_front = {
            ["1sg"] = "_EM_",   -- special: replace emez with emem
            ["2sg"] = "sin",
            ["3sg"] = "",
            ["1pl"] = "_EYIZ_", -- special: replace emez with emeyiz
            ["2pl"] = "siniz",
            ["3pl"] = "ler",
        },
    },
    -- will (future): -ecek / -acak
    -- Negated: stem + ma/me + yacak/yecek + person.
    --   "koşmayacağım" (I won't run), "gelmeyeceğim" (I won't come)
    will = {
        suffix_back  = "acak",
        suffix_front = "ecek",
        aorist       = false,
        voicing      = true,    -- k -> g (yumusak g) before vowel suffix
        person_endings_back = {
            ["1sg"] = "\196\177m",
            ["2sg"] = "s\196\177n",
            ["3sg"] = "",
            ["1pl"] = "\196\177z",
            ["2pl"] = "s\196\177n\196\177z",
            ["3pl"] = "lar",
        },
        person_endings_front = {
            ["1sg"] = "im",
            ["2sg"] = "sin",
            ["3sg"] = "",
            ["1pl"] = "iz",
            ["2pl"] = "siniz",
            ["3pl"] = "ler",
        },
        -- NEGATED forms: insert "ma/me" + "yacak/yecek" before person.
        -- The "y" buffer is included because ma/me ends in vowel and
        -- yacak/yecek starts with consonant -- wait, "yacak" starts with
        -- "y" already. Actually the structure is: stem + ma/me + (NO buffer)
        -- + yacak/yecek + person.
        -- "koşmayacağım" = koş + ma + yacak (with k->ğ) + ım
        neg_suffix_back  = "mayacak",   -- back: ma + yacak
        neg_suffix_front = "meyecek",   -- front: me + yecek
        -- Person endings same as positive will, k->ğ voicing same too
    },
    -- should / must (necessity, obligation): -malI / -meli
    should = {
        suffix_back  = "mal\196\177",  -- -malı
        suffix_front = "meli",
        aorist       = false,
        voicing      = false,
        person_endings_back = {
            ["1sg"] = "y\196\177m",
            ["2sg"] = "s\196\177n",
            ["3sg"] = "",
            ["1pl"] = "y\196\177z",
            ["2pl"] = "s\196\177n\196\177z",
            ["3pl"] = "lar",
        },
        person_endings_front = {
            ["1sg"] = "yim",
            ["2sg"] = "sin",
            ["3sg"] = "",
            ["1pl"] = "yiz",
            ["2pl"] = "siniz",
            ["3pl"] = "ler",
        },
        -- NEGATED forms: ma/me + malı/meli
        neg_suffix_back  = "mamal\196\177",
        neg_suffix_front = "memeli",
        -- Person endings same as positive should
    },
    -- 8.10.2+: could (CAN.PAST: ability in past, also polite request)
    -- Pattern: stem + (a/e)bildi + past-person-endings.
    --   "Koşabildim" (I could/was able to run)
    --   "Gelebildi" (he could/was able to come)
    --   "Görebildiniz" (you could see -- polite/formal 2pl)
    -- The -bildi ends in front-unrounded "i", so person endings after it
    -- all use front-unrounded harmony regardless of stem.
    could = {
        suffix_back  = "abildi",
        suffix_front = "ebildi",
        aorist       = false,
        voicing      = false,
        person_endings = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "niz",
            ["3pl"] = "ler",
        },
        -- 9.0+: negated could (past aorist negative).
        --   koş + amadı + m = koşamadım (I could not run)
        --   gel + emedi + m = gelemedim (I could not come)
        -- Structure: stem + (a/e)madı/medi + person.
        -- The final vowel of -amadı is ı (back); of -emedi is i (front).
        -- Person endings have to be split by harmony so 2pl ends with the
        -- right unrounded high vowel (-nız vs -niz).
        neg_suffix_back  = "amad\196\177",
        neg_suffix_front = "emedi",
        neg_person_endings_back = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "n\196\177z",
            ["3pl"] = "lar",
        },
        neg_person_endings_front = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "niz",
            ["3pl"] = "ler",
        },
    },
    -- 8.10.2+: would (WILL.PAST: hypothetical, conditional, habitual past)
    -- Pattern: stem + (a/e)cak + tı/ti + past-person-endings.
    --   "Koşacaktım" (I would run / I was going to run)
    --   "Gelecekti" (he would come / he was going to come)
    -- After voiceless -k, the past suffix is -tı/-ti (voiceless). Person
    -- endings after the past suffix follow its harmony class.
    would = {
        suffix_back  = "acakt\196\177",   -- acaktı
        suffix_front = "ecekti",
        aorist       = false,
        voicing      = false,
        person_endings_back = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "n\196\177z",       -- nız
            ["3pl"] = "lar",
        },
        person_endings_front = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "niz",
            ["3pl"] = "ler",
        },
        -- 9.0+: negated would (past conditional/intention negative).
        --   koş + ma + yacak (k->ğ) + tı + m = koşmayacaktım (I wouldn't run)
        --   gel + me + yecek (k->ğ) + ti + m = gelmeyecektim
        -- Structure: stem + ma/me + yacak/yecek + tı/ti + person.
        neg_suffix_back  = "mayacakt\196\177",
        neg_suffix_front = "meyecekti",
        -- After -tı/-ti, person endings match harmony.
        neg_person_endings_back = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "n\196\177z",
            ["3pl"] = "lar",
        },
        neg_person_endings_front = {
            ["1sg"] = "m",
            ["2sg"] = "n",
            ["3sg"] = "",
            ["1pl"] = "k",
            ["2pl"] = "niz",
            ["3pl"] = "ler",
        },
    },
}
-- Aliases: must takes the same morphology as should; may and might both
-- take the same morphology as can. Keeping these as separate keys means
-- the lex entry can carry its own modal_type and we don't have to
-- translate them anywhere upstream.
MODAL_DATA.must  = MODAL_DATA.should
MODAL_DATA.may   = MODAL_DATA.can
MODAL_DATA.might = MODAL_DATA.can

M.MODAL_DATA = MODAL_DATA  -- exported for tests / inspection

-- Helper: detect whether a string starts with a vowel (handles UTF-8 multi-byte
-- codepoints for the Turkish-specific vowels). Used for y-buffer insertion
-- and intervocalic voicing decisions.
local function startsWithVowel(s)
    if s == "" then return false end
    local first = s:sub(1, 1)
    if FRONT[first] or BACK[first] then return true end
    local twoByte = s:sub(1, 2)
    if FRONT[twoByte] or BACK[twoByte] then return true end
    return false
end

function M.applyModal(stem, modal, personNumber, opts)
    opts = opts or {}
    local negated = opts.negated or false
    local data = MODAL_DATA[modal]
    if not data then
        error("unknown modal: " .. tostring(modal))
    end

    local cls = lastVowelClass(stem)
    -- Pick modal suffix shape based on stem's harmony class. NEGATED forms
    -- use neg_suffix_back/front. Positive forms use suffix_back/front.
    -- Neutral stems default to FRONT (the unmarked / most common case).
    local suffix
    if negated then
        if cls == "back" then
            suffix = data.neg_suffix_back
        else
            suffix = data.neg_suffix_front
        end
    else
        if cls == "back" then
            suffix = data.suffix_back
        else
            suffix = data.suffix_front
        end
    end

    if not suffix then
        error("modal " .. modal .. " missing negated suffix data")
    end

    local suffixStartsWithVowel = startsWithVowel(suffix)

    -- Stem-side intervocalic voicing: verbs flagged in the lex with
    -- tr_intervocalic_voicing=true (like "git" -> "gid-" before any
    -- vowel-initial suffix) need their stem-final consonant voiced
    -- BEFORE the modal suffix attaches. For NEGATED modals where the
    -- suffix starts with consonant (m), no voicing fires.
    local workingStem = stem
    if opts.intervocalic_voicing and suffixStartsWithVowel then
        workingStem = applyIntervocalicVoicing(stem)
    end

    -- Y-buffer between vowel-ending stem and vowel-initial modal suffix.
    -- Only some modals start with vowels (-abil/-ebil, -acak/-ecek);
    -- -malı/-meli start with a consonant so no buffer needed. Negated
    -- forms all start with "m" so no y-buffer is needed.
    local last
    for ch in utf8chars(workingStem) do last = ch end
    local stemEndsInVowel = (FRONT[last] or BACK[last]) ~= nil

    local stemWithBuffer = workingStem
    if stemEndsInVowel and suffixStartsWithVowel then
        stemWithBuffer = workingStem .. "y"
    end

    local body = stemWithBuffer .. suffix

    -- Aorist marker (-ir after -bil-) for can/may modals -- POSITIVE ONLY.
    -- The negated CAN form ("amaz/emez") IS the aorist negative already,
    -- so no extra -ir needed.
    if data.aorist and not negated then
        body = body .. "ir"
    end

    -- Select person endings table.
    -- For CAN (positive): single person_endings table (governed by -bilir's i).
    -- For CAN (negated): split by harmony, with special placeholder endings.
    -- For WILL/SHOULD: split by harmony (positive AND negated use same set).
    local endings
    if negated then
        if data.neg_person_endings_back then
            -- can/may negated has its own person endings (with placeholders)
            if cls == "back" then
                endings = data.neg_person_endings_back
            else
                endings = data.neg_person_endings_front
            end
        else
            -- will/should negated reuse the positive person endings
            if cls == "back" then
                endings = data.person_endings_back
            else
                endings = data.person_endings_front
            end
        end
    else
        endings = data.person_endings
        if not endings then
            if cls == "back" then
                endings = data.person_endings_back
            else
                endings = data.person_endings_front
            end
        end
    end

    local ending = endings[personNumber]
    if not ending then
        error("unknown person/number for modal: " .. tostring(personNumber))
    end

    -- Handle special placeholder endings for negated CAN:
    -- The aorist negative -amaz/-emez has irregular 1sg / 1pl forms:
    --   -amaz + 1sg -> -amam (drops z, adds m)
    --   -amaz + 1pl -> -amayız (drops z, adds yız)
    -- Same for front: -emez + 1sg -> -emem, -emez + 1pl -> -emeyiz.
    if ending == "_AM_" then
        body = body:sub(1, -2) .. "m"  -- amaz -> amam
        ending = ""
    elseif ending == "_AYIZ_" then
        body = body:sub(1, -2) .. "y\196\177z"  -- amaz -> amayız
        ending = ""
    elseif ending == "_EM_" then
        body = body:sub(1, -2) .. "m"  -- emez -> emem
        ending = ""
    elseif ending == "_EYIZ_" then
        body = body:sub(1, -2) .. "yiz"  -- emez -> emeyiz
        ending = ""
    end

    -- 3sg ending is empty: return body as-is, no voicing concern.
    if ending == "" then
        local m3 = {
            { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(voiced)" or "STEM" },
        }
        if stemWithBuffer ~= workingStem then
            table.insert(m3, { surface = "y", gloss = "Y-BUFFER" })
        end
        local glossName = negated and ("MODAL." .. modal:upper() .. ".NEG") or ("MODAL." .. modal:upper())
        table.insert(m3, { surface = suffix, gloss = glossName })
        if data.aorist and not negated then
            table.insert(m3, { surface = "ir", gloss = "AOR" })
        end
        table.insert(m3, { surface = "", gloss = "AGR(3SG zero)" })
        return body, m3
    end

    -- Intervocalic voicing for -cek/-cak modal: k -> g (yumusak g) before
    -- vowel-initial person ending. koşacak + ım -> koşacağım.
    -- Same for negated will: koşmayacak + ım -> koşmayacağım.
    local voicedBody = body
    if data.voicing then
        local bodyFinal = body:sub(-1)
        if bodyFinal == "k" and startsWithVowel(ending) then
            voicedBody = body:sub(1, -2) .. "\196\159"  -- k -> ğ
        end
    end

    local morphemes = {
        { surface = workingStem, gloss = (workingStem ~= stem) and "STEM(voiced)" or "STEM" },
    }
    if stemWithBuffer ~= workingStem then
        table.insert(morphemes, { surface = "y", gloss = "Y-BUFFER" })
    end
    local glossName = negated and ("MODAL." .. modal:upper() .. ".NEG") or ("MODAL." .. modal:upper())
    table.insert(morphemes, { surface = suffix, gloss = glossName })
    if data.aorist and not negated then
        table.insert(morphemes, { surface = "ir", gloss = "AOR" })
    end
    table.insert(morphemes, { surface = ending, gloss = "AGR(" .. personNumber:upper() .. ")" })

    return voicedBody .. ending, morphemes
end

-- ---------------------------------------------------------------------------
-- Question particle morphology (8.9.18+).
--
-- Turkish yes/no questions are formed by attaching the particle "mı/mi/mu/mü"
-- to the predicate, with vowel harmony determined by the last vowel of the
-- predicate. Person/number agreement attaches to the particle OR to the
-- predicate, depending on tense:
--
--   COPULAR predicates (zero suffix in 3sg):
--     "yorgun" (tired) + "musun?" -> "Yorgun musun?" (Are you tired?)
--     Predicate emitted BARE; particle takes the agreement.
--
--   VERBAL PAST (-di) predicates:
--     "koştun" (you ran) + "mu?" -> "Koştun mu?" (Did you run?)
--     Predicate emitted with full agreement; particle is BARE.
--
--   VERBAL PRESENT PROGRESSIVE (-yor) predicates (proper rule):
--     "koşuyor" (running, 3sg) + "musun?" -> "Koşuyor musun?" (Are you running?)
--     Predicate emitted WITHOUT person agreement; particle takes agreement.
--     v1 SIMPLIFICATION: we emit the verb with full agreement and append a
--     bare particle, producing "Koşuyorsun mu?" -- grammatically nonstandard
--     but readable. Proper splitting is a follow-up refinement.
--
--   EXISTENTIAL ("var" / "yok"):
--     "Köpek var" + "mı?" -> "Köpek var mı?" (Is there a dog?)
--     Particle is BARE after var/yok.
--
-- This module provides two helpers; the engine decides which to call based
-- on the construction type.
-- ---------------------------------------------------------------------------

local function particleHarmony(stem)
    -- I-type harmony based on stem's last vowel. Returns the appropriate
    -- particle ("mı"/"mi"/"mu"/"mü") for the question form.
    local v = bufferVowel(stem)
    if v == "\196\177" then return "m\196\177" end       -- mı (back unrounded)
    if v == "u"        then return "mu" end                -- mu (back rounded)
    if v == "\195\188" then return "m\195\188" end        -- mü (front rounded)
    return "mi"                                            -- mi (front unrounded, default)
end

M.particleHarmony = particleHarmony

-- Agreement endings AFTER the question particle. The particle is the last
-- vowel of the new "stem" for harmony purposes, so endings follow I-type
-- harmony based on the particle vowel.
local Q_AGR_AFTER_BACK_UNROUNDED = {  -- after mı
    ["1sg"] = "y\196\177m",            -- -yım
    ["2sg"] = "s\196\177n",            -- -sın
    ["3sg"] = "",
    ["1pl"] = "y\196\177z",            -- -yız
    ["2pl"] = "s\196\177n\196\177z",   -- -sınız
    ["3pl"] = "lar",
}
local Q_AGR_AFTER_FRONT_UNROUNDED = {  -- after mi
    ["1sg"] = "yim",
    ["2sg"] = "sin",
    ["3sg"] = "",
    ["1pl"] = "yiz",
    ["2pl"] = "siniz",
    ["3pl"] = "ler",
}
local Q_AGR_AFTER_BACK_ROUNDED = {  -- after mu
    ["1sg"] = "yum",
    ["2sg"] = "sun",
    ["3sg"] = "",
    ["1pl"] = "yuz",
    ["2pl"] = "sunuz",
    ["3pl"] = "lar",
}
local Q_AGR_AFTER_FRONT_ROUNDED = {  -- after mü
    ["1sg"] = "y\195\188m",            -- -yüm
    ["2sg"] = "s\195\188n",            -- -sün
    ["3sg"] = "",
    ["1pl"] = "y\195\188z",            -- -yüz
    ["2pl"] = "s\195\188n\195\188z",   -- -sünüz
    ["3pl"] = "ler",
}

-- Returns the question particle with person/number agreement appended.
-- Used for copular questions ("Yorgun musun?") where the predicate is
-- emitted bare and the particle carries the agreement.
function M.applyQuestionParticleWithAgreement(predicateStem, personNumber)
    local v = bufferVowel(predicateStem)
    local particle, endings
    if v == "\196\177" then
        particle = "m\196\177"; endings = Q_AGR_AFTER_BACK_UNROUNDED
    elseif v == "u" then
        particle = "mu"; endings = Q_AGR_AFTER_BACK_ROUNDED
    elseif v == "\195\188" then
        particle = "m\195\188"; endings = Q_AGR_AFTER_FRONT_ROUNDED
    else
        particle = "mi"; endings = Q_AGR_AFTER_FRONT_UNROUNDED
    end
    local agr = endings[personNumber] or ""
    return particle .. agr
end

-- Returns just the bare harmony-matched particle. Used for verbal-past
-- questions ("Koştun mu?") and existential questions ("Köpek var mı?")
-- where the predicate already carries its agreement.
function M.applyQuestionParticleBare(predicateStem)
    return particleHarmony(predicateStem)
end

-- ---------------------------------------------------------------------------
-- Verbal noun / gerund-as-object (9.0+).
--
-- Generates the Turkish verbal noun form used as the object of a matrix
-- verb in constructions like "stop V-ing" / "start V-ing" / "want to V"
-- (the bare-infinitive complement of a control verb).
--
-- Morphology:
--   stem + (a/e)+ma/me     -> infinitive form (yapma, gelme, inanma)
--   + y                    -> buffer (because -ma/-me ends in vowel and
--                              accusative starts with vowel)
--   + ı/i/u/ü              -> accusative case marker (vowel harmony)
--
-- Examples:
--   inan + ma + y + ı = inanmayı  (believing-ACC)
--   koş  + ma + y + ı = koşmayı   (running-ACC)
--   gel  + me + y + i = gelmeyi   (coming-ACC)
--   gör  + me + y + i = görmeyi   (seeing-ACC)
--   yap  + ma + y + ı = yapmayı   (doing-ACC)
--
-- For dative ("to do, in order to") the same -ma/-me + y + a/e is used:
--   inan + ma + y + a = inanmaya  (believing-DAT, "to believe")
-- Currently we only emit the accusative form, used for direct-object
-- gerund complements ("stop believing"). The dative variant can be
-- added later when we tackle the ECM/causative cases.
-- ---------------------------------------------------------------------------

function M.applyVerbalNounAcc(stem, opts)
    opts = opts or {}
    local cls = lastVowelClass(stem)
    local maSuffix = (cls == "back") and "ma" or "me"
    -- Stem-side intervocalic voicing fires here because the -ma/-me suffix
    -- starts with consonant /m/ — wait, actually voicing applies to a
    -- stem-final voiceless stop only when the following suffix starts with
    -- a VOWEL. /m/ is a consonant, so no voicing.
    local workingStem = stem
    local infinitive = workingStem .. maSuffix
    -- Accusative: -ı/-i/-u/-ü by full vowel harmony.
    -- After -ma (back unrounded) -> ı; after -me (front unrounded) -> i.
    -- The infinitive's final vowel determines the case-marker vowel.
    local accVowelChar = (cls == "back") and "\196\177" or "i"
    -- Buffer y between infinitive's final vowel (a/e) and case-marker vowel.
    local form = infinitive .. "y" .. accVowelChar
    local morphemes = {
        { surface = workingStem, gloss = "STEM" },
        { surface = maSuffix,    gloss = "INF(" .. (cls or "front") .. ")" },
        { surface = "y" .. accVowelChar, gloss = "ACC" },
    }
    return form, morphemes
end

-- ---------------------------------------------------------------------------
-- Embedded clause / nominalised verb form (9.1+).
--
-- Builds: V-stem + (DIK | ACAK) + POSS + ACC.
--
-- This is the Turkish nominalised participle form used as the object of a
-- matrix verb in embedded clauses where the embedded clause's predicate
-- has its own tense/aspect and subject. Common contexts:
--
--   "I don't know what to say"   = Ne diyeceğimi bilmiyorum.
--      (de+ACAK+1SG.POSS+ACC -- "what I-will-say-OBJ")
--   "Tell me what you think"     = Ne düşündüğünü söyle.
--      (düşün+DIK+2SG.POSS+ACC -- "what you-think-OBJ")  
--   "Did you see what happened?" = Ne olduğunu gördün mü?
--      (ol+DIK+3SG.POSS+ACC -- "what (it)-happened-OBJ")
--   "I forgot what I bought"     = Ne aldığımı unuttum.
--      (al+DIK+1SG.POSS+ACC -- "what I-bought-OBJ")
--
-- Morphology layering:
--   1. STEM
--   2. DIK / ACAK with 4-way vowel harmony, voiceless assimilation (d->t
--      after voiceless stem-final), and y-buffer if stem ends in vowel.
--   3. POSS (existing applyPossessive handles k->ğ softening at the
--      DIK/ACAK-final k when the next morpheme starts with a vowel).
--   4. ACC. The 3SG POSS case needs n-buffer (NOT y-buffer) because the
--      pronominal-n linker fires between 3SG POSS and any following case
--      suffix; existing applyAccusative emits y-buffer so we handle the
--      3SG case manually here.
--
-- opts:
--   tense       = "past"   (DIK)  | "future" (ACAK).  Default "future"
--                 because the most common embedded-WH idioms ("what to
--                 say/do/eat") are forward-looking.
--   person      = "1sg" | "2sg" | "3sg" | "1pl" | "2pl" | "3pl".
--                 Default "1sg" (matching English matrix subject "I").
-- ---------------------------------------------------------------------------

function M.applyDikAcakPossAcc(stem, opts)
    opts = opts or {}
    local tense = opts.tense or "future"
    local person = opts.person or "1sg"

    -- Step 0: irregular stem alternation for "ye" (eat) and "de" (say).
    -- These two verbs raise their final vowel (e -> i) before vowel-initial
    -- suffixes. ACAK starts with a vowel; DIK does not.
    --   ye + ACAK -> yiyecek (with y-buffer, not yeyecek)
    --   de + ACAK -> diyecek (with y-buffer, not deyecek)
    --   ye + DIK  -> yedik   (regular, consonant-initial)
    local workingStem = stem
    if tense == "future" and (stem == "ye" or stem == "de") then
        workingStem = stem:sub(1, 1) .. "i"  -- ye->yi, de->di
    end

    -- Step 1: apply DIK or ACAK suffix to the (possibly alternated) stem
    local cls = lastVowelClass(workingStem)
    local last
    for ch in utf8chars(workingStem) do last = ch end
    local stemEndsInVowel = (FRONT[last] or BACK[last]) ~= nil

    local suffix
    if tense == "past" then
        local v = bufferVowel(workingStem)
        local d = pastSuffixInitial(workingStem)
        suffix = d .. v .. "k"
    else
        suffix = (cls == "back") and "acak" or "ecek"
    end

    -- Y-buffer if stem ends in vowel and suffix starts with vowel
    local suffixStartsVowel = suffix:sub(1, 1):match("[ae\196\177iou\195\182\195\188\195\162]") ~= nil
    local yBuffer = ""
    if stemEndsInVowel and suffixStartsVowel then
        yBuffer = "y"
    end

    local nominalStem = workingStem .. yBuffer .. suffix

    -- Step 2: apply person possessive. Existing applyPossessive handles
    -- the k->ğ softening at the suffix-POSS boundary (because POSS starts
    -- with a vowel after consonant-final stems, and the suffix ends in k).
    local possForm, possMorphs = M.applyPossessive(nominalStem, person,
        { voicing = true })

    -- Step 3: apply accusative. For 3SG and 3PL POSS, the form ends in a
    -- vowel and needs n-buffer (pronominal-n linker) before ACC. Other
    -- persons end in -m/-n/-z (consonants) and use plain ACC vowel attach.
    local accForm
    local accMorph
    if person == "3sg" or person == "3pl" then
        -- 3SG/3PL POSS ends in vowel (3sg: olduğu, diyeceği; 3pl: oldukları,
        -- diyecekleri). Add n-buffer + ACC vowel.
        local accV = accVowel(possForm)
        accForm = possForm .. "n" .. accV
        accMorph = { surface = "n" .. accV, gloss = "ACC(n-buffer)" }
    else
        -- Other persons end in consonant. Use applyAccusative which handles
        -- the consonant case correctly (no voicing trigger because the
        -- person endings -m/-n/-mız/-nız/-leri don't end in voiceless
        -- stops).
        local f, ms = M.applyAccusative(possForm, { voicing = false })
        accForm = f
        -- The last morpheme is the ACC vowel
        accMorph = ms[#ms]
    end

    -- Build the full morpheme trace
    local stemGloss = "STEM"
    if workingStem ~= stem then
        stemGloss = "STEM(alt:" .. stem .. ")"
    end
    local morphemes = {
        { surface = workingStem, gloss = stemGloss },
    }
    if yBuffer ~= "" then
        table.insert(morphemes,
            { surface = yBuffer, gloss = "Y-BUFFER" })
    end
    -- The DIK/ACAK suffix's trailing k softens to ğ when applyPossessive's
    -- voicing chain fires (which it does whenever the suffix's k is followed
    -- by a vowel-initial POSS morpheme — every person except possibly the
    -- 3pl which uses -leri/-ları). We detect this from the POSS morphemes
    -- by checking whether the first one is glossed as STEM(voiced).
    local suffixSurface = suffix
    local possFiredVoicing = (possMorphs[1] and possMorphs[1].gloss == "STEM(voiced)")
    if possFiredVoicing and suffix:sub(-1) == "k" then
        suffixSurface = suffix:sub(1, -2) .. "\196\159"  -- replace trailing k with ğ
    end
    table.insert(morphemes, {
        surface = suffixSurface,
        gloss = (tense == "past") and "DIK(" .. cls .. ")"
                                   or "ACAK(" .. cls .. ")",
    })
    -- Add the POSS morpheme(s), skipping the STEM entry from applyPossessive
    -- (its content is already represented by our STEM + Y-BUFFER + DIK/ACAK).
    for i, mp in ipairs(possMorphs) do
        if i > 1 then table.insert(morphemes, mp) end
    end
    table.insert(morphemes, accMorph)

    return accForm, morphemes
end

return M
