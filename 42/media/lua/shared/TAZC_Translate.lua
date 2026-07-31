-- ============================================================================
-- TAZC_Translate -- English to Turkish translation engine (v1 proof of concept)
--
-- This is the minimal subset of TRANSLATOR_SPEC.md sufficient to translate
-- corpus.011-019 (simple SVO sentences in present progressive across all
-- person/number variations, with definite and indefinite objects). The
-- spec's six layers are present but each is implemented at PoC depth:
--
--   1. tokenize: whitespace + punctuation split
--   2. analyze:  match each token against the lexicon, infer roles
--   3. transfer: resolve to Turkish lemmas, drop subject pronoun
--   4. generate: apply morphology (verb conjugation, case marking)
--   5. surface:  reorder SOV, capitalize, restore terminator
--   6. output:   return translation plus metadata
--
-- This engine deliberately does NOT handle: phrasebook, past tense, negation,
-- wh-questions, copular sentences, possessives. Adding any of those is a
-- future iteration. The PoC's job is to prove the architecture works on a
-- non-trivial slice of the corpus.
--
-- Public API:
--   TAZC_Translate.translate(text) -> {
--       ok      = true|false,
--       output  = "<Turkish text>",   -- nil on failure
--       trace   = { ... },             -- per-stage diagnostic
--       errors  = { ... },             -- unhandled tokens, missing lexicon, etc.
--   }
-- ============================================================================

local Lexicon       = require("TAZC_TranslateLexicon")
local Morphology    = require("TAZC_TranslateMorphology")
local Phrasebook    = require("TAZC_TranslatePhrasebook")
local ReverseParser = require("TAZC_TranslateReverseParser")
local Str           = require("TAZC_StringUtils")

local M = {}

M.VERSION = "0.2"

-- ---------------------------------------------------------------------------
-- 0. Normalize (preprocess)
--
-- Input cleanup before tokenization. The job of normalize is to fold away
-- surface variations that the analyzer shouldn't care about:
--   - Smart/curly quotes folded to straight ASCII apostrophe
--   - Common English contractions expanded ("I'm" -> "I am")
--   - Leading and trailing whitespace stripped
--   - Internal whitespace collapsed
--
-- Contraction expansion happens at the preprocess layer so the analyzer
-- sees uniform multi-word forms. This means the lexicon doesn't need
-- separate entries for every contracted form, and the negation pipeline
-- gets a single canonical shape ("do not VERB") regardless of whether the
-- input had "don't", "doesn't", or "do not" explicitly.
-- ---------------------------------------------------------------------------

-- 9.0+ Mosaic: slang passthrough table. A small hand-curated set of chat
-- shorthand that gets emitted in its original English form (covered=true)
-- rather than translated. Three reasons to put a token here:
--   1. Translation would be more confusing than the original ("lol" has
--      no good single-word Turkish; "smh" doesn't translate).
--   2. The form is so universally recognized that the cognitive load of
--      a translation outweighs any benefit.
--   3. Heavy slang/dialect that would require its own lex entry but isn't
--      worth the lexicographic effort.
-- This list is the engine's spec for "what is slang we let through". Add
-- entries here when corpus analysis shows a high-frequency leak that
-- belongs in this bucket. Don't add entries for words that DO have a
-- good Turkish translation -- those belong in the lexicon proper.
local SLANG_PASSTHROUGH = {
    -- General internet/chat shorthand
    ["lol"]    = true, ["lmao"]   = true, ["lmfao"]  = true, ["rofl"]   = true,
    ["smh"]    = true, ["omw"]    = true, ["brb"]    = true, ["gtg"]    = true,
    ["idk"]    = true, ["idc"]    = true, ["idgaf"]  = true,
    ["imo"]    = true, ["imho"]   = true, ["tbh"]    = true, ["ngl"]    = true,
    ["lowkey"] = true, ["highkey"]= true,
    ["prolly"] = true, ["prob"]   = true, ["probs"]  = true,
    ["nvm"]    = true, ["omg"]    = true, ["wtf"]    = true, ["wth"]    = true,
    ["ig"]     = true, ["ik"]     = true,
    ["af"]     = true, ["fr"]     = true, ["frfr"]   = true,
    ["irl"]    = true, ["btw"]    = true, ["fyi"]    = true,
    ["wyd"]    = true, ["wbu"]    = true, ["hbu"]    = true, ["hru"]    = true,
    ["np"]     = true, ["thx"]    = true, ["ty"]     = true, ["tysm"]   = true,
    ["ofc"]    = true, ["ttyl"]   = true, ["smth"]   = true,
    ["sus"]    = true, ["bruh"]   = true, ["bro"]    = true, ["sis"]    = true,
    ["bae"]    = true, ["fam"]    = true,
    -- Exclamations / interjections often used in chat
    ["ayy"]    = true, ["yo"]     = true, ["yoo"]    = true, ["yooo"]   = true,
    ["aight"]  = true, ["alr"]    = true, ["aite"]   = true,
    ["meh"]    = true, ["nah"]    = true, ["nope"]   = true, ["yep"]    = true,
    ["pog"]    = true, ["poggers"]= true, ["sheesh"] = true,
    ["cap"]    = true, ["nocap"]  = true,
    -- Game/community-specific (Project Zomboid / Mongoose)
    ["pvp"]    = true, ["pve"]    = true, ["ooc"]    = true, ["ic"]     = true,
    ["mongoose"]=true, ["pz"]     = true, ["b42"]    = true, ["b41"]    = true,
    -- Channel/slash shorthand that leaks past tokenize
    ["rp"]     = true, ["op"]     = true,
}

local CONTRACTIONS = {
    -- "to be" + "not"
    ["isn't"]    = "is not",
    ["aren't"]   = "are not",
    ["wasn't"]   = "was not",
    ["weren't"]  = "were not",
    -- "to do" + "not"
    ["don't"]    = "do not",
    ["doesn't"]  = "does not",
    ["didn't"]   = "did not",
    -- Modals + "not"
    ["won't"]    = "will not",
    ["can't"]    = "cannot",
    ["couldn't"] = "could not",
    ["wouldn't"] = "would not",
    ["shouldn't"]= "should not",
    ["mustn't"]  = "must not",
    -- 9.0+ Mosaic: have-family apostrophe forms were missing (only the
    -- apostrophe-less variants were here). Common in chat: "haven't
    -- seen", "hasn't come", "hadn't tried". Adding so the engine's
    -- present-perfect collapse path sees "have not" / "has not" / "had
    -- not" instead of leaking the contraction unchanged.
    ["haven't"]  = "have not",
    ["hasn't"]   = "has not",
    ["hadn't"]   = "had not",
    -- 9.0+ Mosaic: 'll family (will-contractions). The pronoun forms
    -- (i'll/you'll/he'll/she'll/we'll/they'll) are already covered above;
    -- here we add the demonstrative/locative variants.
    ["it'll"]    = "it will",
    ["that'll"]  = "that will",
    ["this'll"]  = "this will",
    ["there'll"] = "there will",
    ["who'll"]   = "who will",
    ["what'll"]  = "what will",
    -- Hortative
    ["let's"]    = "let us",
    -- Pronoun + "to be"
    ["i'm"]      = "i am",
    ["you're"]   = "you are",
    ["he's"]     = "he is",
    ["she's"]    = "she is",
    ["it's"]     = "it is",
    ["we're"]    = "we are",
    ["they're"]  = "they are",
    -- 9.0+ Mosaic: demonstrative/WH/locative contractions. Phrasebook
    -- normalise() had these; engine's local copy didn't, so
    -- "there's a knife" leaked "there's". Routing through here lets
    -- the engine pipeline see "there is a knife" and trigger the
    -- existential-bare construction.
    ["there's"]  = "there is",
    ["here's"]   = "here is",
    ["that's"]   = "that is",
    ["what's"]   = "what is",
    ["where's"]  = "where is",
    ["how's"]    = "how is",
    ["who's"]    = "who is",
    -- Pronoun + "have"
    ["i've"]     = "i have",
    ["you've"]   = "you have",
    ["we've"]    = "we have",
    ["they've"]  = "they have",
    -- Pronoun + "would"
    ["i'd"]      = "i would",
    ["you'd"]    = "you would",
    ["he'd"]     = "he would",
    ["she'd"]    = "she would",
    ["we'd"]     = "we would",
    ["they'd"]   = "they would",
    -- Pronoun + "will"
    ["i'll"]     = "i will",
    ["you'll"]   = "you will",
    ["he'll"]    = "he will",
    ["she'll"]   = "she will",
    ["we'll"]    = "we will",
    ["they'll"]  = "they will",
    -- Lazy / apostrophe-less variants. These are the forms native typers
    -- produce when texting fast: "im", "dont", "youre", etc. Listed in a
    -- separate block so the policy is explicit -- we accept these even
    -- though they're grammatically incorrect in formal writing, because
    -- roleplayers will type them.
    --
    -- The following lazy forms are DELIBERATELY EXCLUDED because they
    -- have ambiguous meanings without the apostrophe and the contraction
    -- interpretation is not safely the more common one:
    --   "were"  -- past tense of "are" vs "we are"  (matters for Turkish past)
    --   "well"  -- adverb vs "we will"
    --   "ill"   -- sick adjective vs "I will"        (also in lexicon as alias)
    --   "id"    -- identification vs "I would"
    --   "shed"  -- noun vs "she would"
    --   "hed"   -- not in lexicon, low ambiguity, but listed for symmetry
    -- Users who want these as contractions should type the apostrophe.
    --
    -- 9.0+ Mosaic: "its" -> "it is". Corpus shows ~95% of "its" usage
    -- in chat is "it is" (copula), not POSS. The POSS lex entry is
    -- kept for the rare case but bypassed by this normalize step. The
    -- handful of POSS uses ("its bag") tolerate the rewrite poorly
    -- but the chat-frequency win is overwhelming.
    ["its"]      = "it is",
    ["im"]       = "i am",
    ["youre"]    = "you are",
    ["hes"]      = "he is",
    ["shes"]     = "she is",
    ["theyre"]   = "they are",
    ["isnt"]     = "is not",
    ["arent"]    = "are not",
    ["wasnt"]    = "was not",
    ["werent"]   = "were not",
    ["wont"]     = "will not",
    ["cant"]     = "cannot",
    ["couldnt"]  = "could not",
    ["wouldnt"]  = "would not",
    ["shouldnt"] = "should not",
    ["mustnt"]   = "must not",
    ["ive"]      = "i have",
    ["youve"]    = "you have",
    ["weve"]     = "we have",
    ["theyve"]   = "they have",
    ["youll"]    = "you will",
    ["theyll"]   = "they will",
    ["youd"]     = "you would",
    ["theyd"]    = "they would",
    -- 9.1+ additions: don't-family (unambiguous), have-not-family
    -- (unambiguous), and ill->"i will". Excluded "were" and "well" still
    -- since their non-contraction senses appear naturally in chat
    -- ("we were tired", "well, ok"). Excluded "id"/"shed" still since
    -- the contraction reading is less common in chat than for the
    -- don't-family.
    ["dont"]     = "do not",
    ["didnt"]    = "did not",
    ["doesnt"]   = "does not",
    ["havent"]   = "have not",
    ["hasnt"]    = "has not",
    ["hadnt"]    = "had not",
    -- 9.0+ Mosaic: chat-speak contractions that compress an aux+verb or
    -- modal+verb into one written word. Expanded here so downstream
    -- multi-word normalize ("going to" -> "will", "want to" -> "will")
    -- catches them. Pure substitution; the engine doesn't see the
    -- short form.
    ["gonna"]    = "going to",
    ["wanna"]    = "want to",
    ["gotta"]    = "got to",
    ["imma"]     = "i am going to",
    ["finna"]    = "going to",   -- "I'm finna X" = future / about to X
    ["tryna"]    = "trying to",
    ["hafta"]    = "have to",
    ["hasta"]    = "has to",
    ["oughta"]   = "ought to",
    ["lemme"]    = "let me",
    ["gimme"]    = "give me",
    ["dunno"]    = "do not know",
    ["dontcha"]  = "do not you",
    ["wouldja"]  = "would you",
    ["couldja"]  = "could you",
    ["shouldja"] = "should you",
    -- More apostropheless variants surfaced by corpus analysis
    ["thats"]    = "that is",
    ["lets"]     = "let us",       -- "lets go" -> hortative path
    ["theres"]   = "there is",
    ["wheres"]   = "where is",
    ["whats"]    = "what is",
    ["hows"]     = "how is",
    ["whys"]     = "why is",
    ["whos"]     = "who is",
    ["hadnt"]    = "had not",
    ["hasnt"]    = "has not",
    ["havent"]   = "have not",
    -- 9.0+ Mosaic: do-family apostrophe-less. Common in chat ("dont
    -- shoot", "didnt see"). The do-family is critical because it
    -- carries past-tense marking — without recognition, "didnt see"
    -- would parse as "see" present rather than "did not see".
    ["dont"]     = "do not",
    ["doesnt"]   = "does not",
    ["didnt"]    = "did not",
    -- 9.0+ Mosaic: chat slang variants.
    -- "em" -> "them" (colloquial "tell em", "shoot em")
    -- "gunna" -> "going to" (variant of "gonna")
    -- "tryin" -> "trying", "doin" -> "doing", etc. (g-dropping)
    ["em"]       = "them",
    ["gunna"]    = "going to",
    ["tryin"]    = "trying",
    ["doin"]     = "doing",
    ["goin"]     = "going",
    ["comin"]    = "coming",
    ["lookin"]   = "looking",
    ["gettin"]   = "getting",
    ["makin"]    = "making",
    ["talkin"]   = "talking",
    ["bein"]     = "being",
    ["sayin"]    = "saying",
    ["workin"]   = "working",
    -- More g-dropping
    ["mornin"]   = "morning",
    ["evenin"]   = "evening",
    ["nothin"]   = "nothing",
    ["somethin"] = "something",
    ["everythin"]= "everything",
    ["anythin"]  = "anything",
    ["walkin"]   = "walking",
    ["runnin"]   = "running",
    ["movin"]    = "moving",
    ["fightin"]  = "fighting",
    -- More g-droppings (chat-frequent verbs of motion/state)
    ["carryin"]  = "carrying",
    ["holdin"]   = "holding",
    ["bringin"]  = "bringing",
    ["leavin"]   = "leaving",
    ["sittin"]   = "sitting",
    ["standin"]  = "standing",
    ["readin"]   = "reading",
    ["sleepin"]  = "sleeping",
    ["eatin"]    = "eating",
    ["drinkin"]  = "drinking",
    ["wakin"]    = "waking",
    ["headin"]   = "heading",
    ["pushin"]   = "pushing",
    ["pullin"]   = "pulling",
    -- Other slang
    ["lil"]      = "little",
    ["yall"]     = "you all",
    ["y'all"]    = "you all",
    ["aint"]     = "is not",     -- approximation: ain't has multiple meanings
    ["ain't"]    = "is not",     -- with apostrophe
    -- Common informal greetings/affirmatives that often run together
    ["howdy"]    = "hello",       -- "howdy" not in lex as greeting; map to "hello"
    -- 9.0+ Mosaic: common chat typos. CONTRACTIONS is the right hook
    -- because it runs before tokenization/lexicon lookup, so the
    -- corrected form propagates through everything downstream.
    ["usefull"]  = "useful",
    ["definately"] = "definitely",
    ["seperate"]  = "separate",
    ["recieve"]   = "receive",
    ["alot"]      = "a lot",
    ["thier"]     = "their",
    ["wich"]      = "which",
    ["liek"]      = "like",      -- common chat misspelling
    ["teh"]       = "the",
    ["nvm"]       = "never mind",
    ["idk"]       = "i do not know",
    ["thx"]       = "thanks",
    ["ur"]        = "your",      -- ambiguous (you/your) but 'your' is more common
    -- More chat typos
    ["somthing"]  = "something",
    ["sumthing"]  = "something",
    ["sumtin"]    = "something",
    ["nuthin"]    = "nothing",
    ["hopfully"]  = "hopefully",
    ["litereally"]= "literally",
    ["unneccisary"] = "unnecessary",
    ["otiher"]    = "other",
    ["completly"] = "completely",
    ["burry"]     = "bury",
    ["wory"]      = "worry",
    ["yur"]       = "your",
    ["preist"]    = "priest",
    ["sheeit"]    = "shit",
    ["shittttt"]  = "shit",
    ["shitt"]     = "shit",
    ["recieved"]  = "received",
    ["beleive"]   = "believe",
    ["beleived"]  = "believed",
    ["wierd"]     = "weird",
    -- More apostrophe-less variants
    ["itll"]      = "it will",
    ["thatll"]    = "that will",
    ["theyll"]    = "they will",
    -- NB: "hell"/"shell" deliberately excluded — too ambiguous with noun usage.
    -- More chat shortform
    ["cmon"]      = "come on",
    ["c'mon"]     = "come on",
    ["gnight"]    = "good night",
    ["g'night"]   = "good night",
    ["whaddya"]   = "what do you",
    ["dunno"]     = "do not know",
    ["mauldraugh"] = "muldraugh",
    ["huntin"]    = "hunting",
    ["hoppin"]    = "hopping",
    -- Common chat-form contractions without apostrophe
    ["heres"]     = "here is",
    ["wheres"]    = "where is",
    ["hows"]      = "how is",
    ["whos"]      = "who is",
    ["whens"]     = "when is",
    ["whys"]      = "why is",
    ["cannot"]    = "can not",   -- engine treats 'can' MODAL + 'not' NEG separately
    -- More typos
    ["hmmh"]      = "hmm",
    ["t-the"]     = "the",      -- stutter
    ["youh"]      = "you",
    ["toh"]       = "to",
    ["dihsrespect"]= "disrespect",
    ["ohkay"]     = "okay",
    -- Common chat typos
    ["incase"]    = "in case",
    ["stiches"]   = "stitches",
    ["ammount"]   = "amount",
    ["sterlized"] = "sterilized",
    ["alright"]   = "all right",   -- standardize
    -- More chat-typo shortforms
    ["fuckin"]    = "fucking",
    ["t-that"]    = "that",      -- stutter
    ["rn"]        = "right now",
    ["wernt"]     = "weren't",
    ["lemme"]     = "let me",
    -- Common phrasal/colloquial contractions
    ["outta"]     = "out of",
    ["sorta"]     = "sort of",
    ["coulda"]    = "could have",
    ["shoulda"]   = "should have",
    ["woulda"]    = "would have",
    ["mighta"]    = "might have",
    ["musta"]     = "must have",
    -- More common chat modal contractions
    ["needa"]     = "need to",
    -- Lowercase variants picked up by the lower() call below; the table
    -- only needs to list the canonical lowercase form.
}

-- 9.0+ Mosaic: multi-word control patterns. After contraction expansion
-- (which turns "gonna" -> "going to" etc.) we run this pass to replace
-- English control constructs with single Turkish-friendly modals on the
-- main verb. Each entry has:
--   match: the multi-word phrase to look for (lowercase)
--   replace: the single token to swap it for
--   guard: a function(nextWord) returning true if the substitution
--          should fire. Typically "is the next token a verb?" to avoid
--          rewriting motion phrases like "going to the store".
--
-- Rationale: Turkish doesn't use control verbs the way English does.
-- "I'm going to run" / "I want to run" / "I need to run" / "I have to
-- run" all express variations on future intent or modal obligation.
-- For chat translation, mapping them all to a Turkish modal on the
-- main verb produces clean, recognizable output even if it loses
-- subtle aspectual distinctions.
local CONTROL_PATTERNS = {
    -- 9.0+ Mosaic: AUX-aware variants of the auxiliary-VERB modals. Must
    -- come BEFORE the bare forms or the bare forms shadow them. English
    -- "I am going to X" / "I'm about to X" preserves the "am/is/are" AUX
    -- with the future-construction "going to" / "about to". The bare
    -- rewrites below produce malformed "I am will X" sequences that the
    -- engine can't recover from (AUX claims copular construction,
    -- stranded MODAL becomes UNKNOWN). Consume both tokens here.
    { match = "am going to",   replace = "will" },
    { match = "is going to",   replace = "will" },
    { match = "are going to",  replace = "will" },
    { match = "was going to",  replace = "would" },
    { match = "were going to", replace = "would" },
    { match = "am about to",   replace = "will" },
    { match = "is about to",   replace = "will" },
    { match = "are about to",  replace = "will" },
    { match = "was about to",  replace = "would" },
    { match = "were about to", replace = "would" },
    -- "going to X" -> future tense on X
    { match = "going to",  replace = "will",   guard = "verb_after" },
    -- "want/wants to X" -> future (approximation)
    { match = "want to",   replace = "will",   guard = "verb_after" },
    { match = "wants to",  replace = "will",   guard = "verb_after" },
    { match = "wanted to", replace = "would",  guard = "verb_after" },
    -- "need to X" -> should (necessity)
    { match = "need to",   replace = "should", guard = "verb_after" },
    { match = "needs to",  replace = "should", guard = "verb_after" },
    { match = "needed to", replace = "should", guard = "verb_after" },
    -- "have to X" -> should (obligation). The verb-after guard avoids
    -- rewriting "I have a thing to do" (possessive + infinitive).
    { match = "have to",   replace = "should", guard = "verb_after" },
    { match = "has to",    replace = "should", guard = "verb_after" },
    { match = "had to",    replace = "should", guard = "verb_after" },
    -- "got to X" -> should (informal obligation)
    { match = "got to",    replace = "should", guard = "verb_after" },
    -- "ought to X" -> should
    { match = "ought to",  replace = "should", guard = "verb_after" },
    -- "trying to X" / "tried to X" -> future / past (best chat approximation)
    { match = "trying to", replace = "will",   guard = "verb_after" },
    { match = "tried to",  replace = "would",  guard = "verb_after" },
    { match = "try to",    replace = "will",   guard = "verb_after" },
    -- "about to X" -> future
    { match = "about to",  replace = "will",   guard = "verb_after" },
    -- "used to X" -> habitual past (closest Turkish form is -irdi/-erdi)
    -- For chat we approximate as "would" which generates the conditional
    -- past form -- close enough.
    { match = "used to",   replace = "would",  guard = "verb_after" },
    -- 9.0+ Mosaic: pseudo-imperative "go VERB" -> bare VERB. English
    -- "go play with your toy" is structurally a sequence (go-AND-play)
    -- but functionally an imperative. Turkish handles this as a plain
    -- imperative on the inner verb ("Oyna" = "play"), with the
    -- movement aspect implicit. Drop "go" when followed by a verb so
    -- the engine treats the inner verb as imperative.
    { match = "go",        replace = "",       guard = "verb_after" },
    -- 9.0+ Mosaic: "I think X" / "i think X" -> drop "I think". As
    -- discourse marker for epistemic hedge, the remaining clause
    -- carries the content. Turkish has "bence" for this but we keep
    -- the rewrite English-only here; the slight loss of hedge meaning
    -- is acceptable for chat. If a future "bence" injection is
    -- wanted, route it via a phrasebook entry instead.
    --
    -- NOT dropped (tried in 9.0+ and reverted for false positives):
    --   "you know" -- breaks "do you know" yes/no questions, "you know what"
    --   "i mean"   -- breaks "i mean it" (emphatic) and "what do you mean"
    --   "i guess"  -- breaks "i guess so" phrasebook hit
    -- These need clause-start anchoring (not yet supported by the
    -- CONTROL_PATTERNS matcher), or smarter handling. Skipped for v1.
    { match = "i think",   replace = "" },
    -- 9.0+ Mosaic: "be able to X" -> "can X". The "be able to" idiom
    -- is functionally equivalent to "can". Rewrite consumes "be able
    -- to" and lets the existing modal+VERB machinery handle "can VERB".
    -- Variations cover the inflected forms: "am/are/is/was/were able to".
    --
    -- Also consume the INF "to" particle when "to be able to" appears
    -- as a verb complement ("seem to be able to", "want to be able to").
    -- "to be able to open" -> "can open" (drop the leading "to"). Without
    -- this, the rewrite leaves "to can open" which routes "can" through
    -- the PREP-before MODAL+NOUN disambig and emits "konserveye" (can-DAT).
    { match = "to be able to",   replace = "can" },
    { match = "am able to",   replace = "can" },
    { match = "are able to",  replace = "can" },
    { match = "is able to",   replace = "can" },
    { match = "was able to",  replace = "could" },
    { match = "were able to", replace = "could" },
    { match = "be able to",   replace = "can" },
    -- 9.0+ Mosaic: "at least" idiom -> single Turkish adverb "en azından".
    -- Most CONTROL_PATTERNS replace with another English word; here we
    -- inject Turkish directly because no English single-word equivalent
    -- captures "en azından". The engine sees "en azından" and treats it
    -- as an unknown (passthrough) — but it's already Turkish so it lands
    -- correctly in output.
    { match = "at least",  replace = "en az\196\177ndan" },
    -- 9.0+ Mosaic: "as well as X" -> "and X". Coordinator meaning
    -- "X and also Y". More specific than "as well" so must come
    -- first or it'd be shadowed.
    { match = "as well as", replace = "and" },
    -- "as well" -> "also". Discourse marker meaning "additionally/too".
    -- Turkish has "de/da" (enclitic) or "ayrıca" (initial); "also"
    -- routes through the engine cleanly.
    { match = "as well",   replace = "also" },
    -- 9.0+ Mosaic: "of course" idiom -> "tabii". Common discourse marker
    -- (affirmation/confirmation). Adding here so the whole 2-word
    -- sequence emits a single Turkish word.
    { match = "of course", replace = "tabii" },
    -- 9.0+ Mosaic: "you'd best X" / "you had best X" -> "you should X".
    -- Old-fashioned-but-common chat idiom. Strict translation would be
    -- conditional perfect; pragmatic chat reads as obligation. We need
    -- to match BOTH the pre-expansion ("you'd best") AND the post-
    -- expansion form ("you would best") because CONTRACTIONS expansion
    -- happens before CONTROL_PATTERNS. Same for had best / had better.
    { match = "you'd best",     replace = "you should" },
    { match = "you would best", replace = "you should" },
    { match = "you had best",   replace = "you should" },
    { match = "we'd best",      replace = "we should" },
    { match = "we would best",  replace = "we should" },
    { match = "i'd best",       replace = "i should" },
    { match = "i would best",   replace = "i should" },
    { match = "had better",     replace = "should" },
    -- 9.0+ Mosaic: partitive QUANT-of rewrites. English "a lot of X",
    -- "lots of X", "plenty of X", etc. use an attributive quantifier
    -- + "of" + NP (often with "the"). Turkish prefers a simple DET +
    -- NP construction ("çok X", "biraz X", "birkaç X") without "of"
    -- or article. We rewrite to drop the partitive scaffolding and
    -- substitute a DET the lex translates correctly. More-specific
    -- patterns (with "the") must come BEFORE the bare forms or the
    -- bare forms would shadow them.
    --
    -- Examples after rewrite:
    --   "I have a lot of food"        -> "I have many food"   -> "Çok yemeğim var"
    --   "give me a bit of bread"      -> "give me some bread" -> "Biraz ekmek ver"
    --   "couple of zombies"           -> "few zombies"        -> "Birkaç zombi"
    --   "many of the guards are dead" -> "many guards are dead"
    --
    -- "out of X" deliberately NOT rewritten — the cases split between
    -- status (out of ammo = no ammo) and movement (out of building),
    -- and the engine's existential-negative path doesn't compose well
    -- with the "no X" rewrite for the status sense. Handled later via
    -- a dedicated "X yok" pattern.
    { match = "a lot of the",  replace = "many" },
    { match = "a lot of",      replace = "many" },
    { match = "lots of the",   replace = "many" },
    { match = "lots of",       replace = "many" },
    { match = "lot of the",    replace = "many" },
    { match = "lot of",        replace = "many" },
    { match = "plenty of the", replace = "many" },
    { match = "plenty of",     replace = "many" },
    { match = "a bit of",      replace = "some" },
    { match = "bit of",        replace = "some" },
    { match = "bunch of the",  replace = "many" },
    { match = "bunch of",      replace = "many" },
    { match = "couple of the", replace = "few" },
    { match = "couple of",     replace = "few" },
    { match = "many of the",   replace = "many" },
    { match = "many of",       replace = "many" },
    { match = "much of the",   replace = "much" },
    { match = "much of",       replace = "much" },
    -- 9.0+ Mosaic: container-of rewrites. "a bottle of water" -> "bottle
    -- water" — Turkish doesn't use "of" between container and content
    -- ("şişe su" or "bir şişe su"). Drop "of" so the engine treats
    -- container and content as adjacent NPs.
    { match = "a bottle of", replace = "bottle" },
    { match = "a piece of",  replace = "piece" },
    { match = "a pack of",   replace = "pack" },
    { match = "a ton of",    replace = "ton" },
    { match = "a can of",    replace = "can" },
    { match = "a cup of",    replace = "cup" },
    { match = "a glass of",  replace = "glass" },
    { match = "a slice of",  replace = "slice" },
    { match = "a bag of",    replace = "bag" },
    { match = "a box of",    replace = "box" },
    -- 9.0+ Mosaic: "take care of X" idiom. Turkish equivalent is
    -- "X-ile ilgilenmek" (concern oneself with X). For chat we
    -- approximate as just "X-ile ilgilen" via dropping take and
    -- replacing care-of with bare verb. Simpler rewrite: just drop
    -- "of" since "take care" (the imperative) translates OK as-is.
    { match = "take care of", replace = "take care" },
    -- 9.0+: present-perfect collapse. "have/has/had + past participle" is
    -- the English perfect aspect. Turkish doesn't have a separate perfect;
    -- it expresses the same meaning with simple past. Drop the auxiliary
    -- and let the next verb (recognized via irregular-past or -ed) carry
    -- the past tense.
    --   "I have seen X"    -> "X gördüm"     (just past, no "have" word)
    --   "I have done it"   -> "Onu yaptım"
    --   "she has gone"     -> "gitti"
    --   "they had left"    -> "ayrıldılar"
    -- IMPORTANT: this fires AFTER the longer "have to / has to / had to"
    -- patterns because Lua iterates the table in order; we don't want
    -- "I have to go" to collapse "have" before the "have to" pattern gets
    -- a chance to match.
    { match = "have",      replace = "",       guard = "verb_after" },
    { match = "has",       replace = "",       guard = "verb_after" },
    { match = "had",       replace = "",       guard = "verb_after" },
}

local function normalize(text)
    -- Smart-quote folding: U+2018 U+2019 (left/right single quote),
    -- U+201C U+201D (left/right double), and U+2032 (prime) all become
    -- straight ASCII apostrophe. We replace UTF-8 byte sequences directly.
    text = text:gsub("\226\128\152", "'")
                :gsub("\226\128\153", "'")
                :gsub("\226\128\156", '"')
                :gsub("\226\128\157", '"')
                :gsub("\226\128\178", "'")

    -- 9.0+ Mosaic: semicolon-as-apostrophe normalize. Chat users type
    -- "i;ve" / "i;m" / "don;t" instead of "i've"/"i'm"/"don't" — the
    -- semicolon and apostrophe share the same keyboard region and on
    -- some layouts (esp. mobile) the typo is frequent. When a semicolon
    -- sits BETWEEN two letter-characters (no space), it's almost always
    -- meant as an apostrophe. We only rewrite in that intra-word position
    -- so legitimate semicolons (clause separators) aren't disturbed.
    text = text:gsub("(%a);(%a)", "%1'%2")

    -- 9.0+ Mosaic: chat-style "-in'" -> "-ing" canonicalization. Patterns
    -- like "goin'", "doin'", "huntin'", "kiddin'" — the apostrophe stands
    -- in for the dropped 'g'. Restore the 'g' before tokenization so
    -- regular lex lookup matches the canonical form. The pattern is
    -- letter + "in'" (case-insensitive via the gsub on lower text — but
    -- we want to preserve case, so apply the pattern directly).
    text = text:gsub("(%a)in'(%s)", "%1ing%2")
    text = text:gsub("(%a)in'$", "%1ing")
    text = text:gsub("(%a)In'(%s)", "%1Ing%2")  -- mixed-case variant
    text = text:gsub("(%a)In'$", "%1Ing")

    -- Collapse runs of whitespace and trim
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return text end

    -- Contraction expansion. We split into words (preserving terminator),
    -- check each lowercase form against the table, and substitute. The
    -- original case of the first letter is preserved so "I'm" doesn't
    -- become "i am" but "I am".
    local out = {}
    for word in text:gmatch("%S+") do
        -- 9.0+ Mosaic: peel off both leading and trailing punctuation so
        -- contractions in chat-formatted quoting still match.
        -- Examples: ''I'm gonna' — the leading '' and possibly trailing
        -- punctuation must not prevent "I'm" from matching CONTRACTIONS.
        -- We capture the prefix and terminator separately so they can be
        -- re-attached if no replacement matches.
        local prefix = word:match("^([%.%?!,;:'\"`%-_%(%)%[%]%{%}]+)") or ""
        local terminator = word:match("([%.%?!,;:'\"`%-_%(%)%[%]%{%}]+)$") or ""
        local coreStart = 1 + #prefix
        local coreEnd = #word - #terminator
        local core
        if coreStart > coreEnd then
            -- Word is ALL punctuation — no core to look up. Pass through.
            table.insert(out, word)
        else
            core = word:sub(coreStart, coreEnd)
            local lc = core:lower()
            local replacement = CONTRACTIONS[lc]
            if replacement then
                -- Preserve initial capitalization of the original core
                if core:sub(1, 1) == core:sub(1, 1):upper() and core:sub(1, 1) ~= core:sub(1, 1):lower() then
                    replacement = replacement:sub(1, 1):upper() .. replacement:sub(2)
                end
                table.insert(out, prefix .. replacement .. terminator)
            else
                table.insert(out, word)
            end
        end
    end
    local text2 = table.concat(out, " ")

    -- 9.0+ Mosaic: Saxon-genitive ('s) rewrite. "warden's office" ->
    -- "the office of warden". Reuses Pass 2.4's "Y of X" -> "X-GEN
    -- Y-POSS" machinery so the engine emits the proper Turkish genitive
    -- (X-GEN Y-3SG.POSS).
    --
    -- This runs AFTER the per-word CONTRACTIONS loop above, so pronoun
    -- contractions ("it's", "that's", "here's", "where's", "who's",
    -- "how's") have already been expanded to "it is", "that is", etc.
    -- Any remaining "X's Y" can therefore be confidently treated as
    -- possessive.
    --
    -- Token-aware rewrite: split into words, replace each "X's"
    -- followed by a word with the genitive structure.
    do
        local words = {}
        for w in text2:gmatch("%S+") do table.insert(words, w) end
        local rewritten = {}
        local i = 1
        while i <= #words do
            local w = words[i]
            local stem = w:match("^(%a+)'s$")
            -- Also handle "X's." or "X's," (with trailing punct)
            local stemP, punct = w:match("^(%a+)'s([%.,!%?;:]+)$")
            local nextWord = words[i + 1]
            if stem and nextWord and nextWord:match("^%a") then
                -- "warden's office" -> "the office of warden". Preserve case
                -- of the stem: if it starts uppercase (proper noun), keep it
                -- uppercase so the engine's proper-noun-GEN handler fires.
                table.insert(rewritten, "the")
                table.insert(rewritten, nextWord)
                table.insert(rewritten, "of")
                local stemFirst = stem:sub(1, 1)
                local stemIsUpper = stemFirst == stemFirst:upper()
                                    and stemFirst ~= stemFirst:lower()
                table.insert(rewritten, stemIsUpper and stem or stem:lower())
                i = i + 2
            elseif stemP and nextWord and nextWord:match("^%a") then
                -- "warden's. office" - keep the trailing punctuation on the noun
                table.insert(rewritten, "the")
                table.insert(rewritten, nextWord)
                table.insert(rewritten, "of")
                local stemFirst = stemP:sub(1, 1)
                local stemIsUpper = stemFirst == stemFirst:upper()
                                    and stemFirst ~= stemFirst:lower()
                table.insert(rewritten, (stemIsUpper and stemP or stemP:lower()) .. punct)
                i = i + 2
            else
                table.insert(rewritten, w)
                i = i + 1
            end
        end
        text2 = table.concat(rewritten, " ")
    end

    -- 8.16.x: apostrophe-less possessive ("Marys gun" / "Bobs keys").
    -- Chat-realistic typing often drops the apostrophe. Mirror the Saxon
    -- rewrite for "Xs Y" where X is an uppercase-initial unknown word
    -- (heuristic for proper noun) and Y is a known NOUN. Conservative:
    -- only fires when X-without-trailing-s isn't a known lex entry, so
    -- "Cars are loud" / "Apples are sour" stay correct.
    do
        local LexiconForCheck = require("TAZC_TranslateLexicon")
        local words = {}
        for w in text2:gmatch("%S+") do table.insert(words, w) end
        local rewritten = {}
        local i = 1
        while i <= #words do
            local w = words[i]
            -- Match "Xs" or "Xs<punct>" where X starts with uppercase
            local stem = w:match("^(%u%a+)s$")
            local stemP, punct = w:match("^(%u%a+)s([%.,!%?;:]+)$")
            local rawStem = stem or stemP
            local nextWord = words[i + 1]
            local rewrote = false
            if rawStem and nextWord and nextWord:match("^%a") and #rawStem >= 2 then
                local stemLower = rawStem:lower()
                local stemEntries = LexiconForCheck.lookupAll(stemLower) or {}
                local nextLower = nextWord:gsub("[%.,!%?;:]+$", ""):lower()
                local nextEntries = LexiconForCheck.lookupAll(nextLower) or {}
                local nextIsNoun = false
                for _, e in ipairs(nextEntries) do
                    if e.pos == "NOUN" then nextIsNoun = true; break end
                end
                -- Check: is rawStem+s a REGISTERED plural form in lex?
                -- If YES, it's a real plural ("Cars" / "Apples") — don't
                -- fire. If NO (or stem has no NOUN entry), treat as proper
                -- noun possessive ("Marys" / "Bobs" / "Toms").
                local isRegisteredPlural = false
                local fullPlural = stemLower .. "s"
                for _, e in ipairs(stemEntries) do
                    if e.pos == "NOUN" and e.en_plurals then
                        for _, p in ipairs(e.en_plurals) do
                            if p:lower() == fullPlural then
                                isRegisteredPlural = true
                                break
                            end
                        end
                    end
                    if isRegisteredPlural then break end
                end
                if not isRegisteredPlural and nextIsNoun then
                    -- "Bobs keys" -> "the keys of Bob"
                    table.insert(rewritten, "the")
                    if punct then
                        table.insert(rewritten, nextWord)
                        table.insert(rewritten, "of")
                        table.insert(rewritten, rawStem .. punct)
                    else
                        table.insert(rewritten, nextWord)
                        table.insert(rewritten, "of")
                        table.insert(rewritten, rawStem)
                    end
                    i = i + 2
                    rewrote = true
                end
            end
            if not rewrote then
                table.insert(rewritten, w)
                i = i + 1
            end
        end
        text2 = table.concat(rewritten, " ")
    end

    -- 8.16.x: ditransitive rewrite. English "give me the gun" has the
    -- recipient (me) BEFORE the theme (the gun). Turkish needs the
    -- recipient in DAT case: "Tabancayı bana ver" (gun-ACC me-DAT
    -- give-IMP). The engine's existing "verb X to Y" → "X-ACC Y-DAT
    -- verb" path works correctly, so we rewrite the recipient-first
    -- form to the explicit "to"-form: "give me X" → "give X to me".
    --
    -- Only fires for known ditransitive verbs (give/bring/show/tell/
    -- send/hand/pass/throw/sell/pay/offer) followed by a recipient
    -- pronoun (me/you/him/her/us/them) followed by more content (the
    -- theme NP). Single-arg cases like "tell me." (no NP) are excluded
    -- — they're handled by phrasebook.
    do
        local DITRANS_VERBS = {
            give = true, bring = true, show = true, tell = true,
            send = true, hand = true, pass = true, throw = true,
            sell = true, pay = true, offer = true, lend = true,
            ["gives"] = true, ["brings"] = true, ["shows"] = true,
            ["tells"] = true, ["sends"] = true, ["hands"] = true,
            ["throws"] = true, ["sells"] = true, ["pays"] = true,
            ["offers"] = true, ["lends"] = true,
            ["gave"] = true, ["brought"] = true, ["showed"] = true,
            ["told"] = true, ["sent"] = true, ["handed"] = true,
            ["passed"] = true, ["threw"] = true, ["sold"] = true,
            ["paid"] = true, ["offered"] = true, ["lent"] = true,
        }
        local RECIPIENT_PRONS = {
            me = true, you = true, him = true, her = true,
            us = true, them = true,
        }
        local pre, verb, recipient, rest =
            text2:match("^(%s*)(%w+)%s+(%w+)%s+(.+)$")
        if pre and verb and recipient and rest then
            local verbL = verb:lower()
            local recipientL = recipient:lower()
            if DITRANS_VERBS[verbL] and RECIPIENT_PRONS[recipientL] then
                -- Strip trailing punctuation from `rest`
                local restBody, punct =
                    rest:match("^(.-)([%.%?!,;:]+)%s*$")
                if not restBody then
                    restBody = rest
                    punct = ""
                end
                -- Don't rewrite if `rest` is "to <something>" already
                -- ("give me to him" — would be a weird sentence, but
                -- our pattern shouldn't touch it). Also don't fire
                -- if `rest` starts with "and" (coordination).
                local restFirst = restBody:match("^(%w+)") or ""
                if restFirst:lower() ~= "to"
                   and restFirst:lower() ~= "and"
                   and restFirst ~= "" then
                    text2 = pre .. verb .. " " .. restBody
                            .. " to " .. recipientL .. punct
                end
            end
        end

        -- Subject-prefixed form: "She gave me X" / "I told him X"
        -- Same rewrite but with a subject pronoun at position 1.
        local SUBJECT_PRONS = {
            i = true, you = true, he = true, she = true, it = true,
            we = true, they = true,
        }
        local pre2, subj, verb2, recipient2, rest2 =
            text2:match("^(%s*)(%w+)%s+(%w+)%s+(%w+)%s+(.+)$")
        if pre2 and subj and verb2 and recipient2 and rest2 then
            local subjL = subj:lower()
            local verb2L = verb2:lower()
            local recipient2L = recipient2:lower()
            if SUBJECT_PRONS[subjL] and DITRANS_VERBS[verb2L]
               and RECIPIENT_PRONS[recipient2L] then
                local restBody, punct =
                    rest2:match("^(.-)([%.%?!,;:]+)%s*$")
                if not restBody then
                    restBody = rest2
                    punct = ""
                end
                local restFirst = restBody:match("^(%w+)") or ""
                if restFirst:lower() ~= "to"
                   and restFirst:lower() ~= "and"
                   and restFirst ~= "" then
                    text2 = pre2 .. subj .. " " .. verb2 .. " "
                            .. restBody .. " to " .. recipient2L .. punct
                end
            end
        end
    end

    -- 9.0+ Mosaic: sentence-initial "Have/Has/Had + PRON + ..." question
    -- rewrite. English perfect-aspect questions invert AUX with subject:
    -- "Have you eaten?" / "Has she gone?" — declarative form is "You have
    -- eaten" / "She has gone". The engine's perfect-aspect handling
    -- works on the declarative form, so we rewrite the inverted form to
    -- declarative. The question reading is preserved by trailing "?"
    -- (which Mosaic includes in the clause sep).
    --
    -- Only fires at clause start with specific PRON tokens. We don't
    -- touch other AUX+PRON patterns ("Did you", "Will we") which the
    -- engine handles differently (phrasebook for Did, modal for Will).
    do
        local pre, aux, pron, rest = text2:match(
            "^(%s*)([Hh]ave?[sd]?)%s+([Yy]ou)%s+(.*)$")
        if not pre then
            pre, aux, pron, rest = text2:match(
                "^(%s*)([Hh]ave?[sd]?)%s+([Ww]e)%s+(.*)$")
        end
        if not pre then
            pre, aux, pron, rest = text2:match(
                "^(%s*)([Hh]ave?[sd]?)%s+([Tt]hey)%s+(.*)$")
        end
        if not pre then
            pre, aux, pron, rest = text2:match(
                "^(%s*)([Hh]a[sd])%s+([Hh]e)%s+(.*)$")
        end
        if not pre then
            pre, aux, pron, rest = text2:match(
                "^(%s*)([Hh]a[sd])%s+([Ss]he)%s+(.*)$")
        end
        if not pre then
            pre, aux, pron, rest = text2:match(
                "^(%s*)([Hh]a[sd])%s+([Ii]t)%s+(.*)$")
        end
        -- Validate that aux is actually one of: have/has/had
        if aux then
            local auxLow = aux:lower()
            if auxLow == "have" or auxLow == "has" or auxLow == "had" then
                text2 = pre .. pron .. " " .. auxLow .. " " .. rest
            end
        end
    end

    return text2
end

-- ---------------------------------------------------------------------------
-- Multi-word control normalization (9.0+ Mosaic).
--
-- After single-word contraction expansion, scan for CONTROL_PATTERNS
-- (going to, want to, need to, have to, etc.) and replace each with the
-- single-modal equivalent when followed by a verb. Run AFTER the main
-- normalize() so contractions like "gonna" -> "going to" feed through.
--
-- The Lexicon module is imported here lazily — at the top of the file
-- it would create a circular dependency, since TAZC_TranslateLexicon
-- imports from TAZC_Translate for some shared utilities in early
-- iterations. Looking it up at call-time avoids that.
-- ---------------------------------------------------------------------------

local function isVerbLike(word)
    local lc = word:lower():gsub("[%.,!%?;:]+$", "")
    if lc == "" then return false end
    local Lexicon = require("TAZC_TranslateLexicon")
    -- Check all entries, not just the first-listed. Words like "do" are
    -- listed as AUX_DO first but can be the main verb in "to do" / "want
    -- to do" / "going to do" — we still want the control patterns to fire.
    local entries = Lexicon.lookupAll and Lexicon.lookupAll(lc) or nil
    if entries then
        for _, e in ipairs(entries) do
            if e.pos == "VERB" or e.pos == "AUX_DO" then return true end
        end
    else
        local entry = Lexicon.lookup(lc)
        if entry and (entry.pos == "VERB" or entry.pos == "AUX_DO") then
            return true
        end
    end
    -- Past forms via irregular_past
    if Lexicon.isIrregularPast and Lexicon.isIrregularPast(lc) then return true end
    -- -ing forms aren't directly in the lex but are clearly verbs.
    -- Same for -ed regular past forms. Use a conservative heuristic:
    -- if the stem-stripped form is a known verb, treat as verb.
    if lc:sub(-3) == "ing" then
        local stem = lc:sub(1, -4)
        local stemEntry = Lexicon.lookup(stem)
        if stemEntry and stemEntry.pos == "VERB" then return true end
        -- Handle doubled-consonant -ing (e.g. "running" -> "run")
        if #stem >= 2 and stem:sub(-1) == stem:sub(-2, -2) then
            local stem2 = stem:sub(1, -2)
            local stemEntry2 = Lexicon.lookup(stem2)
            if stemEntry2 and stemEntry2.pos == "VERB" then return true end
        end
    end
    if lc:sub(-2) == "ed" then
        local stem = lc:sub(1, -3)
        local stemEntry = Lexicon.lookup(stem)
        if stemEntry and stemEntry.pos == "VERB" then return true end
    end
    return false
end

local function normalizeControl(text)
    if not text or text == "" then return text end
    -- Tokenize provisionally (split on whitespace, keep terminators attached).
    local tokens = {}
    for word in text:gmatch("%S+") do
        table.insert(tokens, word)
    end

    -- Walk tokens with sliding-window multi-word match.
    local out = {}
    local i = 1
    while i <= #tokens do
        local matched = false
        for _, pat in ipairs(CONTROL_PATTERNS) do
            local words = {}
            for w in pat.match:gmatch("%S+") do table.insert(words, w) end
            local nw = #words
            -- Check tokens[i..i+nw-1] match all words of the pattern
            if i + nw - 1 <= #tokens then
                local ok = true
                for k = 1, nw do
                    local tok = tokens[i + k - 1]:lower():gsub("[%.,!%?;:]+$", "")
                    if tok ~= words[k] then ok = false; break end
                end
                if ok then
                    -- Guard: next token (tokens[i+nw]) must be verb-like.
                    -- 9.0+: also skip past adverbs and negation when looking
                    -- for the verb, so "have never seen X" and "have not
                    -- done Y" still trigger the present-perfect collapse.
                    local guardOk = true
                    if pat.guard == "verb_after" then
                        local probe = i + nw
                        -- Skip over ADV / "not" / "never" tokens
                        while probe <= #tokens do
                            local tlc = tokens[probe]:lower():gsub("[%.,!%?;:]+$", "")
                            if tlc == "not" or tlc == "never" or tlc == "already"
                                or tlc == "always" or tlc == "just" then
                                probe = probe + 1
                            else
                                break
                            end
                        end
                        local nextTok = tokens[probe]
                        guardOk = nextTok and isVerbLike(nextTok)
                    end
                    if guardOk then
                        -- Preserve initial capitalization of the first matched token
                        local replacement = pat.replace
                        local firstChar = tokens[i]:sub(1, 1)
                        if firstChar == firstChar:upper() and firstChar ~= firstChar:lower() then
                            replacement = replacement:sub(1, 1):upper() .. replacement:sub(2)
                        end
                        -- Preserve trailing terminator from the LAST matched token
                        local lastTok = tokens[i + nw - 1]
                        local terminator = lastTok:match("([%.%?!,;:]+)$") or ""
                        if replacement == "" then
                            -- Pattern collapses the matched tokens entirely
                            -- (e.g. perfect-aspect "have" drop). Still keep
                            -- the terminator if any, so sentence punctuation
                            -- doesn't disappear silently.
                            if terminator ~= "" then
                                table.insert(out, terminator)
                            end
                        else
                            table.insert(out, replacement .. terminator)
                        end
                        i = i + nw
                        matched = true
                        break
                    end
                end
            end
        end
        if not matched then
            table.insert(out, tokens[i])
            i = i + 1
        end
    end
    return table.concat(out, " ")
end

M.normalize = normalize

-- ---------------------------------------------------------------------------
-- Yes/no perfect-question rewrite (9.0+).
--
-- English yes/no questions with subject-aux inversion in the perfect aspect:
--   "Have you ever seen X?"
--   "Has she gone home?"
--   "Had they finished?"
-- ...are semantically equivalent for chat purposes to simple past
-- questions ("Did you ever see X?", "Did she go home?", "Did they
-- finish?"). Turkish doesn't distinguish perfect from simple past, so
-- the simpler form is the right target.
--
-- We rewrite at the full-string level (not token level) so the check
-- can include both the sentence start AND the sentence-final "?". The
-- function fires before normalizeControl so the "have/has/had + V"
-- perfect-aspect collapse doesn't preempt this rewrite.
-- ---------------------------------------------------------------------------

local function normalizeYesNoPerfect(text)
    if not text or text == "" then return text end
    -- Must end with "?" (allow trailing whitespace).
    if not text:match("%?%s*$") then return text end
    -- Match Have/Has/Had at start, followed by a subject pronoun.
    -- Case-insensitive on the aux; preserve case of the pronoun.
    local replaced = text:gsub(
        "^(Have)%s+(you)%s+", "Did %2 "
    ):gsub(
        "^(Has)%s+(he)%s+", "Did %2 "
    ):gsub(
        "^(Has)%s+(she)%s+", "Did %2 "
    ):gsub(
        "^(Has)%s+(it)%s+", "Did %2 "
    ):gsub(
        "^(Have)%s+(we)%s+", "Did %2 "
    ):gsub(
        "^(Have)%s+(they)%s+", "Did %2 "
    ):gsub(
        "^(Have)%s+(I)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(you)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(he)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(she)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(it)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(we)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(they)%s+", "Did %2 "
    ):gsub(
        "^(Had)%s+(I)%s+", "Did %2 "
    )
    -- Lowercase variant for fully-lowercase input
    replaced = replaced:gsub("^(have)%s+(you)%s+", "did %2 ")
                       :gsub("^(has)%s+(he)%s+", "did %2 ")
                       :gsub("^(has)%s+(she)%s+", "did %2 ")
                       :gsub("^(have)%s+(we)%s+", "did %2 ")
                       :gsub("^(have)%s+(they)%s+", "did %2 ")
                       :gsub("^(had)%s+(you)%s+", "did %2 ")
                       :gsub("^(had)%s+(he)%s+", "did %2 ")
                       :gsub("^(had)%s+(she)%s+", "did %2 ")
                       :gsub("^(had)%s+(we)%s+", "did %2 ")
                       :gsub("^(had)%s+(they)%s+", "did %2 ")
    return replaced
end

M.normalizeYesNoPerfect = normalizeYesNoPerfect
M.normalizeControl = normalizeControl

-- ---------------------------------------------------------------------------
-- 1. Tokenize
-- ---------------------------------------------------------------------------

local function tokenize(text)
    local tokens = {}
    local terminator = ""
    -- Strip trailing punctuation; remember it for surface restore.
    local trimmed = text:match("^%s*(.-)%s*$") or text
    local lastChar = trimmed:sub(-1)
    if lastChar == "." or lastChar == "?" or lastChar == "!" then
        terminator = lastChar
        trimmed = trimmed:sub(1, -2)
    end
    for word in trimmed:gmatch("%S+") do
        -- Strip leading/trailing punctuation off each token
        local clean = word:gsub("^[%p]+", ""):gsub("[%p]+$", "")
        if clean ~= "" then
            table.insert(tokens, clean)
        end
    end
    return tokens, terminator
end

M.tokenize = tokenize

-- ---------------------------------------------------------------------------
-- 2. Analyze
--
-- Walk tokens left-to-right. Each token gets a structured analysis:
--   { surface  = "drinking",
--     lemma    = "drink",
--     entry    = <lexicon entry>,
--     pos      = "VERB",
--     role     = "PREDICATE"|"SUBJECT"|"OBJECT"|"DET"|"AUX"|"UNKNOWN",
--     tense    = "PRESENT_PROGRESSIVE" (verbs only)
--   }
--
-- Role assignment for the v1 grammar:
--   PRON before AUX before VERB-ing : the PRON is SUBJECT
--   any noun after the verb         : OBJECT
--   determiner before noun          : associate with the noun (definiteness)
--
-- This is a one-pass approximate parser, not a real parser. It's enough for
-- the corpus subset; more complex sentences need a real parser.
-- ---------------------------------------------------------------------------

local function detectTense(surface, entry)
    local lower = surface:lower()
    -- Past tense markers come first because some irregular past forms
    -- (e.g., "bought") aren't -ing forms.
    if Lexicon.isIrregularPast(lower) then
        return "PAST"
    end
    if lower:sub(-2) == "ed" and entry.pos == "VERB"
        and lower ~= (entry.en or ""):lower() then
        -- Regular -ed past (e.g., "watched"). Guard against false
        -- positives on verbs whose BASE form happens to end in -ed:
        -- "need", "feed", "lead", "bleed", "speed", "succeed", "exceed".
        -- The lemma surface (entry.en) is the base form; if the
        -- inspected surface matches it, this isn't a past inflection.
        return "PAST"
    end
    if entry.pos == "VERB" and lower:sub(-3) == "ing" then
        return "PRESENT_PROGRESSIVE"
    end
    return nil
end

local function analyze(tokens, terminator)
    local errors = {}

    -- Pass 0.5 (8.9.19+): POS pre-resolution for ambiguous surfaces.
    --
    -- Many English surfaces have multiple POS readings in the lexicon:
    --   "open"  -> VERB or ADJ
    --   "there" -> EXIS or ADV
    --   "hate"  -> NOUN or VERB
    --   "right" -> ADJ or NOUN or ADV
    --   "back"  -> ADV or NOUN or VERB
    -- Without disambiguation, the lex's first-write-wins rule picks one
    -- arbitrarily and the other entries are dead. This pass uses simple
    -- syntactic context to pick the right entry per token.
    --
    -- The rules are intentionally narrow to keep regressions small:
    --   (R1) "there" at position 1 followed by AUX -> EXIS
    --   (R2) "there" elsewhere -> ADV
    --   (R3) Surface with both ADJ and VERB readings:
    --        - If a preceding AUX (is/are/etc) exists and no other VERB exists
    --          downstream -> ADJ (copular predicate / attributive)
    --        - Otherwise -> VERB
    --   (R4) Surface with both NOUN and VERB readings:
    --        - If a preceding AUX exists -> NOUN (copular pred)
    --        - If followed by a NOUN -> stay NOUN (attributive doesn't apply
    --          to NOUN+NOUN, but VERB+NOUN is "verb its object" so keep VERB
    --          if a subject precedes)
    --        - If a subject (PRON/NOUN with DET) precedes -> VERB
    --        - Otherwise -> first-listed (existing behavior)
    --   (R5) Surface with both ADJ and NOUN readings:
    --        - If a preceding AUX exists -> NOUN if no other content noun
    --          downstream, else ADJ
    --        - If followed by a NOUN -> ADJ (attributive)
    --        - Otherwise -> first-listed
    --
    -- All other ambiguities fall through to the default first-listed entry.
    -- This is a heuristic; the proper solution is full multi-candidate
    -- analysis with downstream disambiguation, deferred to a later refinement.
    --
    -- Pre-resolution also pre-computes a quick lookup of token POS-tags
    -- (without entering the per-item full structure) so we can examine
    -- surrounding context.
    local preResolved = {}  -- index -> chosen entry (or nil if no override)
    do
        -- First sweep: gather first-write-wins entries and AUX positions for context.
        local firstEntries = {}
        local hasAuxBefore = {}
        local sawAuxYet = false
        for i, surf in ipairs(tokens) do
            firstEntries[i] = Lexicon.lookup(surf)
            hasAuxBefore[i] = sawAuxYet
            if firstEntries[i] and firstEntries[i].pos == "AUX" then
                sawAuxYet = true
            end
        end
        -- Has any VERB downstream of position i?
        local function hasVerbAfter(i)
            for j = i + 1, #tokens do
                local e = firstEntries[j]
                if e and e.pos == "VERB" then return true end
            end
            return false
        end
        -- Any subject-shaped item before i?
        local function hasSubjectBefore(i)
            for j = 1, i - 1 do
                local e = firstEntries[j]
                if e and (e.pos == "PRON" or e.pos == "NOUN") then return true end
            end
            return false
        end
        -- Any AUX downstream of position i (indicating subject position)?
        local function hasAuxAfter(i)
            for j = i + 1, #tokens do
                local e = firstEntries[j]
                if e and e.pos == "AUX" then return true end
            end
            return false
        end
        -- Any NOUN downstream of position i?
        local function hasNounAfter(i)
            for j = i + 1, #tokens do
                local e = firstEntries[j]
                if e and e.pos == "NOUN" then return true end
            end
            return false
        end
        for i, surf in ipairs(tokens) do
            local candidates = Lexicon.lookupAll(surf)
            if #candidates <= 1 then
                -- Single entry or none: no disambiguation needed
            else
                -- Multi-candidate: apply rules
                local picks = {}
                for _, e in ipairs(candidates) do picks[e.pos] = e end
                local chosen

                -- R1/R2: "there" — EXIS only when at sentence position 1 with
                -- following AUX (declarative existential) OR when preceded by
                -- a sentence-initial AUX (inverted existential question).
                -- Otherwise it's a place adverb: "the cat is there", "I live
                -- there", "right there", etc.
                if surf:lower() == "there" and picks["EXIS"] and picks["ADV"] then
                    local next_e = firstEntries[i + 1]
                    local prev_e = firstEntries[i - 1]
                    local nextIsAux = (next_e and next_e.pos == "AUX")
                    local prevIsAux = (prev_e and prev_e.pos == "AUX")
                    local firstIsAux = (firstEntries[1] and firstEntries[1].pos == "AUX")
                    if (i == 1 and nextIsAux)
                        or (i >= 2 and prevIsAux and firstIsAux) then
                        chosen = picks["EXIS"]
                    else
                        chosen = picks["ADV"]
                    end
                -- R3: ADJ + VERB (e.g. "open", "clean", "empty", "dry", "hurt")
                elseif picks["ADJ"] and picks["VERB"] then
                    local next_e = firstEntries[i + 1]
                    local prev_e = firstEntries[i - 1]
                    if prev_e and prev_e.pos == "MODAL" then
                        -- 9.0+ Mosaic: MODAL-before always wants VERB.
                        -- "can open doors" — modal needs a verb to suffix
                        -- onto. Without this rule, "open doors" gets the
                        -- attributive ADJ+NOUN reading and the modal
                        -- leaks. Modal pairing is structural and
                        -- overrides next-token heuristics.
                        chosen = picks["VERB"]
                    elseif next_e and next_e.pos == "NOUN" then
                        -- Attributive: "the open door" -> ADJ
                        chosen = picks["ADJ"]
                    elseif hasAuxBefore[i] and not hasVerbAfter(i) then
                        -- Copular predicate: "the door is open" -> ADJ
                        chosen = picks["ADJ"]
                    else
                        chosen = picks["VERB"]
                    end
                -- R4: NOUN + VERB
                elseif picks["NOUN"] and picks["VERB"] then
                    local prev_e = firstEntries[i - 1]
                    -- 8.10.3+: if preceded by POSS or DET, we're inside an NP
                    -- and the ambiguous word is the head NOUN.
                    --   "your back" -> back = NOUN, not VERB
                    --   "the watch" -> watch = NOUN, not VERB
                    --   "my fear"   -> fear = NOUN, not VERB
                    local prevIsDetLike = prev_e and (prev_e.pos == "POSS"
                                                       or prev_e.pos == "DET")
                    -- 9.0+: frequency adverbs (ever/never/often/always/just/
                    -- sometimes) only modify verbs, never nouns. If the
                    -- ambiguous token is preceded by one, it's a verb.
                    -- Fixes "Have you ever thought ..." picking NOUN
                    -- because of an AUX in a later embedded clause.
                    local prevSurfL = (i >= 2 and tokens[i - 1])
                        and tokens[i - 1]:lower() or nil
                    local prevIsFreqAdv = prevSurfL and (
                        prevSurfL == "ever" or prevSurfL == "never"
                        or prevSurfL == "often" or prevSurfL == "always"
                        or prevSurfL == "sometimes" or prevSurfL == "just")
                    if prevIsDetLike then
                        chosen = picks["NOUN"]
                    elseif prevIsFreqAdv then
                        chosen = picks["VERB"]
                    elseif prev_e and prev_e.pos == "MODAL" then
                        -- 9.0+ Mosaic: MODAL-before -> prefer VERB. Modals
                        -- always attach to a following verb in English
                        -- ("can run", "should go", "would trade"). The
                        -- earlier disambig didn't recognize this and let
                        -- dual-POS NOUN+VERB words like "trade", "head",
                        -- "deal" stay NOUN, stranding the modal.
                        chosen = picks["VERB"]
                    elseif hasAuxBefore[i] then
                        -- After AUX -> copular predicate noun
                        chosen = picks["NOUN"]
                    elseif hasAuxAfter(i) then
                        -- AUX comes later -> this is subject position
                        chosen = picks["NOUN"]
                    elseif hasSubjectBefore(i) and not hasVerbAfter(i) then
                        chosen = picks["VERB"]
                    elseif i == 1 then
                        -- 8.16.x: sentence-initial NOUN+VERB. If next token
                        -- starts an NP (DET/POSS/ADJ/PRON-acc), this is an
                        -- imperative verb taking that NP as direct object:
                        --   "Lock the doors" / "Take her keys" /
                        --   "Open my window" / "Drop it"
                        local next_e = firstEntries[i + 1]
                        local nextStartsNp = next_e and (
                            next_e.pos == "DET" or next_e.pos == "POSS"
                            or next_e.pos == "ADJ"
                            or next_e.pos == "PRON")
                        if nextStartsNp then
                            chosen = picks["VERB"]
                        end
                    end
                    -- else: leave as first-listed
                -- R5: ADJ + NOUN
                elseif picks["ADJ"] and picks["NOUN"] then
                    local next_e = firstEntries[i + 1]
                    local prev_e = firstEntries[i - 1]
                    if next_e and next_e.pos == "NOUN" then
                        -- Attributive: "the red car" -> ADJ
                        chosen = picks["ADJ"]
                    elseif prev_e and prev_e.pos == "NEG" then
                        -- 9.0+ Mosaic: NEG-before ("not safe", "not happy")
                        -- signals copular-predicate ADJ. Without this rule
                        -- the ambiguous word stays NOUN and "Not safe here"
                        -- comes out "Kasa Not burada" (safe-as-noun).
                        chosen = picks["ADJ"]
                    elseif hasAuxBefore[i] and not hasNounAfter(i) then
                        -- 9.0+ Mosaic: predicate position after AUX with no
                        -- following NOUN — "X is sweet", "it is sudden" —
                        -- ADJ is the more common reading in chat. The
                        -- previous heuristic preferred NOUN which produced
                        -- e.g. "şekerleme" (candy) for "sweet" predicate.
                        -- For determiner-marked predicate nouns ("a/the
                        -- doctor"), R5b above already picks NOUN; here
                        -- we cover the bare case.
                        chosen = picks["ADJ"]
                    elseif hasAuxBefore[i] then
                        chosen = picks["ADJ"]
                    elseif hasAuxAfter(i) then
                        -- Subject position -> prefer NOUN
                        chosen = picks["NOUN"]
                    end
                -- R5b (9.0+): POSS + PRON. The word "her" is both the
                -- possessive determiner ("her book") and the 3sg object
                -- pronoun ("give it to her"). Pick PRON when:
                --   * preceded by a PREP AND not followed by a NOUN
                --     ("to her", "with her", "from her" — bare pronoun)
                --   * preceded by a VERB and not followed by a NOUN
                --     ("see her")
                -- Otherwise default to POSS (modifies a NOUN that follows:
                -- "to her car", "with her gun", "see her book").
                elseif picks["POSS"] and picks["PRON"] then
                    local prev_e = firstEntries[i - 1]
                    local next_e = firstEntries[i + 1]
                    local prevIsPrep = prev_e and prev_e.pos == "PREP"
                    local prevIsVerb = prev_e and prev_e.pos == "VERB"
                    local nextIsNoun = next_e and next_e.pos == "NOUN"
                    -- 8.16.x: if a NOUN follows, "her" is the possessive
                    -- determiner modifying that NOUN, regardless of what
                    -- precedes. "to her car" → POSS (her modifies car).
                    if nextIsNoun then
                        chosen = picks["POSS"]
                    elseif prevIsPrep then
                        chosen = picks["PRON"]
                    elseif prevIsVerb and not nextIsNoun then
                        chosen = picks["PRON"]
                    else
                        chosen = picks["POSS"]
                    end
                -- R5d (9.0+): NOUN + PRON. The word "mine" is both NOUN
                -- ("a coal mine") and PRON (possessive: "that's mine").
                -- Pick PRON in predicate position (after AUX with no
                -- NOUN-after) and after PREP. Default to NOUN otherwise.
                elseif picks["NOUN"] and picks["PRON"] then
                    local prev_e = firstEntries[i - 1]
                    local next_e = firstEntries[i + 1]
                    local prevIsAux = prev_e and prev_e.pos == "AUX"
                    local prevIsPrep = prev_e and prev_e.pos == "PREP"
                    local nextIsNoun = next_e and next_e.pos == "NOUN"
                    if prevIsPrep then
                        chosen = picks["PRON"]
                    elseif prevIsAux and not nextIsNoun then
                        chosen = picks["PRON"]
                    else
                        chosen = picks["NOUN"]
                    end
                -- R5g (9.0+): MODAL + NOUN. Words like "can" (modal vs.
                -- tin-can) and "will" (modal vs. testament). When the
                -- previous token is a determiner, possessive, adjective,
                -- or another NP-internal element, pick NOUN.
                -- "an empty can" -> NOUN. "we can run" -> MODAL.
                elseif picks["MODAL"] and picks["NOUN"] then
                    local prev_e = firstEntries[i - 1]
                    local prevIsNpInternal = prev_e and (
                        prev_e.pos == "DET" or prev_e.pos == "POSS"
                        or prev_e.pos == "ADJ" or prev_e.pos == "PREP")
                    if prevIsNpInternal then
                        chosen = picks["NOUN"]
                    else
                        chosen = picks["MODAL"]
                    end
                -- R5f (9.0+): ADJ + PREP. Words like "near" function
                -- as both — ADJ ("the near future") and PREP ("near the
                -- river"). When the next token begins an NP, pick PREP.
                elseif picks["ADJ"] and picks["PREP"] then
                    local next_e = firstEntries[i + 1]
                    local nextIsNpStart = next_e and (
                        next_e.pos == "DET" or next_e.pos == "POSS"
                        or next_e.pos == "NOUN" or next_e.pos == "PRON")
                    if nextIsNpStart then
                        chosen = picks["PREP"]
                    else
                        chosen = picks["ADJ"]
                    end
                -- R5e (9.0+): PREP + ADV. Words like "over", "inside",
                -- "outside", "around" function as both — PREP introducing a
                -- PP ("over the wall", "inside the cell") and ADV
                -- standalone ("look over there", "go inside"). Heuristic:
                -- if the next token starts an NP (DET/POSS/NOUN/PRON), pick
                -- PREP. Otherwise pick ADV.
                elseif picks["PREP"] and picks["ADV"] then
                    local next_e = firstEntries[i + 1]
                    local nextIsNpStart = next_e and (
                        next_e.pos == "DET" or next_e.pos == "POSS"
                        or next_e.pos == "NOUN" or next_e.pos == "PRON")
                    if nextIsNpStart then
                        chosen = picks["PREP"]
                    else
                        chosen = picks["ADV"]
                    end
                -- R5c (9.0+): NEG + DET. The word "no" is both a negation
                -- response marker ("no, that's wrong") and a negative
                -- quantifier ("no more food"). Pick DET when followed by
                -- another DET, ADJ, NOUN, or PRON (it's modifying an NP).
                -- BUT keep NEG in existential contexts: "there is no water"
                -- needs the NEG reading so the existential goes negative
                -- ("Su yok"), not "Hiç su var".
                elseif picks["NEG"] and picks["DET"] then
                    local next_e = firstEntries[i + 1]
                    -- Look back for EXIS or AUX (signals existential)
                    local hasExisBefore = false
                    for k = i - 1, math.max(1, i - 3), -1 do
                        local pe = firstEntries[k]
                        if pe and (pe.pos == "EXIS" or pe.pos == "AUX") then
                            hasExisBefore = true; break
                        end
                    end
                    if hasExisBefore then
                        chosen = picks["NEG"]
                    elseif next_e and (next_e.pos == "DET" or next_e.pos == "ADJ"
                                   or next_e.pos == "NOUN" or next_e.pos == "PRON") then
                        chosen = picks["DET"]
                    else
                        chosen = picks["NEG"]
                    end
                -- R6: AUX_DO + VERB (specifically "do" — both auxiliary
                -- and main verb). Pick VERB when:
                --   * preceded by a MODAL ("what can I do?" -> do is main verb)
                --   * preceded by another AUX_DO earlier in the sentence
                --     ("don't do that", "do you do that?" -> second do = verb)
                --   * at sentence end with no following content ("what to do?")
                --   * preceded by a subject + no other verb available
                -- Otherwise default to AUX_DO (the more common pattern in
                -- chat: "do you run?", "did you see?").
                elseif picks["AUX_DO"] and picks["VERB"] then
                    local prev_e = firstEntries[i - 1]
                    local next_e = firstEntries[i + 1]
                    local prevIsModal = (prev_e and prev_e.pos == "MODAL")
                    local atEnd = (next_e == nil)
                    local hasAuxDoBefore = false
                    for j = 1, i - 1 do
                        local e = firstEntries[j]
                        if e and e.pos == "AUX_DO" then
                            hasAuxDoBefore = true
                            break
                        end
                    end
                    if prevIsModal or hasAuxDoBefore or atEnd then
                        chosen = picks["VERB"]
                    elseif hasSubjectBefore(i) and not hasVerbAfter(i) then
                        chosen = picks["VERB"]
                    end
                    -- else: leave as first-listed (AUX_DO)
                -- 9.0+ R7: NOUN + ADV (e.g. "back" = body part vs direction).
                -- Heuristic: if preceded by POSS or DET, the ambiguous word
                -- is the head of an NP -> NOUN. Otherwise, if preceded by a
                -- VERB or sentence-final position, treat as direction ADV.
                --   "your back"  -> NOUN (sırt)
                --   "the back"   -> NOUN
                --   "I came back" -> ADV (geri)
                --   "go back"     -> ADV
                elseif picks["NOUN"] and picks["ADV"] then
                    local prev_e = firstEntries[i - 1]
                    local next_e = firstEntries[i + 1]
                    local prevIsDetLike = prev_e and
                        (prev_e.pos == "POSS" or prev_e.pos == "DET")
                    local prevIsVerb = prev_e and
                        (prev_e.pos == "VERB" or prev_e.pos == "AUX_DO")
                    -- 8.16.x: NEXT is a subject pronoun (I/you/we/they/he/she/
                    -- it). The current word is a sentence-initial temporal-
                    -- adverbial modifier, NOT the subject. Pick ADV so the
                    -- pronoun becomes subject. "Tomorrow we move" / "Yesterday
                    -- I went home" / "Today they came back".
                    local nextIsSubjPron = next_e and next_e.pos == "PRON"
                    if prevIsDetLike then
                        chosen = picks["NOUN"]
                    elseif prevIsVerb then
                        chosen = picks["ADV"]
                    elseif nextIsSubjPron and i == 1 then
                        -- Sentence-initial NOUN-or-ADV before a subject pronoun
                        chosen = picks["ADV"]
                    end
                    -- else: first-listed wins
                end

                preResolved[i] = chosen  -- may be nil (no override)
            end
        end
    end

    -- Pass 1: per-token classification. Every token gets its lexicon
    -- lookup, POS tag, and morphological details (person/number for PRON,
    -- tense for VERB, plurality for NOUN). Role is assigned in pass 2.
    local items = {}
    local sawAux = false
    local sawDoAux = false
    local sawDoAuxPast = false
    local sawNegation = false
    local sawExis = false   -- "there is/are" marker
    local sawFutureTemporal = false  -- "tomorrow", "tonight", "soon", "later"
    local sawPastTemporal = false    -- "yesterday", "ago" — supports past default
    local isExistentialHave = false  -- predicate is the "have" verb
    local verbIndex
    local auxIndex

    -- 8.16.x: temporal adverbs that disambiguate tense for bare verbs.
    -- "Tomorrow we move" → future; "Yesterday I saw" → past (already default).
    local FUTURE_TEMPORAL_LOWER = {
        ["tomorrow"] = true, ["tonight"] = true, ["soon"] = true,
        ["later"] = true,
    }
    local PAST_TEMPORAL_LOWER = {
        ["yesterday"] = true, ["ago"] = true,
    }

    for i, surf in ipairs(tokens) do
        local lower = surf:lower()
        -- 8.16.x: detect temporal adverbs at the surface level (before lex
        -- lookup, since these are simple token-level checks)
        if FUTURE_TEMPORAL_LOWER[lower] then
            sawFutureTemporal = true
        elseif PAST_TEMPORAL_LOWER[lower] then
            sawPastTemporal = true
        end
        -- 9.0+ Mosaic: slang passthrough. A short, hard-coded list of chat
        -- shorthand that emits as the original English surface instead of
        -- being translated. These are forms a Turkish reader would
        -- recognize from chat -- "lol", "omw", "smh" -- and that we
        -- deliberately don't try to render in Turkish (the translation
        -- would be more confusing than the original).
        if SLANG_PASSTHROUGH[lower] then
            items[i] = {
                surface = surf,
                entry   = nil,
                pos     = "SLANG",
                role    = "PASSTHROUGH",
                lemma   = lower,
            }
        else
        -- Use pre-resolved entry from Pass 0.5 if present, else default lookup.
        local entry = preResolved[i] or Lexicon.lookup(surf)
        if not entry then
            local lemmaIfPast = Lexicon.isIrregularPast(lower)
            if lemmaIfPast then entry = Lexicon.lookup(lemmaIfPast) end
        end

        local item = { surface = surf, entry = entry, role = "UNKNOWN" }
        if not entry then
            -- 8.16.x: proper-noun fallback in genitive context. Only fires
            -- when the previous token is "of" (the GEN marker from Saxon
            -- rewriter or natural "Y of X" form). Synthesizes a NOUN entry
            -- with surface as the Turkish stem, letting case marking apply.
            -- Excludes sentence-initial position (Take, Run, Stop, etc.)
            -- and non-of contexts (so MODAL+UNKNOWN OOV-verb cases like
            -- "Can we Retcon" still work — Retcon isn't after "of").
            local first = surf:sub(1, 1)
            local isUpper = first ~= "" and first == first:upper()
                            and first ~= first:lower()
            local prevSurf = tokens[i - 1]
            local prevIsOf = prevSurf and prevSurf:lower() == "of"
            if isUpper and prevIsOf and i ~= 1 then
                entry = {
                    en = surf:lower(),
                    pos = "NOUN",
                    tr = surf,
                    isProperNoun = true,
                }
                item.entry = entry
                item.isProperNoun = true
            else
                table.insert(errors, "no lexicon entry: '" .. surf .. "'")
            end
        end
        if entry then
            item.lemma = entry.en
            item.pos   = entry.pos
            if entry.pos == "AUX" then
                sawAux = true
                auxIndex = auxIndex or i
            elseif entry.pos == "AUX_DO" then
                sawDoAux = true
                -- The "did" auxiliary signals PAST tense for the main verb.
                -- Without this, "Did you run?" parses as present progressive
                -- ("Koşuyorsun mu?") instead of the correct past form
                -- ("Koştun mu?"). Distinguishing on surface form is a small
                -- POS-disambiguation: do/does signal present, did signals past.
                if surf:lower() == "did" then
                    sawDoAuxPast = true
                end
            elseif entry.pos == "AUX_DO_NEG" then
                sawDoAux = true
                sawNegation = true
                if surf:lower() == "didn't" then
                    sawDoAuxPast = true
                end
            elseif entry.pos == "NEG" then
                sawNegation = true
            elseif entry.pos == "EXIS" then
                sawExis = true
            elseif entry.pos == "PRON" then
                item.person = entry.person
                item.number = entry.number
            elseif entry.pos == "VERB" then
                item.tense = detectTense(surf, entry)
                -- 9.0+ Mosaic: existential-have anchors the verbIndex.
                -- When "have/has/had" is in subject position followed by
                -- a to-VERB infinitive ("I have a plan to break in"),
                -- the previous "last verb wins" heuristic would let the
                -- infinitive verb steal the PREDICATE role and demote
                -- "have" to UNKNOWN. Lock existential-have as the
                -- predicate anchor so the construction survives.
                local isExisHave = false
                if entry.subcat then
                    for _, s in ipairs(entry.subcat) do
                        if s == "existential_have" then
                            isExisHave = true; break
                        end
                    end
                end
                if isExisHave then
                    isExistentialHave = true
                    verbIndex = i
                    item.lockVerbIndex = true
                else
                    local locked = verbIndex and items[verbIndex] and items[verbIndex].lockVerbIndex
                    if not locked then
                        verbIndex = i
                    end
                end
            elseif entry.pos == "POSS" then
                item.possPerson = entry.person
                item.possNumber = entry.number
            elseif entry.pos == "MODAL" then
                -- Modals like "will", "can", "should" don't surface as Turkish
                -- words: they attach to the verb as a suffix (-ecek/-acak,
                -- -ebilir, -malı/-meli). We capture the modal type here and
                -- attach it to the following VERB in a dedicated pass below
                -- (Pass 1.6). The MODAL token itself is then consumed.
                --
                -- The modal type is the first entry in the lex entry's
                -- subcat list: e.g. subcat={"will"} for the "will" entry.
                -- A subcat ending in "_neg" (e.g. "can_neg" for "cannot")
                -- marks the modal as inherently negated -- no separate
                -- NEG token needed.
                if entry.subcat and entry.subcat[1] then
                    local raw = entry.subcat[1]
                    local negSuffix = raw:match("_neg$")
                    if negSuffix then
                        item.modalType    = raw:sub(1, -5)  -- strip "_neg"
                        item.modalNegated = true
                    else
                        item.modalType = raw
                    end
                end
            elseif entry.pos == "NOUN" then
                if entry.en_plurals then
                    for _, pl in ipairs(entry.en_plurals) do
                        if pl == lower then item.isPlural = true; break end
                    end
                end
            end
        end
        items[i] = item
        end -- else: not slang
    end

    -- Pass 1.4: Turkish numeral/quantifier de-pluralization.
    --
    -- Turkish grammar rule: countable nouns stay SINGULAR after numerals
    -- and most quantifiers. English says "three guns", Turkish says
    -- "üç tabanca" (NOT "üç tabancalar"). Same for "many zombies" ->
    -- "çok zombi", "few bullets" -> "az mermi", "five minutes" ->
    -- "beş dakika".
    --
    -- This is a robust productive rule with very few exceptions. The
    -- exceptions are mostly definite-plural references ("the three
    -- guns I found" -> "bulduğum üç silahlar" CAN appear in spoken
    -- Turkish but the bare-singular form is dominant and considered
    -- standard). For chat translation the singular-after-quantifier
    -- rule is the right default.
    --
    -- Triggers: DET items matching the closed set below, immediately
    -- followed by an isPlural NOUN. The NOUN's isPlural is cleared so
    -- downstream pluralization in Pass 8 stays singular.
    local DEPLURALIZE_AFTER = {
        -- Cardinal numerals (the most common chat range)
        ["one"] = true, ["two"] = true, ["three"] = true,
        ["four"] = true, ["five"] = true, ["six"] = true,
        ["seven"] = true, ["eight"] = true, ["nine"] = true,
        ["ten"] = true, ["eleven"] = true, ["twelve"] = true,
        ["thirteen"] = true, ["fourteen"] = true, ["fifteen"] = true,
        ["sixteen"] = true, ["seventeen"] = true, ["eighteen"] = true,
        ["nineteen"] = true, ["twenty"] = true, ["thirty"] = true,
        ["forty"] = true, ["fifty"] = true, ["sixty"] = true,
        ["seventy"] = true, ["eighty"] = true, ["ninety"] = true,
        ["hundred"] = true, ["thousand"] = true, ["million"] = true,
        -- Quantifiers (the chat-frequent set)
        ["many"] = true, ["few"] = true, ["several"] = true,
        ["some"] = true, ["lots"] = true, ["multiple"] = true,
        ["dozen"] = true,
    }
    for i = 1, #items - 1 do
        local cur, nxt = items[i], items[i + 1]
        if cur and nxt
           and cur.surface and DEPLURALIZE_AFTER[cur.surface:lower()]
           and nxt.pos == "NOUN"
           and nxt.isPlural
        then
            nxt.isPlural = false
            nxt.depluralized_by_numeral = true  -- diagnostic flag
        end
    end

    -- Pass 1.5: position-independent role assignment. Some POS categories
    -- (INTERJ, ADV) participate in neither argument structure nor the
    -- subject/predicate zoning, so their role is fixed by their POS alone.
    -- Doing this BEFORE the pivot-aware pass means one-word utterances
    -- ("Hello!", "Quickly!") get a role even though they have no verb or
    -- AUX to anchor a pivot.
    -- 8.16.x: temporal adverbs at sentence-initial position (yesterday/
    -- today/tomorrow/tonight/etc.) get a sentenceInitial flag so the
    -- surface stage can place them at sentence start, not before the
    -- predicate. Without this, "Yesterday I went home" produces "Ev dün
    -- gittim" (object first, then adverb) instead of "Dün eve gittim"
    -- (adverb first, then object).
    local SENTENCE_INITIAL_TEMPORALS = {
        ["yesterday"] = true, ["today"] = true, ["tomorrow"] = true,
        ["tonight"] = true, ["last"] = true,  -- "last night" via lex
        ["soon"] = true, ["later"] = true, ["now"] = true,
    }
    for i, item in ipairs(items) do
        if item.pos == "INTERJ" then
            item.role = "INTERJ"
        elseif item.pos == "ADV" then
            -- Adverbs are position-flexible in Turkish. v1 places all
            -- adverbs immediately before the predicate (the most common
            -- and most reliably-correct position for time, frequency,
            -- and manner adverbs). Degree adverbs and place adverbs
            -- have other natural positions but pre-predicate is rarely
            -- WRONG, just sometimes less idiomatic. Refinement (subcat
            -- field distinguishing time/manner/degree/place) is a
            -- future ship.
            item.role = "ADV"
            -- 8.16.x: sentence-initial temporal flag
            if i == 1 then
                local surfL = (item.surface or ""):lower()
                if SENTENCE_INITIAL_TEMPORALS[surfL] then
                    item.sentenceInitial = true
                end
            end
        end
    end

    -- Pass 1.6: MODAL-VERB pairing. Turkish modals are verb suffixes, not
    -- standalone words. For each MODAL token, find the next VERB token,
    -- propagate the modalType (and modalNegated flag) onto the VERB so
    -- generate() can produce the combined form (e.g. koş+abilir+im for
    -- "I can run", koş+amam for "I can't run"), and consume the MODAL
    -- itself so it emits no Turkish output.
    --
    -- Negation detection: if the MODAL itself is inherently negated
    -- ("cannot" -> can_neg) OR if a NEG token ("not") appears between
    -- the MODAL and the VERB, the verb gets modalNegated=true. The NEG
    -- token is also consumed in the latter case so it doesn't trigger
    -- copular/aorist negation elsewhere.
    --
    -- Edge cases:
    --   * MODAL with no following VERB ("I can.") -- MODAL stays unconsumed,
    --     which will surface as UNKNOWN. v1 doesn't try to elide a stranded
    --     modal; this happens rarely in chat.
    for i, item in ipairs(items) do
        if item.pos == "MODAL" and item.modalType then
            local intermediateNeg
            local paired = false
            for j = i + 1, #items do
                if items[j].pos == "NEG" then
                    intermediateNeg = items[j]
                elseif items[j].pos == "VERB" then
                    items[j].modalType    = item.modalType
                    items[j].modalNegated = item.modalNegated or (intermediateNeg ~= nil)
                    item.consumed = true
                    item.role = "MODAL"  -- so role-based filters know to skip
                    if intermediateNeg then
                        intermediateNeg.consumed = true
                        intermediateNeg.role = "MODAL"  -- absorbed into modal morphology
                        -- Do NOT set sawNegation for this NEG: it was absorbed
                        -- into the modal, not used for copular/aorist negation.
                    end
                    paired = true
                    break
                end
            end
            -- 9.0+ Mosaic: when MODAL doesn't find a VERB, look for an
            -- UNKNOWN-pos token (e.g. unknown English verb the user typed
            -- like "Retcon", "comeback", "ashell") and synthesize a VERB
            -- role on it. The token's surface stays as fallback (no
            -- Turkish translation), but it gets the modal suffix applied
            -- via the same machinery. This preserves the modal-meaning
            -- even when the verb is out-of-vocab.
            --
            -- We're conservative: only fire when (a) no VERB was found,
            -- (b) there IS an UNKNOWN-pos token after the modal, (c) that
            -- token is alphabetic (not punctuation/digits). The synthesized
            -- VERB uses the unknown token's surface as both stem and tr —
            -- output will be e.g. "Retconabiliriz" which signals to the
            -- Turkish reader "we can [English-Retcon]". Mixed but better
            -- than leaving the modal stranded English.
            if not paired then
                local synthIdx
                for j = i + 1, #items do
                    local it = items[j]
                    if it.pos == nil and it.surface
                        and it.surface:match("^[A-Za-z]+$") then
                        synthIdx = j
                        break
                    end
                end
                if synthIdx then
                    local synth = items[synthIdx]
                    synth.pos = "VERB"
                    synth.modalType    = item.modalType
                    synth.modalNegated = item.modalNegated or (intermediateNeg ~= nil)
                    -- Build a minimal entry stub so transfer/generate finds it.
                    -- Stem = lowercased surface; emit as-is (no real Turkish).
                    synth.entry = {
                        en = synth.surface:lower(),
                        pos = "VERB",
                        tr = synth.surface:lower(),
                        tr_stem = synth.surface:lower(),
                        subcat = "intransitive",
                    }
                    -- 9.0+ Mosaic: also update verbIndex so the downstream
                    -- Pass 2 role assignment treats this token as the
                    -- matrix predicate. Without this the synth has the
                    -- right pos/modalType but no role, and the modal
                    -- suffix never gets emitted.
                    verbIndex = synthIdx
                    item.consumed = true
                    item.role = "MODAL"
                    if intermediateNeg then
                        intermediateNeg.consumed = true
                        intermediateNeg.role = "MODAL"
                    end
                else
                    -- 9.0+ Mosaic: MODAL fully stranded (no VERB, no
                    -- UNKNOWN-pos token to synth onto). Common in chat
                    -- fragments like "all the ammo I can", "wait maybe
                    -- I can", "what you can" — the verb is implicit and
                    -- dropped by the speaker.
                    --
                    -- Emit an impersonal Turkish modal form by rewriting
                    -- the MODAL token itself as a VERB with the generic
                    -- "yap" (do) stem. "can" alone -> "yapabilir", "could"
                    -- -> "yapabilirdi", "will" -> "yapacak", etc. The
                    -- modal-suffix machinery handles the morphology;
                    -- we just supply the stem.
                    item.pos = "VERB"
                    item.entry = {
                        en = item.surface:lower(),
                        pos = "VERB",
                        tr = "yap",
                        tr_stem = "yap",
                        subcat = "intransitive",
                    }
                    verbIndex = i
                    -- modalType and modalNegated already on item; keep
                    -- them so the generator applies the suffix.
                end
            end
        end
    end

    -- Pass 1.7 (9.0+): VERB + V-ing pattern (gerund-complement constructions
    -- like "stop believing", "start running", "keep going", "finish eating").
    --
    -- English uses bare VERB + -ing-VERB sequences for these. The first
    -- verb is the matrix predicate; the -ing form is a verbal noun
    -- complement in accusative case. Turkish:
    --   "I stop believing"   -> "İnanmayı bıraktım"
    --                           (believe-VN-ACC stop-PAST-1SG)
    --   "I start running"    -> "Koşmayı başladım"
    --   "she kept walking"   -> "Yürümeyi devam etti" (loose)
    --
    -- Without this pass, the engine's "last verb wins" rule for verbIndex
    -- gives PREDICATE to the -ing form (which would be the verbal noun
    -- in correct Turkish), leaving the matrix verb stranded with
    -- role=UNKNOWN. Fix: detect the pattern, override verbIndex to point
    -- at the matrix verb, and mark the -ing token as a verbal noun object.
    --
    -- Detection: two consecutive entries both POS=VERB where the second
    -- token's surface ends in "ing" (English present participle / gerund
    -- form). The "-ing" form is identified via surface inspection because
    -- the lex maps gerund forms to their verb lemma (so the POS tag alone
    -- doesn't distinguish them). The matrix verb may itself be tagged
    -- past (irregular_past) or take a tense suffix later.
    for i = 1, #items - 1 do
        local cur = items[i]
        local nxt = items[i + 1]
        if cur and nxt
            and cur.entry and cur.entry.pos == "VERB"
            and nxt.entry and nxt.entry.pos == "VERB"
            and nxt.surface
            and nxt.surface:lower():gsub("[%.,!%?;:]+$", ""):sub(-3) == "ing"
            and not cur.consumed and not nxt.consumed
        then
            verbIndex = i  -- matrix verb becomes the predicate
            nxt.role = "VERBAL_NOUN_OBJ"
            nxt.verbalNounCase = "accusative"
            -- The verbal noun doesn't carry its own tense. The matrix
            -- verb carries the sentence's tense.
            nxt.tense = nil
        end
    end

    -- Pass 1.8 (9.0+): word-sense disambiguation, data-driven.
    --
    -- Some English verbs map to different Turkish verbs depending on
    -- their object's semantic class. The classic case:
    --   * "play" + music class object  -> çalmak (çal-)
    --   * "play" + (default)           -> oynamak (oyna-)
    --
    -- The disambiguation rules live in data/lexicon/sense_disambig.csv
    -- and the noun semantic classes in data/lexicon/noun_classes.csv,
    -- both compiled into TAZC_TranslateLexiconData. This pass:
    --   1. For each VERB item, look up its sense disambig rules
    --      (keyed by entry.en, e.g. "play").
    --   2. If rules exist, scan other items for a NOUN whose lex id
    --      maps to a trigger_class matching any rule.
    --   3. On first match, set the item-level shadow fields
    --      (trOverrideStem / trOverrideTr) which PREDICATE transfer
    --      reads in preference to entry.tr_stem / entry.tr.
    --
    -- Scope notes:
    --   * Object scan is whole-clause (any matching noun triggers, not
    --     just the syntactic direct object). This is right for most
    --     chat constructions: "guitar" mentioned anywhere in the clause
    --     signals music-sense play, even if word-order obscures the
    --     direct-object relation. False positives possible but rare.
    --   * Only the FIRST matching rule fires — multi-class verbs (if
    --     they emerge) would need a priority field; not needed yet.
    --   * Sense rules apply only to lex-tagged VERBs. Bare V-ing
    --     gerunds and irregular pasts go through the same path because
    --     they resolve to the same lex entry.
    for _, item in ipairs(items) do
        if item.entry and item.entry.pos == "VERB" then
            local rules = Lexicon.getSenseDisambig and Lexicon.getSenseDisambig(item.entry.en)
            if rules then
                local matched = false
                for _, other in ipairs(items) do
                    if matched then break end
                    if other ~= item and other.entry and other.entry.pos == "NOUN" then
                        local cls = Lexicon.getNounClass and Lexicon.getNounClass(other.entry.id)
                        if cls then
                            for _, rule in ipairs(rules) do
                                if rule.trigger_class == cls then
                                    item.trOverrideStem = rule.override_stem
                                    item.trOverrideTr   = rule.override_tr
                                    -- override_voicing not yet wired
                                    -- through; reserved for future
                                    -- senses that need it.
                                    matched = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Pass 2: position-aware role assignment. The pivot is the verb's
    -- index (or, for copular sentences, the AUX's index when there's no
    -- following verb). Tokens BEFORE the pivot are in the subject zone;
    -- tokens AFTER it are in the object/predicate zone.
    --
    -- Construction-type detection:
    --   - EXISTENTIAL_BARE: "there is/are X" -> "X var"
    --   - EXISTENTIAL_HAVE: "X has Y"        -> "Y-poss var"
    --   - COPULAR:          "X is Y"         -> "X Y-cop"
    --   - PRODUCTIVE:       "X V Y"          -> productive verb pipeline
    local isExistentialBare = (sawExis and verbIndex == nil)
    local isCopular = (sawAux and verbIndex == nil and not isExistentialBare)
    local pivot = verbIndex or auxIndex  -- position to split subject from rest
    local copularPredicateIndex  -- for copular sentences, where the ADJ/NOUN is

    -- 9.0+ Mosaic: implicit copular for sentence-initial NEG fragments.
    -- "Not bad", "Not so old", "Not really", "Not the worst", "Not in a
    -- dream" — bare predicate-only negation with no AUX or VERB.
    -- Turkish renders as "X değil" (predicate + değil particle for 3sg).
    --
    -- Detect: sentence starts with NEG; the rest is "predicate-able"
    -- content — ADJ/ADV/DET/NOUN/PREP/INTERJ allowed; no AUX, no VERB.
    -- Predicate head = last ADJ (preferred), else last NOUN, else last
    -- ADV. The predicate gets COPULAR_PRED_ADJ role; sawNegation already
    -- true means the predicate.negated path applies "değil".
    --
    -- The rest of the fragment (DETs, intervening PPs) gets emitted
    -- through normal role assignment. For "not the worst" -> "the worst
    -- değil" -> "En kötü değil" (DET emits nothing). For "not in a
    -- dream" -> PP + değil — handled through PREP-NP pairing for the
    -- NOUN, then değil at end.
    if not isCopular and not isExistentialBare and not pivot and sawNegation then
        local negIdx, predIdx
        local saw_only_predicate_content = true
        local adjFound = false
        local lastAdvIdx, lastNounIdx
        for i, item in ipairs(items) do
            if item.pos == "NEG" and not negIdx then
                negIdx = i
            elseif item.pos == "ADJ" then
                -- The last ADJ in the fragment is the predicate; if multiple
                -- ADJs appear we just pick the last (most chat fragments
                -- have one ADJ).
                predIdx = i
                adjFound = true
            elseif item.pos == "ADV" then
                lastAdvIdx = i
            elseif item.pos == "NOUN" then
                lastNounIdx = i
            elseif item.pos == "DET" or item.pos == "POSS"
                or item.pos == "PREP" or item.pos == "PRON"
                or item.pos == "NEG" or item.pos == "INTERJ"
                or item.pos == "CONJ" then
                -- allowed: function words that don't disqualify the
                -- fragment as predicate-only. CONJ ("but", "and", "yet",
                -- "though" when categorized as CONJ) prefixes a NEG-frag
                -- with a discourse marker. "But not safe" — "but" is
                -- discourse, the fragment is still NEG-predicate.
            else
                saw_only_predicate_content = false
                break
            end
        end
        -- Predicate priority: ADJ > NOUN > ADV.
        if not adjFound and lastNounIdx then
            predIdx = lastNounIdx
        elseif not adjFound and lastAdvIdx then
            predIdx = lastAdvIdx
        end
        if negIdx and predIdx and saw_only_predicate_content then
            isCopular = true
            pivot = negIdx
            copularPredicateIndex = predIdx
            -- ADJ vs NOUN vs ADV: same downstream path — the
            -- COPULAR_PRED_ADJ role is the catch-all for "bare
            -- predicate". The generator emits stem + değil.
            items[predIdx].role = "COPULAR_PRED_ADJ"
        end
    end

    if pivot then
        for i, item in ipairs(items) do
            if item.entry == nil then
                -- already UNKNOWN
            elseif item.pos == "INTERJ" then
                -- already assigned in Pass 1.5
            elseif item.pos == "ADV" then
                -- already assigned in Pass 1.5
            elseif item.pos == "MODAL" then
                -- already consumed in Pass 1.6: modalType propagated to
                -- the next VERB, item itself elided from output
            elseif item.pos == "WH" then
                -- will be assigned in Pass 9 (WH-question fix-up)
            elseif item.pos == "AUX" then
                item.role = "AUX"
            elseif item.pos == "AUX_DO" then
                item.role = "AUX_DO"
            elseif item.pos == "AUX_DO_NEG" then
                item.role = "AUX_DO_NEG"
            elseif item.pos == "NEG" then
                item.role = "NEG"
            elseif item.pos == "EXIS" then
                item.role = "EXIS"
            elseif item.pos == "POSS" then
                -- Possessive determiners are uniform: they attach to the
                -- following NOUN regardless of subject/object zone.
                item.role = "POSS_DET"
            elseif i < pivot then
                if item.pos == "PRON" then
                    item.role = "SUBJECT_PRON"
                elseif item.pos == "NOUN" then
                    item.role = "SUBJECT_NOUN"
                elseif item.pos == "DET" then
                    item.role = "DET_SUBJ"
                elseif item.pos == "ADJ" then
                    item.role = "ADJ_SUBJ"  -- attributive adjective before noun
                end
            elseif i == pivot then
                if isCopular or isExistentialBare then
                    item.role = "AUX"  -- the AUX itself
                else
                    item.role = "PREDICATE"
                end
            else  -- i > pivot
                if isCopular then
                    if item.pos == "ADJ" then
                        item.role = "COPULAR_PRED_ADJ"
                        copularPredicateIndex = i
                    elseif item.pos == "NOUN" then
                        item.role = "COPULAR_PRED_NOUN"
                        copularPredicateIndex = i
                    elseif item.pos == "DET" then
                        item.role = "DET_PRED"  -- "a" before predicate noun
                    end
                elseif isExistentialBare then
                    -- For "there is a car", the NOUN after the AUX is the
                    -- existential subject. Treat it as OBJECT for transfer
                    -- purposes (it becomes the bare noun that var/yok
                    -- attaches to in Turkish).
                    if item.pos == "NOUN" then
                        item.role = "OBJECT"
                    elseif item.pos == "DET" then
                        item.role = "DET_OBJ"
                    elseif item.pos == "ADJ" then
                        item.role = "ADJ_OBJ"
                    end
                else
                    if item.pos == "PRON" then
                        item.role = "OBJECT_PRON"
                        -- 8.16.x: DAT-taking verbs (help/trust/believe) mark
                        -- their direct-object pronoun as DAT. The lex's
                        -- subcat carries "dat_obj" for these verbs.
                        local verb = verbIndex and items[verbIndex]
                        if verb and verb.entry and verb.entry.subcat then
                            for _, s in ipairs(verb.entry.subcat) do
                                if s == "dat_obj" then
                                    item.datObj = true
                                    break
                                end
                            end
                        end
                    elseif item.pos == "NOUN" then
                        item.role = "OBJECT"
                    elseif item.pos == "DET" then
                        item.role = "DET_OBJ"
                    elseif item.pos == "ADJ" then
                        item.role = "ADJ_OBJ"  -- attributive adjective in object NP
                    end
                end
            end
        end
    end

    -- 8.9.21+: NP fragment fall-through. When the input has no pivot
    -- (no VERB, no AUX) but contains a NOUN, treat it as a bare NP and
    -- emit it in subject (nominative) position. This rescues inputs like
    -- "the cat", "twenty zombies", "a knife" -- standalone noun phrases
    -- with no implied verb. Without this, all roles stay UNKNOWN and the
    -- whole input leaks as English.
    --
    -- Behavior: the first NOUN becomes SUBJECT_NOUN; any preceding DET
    -- becomes DET_SUBJ; any preceding ADJ becomes ADJ_SUBJ. Additional
    -- nouns or post-noun content stays UNKNOWN. This is a deliberately
    -- minimal fragment-rescue: more elaborate fragments ("the big red
    -- car with the broken window") will get partial output.
    if not pivot then
        local firstNounIdx
        for i, item in ipairs(items) do
            if item.pos == "NOUN" and item.role == "UNKNOWN" then
                firstNounIdx = i
                break
            end
        end
        if firstNounIdx then
            items[firstNounIdx].role = "SUBJECT_NOUN"
            for j = 1, firstNounIdx - 1 do
                local p = items[j].pos
                if items[j].role == "UNKNOWN" then
                    if p == "DET" then
                        items[j].role = "DET_SUBJ"
                    elseif p == "ADJ" then
                        items[j].role = "ADJ_SUBJ"
                    elseif p == "POSS" then
                        items[j].role = "POSS_DET"
                    end
                end
            end
        end
    end

    -- Pass 2.4 (9.0+): genitive "X of Y" construction.
    --
    -- English uses "X of Y" for the possessor relationship (with the
    -- possessor as the OBJECT of the preposition, modifier-second).
    -- Turkish reverses this: Y-GEN X-3SG.POSS, modifier-first.
    --   "People of the River"      -> "Nehrin halkı"
    --   "the end of the world"     -> "dünyanın sonu"
    --   "blessings of the ancestor" -> "atanın nimetleri"
    --
    -- Detection pattern: NOUN1 [DET/ADJ]* PREP(of) [DET/ADJ]* NOUN2.
    -- NOUN1 becomes the possessed head (3SG.POSS marker, definite).
    -- NOUN2 becomes the modifier (genitive case).
    -- Intervening DETs on either side are consumed (no Turkish
    -- determiner needed -- the possessive suffix encodes definiteness).
    -- The "of" PREP is consumed.
    --
    -- Word order: after this pass, swap items so NOUN2 (modifier)
    -- precedes NOUN1 (head) in the items array. Subsequent passes and
    -- the surface assembly walk in the post-swap order, so the output
    -- naturally surfaces as "Y-GEN X-POSS" in the same cluster.
    --
    -- Limitations:
    --   * Pronominal genitives ("end of it" -> "onun sonu") work via
    --     n-buffer + genitive on the pronoun.
    --   * Chains ("X of Y of Z") not yet supported -- multi-pair
    --     interleaving would require careful ordering; v1 handles only
    --     the first pair detected.
    --   * Genitive isn't the only "of" sense: partitive ("a piece of
    --     bread"), material ("ring of gold"), apposition ("city of
    --     Sydney") could use different Turkish constructions. v1
    --     treats them all as genitive -- correct often enough, stiff
    --     occasionally.
    for i, item in ipairs(items) do
        if item.entry and item.entry.pos == "PREP"
            and (item.entry.en == "of" or item.lemma == "of")
            and not item.consumed
        then
            -- Find NOUN1 (head) -- the closest NOUN before this PREP
            local headIdx
            for j = i - 1, 1, -1 do
                local p = items[j].pos
                if p == "NOUN" then headIdx = j; break end
                if p ~= "DET" and p ~= "ADJ" and p ~= "POSS" then break end
            end
            -- Find NOUN2 (modifier) -- the closest NOUN after the PREP
            local modIdx
            for j = i + 1, #items do
                local p = items[j].pos
                if p == "NOUN" or p == "PRON" then modIdx = j; break end
                if p ~= "DET" and p ~= "ADJ" and p ~= "POSS" then break end
            end
            if headIdx and modIdx then
                local head = items[headIdx]
                local mod = items[modIdx]
                -- Tag the head as possessed (3sg) and definite
                head.possessed = true
                head.possessedPerson = 3
                head.possessedNumber = "sg"
                head.definite = true
                head.ofPaired = true  -- marks for swap pass
                -- Tag the modifier with genitive case
                mod.case = "genitive"
                mod.ofPaired = true
                mod.ofPartner = headIdx
                -- Mirror the head's role to the modifier so both go to
                -- the same cluster. If the head doesn't have a role yet
                -- (fragments without verbs), default to SUBJECT_NOUN.
                local headRole = head.role
                if headRole == "UNKNOWN" or not headRole then
                    headRole = "SUBJECT_NOUN"
                    head.role = headRole
                end
                if mod.pos == "PRON" then
                    -- Pronoun modifiers ("end of it") need a NOUN-like
                    -- transfer path that honours the case suffix.
                    mod.role = "GEN_MOD_PRON"
                else
                    mod.role = headRole
                end
                -- Consume the "of" PREP and any intervening DETs
                item.consumed = true
                item.role = "OF_CONSUMED"
                for j = i - 1, headIdx + 1, -1 do
                    if items[j].pos == "DET" or items[j].pos == "ADJ" then
                        items[j].consumed = true
                        items[j].role = "OF_DET_CONSUMED"
                    end
                end
                for j = i + 1, modIdx - 1 do
                    if items[j].pos == "DET" or items[j].pos == "ADJ" then
                        items[j].consumed = true
                        items[j].role = "OF_DET_CONSUMED"
                    end
                end
            end
        end
    end
    -- Post-pass: swap items so the genitive modifier appears before
    -- the head. We swap in place, after which transfer/generate/surface
    -- walk in Turkish order.
    do
        local i = 1
        while i <= #items do
            local item = items[i]
            if item.ofPaired and item.ofPartner then
                -- This is a MOD with a HEAD earlier in the array.
                -- Swap until MOD is immediately before HEAD.
                local headIdx = item.ofPartner
                if headIdx and headIdx < i then
                    -- Move item from position i to position headIdx,
                    -- shifting headIdx..i-1 right by one.
                    table.remove(items, i)
                    table.insert(items, headIdx, item)
                    -- ofPartner indices on other items are stale now,
                    -- but we don't use them after this point. Reset the
                    -- partner refs.
                    item.ofPartner = nil
                    -- The head moved one position to the right, but
                    -- we don't need to retrack it; both items still
                    -- carry the role/case/possessed flags they need.
                end
            end
            i = i + 1
        end
    end

    -- Pass 2.45 (9.0+): WH-determiner ("what songs", "which one", "what time").
    --
    -- When a WH word (what/which) is followed immediately by a NOUN, the WH
    -- is acting as an interrogative determiner modifying the noun. The
    -- WH+NOUN together form an NP that's typically the OBJECT of the
    -- following clause: "What songs can you play?" -> the WH-NP is the
    -- object of "play".
    --
    -- Pass 2 will have classified the NOUN as SUBJECT_NOUN (because it's
    -- before the modal/verb in linear order). We override: in a WH-DET
    -- structure with a following MODAL/AUX/AUX_DO, the WH+NOUN is the
    -- object. Mark the WH as consumed (it merges into the noun's tr by
    -- prepending "hangi") and mark the NOUN as OBJECT.
    --
    -- Turkish target:
    --   "what songs can you play"   -> "hangi şarkıları çalabilirsin"
    --   "which one do you want"     -> "hangisi istiyorsun" (approximate)
    --   "what time is it"           -> "saat kaç" / "ne zaman" (idiomatic)
    --
    -- v1 handles only the WH+NOUN+MODAL/AUX_DO pattern (clear object
    -- position). Cases where the WH-NP is the subject ("what songs
    -- exist?") are deferred.
    for i, item in ipairs(items) do
        if item.pos == "WH"
            and (item.lemma == "what" or item.lemma == "which")
            and items[i + 1]
            and items[i + 1].pos == "NOUN"
        then
            local nounItem = items[i + 1]
            local afterNP = items[i + 2]
            local nextIsAuxOrModal = afterNP and (
                afterNP.pos == "MODAL"
                or afterNP.pos == "AUX_DO"
                or afterNP.pos == "AUX"
            )
            if nextIsAuxOrModal then
                -- WH consumed; prepended Turkish det "hangi" goes on the NOUN
                item.consumed = true
                item.role = "WH_DET"  -- counted as covered, emits nothing
                nounItem.role = "OBJECT"
                nounItem.whDeterminer = true  -- transfer prepends "hangi"
                nounItem.definite = true       -- "what songs" -> definite obj
                -- Find the subject (PRON immediately after MODAL/AUX) and
                -- propagate its person/number to the predicate. Pass 2 may
                -- have set the noun's person/number on the predicate; we
                -- need to fix that.
                for k = i + 2, #items do
                    if items[k].pos == "PRON" then
                        -- Find the predicate VERB and adjust agreement
                        for v = k + 1, #items do
                            if items[v].pos == "VERB" then
                                items[v].subjectPerson = items[k].person or 3
                                items[v].subjectNumber = items[k].number or "sg"
                                break
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    -- Pass 2.5 (8.10.2+): PREP-NP pairing. Turkish marks prepositional
    -- relationships as case suffixes on the noun, not as separate words.
    -- For each PREP token, find the next NOUN (skipping DET/ADJ tokens
    -- that belong to the same NP), override the NOUN's role to PP_NOUN,
    -- and copy the PREP's case marker onto the NOUN. The PREP token itself
    -- is then consumed (emits nothing in Turkish output).
    --
    -- Examples:
    --   "at the base"    PREP DET NOUN  -> base.role=PP_NOUN, base.case=locative
    --   "with the gun"   PREP DET NOUN  -> gun.role=PP_NOUN,  gun.case=comitative
    --   "to the kitchen" PREP DET NOUN  -> kitchen.role=PP_NOUN, kitchen.case=dative
    --   "from the base"  PREP DET NOUN  -> base.role=PP_NOUN,  base.case=ablative
    --
    -- Edge cases:
    --   * PREP with no following NOUN ("at home." where home isn't lex'd):
    --     PREP stays unconsumed, will leak. Acceptable for v1.
    --   * Compound prepositions ("on top of", "next to"): not handled.
    for i, item in ipairs(items) do
        if item.pos == "PREP" and not item.consumed then
            local nounIdx
            local infinitiveTarget  -- 9.0+: track VERB-after-to for infinitive consumption
            for j = i + 1, #items do
                local p = items[j].pos
                if p == "DET" or p == "ADJ" or p == "POSS" then
                    -- skip — these belong to the NP
                else
                    if p == "NOUN" or p == "PRON" then
                        nounIdx = j
                    elseif p == "VERB" and item.lemma == "to" then
                        -- "to" + VERB is the English infinitive marker. Turkish
                        -- verbs have their own infinitive form (-mek/-mak); no
                        -- Turkish word corresponds to "to" here. Consume it
                        -- silently so it doesn't leak. The following verb is
                        -- left for the normal engine path to handle.
                        infinitiveTarget = j
                    end
                    break
                end
            end
            if infinitiveTarget then
                item.consumed = true
                item.role = "INFINITIVE_TO"  -- counted as covered, emits nothing
            elseif nounIdx then
                local prepCase = item.entry.subcat and item.entry.subcat[1] or "locative"
                local target = items[nounIdx]
                target.role = "PP_NOUN"
                -- 9.0+: postposition subcat ("postposition_için", etc.). The
                -- noun typically stays nominative (no case suffix) and a
                -- Turkish postposition word is emitted after via the
                -- postposition field. Used for "for X" -> "X için".
                --
                -- Some postpositions require a case on the noun too:
                -- "kadar" (until/as-much-as) takes dative ("yarına kadar").
                -- These use subcat "postposition_KADAR+dat" style where the
                -- "+dat" suffix tells us to also set the case.
                local postpositionMatch = prepCase:match("^postposition_(.+)$")
                if postpositionMatch then
                    local postpWord, plusCase = postpositionMatch:match("^([^+]+)%+(%w+)$")
                    if postpWord and plusCase then
                        target.postposition = postpWord
                        target.case = plusCase  -- e.g. "dative"
                    else
                        target.postposition = postpositionMatch
                        -- target.case stays nil so no case suffix applies
                    end
                else
                    target.case = prepCase
                end
                item.consumed = true
                item.role = "PREP"  -- mark as such (transfer ignores it)
                -- Re-tag any preceding DET/ADJ inside this NP so they
                -- route to the same cluster as the PP head.
                for k = i + 1, nounIdx - 1 do
                    local k_pos = items[k].pos
                    if k_pos == "DET" then
                        items[k].role = "DET_PP"
                    elseif k_pos == "ADJ" then
                        items[k].role = "ADJ_PP"
                    elseif k_pos == "POSS" then
                        items[k].role = "POSS_PP"
                    end
                end
            else
                -- 9.0+: Stranded preposition (no NP follower). Common in:
                --   "What are you talking about?"  -> "about" links to "What"
                --   "Where did you come from?"     -> "from" links to "Where"
                --   "Who are you talking to?"      -> "to" links to "Who"
                -- We ONLY apply this when items[1] is a WH word — outside
                -- of a WH-question context, a stranded PREP is more likely
                -- a parse failure we shouldn't paper over (e.g. "have to be"
                -- where "be" isn't lex'd as VERB; consuming "to" silently
                -- would mangle the sentence shape further).
                local wh = items[1]
                if wh and wh.pos == "WH" and wh.entry and wh.entry.tr then
                    -- Map common stranded preps to Turkish equivalents
                    -- that combine cleanly with a WH word. These are
                    -- best-effort approximations; the perfect translation
                    -- would inflect the WH itself (nereden, kime) but
                    -- that requires WH-stem morphology.
                    local mergeTr = nil
                    if item.lemma == "about" then
                        mergeTr = wh.entry.tr .. " hakk\196\177nda"  -- "ne hakkında"
                    elseif item.lemma == "with" then
                        mergeTr = wh.entry.tr .. "le"                -- "neyle" (rough)
                    elseif item.lemma == "for" then
                        mergeTr = wh.entry.tr .. " i\195\167in"      -- "ne için"
                    end
                    if mergeTr then
                        -- Override the WH's surface tr for transfer. The
                        -- entry table is shared across lookups, so we
                        -- stash on the item itself, not entry.
                        wh.trOverride = mergeTr
                    end
                    item.consumed = true
                    item.role = "STRANDED_PREP"
                end
                -- Outside a WH question, the PREP stays role=UNKNOWN and
                -- leaks — visible but harmless.
            end
        end
    end

    -- Pass 2.7 (8.10.3+): CONJ coordination. For "X and Y" / "X or Y"
    -- patterns, the second NOUN inherits the role of the first so both
    -- conjuncts emit at the appropriate position. Same applies for verbs
    -- ("I ran and shot") -- both VERBs become predicates emitted in
    -- sequence with "ve" between.
    --
    -- VERB-CONJ-VERB requires special care: the engine's pivot detection
    -- prefers the LAST verb ("last verb wins"), but for coordination the
    -- FIRST verb should be the main predicate and the second is a
    -- continuation. We override here, forcing left=PREDICATE and
    -- right=PREDICATE_CONT.
    for i, item in ipairs(items) do
        if item.pos == "CONJ" then
            -- Set role so coverage tracker counts CONJ as covered (transfer
            -- emits "ve"/"veya" regardless of further coordination context;
            -- leaving role=UNKNOWN miscounted these as leaks).
            item.role = "CONJ"
            local prev = items[i - 1]
            local nextNoun
            for j = i + 1, #items do
                local p = items[j].pos
                if p == "NOUN" or p == "PRON" or p == "VERB" then
                    nextNoun = items[j]
                    break
                elseif p == "DET" or p == "ADJ" or p == "POSS" then
                    -- skip past determiners/adjectives belonging to the next NP
                else
                    break
                end
            end
            if prev and nextNoun then
                -- VERB-VERB coordination: override pivot detection
                if prev.pos == "VERB" and nextNoun.pos == "VERB" then
                    prev.role = "PREDICATE"
                    nextNoun.role = "PREDICATE_CONT"
                    -- The second verb keeps its own tense (detected per-token).
                    -- If the first verb has a modal, the second inherits it.
                    if prev.modalType then
                        nextNoun.modalType = prev.modalType
                        nextNoun.modalNegated = prev.modalNegated
                    end
                    nextNoun.subjectPerson = prev.subjectPerson
                    nextNoun.subjectNumber = prev.subjectNumber
                    item.conjCluster = "predicate"
                elseif nextNoun.role == "UNKNOWN" then
                    -- NP-NP coordination: inherit role from left conjunct
                    local cluster
                    if prev.role == "SUBJECT_NOUN" and nextNoun.pos == "NOUN" then
                        nextNoun.role = "SUBJECT_NOUN"
                        cluster = "subject"
                    elseif prev.role == "SUBJECT_PRON" and nextNoun.pos == "PRON" then
                        nextNoun.role = "SUBJECT_PRON"
                        cluster = "subject"
                    elseif prev.role == "OBJECT" and nextNoun.pos == "NOUN" then
                        nextNoun.role = "OBJECT"
                        cluster = "object"
                    elseif prev.role == "OBJECT_PRON" and nextNoun.pos == "PRON" then
                        nextNoun.role = "OBJECT_PRON"
                        cluster = "object"
                    elseif prev.role == "PP_NOUN" and nextNoun.pos == "NOUN" then
                        nextNoun.role = "PP_NOUN"
                        nextNoun.case = prev.case
                        cluster = "object"
                    end
                    item.conjCluster = cluster
                    -- DET/ADJ between CONJ and the right conjunct route to the right cluster
                    for k = i + 1, #items do
                        if items[k] == nextNoun then break end
                        local kp = items[k].pos
                        if kp == "DET" then
                            if nextNoun.role == "SUBJECT_NOUN" then items[k].role = "DET_SUBJ"
                            elseif nextNoun.role == "OBJECT" then items[k].role = "DET_OBJ"
                            elseif nextNoun.role == "PP_NOUN" then items[k].role = "DET_PP"
                            end
                        elseif kp == "ADJ" then
                            if nextNoun.role == "SUBJECT_NOUN" then items[k].role = "ADJ_SUBJ"
                            elseif nextNoun.role == "OBJECT" then items[k].role = "ADJ_OBJ"
                            elseif nextNoun.role == "PP_NOUN" then items[k].role = "ADJ_PP"
                            end
                        elseif kp == "POSS" then
                            items[k].role = "POSS_DET"
                        end
                    end
                end
            end
        end
    end

    -- Pass 3: DET-NOUN pairing within each zone. A determiner immediately
    -- preceding a noun applies its definiteness/cardinality flags to the
    -- noun and marks itself consumed. POSS_DET works similarly but marks
    -- the noun as possessed with the determiner's person/number.
    --
    -- 8.10.2+: DET + ADJ* + NOUN pattern. When a DET is followed by one
    -- or more attributive adjectives before the noun ("the big dog",
    -- "a small heavy bag"), the DET still attaches to the NOUN -- we
    -- skip over the intervening ADJ tokens.
    local function findNounAfterAdjs(startIdx)
        for j = startIdx, #items do
            local r = items[j].role
            if r == "ADJ_SUBJ" or r == "ADJ_OBJ" or r == "ADJ_PP" then
                -- continue past attributive ADJ
            elseif r == "SUBJECT_NOUN" or r == "OBJECT"
                or r == "COPULAR_PRED_NOUN" or r == "PP_NOUN" then
                return j
            else
                return nil  -- something else interrupts the NP
            end
        end
        return nil
    end
    for i = 1, #items - 1 do
        local d = items[i]
        -- Locate the NOUN this determiner/possessive applies to (skipping
        -- intervening ADJs). For DET_SUBJ/DET_OBJ/POSS_DET we look ahead.
        local nIdx
        if d.role == "DET_SUBJ" or d.role == "DET_OBJ"
            or d.role == "DET_PRED" or d.role == "POSS_DET"
            or d.role == "DET_PP" or d.role == "POSS_PP" then
            nIdx = findNounAfterAdjs(i + 1)
        end
        local n = nIdx and items[nIdx] or items[i + 1]
        if d.role == "DET_SUBJ" and n.role == "SUBJECT_NOUN" then
            n.definite = d.entry.definite
            if d.entry.tr and d.entry.tr ~= "" then
                n.detText = d.entry.tr
            end
            d.consumed = true
        elseif d.role == "DET_OBJ" and n.role == "OBJECT" then
            n.definite = d.entry.definite
            n.indefiniteMarker = (d.entry.indefMarker == true)
            if d.entry.tr and d.entry.tr ~= "" then
                n.detText = d.entry.tr
            end
            d.consumed = true
        elseif d.role == "DET_PRED" and (n.role == "COPULAR_PRED_NOUN") then
            -- "a doctor" in copular position -- no bir, just drop the det
            if d.entry.tr and d.entry.tr ~= "" then
                n.detText = d.entry.tr
            end
            d.consumed = true
        elseif d.role == "DET_PP" and n.role == "PP_NOUN" then
            -- DET inside a prepositional phrase ("the kitchen", "a base"):
            -- mark the NP as definite if "the", leave bare if "a".
            -- (Bir doesn't get emitted in PP context for v1; case marking
            -- alone conveys the relationship.)
            n.definite = d.entry.definite
            if d.entry.tr and d.entry.tr ~= "" then
                n.detText = d.entry.tr
            end
            d.consumed = true
        elseif d.role == "POSS_DET" or d.role == "POSS_PP" then
            -- POSS attaches to any following NOUN regardless of zone.
            -- It can apply to SUBJECT_NOUN, OBJECT, COPULAR_PRED_NOUN, or
            -- PP_NOUN.
            if n.role == "SUBJECT_NOUN" or n.role == "OBJECT"
                or n.role == "COPULAR_PRED_NOUN" or n.role == "PP_NOUN" then
                n.possessed = true
                n.possessedPerson = d.possPerson
                n.possessedNumber = d.possNumber
                d.consumed = true
                -- 8.10.3+: possessed direct objects are inherently definite
                -- in Turkish ("kitabımı okudum" with -ı accusative, not
                -- "kitabım okudum"). Possession implies a specific instance.
                -- This rule applies to direct objects only — possessed PP
                -- nouns take their PP case, not accusative.
                if n.role == "OBJECT" then
                    n.definite = true
                end
            end
        end
    end

    -- Pass 4: identify the active subject (pronoun OR noun) and the
    -- predicate (verb for productive sentences, ADJ/NOUN for copular).
    local subject, predicate
    for _, item in ipairs(items) do
        if (item.role == "SUBJECT_PRON" or item.role == "SUBJECT_NOUN")
            and not subject then
            subject = item
        end
        if item.role == "PREDICATE" then
            predicate = item
        elseif item.role == "COPULAR_PRED_ADJ" or item.role == "COPULAR_PRED_NOUN" then
            predicate = item
        end
    end

    -- Pass 5: tense disambiguation for productive sentences. If predicate
    -- 8.10.1+: imperative detection. When position 1 is a VERB (or AUX_DO
    -- when it was disambiguated to VERB, e.g. "Do not move"), there's no
    -- explicit subject PRON anywhere, and the sentence isn't a question,
    -- treat the verb as a 2sg imperative. In Turkish, 2sg imperatives are
    -- the bare verb stem ("koş!", "git!", "düşür!"). No tense suffix, no
    -- person agreement.
    --
    -- 8.10.2+: also detect NEGATED imperative. Pattern: AUX_DO + NEG + VERB
    -- at sentence start with no subject ("Don't run", "Don't shoot",
    -- "Don't do anything"). After contraction normalize "don't" -> "do not"
    -- so the tokens are AUX_DO, NEG, VERB, ... . The VERB gets
    -- tense = "IMPERATIVE_NEG" so generate emits stem + -ma/-me.
    --
    -- Examples:
    --   "Drop the gun!"  -> "Tabancayı düşür" (positive)
    --   "Run!"           -> "Koş"             (positive)
    --   "Don't run!"     -> "Koşma"           (negative)
    --   "Don't move!"    -> "Hareket etme"    (negative)
    --   "Don't do that"  -> "Onu yapma"       (negative)
    --
    -- We override predicate.tense to "IMPERATIVE" / "IMPERATIVE_NEG" so
    -- generate() emits the appropriate form. SOV order is preserved
    -- ("Silahı düşür"); subject zone is empty since imperatives have an
    -- implicit "you" subject that Turkish drops anyway.
    if predicate and predicate.role == "PREDICATE"
        and not isYesNoQuestion and not isWHQuestion
    then
        local hasSubjectPron = false
        for _, it in ipairs(items) do
            if it.role == "SUBJECT_PRON" then
                hasSubjectPron = true
                break
            end
        end

        -- Positive imperative: position 1 is the predicate VERB itself.
        local positiveImp = (items[1] and items[1].pos == "VERB"
                            and items[1] == predicate)
        -- Negated imperative: position 1 is AUX_DO, position 2 is NEG,
        -- and the predicate is the verb that follows.
        local negativeImp = (items[1] and items[1].pos == "AUX_DO"
                            and items[2] and items[2].pos == "NEG"
                            and predicate.pos == "VERB")

        if not hasSubjectPron then
            if negativeImp then
                predicate.tense = "IMPERATIVE_NEG"
                -- The AUX_DO + NEG were consumed by the imperative; mark them
                -- with role = "IMPERATIVE_AUX" so they emit nothing.
                items[1].role = "IMPERATIVE_AUX"
                items[2].role = "IMPERATIVE_AUX"
                -- Clear sawNegation: the NEG token was absorbed into the
                -- imperative form, not into copular/aorist negation.
                sawNegation = false
            elseif positiveImp then
                predicate.tense = "IMPERATIVE"
            end
        end
    end

    -- 8.10.3+: Hortative ("let's X" / "let us X" / "let me X").
    -- After contraction normalize, "let's" -> "let us" and "lemme" ->
    -- "let me". The surface patterns are:
    --   items[1] = "let" (VERB)
    --   items[2] = PRON 1sg ("me") or 1pl ("us")
    --   items[3] = VERB  (the action verb)
    --
    -- Turkish: stem + -alım/-elim for 1pl ("Gidelim" = let's go),
    --          stem + -ayım/-eyim for 1sg ("Gideyim" = let me go).
    -- We mark items[3] as the PREDICATE with the appropriate hortative
    -- tense and consume items[1] and items[2].
    if items[1] and items[1].entry
        and items[1].entry.en == "let"
        and items[2] and items[2].pos == "PRON" and items[2].person == 1
        and items[3] and items[3].pos == "VERB"
    then
        items[3].role = "PREDICATE"
        if items[2].number == "pl" then
            items[3].tense = "HORTATIVE_1PL"
            items[3].subjectPerson = 1
            items[3].subjectNumber = "pl"
        else
            items[3].tense = "HORTATIVE_1SG"
            items[3].subjectPerson = 1
            items[3].subjectNumber = "sg"
        end
        items[1].role = "HORTATIVE_AUX"  -- consumed
        items[1].consumed = true
        items[2].role = "HORTATIVE_AUX"  -- consumed
        items[2].consumed = true
        predicate = items[3]
        -- Continuation: object NPs after the hortative VERB should route
        -- normally. Walk past items[3] and assign object roles.
        for k = 4, #items do
            local p = items[k].pos
            if items[k].role == "UNKNOWN" then
                if p == "NOUN" then items[k].role = "OBJECT"
                elseif p == "PRON" then items[k].role = "OBJECT_PRON"
                elseif p == "DET" then items[k].role = "DET_OBJ"
                elseif p == "ADJ" then items[k].role = "ADJ_OBJ"
                elseif p == "POSS" then items[k].role = "POSS_DET"
                end
            end
        end
    end

    -- has no detected tense and no aux is present, default to past (handles
    -- bare verb forms like "We read a book"). Aorist negation overrides.
    -- Special: "did" / "didn't" auxiliary signals PAST tense for the main
    -- verb -- without this, "Did you run?" parses as present progressive.
    if predicate and predicate.role == "PREDICATE" then
        if sawDoAuxPast and sawNegation and predicate.tense == nil then
            -- "didn't VERB" -> past negative ("görmedim" = "I didn't see")
            predicate.tense = "PAST_NEGATIVE"
        elseif sawDoAux and sawNegation and predicate.tense == nil then
            -- "don't VERB" / "doesn't VERB" -> aorist negative
            predicate.tense = "AORIST_NEGATIVE"
        elseif sawDoAuxPast and predicate.tense == nil then
            predicate.tense = "PAST"
        elseif predicate.tense == nil and not sawAux and not sawDoAux then
            -- 8.16.x: temporal-adverb tense inference. If a future-temporal
            -- adverb is present (tomorrow/tonight/soon/later) and no past-
            -- temporal adverb, default to FUTURE (MODAL+will) rather than
            -- PAST. Past-temporal cases (yesterday) keep PAST. Bare contexts
            -- without temporal adverb still default to PAST (the read/cut/
            -- hit-homograph compromise).
            if sawFutureTemporal and not sawPastTemporal then
                predicate.tense = "MODAL"
                predicate.modalType = "will"
            else
                predicate.tense = "PAST"
            end
        end
        -- 9.0+ Mosaic: present-perfect collapse case. "I haven't seen X"
        -- normalizes to "I not seen X". sawNegation is true, predicate
        -- gets PAST (from the bare-verb path above). Promote to
        -- PAST_NEGATIVE so the generator applies -medi/-madı morphology.
        if predicate.tense == "PAST" and sawNegation and not isExistentialBare
            and not (predicate.role == "COPULAR_PRED_ADJ"
                     or predicate.role == "COPULAR_PRED_NOUN") then
            predicate.tense = "PAST_NEGATIVE"
        end
    end

    -- Copular negation: "I am not tired" -> "Yorgun değilim". When isCopular
    -- and we saw a NEG token, mark the predicate so the generator inserts
    -- the "değil" particle between the predicate stem and the copular
    -- person/number suffix. The suffix's harmony class shifts to that of
    -- "değil" (front-unrounded i), not the predicate.
    if predicate and isCopular and sawNegation then
        predicate.negated = true
    end

    -- Pronoun retention rule for copular sentences: when the predicate is
    -- a NOUN with 3sg agreement, the Turkish copular suffix is zero --
    -- there's no person marker on the predicate to identify the subject.
    -- In that case Turkish keeps the subject pronoun ("O doktor" = "She
    -- is a doctor"). For other persons (1sg/2sg/1pl/2pl) the copular
    -- suffix carries enough info and the pronoun drops. ADJ predicates
    -- always drop the pronoun (the adjective itself signals predicate
    -- function).
    if subject and predicate and isCopular
        and predicate.role == "COPULAR_PRED_NOUN"
        and subject.role == "SUBJECT_PRON"
        and (subject.person == 3 and subject.number == "sg") then
        subject.keepPronoun = true
    end

    -- 8.16.x: indefinite pronouns (everyone/someone/something/nothing/
    -- anyone/anything) are lexically meaningful and must NOT drop, even
    -- in adjectival copular ("Everyone is tired" → "Herkes yorgun", not
    -- just "Yorgun"). These differ from personal pronouns (I/you/he/etc.)
    -- whose information is carried by verb agreement.
    if subject and subject.role == "SUBJECT_PRON" and subject.entry
        and subject.entry.en then
        local en = subject.entry.en:lower()
        if en == "everyone" or en == "someone" or en == "something"
           or en == "nothing" or en == "anyone" or en == "anything"
           or en == "everybody" or en == "somebody" or en == "nobody"
           or en == "everything" then
            subject.keepPronoun = true
        end
    end

    -- Pass 6: propagate subject person/number to the predicate.
    -- For pronoun subjects: use the pronoun's person/number directly.
    -- For noun subjects: Turkish uses 3sg default agreement on the verb
    --   even when the noun is plural (the plural marker on the noun is
    --   enough; -lar on the verb is redundant). This is a real rule of
    --   Turkish grammar, not a simplification. Pronoun subjects DO take
    --   -lar (Onlar oynuyorlar) because there's no other plural marker.
    --
    -- 8.10.3+: also propagate to PREDICATE_CONT items (second-and-later
    -- verbs in VP coordination, "ran and shot"). They share the subject
    -- so they share agreement.
    if subject and predicate then
        local sp, sn
        if subject.role == "SUBJECT_PRON" then
            sp = subject.person
            sn = subject.number
        else
            -- SUBJECT_NOUN: predicate takes 3sg agreement regardless
            sp = 3
            sn = "sg"
        end
        predicate.subjectPerson = sp
        predicate.subjectNumber = sn
        for _, it in ipairs(items) do
            if it.role == "PREDICATE_CONT" then
                it.subjectPerson = sp
                it.subjectNumber = sn
            end
        end
    end

    -- Pass 7 (existential-have only): propagate subject person/number to
    -- the object noun, so the possessive suffix on the object reflects
    -- "X has Y" -> Y-poss-X.person/number var. The object's possessed
    -- agreement comes from the SUBJECT, not from anywhere else.
    if isExistentialHave and subject and predicate then
        local sp, sn
        if subject.role == "SUBJECT_PRON" then
            sp = subject.person
            sn = subject.number
        else
            sp = 3
            sn = subject.isPlural and "pl" or "sg"
        end
        -- Find the OBJECT and apply possession
        for _, item in ipairs(items) do
            if item.role == "OBJECT" then
                item.possessed = true
                item.possessedPerson = sp
                item.possessedNumber = sn
                -- Don't clear indefiniteMarker: corpus keeps "bir" in
                -- "Bir arabam var" alongside the possessive.
            end
        end
    end

    -- Yes/no question detection (8.9.18+): input ends with "?" AND no
    -- WH-word is present. WH-questions take a different shape (the WH-word
    -- itself replaces the questioned slot, no question particle). For now
    -- we detect WH-words by surface form, since the WH POS is added later
    -- in the WH-productive ship; once that lands, we'll switch to a
    -- pos-based check. The current check covers the canonical WH set:
    --   what, where, when, why, who, how, which, whose
    -- which is exhaustive for English chat.
    local WH_SURFACE = {
        what = true, where = true, when = true, why = true,
        who = true, how = true, which = true, whose = true,
    }
    local hasWH = false
    for _, t in ipairs(tokens) do
        if WH_SURFACE[t:lower()] then hasWH = true; break end
    end
    -- 9.0+ Mosaic: structural yes/no question detection.
    --
    -- The "?" terminator isn't reliable in chat: people drop it, and
    -- Mosaic's clause splitter strips it from non-final clauses (the
    -- "?" in "Do you need X or are you good?" lives in clause 2's sep,
    -- so clause 1 "Do you need X" sees terminator="" but is clearly
    -- still a question).
    --
    -- Structural cue: subject-aux inversion. When the first token is
    -- AUX/AUX_DO/AUX_DO_NEG immediately followed by a PRON (or DET+NOUN
    -- for impersonal subjects), this is an inverted question regardless
    -- of terminator. Cover the standard patterns:
    --   "Do you V"           AUX_DO PRON VERB
    --   "Did you V"          AUX_DO PRON VERB
    --   "Are you ADJ/NOUN"   AUX    PRON ...
    --   "Is the X ADJ"       AUX    DET NOUN ADJ
    -- The post-detection yes/no machinery (predicate scan, particle
    -- generation, person/number agreement) is structure-agnostic; it
    -- just needs the isYesNoQuestion flag set.
    local hasYesNoStructure = false
    if #items >= 2 and not hasWH then
        local first = items[1]
        local second = items[2]
        if first and (first.pos == "AUX" or first.pos == "AUX_DO"
                or first.pos == "AUX_DO_NEG") then
            if second and (second.pos == "PRON" or second.pos == "DET") then
                hasYesNoStructure = true
            end
        end
    end
    local isYesNoQuestion = ((terminator == "?") or hasYesNoStructure) and not hasWH
    local isWHQuestion    = (terminator == "?") and hasWH

    -- Pass 8 (yes/no inversion fix-up): English yes/no questions invert
    -- the subject and auxiliary ("Are you tired?" not "*You are tired?"),
    -- but the standard Pass 2 / Pass 6 chain assumes subject-first
    -- declarative order. Without this pass, "Are you tired?" produces
    -- "You yorgun mu?" (subject leaks, no 2sg agreement) instead of the
    -- correct "Yorgun musun?".
    --
    -- The fix: when the first token is AUX/AUX_DO/AUX_DO_NEG and the
    -- input is a yes/no question, locate the predicate (LAST content word
    -- in the sequence -- ADJ, VERB, or copular NOUN) and re-classify
    -- everything BETWEEN the inverted AUX and the predicate as the
    -- subject NP. Then re-propagate subject person/number to the
    -- predicate's agreement slot.
    --
    -- This covers the four canonical inversion patterns:
    --   "Are you tired?"        AUX PRON ADJ        -> PRON=subj, ADJ=pred
    --   "Is the door locked?"   AUX DET NOUN ADJ    -> NOUN=subj, ADJ=pred
    --   "Is the cat a dog?"     AUX DET NOUN DET NOUN -> NOUN=subj, NOUN=pred
    --   "Did you run?"          AUX_DO PRON VERB    -> PRON=subj, VERB=pred
    --
    -- Excluded: existential constructions. "Is there a dog?" already has
    -- a valid structure (the NOUN gets role=OBJECT, var/yok appended at
    -- the end). Overriding it would corrupt the existential semantics
    -- and break the existential-have possession path too.
    if isYesNoQuestion and #items > 0
        and not isExistentialBare and not isExistentialHave then
        local first = items[1]
        if first.pos == "AUX" or first.pos == "AUX_DO" or first.pos == "AUX_DO_NEG" then
            -- Find predicate. Prefer VERB (the most common predicate),
            -- then ADJ (copular predicates "Are you tired?"), then NOUN
            -- (predicate nominal "Are you a doctor?"). Without this
            -- preference, "Do you need more ammo?" picks the rightmost
            -- content word (NOUN "ammo") as predicate, attaching the
            -- question particle to the object instead of the verb.
            -- 9.0+: skip items already tagged VERBAL_NOUN_OBJ by Pass 1.7
            -- (gerund complement of a matrix verb -- "did you stop
            -- believing?" should pick "stop" as the predicate, not the
            -- -ing form).
            local predicateIdx
            for j = #items, 2, -1 do
                if items[j].pos == "VERB"
                    and items[j].role ~= "VERBAL_NOUN_OBJ" then
                    predicateIdx = j
                    break
                end
            end
            if not predicateIdx then
                for j = #items, 2, -1 do
                    if items[j].pos == "ADJ" then
                        predicateIdx = j
                        break
                    end
                end
            end
            if not predicateIdx then
                for j = #items, 2, -1 do
                    if items[j].pos == "NOUN" then
                        predicateIdx = j
                        break
                    end
                end
            end
            if predicateIdx and predicateIdx > 1 then
                local subjectPerson = 3
                local subjectNumber = "sg"
                local hasSubject = false
                -- Subject region: positions 2 .. predicateIdx-1
                for j = 2, predicateIdx - 1 do
                    local p = items[j].pos
                    if p == "PRON" then
                        items[j].role = "SUBJECT_PRON"
                        subjectPerson = items[j].person or 3
                        subjectNumber = items[j].number or "sg"
                        hasSubject = true
                    elseif p == "NOUN" then
                        items[j].role = "SUBJECT_NOUN"
                        hasSubject = true
                        -- Noun subject -> verb takes 3sg even if noun plural
                        subjectPerson = 3
                        subjectNumber = "sg"
                    elseif p == "DET" then
                        items[j].role = "DET_SUBJ"
                    elseif p == "ADJ" then
                        items[j].role = "ADJ_SUBJ"  -- attributive in subject NP
                    end
                end
                -- Re-classify the predicate
                local predicate = items[predicateIdx]
                if predicate.pos == "ADJ" then
                    predicate.role = "COPULAR_PRED_ADJ"
                elseif predicate.pos == "VERB" then
                    predicate.role = "PREDICATE"
                elseif predicate.pos == "NOUN" then
                    predicate.role = "COPULAR_PRED_NOUN"
                end
                predicate.subjectPerson = subjectPerson
                predicate.subjectNumber = subjectNumber
                -- The inverted AUX itself emits no Turkish word (function
                -- word); its role stays AUX which the transfer pass already
                -- filters out.
            end
        end
    end

    -- Pass 9 (WH-question fix-up): WH-questions invert similarly to yes/no
    -- but the WH-word itself plays a specific role in the output. We handle
    -- two patterns:
    --
    --   COPULAR WH (WH + AUX + NP):
    --     "Where is the cat?"   WH AUX DET NOUN     -> NOUN=subj, WH=copular pred
    --     "Who is the doctor?"  WH AUX DET NOUN     -> NOUN=subj, WH=copular pred
    --     "What is your name?"  WH AUX POSS NOUN    -> NOUN(poss)=subj, WH=copular pred
    --     "How are you?"        WH AUX PRON         -> PRON=subj, WH=copular pred
    --
    --     The WH-word becomes the predicate and takes copular agreement.
    --     "Where" + 2sg agreement = neredesin; "how" + 1sg = nasılım;
    --     "who" + 2sg = kimsin; "what" stays 3sg bare = ne.
    --
    --   VERBAL WH (WH + AUX_DO + PRON + VERB):
    --     "When did you arrive?"  WH AUX_DO PRON VERB -> WH=adv, PRON=subj, VERB=pred(past)
    --     "How do you feel?"      WH AUX_DO PRON VERB -> WH=adv, PRON=subj, VERB=pred
    --
    --     The WH-word acts as an adverb in sentence-initial position. The
    --     existing ADV dispatch handles placement. PAST tense for "did"
    --     comes from the sawDoAuxPast machinery in Pass 5.
    --
    -- Patterns NOT yet handled (future refinement):
    --   * WH as direct object: "What do you want?" -- needs accusative on WH
    --   * WH inside NP: "What time is it?", "Which door?" (WH+NOUN compound)
    --   * "Whose" possessive: needs possessive-marking on the following NP
    --   * Stranded prepositions: "Where are you from?" -- ablative case on WH
    if isWHQuestion and #items >= 2 then
        local first = items[1]
        if first.pos == "WH" then
            local second = items[2]
            if second and second.pos == "AUX" then
                -- Look for an alternative predicate (ADJ or VERB) after the
                -- AUX. Scan right-to-left so a sentence-final predicate wins.
                local altPredicateIdx
                for j = #items, 3, -1 do
                    local p = items[j].pos
                    if p == "ADJ" or p == "VERB" then
                        altPredicateIdx = j
                        break
                    end
                end

                -- Subject region = positions 3..(altPredicate-1) when found,
                -- else 3..#items (entire post-AUX region is the subject NP).
                local subjectEnd = altPredicateIdx and (altPredicateIdx - 1) or #items
                local subjectPerson, subjectNumber = 3, "sg"
                for j = 3, subjectEnd do
                    local p = items[j].pos
                    if p == "PRON" then
                        items[j].role = "SUBJECT_PRON"
                        subjectPerson = items[j].person or 3
                        subjectNumber = items[j].number or "sg"
                    elseif p == "NOUN" then
                        items[j].role = "SUBJECT_NOUN"
                        subjectPerson = 3; subjectNumber = "sg"
                    elseif p == "DET" then
                        items[j].role = "DET_SUBJ"
                    elseif p == "POSS" then
                        items[j].role = "POSS_DET"
                    elseif p == "ADJ" then
                        items[j].role = "ADJ_SUBJ"
                    end
                end

                if altPredicateIdx then
                    -- WH = adverb; the trailing ADJ/VERB is the predicate.
                    -- "Why is the door open?" -> "Kapı neden açık?"
                    first.role = "ADV"
                    local altP = items[altPredicateIdx]
                    if altP.pos == "ADJ" then
                        altP.role = "COPULAR_PRED_ADJ"
                        isCopular = true
                    elseif altP.pos == "VERB" then
                        altP.role = "PREDICATE"
                    end
                    altP.subjectPerson = subjectPerson
                    altP.subjectNumber = subjectNumber
                else
                    -- No alt predicate -- WH IS the copular predicate.
                    -- "Where is the cat?" -> "Kedi nerede?"
                    first.role = "COPULAR_PRED_ADJ"
                    first.subjectPerson = subjectPerson
                    first.subjectNumber = subjectNumber
                    isCopular = true
                end
            elseif second and (second.pos == "AUX_DO" or second.pos == "AUX_DO_NEG") then
                -- Verbal WH: WH + AUX_DO + ... -- treat WH as adverb
                first.role = "ADV"
            elseif second and second.pos == "MODAL" then
                -- 8.10.1+: WH + MODAL + (PRON) + VERB.
                --   "Where should I go?"      -> "Nereye gitmeliyim?"
                --   "What can I do?"          -> "Ne yapabilirim?"
                --   "Why can't I see anything?" -> "Neden bir şeyi göremem?"
                --
                -- The MODAL was already paired with the following VERB in
                -- Pass 1.6 (modalType set on the VERB, MODAL token consumed).
                -- We just need to mark the WH as an adverb and identify the
                -- subject PRON if present, so Pass 6 propagates agreement.
                first.role = "ADV"
                for j = 3, #items do
                    local p = items[j].pos
                    if p == "PRON" then
                        items[j].role = "SUBJECT_PRON"
                        break  -- only the first PRON is subject; later PRONs are objects
                    end
                end
            end
        end
    end

    -- Stash construction-type metadata on the items table for downstream
    -- transfer/generate stages.
    items.construction = {
        isExistentialBare = isExistentialBare,
        isExistentialHave = isExistentialHave,
        isCopular         = isCopular,
        sawNegation       = sawNegation,
        isYesNoQuestion   = isYesNoQuestion,
        isWHQuestion      = isWHQuestion,
    }

    return items, errors
end

M.analyze = analyze

-- ---------------------------------------------------------------------------
-- 3. Transfer
--
-- Build a target-language structure. Each non-consumed item gets a
-- transferred form. Subject pronouns are MARKED for drop (Turkish drops
-- them when the verb's person/number suffix encodes the same information).
-- ---------------------------------------------------------------------------

local function transfer(analyzed)
    local transferred = {}
    local construction = analyzed.construction or {}
    for _, item in ipairs(analyzed) do
        if item.consumed then
            -- DET folded into its noun; skip
        elseif item.role == "AUX"
            or item.role == "AUX_DO"
            or item.role == "AUX_DO_NEG"
            or item.role == "NEG"
            or item.role == "EXIS"
            or item.role == "POSS_DET"
            or item.role == "MODAL" then
            -- Function words / consumed determiners / consumed modals:
            -- encoded into the predicate or noun morphology; skip direct emission.
        elseif item.role == "SUBJECT_PRON" then
            -- Usually dropped: Turkish verb agreement carries person/number.
            -- Exception: 3sg copular noun construction keeps the pronoun
            -- because the copular suffix is zero in that position.
            if item.keepPronoun then
                -- 9.0+ Mosaic: PRON lex stores accusative form (beni/seni/
                -- onu/bizi/sizi/onları). Subject position needs nominative.
                -- Map accusative -> nominative.
                local PRON_NOM = {
                    beni     = "ben",     seni     = "sen",
                    onu      = "o",       bizi     = "biz",
                    sizi     = "siz",
                    ["onlar\196\177"] = "onlar",  -- "onları" -> "onlar"
                }
                local nomStem = PRON_NOM[item.entry.tr] or item.entry.tr
                table.insert(transferred, {
                    kind   = "SUBJECT_NOUN",  -- emit as if it were a noun subject
                    stem   = nomStem,          -- nominative pronoun
                    isPlural = false,
                    source = item,
                })
            else
                table.insert(transferred, { kind = "DROPPED_SUBJECT", source = item })
            end
        elseif item.role == "SUBJECT_NOUN" then
            -- Keep noun subjects in nominative (no case marking) by default.
            -- 9.0+: Genitive "X of Y" pairs go through this role for both
            -- head and modifier (see Pass 2.4). For these, case/possessed
            -- flags need to flow into transfer for morphology to apply.
            local entry = item.entry
            table.insert(transferred, {
                kind             = "SUBJECT_NOUN",
                stem             = entry.tr,
                isPlural         = item.isPlural or false,
                detText          = item.detText,
                case             = item.case,             -- genitive for of-modifiers
                possessed        = item.possessed or false,
                possessedPerson  = item.possessedPerson,
                possessedNumber  = item.possessedNumber,
                definite         = item.definite or false,
                voicing          = entry.tr_final_voicing or false,
                isProperNoun     = item.isProperNoun or false,
                source           = item,
            })
        elseif item.role == "PREDICATE" or item.role == "PREDICATE_CONT" then
            local entry = item.entry
            -- Existential-have: the "have" verb emits no Turkish word. The
            -- object will be possessed instead, and a var/yok particle
            -- gets appended at the surface stage.
            if construction.isExistentialHave then
                -- skip: no Turkish verb form for "have"
            else
                -- If a MODAL was paired to this verb in Pass 1.6, override
                -- the tense so generate() routes to applyModal() rather
                -- than the default tense pipeline.
                local tense = item.tense or "PRESENT_PROGRESSIVE"
                if item.modalType then
                    tense = "MODAL"
                end
                table.insert(transferred, {
                    kind        = "VERB",
                    stem        = item.trOverrideStem or entry.tr_stem,
                    lemma       = item.trOverrideTr or entry.tr,
                    tense       = tense,
                    modal       = item.modalType,
                    modalNegated = item.modalNegated or false,
                    person      = item.subjectPerson or 3,
                    number      = item.subjectNumber or "sg",
                    intervocalic_voicing = entry.tr_intervocalic_voicing or false,
                    source      = item,
                })
            end
        elseif item.role == "COPULAR_PRED_ADJ" then
            -- Copular adjective predicate: "tired" + person/number copular suffix.
            -- In yes/no question form, the predicate is emitted bare and the
            -- question particle takes the agreement: "Yorgun musun?" instead
            -- of "Yorgunsun." Negated copular questions
            -- ("Aren't you tired?" / "Yorgun değil misin?") are deferred --
            -- v1 emits without negation collision protection.
            local entry = item.entry
            if construction.isYesNoQuestion and not item.negated then
                table.insert(transferred, {
                    kind   = "COPULAR_PRED_BARE",
                    stem   = entry.tr,
                    source = item,
                })
                table.insert(transferred, {
                    kind          = "QUESTION_PARTICLE",
                    mode          = "copular_agr",
                    predicateStem = entry.tr,
                    person        = item.subjectPerson or 3,
                    number        = item.subjectNumber or "sg",
                    source        = item,
                })
            else
                table.insert(transferred, {
                    kind   = "COPULAR_PRED",
                    stem   = entry.tr,
                    person = item.subjectPerson or 3,
                    number = item.subjectNumber or "sg",
                    voicing = entry.tr_final_voicing or false,
                    negated = item.negated or false,
                    source = item,
                })
            end
        elseif item.role == "COPULAR_PRED_NOUN" then
            -- Copular noun predicate: "doctor" + person/number copular suffix.
            -- Same yes/no split as COPULAR_PRED_ADJ.
            local entry = item.entry
            if construction.isYesNoQuestion and not item.negated then
                table.insert(transferred, {
                    kind   = "COPULAR_PRED_BARE",
                    stem   = entry.tr,
                    source = item,
                })
                table.insert(transferred, {
                    kind          = "QUESTION_PARTICLE",
                    mode          = "copular_agr",
                    predicateStem = entry.tr,
                    person        = item.subjectPerson or 3,
                    number        = item.subjectNumber or "sg",
                    source        = item,
                })
            else
                table.insert(transferred, {
                    kind   = "COPULAR_PRED",
                    stem   = entry.tr,
                    person = item.subjectPerson or 3,
                    number = item.subjectNumber or "sg",
                    voicing = entry.tr_final_voicing or false,
                    negated = item.negated or false,
                    source = item,
                })
            end
        elseif item.role == "VERBAL_NOUN_OBJ" then
            -- 9.0+: gerund-complement of a matrix verb ("stop believing",
            -- "start running"). Generate the verbal noun + accusative
            -- form immediately and emit as a passthrough surface element.
            -- The matrix verb still carries the sentence tense/agreement.
            --
            -- Stem comes from the lex entry's tr_stem (the verbal root,
            -- not the full -mek/-mak infinitive). Fall back to entry.tr
            -- with -mAk stripped if tr_stem isn't set.
            local entry = item.entry
            local stem = entry.tr_stem
            if not stem and entry.tr then
                local t = entry.tr
                if t:sub(-3) == "mek" or t:sub(-3) == "mak" then
                    stem = t:sub(1, -4)
                else
                    stem = t
                end
            end
            local form, _ = Morphology.applyVerbalNounAcc(stem, {
                intervocalic_voicing = entry.tr_intervocalic_voicing,
            })
            -- Capitalize if this is the first emitted item (sentence start).
            -- Surface stage handles capitalization for the first token by
            -- default; we emit as a "passthrough" kind which goes to the
            -- object cluster (placed immediately before the predicate).
            table.insert(transferred, {
                kind   = "VERBAL_NOUN",
                text   = form,
                source = item,
            })
        elseif item.role == "OBJECT" then
            local entry = item.entry
            table.insert(transferred, {
                kind             = "NOUN",
                stem             = entry.tr,
                -- 8.16.x: case must propagate through OBJECT role too.
                -- Genitive-marked of-modifier nouns get role=OBJECT (not
                -- PP_NOUN) when there's a verb in the sentence. Without
                -- this, case=genitive gets dropped and the default ACC
                -- (from definite=true) kicks in incorrectly.
                case             = item.case,
                definite         = item.definite or false,
                indefiniteMarker = item.indefiniteMarker or false,
                isPlural         = item.isPlural or false,
                voicing          = entry.tr_final_voicing or false,
                possessed        = item.possessed or false,
                possessedPerson  = item.possessedPerson,
                possessedNumber  = item.possessedNumber,
                detText          = item.detText,
                whDeterminer     = item.whDeterminer or false,
                isProperNoun     = item.isProperNoun or false,
                source           = item,
            })
        elseif item.role == "PP_NOUN" then
            -- 8.10.2+: prepositional-phrase noun. Emit as kind="NOUN" with
            -- the `case` field set so generate() applies the appropriate
            -- case suffix (locative/dative/ablative/comitative) after
            -- accusative/possessive/plural marking.
            -- 9.0+: postposition (for/X için) propagates via the postposition
            -- field. Noun stays nominative; postposition word is emitted by
            -- generate as a separate surface element AFTER the noun.
            local entry = item.entry
            table.insert(transferred, {
                kind             = "NOUN",
                stem             = entry.tr,
                case             = item.case,
                postposition     = item.postposition,
                definite         = item.definite or false,
                indefiniteMarker = false,
                isPlural         = item.isPlural or false,
                voicing          = entry.tr_final_voicing or false,
                possessed        = item.possessed or false,
                possessedPerson  = item.possessedPerson,
                possessedNumber  = item.possessedNumber,
                detText          = item.detText,
                isPP             = true,
                isProperNoun     = item.isProperNoun or false,
                source           = item,
            })
        elseif item.role == "PREP" then
            -- PREP is consumed by Pass 2.5 (case marking moved to the NP).
            -- Emit nothing.
        elseif item.role == "OBJECT_PRON" then
            -- 8.10.1+: PRON in object position. Two flavors:
            --   * Pre-baked accusative ("me" -> "beni", "him" -> "onu",
            --     "us" -> "bizi", "them" -> "onları"): the lex entry's
            --     tr is already the accusative form. Emit as-is, NO
            --     additional case marking.
            --   * Indefinite pronouns ("anything" -> "bir şey",
            --     "something" -> "bir şey", "nothing" -> "hiçbir şey",
            --     etc.): lex tr is the bare/nominative form; we need
            --     to mark accusative through the standard pipeline by
            --     setting definite=true on the transferred NOUN.
            --
            -- 8.16.x: third flavor — DAT-taking verb. When item.datObj is
            -- set (from verb subcat "dat_obj"), override the pre-baked ACC
            -- stem with the DAT form via PRONOUN_CASE_OVERRIDE. "help me"
            -- → "Bana yardım et" (was "Beni yardım et").
            local entry = item.entry
            local enSurf = (entry.en or ""):lower()
            local prebakedAcc = {
                me = true, him = true, her = true, us = true,
                them = true, it = true,
                -- 9.0+ Mosaic: reflexive pronouns. Their Turkish lex tr
                -- is the accusative form of kendi+POSS (kendimi/kendini/
                -- kendini/kendimizi/kendinizi/kendilerini). Pre-baked so
                -- the OBJECT_PRON pipeline doesn't double up the case.
                myself = true, yourself = true, himself = true,
                herself = true, itself = true, ourselves = true,
                yourselves = true, themselves = true,
            }
            local stem = entry.tr
            local needsCase = not prebakedAcc[enSurf]
            if item.datObj then
                -- Override pre-baked ACC stem with DAT form. applyDative
                -- handles the suppletive pronoun table internally (beni →
                -- bana, onu → ona, bizi → bize, etc.).
                local ok, datResult = pcall(Morphology.applyDative, entry.tr)
                if ok and datResult then
                    stem = datResult
                    needsCase = false  -- DAT already applied
                end
            end
            table.insert(transferred, {
                kind             = "NOUN",
                stem             = stem,
                definite         = needsCase,    -- triggers accusative if not pre-baked
                indefiniteMarker = false,
                isPlural         = false,
                voicing          = entry.tr_final_voicing or false,
                possessed        = false,
                source           = item,
            })
        elseif item.role == "INTERJ" then
            -- Interjections are emitted as their Turkish surface (entry.tr),
            -- preserved in position. No inflection, no agreement.
            local tr = item.entry and item.entry.tr or item.surface
            table.insert(transferred, {
                kind   = "INTERJ",
                text   = tr,
                source = item,
            })
        elseif item.role == "ADV" then
            -- Adverbs: emit as their Turkish surface (entry.tr). No
            -- inflection, no agreement. Placement is decided at the
            -- surface stage (currently: immediately before the predicate).
            -- 9.0+: WH words whose meaning was merged with a stranded
            -- preposition (e.g. "What...about" -> "ne hakkında") carry a
            -- trOverride field set by Pass 2.5. Honour it.
            local tr = item.trOverride or (item.entry and item.entry.tr) or item.surface
            table.insert(transferred, {
                kind             = "ADV",
                text             = tr,
                sentenceInitial  = item.sentenceInitial,
                source           = item,
            })
        elseif item.pos == "CONJ" then
            -- 8.10.3+: CONJ ("and" -> "ve", "or" -> "veya"). Emit as a
            -- passthrough surface element with cluster info so the
            -- surface stage routes it to the right cluster (between
            -- its conjuncts).
            local tr = item.entry and item.entry.tr or item.surface
            table.insert(transferred, {
                kind    = "CONJ",
                text    = tr,
                cluster = item.conjCluster,
                source  = item,
            })
        elseif item.role == "ADJ_SUBJ" or item.role == "ADJ_OBJ" or item.role == "ADJ_PP" then
            -- 8.10.2+: attributive adjectives inside an NP ("the big dog",
            -- "a small heavy bag", "with the heavy gun"). Emit as
            -- kind="ADJ_ATTR" so the surface stage places them BEFORE
            -- the noun they modify. The role distinguishes which NP-zone
            -- the ADJ belongs to (subject / object / PP) so surface
            -- assembly routes correctly.
            local tr = item.entry and item.entry.tr or item.surface
            local zone
            if item.role == "ADJ_SUBJ" then zone = "subject"
            elseif item.role == "ADJ_OBJ" then zone = "object"
            else zone = "pp" end
            table.insert(transferred, {
                kind = "ADJ_ATTR",
                text = tr,
                zone = zone,
                source = item,
            })
        elseif item.role == "PASSTHROUGH" then
            -- 9.0+ Mosaic: slang passthrough. Emit the original English
            -- surface in its source position. Coverage counts these as
            -- covered (the engine knew about the token and made an
            -- intentional choice to keep it English).
            table.insert(transferred, {
                kind    = "PASSTHROUGH",
                text    = item.surface,
                source  = item,
            })
        elseif item.role == "UNKNOWN" then
            -- 9.0+ Mosaic: when role assignment failed but the lex has
            -- a translation (e.g. WH "what" -> "ne", DET "any" -> "herhangi"),
            -- prefer the Turkish form. Without this, the English surface
            -- leaks even though the word is fully known. This is a
            -- graceful-degradation path: the role is wrong but the
            -- vocabulary is right, which is usually better for chat.
            local surface = item.surface
            if item.entry and item.entry.tr and item.entry.tr ~= "" then
                surface = item.entry.tr
            end
            table.insert(transferred, {
                kind    = "UNKNOWN",
                surface = surface,
                source  = item,
            })
        end
    end

    -- Append existential particle at the end for existential constructions.
    if construction.isExistentialBare or construction.isExistentialHave then
        local particle = construction.sawNegation and "yok" or "var"
        table.insert(transferred, {
            kind = "EXISTENTIAL",
            text = particle,
            negated = construction.sawNegation or false,
            source = nil,
        })
    end

    -- Yes/no question particle (8.9.18+): for verbal and existential
    -- predicates, the particle is BARE (mı/mi/mu/mü chosen by harmony of
    -- the preceding word at surface stage). For copular predicates the
    -- particle was already inserted with agreement during transfer of
    -- COPULAR_PRED_ADJ / COPULAR_PRED_NOUN above, so we don't add another.
    if construction.isYesNoQuestion then
        local alreadyHasParticle = false
        for _, t in ipairs(transferred) do
            if t.kind == "QUESTION_PARTICLE" then
                alreadyHasParticle = true; break
            end
        end
        if not alreadyHasParticle then
            table.insert(transferred, {
                kind = "QUESTION_PARTICLE",
                mode = "bare",
                source = nil,
            })
        end
    end

    return transferred
end

M.transfer = transfer

-- ---------------------------------------------------------------------------
-- 4. Generate
--
-- For each transferred item, produce a Turkish surface form.
-- ---------------------------------------------------------------------------

local function generate(transferred)
    local generated = {}
    for _, item in ipairs(transferred) do
        if item.kind == "VERB" then
            local personNumber = tostring(item.person) .. item.number
            local form, morphemes
            if item.tense == "MODAL" then
                -- Modal verbs (can/will/should/must/may): the modal attaches
                -- to the verb stem as a Turkish suffix, with vowel harmony
                -- and person/number agreement built into a single word.
                -- See TAZC_TranslateMorphology.applyModal for details.
                form, morphemes = Morphology.applyModal(item.stem, item.modal, personNumber, {
                    intervocalic_voicing = item.intervocalic_voicing,
                    negated              = item.modalNegated,
                })
            elseif item.tense == "PAST" then
                form, morphemes = Morphology.conjugatePast(item.stem, personNumber)
            elseif item.tense == "PAST_NEGATIVE" then
                -- 9.0+ Mosaic: negated past for "haven't VERB" / "hasn't
                -- VERB" / "didn't VERB" cases that go through the bare-
                -- past path. Pattern: stem + -me/-ma (negation) + -di/-dı
                -- (past) + person agreement.
                form, morphemes = Morphology.conjugatePastNegative(item.stem, personNumber)
            elseif item.tense == "AORIST_NEGATIVE" then
                form, morphemes = Morphology.conjugateAoristNegative(item.stem, personNumber)
            elseif item.tense == "IMPERATIVE" then
                -- 2sg imperative = bare verb stem ("koş!", "git!", "düşür!")
                form = item.stem
                morphemes = {
                    { surface = item.stem, gloss = "STEM" },
                    { surface = "", gloss = "IMP.2SG (zero)" },
                }
            elseif item.tense == "IMPERATIVE_NEG" then
                -- 2sg negated imperative = stem + -ma/-me ("koşma!", "yapma!")
                form, morphemes = Morphology.applyImperativeNeg(item.stem)
            elseif item.tense == "HORTATIVE_1PL" then
                -- 1pl hortative ("let's X") = stem + -alım/-elim
                form, morphemes = Morphology.applyHortative1pl(item.stem, {
                    intervocalic_voicing = item.intervocalic_voicing,
                })
            elseif item.tense == "HORTATIVE_1SG" then
                -- 1sg hortative ("let me X") = stem + -ayım/-eyim
                form, morphemes = Morphology.applyHortative1sg(item.stem, {
                    intervocalic_voicing = item.intervocalic_voicing,
                })
            else
                form, morphemes = Morphology.conjugatePresProg(item.stem, personNumber, {
                    intervocalic_voicing = item.intervocalic_voicing,
                })
            end
            table.insert(generated, {
                kind = "VERB", text = form, morphemes = morphemes, source = item,
            })
        elseif item.kind == "COPULAR_PRED" then
            local personNumber = tostring(item.person) .. item.number
            local form, morphemes
            if item.negated then
                -- Negated copular: PREDICATE + " değil" + COPULAR_SUFFIX.
                -- The suffix attaches to "değil" (front-unrounded harmony),
                -- not to the original predicate.
                local degilForm, degilMorph = Morphology.applyCopular("de\196\159il", personNumber)
                form = item.stem .. " " .. degilForm
                morphemes = {
                    { surface = item.stem, gloss = "PREDICATE" },
                    { surface = " ", gloss = "(separator)" },
                }
                for _, m in ipairs(degilMorph) do
                    if m.gloss == "STEM" then
                        table.insert(morphemes, { surface = m.surface, gloss = "NEG.COP" })
                    else
                        table.insert(morphemes, m)
                    end
                end
            else
                form, morphemes = Morphology.applyCopular(item.stem, personNumber)
            end
            table.insert(generated, {
                kind = "COPULAR", text = form, morphemes = morphemes, source = item,
            })
        elseif item.kind == "SUBJECT_NOUN" then
            local form = item.stem
            local morphemes = { { surface = item.stem, gloss = "STEM" } }

            -- Turkish morpheme order: STEM + PLURAL + POSSESSIVE + CASE.
            --   kitap + lar + ım   = kitaplarım   (my books)
            --   nehir + ler + i    = nehirleri    (its rivers)
            -- We apply plural FIRST, then possessive, then case.
            if item.isPlural then
                local pluralized, plMorphemes = Morphology.applyPlural(form)
                form = pluralized
                morphemes = plMorphemes
            end
            if item.possessed then
                local pn = tostring(item.possessedPerson) .. item.possessedNumber
                local possForm, possMorphemes = Morphology.applyPossessive(
                    form, pn, { voicing = item.voicing })
                form = possForm
                if item.isPlural then
                    table.insert(morphemes, possMorphemes[#possMorphemes])
                else
                    morphemes = possMorphemes
                end
            end
            if item.case then
                local caseForm, caseMorphemes
                local afterPossessive3 = item.possessed
                    and (item.possessedPerson == 3
                         or item.possessedPerson == "3")
                if item.case == "locative" then
                    caseForm, caseMorphemes = Morphology.applyLocative(form,
                        { afterPossessive3 = afterPossessive3 })
                elseif item.case == "dative" then
                    caseForm, caseMorphemes = Morphology.applyDative(form,
                        { afterPossessive3 = afterPossessive3,
                          isProperNoun = item.isProperNoun })
                elseif item.case == "ablative" then
                    caseForm, caseMorphemes = Morphology.applyAblative(form,
                        { afterPossessive3 = afterPossessive3 })
                elseif item.case == "comitative" then
                    caseForm, caseMorphemes = Morphology.applyComitative(form)
                elseif item.case == "genitive" then
                    caseForm, caseMorphemes = Morphology.applyGenitive(form,
                        { isProperNoun = item.isProperNoun })
                end
                if caseForm then
                    form = caseForm
                    if item.isPlural or item.possessed then
                        table.insert(morphemes, caseMorphemes[#caseMorphemes])
                    else
                        morphemes = caseMorphemes
                    end
                end
            end

            -- Determiner literal (this/that/two/iki/etc) precedes the noun.
            -- Emitted as its own DETERMINER element with slot="subject" so
            -- the surface stage routes it into the subject cluster rather
            -- than the object/predicate cluster.
            if item.detText then
                table.insert(generated, {
                    kind = "DETERMINER", text = item.detText, slot = "subject",
                    morphemes = { { surface = item.detText, gloss = "DET" } },
                    source = item,
                })
            end
            table.insert(generated, {
                kind = "SUBJECT_NOUN", text = form, morphemes = morphemes, source = item,
            })
        elseif item.kind == "NOUN" then
            local form = item.stem
            local morphemes = { { surface = item.stem, gloss = "STEM" } }

            -- Determiner literal precedes the noun. Emitted first so the
            -- surface stage positions it before any indefinite "bir" marker
            -- and before the noun itself. The DET-NOUN consumption pass
            -- transferred the literal from the source DET via item.detText.
            -- slot="object" so surface routes it into the object cluster.
            if item.detText then
                table.insert(generated, {
                    kind = "DETERMINER", text = item.detText, slot = "object",
                    morphemes = { { surface = item.detText, gloss = "DET" } },
                    source = item,
                })
            end

            -- 8.16.x: Turkish morpheme order is STEM + PL + POSS + CASE.
            -- "anahtar" + lar (PL) + ı (POSS-3sg) = "anahtarları";
            -- + ACC = "anahtarlarını". Plural goes BEFORE possessive.
            if item.isPlural then
                local pluralized, plMorphemes = Morphology.applyPlural(form)
                form = pluralized
                morphemes = plMorphemes
            end

            -- Possessive marker (if any). Possessive subsumes the indefinite
            -- marker: "my book" doesn't want "bir kitabım", just "kitabım".
            if item.possessed then
                -- 9.0+ Mosaic guard: when possessed is set without
                -- person/number (can happen via genitive Pass 2.4 with
                -- a missing role transfer), default to 3sg. This avoids
                -- a tostring(nil) crash and produces sensible output.
                local pn = tostring(item.possessedPerson or 3)
                    .. (item.possessedNumber or "sg")
                local possForm, possMorphemes = Morphology.applyPossessive(
                    form, pn, { voicing = item.voicing })
                form = possForm
                -- If plural was applied, append POSS morphemes; otherwise
                -- replace (POSS morphemes describe the full transformation).
                if item.isPlural then
                    table.insert(morphemes, possMorphemes[#possMorphemes])
                else
                    morphemes = possMorphemes
                end
            end
            if item.definite and not item.case and not item.postposition then
                -- 8.16.x: pass afterPossessive3 when stem was just POSS-3
                -- marked, so ACC uses n-buffer instead of y-buffer.
                -- "tabancası" + ACC → "tabancasını" not "tabancasıyı".
                local afterPossessive3 = item.possessed
                    and (item.possessedPerson == 3
                         or item.possessedPerson == "3")
                local accForm, accMorphemes = Morphology.applyAccusative(
                    form, { voicing = item.voicing,
                            afterPossessive3 = afterPossessive3 })
                form = accForm
                if item.isPlural or item.possessed then
                    table.insert(morphemes, accMorphemes[#accMorphemes])
                else
                    morphemes = accMorphemes
                end
            end
            -- 8.10.2+: case suffix for prepositional-phrase nouns. Applied
            -- AFTER plural/possessive but mutually exclusive with accusative
            -- (definite-direct-object marking). A PP-noun is never also
            -- the direct object of the verb; its case conveys the
            -- prepositional relationship instead.
            if item.case then
                local caseForm, caseMorphemes
                local afterPossessive3 = item.possessed
                    and (item.possessedPerson == 3
                         or item.possessedPerson == "3")
                if item.case == "locative" then
                    caseForm, caseMorphemes = Morphology.applyLocative(form,
                        { afterPossessive3 = afterPossessive3 })
                elseif item.case == "dative" then
                    caseForm, caseMorphemes = Morphology.applyDative(form,
                        { afterPossessive3 = afterPossessive3,
                          isProperNoun = item.isProperNoun })
                elseif item.case == "ablative" then
                    caseForm, caseMorphemes = Morphology.applyAblative(form,
                        { afterPossessive3 = afterPossessive3 })
                elseif item.case == "comitative" then
                    caseForm, caseMorphemes = Morphology.applyComitative(form)
                elseif item.case == "genitive" then
                    -- 9.0+ Mosaic: genitive case for "X of Y" -> "Y-GEN X-POSS".
                    caseForm, caseMorphemes = Morphology.applyGenitive(form,
                        { isProperNoun = item.isProperNoun })
                end
                if caseForm then
                    form = caseForm
                    if item.isPlural or item.possessed then
                        table.insert(morphemes, caseMorphemes[#caseMorphemes])
                    else
                        morphemes = caseMorphemes
                    end
                end
            end
            -- Indefinite marker "bir" is emitted as its own preceding word.
            -- Kept even on possessed nouns: the corpus prefers
            -- "Bir arabam var" over the (also acceptable) "Arabam var".
            if item.indefiniteMarker then
                table.insert(generated, {
                    kind = "DETERMINER", text = "bir",
                    morphemes = { { surface = "bir", gloss = "INDEF(cardinal)" } },
                    source = item,
                })
            end
            -- 9.0+ WH-determiner prefix ("what songs" -> "hangi şarkıları").
            -- "hangi" is emitted as a separate DETERMINER kind so the surface
            -- layer can place it correctly in the cluster (immediately before
            -- the noun it modifies).
            if item.whDeterminer then
                table.insert(generated, {
                    kind = "DETERMINER",
                    text = "hangi",
                    morphemes = { { surface = "hangi", gloss = "WH.DET" } },
                    slot = "object",
                    source = item,
                })
            end
            table.insert(generated, {
                kind = "NOUN", text = form, morphemes = morphemes, source = item,
            })
            -- 9.0+ postposition word ("için", future: "ile", "kadar", "gibi").
            -- Emitted as its own surface element AFTER the noun, in the same
            -- cluster. Stays an invariant word; no harmony or conjugation.
            if item.postposition then
                table.insert(generated, {
                    kind = "POSTPOSITION",
                    text = item.postposition,
                    morphemes = { { surface = item.postposition, gloss = "POSTP" } },
                    source = item,
                })
            end
        elseif item.kind == "EXISTENTIAL" then
            -- Existential particle: var (positive) or yok (negative).
            -- Treated as its own surface element so the surface layer can
            -- place it at the sentence end after the SOV ordering.
            table.insert(generated, {
                kind = "EXISTENTIAL",
                text = item.text,
                morphemes = {
                    { surface = item.text,
                      gloss = item.negated and "EXIS.NEG" or "EXIS" },
                },
                source = item,
            })
        elseif item.kind == "DROPPED_SUBJECT" then
            table.insert(generated, { kind = "DROPPED", source = item })
        elseif item.kind == "INTERJ" then
            table.insert(generated, { kind = "INTERJ", text = item.text, source = item })
        elseif item.kind == "ADV" then
            table.insert(generated, { kind = "ADV", text = item.text,
                sentenceInitial = item.sentenceInitial, source = item })
        elseif item.kind == "CONJ" then
            -- 8.10.3+: conjunction passthrough ("ve", "veya"). The
            -- cluster field tags which cluster (subject / object /
            -- predicate) the CONJ should route to.
            table.insert(generated, {
                kind    = "CONJ",
                text    = item.text,
                cluster = item.cluster,
                source  = item,
            })
        elseif item.kind == "PASSTHROUGH" then
            -- 9.0+ Mosaic: slang passthrough — emit original English surface.
            table.insert(generated, {
                kind   = "PASSTHROUGH",
                text   = item.text,
                source = item,
            })
        elseif item.kind == "VERBAL_NOUN" then
            -- 9.0+: gerund-complement of a matrix verb ("stop believing" ->
            -- "İnanmayı bıraktım"). The verbal noun phrase routes to the
            -- object cluster (placed immediately before the predicate in
            -- Turkish SOV order). Already-inflected as a single token by
            -- transfer; surface just emplaces it.
            table.insert(generated, {
                kind   = "VERBAL_NOUN",
                text   = item.text,
                source = item,
            })
        elseif item.kind == "ADJ_ATTR" then
            -- Attributive adjective in NP. Surface places it immediately
            -- before the noun in its zone (subject or object cluster).
            table.insert(generated, {
                kind = "ADJ_ATTR",
                text = item.text,
                slot = item.zone,  -- "subject" or "object"
                source = item,
            })
        elseif item.kind == "COPULAR_PRED_BARE" then
            -- Bare predicate (yes/no question): just the stem, no agreement.
            -- The question particle that follows will carry the agreement.
            table.insert(generated, {
                kind = "COPULAR_PRED_BARE",
                text = item.stem,
                morphemes = { { surface = item.stem, gloss = "PRED(bare)" } },
                source = item,
            })
        elseif item.kind == "QUESTION_PARTICLE" then
            -- The particle has two modes:
            --   "copular_agr" -> particle takes the agreement; computed here
            --                    from predicateStem + person/number.
            --   "bare"        -> particle with no agreement; harmony chosen
            --                    at surface stage based on the actually-emitted
            --                    previous word (because for verbal predicates
            --                    that word's vowels can differ from the stem).
            if item.mode == "copular_agr" then
                local pn = tostring(item.person) .. item.number
                local form = Morphology.applyQuestionParticleWithAgreement(item.predicateStem, pn)
                table.insert(generated, {
                    kind = "QUESTION_PARTICLE",
                    text = form,
                    mode = "copular_agr",
                    morphemes = {
                        { surface = form, gloss = "Q.PART+AGR(" .. pn:upper() .. ")" },
                    },
                    source = item,
                })
            else
                table.insert(generated, {
                    kind = "QUESTION_PARTICLE",
                    text = nil,  -- filled at surface
                    mode = "bare",
                    morphemes = { { surface = "?", gloss = "Q.PART(bare)" } },
                    source = item,
                })
            end
        elseif item.kind == "UNKNOWN" then
            table.insert(generated, { kind = "UNKNOWN", text = item.surface, source = item })
        end
    end
    return generated
end

M.generate = generate

-- ---------------------------------------------------------------------------
-- 5. Surface
--
-- Reorder to SOV: any NOUN object precedes the VERB. For the v1 PoC, the
-- ordering is straightforward because the corpus has at most one noun object
-- per sentence. Capitalize the first surface word. Append the terminator
-- from the original input.
-- ---------------------------------------------------------------------------

-- Turkish uppercase map for characters where Lua's ASCII-only :upper() gives
-- the wrong result. Most notably:
--   i (Latin small letter i, dotted)  -> İ (Latin capital I with dot above)
--   ı (Latin small letter dotless i)  -> I (Latin capital I)
-- and the Turkish-specific consonants. The English ASCII letters fall
-- through to the regular :upper() path.
local TR_UPPER = {
    ["i"] = "\196\176",  -- İ
    ["\196\177"] = "I",  -- ı -> I
    ["\195\167"] = "\195\135",  -- ç -> Ç
    ["\197\159"] = "\197\158",  -- ş -> Ş
    ["\196\159"] = "\196\158",  -- ğ -> Ğ
    ["\195\182"] = "\195\150",  -- ö -> Ö
    ["\195\188"] = "\195\156",  -- ü -> Ü
}

-- UTF-8 helpers come from TAZC_StringUtils so the iterator works on both Lua
-- 5.4 (byte storage in tests) and Kahlua (codepoint storage in PZ). See that
-- module for the storage-model discriminator.
local utf8chars   = Str.utf8chars
local utf8charLen = Str.utf8charLen

local function capitalizeTurkish(s)
    if s == "" then return s end
    -- Get the first UTF-8 character (handling multi-byte sequences)
    local sz = utf8charLen(s)
    local first = s:sub(1, sz)
    local rest = s:sub(sz + 1)
    -- 8.10.3+: i->İ mapping only when the first word is recognizably
    -- Turkish, not an English leak. For "if", "in", "is", "it", "into"
    -- (English words that leak when not in the lex), use ASCII I to
    -- avoid "İf" / "İn" / "İs" output. Other Turkish characters (ç, ş,
    -- ğ, ö, ü) are multi-byte so they don't have this ambiguity.
    if first == "i" then
        local firstWordEnd = s:find(" ", 1, true) or (#s + 1)
        local firstWord = s:sub(1, firstWordEnd - 1):lower()
        local englishLeaks = {
            ["if"] = true, ["in"] = true, ["is"] = true, ["it"] = true,
            ["into"] = true, ["i"] = true, ["i'd"] = true, ["i'm"] = true,
            ["i've"] = true, ["i'll"] = true,
        }
        if englishLeaks[firstWord] then
            return "I" .. rest
        end
        return "\196\176" .. rest  -- İ
    end
    local mapped = TR_UPPER[first] or first:upper()
    return mapped .. rest
end

local function surface(generated, terminator)
    -- SOV (Subject-Object-Verb) ordering for Turkish output:
    --   1. Subject noun (if present and not dropped)
    --   2. Determiner + object noun(s)
    --   3. Verb or copular predicate (or bare predicate for yes/no questions)
    --   4. Existential particle (var/yok) -- comes last in existential
    --      and existential-have constructions.
    --   5. Question particle (mı/mi/mu/mü, optionally with agreement) at the
    --      very end for yes/no questions. Bare-mode particles resolve their
    --      harmony class against the actually-emitted previous word.
    local subjectNouns = {}
    local objectPhrases = {}
    local interjections = {}
    local adverbs = {}
    local initialAdverbs = {}  -- 8.16.x: sentence-initial temporal adverbs
    local predicate
    local predicateContinuations = {}  -- 8.10.3+: second-and-later verbs in coordination
    local existentialParticle
    local questionParticle
    for _, g in ipairs(generated) do
        if g.kind == "VERB" or g.kind == "COPULAR" or g.kind == "COPULAR_PRED_BARE" then
            if predicate then
                -- 8.10.3+: second VERB is a coordinated continuation
                -- ("ran and shot" -> "koştum ve vurdum"). Saved here and
                -- appended after the main predicate in surface order.
                table.insert(predicateContinuations, g)
            else
                predicate = g
            end
        elseif g.kind == "EXISTENTIAL" then
            existentialParticle = g
        elseif g.kind == "QUESTION_PARTICLE" then
            questionParticle = g
        elseif g.kind == "INTERJ" then
            -- Interjections lead the sentence ("Merhaba, kapı kırık").
            -- v1 places all INTERJs first regardless of original position;
            -- sentence-final interjections will be handled when needed.
            table.insert(interjections, g)
        elseif g.kind == "ADV" then
            -- 8.16.x: sentence-initial temporal adverbs (yesterday/today/
            -- tomorrow/tonight/etc.) go at sentence start in Turkish, not
            -- immediately before predicate. Routes via initialAdverbs.
            if g.sentenceInitial then
                table.insert(initialAdverbs, g)
            else
                -- Adverbs cluster immediately before the predicate (see below).
                table.insert(adverbs, g)
            end
        elseif g.kind == "PASSTHROUGH" then
            -- 9.0+ Mosaic: slang passthrough. Routes to adverbs cluster so
            -- it appears immediately before the predicate -- "Koşuyorum lol"
            -- ("I'm running lol") reads naturally with the slang where you'd
            -- expect a discourse marker in chat.
            table.insert(adverbs, g)
        elseif g.kind == "SUBJECT_NOUN" then
            table.insert(subjectNouns, g)
        elseif g.kind == "POSTPOSITION" then
            -- 9.0+ Mosaic: postposition word ("için", future: "ile",
            -- "kadar", "gibi"). Emitted by NOUN generate immediately
            -- after its noun. Routes to the object cluster by default
            -- (PP NPs are object-cluster routed); the postposition word
            -- follows the noun in the generated stream so order is
            -- naturally preserved within the cluster.
            table.insert(objectPhrases, g)
        elseif g.kind == "DETERMINER" then
            -- Route DETERMINERs to the slot that owns them. Determiners
            -- without a slot tag fall back to the object cluster (where
            -- the existing indefinite-"bir" marker has always lived).
            if g.slot == "subject" then
                table.insert(subjectNouns, g)
            else
                table.insert(objectPhrases, g)
            end
        elseif g.kind == "ADJ_ATTR" then
            -- 8.10.2+: attributive ADJ goes into the cluster matching its
            -- slot. Insertion order is preserved within the cluster (the
            -- generated stream is in source-token order), so adjectives
            -- naturally appear between the determiner and the noun:
            --   "the big dog" -> [DET=the, ADJ_ATTR=big, NOUN=dog]
            --   subject cluster: [the->o, big->büyük, dog->köpek]
            --   output: "Büyük köpek" (DET drops; ADJ + NOUN in order)
            if g.slot == "subject" then
                table.insert(subjectNouns, g)
            else
                table.insert(objectPhrases, g)
            end
        elseif g.kind == "CONJ" then
            -- 8.10.3+: CONJ routes to the cluster matching its conjuncts.
            -- For NP coordination ("X and Y" with X,Y in subject/object),
            -- CONJ goes into that same cluster. For VP coordination
            -- ("ran and shot"), CONJ goes alongside the predicate.
            if g.cluster == "subject" then
                table.insert(subjectNouns, g)
            elseif g.cluster == "predicate" then
                -- Saved with continuations and emitted between predicates
                table.insert(predicateContinuations, g)
            else
                table.insert(objectPhrases, g)
            end
        elseif g.kind == "NOUN" then
            table.insert(objectPhrases, g)
        elseif g.kind == "VERBAL_NOUN" then
            -- 9.0+: gerund-complement of matrix verb routes to object
            -- cluster (placed immediately before the predicate, where
            -- Turkish direct objects belong).
            table.insert(objectPhrases, g)
        elseif g.kind == "UNKNOWN" then
            table.insert(objectPhrases, g)
        end
    end

    local parts = {}
    for _, n in ipairs(interjections) do
        if n.text and n.text ~= "" then table.insert(parts, n.text) end
    end
    -- 8.16.x: sentence-initial temporal adverbs (yesterday/today/tomorrow)
    -- go right after interjections so they appear at sentence start.
    for _, n in ipairs(initialAdverbs) do
        if n.text and n.text ~= "" then table.insert(parts, n.text) end
    end
    for _, n in ipairs(subjectNouns) do
        if n.text and n.text ~= "" then table.insert(parts, n.text) end
    end
    for _, n in ipairs(objectPhrases) do
        if n.text and n.text ~= "" then table.insert(parts, n.text) end
    end
    -- Adverbs go between objects and the predicate. In Turkish SOV order,
    -- this puts "her zaman koşarım" (always I-run), "hızlıca koştu" (he
    -- ran quickly), etc., which is the unmarked position for time,
    -- frequency, and manner adverbs. Degree adverbs (very/quite) modifying
    -- a copular adjective predicate ideally would go between the adjective
    -- and the copular suffix, but the simpler "before predicate" rule
    -- still produces intelligible output ("evim çok güzel" vs the strict
    -- "çok güzel evim" -- both convey the same meaning in chat).
    for _, n in ipairs(adverbs) do
        if n.text and n.text ~= "" then table.insert(parts, n.text) end
    end
    if predicate and predicate.text then table.insert(parts, predicate.text) end
    -- 8.10.3+: predicate continuations (second verb in coordination,
    -- plus CONJ between them) emitted in source order after the main
    -- predicate. "Koştum ve vurdum" = past 1sg run + ve + past 1sg shoot.
    for _, c in ipairs(predicateContinuations) do
        if c.text and c.text ~= "" then table.insert(parts, c.text) end
    end
    if existentialParticle and existentialParticle.text then
        table.insert(parts, existentialParticle.text)
    end

    -- Question particle at the very end (before terminator). For bare mode,
    -- harmony is resolved against the actually-emitted last word -- which
    -- might be the verb's full conjugation ("koştun" -> mu) or the existential
    -- particle ("var" -> mı). For copular-agr mode, the particle text was
    -- pre-computed during generate from the predicate stem + person/number.
    if questionParticle then
        local text = questionParticle.text
        if not text and questionParticle.mode == "bare" and #parts > 0 then
            local lastWord = parts[#parts]
            text = Morphology.applyQuestionParticleBare(lastWord)
        end
        if text and text ~= "" then
            table.insert(parts, text)
        end
    end

    if #parts == 0 then return "", {} end

    -- Capitalize first character (Turkish-aware)
    parts[1] = capitalizeTurkish(parts[1])

    return table.concat(parts, " ") .. (terminator or ""), parts
end

M.surface = surface

-- ---------------------------------------------------------------------------
-- Fragment helpers for the "spirit over literalness" path (8.9.12 "Gist").
-- ---------------------------------------------------------------------------
--
-- When the input has multiple comma- or semicolon-separated clauses, each
-- clause is treated as an independent translation unit. Clauses that fail
-- to translate cleanly are DROPPED rather than producing partial-with-leak
-- output for the whole sentence. The surviving clauses are reassembled
-- with commas. This trades literal fidelity for legibility: "Damn, the
-- cave is dark" becomes "Mağara karanlık." (Damn dropped) instead of
-- "Damn mağara karanlık." (Damn leaked).
--
-- Single-clause inputs (no comma) take the existing whole-input path,
-- including Hail's INTERJ-leading-sentence support.

local function fragmentInput(text)
    text = text:match("^%s*(.-)%s*$") or text
    -- Preserve the sentence-final terminator; restore after assembly.
    local terminator = ""
    local lastChar = text:sub(-1)
    if lastChar == "." or lastChar == "?" or lastChar == "!" then
        terminator = lastChar
        text = text:sub(1, -2)
    end
    local fragments = {}
    local current = ""
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "," or ch == ";" then
            local trimmed = current:match("^%s*(.-)%s*$") or current
            if trimmed ~= "" then table.insert(fragments, trimmed) end
            current = ""
        else
            current = current .. ch
        end
    end
    local trimmed = current:match("^%s*(.-)%s*$") or current
    if trimmed ~= "" then table.insert(fragments, trimmed) end
    return fragments, terminator
end

-- ASCII-only lowercase of the first character. Turkish-letter starts
-- (İ, Ş, Ç, Ö, Ü, Ğ) need Turkish-aware case mapping which isn't
-- available here; those stay as-is, which is rare enough not to matter
-- for v1 fragmented output.
local function lowercaseFirstASCII(s)
    if s == nil or s == "" then return s end
    local b = s:byte(1)
    if b and b >= 65 and b <= 90 then
        return string.char(b + 32) .. s:sub(2)
    end
    return s
end

-- ---------------------------------------------------------------------------
-- 6. Public end-to-end: translate
-- ---------------------------------------------------------------------------

function M.translate(text)
    if type(text) ~= "string" or text == "" then
        return { ok = false, errors = {"empty input"} }
    end

    -- Phrasebook fast-path FIRST: try the input verbatim before any
    -- normalization. The phrasebook is for fixed idioms that may include
    -- contractions ("you're welcome", "what's up") which the productive
    -- pipeline would normalize away.
    do
        local pbEntry = Phrasebook.lookup(text)
        if pbEntry then
            return {
                ok        = true,
                output    = pbEntry.tr,
                trace     = { path = "phrasebook", phrasebook_id = pbEntry.id },
                errors    = {},
                direction = "en-to-tr",
            }
        end
    end

    -- Preprocess: contraction expansion, quote normalization, whitespace
    text = normalize(text)
    -- 9.0+: Yes/no perfect-question rewrite. Fires before control normalize
    -- so "Have you ever seen X?" -> "Did you ever seen X?" -> engine
    -- handles as yes/no past question.
    text = normalizeYesNoPerfect(text)
    -- Then multi-word control patterns (going to X, want to X, need to X,
    -- have to X, etc.) -> single-modal equivalents. Requires single-word
    -- contractions already expanded (so "gonna" became "going to" first).
    text = normalizeControl(text)
    if text == "" then
        return { ok = false, errors = {"empty input after normalization"} }
    end

    -- Try phrasebook again on the normalized form (catches cases where the
    -- user typed an expanded form but the phrasebook has the same form).
    do
        local pbEntry = Phrasebook.lookup(text)
        if pbEntry then
            return {
                ok        = true,
                output    = pbEntry.tr,
                trace     = { path = "phrasebook", phrasebook_id = pbEntry.id },
                errors    = {},
                direction = "en-to-tr",
            }
        end
    end

    -- 8.9.20+: phrasebook PREFIX matching. If the input starts with a
    -- multi-word phrasebook entry, treat that entry as a translation
    -- unit and let the productive engine handle the remainder. Compose
    -- by placing the productive output first (preserving Turkish SOV
    -- order: "the lamp turn-off" -> "Lambayı kapat") and the phrasebook
    -- translation at the end with capitalization + terminator stripped
    -- for mid-sentence inlining.
    --
    -- Examples:
    --   "turn off the lamp"   -> productive(the lamp) + " " + lc(Kapat.) = "Lambayı kapat"
    --   "stand up everyone"   -> productive(everyone) + " " + lc(Kalk.)
    --
    -- Conservative: only fires when the prefix entry is multi-word (so
    -- single-word phrasebook entries don't shadow productive paths) and
    -- only when there's meaningful remainder text to translate. If the
    -- remainder produces nothing useful, we fall through to the normal
    -- productive path so the user doesn't get a worse answer than before.
    do
        local prefMatch = Phrasebook.lookupPrefix(text)
        if prefMatch and prefMatch.matchStr and prefMatch.matchStr:find(" ", 1, true) then
            -- Multi-word prefix match found. Extract the remainder.
            local remainder = text:sub(prefMatch.matchLen + 1)
            -- Strip leading whitespace and any terminator the prefix
            -- might have already stripped.
            remainder = remainder:match("^%s*(.-)%s*$") or remainder
            -- Preserve the input's final terminator (if any) for the
            -- composed output.
            local outTerm = ""
            local lastCh = remainder:sub(-1)
            if lastCh == "." or lastCh == "?" or lastCh == "!" then
                outTerm = lastCh
                remainder = remainder:sub(1, -2):match("^%s*(.-)%s*$") or remainder
            else
                local origLast = text:sub(-1)
                if origLast == "." or origLast == "?" or origLast == "!" then
                    outTerm = origLast
                end
            end
            if remainder ~= "" then
                -- Recursively translate the remainder via the productive path.
                local rem = M.translate(remainder)
                -- Helper: detect if the remainder output is a clean Turkish
                -- translation (no leaked English ASCII words). Verb-less NP
                -- fragments like "the lamp" return ok=false with leaked
                -- output "The lamp"; we can't compose with that, so we
                -- fall back to emitting just the phrasebook translation
                -- (marked partial so the chat-hook can flag it).
                local function isClean(r)
                    if not (r and r.ok and r.output and r.output ~= "") then
                        return false
                    end
                    if r.partial then return false end
                    -- Leak detection: does the output contain any of the
                    -- input's content words? "the lamp" -> "The lamp" has
                    -- "the" and "lamp" both leaked. "everyone" -> "Herkes."
                    -- doesn't contain "everyone" -- clean.
                    local outLower = r.output:lower()
                    for inWord in remainder:lower():gmatch("%S+") do
                        local stripped = inWord:gsub("[%.%?%!%,]+$", "")
                        if #stripped >= 2 and outLower:find(stripped, 1, true) then
                            return false
                        end
                    end
                    return true
                end

                -- Build the inlined phrasebook translation (lowercase first
                -- char + no terminal punctuation, ready for embedding).
                local function inlinePbTr(pbTr)
                    pbTr = pbTr:gsub("[%.%?%!]+$", "")
                    local TR_LOWER = {
                        ["\196\176"] = "i",         -- İ -> i
                        ["I"]        = "\196\177",  -- I -> ı
                        ["\195\135"] = "\195\167",  -- Ç -> ç
                        ["\197\158"] = "\197\159",  -- Ş -> ş
                        ["\196\158"] = "\196\159",  -- Ğ -> ğ
                        ["\195\150"] = "\195\182",  -- Ö -> ö
                        ["\195\156"] = "\195\188",  -- Ü -> ü
                    }
                    if pbTr ~= "" then
                        local sz = utf8charLen(pbTr)
                        local first = pbTr:sub(1, sz)
                        local rest = pbTr:sub(sz + 1)
                        local lowered = TR_LOWER[first] or first:lower()
                        pbTr = lowered .. rest
                    end
                    return pbTr
                end

                if isClean(rem) then
                    -- Compose: productive (object NP) first, phrasebook
                    -- (verb) at the end -- Turkish SOV order.
                    local pbInline = inlinePbTr(prefMatch.entry.tr or "")
                    local remOut = (rem.output or ""):gsub("[%.%?%!]+$", "")
                    local composed = remOut .. " " .. pbInline .. outTerm
                    return {
                        ok        = true,
                        partial   = false,
                        coverage  = 1,  -- 9.0+ Mosaic: phrasebook-prefix + clean remainder = full coverage
                        output    = composed,
                        trace     = {
                            path = "phrasebook_prefix",
                            phrasebook_id = prefMatch.entry.id,
                            remainder = remainder,
                            remainder_trace = rem.trace,
                        },
                        errors    = rem.errors or {},
                        direction = "en-to-tr",
                    }
                else
                    -- Remainder couldn't translate cleanly (typically a
                    -- verb-less NP fragment like "the lamp"). Emit the
                    -- phrasebook translation alone, mark partial. The
                    -- output is semantically correct for the verb/idiom
                    -- the phrasebook matched, just missing the object.
                    -- Better than letting the regular productive path
                    -- produce mixed-language garbage ("Off lambayı döndü").
                    return {
                        ok        = true,
                        partial   = true,
                        -- 9.0+ Mosaic: even when the remainder failed,
                        -- the phrasebook portion IS the dominant content
                        -- and yields a complete Turkish utterance ("im
                        -- dying of thirst" -> "Ölüyorum" — phrasebook
                        -- handles "im dying", "of thirst" lost). Mark
                        -- coverage=1 so Mosaic accepts the output rather
                        -- than passing through English. The partial flag
                        -- still informs the caller.
                        coverage  = 1,
                        output    = prefMatch.entry.tr,
                        trace     = {
                            path = "phrasebook_prefix_partial",
                            phrasebook_id = prefMatch.entry.id,
                            remainder = remainder,
                            remainder_failed = true,
                        },
                        errors    = {
                            "could not translate remainder: '" .. remainder .. "'",
                        },
                        direction = "en-to-tr",
                    }
                end
            end
        end
    end

    -- Fragment-and-salvage (8.9.12 Gist). When the input has multiple
    -- comma/semicolon-separated clauses, recurse per fragment and reassemble.
    -- Clauses that produce only partial output get dropped, preserving the
    -- legibility of the surviving clauses. Single-fragment inputs (no
    -- delimiter) fall through to the existing whole-input pipeline.
    local fragments, fragTerminator = fragmentInput(text)
    if #fragments > 1 then
        local outputs = {}
        local dropped = {}
        local errors  = {}
        for _, frag in ipairs(fragments) do
            local r = M.translate(frag)
            if r.ok and not r.partial and r.output and r.output ~= "" then
                -- Strip fragment-internal terminator; we'll add the
                -- original outer terminator after assembly.
                local fragTr = r.output:gsub("[%.%!%?]+$", "")
                table.insert(outputs, fragTr)
            else
                table.insert(dropped, frag)
                if r.errors then
                    for _, e in ipairs(r.errors) do
                        table.insert(errors,
                            "fragment '" .. frag .. "': " .. tostring(e))
                    end
                end
                if (not r.ok or not r.output or r.output == "") and r.partial == nil then
                    -- Cover the case where the fragment had no errors but
                    -- still failed to produce output (e.g. empty after
                    -- normalize). Add a generic note.
                    table.insert(errors,
                        "fragment '" .. frag .. "': no usable output")
                end
            end
        end

        if #outputs > 0 then
            -- Lowercase non-first fragments since Turkish doesn't capitalize
            -- after commas. (ASCII-only; Turkish-letter starts stay as-is.)
            for i = 2, #outputs do
                outputs[i] = lowercaseFirstASCII(outputs[i])
            end
            return {
                ok      = true,
                partial = #dropped > 0,
                output  = table.concat(outputs, ", ") .. fragTerminator,
                errors  = errors,
                trace   = {
                    path      = #dropped > 0 and "fragmented_partial" or "fragmented",
                    fragments = fragments,
                    dropped   = dropped,
                },
                direction = "en-to-tr",
            }
        end
        -- All fragments dropped: fall through to whole-input productive
        -- (which produces a partial-with-leak via the Adage permissive
        -- ok semantics). At least the user sees something.
    end

    local tokens, terminator = tokenize(text)
    if #tokens == 0 then
        return { ok = false, errors = {"no tokens after tokenize"} }
    end

    local analyzed, analyzeErrors = analyze(tokens, terminator)
    local transferred = transfer(analyzed)
    local generated   = generate(transferred)
    local output, parts = surface(generated, terminator)

    -- Permissive ok: if the engine produced ANY useful Turkish (output is
    -- non-empty AND at least one input token resolved to a recognized POS),
    -- we surface it even when some tokens leaked through as English. The
    -- chat-hook reads `ok` to decide whether to display, and `partial` to
    -- optionally mark the line as best-effort. `errors` retains the
    -- per-token diagnostic ("no lexicon entry: 'damn'") so the gap is
    -- still recoverable for testers.
    --
    -- 9.0+ Mosaic: also expose per-token coverage. uncoveredTokens is the
    -- list of original-surface forms (in source order) whose role is
    -- UNKNOWN at the end of analysis -- i.e. tokens the engine had no
    -- handler for. Used by the clause-level mosaic wrapper to decide
    -- whether to emit Turkish or pass the clause through as English.
    local resolved = 0
    local uncoveredTokens = {}
    for _, item in ipairs(analyzed) do
        if item.role ~= "UNKNOWN" then
            resolved = resolved + 1
        elseif item.entry and item.entry.tr and item.entry.tr ~= "" then
            -- 9.0+ Mosaic: UNKNOWN role but lex tr available. The
            -- transfer emits the Turkish form anyway (graceful
            -- degradation for known WH/DET/etc that didn't fit any
            -- construction). Count as resolved for coverage so the
            -- Mosaic wrapper doesn't reject the clause as too-leaky.
            resolved = resolved + 1
        elseif item.surface and item.surface:match("^[%d%.,:%-]+$") then
            -- 9.0+ Mosaic: pure-digit tokens (and digit-only sequences
            -- with separators like "1,000", "3.5", "10:30") are
            -- language-neutral. They pass through unchanged and should
            -- not count as leaks — otherwise sentences like "I have 3
            -- of them" reach the threshold via the digit alone. The
            -- surface is preserved in output already by the catchall
            -- passthrough; this just stops uncovered-counting.
            resolved = resolved + 1
        elseif item.entry and item.entry.tr == ""
            and (item.entry.pos == "DET" or item.entry.pos == "PREP") then
            -- 9.0+ Mosaic: function words with intentionally-empty tr
            -- ("the"/"a"/"an"/"of"). Turkish has no definite articles and
            -- some English preps map to suffix-only morphology with no
            -- surface word. When the engine knows the POS but a role
            -- couldn't be assigned (e.g. "of" not paired into a
            -- genitive Pass 2.4), the token's correct Turkish equivalent
            -- IS the empty string. Count as resolved so the clause isn't
            -- rejected for legitimate function-word silences. The surface
            -- still appears in output via the unmatched-passthrough path,
            -- which is a separate bug we tolerate for now.
            resolved = resolved + 1
        else
            table.insert(uncoveredTokens, item.surface)
        end
    end
    local hasOutput = output ~= nil and output ~= ""
    local total     = #analyzed
    local coverage  = (total > 0) and (resolved / total) or 0

    return {
        ok               = hasOutput and resolved > 0,
        partial          = resolved < total,
        coverage         = coverage,
        uncoveredTokens  = uncoveredTokens,
        output           = output,
        trace            = {
            path        = "productive",
            tokens      = tokens,
            terminator  = terminator,
            analyzed    = analyzed,
            transferred = transferred,
            generated   = generated,
            parts       = parts,
        },
        errors  = analyzeErrors,
    }
end

-- ---------------------------------------------------------------------------
-- Reverse direction: Turkish -> English.
--
-- v2 scope: phrasebook lookup only. Productive reverse (parsing inflected
-- Turkish back into stem + suffix chain via the spec's section 14.2 Turkish
-- morphological analyzer, then reverse-lex and English generation) is
-- multi-session work deferred to v3.
--
-- The asymmetry is principled, not lazy: per the spec's design philosophy
-- ("Asymmetric quality is honest, not lazy"), Turkish-to-English is the
-- less polished direction because the recipient (English reader) tolerates
-- non-fluent English without losing comprehension. v3 will produce
-- English output that may read as machine-translated but remains
-- understandable; v2 only handles the easy phrasebook cases.
-- ---------------------------------------------------------------------------

function M.translateReverse(text)
    if type(text) ~= "string" or text == "" then
        return { ok = false, errors = {"empty input"}, direction = "tr-to-en" }
    end

    -- Phrasebook fast-path (exact-match TR lookup)
    local pbEntry = Phrasebook.lookupReverse(text)
    if pbEntry then
        local term = text:match("[%.!%?]$") or "."
        local en = pbEntry.en:sub(1, 1):upper() .. pbEntry.en:sub(2)
        return {
            ok        = true,
            output    = en .. term,
            trace     = { path = "phrasebook_reverse", phrasebook_id = pbEntry.id },
            errors    = {},
            direction = "tr-to-en",
        }
    end

    -- Productive reverse: morphological analysis + English generation
    local r = ReverseParser.parseSentence(text)
    if r.ok then
        return {
            ok        = true,
            output    = r.output,
            trace     = {
                path           = "productive_reverse",
                analyzedTokens = r.analyzedTokens,
                terminator     = r.terminator,
            },
            errors    = {},
            direction = "tr-to-en",
        }
    end

    return {
        ok        = false,
        output    = nil,
        errors    = r.errors or {"productive reverse direction failed"},
        trace     = {
            path           = "productive_reverse_failed",
            analyzedTokens = r.analyzedTokens,
        },
        direction = "tr-to-en",
    }
end

-- ---------------------------------------------------------------------------
-- Language detection.
--
-- Heuristic for deciding whether input is English or Turkish. Used by
-- translateAuto and by the in-chat /translate command, where the user
-- types a single line and expects the engine to figure out which direction
-- they want.
--
-- Signals (in priority order):
--   1. Turkish-specific diacritics (ç ş ğ ö ü ı İ etc.) -> strong Turkish
--      signal. If present, classify as Turkish.
--   2. Token-by-token lexicon hit rate. Each token is checked against the
--      English lexicon (Lexicon.lookup) and Turkish lazy lookup
--      (Lexicon.lookupTurkishLazy). Whichever side scores more matches
--      wins. Ties default to English (the more common input).
--   3. Empty / non-textual input -> "unknown".
--
-- LIMITATIONS:
--   - Inflected Turkish forms like "içiyorum" don't match the bare lemma,
--     so lexicon hit rate underweights Turkish. The diacritic signal
--     mostly compensates. Lazy Turkish input (no diacritics) followed by
--     inflection is the hardest case; we fall through to forward
--     translation and let the engine's UNKNOWN report flag the mismatch.
--   - English words that happen to be valid Turkish lemmas (e.g., "park",
--     "market") will tie or favour Turkish. Defaulting to English on ties
--     is the safer call for the typical English-speaking tester.
-- ---------------------------------------------------------------------------

local TURKISH_DIACRITICS = {
    ["\195\167"] = true, ["\195\135"] = true,  -- ç Ç
    ["\197\159"] = true, ["\197\158"] = true,  -- ş Ş
    ["\196\159"] = true, ["\196\158"] = true,  -- ğ Ğ
    ["\195\182"] = true, ["\195\150"] = true,  -- ö Ö
    ["\195\188"] = true, ["\195\156"] = true,  -- ü Ü
    ["\196\177"] = true, ["\196\176"] = true,  -- ı İ
}

local function hasTurkishDiacritics(text)
    for ch in utf8chars(text) do
        if TURKISH_DIACRITICS[ch] then return true end
    end
    return false
end

function M.detectLanguage(text)
    if type(text) ~= "string" or text == "" then return "unknown" end

    -- Strong signal: Turkish-specific diacritics
    if hasTurkishDiacritics(text) then return "tr" end

    -- Strong signal: phrasebook match in either direction
    if Phrasebook.lookup(text) then return "en" end
    if Phrasebook.lookupReverse(text) then return "tr" end

    -- Token-by-token analysis. English side: lexicon lookup. Turkish side:
    -- lexicon lookup OR morphological analysis (so inflected forms like
    -- "yorgunum", "oynuyor" still register as Turkish).
    local normalized = normalize(text)
    local tokens = {}
    for word in normalized:gmatch("[%w']+") do
        table.insert(tokens, word:lower())
    end
    if #tokens == 0 then return "unknown" end

    local enHits, trHits = 0, 0
    for _, tok in ipairs(tokens) do
        if Lexicon.lookup(tok) then enHits = enHits + 1 end
        if Lexicon.lookupTurkishLazy(tok) then
            trHits = trHits + 1
        else
            -- Try morphological analysis -- catches inflected forms
            if ReverseParser.analyzeToken(tok) then
                trHits = trHits + 1
            end
        end
    end

    if enHits > trHits then return "en"
    elseif trHits > enHits then return "tr"
    else return "en" end  -- tie -> default English
end

-- ---------------------------------------------------------------------------
-- translateAuto: detect direction and dispatch.
--
-- Returns the same shape as translate / translateReverse, with an extra
-- `detected_language` field for transparency. If detection picks the wrong
-- direction (e.g., English heavy in Turkish lemmas), caller can override
-- by calling translate / translateReverse directly.
-- ---------------------------------------------------------------------------

function M.translateAuto(text)
    if type(text) ~= "string" or text == "" then
        return { ok = false, errors = {"empty input"}, direction = "unknown" }
    end
    local lang = M.detectLanguage(text)
    local r
    if lang == "tr" then
        r = M.translateReverse(text)
    else
        -- 9.0+ Mosaic: route English through the Mosaic clause-splitter
        -- instead of calling the engine directly. The engine alone can
        -- only translate a sentence as a single unit, so chat messages
        -- with multiple clauses ("Oh boy, I hope I don't immediately
        -- break the translator") lose everything after the first clause
        -- whenever the engine's phrasebook prefix-matches a leading
        -- fragment. Mosaic splits on commas/semicolons/ellipses first,
        -- then calls the engine per clause, and reassembles.
        --
        -- This was the original architectural intent of 9.0 Mosaic but
        -- the dispatch wasn't wired here, so all the clause-splitting,
        -- threshold tuning, stranded-modal merge, vocative-split, and
        -- repeated-token collapse work was bypassed in production. Wire
        -- it now.
        --
        -- Shape compatibility: Mosaic.translate returns
        -- { ok, output, clauses, ... }. Callers expect translate's shape
        -- which has output/trace/errors. Mosaic's shape is a superset —
        -- it always has output and ok, so existing callers (TAZC_Server)
        -- continue to work.
        local Mosaic = require("TAZC_TranslateMosaic")
        r = Mosaic.translate(text)
        -- Make sure the returned shape has the fields downstream expects.
        -- Mosaic returns { output, errors, clauses, turkish_pct, coverage }
        -- but callers check `r.ok and r.output`. Synthesize `ok` from the
        -- presence of any output.
        if r.errors == nil then r.errors = {} end
        if r.direction == nil then r.direction = "en-to-tr" end
        if r.ok == nil then
            r.ok = (r.output ~= nil and r.output ~= "")
        end
    end
    r.detected_language = lang
    return r
end

return M
