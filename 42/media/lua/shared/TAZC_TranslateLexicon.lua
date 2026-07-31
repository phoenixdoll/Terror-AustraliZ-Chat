-- ============================================================================
-- TAZC_TranslateLexicon -- runtime API + indices over the English/Turkish
-- lexicon data.
--
-- The lexicon DATA (entries table, irregular past forms) lives in
-- TAZC_TranslateLexiconData.lua, which is GENERATED from the source-of-truth
-- CSVs at data/lexicon/*.csv via devtools/generate_lexicon.py. This file
-- holds only logic: index building, lookup functions, diacritic-stripping,
-- and the public API surface.
--
-- To add or modify entries, edit the CSVs (spreadsheet-friendly), then run
-- the generator. The generated TAZC_TranslateLexiconData.lua is committed
-- alongside its sources but never edited by hand.
--
-- The id field is stable forever; never rename, only deprecate and supersede.
-- ============================================================================

local M = {}

-- VM-portable UTF-8 iteration; matches the rest of the translator pipeline.
local Str = require("TAZC_StringUtils")

-- Pull the generated data in. Two fields surface as public API: entries
-- (list of lexicon table-records) and IRREGULAR_PAST_FORMS (past-surface
-- -> present-lemma map). Everything else in this module is derived.
local Data = require("TAZC_TranslateLexiconData")

M.VERSION = "0.2"  -- 0.2 = post-CSV-migration architecture
M.entries = Data.entries
M.IRREGULAR_PAST_FORMS = Data.IRREGULAR_PAST_FORMS

-- 9.0+ Mosaic: noun semantic classes and verb sense disambiguation.
-- Both are sparse maps generated from data/lexicon/noun_classes.csv and
-- data/lexicon/sense_disambig.csv. The engine's word-sense pass reads
-- them to override default Turkish translations when a verb's object
-- is in a specific semantic class.
M.NOUN_CLASSES = Data.NOUN_CLASSES or {}
M.SENSE_DISAMBIG = Data.SENSE_DISAMBIG or {}

-- Lookup a noun's semantic class by its lex id (e.g. "guitar.n" -> "music").
-- Returns nil if the noun has no registered class. Use after Lexicon.lookup
-- has resolved a surface to an entry; pass entry.id (not entry.en).
function M.getNounClass(noun_id)
    if not noun_id then return nil end
    return M.NOUN_CLASSES[noun_id]
end

-- Lookup sense-disambiguation rules for a verb by its English lemma
-- (e.g. "play"). Returns a list of {trigger_class, override_tr,
-- override_stem, override_voicing} rules, or nil if none registered.
function M.getSenseDisambig(verb_en)
    if not verb_en then return nil end
    return M.SENSE_DISAMBIG[verb_en]
end

-- ---------------------------------------------------------------------------
-- Diacritic-stripping table. Used by the lazy lookup path so users typing
-- "iciyorum" (no diacritics) find "içiyorum" in the lexicon. Keys are byte
-- sequences for Lua 5.4 storage; the underlying utf8chars iterator in
-- TAZC_StringUtils handles both byte and codepoint storage VMs.
-- ---------------------------------------------------------------------------

local TR_STRIP = {
    ["\195\167"] = "c",       -- ç -> c
    ["\197\159"] = "s",       -- ş -> s
    ["\196\159"] = "g",       -- ğ -> g
    ["\195\182"] = "o",       -- ö -> o
    ["\195\188"] = "u",       -- ü -> u
    ["\196\177"] = "i",       -- ı -> i  (dotless i collapses to dotted i)
}

local utf8chars = Str.utf8chars

local function stripDiacritics(s)
    if type(s) ~= "string" then return nil end
    local out = {}
    for ch in utf8chars(s) do
        table.insert(out, TR_STRIP[ch] or ch)
    end
    return table.concat(out)
end

M.stripDiacritics = stripDiacritics

-- ---------------------------------------------------------------------------
-- English alias index. Maps every recognised English surface (canonical
-- en + en_aliases) to its lexicon entry. First-write-wins: when an
-- English surface is shared (e.g. "do" as AUX_DO and a hypothetical
-- "do" as VERB), the entry appearing first in M.entries takes priority.
-- Function words (auxiliaries, determiners, pronouns) appear before
-- content words in the generated data so AUX correctly wins for
-- ambiguous "do"/"does"/etc.
-- ---------------------------------------------------------------------------

local index = {}
local indexAll = {}  -- 8.9.19+: surface -> list of ALL entries (multi-POS support)

-- ---------------------------------------------------------------------------
-- Turkish indices, POS-segmented.
--
-- The Turkish lookup space has a natural ambiguity: a verb's tr_stem can
-- coincide with another entry's tr surface form. Example: hungry.a has
-- tr="aç" (predicate adjective); open.v has tr_stem="aç" (stem of açmak).
-- Both are real Turkish words spelled identically. Correct interpretation
-- depends on context -- a bare "Aç" is the adjective; "Açıyor" is the
-- verb in -iyor present continuous.
--
-- Resolution: split the index. trIndex holds canonical surface forms
-- (entry.tr). trVerbStemIndex holds verb stems (entry.tr_stem, VERB POS
-- only). The reverse parser's callers already know which they want --
-- after stripping verb morphology they want a verb stem; after stripping
-- copular/plural/accusative they want a surface form. They call the
-- POS-appropriate lookup function and the ambiguity dissolves.
--
-- Backward compatibility: lookupTurkish and lookupTurkishLazy keep
-- returning a single entry. They check the surface index first, fall
-- back to the verb-stem index.
-- ---------------------------------------------------------------------------

local trIndex = {}
local trVerbStemIndex = {}

for _, entry in ipairs(M.entries) do
    if not index[entry.en] then index[entry.en] = entry end
    indexAll[entry.en] = indexAll[entry.en] or {}
    table.insert(indexAll[entry.en], entry)
    for _, alias in ipairs(entry.en_aliases or {}) do
        if not index[alias] then index[alias] = entry end
        indexAll[alias] = indexAll[alias] or {}
        table.insert(indexAll[alias], entry)
    end
    if entry.tr and entry.tr ~= "" then
        if not trIndex[entry.tr:lower()] then
            trIndex[entry.tr:lower()] = entry
        end
    end
    if entry.pos == "VERB" and entry.tr_stem and entry.tr_stem ~= "" then
        if not trVerbStemIndex[entry.tr_stem:lower()] then
            trVerbStemIndex[entry.tr_stem:lower()] = entry
        end
    end
end

-- ---------------------------------------------------------------------------
-- Diacritic-stripped versions of the Turkish indices. Built once at module
-- load. Used by the lazy lookup path.
-- ---------------------------------------------------------------------------

local trStrippedIndex = {}
local trVerbStemStrippedIndex = {}

for _, entry in ipairs(M.entries) do
    if entry.tr and entry.tr ~= "" then
        local key = stripDiacritics(entry.tr:lower())
        if not trStrippedIndex[key] then
            trStrippedIndex[key] = entry
        end
    end
    if entry.pos == "VERB" and entry.tr_stem and entry.tr_stem ~= "" then
        local key = stripDiacritics(entry.tr_stem:lower())
        if not trVerbStemStrippedIndex[key] then
            trVerbStemStrippedIndex[key] = entry
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.isIrregularPast(word)
    if type(word) ~= "string" then return nil end
    return M.IRREGULAR_PAST_FORMS[word:lower()]
end

function M.lookup(word)
    if type(word) ~= "string" then return nil end
    return index[word:lower()]
end

-- 8.9.19+: Multi-POS lookup. Returns the full list of lexicon entries that
-- match this surface form (canonical en + aliases). Used by the analyzer's
-- context-aware POS picker for ambiguous words: "there" (EXIS/ADV), "open"
-- (ADJ/VERB), "hate" (NOUN/VERB), etc.
--
-- Returns an empty list (NOT nil) when no entries match, so callers can
-- safely iterate without nil-checking. Returns a single-element list when
-- only one POS exists (most words).
function M.lookupAll(word)
    if type(word) ~= "string" then return {} end
    return indexAll[word:lower()] or {}
end

-- Turkish lookup, surface-first.
-- Backward-compatible: callers that don't know the surface/stem distinction
-- (e.g., direction-detection heuristics in TAZC_Translate) get a useful answer.
-- Reverse-parser callers that know they're after a verb stem should use
-- lookupTurkishVerbStem instead.
function M.lookupTurkish(word)
    if type(word) ~= "string" then return nil end
    local lower = word:lower()
    return trIndex[lower] or trVerbStemIndex[lower]
end

-- Turkish lookup, verb-stem only. Returns the VERB entry whose tr_stem
-- matches, or nil. Used by reverse-parser code paths after stripping verb
-- morphology (-iyor, accusative on object positions, etc.).
function M.lookupTurkishVerbStem(word)
    if type(word) ~= "string" then return nil end
    return trVerbStemIndex[word:lower()]
end

-- Lazy Turkish lookup. Tries the literal form first, then strips diacritics
-- and retries. Returns (entry, was_lazy_match). Callers can use the flag to
-- tag the analysis as lower confidence in trace output.
function M.lookupTurkishLazy(word)
    if type(word) ~= "string" then return nil, false end
    local lower = word:lower()
    local hit = trIndex[lower] or trVerbStemIndex[lower]
    if hit then return hit, false end
    local stripped = stripDiacritics(lower)
    hit = trStrippedIndex[stripped] or trVerbStemStrippedIndex[stripped]
    if hit then return hit, true end
    return nil, false
end

-- Lazy verb-stem lookup. Same as lookupTurkishVerbStem but with the
-- diacritic-strip fallback.
function M.lookupTurkishVerbStemLazy(word)
    if type(word) ~= "string" then return nil, false end
    local lower = word:lower()
    local hit = trVerbStemIndex[lower]
    if hit then return hit, false end
    local stripped = stripDiacritics(lower)
    hit = trVerbStemStrippedIndex[stripped]
    if hit then return hit, true end
    return nil, false
end

function M.count()
    return #M.entries
end

return M
