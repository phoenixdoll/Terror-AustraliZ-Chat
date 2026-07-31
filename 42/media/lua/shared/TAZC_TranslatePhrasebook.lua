-- ============================================================================
-- TAZC_TranslatePhrasebook -- fixed-phrase lookup for idiomatic translations.
--
-- Sibling of the productive path per TRANSLATOR_SPEC.md section 9: idioms,
-- fixed greetings, and conventional expressions whose meaning does not
-- decompose compositionally go here. The translator engine consults the
-- phrasebook BEFORE the productive pipeline; on a hit, the engine's output
-- is the phrasebook entry's tr field and the productive layers are
-- bypassed entirely.
--
-- v2 limitation: exact full-sentence match only. Within-sentence collocation
-- matching (e.g., "buy groceries" appearing inside a longer sentence) is
-- reserved for v3 once the spec's pattern-match grammar is implemented.
--
-- Normalisation rules:
--   - Input is lowercased before lookup
--   - Trailing terminator (. ? !) is stripped before lookup but preserved
--     in the output (the entry's tr text already carries the appropriate
--     terminator)
--   - Leading and trailing whitespace are stripped
--
-- Entries follow spec section 9. id is stable forever; never renamed.
-- ============================================================================

local M = {}

M.VERSION = "0.1"

M.entries = {
    -- ----- Greetings -----
    { id = "ph.001", en = "hello",          tr = "Merhaba.",        direction = "both", tags = {"greeting"} },
    { id = "ph.002", en = "hi",             tr = "Selam!",          direction = "both", tags = {"greeting", "informal"} },
    { id = "ph.003", en = "good morning",   tr = "G\195\188nayd\196\177n.",       direction = "both", tags = {"greeting", "time_of_day"} },
    { id = "ph.004", en = "good evening",   tr = "\196\176yi ak\197\159amlar.",   direction = "both", tags = {"greeting", "time_of_day"} },
    { id = "ph.005", en = "good night",     tr = "\196\176yi geceler.",    direction = "both", tags = {"greeting", "time_of_day"} },

    -- ----- Farewells -----
    { id = "ph.006", en = "goodbye",        tr = "Ho\197\159\195\167akal.",       direction = "both", tags = {"farewell"} },
    { id = "ph.007", en = "see you later",  tr = "G\195\182r\195\188\197\159\195\188r\195\188z.",      direction = "both", tags = {"farewell"} },

    -- ----- Courtesy -----
    { id = "ph.008", en = "thank you",      tr = "Te\197\159ekk\195\188r ederim.", direction = "both", tags = {"courtesy"} },
    { id = "ph.009", en = "you're welcome", tr = "Rica ederim.",    direction = "both", tags = {"courtesy"} },
    { id = "ph.010", en = "sorry",          tr = "\195\150z\195\188r dilerim.",   direction = "both", tags = {"courtesy", "apology"} },

    -- ----- Light extensions of the corpus (commonly-used phrases the
    --       PoC should handle even if not corpus-attested). These will be
    --       sign-off-reviewed alongside the corpus pairs. -----
    { id = "ph.011", en = "thanks",         tr = "Sa\196\159 ol.",         direction = "both", tags = {"courtesy", "informal"} },
    { id = "ph.012", en = "please",         tr = "L\195\188tfen.",         direction = "both", tags = {"courtesy"} },
    { id = "ph.013", en = "excuse me",      tr = "Affedersiniz.",   direction = "both", tags = {"courtesy"} },
    { id = "ph.014", en = "yes",            tr = "Evet.",           direction = "both", tags = {"response"} },
    { id = "ph.015", en = "no",             tr = "Hay\196\177r.",          direction = "both", tags = {"response"} },

    -- ----- 8.9.11 Adage: bulk phrasebook expansion (conversational,
    -- imperative, question, emergency, state, time). These are mostly
    -- whole-sentence idioms or constructions the productive engine does
    -- not yet compose cleanly (imperatives, questions). The phrasebook
    -- short-circuits in front of the productive pipeline, so they ship
    -- correct output today and become regressions to protect when the
    -- engine ships eventually do learn imperative mood and WH-questions.

    -- ----- Greetings and conversational responses -----
    { id = "ph.016", en = "morning",        tr = "G\195\188nayd\196\177n.",       direction = "forward", tags = {"greeting", "time_of_day", "informal"} },
    { id = "ph.017", en = "evening",        tr = "\196\176yi ak\197\159amlar.",   direction = "forward", tags = {"greeting", "time_of_day", "informal"} },
    { id = "ph.018", en = "how are you",    tr = "Nas\196\177ls\196\177n?",       direction = "both", tags = {"greeting", "question"} },
    { id = "ph.019", en = "i'm fine",       tr = "\196\176yiyim.",         direction = "forward", tags = {"response", "state"} },
    { id = "ph.020", en = "i'm okay",       tr = "\196\176yiyim.",         direction = "forward", tags = {"response", "state"} },

    -- ----- Affirmations and discourse responses -----
    { id = "ph.021", en = "of course",      tr = "Tabii ki.",       direction = "both", tags = {"response"} },
    { id = "ph.022", en = "sure",           tr = "Tabii.",          direction = "both", tags = {"response", "informal"} },
    { id = "ph.023", en = "definitely",     tr = "Kesinlikle.",     direction = "both", tags = {"response"} },
    { id = "ph.024", en = "maybe",          tr = "Belki.",          direction = "both", tags = {"response"} },
    { id = "ph.025", en = "i don't know",   tr = "Bilmiyorum.",     direction = "both", tags = {"response"} },
    { id = "ph.026", en = "i don't understand", tr = "Anlam\196\177yorum.", direction = "both", tags = {"response"} },
    { id = "ph.027", en = "no problem",     tr = "Sorun de\196\159il.",    direction = "both", tags = {"response"} },
    { id = "ph.028", en = "alright",        tr = "Tamam.",          direction = "both", tags = {"response", "informal"} },
    { id = "ph.029", en = "exactly",        tr = "Aynen.",          direction = "both", tags = {"response"} },

    -- ----- Imperatives (engine-gap workaround until Ship 3) -----
    { id = "ph.030", en = "stop",           tr = "Dur!",            direction = "both", tags = {"imperative", "command"} },
    { id = "ph.031", en = "wait",           tr = "Bekle!",          direction = "both", tags = {"imperative", "command"} },
    { id = "ph.032", en = "run",            tr = "Ka\195\167!",            direction = "both", tags = {"imperative", "command", "emergency"} },
    { id = "ph.033", en = "hurry",          tr = "Acele et!",       direction = "both", tags = {"imperative", "command"} },
    { id = "ph.034", en = "hide",           tr = "Saklan!",         direction = "both", tags = {"imperative", "command"} },
    { id = "ph.035", en = "look",           tr = "Bak!",            direction = "both", tags = {"imperative", "command"} },
    { id = "ph.036", en = "listen",         tr = "Dinle!",          direction = "both", tags = {"imperative", "command"} },
    { id = "ph.037", en = "help",           tr = "Yard\196\177m et!",      direction = "forward", tags = {"imperative", "command", "emergency"} },
    { id = "ph.038", en = "come here",      tr = "Buraya gel!",     direction = "both", tags = {"imperative", "command"} },
    { id = "ph.039", en = "come on",        tr = "Hadi!",           direction = "both", tags = {"imperative", "informal"} },
    { id = "ph.040", en = "let's go",       tr = "Gidelim!",        direction = "both", tags = {"imperative"} },
    { id = "ph.041", en = "watch out",      tr = "Dikkat!",         direction = "both", tags = {"imperative", "warning"} },
    { id = "ph.042", en = "get down",       tr = "E\196\159il!",           direction = "both", tags = {"imperative", "command"} },
    { id = "ph.043", en = "stay back",      tr = "Geri dur!",       direction = "both", tags = {"imperative", "command"} },
    { id = "ph.044", en = "follow me",      tr = "Beni takip et!",  direction = "both", tags = {"imperative", "command"} },
    { id = "ph.045", en = "don't move",     tr = "K\196\177p\196\177rdama!",      direction = "both", tags = {"imperative", "command"} },
    { id = "ph.046", en = "calm down",      tr = "Sakin ol!",       direction = "both", tags = {"imperative", "command"} },
    { id = "ph.047", en = "shut up",        tr = "Sus!",            direction = "both", tags = {"imperative", "informal"} },
    { id = "ph.048", en = "quiet",          tr = "Sessiz ol!",      direction = "both", tags = {"imperative", "command"} },
    { id = "ph.049", en = "hold on",        tr = "Bekle bir.",      direction = "both", tags = {"imperative"} },

    -- ----- Emergency / combat -----
    { id = "ph.050", en = "help me",        tr = "Yard\196\177m et!",      direction = "both", tags = {"emergency"} },
    { id = "ph.051", en = "i'm hit",        tr = "Vuruldum!",       direction = "forward", tags = {"emergency", "state"} },
    { id = "ph.052", en = "i'm bitten",     tr = "Is\196\177r\196\177ld\196\177m!",      direction = "forward", tags = {"emergency", "state"} },
    { id = "ph.053", en = "i'm bleeding",   tr = "Kan\196\177yorum!",      direction = "forward", tags = {"emergency", "state"} },
    { id = "ph.054", en = "i need help",    tr = "Yard\196\177ma ihtiyac\196\177m var!", direction = "both", tags = {"emergency"} },
    { id = "ph.055", en = "cover me",       tr = "Beni koru!",      direction = "both", tags = {"emergency", "imperative"} },
    { id = "ph.056", en = "behind you",     tr = "Arkanda!",        direction = "both", tags = {"warning"} },

    -- ----- States / feelings -----
    { id = "ph.057", en = "i'm hungry",     tr = "A\195\167\196\177m.",           direction = "forward", tags = {"state"} },
    { id = "ph.058", en = "i'm thirsty",    tr = "Susad\196\177m.",        direction = "forward", tags = {"state"} },
    { id = "ph.059", en = "i'm cold",       tr = "\195\156\197\159\195\188yorum.",       direction = "forward", tags = {"state"} },
    { id = "ph.060", en = "i'm tired",      tr = "Yorgunum.",       direction = "forward", tags = {"state"} },
    { id = "ph.061", en = "i'm sick",       tr = "Hastay\196\177m.",       direction = "forward", tags = {"state"} },
    { id = "ph.062", en = "i'm scared",     tr = "Korkuyorum.",     direction = "forward", tags = {"state"} },
    { id = "ph.063", en = "i'm ready",      tr = "Haz\196\177r\196\177m.",        direction = "forward", tags = {"state"} },
    { id = "ph.064", en = "i'm lost",       tr = "Kayboldum.",      direction = "forward", tags = {"state"} },
    { id = "ph.065", en = "i'm safe",       tr = "G\195\188vendeyim.",     direction = "forward", tags = {"state"} },
    { id = "ph.066", en = "i'm here",       tr = "Buraday\196\177m.",      direction = "forward", tags = {"state"} },

    -- ----- Questions (engine-gap workaround until Ship 4) -----
    { id = "ph.067", en = "are you ok",     tr = "\196\176yi misin?",      direction = "both", tags = {"question"} },
    { id = "ph.068", en = "what is that",   tr = "O ne?",           direction = "both", tags = {"question"} },
    { id = "ph.069", en = "where are you",  tr = "Neredesin?",      direction = "both", tags = {"question"} },
    { id = "ph.070", en = "what's wrong",   tr = "Sorun ne?",       direction = "both", tags = {"question"} },
    { id = "ph.071", en = "what was that",  tr = "O neydi?",        direction = "both", tags = {"question"} },
    { id = "ph.072", en = "is anyone there", tr = "Kimse var m\196\177?",  direction = "both", tags = {"question"} },
    { id = "ph.073", en = "what happened",  tr = "Ne oldu?",        direction = "both", tags = {"question"} },
    { id = "ph.074", en = "really",         tr = "Ger\195\167ekten mi?",   direction = "both", tags = {"question", "informal"} },

    -- ----- Polite / parting -----
    { id = "ph.075", en = "take care",      tr = "Kendine iyi bak.", direction = "both", tags = {"farewell", "courtesy"} },
    { id = "ph.076", en = "be careful",     tr = "Dikkatli ol.",    direction = "both", tags = {"courtesy", "warning"} },
    { id = "ph.077", en = "good luck",      tr = "\196\176yi \197\159anslar.",    direction = "both", tags = {"courtesy"} },
    { id = "ph.078", en = "see you tomorrow", tr = "Yar\196\177n g\195\182r\195\188\197\159\195\188r\195\188z.", direction = "both", tags = {"farewell"} },
    { id = "ph.079", en = "see you soon",   tr = "Yak\196\177nda g\195\182r\195\188\197\159\195\188r\195\188z.", direction = "both", tags = {"farewell"} },

    -- ----- Time markers -----
    { id = "ph.080", en = "not yet",        tr = "Hen\195\188z de\196\159il.",    direction = "both", tags = {"time", "response"} },
    { id = "ph.081", en = "right now",      tr = "\197\158u anda.",        direction = "both", tags = {"time"} },
    { id = "ph.082", en = "now",            tr = "\197\158imdi.",          direction = "both", tags = {"time"} },
    { id = "ph.083", en = "later",          tr = "Sonra.",          direction = "both", tags = {"time"} },
    { id = "ph.084", en = "soon",           tr = "Yak\196\177nda.",        direction = "both", tags = {"time"} },

    -- ----- WH-question stems (8.9.14 audit; engine-blocked until Ship 4) -----
    -- Bare WH-words and their common stems. Engine has no WH POS dispatch
    -- yet, so these phrasebook entries are the only path to clean output
    -- for question forms. Tagged "wh" so they're easy to migrate when
    -- Ship 4 lands productive WH support.
    { id = "ph.085", en = "what",           tr = "Ne?",             direction = "both", tags = {"question", "wh"} },
    { id = "ph.086", en = "where",          tr = "Nerede?",         direction = "both", tags = {"question", "wh"} },
    { id = "ph.087", en = "when",           tr = "Ne zaman?",       direction = "both", tags = {"question", "wh"} },
    { id = "ph.088", en = "why",            tr = "Neden?",          direction = "both", tags = {"question", "wh"} },
    { id = "ph.089", en = "who",            tr = "Kim?",            direction = "both", tags = {"question", "wh"} },
    { id = "ph.090", en = "how",            tr = "Nas\196\177l?",   direction = "both", tags = {"question", "wh"} },
    { id = "ph.091", en = "what time",      tr = "Saat ka\195\167?",      direction = "both", tags = {"question", "wh"} },
    { id = "ph.092", en = "what color",     tr = "Ne renk?",        direction = "both", tags = {"question", "wh"} },
    { id = "ph.093", en = "what kind",      tr = "Ne t\195\188r?",  direction = "both", tags = {"question", "wh"} },
    { id = "ph.094", en = "what for",       tr = "Ni\195\167in?",   direction = "both", tags = {"question", "wh"} },
    { id = "ph.095", en = "what is this",   tr = "Bu ne?",          direction = "both", tags = {"question", "wh"} },
    { id = "ph.096", en = "what's this",    tr = "Bu ne?",          direction = "forward", tags = {"question", "wh", "contraction"} },
    { id = "ph.097", en = "what's that",    tr = "O ne?",           direction = "forward", tags = {"question", "wh", "contraction"} },
    { id = "ph.098", en = "what are you doing", tr = "Ne yap\196\177yorsun?", direction = "both", tags = {"question", "wh"} },
    { id = "ph.099", en = "where am i",     tr = "Neredeyim?",      direction = "both", tags = {"question", "wh"} },
    { id = "ph.100", en = "where is he",    tr = "O nerede?",       direction = "forward", tags = {"question", "wh"} },
    { id = "ph.101", en = "where is she",   tr = "O nerede?",       direction = "forward", tags = {"question", "wh"} },
    { id = "ph.102", en = "where are we",   tr = "Neredeyiz?",      direction = "both", tags = {"question", "wh"} },
    { id = "ph.103", en = "where are they", tr = "Neredeler?",      direction = "both", tags = {"question", "wh"} },
    { id = "ph.104", en = "where are we going", tr = "Nereye gidiyoruz?", direction = "both", tags = {"question", "wh"} },
    { id = "ph.105", en = "why not",        tr = "Neden olmas\196\177n?", direction = "both", tags = {"question", "wh"} },
    { id = "ph.106", en = "who is that",    tr = "O kim?",          direction = "forward", tags = {"question", "wh"} },
    { id = "ph.107", en = "who is it",      tr = "O kim?",          direction = "forward", tags = {"question", "wh"} },
    { id = "ph.108", en = "who are you",    tr = "Sen kimsin?",     direction = "both", tags = {"question", "wh"} },
    { id = "ph.109", en = "how is it",      tr = "Nas\196\177l?",   direction = "forward", tags = {"question", "wh"} },
    { id = "ph.110", en = "how much",       tr = "Ne kadar?",       direction = "both", tags = {"question", "wh"} },
    { id = "ph.111", en = "how many",       tr = "Ka\195\167 tane?",      direction = "both", tags = {"question", "wh"} },

    -- ----- Common modal/cognition phrases (8.9.14; engine-blocked modals) -----
    { id = "ph.112", en = "i know",         tr = "Biliyorum.",      direction = "both", tags = {"cognition"} },
    { id = "ph.113", en = "i think so",     tr = "San\196\177r\196\177m.", direction = "both", tags = {"cognition"} },
    { id = "ph.114", en = "i don't think so", tr = "Sanm\196\177yorum.", direction = "both", tags = {"cognition"} },
    { id = "ph.115", en = "i agree",        tr = "Kat\196\177l\196\177yorum.", direction = "both", tags = {"response"} },
    { id = "ph.116", en = "i disagree",     tr = "Kat\196\177lm\196\177yorum.", direction = "both", tags = {"response"} },
    { id = "ph.117", en = "always",         tr = "Her zaman.",      direction = "both", tags = {"time", "adverb"} },
    { id = "ph.118", en = "never",          tr = "Asla.",           direction = "both", tags = {"time", "adverb"} },

    -- ----- Conversational fillers (added in deeper audit pass) -----
    { id = "ph.119", en = "let me see",     tr = "Bir bakay\196\177m.",   direction = "both", tags = {"filler"} },
    { id = "ph.120", en = "let me think",   tr = "D\195\188\197\159\195\188neyim.",      direction = "both", tags = {"filler"} },
    { id = "ph.121", en = "i'm not sure",   tr = "Emin de\196\159ilim.",  direction = "both", tags = {"cognition", "uncertainty"} },
    { id = "ph.122", en = "i have no idea", tr = "Hi\195\167 fikrim yok.", direction = "both", tags = {"cognition", "uncertainty"} },
    { id = "ph.123", en = "no big deal",    tr = "B\195\188y\195\188k sorun de\196\159il.", direction = "both", tags = {"response"} },
    { id = "ph.124", en = "good idea",      tr = "G\195\188zel fikir.",   direction = "both", tags = {"response"} },
    { id = "ph.125", en = "bad idea",       tr = "K\195\182t\195\188 fikir.",     direction = "both", tags = {"response"} },
    { id = "ph.126", en = "i'll be back",   tr = "D\195\182nerim.",       direction = "both", tags = {"farewell"} },
    { id = "ph.127", en = "take it easy",   tr = "Sakin ol.",       direction = "both", tags = {"response"} },
    { id = "ph.128", en = "knock it off",   tr = "Kes \197\159unu.",      direction = "both", tags = {"command"} },
    { id = "ph.129", en = "back off",       tr = "Geri \195\167ekil.",    direction = "both", tags = {"command"} },
    { id = "ph.130", en = "go away",        tr = "Git buradan.",    direction = "both", tags = {"command"} },
    { id = "ph.131", en = "leave me alone", tr = "Beni rahat b\196\177rak.", direction = "both", tags = {"command"} },
    { id = "ph.132", en = "what's up",      tr = "Ne haber?",       direction = "both", tags = {"greeting", "informal"} },
    { id = "ph.133", en = "all good",       tr = "Her \197\159ey iyi.",   direction = "both", tags = {"response"} },
    { id = "ph.134", en = "fair enough",    tr = "Tamam.",          direction = "forward", tags = {"response"} },
    { id = "ph.135", en = "i'm out",        tr = "Ben \195\167\196\177kt\196\177m.", direction = "both", tags = {"farewell"} },
    { id = "ph.136", en = "let's do this",  tr = "Hadi yapal\196\177m.",  direction = "both", tags = {"command"} },
    { id = "ph.137", en = "good job",       tr = "Aferin.",         direction = "both", tags = {"response"} },
    { id = "ph.138", en = "well done",      tr = "Aferin.",         direction = "forward", tags = {"response"} },
    { id = "ph.139", en = "nice one",       tr = "G\195\188zel.",         direction = "forward", tags = {"response"} },
    { id = "ph.140", en = "no worries",     tr = "Sorun yok.",      direction = "both", tags = {"response"} },
    { id = "ph.141", en = "you got it",     tr = "Anla\197\159t\196\177k.",      direction = "both", tags = {"response"} },
    { id = "ph.142", en = "i got it",       tr = "Anlad\196\177m.",        direction = "both", tags = {"response"} },
    { id = "ph.143", en = "shut the door",  tr = "Kap\196\177y\196\177 kapat.",  direction = "both", tags = {"command"} },
    { id = "ph.144", en = "open the door",  tr = "Kap\196\177y\196\177 a\195\167.",       direction = "both", tags = {"command"} },
    { id = "ph.145", en = "be quiet",       tr = "Sessiz ol.",      direction = "both", tags = {"command"} },
    { id = "ph.146", en = "stay close",     tr = "Yak\196\177n dur.",      direction = "both", tags = {"command"} },
    { id = "ph.147", en = "move it",        tr = "Acele et.",       direction = "both", tags = {"command"} },
    { id = "ph.148", en = "freeze",         tr = "Kal.",            direction = "forward", tags = {"command"} },
    { id = "ph.149", en = "don't shoot",    tr = "Ate\197\159 etme.",     direction = "both", tags = {"command"} },
    { id = "ph.150", en = "i'm coming",     tr = "Geliyorum.",      direction = "both", tags = {"response"} },

    -- ----- Spatial/directional pointers (engine-blocked ADV workarounds) -----
    { id = "ph.151", en = "right here",     tr = "Tam burada.",     direction = "both", tags = {"spatial"} },
    { id = "ph.152", en = "right there",    tr = "Tam orada.",      direction = "both", tags = {"spatial"} },
    { id = "ph.153", en = "over here",      tr = "Buraya.",         direction = "both", tags = {"spatial"} },
    { id = "ph.154", en = "over there",     tr = "Oraya.",          direction = "both", tags = {"spatial"} },
    { id = "ph.155", en = "down here",      tr = "A\197\159a\196\159\196\177da.",      direction = "both", tags = {"spatial"} },
    { id = "ph.156", en = "up there",       tr = "Yukar\196\177da.",       direction = "both", tags = {"spatial"} },
    { id = "ph.157", en = "in here",        tr = "\196\176\195\167eride.",       direction = "both", tags = {"spatial"} },
    { id = "ph.158", en = "out there",      tr = "D\196\177\197\159ar\196\177da.",       direction = "both", tags = {"spatial"} },
    { id = "ph.159", en = "here",           tr = "Burada.",         direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.160", en = "there",          tr = "Orada.",          direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.161", en = "up",             tr = "Yukar\196\177.",        direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.162", en = "down",           tr = "A\197\159a\196\159\196\177.",        direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.163", en = "inside",         tr = "\196\176\195\167eride.",       direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.164", en = "outside",        tr = "D\196\177\197\159ar\196\177da.",       direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.165", en = "back",           tr = "Geri.",           direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.166", en = "behind",         tr = "Arkada.",         direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.167", en = "ahead",          tr = "\196\176leride.",        direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.168", en = "around",         tr = "Etrafta.",        direction = "forward", tags = {"spatial", "adverb"} },
    { id = "ph.169", en = "everywhere",     tr = "Her yerde.",      direction = "both", tags = {"spatial", "adverb"} },
    { id = "ph.170", en = "nowhere",        tr = "Hi\195\167bir yerde.",  direction = "both", tags = {"spatial", "adverb"} },
    { id = "ph.171", en = "somewhere",      tr = "Bir yerde.",      direction = "both", tags = {"spatial", "adverb"} },

    -- ----- More common chat (filling out the adverb/intensifier gap) -----
    { id = "ph.172", en = "very",           tr = "\195\135ok.",           direction = "forward", tags = {"intensifier", "adverb"} },
    { id = "ph.173", en = "too",            tr = "\195\135ok.",           direction = "forward", tags = {"intensifier", "adverb"} },
    { id = "ph.174", en = "just",           tr = "Sadece.",         direction = "forward", tags = {"adverb"} },
    { id = "ph.175", en = "only",           tr = "Sadece.",         direction = "forward", tags = {"adverb"} },
    { id = "ph.176", en = "also",           tr = "Ayr\196\177ca.",        direction = "forward", tags = {"adverb"} },
    { id = "ph.177", en = "again",          tr = "Tekrar.",         direction = "forward", tags = {"adverb"} },
    { id = "ph.178", en = "still",          tr = "Hala.",           direction = "forward", tags = {"adverb"} },
    { id = "ph.179", en = "already",        tr = "Zaten.",          direction = "forward", tags = {"adverb"} },
    { id = "ph.180", en = "almost",         tr = "Neredeyse.",      direction = "forward", tags = {"adverb"} },
    { id = "ph.181", en = "probably",       tr = "Muhtemelen.",     direction = "forward", tags = {"adverb"} },
    { id = "ph.182", en = "certainly",      tr = "Kesinlikle.",     direction = "forward", tags = {"adverb"} },
    { id = "ph.183", en = "absolutely",     tr = "Kesinlikle.",     direction = "forward", tags = {"adverb"} },

    -- ----- Phrasal verbs (engine-blocked compositions; high-frequency chat) -----
    -- Movement & posture
    { id = "ph.184", en = "look out",       tr = "Dikkat et.",      direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.185", en = "get out",        tr = "\195\135\196\177k.",          direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.186", en = "get in",         tr = "Gir.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.187", en = "get up",         tr = "Kalk.",           direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.188", en = "sit down",       tr = "Otur.",           direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.189", en = "stand up",       tr = "Aya\196\159a kalk.",     direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.190", en = "lie down",       tr = "Yat.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.191", en = "come back",      tr = "Geri gel.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.192", en = "go back",        tr = "Geri d\195\182n.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.193", en = "go on",          tr = "Devam et.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.194", en = "come over",      tr = "Buraya gel.",     direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.195", en = "come in",        tr = "Gir.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.196", en = "step back",      tr = "Geri \195\167ekil.",     direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.197", en = "step forward",   tr = "\196\176leri \195\167\196\177k.",      direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.198", en = "go ahead",       tr = "\196\176leri git.",      direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.199", en = "turn around",    tr = "D\195\182n.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.200", en = "turn back",      tr = "Geri d\195\182n.",       direction = "both", tags = {"phrasal", "command"} },

    -- Common action phrasal verbs
    { id = "ph.201", en = "give up",        tr = "Vazge\195\167.",         direction = "both", tags = {"phrasal"} },
    { id = "ph.202", en = "find out",       tr = "\195\150\196\159ren.",          direction = "both", tags = {"phrasal"} },
    { id = "ph.203", en = "look for",       tr = "Ara.",            direction = "both", tags = {"phrasal"} },
    { id = "ph.204", en = "look up",        tr = "Bul.",            direction = "forward", tags = {"phrasal"} },
    { id = "ph.205", en = "look at",        tr = "Bak.",            direction = "forward", tags = {"phrasal"} },
    { id = "ph.206", en = "look after",     tr = "Bak.",            direction = "forward", tags = {"phrasal"} },
    { id = "ph.207", en = "listen to",      tr = "Dinle.",          direction = "forward", tags = {"phrasal"} },
    { id = "ph.208", en = "take off",       tr = "\195\135\196\177kar.",         direction = "both", tags = {"phrasal"} },
    { id = "ph.209", en = "put on",         tr = "Giy.",            direction = "both", tags = {"phrasal"} },
    { id = "ph.210", en = "put down",       tr = "B\196\177rak.",          direction = "both", tags = {"phrasal"} },
    { id = "ph.211", en = "pick up",        tr = "Al.",             direction = "both", tags = {"phrasal"} },
    { id = "ph.212", en = "pick out",       tr = "Se\195\167.",            direction = "both", tags = {"phrasal"} },
    { id = "ph.213", en = "throw away",     tr = "At.",             direction = "both", tags = {"phrasal"} },
    { id = "ph.214", en = "get away",       tr = "Ka\195\167.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.215", en = "run away",       tr = "Ka\195\167.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.216", en = "run out",        tr = "T\195\188ken.",          direction = "both", tags = {"phrasal"} },
    { id = "ph.217", en = "break down",     tr = "\195\135\195\182k.",          direction = "both", tags = {"phrasal"} },
    { id = "ph.218", en = "break in",       tr = "\196\176\195\167eri gir.",     direction = "both", tags = {"phrasal"} },
    { id = "ph.219", en = "shut down",      tr = "Kapat.",          direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.220", en = "turn on",        tr = "A\195\167.",             direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.221", en = "turn off",       tr = "Kapat.",          direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.222", en = "show up",        tr = "Geldi.",          direction = "forward", tags = {"phrasal"} },
    { id = "ph.223", en = "check it out",   tr = "Bak \197\159una.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.224", en = "hand over",      tr = "Teslim et.",      direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.225", en = "hang on",        tr = "Bekle.",          direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.226", en = "back up",        tr = "Yedekle.",        direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.227", en = "back down",      tr = "Geri \195\167ekil.",     direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.228", en = "pass out",       tr = "Bay\196\177l.",          direction = "both", tags = {"phrasal"} },
    { id = "ph.229", en = "carry on",       tr = "Devam et.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.230", en = "speak up",       tr = "Y\195\188ksek sesle konu\197\159.", direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.231", en = "wake up",        tr = "Uyan.",           direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.232", en = "calm yourself",  tr = "Sakinle\197\159.",       direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.233", en = "wait up",        tr = "Bekle.",          direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.234", en = "hurry up",       tr = "Acele et.",       direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.235", en = "fight back",     tr = "Kar\197\159\196\177 koy.",      direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.236", en = "watch yourself", tr = "Dikkat et.",      direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.237", en = "head out",       tr = "\195\135\196\177k.",          direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.238", en = "head back",      tr = "Geri d\195\182n.",       direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.239", en = "head over",      tr = "Yan\196\177na git.",     direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.240", en = "get back",       tr = "Geri d\195\182n.",       direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.241", en = "get going",      tr = "Hadi git.",       direction = "forward", tags = {"phrasal", "command"} },
    { id = "ph.242", en = "knock down",     tr = "Devir.",          direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.243", en = "tear down",      tr = "Y\196\177k.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.244", en = "put away",       tr = "Kald\196\177r.",         direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.245", en = "set up",         tr = "Kur.",            direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.246", en = "clean up",       tr = "Temizle.",        direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.247", en = "patch up",       tr = "Yamala.",         direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.248", en = "fix up",         tr = "Onar.",           direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.249", en = "lock up",        tr = "Kilitle.",        direction = "both", tags = {"phrasal", "command"} },
    { id = "ph.250", en = "lock down",      tr = "Kilitle.",        direction = "forward", tags = {"phrasal", "command"} },

    -- Common contractions (engine has trouble with apostrophe-shortened modals)
    { id = "ph.251", en = "i can't",        tr = "Yapamam.",        direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.252", en = "i won't",        tr = "Yapmayaca\196\159\196\177m.",   direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.253", en = "i couldn't",     tr = "Yapamad\196\177m.",      direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.254", en = "i shouldn't",    tr = "Yapmamal\196\177y\196\177m.",   direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.255", en = "i wouldn't",     tr = "Yapmazd\196\177m.",      direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.256", en = "i didn't",       tr = "Yapmad\196\177m.",       direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.257", en = "i haven't",      tr = "Yapmad\196\177m.",       direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.258", en = "you can't",      tr = "Yapamazs\196\177n.",     direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.259", en = "you should",     tr = "Yapmal\196\177s\196\177n.",     direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.260", en = "we can",         tr = "Yapabiliriz.",    direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.261", en = "we should",      tr = "Yapmal\196\177y\196\177z.",     direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.262", en = "we must",        tr = "Yapmak zorunday\196\177z.", direction = "forward", tags = {"modal", "contraction"} },
    { id = "ph.263", en = "they will",      tr = "Yapacaklar.",     direction = "forward", tags = {"modal", "contraction"} },

    -- ----- Indefinite pronouns (engine-blocked; high chat frequency) -----
    { id = "ph.264", en = "everyone",       tr = "Herkes.",         direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.265", en = "everybody",      tr = "Herkes.",         direction = "forward", tags = {"pronoun", "indefinite"} },
    { id = "ph.266", en = "everything",     tr = "Her \197\159ey.",        direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.267", en = "someone",        tr = "Biri.",           direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.268", en = "somebody",       tr = "Biri.",           direction = "forward", tags = {"pronoun", "indefinite"} },
    { id = "ph.269", en = "something",      tr = "Bir \197\159ey.",         direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.270", en = "anyone",         tr = "Herhangi biri.",  direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.271", en = "anybody",        tr = "Herhangi biri.",  direction = "forward", tags = {"pronoun", "indefinite"} },
    { id = "ph.272", en = "anything",       tr = "Herhangi bir \197\159ey.", direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.273", en = "nobody",         tr = "Hi\195\167 kimse.",      direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.274", en = "no one",         tr = "Hi\195\167 kimse.",      direction = "forward", tags = {"pronoun", "indefinite"} },
    { id = "ph.275", en = "nothing",        tr = "Hi\195\167bir \197\159ey.",   direction = "both", tags = {"pronoun", "indefinite"} },
    { id = "ph.276", en = "anywhere",       tr = "Herhangi bir yere.", direction = "forward", tags = {"spatial", "indefinite"} },

    -- ----- Frequency/manner adverbs (engine-blocked ADV workarounds) -----
    { id = "ph.277", en = "ever",           tr = "Hi\195\167.",            direction = "forward", tags = {"adverb"} },
    { id = "ph.278", en = "truly",          tr = "Ger\195\167ekten.",      direction = "forward", tags = {"adverb"} },
    { id = "ph.279", en = "usually",        tr = "Genellikle.",     direction = "forward", tags = {"adverb"} },
    { id = "ph.280", en = "normally",       tr = "Normalde.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.281", en = "mostly",         tr = "\195\135o\196\159unlukla.",     direction = "forward", tags = {"adverb"} },
    { id = "ph.282", en = "sometimes",      tr = "Bazen.",          direction = "both", tags = {"adverb"} },
    { id = "ph.283", en = "often",          tr = "S\196\177k s\196\177k.",        direction = "both", tags = {"adverb"} },
    { id = "ph.284", en = "rarely",         tr = "Nadiren.",        direction = "both", tags = {"adverb"} },
    { id = "ph.285", en = "occasionally",   tr = "Ara s\196\177ra.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.286", en = "suddenly",       tr = "Aniden.",         direction = "both", tags = {"adverb"} },
    { id = "ph.287", en = "quickly",        tr = "H\196\177zl\196\177ca.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.288", en = "slowly",         tr = "Yava\197\159\195\167a.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.289", en = "carefully",      tr = "Dikkatlice.",     direction = "forward", tags = {"adverb"} },
    { id = "ph.290", en = "quietly",        tr = "Sessizce.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.291", en = "loudly",         tr = "Y\195\188ksek sesle.",   direction = "forward", tags = {"adverb"} },
    { id = "ph.292", en = "finally",        tr = "Sonunda.",        direction = "both", tags = {"adverb"} },
    { id = "ph.293", en = "eventually",     tr = "Eninde sonunda.", direction = "forward", tags = {"adverb"} },
    { id = "ph.294", en = "recently",       tr = "Yak\196\177n zamanda.",  direction = "forward", tags = {"adverb"} },
    { id = "ph.296", en = "completely",     tr = "Tamamen.",        direction = "forward", tags = {"adverb"} },
    { id = "ph.297", en = "totally",        tr = "Tamamen.",        direction = "forward", tags = {"adverb"} },
    { id = "ph.298", en = "obviously",      tr = "A\195\167\196\177k\195\167a.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.299", en = "honestly",       tr = "D\195\188r\195\188st\195\167e.",      direction = "forward", tags = {"adverb"} },
    { id = "ph.300", en = "barely",         tr = "Zar zor.",        direction = "forward", tags = {"adverb"} },
    { id = "ph.301", en = "hardly",         tr = "Zorlukla.",       direction = "forward", tags = {"adverb"} },
    { id = "ph.302", en = "nearly",         tr = "Neredeyse.",      direction = "forward", tags = {"adverb"} },
    { id = "ph.303", en = "approximately",  tr = "Yakla\197\159\196\177k.",      direction = "forward", tags = {"adverb"} },

    -- ----- Connectives (engine-blocked CONJ; high chat frequency) -----
    { id = "ph.304", en = "however",        tr = "Ancak.",          direction = "forward", tags = {"connective"} },
    { id = "ph.305", en = "although",       tr = "Ra\196\159men.",         direction = "forward", tags = {"connective"} },
    { id = "ph.306", en = "because",        tr = "\195\135\195\188nk\195\188.",         direction = "forward", tags = {"connective"} },
    { id = "ph.307", en = "since",          tr = "Madem.",          direction = "forward", tags = {"connective"} },
    { id = "ph.308", en = "if",             tr = "E\196\159er.",           direction = "forward", tags = {"connective"} },
    { id = "ph.309", en = "unless",         tr = "S\195\188rece.",         direction = "forward", tags = {"connective"} },
    { id = "ph.310", en = "until",          tr = "Kadar.",          direction = "forward", tags = {"connective"} },
    { id = "ph.311", en = "while",          tr = "\196\176ken.",          direction = "forward", tags = {"connective"} },
    { id = "ph.312", en = "otherwise",      tr = "Aksi takdirde.",  direction = "forward", tags = {"connective"} },
    { id = "ph.313", en = "therefore",      tr = "Bu y\195\188zden.",      direction = "forward", tags = {"connective"} },
    { id = "ph.314", en = "instead",        tr = "Onun yerine.",    direction = "forward", tags = {"connective"} },
    { id = "ph.315", en = "meanwhile",      tr = "Bu arada.",       direction = "forward", tags = {"connective"} },
    { id = "ph.316", en = "afterward",      tr = "Sonra.",          direction = "forward", tags = {"connective"} },
    { id = "ph.317", en = "besides",        tr = "Ayr\196\177ca.",         direction = "forward", tags = {"connective"} },
    { id = "ph.318", en = "regardless",     tr = "Yine de.",        direction = "forward", tags = {"connective"} },

    -- ----- Prepositions (engine-blocked PREP; standalone uses common) -----
    { id = "ph.319", en = "across",         tr = "Kar\197\159\196\177ya.",       direction = "forward", tags = {"preposition"} },
    { id = "ph.320", en = "against",        tr = "Kar\197\159\196\177.",         direction = "forward", tags = {"preposition"} },
    { id = "ph.321", en = "between",        tr = "Aras\196\177nda.",       direction = "forward", tags = {"preposition"} },
    { id = "ph.322", en = "beyond",         tr = "\195\150tesinde.",       direction = "forward", tags = {"preposition"} },
    { id = "ph.323", en = "beside",         tr = "Yan\196\177nda.",        direction = "forward", tags = {"preposition"} },
    { id = "ph.324", en = "below",          tr = "Alt\196\177nda.",        direction = "forward", tags = {"preposition"} },
    { id = "ph.325", en = "above",          tr = "\195\156zerinde.",        direction = "forward", tags = {"preposition"} },
    { id = "ph.326", en = "throughout",     tr = "Boyunca.",        direction = "forward", tags = {"preposition"} },
    { id = "ph.327", en = "near",           tr = "Yak\196\177n\196\177nda.",      direction = "forward", tags = {"preposition"} },
    { id = "ph.328", en = "far",            tr = "Uzak.",           direction = "forward", tags = {"adverb"} },
    { id = "ph.329", en = "close",          tr = "Yak\196\177n.",          direction = "forward", tags = {"adverb"} },

    -- ===== SURVIVAL CHAT WHOLE-SENTENCE IDIOMS =====
    -- These work around the engine's mid-sentence limitation by capturing
    -- the most-common complete utterances PZ players produce. Each entry
    -- is a literal phrase that comes up in proximity chat constantly.

    -- ----- Resource state / needs -----
    { id = "ph.330", en = "i need ammo",      tr = "Mermiye ihtiyac\196\177m var.",      direction = "both", tags = {"need", "survival"} },
    { id = "ph.331", en = "i need food",      tr = "Yemeye ihtiyac\196\177m var.",       direction = "both", tags = {"need", "survival"} },
    { id = "ph.332", en = "i need water",     tr = "Suya ihtiyac\196\177m var.",         direction = "both", tags = {"need", "survival"} },
    { id = "ph.333", en = "i need bandages",  tr = "Sarg\196\177ya ihtiyac\196\177m var.",     direction = "both", tags = {"need", "survival"} },
    { id = "ph.334", en = "i need medicine",  tr = "\196\176la\195\167a ihtiyac\196\177m var.",       direction = "both", tags = {"need", "survival"} },
    { id = "ph.335", en = "i need a weapon",  tr = "Silaha ihtiyac\196\177m var.",       direction = "both", tags = {"need", "survival"} },
    { id = "ph.336", en = "i'm out of ammo",  tr = "Mermim bitti.",          direction = "both", tags = {"state", "survival"} },
    { id = "ph.337", en = "i'm out of food",  tr = "Yemem bitti.",           direction = "both", tags = {"state", "survival"} },
    { id = "ph.338", en = "i'm out of water", tr = "Suyum bitti.",           direction = "both", tags = {"state", "survival"} },
    { id = "ph.339", en = "i ran out",        tr = "Bitirdim.",              direction = "both", tags = {"state", "survival"} },
    { id = "ph.340", en = "low on ammo",      tr = "Mermim az.",             direction = "forward", tags = {"state", "survival"} },
    { id = "ph.341", en = "low on food",      tr = "Yemem az.",              direction = "forward", tags = {"state", "survival"} },
    { id = "ph.342", en = "low on health",    tr = "Sa\196\159l\196\177\196\159\196\177m az.",          direction = "forward", tags = {"state", "survival"} },

    -- ----- Location queries / answers -----
    { id = "ph.343", en = "where is the base",     tr = "\195\156s nerede?",        direction = "both", tags = {"question", "location"} },
    { id = "ph.344", en = "where is everyone",     tr = "Herkes nerede?",   direction = "both", tags = {"question", "location"} },
    { id = "ph.345", en = "where are the others",  tr = "Di\196\159erleri nerede?", direction = "both", tags = {"question", "location"} },
    { id = "ph.346", en = "where are you going",   tr = "Nereye gidiyorsun?",direction = "both", tags = {"question", "location"} },
    { id = "ph.347", en = "i'm at the base",       tr = "\195\156steyim.",          direction = "both", tags = {"location"} },
    { id = "ph.348", en = "i'm at the house",      tr = "Evdeyim.",         direction = "both", tags = {"location"} },
    { id = "ph.349", en = "i'm in the house",      tr = "Evin i\195\167indeyim.",  direction = "both", tags = {"location"} },
    { id = "ph.350", en = "i'm outside",           tr = "D\196\177\197\159ar\196\177day\196\177m.",   direction = "both", tags = {"location"} },
    { id = "ph.351", en = "i'm inside",            tr = "\196\176\195\167erideyim.",      direction = "both", tags = {"location"} },
    { id = "ph.352", en = "i'm on the roof",       tr = "\195\135at\196\177day\196\177m.",       direction = "both", tags = {"location"} },
    { id = "ph.353", en = "i'm upstairs",          tr = "Yukar\196\177day\196\177m.",     direction = "both", tags = {"location"} },
    { id = "ph.354", en = "i'm downstairs",        tr = "A\197\159a\196\159\196\177day\196\177m.",      direction = "both", tags = {"location"} },
    { id = "ph.355", en = "meet me at the base",   tr = "\195\156ste bulu\197\159al\196\177m.",   direction = "both", tags = {"command", "location"} },
    { id = "ph.356", en = "see you at the base",   tr = "\195\156ste g\195\182r\195\188\197\159\195\188r\195\188z.",direction = "both", tags = {"farewell", "location"} },

    -- ----- Threat & combat -----
    { id = "ph.357", en = "they're coming",        tr = "Geliyorlar.",      direction = "both", tags = {"threat", "survival"} },
    { id = "ph.358", en = "they're here",          tr = "Buradalar.",       direction = "both", tags = {"threat", "survival"} },
    { id = "ph.359", en = "they're inside",        tr = "\196\176\195\167erideler.",      direction = "both", tags = {"threat", "survival"} },
    { id = "ph.360", en = "they're everywhere",    tr = "Her yerdeler.",    direction = "both", tags = {"threat", "survival"} },
    { id = "ph.361", en = "we're under attack",    tr = "Sald\196\177r\196\177 alt\196\177nday\196\177z.",direction = "both", tags = {"threat", "survival"} },
    { id = "ph.362", en = "we're surrounded",      tr = "Ku\197\159at\196\177ld\196\177k.",     direction = "both", tags = {"threat", "survival"} },
    { id = "ph.363", en = "we need to leave",      tr = "Gitmeliyiz.",      direction = "both", tags = {"command", "survival"} },
    { id = "ph.364", en = "we need to move",       tr = "Hareket etmeliyiz.",direction = "both", tags = {"command", "survival"} },
    { id = "ph.365", en = "we need to hide",       tr = "Saklanmal\196\177y\196\177z.",   direction = "both", tags = {"command", "survival"} },
    { id = "ph.366", en = "we need to fight",      tr = "Sava\197\159mal\196\177y\196\177z.",    direction = "both", tags = {"command", "survival"} },
    { id = "ph.367", en = "we need to regroup",    tr = "Toparlanmal\196\177y\196\177z.",   direction = "both", tags = {"command", "survival"} },
    { id = "ph.368", en = "fall back",             tr = "Geri \195\167ekil.",       direction = "both", tags = {"command", "survival"} },
    { id = "ph.369", en = "hold the line",         tr = "Hatt\196\177 tut.",        direction = "both", tags = {"command", "survival"} },
    { id = "ph.370", en = "hold your fire",        tr = "Ate\197\159i tut.",        direction = "both", tags = {"command", "survival"} },
    { id = "ph.371", en = "open fire",             tr = "Ate\197\159 a\195\167.",         direction = "both", tags = {"command", "survival"} },
    { id = "ph.372", en = "take cover",            tr = "Siper al.",        direction = "both", tags = {"command", "survival"} },
    { id = "ph.373", en = "stay behind me",        tr = "Arkamda kal.",     direction = "both", tags = {"command", "survival"} },
    { id = "ph.374", en = "stay together",         tr = "Birlikte kal\196\177n.",  direction = "both", tags = {"command", "survival"} },
    { id = "ph.375", en = "spread out",            tr = "Yay\196\177l\196\177n.",         direction = "both", tags = {"command", "survival"} },
    { id = "ph.376", en = "watch the door",        tr = "Kap\196\177y\196\177 g\195\182zle.",     direction = "both", tags = {"command", "survival"} },
    { id = "ph.377", en = "watch the window",      tr = "Pencereyi g\195\182zle.",  direction = "both", tags = {"command", "survival"} },
    { id = "ph.378", en = "watch the perimeter",   tr = "\195\135evreyi g\195\182zle.",    direction = "both", tags = {"command", "survival"} },
    { id = "ph.380", en = "i'll cover you",        tr = "Seni korurum.",    direction = "both", tags = {"survival"} },
    { id = "ph.381", en = "got him",               tr = "Onu hallettim.",   direction = "forward", tags = {"survival"} },
    { id = "ph.382", en = "got them",              tr = "Onlar\196\177 hallettim.", direction = "forward", tags = {"survival"} },

    -- ----- Status / acknowledgments -----
    { id = "ph.383", en = "on my way",             tr = "Yolday\196\177m.",        direction = "both", tags = {"response"} },
    { id = "ph.384", en = "i'm on it",             tr = "Hallediyorum.",    direction = "both", tags = {"response"} },
    { id = "ph.385", en = "right behind you",      tr = "Hemen arkanday\196\177m.",direction = "both", tags = {"response"} },
    { id = "ph.386", en = "i'm coming with you",   tr = "Seninle geliyorum.",direction = "both", tags = {"response"} },
    { id = "ph.387", en = "wait for me",           tr = "Beni bekle.",      direction = "both", tags = {"command"} },
    { id = "ph.388", en = "i'm waiting",           tr = "Bekliyorum.",      direction = "both", tags = {"response"} },
    { id = "ph.389", en = "copy that",             tr = "Anla\197\159\196\177ld\196\177.",       direction = "both", tags = {"response", "radio"} },
    { id = "ph.390", en = "roger that",            tr = "Anla\197\159\196\177ld\196\177.",       direction = "both", tags = {"response", "radio"} },
    { id = "ph.391", en = "understood",            tr = "Anla\197\159\196\177ld\196\177.",       direction = "both", tags = {"response"} },
    { id = "ph.392", en = "affirmative",           tr = "Olumlu.",          direction = "both", tags = {"response", "radio"} },
    { id = "ph.393", en = "negative",              tr = "Olumsuz.",         direction = "both", tags = {"response", "radio"} },
    { id = "ph.394", en = "loud and clear",        tr = "Y\195\188ksek ve net.",  direction = "both", tags = {"response", "radio"} },
    { id = "ph.395", en = "say again",             tr = "Tekrar et.",       direction = "both", tags = {"radio"} },
    { id = "ph.396", en = "i hear you",            tr = "Seni duyuyorum.",  direction = "both", tags = {"radio"} },
    { id = "ph.397", en = "do you copy",           tr = "Anlad\196\177n m\196\177?",      direction = "both", tags = {"radio"} },
    { id = "ph.398", en = "can you hear me",       tr = "Beni duyabiliyor musun?",direction = "both", tags = {"radio"} },

    -- ----- Q&A about safety / state -----
    { id = "ph.399", en = "is it safe",            tr = "G\195\188venli mi?",      direction = "both", tags = {"question", "survival"} },
    { id = "ph.400", en = "is anyone alive",       tr = "Kimse hayatta m\196\177?", direction = "both", tags = {"question", "survival"} },
    { id = "ph.401", en = "are you alone",         tr = "Yaln\196\177z m\196\177s\196\177n?",    direction = "both", tags = {"question"} },
    { id = "ph.402", en = "are you bitten",        tr = "Is\196\177r\196\177ld\196\177n m\196\177?",     direction = "both", tags = {"question", "survival"} },
    { id = "ph.403", en = "are you hurt",          tr = "Yaraland\196\177n m\196\177?",  direction = "both", tags = {"question", "survival"} },
    { id = "ph.404", en = "are you injured",       tr = "Yaraland\196\177n m\196\177?",  direction = "forward", tags = {"question", "survival"} },
    { id = "ph.405", en = "do you have food",      tr = "Yiyece\196\159in var m\196\177?", direction = "both", tags = {"question", "survival"} },
    { id = "ph.406", en = "do you have water",     tr = "Suyun var m\196\177?",     direction = "both", tags = {"question", "survival"} },
    { id = "ph.407", en = "do you have ammo",      tr = "Mermin var m\196\177?",    direction = "both", tags = {"question", "survival"} },
    { id = "ph.408", en = "do you have bandages",  tr = "Sarg\196\177n var m\196\177?",    direction = "both", tags = {"question", "survival"} },
    { id = "ph.409", en = "what do you have",      tr = "Neyin var?",       direction = "both", tags = {"question"} },
    { id = "ph.410", en = "what do you need",      tr = "Neye ihtiyac\196\177n var?", direction = "both", tags = {"question"} },
    { id = "ph.411", en = "what do you mean",      tr = "Ne demek istiyorsun?", direction = "both", tags = {"question"} },
    { id = "ph.412", en = "what do you think",     tr = "Ne d\195\188\197\159\195\188n\195\188yorsun?",  direction = "both", tags = {"question"} },
    { id = "ph.413", en = "what should i do",      tr = "Ne yapmal\196\177y\196\177m?",    direction = "both", tags = {"question"} },
    { id = "ph.414", en = "what should we do",     tr = "Ne yapmal\196\177y\196\177z?",    direction = "both", tags = {"question"} },

    -- ----- Door/access commands -----
    { id = "ph.415", en = "lock the door",         tr = "Kap\196\177y\196\177 kilitle.",  direction = "both", tags = {"command"} },
    { id = "ph.416", en = "unlock the door",       tr = "Kap\196\177n\196\177n kilidini a\195\167.",direction = "both", tags = {"command"} },
    { id = "ph.417", en = "open the gate",         tr = "Kap\196\177y\196\177 a\195\167.",       direction = "both", tags = {"command"} },
    { id = "ph.418", en = "close the gate",        tr = "Kap\196\177y\196\177 kapat.",    direction = "both", tags = {"command"} },
    { id = "ph.419", en = "close the window",      tr = "Pencereyi kapat.", direction = "both", tags = {"command"} },
    { id = "ph.420", en = "barricade the door",    tr = "Kap\196\177y\196\177 barikatla.",direction = "both", tags = {"command"} },
    { id = "ph.421", en = "block the door",        tr = "Kap\196\177y\196\177 engelle.",  direction = "both", tags = {"command"} },

    -- ----- Conversational openers/closers -----
    { id = "ph.422", en = "what's going on",       tr = "Neler oluyor?",    direction = "both", tags = {"greeting"} },
    { id = "ph.423", en = "how's it going",        tr = "Nas\196\177l gidiyor?",  direction = "both", tags = {"greeting"} },
    { id = "ph.424", en = "how have you been",     tr = "Nas\196\177ld\196\177n?",        direction = "both", tags = {"greeting"} },
    { id = "ph.425", en = "long time no see",      tr = "Uzun zamand\196\177r g\195\182r\195\188\197\159medik.",direction = "both", tags = {"greeting"} },
    { id = "ph.426", en = "see you around",        tr = "Yak\196\177nda g\195\182r\195\188\197\159\195\188r\195\188z.", direction = "both", tags = {"farewell"} },
    { id = "ph.427", en = "catch you later",       tr = "Sonra g\195\182r\195\188\197\159\195\188r\195\188z.",  direction = "both", tags = {"farewell"} },
    { id = "ph.428", en = "talk to you later",     tr = "Sonra konu\197\159uruz.", direction = "both", tags = {"farewell"} },
    { id = "ph.429", en = "stay safe",             tr = "G\195\188vende kal.",    direction = "both", tags = {"farewell"} },
    { id = "ph.430", en = "be safe",               tr = "G\195\188vende ol.",     direction = "both", tags = {"farewell"} },
    { id = "ph.431", en = "see ya",                tr = "Hadi g\195\182r\195\188\197\159\195\188r\195\188z.",   direction = "forward", tags = {"farewell"} },

    -- ----- Common reactions / acknowledgments -----
    { id = "ph.433", en = "i see",                 tr = "Anl\196\177yorum.",       direction = "forward", tags = {"response"} },
    { id = "ph.434", en = "i understand",          tr = "Anl\196\177yorum.",       direction = "both", tags = {"response"} },
    { id = "ph.436", en = "makes sense",           tr = "Mant\196\177kl\196\177.",        direction = "forward", tags = {"response"} },
    { id = "ph.437", en = "good point",            tr = "G\195\188zel nokta.",    direction = "both", tags = {"response"} },
    { id = "ph.438", en = "fair point",            tr = "Hakl\196\177s\196\177n.",        direction = "forward", tags = {"response"} },
    { id = "ph.439", en = "you're right",          tr = "Hakl\196\177s\196\177n.",        direction = "both", tags = {"response"} },
    { id = "ph.440", en = "you're wrong",          tr = "Yan\196\177l\196\177yorsun.",     direction = "both", tags = {"response"} },
    { id = "ph.441", en = "i was wrong",           tr = "Yan\196\177lm\196\177\197\159\196\177m.",      direction = "both", tags = {"response"} },
    { id = "ph.442", en = "my bad",                tr = "Hatam.",           direction = "forward", tags = {"response", "informal"} },
    { id = "ph.443", en = "my fault",              tr = "Benim hatam.",     direction = "both", tags = {"response"} },
    { id = "ph.444", en = "not my fault",          tr = "Benim hatam de\196\159il.",direction = "both", tags = {"response"} },
    { id = "ph.445", en = "your turn",             tr = "S\196\177ra sende.",     direction = "both", tags = {"response"} },
    { id = "ph.446", en = "my turn",               tr = "S\196\177ra bende.",     direction = "both", tags = {"response"} },
    { id = "ph.447", en = "let me try",            tr = "Bir deneyeyim.",   direction = "both", tags = {"response"} },
    { id = "ph.448", en = "let me help",           tr = "Yard\196\177m edeyim.",  direction = "both", tags = {"response"} },

    -- ----- Medical / health -----
    { id = "ph.449", en = "i'm hurt",              tr = "Yaraland\196\177m.",     direction = "both", tags = {"medical"} },
    { id = "ph.450", en = "i'm dying",             tr = "\195\150l\195\188yorum.",         direction = "both", tags = {"medical"} },
    { id = "ph.451", en = "i'm infected",          tr = "Enfekteyim.",      direction = "both", tags = {"medical"} },
    { id = "ph.452", en = "i have a fever",        tr = "Ate\197\159im var.",     direction = "both", tags = {"medical"} },
    { id = "ph.453", en = "i need a bandage",      tr = "Sarg\196\177ya ihtiyac\196\177m var.",direction = "both", tags = {"medical"} },
    { id = "ph.454", en = "i need a painkiller",   tr = "A\196\159r\196\177 kesiciye ihtiyac\196\177m var.",direction = "both", tags = {"medical"} },
    { id = "ph.455", en = "you'll be ok",          tr = "\196\176yi olacaks\196\177n.",   direction = "both", tags = {"medical"} },
    { id = "ph.456", en = "stay with me",          tr = "Benimle kal.",     direction = "both", tags = {"medical"} },
    { id = "ph.457", en = "don't die",             tr = "\195\150lme.",            direction = "both", tags = {"medical"} },
    { id = "ph.458", en = "patch me up",           tr = "Beni yamala.",     direction = "both", tags = {"medical"} },
    { id = "ph.459", en = "heal me",               tr = "Beni iyile\197\159tir.", direction = "both", tags = {"medical"} },
    { id = "ph.460", en = "i feel sick",           tr = "Hasta hissediyorum.",direction = "both", tags = {"medical"} },
    { id = "ph.461", en = "i feel weak",           tr = "G\195\188\195\167s\195\188z hissediyorum.",direction = "both", tags = {"medical"} },
    { id = "ph.462", en = "i feel dizzy",          tr = "Ba\197\159\196\177m d\195\182n\195\188yor.",     direction = "both", tags = {"medical"} },
    { id = "ph.463", en = "it hurts",              tr = "Ac\196\177yor.",          direction = "both", tags = {"medical"} },

    -- ----- General resolution -----
    { id = "ph.464", en = "i found it",            tr = "Buldum.",          direction = "both", tags = {"response"} },
    { id = "ph.465", en = "i lost it",             tr = "Kaybettim.",       direction = "both", tags = {"response"} },
    { id = "ph.466", en = "i did it",              tr = "Yapt\196\177m.",          direction = "both", tags = {"response"} },
    { id = "ph.467", en = "i can do it",           tr = "Yapabilirim.",     direction = "both", tags = {"response"} },
    { id = "ph.468", en = "we can do it",          tr = "Yapabiliriz.",     direction = "both", tags = {"response"} },
    { id = "ph.469", en = "let's try",             tr = "Deneyelim.",       direction = "both", tags = {"command"} },
    { id = "ph.470", en = "i'll try",              tr = "Deneyece\196\159im.",   direction = "both", tags = {"response"} },
    { id = "ph.471", en = "i'll handle it",        tr = "Hallederim.",      direction = "both", tags = {"response"} },
    { id = "ph.472", en = "leave it to me",        tr = "Bana b\196\177rak.",     direction = "both", tags = {"response"} },
    { id = "ph.473", en = "i can't do it",         tr = "Yapamam.",         direction = "forward", tags = {"response"} },
    { id = "ph.474", en = "it's broken",           tr = "K\196\177r\196\177k.",          direction = "both", tags = {"state"} },
    { id = "ph.475", en = "it's empty",            tr = "Bo\197\159.",             direction = "both", tags = {"state"} },
    { id = "ph.476", en = "it's full",             tr = "Dolu.",            direction = "both", tags = {"state"} },
    { id = "ph.477", en = "it's locked",           tr = "Kilitli.",         direction = "both", tags = {"state"} },
    { id = "ph.478", en = "it's open",             tr = "A\195\167\196\177k.",           direction = "both", tags = {"state"} },
    { id = "ph.479", en = "it's closed",           tr = "Kapal\196\177.",          direction = "both", tags = {"state"} },
    { id = "ph.480", en = "no good",               tr = "\196\176yi de\196\159il.",        direction = "both", tags = {"response"} },

    -- ----- More chat idioms (reactive / situational utterances) -----
    { id = "ph.481", en = "you're kidding",        tr = "\197\158aka yap\196\177yorsun.",   direction = "both", tags = {"response"} },
    { id = "ph.482", en = "no way",                tr = "Olamaz.",          direction = "both", tags = {"response"} },
    { id = "ph.483", en = "for real",              tr = "Ger\195\167ekten mi?",  direction = "both", tags = {"response"} },
    { id = "ph.484", en = "are you serious",       tr = "Ciddi misin?",     direction = "both", tags = {"response"} },
    { id = "ph.485", en = "don't worry about it",  tr = "Endi\197\159elenme.",     direction = "both", tags = {"response"} },
    { id = "ph.486", en = "don't worry",           tr = "Endi\197\159elenme.",     direction = "both", tags = {"response"} },
    { id = "ph.487", en = "don't bother",          tr = "Bo\197\159una u\196\159ra\197\159ma.",    direction = "both", tags = {"response"} },
    { id = "ph.488", en = "don't mention it",      tr = "Lafi bile olmaz.", direction = "both", tags = {"response"} },
    { id = "ph.489", en = "don't panic",           tr = "Panik yapma.",     direction = "both", tags = {"command"} },
    { id = "ph.490", en = "i forgive you",         tr = "Seni affediyorum.", direction = "both", tags = {"response"} },
    { id = "ph.491", en = "let me see that",       tr = "G\195\182ster bana.",    direction = "both", tags = {"command"} },
    { id = "ph.492", en = "hand me that",          tr = "\197\158unu uzat.",       direction = "both", tags = {"command"} },
    { id = "ph.493", en = "pass me that",          tr = "\197\158unu uzat.",       direction = "forward", tags = {"command"} },
    { id = "ph.494", en = "catch",                 tr = "Yakala.",          direction = "forward", tags = {"command"} },
    { id = "ph.495", en = "watch this",            tr = "\197\158unu izle.",       direction = "both", tags = {"command"} },
    { id = "ph.496", en = "look at me",            tr = "Bana bak.",        direction = "both", tags = {"command"} },
    { id = "ph.497", en = "look at this",          tr = "\197\158una bak.",        direction = "both", tags = {"command"} },
    { id = "ph.498", en = "did you see that",      tr = "Onu g\195\182rd\195\188n m\195\188?", direction = "both", tags = {"question"} },
    { id = "ph.499", en = "did you hear that",     tr = "Onu duydun mu?",   direction = "both", tags = {"question"} },
    { id = "ph.500", en = "i hear something",      tr = "Bir \197\159ey duyuyorum.",direction = "both", tags = {"survival"} },
    { id = "ph.501", en = "i see something",       tr = "Bir \197\159ey g\195\182r\195\188yorum.", direction = "both", tags = {"survival"} },
    { id = "ph.502", en = "i smell something",     tr = "Bir \197\159ey kokluyorum.",direction = "both", tags = {"survival"} },
    { id = "ph.503", en = "we're saved",           tr = "Kurtulduk.",       direction = "both", tags = {"response"} },
    { id = "ph.504", en = "we're doomed",          tr = "Mahvolduk.",       direction = "both", tags = {"response"} },
    { id = "ph.505", en = "it's over",             tr = "Bitti.",           direction = "both", tags = {"state"} },
    { id = "ph.506", en = "it's done",             tr = "Tamam.",           direction = "both", tags = {"state"} },
    { id = "ph.507", en = "almost there",          tr = "Az kald\196\177.",        direction = "both", tags = {"state"} },
    { id = "ph.508", en = "just in time",          tr = "Tam zaman\196\177nda.",   direction = "both", tags = {"state"} },
    { id = "ph.509", en = "too late",              tr = "\195\135ok ge\195\167.",        direction = "both", tags = {"state"} },
    { id = "ph.510", en = "right on time",         tr = "Tam zaman\196\177nda.",   direction = "forward", tags = {"state"} },
    { id = "ph.511", en = "wait for it",           tr = "Bekle.",           direction = "forward", tags = {"command"} },
    { id = "ph.512", en = "get ready",             tr = "Haz\196\177r ol.",        direction = "both", tags = {"command"} },
    { id = "ph.513", en = "are you ready",         tr = "Haz\196\177r m\196\177s\196\177n?",      direction = "both", tags = {"question"} },
    { id = "ph.514", en = "ready when you are",    tr = "Sen haz\196\177r oldu\196\159unda ben de hazirim.", direction = "forward", tags = {"response"} },
    { id = "ph.515", en = "let's roll",            tr = "Hadi gidelim!",    direction = "forward", tags = {"command"} },
    { id = "ph.516", en = "move out",              tr = "Hareket et.",      direction = "both", tags = {"command"} },
    { id = "ph.517", en = "let me through",        tr = "Ge\195\167meme izin ver.",direction = "forward", tags = {"command"} },
    { id = "ph.518", en = "step aside",            tr = "Kenara \195\167ekil.",    direction = "both", tags = {"command"} },
    { id = "ph.519", en = "make way",              tr = "Yol a\195\167.",          direction = "forward", tags = {"command"} },
    { id = "ph.520", en = "out of the way",        tr = "Yoldan \195\167ekil.",    direction = "both", tags = {"command"} },
    { id = "ph.521", en = "which way",             tr = "Hangi y\195\182nde?",     direction = "both", tags = {"question"} },
    { id = "ph.522", en = "heads up",              tr = "Dikkat!",          direction = "both", tags = {"command"} },
    { id = "ph.523", en = "good news",             tr = "\196\176yi haber.",       direction = "both", tags = {"response"} },
    { id = "ph.524", en = "bad news",              tr = "K\195\182t\195\188 haber.",      direction = "both", tags = {"response"} },
    { id = "ph.525", en = "any news",              tr = "Haber var m\196\177?",   direction = "both", tags = {"question"} },
    { id = "ph.526", en = "any sign of them",      tr = "\196\176z var m\196\177?",        direction = "both", tags = {"question", "survival"} },
    { id = "ph.527", en = "all clear",             tr = "Temiz.",           direction = "both", tags = {"response", "survival"} },
    { id = "ph.528", en = "area secure",           tr = "B\195\182lge g\195\188venli.",   direction = "both", tags = {"response", "survival"} },
    { id = "ph.529", en = "perimeter secure",      tr = "\195\135evre g\195\188venli.",    direction = "both", tags = {"response", "survival"} },
    { id = "ph.530", en = "i found something",     tr = "Bir \197\159ey buldum.",   direction = "both", tags = {"survival"} },
    { id = "ph.531", en = "i found someone",       tr = "Birini buldum.",   direction = "both", tags = {"survival"} },
    { id = "ph.532", en = "i found them",          tr = "Onlar\196\177 buldum.",   direction = "both", tags = {"survival"} },
    { id = "ph.534", en = "stay with the group",   tr = "Grupla kal.",      direction = "both", tags = {"command", "survival"} },
    { id = "ph.535", en = "split up",              tr = "Ayr\196\177l\196\177n.",        direction = "both", tags = {"command", "survival"} },
    { id = "ph.536", en = "regroup",               tr = "Toparlan\196\177n.",      direction = "both", tags = {"command", "survival"} },
    { id = "ph.537", en = "i'm low",               tr = "Az\196\177m kald\196\177.",     direction = "forward", tags = {"state", "survival"} },
    { id = "ph.538", en = "i'm full",              tr = "Doluyum.",         direction = "both", tags = {"state"} },
    { id = "ph.539", en = "i'm empty",             tr = "Bo\197\159um.",            direction = "both", tags = {"state"} },
    { id = "ph.541", en = "i'm good",              tr = "\196\176yiyim.",          direction = "forward", tags = {"state"} },
    { id = "ph.542", en = "trust me",              tr = "Bana g\195\188ven.",      direction = "both", tags = {"response"} },
    { id = "ph.543", en = "trust no one",          tr = "Kimseye g\195\188venme.", direction = "both", tags = {"response"} },
    { id = "ph.544", en = "be honest",             tr = "D\195\188r\195\188st ol.",     direction = "both", tags = {"command"} },
    { id = "ph.545", en = "tell me the truth",     tr = "Bana ger\195\167e\196\159i s\195\182yle.", direction = "both", tags = {"command"} },
    { id = "ph.546", en = "you're lying",          tr = "Yalan s\195\182yl\195\188yorsun.", direction = "both", tags = {"response"} },
    { id = "ph.547", en = "swear it",              tr = "Yemin et.",        direction = "forward", tags = {"command"} },
    { id = "ph.548", en = "i swear",               tr = "Yemin ederim.",    direction = "both", tags = {"response"} },
    { id = "ph.549", en = "i promise",             tr = "S\195\182z veriyorum.",  direction = "both", tags = {"response"} },
    { id = "ph.550", en = "promise me",            tr = "Bana s\195\182z ver.",   direction = "both", tags = {"command"} },
    -- 9.0+ Mosaic: not+PP idiom fragments. These don't fit the productive
    -- engine cleanly (PP-as-predicate would need değil appended after a
    -- variable-length PP). Encoding the common ones as phrasebook is the
    -- pragmatic chat-quality move.
    { id = "ph.551", en = "not for me",            tr = "Benim i\195\167in de\196\159il.", direction = "both", tags = {"response"} },
    { id = "ph.552", en = "not at all",            tr = "Hi\195\167 de\196\159il.",        direction = "both", tags = {"response"} },
    { id = "ph.553", en = "not on purpose",        tr = "Bilerek de\196\159il.",     direction = "both", tags = {"response"} },
    { id = "ph.554", en = "not in there",          tr = "Orada de\196\159il.",       direction = "both", tags = {"response"} },
    { id = "ph.555", en = "not anymore",           tr = "Art\196\177k de\196\159il.",      direction = "both", tags = {"response"} },
    { id = "ph.556", en = "not at the moment",     tr = "\197\158u an de\196\159il.",     direction = "both", tags = {"response"} },
    { id = "ph.557", en = "not right now",         tr = "\197\158u anda de\196\159il.",    direction = "both", tags = {"response"} },
    -- 9.0+ Mosaic: more not-X fragment idioms + tag questions.
    { id = "ph.558", en = "not much",              tr = "Pek de\196\159il.",        direction = "both", tags = {"response"} },
    { id = "ph.559", en = "not many",              tr = "\195\135ok de\196\159il.",        direction = "both", tags = {"response"} },
    { id = "ph.560", en = "not enough",            tr = "Yeterli de\196\159il.",    direction = "both", tags = {"response"} },
    { id = "ph.561", en = "not so much",           tr = "O kadar de\196\159il.",    direction = "both", tags = {"response"} },
    { id = "ph.562", en = "not exactly",           tr = "Tam olarak de\196\159il.", direction = "both", tags = {"response"} },
    { id = "ph.563", en = "not always",            tr = "Her zaman de\196\159il.",  direction = "both", tags = {"response"} },
    { id = "ph.564", en = "not anyone",            tr = "Hi\195\167 kimse de\196\159il.",  direction = "both", tags = {"response"} },
    -- Tag questions
    { id = "ph.565", en = "doesn't it",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.566", en = "isn't it",              tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.567", en = "wasn't it",             tr = "de\196\159il miydi",       direction = "both", tags = {"tag_question"} },
    { id = "ph.568", en = "weren't they",          tr = "de\196\159il miydiler",    direction = "both", tags = {"tag_question"} },
    -- 8.16.x: extended tag question coverage (apostrophe + apostrophe-less)
    { id = "ph.1430", en = "isnt it",              tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1431", en = "wasnt it",             tr = "de\196\159il miydi",       direction = "both", tags = {"tag_question"} },
    { id = "ph.1432", en = "aren't you",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1433", en = "arent you",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1434", en = "won't you",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1435", en = "wont you",             tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1436", en = "didn't you",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1437", en = "didnt you",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1438", en = "didn't she",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1439", en = "didnt she",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1440", en = "didn't he",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1441", en = "didnt he",             tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1442", en = "doesn't she",          tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1443", en = "doesnt she",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1444", en = "doesn't he",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1445", en = "doesnt he",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1446", en = "can't you",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1447", en = "cant you",             tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1448", en = "can't she",            tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1449", en = "cant she",             tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1450", en = "wouldn't it",          tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1451", en = "wouldnt it",           tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1452", en = "couldn't they",        tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.1453", en = "couldnt they",         tr = "de\196\159il mi",          direction = "both", tags = {"tag_question"} },
    { id = "ph.569", en = "aren't they",           tr = "de\196\159iller mi",       direction = "both", tags = {"tag_question"} },
    -- 9.0+ Mosaic: chat response idioms.
    { id = "ph.570", en = "don't mind if i do",    tr = "Memnun olurum.",         direction = "both", tags = {"response"} },
    { id = "ph.571", en = "dont mind if i do",     tr = "Memnun olurum.",         direction = "both", tags = {"response"} },
    { id = "ph.572", en = "i don't mind",          tr = "Sak\196\177ncas\196\177 yok.",    direction = "both", tags = {"response"} },
    { id = "ph.573", en = "i dont mind",           tr = "Sak\196\177ncas\196\177 yok.",    direction = "both", tags = {"response"} },
    { id = "ph.573a", en = "don't mind",           tr = "Sak\196\177ncas\196\177 yok.",    direction = "both", tags = {"response"} },
    { id = "ph.573b", en = "dont mind",            tr = "Sak\196\177ncas\196\177 yok.",    direction = "both", tags = {"response"} },
    { id = "ph.573c", en = "i don't know",         tr = "Bilmiyorum.",            direction = "both", tags = {"response"} },
    { id = "ph.573d", en = "i dont know",          tr = "Bilmiyorum.",            direction = "both", tags = {"response"} },
    { id = "ph.573e", en = "i don't care",         tr = "Umurumda de\196\159il.",     direction = "both", tags = {"response"} },
    { id = "ph.574", en = "no kidding",            tr = "Yok artk.",              direction = "both", tags = {"response"} },
    { id = "ph.575", en = "no kiddin",             tr = "Yok artk.",              direction = "both", tags = {"response"} },
    { id = "ph.576", en = "no way",                tr = "Olamaz.",                direction = "both", tags = {"response"} },
    { id = "ph.577", en = "oh my",                 tr = "Aman tanr\196\177m.",        direction = "both", tags = {"response"} },
    { id = "ph.578", en = "oh no",                 tr = "Oh hay\196\177r.",           direction = "both", tags = {"response"} },
    { id = "ph.579", en = "sure would",            tr = "Kesinlikle.",            direction = "both", tags = {"response"} },
    { id = "ph.580", en = "sure does",             tr = "Kesinlikle.",            direction = "both", tags = {"response"} },
    { id = "ph.581", en = "sure is",               tr = "Kesinlikle.",            direction = "both", tags = {"response"} },
    -- 9.0+ Mosaic: stranded modal-NEG fragments (chat sentence-fragments
    -- where the verb is dropped). Chat readers infer "do/be that" from
    -- context. Provide a generic deontic-impersonal Turkish form.
    { id = "ph.582", en = "shouldn't",             tr = "Yapmamal\196\177.",        direction = "both", tags = {"response"} },
    { id = "ph.583", en = "wouldn't",              tr = "Yapmazd\196\177.",         direction = "both", tags = {"response"} },
    { id = "ph.584", en = "couldn't",              tr = "Yapamazd\196\177.",        direction = "both", tags = {"response"} },
    { id = "ph.585", en = "won't",                 tr = "Yapmayacak.",            direction = "both", tags = {"response"} },
    { id = "ph.586", en = "can't",                 tr = "Yapamaz.",               direction = "both", tags = {"response"} },
    -- 9.0+ Mosaic: bare modal fragments. Clause-final standalone modal
    -- ("if we can...", "I would..., "yes, will") — verb dropped from
    -- context. Provide generic deontic-impersonal Turkish.
    { id = "ph.587", en = "if we can",             tr = "yapabilirsek",          direction = "forward", tags = {"filler"} },
    { id = "ph.588", en = "if i can",              tr = "yapabilirsem",          direction = "forward", tags = {"filler"} },
    { id = "ph.589", en = "if you can",            tr = "yapabilirsen",          direction = "forward", tags = {"filler"} },
    -- 9.0+ Mosaic: bare aux-do response/question idioms. Chat fragments
    -- where the main verb is dropped.
    { id = "ph.590", en = "did they",              tr = "Yapt\196\177lar m\196\177",       direction = "both", tags = {"response"} },
    { id = "ph.591", en = "did you",               tr = "Yapt\196\177n m\196\177",          direction = "both", tags = {"response"} },
    { id = "ph.592", en = "did he",                tr = "Yapt\196\177 m\196\177",           direction = "both", tags = {"response"} },
    { id = "ph.593", en = "did she",               tr = "Yapt\196\177 m\196\177",           direction = "both", tags = {"response"} },
    { id = "ph.594", en = "did we",                tr = "Yapt\196\177k m\196\177",          direction = "both", tags = {"response"} },
    -- Bare-verb past affirmative responses
    { id = "ph.595", en = "i did",                 tr = "Yapt\196\177m.",            direction = "both", tags = {"response"} },
    { id = "ph.596", en = "we did",                tr = "Yapt\196\177k.",            direction = "both", tags = {"response"} },
    { id = "ph.597", en = "they did",              tr = "Yapt\196\177lar.",          direction = "both", tags = {"response"} },
    -- 9.0+ Mosaic: bare aux-do + adverb chat fragments (truncated
    -- negative imperatives).
    { id = "ph.598", en = "don't even",            tr = "Bile yapma.",            direction = "both", tags = {"response"} },
    { id = "ph.599", en = "dont even",             tr = "Bile yapma.",            direction = "both", tags = {"response"} },
    { id = "ph.600", en = "don't just",            tr = "Sadece yapma.",          direction = "both", tags = {"response"} },
    { id = "ph.601", en = "dont just",             tr = "Sadece yapma.",          direction = "both", tags = {"response"} },
    { id = "ph.602", en = "or not",                tr = "Ya da de\196\159il.",        direction = "both", tags = {"response"} },
    { id = "ph.603", en = "not that",              tr = "\197\158u de\196\159il.",         direction = "both", tags = {"response"} },
    -- 9.0+ Mosaic: more chat NEG idioms.
    { id = "ph.604", en = "sure why not",          tr = "Tabii, neden olmas\196\177n.", direction = "both", tags = {"response"} },
    { id = "ph.605", en = "why not",               tr = "Neden olmas\196\177n.",     direction = "both", tags = {"response"} },
    { id = "ph.606", en = "not on me",             tr = "Bende de\196\159il.",      direction = "both", tags = {"response"} },
    { id = "ph.607", en = "not a bad",             tr = "Fena de\196\159il bir",    direction = "forward", tags = {"prefix"} },
    { id = "ph.608", en = "not a lot",             tr = "Pek de\196\159il.",        direction = "both", tags = {"response"} },
    -- 9.0+ embedded-WH idioms. The productive engine path can't yet
    -- produce -DIK/-ACAK + POSS + ACC nominalised forms required for
    -- "what to V" / "where they V-ed" / "what happened" object
    -- complements of know/tell/see. Adding the high-frequency exact
    -- matches via phrasebook covers the natural-chat surface; the
    -- productive engine fix remains open.
    { id = "ph.609", en = "i don't know what to say",      tr = "Ne diyece\196\159imi bilmiyorum.",      direction = "both", tags = {"cognition"} },
    { id = "ph.610", en = "i dont know what to say",       tr = "Ne diyece\196\159imi bilmiyorum.",      direction = "both", tags = {"cognition"} },
    { id = "ph.611", en = "i do not know what to say",     tr = "Ne diyece\196\159imi bilmiyorum.",      direction = "both", tags = {"cognition"} },
    { id = "ph.612", en = "i don't know what to do",       tr = "Ne yapaca\196\159\196\177m\196\177 bilmiyorum.", direction = "both", tags = {"cognition"} },
    { id = "ph.613", en = "i dont know what to do",        tr = "Ne yapaca\196\159\196\177m\196\177 bilmiyorum.", direction = "both", tags = {"cognition"} },
    { id = "ph.614", en = "i don't know what you mean",    tr = "Ne demek istedi\196\159ini anlam\196\177yorum.", direction = "both", tags = {"cognition"} },
    { id = "ph.615", en = "i don't know what happened",    tr = "Ne oldu\196\159unu bilmiyorum.",        direction = "both", tags = {"cognition"} },
    { id = "ph.616", en = "i don't know where to go",      tr = "Nereye gidece\196\159imi bilmiyorum.",   direction = "both", tags = {"cognition"} },
    { id = "ph.617", en = "i don't know how",              tr = "Nas\196\177l yapaca\196\159\196\177m\196\177 bilmiyorum.", direction = "both", tags = {"cognition"} },
    { id = "ph.618", en = "did you see what happened",     tr = "Ne oldu\196\159unu g\195\182rd\195\188n m\195\188?", direction = "both", tags = {"question"} },
    { id = "ph.619", en = "did you see that",              tr = "Onu g\195\182rd\195\188n m\195\188?",            direction = "both", tags = {"question"} },
    { id = "ph.620", en = "tell me what you think",        tr = "Ne d\195\188\197\159\195\188nd\195\188\196\159\195\188n\195\188 s\195\182yle.",      direction = "both", tags = {"request"} },
    { id = "ph.621", en = "tell me what happened",         tr = "Ne oldu\196\159unu anlat.",              direction = "both", tags = {"request"} },
    { id = "ph.622", en = "let me know",                   tr = "Bana haber ver.",                       direction = "both", tags = {"request"} },
    { id = "ph.623", en = "let me see",                    tr = "Bir g\195\182reyim.",                    direction = "both", tags = {"request", "informal"} },
    { id = "ph.624", en = "i am going to bed",             tr = "Yatmaya gidiyorum.",                    direction = "both", tags = {"farewell"} },
    { id = "ph.625", en = "i'm going to bed",              tr = "Yatmaya gidiyorum.",                    direction = "both", tags = {"farewell"} },
    { id = "ph.626", en = "we need food and water",        tr = "Yemek ve suya ihtiyac\196\177m\196\177z var.", direction = "both", tags = {"survival"} },
    { id = "ph.627", en = "are you still there",           tr = "Hala orada m\196\177s\196\177n?",       direction = "both", tags = {"question"} },
    { id = "ph.628", en = "thanks for the help",           tr = "Yard\196\177m i\195\167in te\197\159ekk\195\188rler.", direction = "both", tags = {"response"} },
    { id = "ph.629", en = "long time no see",              tr = "Uzun zaman oldu.",                      direction = "both", tags = {"greeting"} },
    -- 9.0+ "I had a X day" / "I forgot to V" / "if X let us know" --
    -- common chat patterns where the productive engine path stumbles
    -- on PP attachment, embedded VP after "forgot", or "if" subordinate
    -- clauses. Exact-match coverage; productive variants still need
    -- engine work.
    { id = "ph.630", en = "i had a long day at work",       tr = "\196\176\197\159te uzun bir g\195\188n ge\195\167irdim.", direction = "both", tags = {"chat"} },
    { id = "ph.631", en = "i had a long day",               tr = "Uzun bir g\195\188n ge\195\167irdim.",         direction = "both", tags = {"chat"} },
    { id = "ph.632", en = "i had a hard day",               tr = "Zor bir g\195\188n ge\195\167irdim.",          direction = "both", tags = {"chat"} },
    { id = "ph.633", en = "i had a good day",               tr = "G\195\188zel bir g\195\188n ge\195\167irdim.",    direction = "both", tags = {"chat"} },
    { id = "ph.634", en = "i had a bad day",                tr = "K\195\182t\195\188 bir g\195\188n ge\195\167irdim.", direction = "both", tags = {"chat"} },
    { id = "ph.635", en = "i forgot to tell you",           tr = "Sana s\195\182ylemeyi unuttum.",                direction = "both", tags = {"chat"} },
    { id = "ph.636", en = "i forgot to tell you something", tr = "Sana bir \197\159ey s\195\182ylemeyi unuttum.", direction = "both", tags = {"chat"} },
    { id = "ph.637", en = "i forgot to mention",            tr = "S\195\182ylemeyi unuttum.",                     direction = "both", tags = {"chat"} },
    { id = "ph.638", en = "let us know if you need help",   tr = "Yard\196\177ma ihtiyac\196\177n\196\177z olursa bize haber verin.", direction = "both", tags = {"request"} },
    { id = "ph.639", en = "let me know if you need help",   tr = "Yard\196\177ma ihtiyac\196\177n olursa bana haber ver.", direction = "both", tags = {"request"} },
    { id = "ph.640", en = "if you need help",               tr = "Yard\196\177ma ihtiyac\196\177n varsa",          direction = "forward", tags = {"prefix"} },
    -- Perfect progressive ("I have been V-ing") -- the productive engine
    -- path emits broken Vmek+olmak shapes. Cover the high-frequency
    -- exact phrases via phrasebook until the engine fix lands.
    { id = "ph.641", en = "i have been working on this all day", tr = "B\195\188t\195\188n g\195\188n bunun \195\188zerinde \195\167al\196\177\197\159\196\177yordum.", direction = "both", tags = {"chat"} },
    { id = "ph.642", en = "i have been waiting",            tr = "Bekliyordum.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.643", en = "i have been waiting for hours",  tr = "Saatlerdir bekliyorum.",                        direction = "both", tags = {"chat"} },
    { id = "ph.644", en = "i have been looking for you",    tr = "Seni ar\196\177yordum.",                       direction = "both", tags = {"chat"} },
    { id = "ph.645", en = "i have been thinking",           tr = "D\195\188\197\159\195\188n\195\188yordum.",        direction = "both", tags = {"chat"} },
    -- Predicate-noun copular with "this is a X" -- engine emits bare
    -- "X." which is too terse; phrasebook the most common instances.
    { id = "ph.646", en = "this is a test",                 tr = "Bu bir test.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.647", en = "this is a problem",              tr = "Bu bir sorun.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.648", en = "this is important",              tr = "Bu \195\182nemli.",                              direction = "both", tags = {"chat"} },
    { id = "ph.649", en = "it is almost sundown",           tr = "Neredeyse g\195\188n bat\196\177m\196\177.", direction = "both", tags = {"chat"} },
    -- "got home" / "got back" phrasal-verb idioms. Engine treats "got"
    -- as "took/bought", losing the arrival sense.
    { id = "ph.650", en = "i just got home",                tr = "Eve yeni geldim.",                             direction = "both", tags = {"chat"} },
    { id = "ph.651", en = "i got home",                     tr = "Eve geldim.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.652", en = "we just got home",               tr = "Eve yeni geldik.",                             direction = "both", tags = {"chat"} },
    { id = "ph.653", en = "i just got back",                tr = "Yeni d\195\182nd\195\188m.",                  direction = "both", tags = {"chat"} },
    { id = "ph.654", en = "i'm on my way",                  tr = "Yolday\196\177m.",                            direction = "both", tags = {"chat"} },
    { id = "ph.655", en = "i am on my way",                 tr = "Yolday\196\177m.",                            direction = "both", tags = {"chat"} },
    -- Common natural-chat phrases the engine mishandles: "sounds X" (sounds
    -- treated as plural noun), "back up" (back as body part), "what time"
    -- (multi-clause merge), "can I help you" (modal form composition).
    { id = "ph.656", en = "what time is it",                tr = "Saat ka\195\167?",                            direction = "both", tags = {"question"} },
    { id = "ph.657", en = "what time should we meet",       tr = "Saat ka\195\167ta bulu\197\159al\196\177m?", direction = "both", tags = {"question"} },
    { id = "ph.658", en = "that sounds great",              tr = "Kula\196\159a harika geliyor.",               direction = "both", tags = {"response"} },
    { id = "ph.659", en = "that sounds good",               tr = "Kula\196\159a iyi geliyor.",                  direction = "both", tags = {"response"} },
    { id = "ph.660", en = "sounds good to me",              tr = "Bana iyi geliyor.",                            direction = "both", tags = {"response"} },
    { id = "ph.661", en = "the server is back up",          tr = "Sunucu tekrar \195\167al\196\177\197\159\196\177yor.", direction = "both", tags = {"chat"} },
    { id = "ph.662", en = "can i help you",                 tr = "Size yard\196\177mc\196\177 olabilir miyim?", direction = "both", tags = {"question"} },
    { id = "ph.663", en = "how was your day",               tr = "G\195\188n\195\188n nas\196\177ld\196\177?",  direction = "both", tags = {"question"} },
    { id = "ph.664", en = "watch out for the horde",        tr = "S\195\188r\195\188ye dikkat et.",             direction = "both", tags = {"chat"} },
    { id = "ph.665", en = "i love it",                      tr = "Bay\196\177l\196\177yorum.",                  direction = "both", tags = {"response"} },
    -- Phrasal verbs and common short idioms the engine can't decompose
    { id = "ph.666", en = "i just woke up",                 tr = "Yeni uyand\196\177m.",                        direction = "both", tags = {"chat"} },
    { id = "ph.667", en = "i woke up",                      tr = "Uyand\196\177m.",                              direction = "both", tags = {"chat"} },
    { id = "ph.668", en = "i will be right back",           tr = "Hemen d\195\182n\195\188yorum.",              direction = "both", tags = {"chat"} },
    { id = "ph.669", en = "i'll be right back",             tr = "Hemen d\195\182n\195\188yorum.",              direction = "both", tags = {"chat"} },
    { id = "ph.670", en = "what are you up to",             tr = "Ne yap\196\177yorsun?",                       direction = "both", tags = {"question"} },
    { id = "ph.671", en = "i am dying out here",            tr = "Burada \195\182l\195\188yorum.",              direction = "both", tags = {"chat"} },
    { id = "ph.672", en = "i'm dying out here",             tr = "Burada \195\182l\195\188yorum.",              direction = "both", tags = {"chat"} },
    { id = "ph.673", en = "i am going to the store",        tr = "Dukkana gidiyorum.",                           direction = "both", tags = {"chat"} },
    { id = "ph.674", en = "i'm going to the store",         tr = "Dukkana gidiyorum.",                           direction = "both", tags = {"chat"} },
    { id = "ph.675", en = "i am not feeling well",          tr = "Kendimi iyi hissetmiyorum.",                   direction = "both", tags = {"chat"} },
    { id = "ph.676", en = "i'm not feeling well",           tr = "Kendimi iyi hissetmiyorum.",                   direction = "both", tags = {"chat"} },
    { id = "ph.677", en = "i do not feel good",             tr = "Kendimi iyi hissetmiyorum.",                   direction = "both", tags = {"chat"} },
    { id = "ph.678", en = "i don't feel good",              tr = "Kendimi iyi hissetmiyorum.",                   direction = "both", tags = {"chat"} },
    { id = "ph.679", en = "got it",                         tr = "Anlad\196\177m.",                              direction = "both", tags = {"response"} },
    { id = "ph.680", en = "sure thing",                     tr = "Olur.",                                        direction = "both", tags = {"response"} },
    { id = "ph.681", en = "give me a second",               tr = "Bir saniye.",                                  direction = "both", tags = {"request"} },
    { id = "ph.682", en = "give me a minute",               tr = "Bir dakika.",                                  direction = "both", tags = {"request"} },
    { id = "ph.683", en = "hang on a minute",               tr = "Bir dakika bekle.",                            direction = "both", tags = {"request"} },
    { id = "ph.684", en = "why are you here",               tr = "Neden buradas\196\177n?",                     direction = "both", tags = {"question"} },
    { id = "ph.685", en = "are you in game",                tr = "Oyunda m\196\177s\196\177n?",                 direction = "both", tags = {"question"} },
    { id = "ph.686", en = "i need backup",                  tr = "Deste\196\159e ihtiyac\196\177m var.",        direction = "both", tags = {"chat"} },
    { id = "ph.687", en = "it is getting dark",             tr = "Hava karar\196\177yor.",                      direction = "both", tags = {"chat"} },
    { id = "ph.688", en = "it's getting dark",              tr = "Hava karar\196\177yor.",                      direction = "both", tags = {"chat"} },
    { id = "ph.689", en = "should i do it",                 tr = "Yapmal\196\177 m\196\177y\196\177m?",          direction = "both", tags = {"question"} },
    { id = "ph.690", en = "he said hello",                  tr = "Selam s\195\182yledi.",                       direction = "both", tags = {"chat"} },
    { id = "ph.691", en = "she said hello",                 tr = "Selam s\195\182yledi.",                       direction = "both", tags = {"chat"} },
    { id = "ph.692", en = "they asked about you",           tr = "Seni sordular.",                               direction = "both", tags = {"chat"} },
    { id = "ph.693", en = "she told me a story",            tr = "Bana bir hikaye anlatt\196\177.",             direction = "both", tags = {"chat"} },
    { id = "ph.694", en = "he told me a story",             tr = "Bana bir hikaye anlatt\196\177.",             direction = "both", tags = {"chat"} },
    { id = "ph.695", en = "i keep forgetting",              tr = "S\195\188rekli unutuyorum.",                  direction = "both", tags = {"chat"} },
    { id = "ph.696", en = "i keep forgetting things",       tr = "S\195\188rekli bir \197\159eyler unutuyorum.", direction = "both", tags = {"chat"} },
    { id = "ph.697", en = "i keep losing my keys",          tr = "Anahtarlar\196\177m\196\177 s\195\188rekli kaybediyorum.", direction = "both", tags = {"chat"} },
    { id = "ph.698", en = "what is your favorite color",    tr = "Favori rengin ne?",                            direction = "both", tags = {"question"} },
    { id = "ph.699", en = "what's your favorite color",     tr = "Favori rengin ne?",                            direction = "both", tags = {"question"} },
    { id = "ph.700", en = "what is your favorite food",     tr = "Favori yeme\196\159in ne?",                   direction = "both", tags = {"question"} },
    { id = "ph.701", en = "what is your favorite movie",    tr = "Favori filmin ne?",                            direction = "both", tags = {"question"} },
    { id = "ph.702", en = "what is your name",              tr = "Ad\196\177n ne?",                              direction = "both", tags = {"question"} },
    { id = "ph.703", en = "what's your name",               tr = "Ad\196\177n ne?",                              direction = "both", tags = {"question"} },
    { id = "ph.704", en = "what do you do",                 tr = "Ne i\197\159 yap\196\177yorsun?",             direction = "both", tags = {"question"} },
    { id = "ph.705", en = "where are you from",             tr = "Nerelisin?",                                   direction = "both", tags = {"question"} },
    { id = "ph.706", en = "how old are you",                tr = "Ka\195\167 ya\197\159\196\177ndas\196\177n?",  direction = "both", tags = {"question"} },
    -- "had X" meaning "ate/took X" idiom (engine treats "had" as
    -- "have" past which produces wrong sense)
    { id = "ph.707", en = "i had lunch",                    tr = "\195\150\196\159le yeme\196\159i yedim.",     direction = "both", tags = {"chat"} },
    { id = "ph.708", en = "i had breakfast",                tr = "Kahvalt\196\177 yapt\196\177m.",              direction = "both", tags = {"chat"} },
    { id = "ph.709", en = "i had dinner",                   tr = "Ak\197\159am yeme\196\159i yedim.",           direction = "both", tags = {"chat"} },
    { id = "ph.710", en = "we had dinner together",         tr = "Birlikte ak\197\159am yeme\196\159i yedik.",  direction = "both", tags = {"chat"} },
    -- Passive get-disconnected: engine handles "got" as "take" so this breaks
    { id = "ph.711", en = "i got disconnected",             tr = "Ba\196\159lant\196\177m koptu.",              direction = "both", tags = {"chat"} },
    { id = "ph.712", en = "we got disconnected",            tr = "Ba\196\159lant\196\177m\196\177z koptu.",     direction = "both", tags = {"chat"} },
    -- Phrasal verbs in questions
    { id = "ph.713", en = "what time do you wake up",       tr = "Saat ka\195\167ta uyan\196\177yorsun?",       direction = "both", tags = {"question"} },
    { id = "ph.714", en = "what time did you wake up",      tr = "Saat ka\195\167ta uyand\196\177n?",           direction = "both", tags = {"question"} },
    -- Polite forms
    { id = "ph.715", en = "please help me",                 tr = "L\195\188tfen bana yard\196\177m et.",         direction = "both", tags = {"request"} },
    { id = "ph.716", en = "sorry about that",               tr = "Onun i\195\167in \195\188zg\195\188n\195\188m.", direction = "both", tags = {"response"} },
    { id = "ph.717", en = "thank you so much",              tr = "\195\135ok te\197\159ekk\195\188r ederim.",   direction = "both", tags = {"response"} },
    -- Potential ("could V"): engine produces past tense by mistake
    { id = "ph.718", en = "we could meet",                  tr = "Bulu\197\159abiliriz.",                       direction = "both", tags = {"chat"} },
    { id = "ph.719", en = "we could meet up",               tr = "Bulu\197\159abiliriz.",                       direction = "both", tags = {"chat"} },
    -- "How many X are Y-ing" question pattern
    { id = "ph.720", en = "how many people are coming",     tr = "Ka\195\167 ki\197\159i geliyor?",             direction = "both", tags = {"question"} },
    { id = "ph.721", en = "how many people are here",       tr = "Ka\195\167 ki\197\159i burada?",              direction = "both", tags = {"question"} },
    -- Agreement / continuation
    { id = "ph.722", en = "same here",                      tr = "Bende \195\182yle.",                          direction = "both", tags = {"response"} },
    { id = "ph.723", en = "same",                           tr = "Ayn\196\177.",                                direction = "both", tags = {"response"} },
    { id = "ph.724", en = "yeah i know",                    tr = "Evet biliyorum.",                              direction = "both", tags = {"response"} },
    { id = "ph.725", en = "yes i know",                     tr = "Evet biliyorum.",                              direction = "both", tags = {"response"} },
    -- Apologies / sympathy
    { id = "ph.726", en = "i am sorry",                     tr = "\195\150z\195\188r dilerim.",                  direction = "forward", tags = {"response"} },
    { id = "ph.727", en = "i'm sorry",                      tr = "\195\150z\195\188r dilerim.",                  direction = "forward", tags = {"response"} },
    { id = "ph.728", en = "sorry to hear that",             tr = "Bunu duydu\196\159uma \195\188zg\195\188n\195\188m.", direction = "both", tags = {"response"} },
    { id = "ph.729", en = "that sucks",                     tr = "Berbat.",                                      direction = "both", tags = {"response"} },
    { id = "ph.730", en = "hope you feel better",           tr = "Ge\195\167mi\197\159 olsun.",                 direction = "both", tags = {"response"} },
    -- Reactions / compliments
    { id = "ph.731", en = "nice job",                       tr = "Aferin.",                                      direction = "both", tags = {"response"} },
    { id = "ph.732", en = "good job",                       tr = "Aferin.",                                      direction = "both", tags = {"response"} },
    { id = "ph.733", en = "are you kidding",                tr = "\197\158aka m\196\177 yap\196\177yorsun?",     direction = "both", tags = {"question"} },
    { id = "ph.734", en = "are you kidding me",             tr = "Benimle dalga m\196\177 ge\195\167iyorsun?",    direction = "both", tags = {"question"} },
    -- Game/server-specific common phrases
    { id = "ph.735", en = "i am low on health",             tr = "Can\196\177m d\195\188\197\159\195\188k.",     direction = "both", tags = {"chat", "game"} },
    { id = "ph.736", en = "i'm low on health",              tr = "Can\196\177m d\195\188\197\159\195\188k.",     direction = "both", tags = {"chat", "game"} },
    { id = "ph.737", en = "i am in the base",               tr = "\195\156steyim.",                              direction = "both", tags = {"chat", "game"} },
    { id = "ph.738", en = "i'm in the base",                tr = "\195\156steyim.",                              direction = "both", tags = {"chat", "game"} },
    { id = "ph.739", en = "meet me at the gate",            tr = "Kap\196\177da bulu\197\159al\196\177m.",       direction = "both", tags = {"chat", "game"} },
    -- Greetings
    { id = "ph.740", en = "hi there",                       tr = "Selam!",                                       direction = "forward", tags = {"greeting"} },
    { id = "ph.741", en = "good afternoon",                 tr = "\196\176yi g\195\188nler.",                   direction = "both", tags = {"greeting"} },
    -- Thanks variants
    { id = "ph.742", en = "thanks a lot",                   tr = "\195\135ok te\197\159ekk\195\188rler.",       direction = "both", tags = {"response"} },
    { id = "ph.743", en = "thanks so much",                 tr = "\195\135ok te\197\159ekk\195\188r ederim.",   direction = "forward", tags = {"response"} },
    -- "sounds X" idioms
    { id = "ph.744", en = "sounds good",                    tr = "Kula\196\159a iyi geliyor.",                  direction = "both", tags = {"response"} },
    { id = "ph.745", en = "sounds great",                   tr = "Kula\196\159a harika geliyor.",               direction = "forward", tags = {"response"} },
    { id = "ph.746", en = "sounds like a plan",             tr = "G\195\188zel plan.",                          direction = "both", tags = {"response"} },
    -- "went home" / "go home" — engine drops DAT case on "home" adverb
    { id = "ph.747", en = "i went home",                    tr = "Eve gittim.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.748", en = "we went home",                   tr = "Eve gittik.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.749", en = "they went home",                 tr = "Eve gittiler.",                                direction = "both", tags = {"chat"} },
    { id = "ph.750", en = "go home",                        tr = "Eve git.",                                     direction = "both", tags = {"chat"} },
    { id = "ph.751", en = "i'm going home",                 tr = "Eve gidiyorum.",                               direction = "both", tags = {"chat"} },
    { id = "ph.752", en = "i am going home",                tr = "Eve gidiyorum.",                               direction = "both", tags = {"chat"} },
    -- Final batch: common idiomatic chat phrases that don't decompose
    { id = "ph.753", en = "interesting",                    tr = "\196\176lgin\195\167.",                       direction = "forward", tags = {"response"} },
    { id = "ph.754", en = "will be back in a bit",          tr = "Birazdan d\195\182nerim.",                     direction = "both", tags = {"chat"} },
    { id = "ph.755", en = "i'll be back in a bit",          tr = "Birazdan d\195\182nerim.",                     direction = "forward", tags = {"chat"} },
    { id = "ph.756", en = "just wondering",                 tr = "Sadece merak ettim.",                          direction = "both", tags = {"chat"} },
    { id = "ph.757", en = "tell me about it",               tr = "Anlat bakal\196\177m.",                       direction = "both", tags = {"chat"} },
    { id = "ph.758", en = "got a minute",                   tr = "Bir dakikan var m\196\177?",                  direction = "both", tags = {"question"} },
    { id = "ph.759", en = "got a sec",                      tr = "Bir saniyen var m\196\177?",                  direction = "both", tags = {"question"} },
    { id = "ph.760", en = "wait what",                      tr = "Bir saniye, ne?",                              direction = "both", tags = {"response"} },
    { id = "ph.761", en = "anyone need anything",           tr = "Kimsenin bir \197\159eye ihtiyac\196\177 var m\196\177?", direction = "both", tags = {"question"} },
    { id = "ph.762", en = "hopefully this works",           tr = "Umar\196\177m \195\167al\196\177\197\159\196\177r.", direction = "both", tags = {"chat"} },
    { id = "ph.763", en = "just checking in",               tr = "Sadece kontrol ediyorum.",                     direction = "both", tags = {"chat"} },
    { id = "ph.764", en = "does this translate correctly",  tr = "Bu do\196\159ru \195\167eviriyor mu?",         direction = "both", tags = {"question"} },
    { id = "ph.765", en = "i am about to test the translator", tr = "\195\135evirmeni test edece\196\159im.",   direction = "both", tags = {"chat"} },
    { id = "ph.766", en = "i'm about to test the translator", tr = "\195\135evirmeni test edece\196\159im.",    direction = "forward", tags = {"chat"} },
    { id = "ph.767", en = "i am going to reset the server", tr = "Sunucuyu yeniden ba\197\159lataca\196\159\196\177m.", direction = "both", tags = {"chat"} },
    { id = "ph.768", en = "i'm going to reset the server",  tr = "Sunucuyu yeniden ba\197\159lataca\196\159\196\177m.", direction = "forward", tags = {"chat"} },
    { id = "ph.769", en = "did not expect that",            tr = "Bunu beklemiyordum.",                          direction = "both", tags = {"response"} },
    { id = "ph.770", en = "didn't expect that",             tr = "Bunu beklemiyordum.",                          direction = "forward", tags = {"response"} },
    { id = "ph.771", en = "are you guys online",            tr = "Online m\196\177s\196\177n\196\177z?",         direction = "both", tags = {"question"} },
    { id = "ph.772", en = "anyone online",                  tr = "Kimse online mi?",                             direction = "both", tags = {"question"} },
    -- Super-common chat openers (first-thought territory)
    { id = "ph.773", en = "real quick",                     tr = "K\196\177saca.",                              direction = "both", tags = {"chat"} },
    { id = "ph.774", en = "hold up",                        tr = "Bir saniye.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.775", en = "check this out",                 tr = "Buna bak.",                                    direction = "both", tags = {"chat"} },
    { id = "ph.776", en = "you there",                      tr = "Orada m\196\177s\196\177n?",                  direction = "both", tags = {"question"} },
    { id = "ph.777", en = "what now",                       tr = "\197\158imdi ne?",                            direction = "both", tags = {"question"} },
    { id = "ph.778", en = "cool",                           tr = "S\195\188per.",                               direction = "forward", tags = {"response"} },
    { id = "ph.779", en = "be right there",                 tr = "Hemen geliyorum.",                             direction = "both", tags = {"chat"} },
    { id = "ph.780", en = "i'll be right there",            tr = "Hemen geliyorum.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.781", en = "on it",                          tr = "Hallediyorum.",                                direction = "both", tags = {"response"} },
    { id = "ph.782", en = "testing this",                   tr = "Bunu test ediyorum.",                          direction = "both", tags = {"chat"} },
    { id = "ph.783", en = "just testing",                   tr = "Sadece test ediyorum.",                        direction = "both", tags = {"chat"} },
    { id = "ph.784", en = "does this work",                 tr = "Bu \195\167al\196\177\197\159\196\177yor mu?", direction = "both", tags = {"question"} },
    { id = "ph.785", en = "i'm here",                       tr = "Buraday\196\177m.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.786", en = "be back soon",                   tr = "Az sonra d\195\182nerim.",                    direction = "both", tags = {"chat"} },
    { id = "ph.787", en = "back",                           tr = "D\195\182nd\195\188m.",                       direction = "forward", tags = {"chat"} },
    -- Common interjections that should NOT passthrough as-is
    { id = "ph.788", en = "hey",                            tr = "Hey.",                                         direction = "forward", tags = {"greeting"} },
    { id = "ph.789", en = "yo",                             tr = "Hey.",                                         direction = "forward", tags = {"greeting"} },
    { id = "ph.790", en = "sup",                            tr = "Ne haber?",                                    direction = "forward", tags = {"greeting"} },
    -- "I keep V-ing" productive prefix would be ideal; for now common idioms
    { id = "ph.791", en = "i keep getting disconnected",    tr = "S\195\188rekli ba\196\159lant\196\177m kopuyor.", direction = "both", tags = {"chat"} },
    { id = "ph.792", en = "i keep dying",                   tr = "S\195\188rekli \195\182l\195\188yorum.",      direction = "both", tags = {"chat"} },
    -- Apostrophe-less subjectless contractions. Engine drops implicit "I"
    -- subject so "Cant find it" produces 3sg "Bulamaz" instead of 1sg.
    { id = "ph.793", en = "cant find it",                   tr = "Bulam\196\177yorum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.794", en = "can't find it",                  tr = "Bulam\196\177yorum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.795", en = "dont know",                      tr = "Bilmiyorum.",                                  direction = "forward", tags = {"chat"} },
    { id = "ph.796", en = "don't know",                     tr = "Bilmiyorum.",                                  direction = "forward", tags = {"chat"} },
    { id = "ph.797", en = "havent seen him",                tr = "Onu g\195\182rmedim.",                         direction = "forward", tags = {"chat"} },
    { id = "ph.798", en = "haven't seen him",               tr = "Onu g\195\182rmedim.",                         direction = "forward", tags = {"chat"} },
    { id = "ph.799", en = "havent seen her",                tr = "Onu g\195\182rmedim.",                         direction = "forward", tags = {"chat"} },
    { id = "ph.800", en = "doesnt matter",                  tr = "\195\150nemli de\196\159il.",                  direction = "forward", tags = {"response"} },
    { id = "ph.801", en = "doesn't matter",                 tr = "\195\150nemli de\196\159il.",                  direction = "forward", tags = {"response"} },
    { id = "ph.802", en = "didnt expect that",              tr = "Bunu beklemiyordum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.803", en = "didn't expect that",             tr = "Bunu beklemiyordum.",                          direction = "forward", tags = {"chat"} },
    -- "Ill X" specific common forms (chat-context favors "I will" over "sick")
    { id = "ph.804", en = "ill be there",                   tr = "Orada olaca\196\159\196\177m.",               direction = "forward", tags = {"chat"} },
    { id = "ph.805", en = "ill be right back",              tr = "Hemen d\195\182n\195\188yorum.",              direction = "forward", tags = {"chat"} },
    { id = "ph.806", en = "ill go",                         tr = "Giderim.",                                     direction = "forward", tags = {"chat"} },
    { id = "ph.807", en = "ill check",                      tr = "Bakar\196\177m.",                              direction = "forward", tags = {"chat"} },
    { id = "ph.808", en = "ill be back",                    tr = "D\195\182nerim.",                              direction = "forward", tags = {"chat"} },
    { id = "ph.809", en = "ill be there in a minute",       tr = "Bir dakikaya orada olurum.",                   direction = "forward", tags = {"chat"} },
    -- Round 4: remaining common chat patterns
    { id = "ph.810", en = "cant believe it",                tr = "\196\176nanam\196\177yorum.",                  direction = "forward", tags = {"response"} },
    { id = "ph.811", en = "can't believe it",               tr = "\196\176nanam\196\177yorum.",                  direction = "forward", tags = {"response"} },
    { id = "ph.812", en = "hope you are okay",              tr = "Umar\196\177m iyisindir.",                    direction = "both", tags = {"response"} },
    { id = "ph.813", en = "hope you're okay",               tr = "Umar\196\177m iyisindir.",                    direction = "forward", tags = {"response"} },
    { id = "ph.814", en = "glad you are back",              tr = "D\195\182nd\195\188\196\159\195\188ne sevindim.", direction = "both", tags = {"response"} },
    { id = "ph.815", en = "glad you're back",               tr = "D\195\182nd\195\188\196\159\195\188ne sevindim.", direction = "forward", tags = {"response"} },
    { id = "ph.816", en = "that is wild",                   tr = "\195\135\196\177lg\196\177n.",                direction = "both", tags = {"response"} },
    { id = "ph.817", en = "that's wild",                    tr = "\195\135\196\177lg\196\177n.",                direction = "forward", tags = {"response"} },
    -- Dev/Mongoose context
    { id = "ph.818", en = "i am running some tests",        tr = "Baz\196\177 testler yap\196\177yorum.",       direction = "both", tags = {"chat", "dev"} },
    { id = "ph.819", en = "i'm running some tests",         tr = "Baz\196\177 testler yap\196\177yorum.",       direction = "forward", tags = {"chat", "dev"} },
    { id = "ph.820", en = "running some tests",             tr = "Test yap\196\177yorum.",                       direction = "forward", tags = {"chat", "dev"} },
    { id = "ph.821", en = "trying to debug this",           tr = "Bunu debug etmeye \195\167al\196\177\197\159\196\177yorum.", direction = "both", tags = {"chat", "dev"} },
    { id = "ph.822", en = "i am trying to debug this",      tr = "Bunu debug etmeye \195\167al\196\177\197\159\196\177yorum.", direction = "both", tags = {"chat", "dev"} },
    -- Idioms and "got" / "back" patterns
    { id = "ph.823", en = "just got back",                  tr = "Yeni d\195\182nd\195\188m.",                  direction = "both", tags = {"chat"} },
    { id = "ph.824", en = "i just got back",                tr = "Yeni d\195\182nd\195\188m.",                  direction = "forward", tags = {"chat"} },
    { id = "ph.825", en = "let me figure this out",         tr = "\197\158unu \195\167\195\182zeyim.",          direction = "both", tags = {"chat"} },
    { id = "ph.826", en = "got to dash",                    tr = "Ka\195\167mam laz\196\177m.",                 direction = "both", tags = {"chat"} },
    { id = "ph.827", en = "got to go",                      tr = "Gitmem laz\196\177m.",                        direction = "both", tags = {"chat"} },
    { id = "ph.828", en = "gotta go",                       tr = "Gitmem laz\196\177m.",                        direction = "both", tags = {"chat"} },
    -- Continuation idioms
    { id = "ph.829", en = "yeah totally",                   tr = "Evet kesinlikle.",                             direction = "both", tags = {"response"} },
    { id = "ph.830", en = "pretty much",                    tr = "Az \195\167ok.",                              direction = "both", tags = {"response"} },
    { id = "ph.831", en = "sounds about right",             tr = "Do\196\159ruya benziyor.",                    direction = "both", tags = {"response"} },
    -- Coordination
    { id = "ph.832", en = "where do you want to meet",      tr = "Nerede bulu\197\159mak istersin?",            direction = "both", tags = {"question"} },
    { id = "ph.833", en = "when are you free",              tr = "Ne zaman m\195\188saitsin?",                  direction = "both", tags = {"question"} },
    { id = "ph.834", en = "are you in",                     tr = "Var m\196\177s\196\177n?",                    direction = "both", tags = {"question"} },
    -- Game/military idiom
    { id = "ph.835", en = "watch your six",                 tr = "Arkan\196\177 kolla.",                        direction = "both", tags = {"chat", "game"} },
    { id = "ph.836", en = "watch your back",                tr = "Arkan\196\177 kolla.",                        direction = "both", tags = {"chat"} },
    -- Internet memes (kept as transliteration/borrow since no clean Turkish equivalent)
    { id = "ph.837", en = "big mood",                       tr = "B\195\188y\195\188k mood.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.838", en = "same energy",                    tr = "Ayn\196\177 enerji.",                          direction = "forward", tags = {"chat"} },
    -- Round 5: common chat idioms (polite forms, appreciation, openers,
    -- modal questions, checking patterns)
    { id = "ph.839", en = "whats new",                      tr = "Ne var ne yok?",                               direction = "forward", tags = {"question"} },
    { id = "ph.840", en = "what's new",                     tr = "Ne var ne yok?",                               direction = "forward", tags = {"question"} },
    { id = "ph.841", en = "been a while",                   tr = "Uzun zaman oldu.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.842", en = "i missed you",                   tr = "Seni \195\182zledim.",                         direction = "both", tags = {"chat"} },
    { id = "ph.843", en = "missed you",                     tr = "Seni \195\182zledim.",                         direction = "forward", tags = {"chat"} },
    { id = "ph.844", en = "what brings you here",           tr = "Seni buraya ne getirdi?",                      direction = "both", tags = {"question"} },
    { id = "ph.845", en = "glad to see you",                tr = "Seni g\195\182rmek g\195\188zel.",            direction = "both", tags = {"response"} },
    { id = "ph.846", en = "have a good one",                tr = "\196\176yi g\195\188nler.",                   direction = "both", tags = {"response"} },
    { id = "ph.847", en = "have a good day",                tr = "\196\176yi g\195\188nler.",                   direction = "both", tags = {"response"} },
    -- Polite requests / modal questions
    { id = "ph.848", en = "could you help me",              tr = "Bana yard\196\177m edebilir misin?",          direction = "both", tags = {"question"} },
    { id = "ph.849", en = "can you assist",                 tr = "Yard\196\177m edebilir misin?",                direction = "both", tags = {"question"} },
    { id = "ph.850", en = "can you help",                   tr = "Yard\196\177m edebilir misin?",                direction = "both", tags = {"question"} },
    { id = "ph.851", en = "i need a favor",                 tr = "Bir iyilik istiyorum.",                        direction = "both", tags = {"chat"} },
    { id = "ph.852", en = "do me a favor",                  tr = "Bana bir iyilik yap.",                         direction = "both", tags = {"chat"} },
    -- Expressions of appreciation
    { id = "ph.853", en = "i appreciate it",                tr = "Te\197\159ekk\195\188r ederim.",              direction = "forward", tags = {"response"} },
    { id = "ph.854", en = "that means a lot",               tr = "Benim i\195\167in \195\167ok \195\182nemli.", direction = "both", tags = {"response"} },
    { id = "ph.855", en = "means a lot to me",              tr = "Benim i\195\167in \195\167ok \195\182nemli.", direction = "forward", tags = {"response"} },
    { id = "ph.856", en = "i am here for you",              tr = "Senin i\195\167in buraday\196\177m.",         direction = "both", tags = {"response"} },
    { id = "ph.857", en = "i'm here for you",               tr = "Senin i\195\167in buraday\196\177m.",         direction = "forward", tags = {"response"} },
    -- Common openers / transitions
    { id = "ph.858", en = "by the way",                     tr = "Bu arada.",                                    direction = "both", tags = {"chat"} },
    { id = "ph.859", en = "speaking of which",              tr = "Bahsetmi\197\159ken.",                        direction = "both", tags = {"chat"} },
    { id = "ph.860", en = "just wanted to say hi",          tr = "Sadece merhaba demek istedim.",                direction = "both", tags = {"chat"} },
    { id = "ph.861", en = "random thought",                 tr = "Akl\196\177ma geldi.",                        direction = "forward", tags = {"chat"} },
    -- Coordination / requests for attention
    { id = "ph.862", en = "lets get started",               tr = "Ba\197\159layal\196\177m.",                   direction = "both", tags = {"chat"} },
    { id = "ph.863", en = "let's get started",              tr = "Ba\197\159layal\196\177m.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.864", en = "wait a moment",                  tr = "Bir an bekle.",                                direction = "both", tags = {"request"} },
    { id = "ph.865", en = "give me a moment",               tr = "Bir an ver.",                                  direction = "both", tags = {"request"} },
    -- "Is this on?" / "Is everything okay?" patterns
    { id = "ph.866", en = "is this on",                     tr = "Bu \195\167al\196\177\197\159\196\177yor mu?", direction = "both", tags = {"question"} },
    { id = "ph.867", en = "is everything okay",             tr = "Her \197\159ey yolunda m\196\177?",            direction = "both", tags = {"question"} },
    { id = "ph.868", en = "everything okay",                tr = "Her \197\159ey yolunda m\196\177?",            direction = "forward", tags = {"question"} },
    { id = "ph.869", en = "whats the issue",                tr = "Sorun ne?",                                    direction = "forward", tags = {"question"} },
    { id = "ph.870", en = "what's the issue",               tr = "Sorun ne?",                                    direction = "forward", tags = {"question"} },
    -- Continuation
    { id = "ph.871", en = "let me ask you something",       tr = "Sana bir \197\159ey soray\196\177m.",         direction = "both", tags = {"chat"} },
    { id = "ph.872", en = "i see what you mean",            tr = "Ne demek istedi\196\159ini anlad\196\177m.", direction = "both", tags = {"response"} },
    { id = "ph.873", en = "i know what you mean",           tr = "Ne demek istedi\196\159ini anl\196\177yorum.", direction = "both", tags = {"response"} },
    { id = "ph.874", en = "cant argue with that",           tr = "Buna kar\197\159\196\177 \195\167\196\177kam\196\177yorum.", direction = "forward", tags = {"response"} },
    { id = "ph.875", en = "can't argue with that",          tr = "Buna kar\197\159\196\177 \195\167\196\177kam\196\177yorum.", direction = "forward", tags = {"response"} },
    -- Round 6: time/scheduling, more idioms, sense-disambig fixes
    { id = "ph.876", en = "we are running late",            tr = "Ge\195\167 kald\196\177k.",                   direction = "both", tags = {"chat"} },
    { id = "ph.877", en = "we're running late",             tr = "Ge\195\167 kald\196\177k.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.878", en = "i am running late",              tr = "Ge\195\167 kald\196\177m.",                  direction = "both", tags = {"chat"} },
    { id = "ph.879", en = "i'm running late",               tr = "Ge\195\167 kald\196\177m.",                  direction = "forward", tags = {"chat"} },
    { id = "ph.880", en = "it is almost time",              tr = "Neredeyse vakit.",                             direction = "both", tags = {"chat"} },
    { id = "ph.881", en = "it's almost time",               tr = "Neredeyse vakit.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.882", en = "what day is it",                 tr = "Bug\195\188n hangi g\195\188n?",              direction = "both", tags = {"question"} },
    { id = "ph.883", en = "i have nothing to do",           tr = "Yapacak bir \197\159eyim yok.",               direction = "both", tags = {"chat"} },
    { id = "ph.884", en = "lets see what happens",          tr = "Bakal\196\177m ne olacak.",                   direction = "both", tags = {"chat"} },
    { id = "ph.885", en = "let's see what happens",         tr = "Bakal\196\177m ne olacak.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.886", en = "one more try",                   tr = "Bir daha deneyelim.",                          direction = "both", tags = {"chat"} },
    { id = "ph.887", en = "one more time",                  tr = "Bir kere daha.",                               direction = "both", tags = {"chat"} },
    { id = "ph.888", en = "watch out for the zombies",      tr = "Zombilere dikkat.",                            direction = "both", tags = {"chat", "game"} },
    { id = "ph.889", en = "the food smells good",           tr = "Yemek g\195\188zel kokuyor.",                 direction = "both", tags = {"chat"} },
    { id = "ph.890", en = "smells good",                    tr = "G\195\188zel kokuyor.",                       direction = "forward", tags = {"response"} },
    { id = "ph.891", en = "send my regards",                tr = "Selam\196\177m\196\177 s\195\182yle.",        direction = "both", tags = {"chat"} },
    { id = "ph.892", en = "tell them i said hi",            tr = "Onlara selam s\195\182yle.",                  direction = "both", tags = {"chat"} },
    { id = "ph.893", en = "tell her i said hi",             tr = "Ona selam s\195\182yle.",                     direction = "both", tags = {"chat"} },
    { id = "ph.894", en = "tell him i said hi",             tr = "Ona selam s\195\182yle.",                     direction = "both", tags = {"chat"} },
    -- "Where did you go" needs DAT case ("Nereye gittin?" not "Nerede gittin?")
    { id = "ph.895", en = "where did you go",               tr = "Nereye gittin?",                               direction = "both", tags = {"question"} },
    { id = "ph.896", en = "where did they go",              tr = "Nereye gittiler?",                             direction = "both", tags = {"question"} },
    -- Misc common
    { id = "ph.897", en = "i want to relax",                tr = "Rahatlamak istiyorum.",                        direction = "both", tags = {"chat"} },
    { id = "ph.898", en = "i'm full",                       tr = "Doydum.",                                      direction = "forward", tags = {"chat"} },
    { id = "ph.899", en = "lets go somewhere",              tr = "Bir yere gidelim.",                            direction = "both", tags = {"chat"} },
    { id = "ph.900", en = "let's go somewhere",             tr = "Bir yere gidelim.",                            direction = "forward", tags = {"chat"} },
    -- Round 7: high-frequency remaining patterns
    { id = "ph.901", en = "need a hand",                    tr = "Yard\196\177m laz\196\177m m\196\177?",       direction = "both", tags = {"question"} },
    { id = "ph.902", en = "want some help",                 tr = "Yard\196\177m ister misin?",                  direction = "both", tags = {"question"} },
    { id = "ph.903", en = "got your back",                  tr = "Arkanday\196\177m.",                          direction = "both", tags = {"response"} },
    { id = "ph.904", en = "i got your back",                tr = "Arkanday\196\177m.",                          direction = "both", tags = {"response"} },
    { id = "ph.905", en = "bring it on",                    tr = "Hadi getir!",                                  direction = "both", tags = {"response"} },
    { id = "ph.906", en = "get over here",                  tr = "Buraya gel!",                                  direction = "both", tags = {"request"} },
    { id = "ph.907", en = "come here",                      tr = "Buraya gel!",                                  direction = "both", tags = {"request"} },
    { id = "ph.908", en = "whats taking so long",           tr = "Neden bu kadar uzun s\195\188rd\195\188?",    direction = "forward", tags = {"question"} },
    { id = "ph.909", en = "what's taking so long",          tr = "Neden bu kadar uzun s\195\188rd\195\188?",    direction = "forward", tags = {"question"} },
    { id = "ph.910", en = "whats next",                     tr = "S\196\177ra ne?",                              direction = "forward", tags = {"question"} },
    { id = "ph.911", en = "what's next",                    tr = "S\196\177ra ne?",                              direction = "forward", tags = {"question"} },
    { id = "ph.912", en = "lost my keys",                   tr = "Anahtarlar\196\177m\196\177 kaybettim.",       direction = "both", tags = {"chat"} },
    { id = "ph.913", en = "lost my keys again",             tr = "Anahtarlar\196\177m\196\177 tekrar kaybettim.", direction = "both", tags = {"chat"} },
    { id = "ph.914", en = "lost my phone",                  tr = "Telefonumu kaybettim.",                        direction = "both", tags = {"chat"} },
    { id = "ph.915", en = "i lost my keys",                 tr = "Anahtarlar\196\177m\196\177 kaybettim.",       direction = "both", tags = {"chat"} },
    { id = "ph.916", en = "i lost my phone",                tr = "Telefonumu kaybettim.",                        direction = "both", tags = {"chat"} },
    -- Reactions
    { id = "ph.917", en = "thats too bad",                  tr = "\195\135ok k\195\182t\195\188.",              direction = "forward", tags = {"response"} },
    { id = "ph.918", en = "that's too bad",                 tr = "\195\135ok k\195\182t\195\188.",              direction = "forward", tags = {"response"} },
    -- Round 8: polysemy disambig. Words like "right", "cool", "looks",
    -- "sounds", "alright" have a literal/directional/noun Turkish sense
    -- in the lex but the chat-common evaluative sense breaks through
    -- to wrong outputs ("you're right" -> "Sağ" / right-direction).
    -- These phrasebook entries intercept the common predicate uses.

    -- "right" = correct (vs sağ/direction)
    { id = "ph.919", en = "you are right",                  tr = "Hakl\196\177s\196\177n.",                      direction = "both", tags = {"response"} },
    { id = "ph.920", en = "you're right",                   tr = "Hakl\196\177s\196\177n.",                      direction = "forward", tags = {"response"} },
    { id = "ph.921", en = "i am right",                     tr = "Hakl\196\177y\196\177m.",                     direction = "both", tags = {"response"} },
    { id = "ph.922", en = "i'm right",                      tr = "Hakl\196\177y\196\177m.",                     direction = "forward", tags = {"response"} },
    { id = "ph.923", en = "that is right",                  tr = "Do\196\159ru.",                                direction = "both", tags = {"response"} },
    { id = "ph.924", en = "that's right",                   tr = "Do\196\159ru.",                                direction = "forward", tags = {"response"} },
    { id = "ph.925", en = "right answer",                   tr = "Do\196\159ru cevap.",                          direction = "both", tags = {"chat"} },
    { id = "ph.926", en = "wrong answer",                   tr = "Yanl\196\177\197\159 cevap.",                  direction = "both", tags = {"chat"} },

    -- "cool" = awesome (vs serin/temperature) — already have ph.778
    { id = "ph.927", en = "thats cool",                     tr = "Haval\196\177.",                              direction = "forward", tags = {"response"} },
    { id = "ph.928", en = "that's cool",                    tr = "Haval\196\177.",                              direction = "forward", tags = {"response"} },
    { id = "ph.929", en = "very cool",                      tr = "\195\135ok haval\196\177.",                   direction = "both", tags = {"response"} },
    { id = "ph.930", en = "so cool",                        tr = "\195\135ok haval\196\177.",                   direction = "forward", tags = {"response"} },

    -- "alright" = OK as predicate (vs the directional sağ leak)
    { id = "ph.931", en = "everything is alright",          tr = "Her \197\159ey yolunda.",                     direction = "both", tags = {"response"} },
    { id = "ph.932", en = "everything's alright",           tr = "Her \197\159ey yolunda.",                     direction = "forward", tags = {"response"} },
    { id = "ph.933", en = "is everything alright",          tr = "Her \197\159ey yolunda m\196\177?",            direction = "both", tags = {"question"} },
    { id = "ph.934", en = "are you alright",                tr = "\196\176yi misin?",                            direction = "both", tags = {"question"} },
    { id = "ph.935", en = "you alright",                    tr = "\196\176yi misin?",                            direction = "forward", tags = {"question"} },
    { id = "ph.936", en = "i am alright",                   tr = "\196\176yiyim.",                               direction = "both", tags = {"response"} },
    { id = "ph.937", en = "i'm alright",                    tr = "\196\176yiyim.",                               direction = "forward", tags = {"response"} },
    { id = "ph.938", en = "that sounds alright",            tr = "Kula\196\159a iyi geliyor.",                  direction = "forward", tags = {"response"} },

    -- "looks X" perception verb (vs bakmak/look-at)
    { id = "ph.939", en = "looks good",                     tr = "\196\176yi g\195\182r\195\188n\195\188yor.",  direction = "both", tags = {"response"} },
    { id = "ph.940", en = "looks great",                    tr = "Harika g\195\182r\195\188n\195\188yor.",      direction = "both", tags = {"response"} },
    { id = "ph.941", en = "looks bad",                      tr = "K\195\182t\195\188 g\195\182r\195\188n\195\188yor.", direction = "both", tags = {"response"} },
    { id = "ph.942", en = "looks awful",                    tr = "Berbat g\195\182r\195\188n\195\188yor.",      direction = "both", tags = {"response"} },
    { id = "ph.943", en = "it looks good",                  tr = "\196\176yi g\195\182r\195\188n\195\188yor.",  direction = "both", tags = {"response"} },
    { id = "ph.944", en = "it looks great",                 tr = "Harika g\195\182r\195\188n\195\188yor.",      direction = "both", tags = {"response"} },
    { id = "ph.945", en = "you look good",                  tr = "\196\176yi g\195\182r\195\188n\195\188yorsun.", direction = "both", tags = {"response"} },
    { id = "ph.946", en = "you look great",                 tr = "Harika g\195\182r\195\188n\195\188yorsun.",   direction = "both", tags = {"response"} },
    { id = "ph.947", en = "you look tired",                 tr = "Yorgun g\195\182r\195\188n\195\188yorsun.",   direction = "both", tags = {"chat"} },

    -- "feels X" perception verb
    { id = "ph.948", en = "feels good",                     tr = "\196\176yi geliyor.",                          direction = "both", tags = {"response"} },
    { id = "ph.949", en = "feels great",                    tr = "Harika geliyor.",                              direction = "both", tags = {"response"} },
    { id = "ph.950", en = "feels bad",                      tr = "K\195\182t\195\188 geliyor.",                 direction = "both", tags = {"response"} },
    { id = "ph.951", en = "it feels good",                  tr = "\196\176yi geliyor.",                          direction = "both", tags = {"response"} },

    -- "sounds X" — many already covered (sounds good/great/like a plan)
    { id = "ph.952", en = "sounds bad",                     tr = "Kula\196\159a k\195\182t\195\188 geliyor.",   direction = "both", tags = {"response"} },
    { id = "ph.953", en = "sounds amazing",                 tr = "Kula\196\159a harika geliyor.",               direction = "forward", tags = {"response"} },
    { id = "ph.954", en = "sounds awful",                   tr = "Kula\196\159a berbat geliyor.",               direction = "both", tags = {"response"} },
    { id = "ph.955", en = "sounds fun",                     tr = "Kula\196\159a e\196\159lenceli geliyor.",    direction = "both", tags = {"response"} },

    -- "free" = available (vs özgür/liberty) — already have "when are you free"
    { id = "ph.956", en = "i am free",                      tr = "M\195\188saitim.",                             direction = "both", tags = {"response"} },
    { id = "ph.957", en = "i'm free",                       tr = "M\195\188saitim.",                             direction = "forward", tags = {"response"} },
    { id = "ph.958", en = "are you free",                   tr = "M\195\188sait misin?",                        direction = "both", tags = {"question"} },
    { id = "ph.959", en = "if you are free",                tr = "M\195\188saitsen.",                            direction = "both", tags = {"chat"} },

    -- "X is hard" = difficult (sert means firm; zor means difficult)
    { id = "ph.960", en = "this is hard",                   tr = "Bu zor.",                                      direction = "both", tags = {"response"} },
    { id = "ph.961", en = "that is hard",                   tr = "Bu zor.",                                      direction = "both", tags = {"response"} },
    { id = "ph.962", en = "thats hard",                     tr = "Bu zor.",                                      direction = "forward", tags = {"response"} },
    { id = "ph.963", en = "too hard",                       tr = "\195\135ok zor.",                              direction = "both", tags = {"response"} },
    { id = "ph.964", en = "really hard",                    tr = "Ger\195\167ekten zor.",                       direction = "both", tags = {"response"} },

    -- "X means Y" — verb sense already works
    -- "be mean" = cruel (vs verb mean=signify)
    { id = "ph.965", en = "don't be mean",                  tr = "K\195\182t\195\188 olma.",                    direction = "both", tags = {"chat"} },
    { id = "ph.966", en = "dont be mean",                   tr = "K\195\182t\195\188 olma.",                    direction = "forward", tags = {"chat"} },

    -- "wild" / "sick" / "crazy" = amazing (slang)
    { id = "ph.967", en = "that's sick",                    tr = "Bu m\195\188thi\197\159.",                    direction = "forward", tags = {"response"} },
    { id = "ph.968", en = "thats sick",                     tr = "Bu m\195\188thi\197\159.",                    direction = "forward", tags = {"response"} },
    { id = "ph.969", en = "that's crazy",                   tr = "Bu \195\167\196\177lg\196\177nca.",            direction = "forward", tags = {"response"} },
    { id = "ph.970", en = "thats crazy",                    tr = "Bu \195\167\196\177lg\196\177nca.",            direction = "forward", tags = {"response"} },
    { id = "ph.971", en = "thats fire",                     tr = "Bomba.",                                       direction = "forward", tags = {"response"} },
    { id = "ph.972", en = "that's fire",                    tr = "Bomba.",                                       direction = "forward", tags = {"response"} },
    -- Round 9: phrasal verbs. Engine splits "look up" -> "look" + "up"
    -- and produces literal "bak yukarı" instead of "araştır" (research).
    { id = "ph.973", en = "look it up",                     tr = "Ara\197\159t\196\177r.",                      direction = "both", tags = {"request"} },
    { id = "ph.974", en = "look that up",                   tr = "\197\158unu ara\197\159t\196\177r.",          direction = "both", tags = {"request"} },
    { id = "ph.975", en = "figure it out",                  tr = "\195\135\195\182z onu.",                      direction = "both", tags = {"request"} },
    { id = "ph.976", en = "figure out the bug",             tr = "Hatay\196\177 \195\167\195\182z.",            direction = "both", tags = {"chat"} },
    { id = "ph.977", en = "ill figure it out",              tr = "\195\135\195\182zerim.",                      direction = "forward", tags = {"chat"} },
    { id = "ph.978", en = "back me up",                     tr = "Beni destekle.",                               direction = "both", tags = {"request"} },
    { id = "ph.979", en = "pick me up",                     tr = "Beni al.",                                     direction = "both", tags = {"request"} },
    { id = "ph.980", en = "set it up",                      tr = "Onu kur.",                                     direction = "both", tags = {"request"} },
    { id = "ph.981", en = "get over it",                    tr = "A\197\159 onu.",                              direction = "both", tags = {"response"} },
    { id = "ph.982", en = "get over here",                  tr = "Buraya gel!",                                  direction = "forward", tags = {"request"} },
    { id = "ph.983", en = "show me",                        tr = "Bana g\195\182ster.",                         direction = "both", tags = {"request"} },
    { id = "ph.984", en = "tell me",                        tr = "Bana s\195\182yle.",                          direction = "both", tags = {"request"} },
    { id = "ph.985", en = "take a break",                   tr = "Ara ver.",                                     direction = "both", tags = {"chat"} },
    { id = "ph.986", en = "lets take a break",              tr = "Ara verelim.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.987", en = "let's take a break",             tr = "Ara verelim.",                                 direction = "forward", tags = {"chat"} },
    { id = "ph.988", en = "turn on the lights",             tr = "I\197\159\196\177klar\196\177 a\195\167.",    direction = "both", tags = {"request"} },
    { id = "ph.989", en = "turn off the lights",            tr = "I\197\159\196\177klar\196\177 kapat.",        direction = "both", tags = {"request"} },
    { id = "ph.990", en = "hang up",                        tr = "Kapat.",                                       direction = "both", tags = {"request"} },
    { id = "ph.991", en = "hold on tight",                  tr = "S\196\177k\196\177 tutun.",                   direction = "both", tags = {"request"} },
    { id = "ph.992", en = "we ran out",                     tr = "T\195\188kendi.",                              direction = "both", tags = {"chat"} },
    { id = "ph.993", en = "ran out of food",                tr = "Yemek bitti.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.994", en = "ran out of water",               tr = "Su bitti.",                                    direction = "both", tags = {"chat"} },
    { id = "ph.995", en = "ran out of ammo",                tr = "Mermi bitti.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.996", en = "make up your mind",              tr = "Karar ver.",                                   direction = "both", tags = {"request"} },
    { id = "ph.997", en = "try it on",                      tr = "Dene.",                                        direction = "both", tags = {"request"} },
    { id = "ph.998", en = "try on the shirt",               tr = "G\195\182mle\196\159i dene.",                 direction = "both", tags = {"request"} },
    { id = "ph.999", en = "move on",                        tr = "Devam et.",                                    direction = "both", tags = {"chat"} },
    { id = "ph.1000", en = "slow down",                     tr = "Yava\197\159la.",                              direction = "both", tags = {"request"} },
    { id = "ph.1001", en = "speed up",                      tr = "H\196\177zlan.",                              direction = "both", tags = {"request"} },
    { id = "ph.1002", en = "put it down",                   tr = "Onu b\196\177rak.",                           direction = "both", tags = {"request"} },
    { id = "ph.1003", en = "put me down",                   tr = "Beni b\196\177rak.",                          direction = "both", tags = {"request"} },
    { id = "ph.1004", en = "take it off",                   tr = "\195\135\196\177kar onu.",                    direction = "both", tags = {"request"} },
    { id = "ph.1005", en = "pass me the salt",              tr = "Tuzu uzat.",                                   direction = "both", tags = {"request"} },
    { id = "ph.1006", en = "look up the answer",            tr = "Cevab\196\177 ara\197\159t\196\177r.",         direction = "both", tags = {"request"} },
    -- Round 10: tag questions, idiomatic multi-word expressions, short responses
    -- Tag questions
    { id = "ph.1007", en = "right?",                        tr = "De\196\159il mi?",                            direction = "forward", tags = {"question"} },
    { id = "ph.1008", en = "you know?",                     tr = "Biliyor musun?",                               direction = "forward", tags = {"question"} },
    { id = "ph.1009", en = "you know what i mean",          tr = "Ne demek istedi\196\159imi biliyor musun?",   direction = "both", tags = {"question"} },
    -- Multi-word expressions / idioms
    { id = "ph.1010", en = "to be honest",                  tr = "D\195\188r\195\188stcesi.",                    direction = "both", tags = {"chat"} },
    { id = "ph.1011", en = "honestly",                      tr = "D\195\188r\195\188stcesi.",                    direction = "forward", tags = {"chat"} },
    { id = "ph.1012", en = "after all",                     tr = "Sonu\195\167ta.",                              direction = "both", tags = {"chat"} },
    { id = "ph.1013", en = "on second thought",             tr = "Bir d\195\188\197\159\195\188n\195\188nce.",   direction = "both", tags = {"chat"} },
    { id = "ph.1014", en = "in any case",                   tr = "Her halukarda.",                               direction = "both", tags = {"chat"} },
    { id = "ph.1015", en = "as far as i know",              tr = "Bildi\196\159im kadar\196\177yla.",            direction = "both", tags = {"chat"} },
    { id = "ph.1016", en = "for what its worth",            tr = "De\196\159eri varsa.",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1017", en = "for what it's worth",           tr = "De\196\159eri varsa.",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1018", en = "in my opinion",                 tr = "Bence.",                                       direction = "both", tags = {"chat"} },
    { id = "ph.1019", en = "by chance",                     tr = "Tesad\195\188fen.",                           direction = "both", tags = {"chat"} },
    { id = "ph.1020", en = "for now",                       tr = "\197\158imdilik.",                            direction = "both", tags = {"chat"} },
    { id = "ph.1021", en = "for the most part",             tr = "\195\135o\196\159unlukla.",                   direction = "both", tags = {"chat"} },
    { id = "ph.1022", en = "if you ask me",                 tr = "Bence.",                                       direction = "forward", tags = {"chat"} },
    -- Short responses
    { id = "ph.1023", en = "no thanks",                     tr = "Hay\196\177r, sa\196\159 ol.",                direction = "both", tags = {"response"} },
    { id = "ph.1024", en = "no thank you",                  tr = "Hay\196\177r, te\197\159ekk\195\188rler.",     direction = "both", tags = {"response"} },
    { id = "ph.1025", en = "yes please",                    tr = "Evet, l\195\188tfen.",                        direction = "both", tags = {"response"} },
    { id = "ph.1026", en = "uh huh",                        tr = "H\196\177 h\196\177.",                        direction = "forward", tags = {"response"} },
    { id = "ph.1027", en = "uh-huh",                        tr = "H\196\177 h\196\177.",                        direction = "forward", tags = {"response"} },
    -- Continuations
    { id = "ph.1028", en = "and then?",                     tr = "Sonra?",                                       direction = "forward", tags = {"question"} },
    { id = "ph.1029", en = "so what?",                      tr = "Ne olmu\197\159?",                            direction = "forward", tags = {"response"} },
    { id = "ph.1030", en = "what else?",                    tr = "Ba\197\159ka ne?",                            direction = "forward", tags = {"question"} },
    { id = "ph.1031", en = "anything else?",                tr = "Ba\197\159ka bir \197\159ey?",                direction = "forward", tags = {"question"} },
    { id = "ph.1032", en = "thats it?",                     tr = "Bu kadar m\196\177?",                         direction = "forward", tags = {"question"} },
    { id = "ph.1033", en = "that's it?",                    tr = "Bu kadar m\196\177?",                         direction = "forward", tags = {"question"} },
    { id = "ph.1034", en = "thats all?",                    tr = "Hepsi bu mu?",                                 direction = "forward", tags = {"question"} },
    { id = "ph.1035", en = "that's all",                    tr = "Hepsi bu.",                                    direction = "both", tags = {"response"} },
    { id = "ph.1036", en = "thats all",                     tr = "Hepsi bu.",                                    direction = "forward", tags = {"response"} },
    -- Final alright leak: "it is alright" wasn't covered by earlier batches
    { id = "ph.1037", en = "it is alright",                 tr = "\196\176yi.",                                  direction = "both", tags = {"response"} },
    { id = "ph.1038", en = "it's alright",                  tr = "\196\176yi.",                                  direction = "forward", tags = {"response"} },
    { id = "ph.1039", en = "its alright",                   tr = "\196\176yi.",                                  direction = "forward", tags = {"response"} },
    { id = "ph.1040", en = "everything will be alright",    tr = "Her \197\159ey yolunda olacak.",              direction = "both", tags = {"response"} },
    -- 3rd-person right (correct) — needed for Pattern J composition
    -- ("I think she is right" -> "Sanırım haklı")
    { id = "ph.1041", en = "he is right",                   tr = "Hakl\196\177.",                                direction = "forward", tags = {"response"} },
    { id = "ph.1042", en = "she is right",                  tr = "Hakl\196\177.",                                direction = "forward", tags = {"response"} },
    { id = "ph.1043", en = "they are right",                tr = "Hakl\196\177lar.",                             direction = "forward", tags = {"response"} },
    { id = "ph.1044", en = "we are right",                  tr = "Hakl\196\177y\196\177z.",                     direction = "forward", tags = {"response"} },
    -- 3rd-person wrong
    { id = "ph.1045", en = "he is wrong",                   tr = "Yanl\196\177\197\159.",                       direction = "forward", tags = {"response"} },
    { id = "ph.1046", en = "she is wrong",                  tr = "Yanl\196\177\197\159.",                       direction = "forward", tags = {"response"} },
    { id = "ph.1047", en = "you are wrong",                 tr = "Yan\196\177l\196\177yorsun.",                  direction = "both", tags = {"response"} },
    { id = "ph.1048", en = "you're wrong",                  tr = "Yan\196\177l\196\177yorsun.",                  direction = "forward", tags = {"response"} },
    -- "X is okay" → iyi (well/fine), not tamam (agreed/OK)
    { id = "ph.1049", en = "you are okay",                  tr = "\196\176yisin.",                               direction = "both", tags = {"response"} },
    { id = "ph.1050", en = "you're okay",                   tr = "\196\176yisin.",                               direction = "forward", tags = {"response"} },
    { id = "ph.1051", en = "i am okay",                     tr = "\196\176yiyim.",                               direction = "both", tags = {"response"} },
    { id = "ph.1052", en = "im okay",                       tr = "\196\176yiyim.",                               direction = "forward", tags = {"response"} },
    { id = "ph.1053", en = "i'm okay",                      tr = "\196\176yiyim.",                               direction = "forward", tags = {"response"} },
    { id = "ph.1054", en = "he is okay",                    tr = "\196\176yi.",                                  direction = "forward", tags = {"response"} },
    { id = "ph.1055", en = "she is okay",                   tr = "\196\176yi.",                                  direction = "forward", tags = {"response"} },
    { id = "ph.1056", en = "they are okay",                 tr = "\196\176yiler.",                               direction = "forward", tags = {"response"} },
    -- Server-restart sense (reload.v now defaults to "doldur" for weapon-reload).
    -- These cover the admin/ops chat senses explicitly.
    { id = "ph.1057", en = "reload the server",             tr = "Sunucuyu yeniden ba\197\159lat.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1058", en = "restart the server",            tr = "Sunucuyu yeniden ba\197\159lat.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1059", en = "the server is restarting",      tr = "Sunucu yeniden ba\197\159l\196\177yor.",      direction = "forward", tags = {"chat"} },
    { id = "ph.1060", en = "the server crashed",            tr = "Sunucu \195\167\195\182kt\195\188.",         direction = "forward", tags = {"chat"} },
    -- Social meeting idioms — proper Turkish forms
    { id = "ph.1061", en = "nice to meet you",              tr = "Tan\196\177\197\159t\196\177\196\159\196\177m\196\177za memnun oldum.", direction = "both", tags = {"greeting"} },
    { id = "ph.1062", en = "pleasure to meet you",          tr = "Sizinle tan\196\177\197\159mak bir zevk.",    direction = "forward", tags = {"greeting"} },
    { id = "ph.1063", en = "good to see you",               tr = "Seni g\195\182rmek g\195\188zel.",            direction = "both", tags = {"greeting"} },
    { id = "ph.1064", en = "nice to see you",               tr = "Seni g\195\182rmek g\195\188zel.",            direction = "forward", tags = {"greeting"} },
    -- Trust — Turkish verb güvenmek takes DAT (sana/bana), not ACC
    { id = "ph.1065", en = "can i trust you",               tr = "Sana g\195\188venebilir miyim?",              direction = "both", tags = {"question"} },
    { id = "ph.1066", en = "do you trust me",               tr = "Bana g\195\188veniyor musun?",                direction = "both", tags = {"question"} },
    { id = "ph.1067", en = "i trust you",                   tr = "Sana g\195\188veniyorum.",                    direction = "both", tags = {"response"} },
    { id = "ph.1068", en = "i don't trust you",             tr = "Sana g\195\188venmiyorum.",                   direction = "forward", tags = {"response"} },
    { id = "ph.1069", en = "i dont trust you",              tr = "Sana g\195\188venmiyorum.",                   direction = "forward", tags = {"response"} },
    { id = "ph.1070", en = "rely on me",                    tr = "Bana g\195\188ven.",                            direction = "both", tags = {"response"} },
    { id = "ph.1071", en = "are you trustworthy",           tr = "G\195\188venilir misin?",                     direction = "both", tags = {"question"} },
    -- Gameplay coordination idioms
    { id = "ph.1072", en = "hold position",                 tr = "Konumda kal.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.1073", en = "hold your position",            tr = "Konumunda kal.",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1074", en = "on my mark",                    tr = "\196\176\197\159aretimle.",                   direction = "both", tags = {"chat"} },
    { id = "ph.1075", en = "wait for my signal",            tr = "Sinyalimi bekle.",                             direction = "both", tags = {"chat"} },
    { id = "ph.1076", en = "wait for my mark",              tr = "\196\176\197\159aretimi bekle.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1077", en = "get inside",                    tr = "\196\176\195\167eri gir.",                    direction = "both", tags = {"chat"} },
    { id = "ph.1078", en = "get outside",                   tr = "D\196\177\197\159ar\196\177 \195\167\196\177k.", direction = "forward", tags = {"chat"} },
    { id = "ph.1079", en = "take the left",                 tr = "Sola git.",                                    direction = "forward", tags = {"chat"} },
    { id = "ph.1080", en = "take the right",                tr = "Sa\196\159a git.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1081", en = "go left",                       tr = "Sola git.",                                    direction = "forward", tags = {"chat"} },
    { id = "ph.1082", en = "go right",                      tr = "Sa\196\159a git.",                            direction = "forward", tags = {"chat"} },
    -- State announcements
    { id = "ph.1083", en = "i am poisoned",                 tr = "Zehirlendim.",                                 direction = "both", tags = {"chat"} },
    { id = "ph.1084", en = "im poisoned",                   tr = "Zehirlendim.",                                 direction = "forward", tags = {"chat"} },
    { id = "ph.1085", en = "i'm poisoned",                  tr = "Zehirlendim.",                                 direction = "forward", tags = {"chat"} },
    { id = "ph.1086", en = "i need rest",                   tr = "Dinlenmeye ihtiyac\196\177m var.",            direction = "both", tags = {"chat"} },
    { id = "ph.1087", en = "i need to rest",                tr = "Dinlenmem laz\196\177m.",                     direction = "forward", tags = {"chat"} },
    { id = "ph.1088", en = "i need a break",                tr = "Molaya ihtiyac\196\177m var.",                direction = "both", tags = {"chat"} },
    -- Question word order fixes
    { id = "ph.1089", en = "what was that noise",           tr = "O ses neydi?",                                 direction = "both", tags = {"question"} },
    { id = "ph.1090", en = "what was that sound",           tr = "O ses neydi?",                                 direction = "forward", tags = {"question"} },
    { id = "ph.1091", en = "what is your story",            tr = "Hikayen nedir?",                               direction = "both", tags = {"question"} },
    { id = "ph.1092", en = "stop running",                  tr = "Ko\197\159may\196\177 b\196\177rak.",         direction = "both", tags = {"chat"} },
    -- Call X imperatives — engine confuses call.n (noun "call") with call.v
    -- (verb imperative "ara"). Phrasebook the chat-frequent forms.
    { id = "ph.1093", en = "call me",                       tr = "Beni ara.",                                    direction = "both", tags = {"chat"} },
    { id = "ph.1094", en = "call her",                      tr = "Onu ara.",                                     direction = "forward", tags = {"chat"} },
    { id = "ph.1095", en = "call him",                      tr = "Onu ara.",                                     direction = "forward", tags = {"chat"} },
    { id = "ph.1096", en = "call them",                     tr = "Onlar\196\177 ara.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1097", en = "do not call me",                tr = "Beni arama.",                                  direction = "both", tags = {"chat"} },
    { id = "ph.1098", en = "don't call me",                 tr = "Beni arama.",                                  direction = "forward", tags = {"chat"} },
    { id = "ph.1099", en = "dont call me",                  tr = "Beni arama.",                                  direction = "forward", tags = {"chat"} },
    { id = "ph.1100", en = "call for help",                 tr = "Yard\196\177m \195\167a\196\159\196\177r.",   direction = "forward", tags = {"chat"} },
    -- Conditional "if you V" / "when you V" clause fragments. Productive
    -- Pattern L needs aorist-conditional morphology in the engine;
    -- meanwhile the chat-frequent forms are phrasebook'd here. These
    -- render as Turkish conditional verb forms (-irsen/-iyorsan etc.) so
    -- the clause splitter can recombine with imperatives downstream.
    { id = "ph.1101", en = "if you see him",                tr = "Onu g\195\182r\195\188rsen",                  direction = "forward", tags = {"conditional"} },
    { id = "ph.1102", en = "if you see her",                tr = "Onu g\195\182r\195\188rsen",                  direction = "forward", tags = {"conditional"} },
    { id = "ph.1103", en = "if you see them",               tr = "Onlar\196\177 g\195\182r\195\188rsen",        direction = "forward", tags = {"conditional"} },
    { id = "ph.1104", en = "if you see me",                 tr = "Beni g\195\182r\195\188rsen",                 direction = "forward", tags = {"conditional"} },
    { id = "ph.1105", en = "if you see anything",           tr = "Bir \197\159ey g\195\182r\195\188rsen",       direction = "forward", tags = {"conditional"} },
    { id = "ph.1106", en = "if you hear something",         tr = "Bir \197\159ey duyarsan",                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1107", en = "if you hear anything",          tr = "Bir \197\159ey duyarsan",                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1108", en = "if you need help",              tr = "Yard\196\177ma ihtiyac\196\177n olursa",      direction = "forward", tags = {"conditional"} },
    { id = "ph.1109", en = "if you need me",                tr = "Bana ihtiyac\196\177n olursa",                direction = "forward", tags = {"conditional"} },
    { id = "ph.1110", en = "if you need anything",          tr = "Bir \197\159eye ihtiyac\196\177n olursa",     direction = "forward", tags = {"conditional"} },
    { id = "ph.1111", en = "if you find something",         tr = "Bir \197\159ey bulursan",                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1112", en = "if you find anything",          tr = "Bir \197\159ey bulursan",                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1113", en = "if you find him",               tr = "Onu bulursan",                                 direction = "forward", tags = {"conditional"} },
    { id = "ph.1114", en = "if you want",                   tr = "\196\176stersen",                              direction = "forward", tags = {"conditional"} },
    { id = "ph.1115", en = "if you want to",                tr = "\196\176stersen",                              direction = "forward", tags = {"conditional"} },
    { id = "ph.1116", en = "if you can",                    tr = "Yapabilirsen",                                 direction = "forward", tags = {"conditional"} },
    { id = "ph.1117", en = "if you are ready",              tr = "Haz\196\177rsan",                              direction = "forward", tags = {"conditional"} },
    { id = "ph.1118", en = "if you are okay",               tr = "\196\176yiysen",                               direction = "forward", tags = {"conditional"} },
    { id = "ph.1119", en = "if you are hurt",               tr = "Yaral\196\177ysan",                            direction = "forward", tags = {"conditional"} },
    { id = "ph.1120", en = "if you come",                   tr = "Gelirsen",                                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1121", en = "if you go",                     tr = "Gidersen",                                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1122", en = "if you leave",                  tr = "Gidersen",                                     direction = "forward", tags = {"conditional"} },
    { id = "ph.1123", en = "if you stay",                   tr = "Kal\196\177rsan",                              direction = "forward", tags = {"conditional"} },
    { id = "ph.1124", en = "if it rains",                   tr = "Ya\196\159mur ya\196\159arsa",                direction = "forward", tags = {"conditional"} },
    { id = "ph.1125", en = "if it snows",                   tr = "Kar ya\196\159arsa",                          direction = "forward", tags = {"conditional"} },
    { id = "ph.1126", en = "if it works",                   tr = "\195\135al\196\177\197\159\196\177rsa",       direction = "forward", tags = {"conditional"} },
    -- "When you V" common forms — Turkish uses -dığında (when) which the
    -- engine doesn't construct productively; phrasebook the high-frequency ones
    { id = "ph.1127", en = "when you arrive",               tr = "Geldi\196\159inde",                            direction = "forward", tags = {"conditional"} },
    { id = "ph.1128", en = "when you get there",            tr = "Oraya vard\196\177\196\159\196\177nda",       direction = "forward", tags = {"conditional"} },
    { id = "ph.1129", en = "when you are ready",            tr = "Haz\196\177r oldu\196\159unda",                direction = "forward", tags = {"conditional"} },
    { id = "ph.1130", en = "when you can",                  tr = "Yapabildi\196\159inde",                        direction = "forward", tags = {"conditional"} },
    { id = "ph.1131", en = "when you see him",              tr = "Onu g\195\182rd\195\188\196\159\195\188nde",   direction = "forward", tags = {"conditional"} },
    { id = "ph.1132", en = "when you hear something",       tr = "Bir \197\159ey duydu\196\159unda",             direction = "forward", tags = {"conditional"} },
    -- Door-knock sense — engine has knock.v -> tıklamak (mouse-click).
    -- For PZ door context, kapıyı çalmak / kapıyı vurmak is the natural form.
    { id = "ph.1133", en = "knock on the door",             tr = "Kap\196\177y\196\177 \195\167al.",           direction = "both", tags = {"chat"} },
    { id = "ph.1134", en = "knock first",                   tr = "\195\150nce kap\196\177y\196\177 \195\167al.", direction = "forward", tags = {"chat"} },
    -- Bare-present in conditional-consequent context (engine defaults bare
    -- verbs to PAST, intentional for read/cut/hit homographs but wrong here).
    { id = "ph.1135", en = "we stay",                       tr = "Kal\196\177r\196\177z.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1136", en = "we wait",                       tr = "Bekleriz.",                                     direction = "forward", tags = {"chat"} },
    { id = "ph.1137", en = "we go",                         tr = "Gideriz.",                                      direction = "forward", tags = {"chat"} },
    { id = "ph.1138", en = "we come",                       tr = "Geliriz.",                                      direction = "forward", tags = {"chat"} },
    { id = "ph.1139", en = "we leave",                      tr = "Ayr\196\177l\196\177r\196\177z.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1140", en = "we run",                        tr = "Ko\197\159ar\196\177z.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1141", en = "we hide",                       tr = "Saklan\196\177r\196\177z.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1142", en = "we fight",                      tr = "D\195\182v\195\188\197\159\195\188r\195\188z.", direction = "forward", tags = {"chat"} },
    -- High-stakes "want to" / "need to" + negation. Engine normalizes
    -- "want to X" -> "will X" which drops volition AND inverts negated
    -- forms ("do not want to X" -> "will X" gives the OPPOSITE meaning).
    -- Phrasebook the semantically critical cases.
    { id = "ph.1143", en = "i want to die",                 tr = "\195\150lmek istiyorum.",                      direction = "both", tags = {"emotional"} },
    { id = "ph.1144", en = "i do not want to die",          tr = "\195\150lmek istemiyorum.",                    direction = "both", tags = {"emotional"} },
    { id = "ph.1145", en = "i don't want to die",           tr = "\195\150lmek istemiyorum.",                    direction = "forward", tags = {"emotional"} },
    { id = "ph.1146", en = "i dont want to die",            tr = "\195\150lmek istemiyorum.",                    direction = "forward", tags = {"emotional"} },
    { id = "ph.1147", en = "i want to live",                tr = "Ya\197\159amak istiyorum.",                    direction = "both", tags = {"emotional"} },
    { id = "ph.1148", en = "i do not want to live",         tr = "Ya\197\159amak istemiyorum.",                  direction = "both", tags = {"emotional"} },
    { id = "ph.1149", en = "i don't want to live",          tr = "Ya\197\159amak istemiyorum.",                  direction = "forward", tags = {"emotional"} },
    { id = "ph.1150", en = "you do not need to be afraid",  tr = "Korkmana gerek yok.",                          direction = "both", tags = {"emotional"} },
    { id = "ph.1151", en = "you don't need to be afraid",   tr = "Korkmana gerek yok.",                          direction = "forward", tags = {"emotional"} },
    { id = "ph.1152", en = "you dont need to be afraid",    tr = "Korkmana gerek yok.",                          direction = "forward", tags = {"emotional"} },
    { id = "ph.1153", en = "do not be afraid",              tr = "Korkma.",                                       direction = "both", tags = {"emotional"} },
    { id = "ph.1154", en = "don't be afraid",               tr = "Korkma.",                                       direction = "forward", tags = {"emotional"} },
    { id = "ph.1155", en = "dont be afraid",                tr = "Korkma.",                                       direction = "forward", tags = {"emotional"} },
    { id = "ph.1156", en = "do not be scared",              tr = "Korkma.",                                       direction = "forward", tags = {"emotional"} },
    { id = "ph.1157", en = "don't be scared",               tr = "Korkma.",                                       direction = "forward", tags = {"emotional"} },
    -- Other want-to / need-to negation patterns (general)
    { id = "ph.1158", en = "i do not want to",              tr = "\196\176stemiyorum.",                          direction = "both", tags = {"response"} },
    { id = "ph.1159", en = "i don't want to",               tr = "\196\176stemiyorum.",                          direction = "forward", tags = {"response"} },
    { id = "ph.1160", en = "i dont want to",                tr = "\196\176stemiyorum.",                          direction = "forward", tags = {"response"} },
    { id = "ph.1161", en = "i do not want to go",           tr = "Gitmek istemiyorum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1162", en = "i don't want to go",            tr = "Gitmek istemiyorum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1163", en = "i do not want to leave",        tr = "Ayr\196\177lmak istemiyorum.",                direction = "forward", tags = {"chat"} },
    { id = "ph.1164", en = "i don't want to leave",         tr = "Ayr\196\177lmak istemiyorum.",                direction = "forward", tags = {"chat"} },
    { id = "ph.1165", en = "i do not want to stay",         tr = "Kalmak istemiyorum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1166", en = "i do not want to fight",        tr = "D\195\182v\195\188\197\159mek istemiyorum.", direction = "forward", tags = {"chat"} },
    { id = "ph.1167", en = "i do not want to talk",         tr = "Konu\197\159mak istemiyorum.",                direction = "forward", tags = {"chat"} },
    { id = "ph.1168", en = "i do not want to talk about it",tr = "Bunu konu\197\159mak istemiyorum.",           direction = "forward", tags = {"chat"} },
    { id = "ph.1169", en = "i do not need help",            tr = "Yard\196\177ma ihtiyac\196\177m yok.",        direction = "both", tags = {"chat"} },
    { id = "ph.1170", en = "i don't need help",             tr = "Yard\196\177ma ihtiyac\196\177m yok.",        direction = "forward", tags = {"chat"} },
    { id = "ph.1171", en = "you do not need to go",         tr = "Gitmene gerek yok.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1172", en = "you don't need to go",          tr = "Gitmene gerek yok.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1173", en = "you do not need to do this",    tr = "Bunu yapmana gerek yok.",                       direction = "forward", tags = {"chat"} },
    -- More RP-narrative idioms from the probe
    { id = "ph.1174", en = "i can hear them",               tr = "Onlar\196\177 duyabiliyorum.",                direction = "both", tags = {"chat"} },
    { id = "ph.1175", en = "i can hear them moving",        tr = "Hareket etiklerini duyabiliyorum.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1176", en = "i can hear something",          tr = "Bir \197\159ey duyuyorum.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1177", en = "something is wrong",            tr = "Bir \197\159eyler yanl\196\177\197\159.",     direction = "both", tags = {"chat"} },
    { id = "ph.1178", en = "something does not feel right", tr = "Bir \197\159eyler do\196\159ru hissetirmiyor.", direction = "forward", tags = {"chat"} },
    { id = "ph.1179", en = "something doesn't feel right",  tr = "Bir \197\159eyler do\196\159ru hissetirmiyor.", direction = "forward", tags = {"chat"} },
    { id = "ph.1180", en = "someone has been here",         tr = "Birisi buradayd\196\177.",                    direction = "forward", tags = {"chat"} },
    { id = "ph.1181", en = "show me your hands",            tr = "Ellerini g\195\182ster.",                     direction = "both", tags = {"chat"} },
    { id = "ph.1182", en = "tell me about yourself",        tr = "Kendinden bahset.",                            direction = "both", tags = {"chat"} },
    { id = "ph.1183", en = "i do not know you",             tr = "Seni tan\196\177m\196\177yorum.",             direction = "both", tags = {"chat"} },
    { id = "ph.1184", en = "i don't know you",              tr = "Seni tan\196\177m\196\177yorum.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1185", en = "have we met",                   tr = "Tan\196\177\197\159t\196\177k m\196\177?",    direction = "forward", tags = {"chat"} },
    { id = "ph.1186", en = "have we met before",            tr = "Daha \195\182nce tan\196\177\197\159t\196\177k m\196\177?", direction = "both", tags = {"chat"} },
    { id = "ph.1187", en = "i am running out of time",      tr = "Zaman\196\177m t\195\188keniyor.",            direction = "both", tags = {"chat"} },
    { id = "ph.1188", en = "i'm running out of time",       tr = "Zaman\196\177m t\195\188keniyor.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1189", en = "im running out of time",        tr = "Zaman\196\177m t\195\188keniyor.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1190", en = "we are running out of time",    tr = "Zaman\196\177m\196\177z t\195\188keniyor.",  direction = "forward", tags = {"chat"} },
    { id = "ph.1191", en = "we're running out of time",     tr = "Zaman\196\177m\196\177z t\195\188keniyor.",  direction = "forward", tags = {"chat"} },
    { id = "ph.1192", en = "we are running out of ammo",    tr = "Mermimiz t\195\188keniyor.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1193", en = "things will get better",        tr = "\196\176\197\159ler d\195\188zelecek.",       direction = "both", tags = {"chat"} },
    { id = "ph.1194", en = "everyone we knew is gone",      tr = "Tan\196\177d\196\177\196\159\196\177m\196\177z herkes gitti.", direction = "forward", tags = {"chat"} },
    { id = "ph.1195", en = "i have been alone for weeks",   tr = "Haftalard\196\177r yaln\196\177z\196\177m.", direction = "forward", tags = {"chat"} },
    { id = "ph.1196", en = "i have been alone for days",    tr = "G\195\188nlerdir yaln\196\177z\196\177m.",   direction = "forward", tags = {"chat"} },
    { id = "ph.1197", en = "i have seen too much",          tr = "\195\135ok \197\159ey g\195\182rd\195\188m.", direction = "both", tags = {"chat"} },
    { id = "ph.1198", en = "i miss them",                   tr = "Onlar\196\177 \195\182zl\195\188yorum.",     direction = "both", tags = {"chat"} },
    { id = "ph.1199", en = "i miss you",                    tr = "Seni \195\182zl\195\188yorum.",              direction = "both", tags = {"chat"} },
    { id = "ph.1200", en = "i miss home",                   tr = "Evi \195\182zl\195\188yorum.",               direction = "forward", tags = {"chat"} },
    { id = "ph.1201", en = "i had a family",                tr = "Bir ailem vard\196\177.",                     direction = "forward", tags = {"backstory"} },
    { id = "ph.1202", en = "i had a wife",                  tr = "Bir kar\196\177m vard\196\177.",              direction = "forward", tags = {"backstory"} },
    { id = "ph.1203", en = "i had a husband",               tr = "Bir kocam vard\196\177.",                     direction = "forward", tags = {"backstory"} },
    { id = "ph.1204", en = "i had a son",                   tr = "Bir o\196\159lum vard\196\177.",              direction = "forward", tags = {"backstory"} },
    { id = "ph.1205", en = "i had a daughter",              tr = "Bir k\196\177z\196\177m vard\196\177.",      direction = "forward", tags = {"backstory"} },
    { id = "ph.1206", en = "i was a doctor",                tr = "Bir doktordum.",                                direction = "both", tags = {"backstory"} },
    { id = "ph.1207", en = "i was a soldier",               tr = "Bir askerdim.",                                 direction = "forward", tags = {"backstory"} },
    { id = "ph.1208", en = "i was a teacher",               tr = "Bir \195\182\196\159retmendim.",              direction = "forward", tags = {"backstory"} },
    { id = "ph.1209", en = "i was a nurse",                 tr = "Bir hem\197\159ireydim.",                     direction = "forward", tags = {"backstory"} },
    { id = "ph.1210", en = "i was a cop",                   tr = "Bir polistim.",                                 direction = "forward", tags = {"backstory"} },
    { id = "ph.1211", en = "i was a police officer",        tr = "Bir polis memurudum.",                          direction = "forward", tags = {"backstory"} },
    -- Spatial prepositions: multi-word preps + pronouns. Productive Pattern
    -- M for these needs engine plumbing for multi-token preps; phrasebook
    -- the chat-frequent fixed forms.
    { id = "ph.1212", en = "stand next to me",              tr = "Yan\196\177mda dur.",                          direction = "both", tags = {"chat"} },
    { id = "ph.1213", en = "next to me",                    tr = "Yan\196\177mda",                               direction = "forward", tags = {"spatial"} },
    { id = "ph.1214", en = "next to you",                   tr = "Yan\196\177nda",                               direction = "forward", tags = {"spatial"} },
    { id = "ph.1215", en = "next to him",                   tr = "Onun yan\196\177nda",                          direction = "forward", tags = {"spatial"} },
    { id = "ph.1216", en = "next to her",                   tr = "Onun yan\196\177nda",                          direction = "forward", tags = {"spatial"} },
    { id = "ph.1217", en = "in front of me",                tr = "\195\150n\195\188mde",                         direction = "forward", tags = {"spatial"} },
    { id = "ph.1218", en = "in front of you",               tr = "\195\150n\195\188nde",                         direction = "forward", tags = {"spatial"} },
    { id = "ph.1219", en = "in front of the door",          tr = "Kap\196\177n\196\177n \195\182n\195\188nde",  direction = "forward", tags = {"spatial"} },
    { id = "ph.1220", en = "behind me",                     tr = "Arkamda",                                       direction = "forward", tags = {"spatial"} },
    { id = "ph.1222", en = "on top of the roof",            tr = "\195\135at\196\177n\196\177n \195\188st\195\188nde", direction = "forward", tags = {"spatial"} },
    { id = "ph.1223", en = "on the roof",                   tr = "\195\135at\196\177da",                         direction = "forward", tags = {"spatial"} },
    { id = "ph.1224", en = "get on the roof",               tr = "\195\135at\196\177ya \195\167\196\177k.",     direction = "forward", tags = {"chat"} },
    { id = "ph.1225", en = "get off the roof",              tr = "\195\135at\196\177dan in.",                    direction = "forward", tags = {"chat"} },
    { id = "ph.1226", en = "across the street",             tr = "Yolun kar\197\159\196\177s\196\177nda",        direction = "forward", tags = {"spatial"} },
    { id = "ph.1227", en = "across the road",               tr = "Yolun kar\197\159\196\177s\196\177nda",        direction = "forward", tags = {"spatial"} },
    { id = "ph.1228", en = "he is across the street",       tr = "Yolun kar\197\159\196\177s\196\177nda.",       direction = "forward", tags = {"chat"} },
    { id = "ph.1229", en = "she is across the street",      tr = "Yolun kar\197\159\196\177s\196\177nda.",       direction = "forward", tags = {"chat"} },
    { id = "ph.1230", en = "meet me by the river",          tr = "Nehir kenar\196\177nda bulu\197\159al\196\177m.", direction = "forward", tags = {"chat"} },
    { id = "ph.1231", en = "by the river",                  tr = "Nehir kenar\196\177nda",                       direction = "forward", tags = {"spatial"} },
    { id = "ph.1232", en = "by the door",                   tr = "Kap\196\177n\196\177n yan\196\177nda",         direction = "forward", tags = {"spatial"} },
    -- "look above" / "look below" — adverbial form without object
    { id = "ph.1233", en = "look above",                    tr = "Yukar\196\177 bak.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1234", en = "look up",                       tr = "Yukar\196\177 bak.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1235", en = "look below",                    tr = "A\197\159a\196\159\196\177 bak.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1236", en = "look down",                     tr = "A\197\159a\196\159\196\177 bak.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1237", en = "look around",                   tr = "Etrafa bak.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1271", en = "look above you",                tr = "\195\156st\195\188ne bak.",                    direction = "forward", tags = {"chat"} },
    { id = "ph.1272", en = "look behind you",               tr = "Arkana bak.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1273", en = "get on top of the roof",        tr = "\195\135at\196\177n\196\177n \195\188st\195\188ne \195\167\196\177k.", direction = "forward", tags = {"chat"} },
    { id = "ph.1274", en = "the keys are in front of the door", tr = "Anahtarlar kap\196\177n\196\177n \195\182n\195\188nde.", direction = "forward", tags = {"chat"} },
    { id = "ph.1275", en = "in front of",                   tr = "\195\182n\195\188nde",                         direction = "forward", tags = {"spatial"} },
    { id = "ph.1276", en = "on top of",                     tr = "\195\188st\195\188nde",                        direction = "forward", tags = {"spatial"} },
    { id = "ph.1277", en = "next to the door",              tr = "Kap\196\177n\196\177n yan\196\177nda",         direction = "forward", tags = {"spatial"} },
    { id = "ph.1278", en = "next to the window",            tr = "Pencerenin yan\196\177nda",                    direction = "forward", tags = {"spatial"} },
    -- Time idioms — "last night" / "in X" / "for X"
    { id = "ph.1279", en = "last night",                    tr = "D\195\188n gece",                              direction = "forward", tags = {"time"} },
    { id = "ph.1280", en = "tomorrow night",                tr = "Yar\196\177n gece",                            direction = "forward", tags = {"time"} },
    { id = "ph.1281", en = "this morning",                  tr = "Bu sabah",                                      direction = "forward", tags = {"time"} },
    { id = "ph.1282", en = "this evening",                  tr = "Bu ak\197\159am",                              direction = "forward", tags = {"time"} },
    { id = "ph.1283", en = "this afternoon",                tr = "Bu \195\182\196\159leden sonra",              direction = "forward", tags = {"time"} },
    { id = "ph.1284", en = "in an hour",                    tr = "Bir saat i\195\167inde",                      direction = "forward", tags = {"time"} },
    { id = "ph.1285", en = "in a minute",                   tr = "Bir dakika i\195\167inde",                    direction = "forward", tags = {"time"} },
    { id = "ph.1286", en = "in two days",                   tr = "\196\176ki g\195\188n i\195\167inde",         direction = "forward", tags = {"time"} },
    { id = "ph.1287", en = "in five minutes",               tr = "Be\197\159 dakika i\195\167inde",             direction = "forward", tags = {"time"} },
    { id = "ph.1288", en = "in ten minutes",                tr = "On dakika i\195\167inde",                     direction = "forward", tags = {"time"} },
    { id = "ph.1289", en = "for days",                      tr = "G\195\188nlerdir",                              direction = "forward", tags = {"time"} },
    { id = "ph.1290", en = "for hours",                     tr = "Saatlerdir",                                    direction = "forward", tags = {"time"} },
    { id = "ph.1291", en = "for weeks",                     tr = "Haftalard\196\177r",                           direction = "forward", tags = {"time"} },
    { id = "ph.1292", en = "for months",                    tr = "Aylard\196\177r",                              direction = "forward", tags = {"time"} },
    { id = "ph.1293", en = "for years",                     tr = "Y\196\177llard\196\177r",                     direction = "forward", tags = {"time"} },
    { id = "ph.1294", en = "i have not slept for days",     tr = "G\195\188nlerdir uyumad\196\177m.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1295", en = "i havent slept for days",       tr = "G\195\188nlerdir uyumad\196\177m.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1296", en = "she has been gone for hours",   tr = "Saatlerdir yok.",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1297", en = "he has been gone for hours",    tr = "Saatlerdir yok.",                               direction = "forward", tags = {"chat"} },
    -- Imperatives the engine breaks
    { id = "ph.1298", en = "stop right there",              tr = "Hemen orada dur.",                              direction = "both", tags = {"chat"} },
    { id = "ph.1299", en = "do not look at me",             tr = "Bana bakma.",                                   direction = "both", tags = {"chat"} },
    { id = "ph.1300", en = "don't look at me",              tr = "Bana bakma.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1301", en = "never give up",                 tr = "Asla pes etme.",                                direction = "both", tags = {"chat"} },
    { id = "ph.1302", en = "never come back",               tr = "Bir daha asla geri gelme.",                     direction = "forward", tags = {"chat"} },
    { id = "ph.1303", en = "never lose hope",               tr = "Asla umudunu kaybetme.",                        direction = "forward", tags = {"chat"} },
    -- Speech act verbs — "he told me to X" / "she said X" idioms
    -- Engine collapses these awkwardly; productive Pattern N needed for full coverage
    { id = "ph.1239", en = "he told me to leave",           tr = "Bana ayr\196\177lmam\196\177 s\195\182yledi.", direction = "forward", tags = {"chat"} },
    { id = "ph.1240", en = "she told me to leave",          tr = "Bana ayr\196\177lmam\196\177 s\195\182yledi.", direction = "forward", tags = {"chat"} },
    { id = "ph.1241", en = "he told me to go",              tr = "Bana gitmemi s\195\182yledi.",                 direction = "forward", tags = {"chat"} },
    { id = "ph.1242", en = "she told me to go",             tr = "Bana gitmemi s\195\182yledi.",                 direction = "forward", tags = {"chat"} },
    { id = "ph.1243", en = "he told me to wait",            tr = "Bana beklememi s\195\182yledi.",               direction = "forward", tags = {"chat"} },
    { id = "ph.1244", en = "she told me to wait",           tr = "Bana beklememi s\195\182yledi.",               direction = "forward", tags = {"chat"} },
    { id = "ph.1245", en = "i told her i was sorry",        tr = "Ona \195\182z\195\188r diledim.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1246", en = "i told him i was sorry",        tr = "Ona \195\182z\195\188r diledim.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1247", en = "he said hello",                 tr = "Selam dedi.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1248", en = "she said hello",                tr = "Selam dedi.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1249", en = "he said nothing",               tr = "Hi\195\167bir \197\159ey demedi.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1250", en = "she said nothing",              tr = "Hi\195\167bir \197\159ey demedi.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1251", en = "i said nothing",                tr = "Hi\195\167bir \197\159ey demedim.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1252", en = "she asked me where i was going",tr = "Bana nereye gitti\196\159imi sordu.",         direction = "forward", tags = {"chat"} },
    { id = "ph.1253", en = "he asked me where i was going", tr = "Bana nereye gitti\196\159imi sordu.",         direction = "forward", tags = {"chat"} },
    -- Sound/observation: "I heard footsteps", "footsteps" not in lex
    { id = "ph.1254", en = "i heard footsteps",             tr = "Ayak sesleri duydum.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1255", en = "i hear footsteps",              tr = "Ayak sesleri duyuyorum.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1256", en = "i heard a noise",               tr = "Bir ses duydum.",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1257", en = "i hear a noise",                tr = "Bir ses duyuyorum.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1258", en = "did you hear footsteps",        tr = "Ayak sesleri duydun mu?",                       direction = "forward", tags = {"chat"} },
    -- Continuation/temporal narrative
    { id = "ph.1259", en = "then i saw him",                tr = "Sonra onu g\195\182rd\195\188m.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1260", en = "then i saw her",                tr = "Sonra onu g\195\182rd\195\188m.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1261", en = "no one came",                   tr = "Kimse gelmedi.",                                direction = "forward", tags = {"chat"} },
    { id = "ph.1262", en = "no one is here",                tr = "Burada kimse yok.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.1263", en = "no one is coming",              tr = "Kimse gelmiyor.",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1264", en = "someone walked in",             tr = "Birisi i\195\167eri y\195\188r\195\188d\195\188.", direction = "forward", tags = {"chat"} },
    { id = "ph.1265", en = "the door opened",               tr = "Kap\196\177 a\195\167\196\177ld\196\177.",     direction = "forward", tags = {"chat"} },
    { id = "ph.1266", en = "the door closed",               tr = "Kap\196\177 kapand\196\177.",                  direction = "forward", tags = {"chat"} },
    { id = "ph.1267", en = "it was empty",                  tr = "Bo\197\159tu.",                                 direction = "forward", tags = {"chat"} },
    { id = "ph.1268", en = "it is empty",                   tr = "Bo\197\159.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1269", en = "it was quiet",                  tr = "Sessizdi.",                                     direction = "forward", tags = {"chat"} },
    { id = "ph.1270", en = "everything was quiet",          tr = "Her \197\159ey sessizdi.",                      direction = "forward", tags = {"chat"} },
    -- "VERB at X" — these English verbs take DAT in Turkish (bakmak, ateş etmek,
    -- nişan almak). The at.prep defaults to LOC. Phrasebook the chat-frequent
    -- person-object combinations.
    { id = "ph.1304", en = "she looked at me",              tr = "Bana bakt\196\177.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1305", en = "he looked at me",               tr = "Bana bakt\196\177.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1306", en = "she looked at him",             tr = "Ona bakt\196\177.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1307", en = "she looked at her",             tr = "Ona bakt\196\177.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1308", en = "he looked at her",              tr = "Ona bakt\196\177.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1309", en = "i looked at him",               tr = "Ona bakt\196\177m.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1310", en = "i looked at her",               tr = "Ona bakt\196\177m.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1311", en = "i looked at you",               tr = "Sana bakt\196\177m.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1312", en = "they looked at me",             tr = "Bana bakt\196\177lar.",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1313", en = "they looked at us",             tr = "Bize bakt\196\177lar.",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1314", en = "look at this",                  tr = "Buna bak.",                                     direction = "both", tags = {"chat"} },
    { id = "ph.1315", en = "look at that",                  tr = "\197\158una bak.",                              direction = "both", tags = {"chat"} },
    { id = "ph.1316", en = "shoot at them",                 tr = "Onlara ate\197\159 et.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1317", en = "shoot at it",                   tr = "Ona ate\197\159 et.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1318", en = "do not shoot at me",            tr = "Bana ate\197\159 etme.",                       direction = "both", tags = {"chat"} },
    { id = "ph.1319", en = "dont shoot at me",              tr = "Bana ate\197\159 etme.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1320", en = "aim at the head",               tr = "Ba\197\159a ni\197\159an al.",                direction = "forward", tags = {"chat"} },
    { id = "ph.1321", en = "aim at them",                   tr = "Onlara ni\197\159an al.",                      direction = "forward", tags = {"chat"} },
    -- More multi-sentence narrative completions from the RP probe
    { id = "ph.1322", en = "everyone was grateful",         tr = "Herkes minnettard\196\177.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1323", en = "i could not say anything",      tr = "Hi\195\167bir \197\159ey s\195\182yleyemedim.", direction = "forward", tags = {"chat"} },
    { id = "ph.1324", en = "i couldn't say anything",       tr = "Hi\195\167bir \197\159ey s\195\182yleyemedim.", direction = "forward", tags = {"chat"} },
    { id = "ph.1325", en = "i couldnt say anything",        tr = "Hi\195\167bir \197\159ey s\195\182yleyemedim.", direction = "forward", tags = {"chat"} },
    { id = "ph.1326", en = "the silence was heavy",         tr = "Sessizlik a\196\159\196\177rd\196\177.",       direction = "forward", tags = {"chat"} },
    { id = "ph.1327", en = "the wind was cold",             tr = "R\195\188zgar so\196\159uktu.",                direction = "forward", tags = {"chat"} },
    { id = "ph.1328", en = "i tried to forget",             tr = "Unutmaya \195\167al\196\177\197\159t\196\177m.", direction = "forward", tags = {"chat"} },
    { id = "ph.1329", en = "i never slept well",            tr = "Hi\195\167 iyi uyumad\196\177m.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1330", en = "he had been waiting",           tr = "Bekliyordu.",                                    direction = "forward", tags = {"chat"} },
    { id = "ph.1331", en = "she had been waiting",          tr = "Bekliyordu.",                                    direction = "forward", tags = {"chat"} },
    { id = "ph.1332", en = "he was already there",          tr = "Zaten oradayd\196\177.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1333", en = "she was already there",         tr = "Zaten oradayd\196\177.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1334", en = "asking for help",               tr = "Yard\196\177m istiyor",                         direction = "forward", tags = {"chat"} },
    { id = "ph.1335", en = "she was asking for help",       tr = "Yard\196\177m istiyordu.",                     direction = "forward", tags = {"chat"} },
    { id = "ph.1336", en = "he was asking for help",        tr = "Yard\196\177m istiyordu.",                     direction = "forward", tags = {"chat"} },
    -- Direction verbs need DAT
    { id = "ph.1337", en = "moved north",                   tr = "kuzeye hareket etti",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1338", en = "moved south",                   tr = "g\195\188neye hareket etti",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1339", en = "moved east",                    tr = "do\196\159uya hareket etti",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1340", en = "moved west",                    tr = "bat\196\177ya hareket etti",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1341", en = "the horde moved north",         tr = "S\195\188r\195\188 kuzeye hareket etti.",      direction = "forward", tags = {"chat"} },
    { id = "ph.1342", en = "the horde moved south",         tr = "S\195\188r\195\188 g\195\188neye hareket etti.", direction = "forward", tags = {"chat"} },
    -- Radio chat
    { id = "ph.1343", en = "the radio crackled",            tr = "Radyo c\196\177z\196\177rdad\196\177.",       direction = "forward", tags = {"chat"} },
    { id = "ph.1344", en = "radio crackled",                tr = "Radyo c\196\177z\196\177rdad\196\177.",       direction = "forward", tags = {"chat"} },
    -- DAT-verb additions: "help/trust/believe" + recipients with proper Turkish DAT.
    -- The engine'\''s dat_obj subcat handles open-class cases; these phrasebook entries
    -- cover specific chat-frequent forms where the engine path is blocked by
    -- prefix-matched older phrasebook entries or by modal/question context wrinkles.
    { id = "ph.1423", en = "can you help me",               tr = "Bana yard\196\177m edebilir misin?",          direction = "both", tags = {"question"} },
    { id = "ph.1424", en = "will you help me",              tr = "Bana yard\196\177m eder misin?",              direction = "both", tags = {"question"} },
    { id = "ph.1425", en = "please help me",                tr = "L\195\188tfen bana yard\196\177m et.",         direction = "both", tags = {"request"} },
    { id = "ph.1426", en = "help me please",                tr = "Bana yard\196\177m et l\195\188tfen.",        direction = "both", tags = {"request"} },
    { id = "ph.1427", en = "i believe you",                 tr = "Sana inan\196\177yorum.",                      direction = "forward", tags = {"chat"} },
    { id = "ph.1428", en = "i believed you",                tr = "Sana inand\196\177m.",                         direction = "forward", tags = {"chat"} },
    { id = "ph.1429", en = "do you believe me",             tr = "Bana inan\196\177yor musun?",                  direction = "both", tags = {"question"} },
    -- Modal-past constructions (SHOULD HAVE / WOULD HAVE / COULD HAVE / MUST HAVE).
    -- Engine collapses to bare modal which loses past/regret/counterfactual
    -- nuance. Turkish uses -mAlIydI / -EcEktI / -EbilirdI etc. for these.
    -- High-stakes: "I should have gone" vs "I should go" mean different things.
    { id = "ph.1345", en = "i should have gone",            tr = "Gitmem gerekirdi.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.1346", en = "i should have stayed",          tr = "Kalmam gerekirdi.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.1347", en = "i should have known",           tr = "Bilmem gerekirdi.",                             direction = "forward", tags = {"chat"} },
    { id = "ph.1348", en = "i should have listened",        tr = "Dinlemem gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1349", en = "i should have helped",          tr = "Yard\196\177m etmem gerekirdi.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1350", en = "i should not have gone",        tr = "Gitmemem gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1351", en = "i shouldn't have gone",         tr = "Gitmemem gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1352", en = "i shouldnt have gone",          tr = "Gitmemem gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1353", en = "i shouldn't have said that",    tr = "Bunu s\195\182ylememem gerekirdi.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1354", en = "i shouldnt have said that",     tr = "Bunu s\195\182ylememem gerekirdi.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1355", en = "i shouldn't have left",         tr = "Ayr\196\177lmamam gerekirdi.",                 direction = "forward", tags = {"chat"} },
    { id = "ph.1356", en = "you should have waited",        tr = "Beklemen gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1357", en = "you should have listened",      tr = "Dinlemen gerekirdi.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1358", en = "you should have told me",       tr = "Bana s\195\182ylemen gerekirdi.",              direction = "forward", tags = {"chat"} },
    { id = "ph.1359", en = "she should have known",         tr = "Bilmesi gerekirdi.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1360", en = "he should have known",          tr = "Bilmesi gerekirdi.",                            direction = "forward", tags = {"chat"} },
    -- could have (past ability/possibility)
    { id = "ph.1361", en = "you could have helped",         tr = "Yard\196\177m edebilirdin.",                   direction = "forward", tags = {"chat"} },
    { id = "ph.1362", en = "she could have died",           tr = "\195\150lebilirdi.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1363", en = "he could have died",            tr = "\195\150lebilirdi.",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1364", en = "we could have been killed",     tr = "\195\150ld\195\188r\195\188lebilirdik.",       direction = "forward", tags = {"chat"} },
    { id = "ph.1365", en = "i could have helped",           tr = "Yard\196\177m edebilirdim.",                   direction = "forward", tags = {"chat"} },
    -- might have / must have (past inference)
    { id = "ph.1366", en = "i might have been wrong",       tr = "Yan\196\177lm\196\177\197\159 olabilirim.",   direction = "forward", tags = {"chat"} },
    { id = "ph.1367", en = "he must have heard us",         tr = "Bizi duymu\197\159 olmal\196\177.",           direction = "forward", tags = {"chat"} },
    { id = "ph.1368", en = "she must have seen us",         tr = "Bizi g\195\182rm\195\188\197\159 olmal\196\177.", direction = "forward", tags = {"chat"} },
    { id = "ph.1369", en = "they must have gone",           tr = "Gitmi\197\159 olmal\196\177lar.",             direction = "forward", tags = {"chat"} },
    -- would have (counterfactual)
    { id = "ph.1370", en = "i would have come",             tr = "Gelecektim.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1371", en = "we would have come",            tr = "Gelecektik.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1372", en = "we would have stayed",          tr = "Kalacakt\196\177k.",                           direction = "forward", tags = {"chat"} },
    { id = "ph.1373", en = "i would have helped",           tr = "Yard\196\177m edecektim.",                     direction = "forward", tags = {"chat"} },
    { id = "ph.1374", en = "i would have stayed",           tr = "Kalacakt\196\177m.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1419", en = "we could have died",            tr = "\195\150lebilirdik.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1420", en = "they could have died",          tr = "\195\150lebilirlerdi.",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1421", en = "i could have died",             tr = "\195\150lebilirdim.",                          direction = "forward", tags = {"chat"} },
    { id = "ph.1422", en = "you could have died",           tr = "\195\150lebilirdin.",                          direction = "forward", tags = {"chat"} },
    -- Partitive quantifiers — "X of Y" structure
    { id = "ph.1375", en = "all of them are dead",          tr = "Hepsi \195\182l\195\188.",                    direction = "forward", tags = {"chat"} },
    { id = "ph.1376", en = "all of them are gone",          tr = "Hepsi gitti.",                                  direction = "forward", tags = {"chat"} },
    { id = "ph.1377", en = "all of them",                   tr = "Hepsi",                                         direction = "forward", tags = {"chat"} },
    { id = "ph.1378", en = "all of us",                     tr = "Hepimiz",                                       direction = "forward", tags = {"chat"} },
    { id = "ph.1379", en = "all of you",                    tr = "Hepiniz",                                       direction = "forward", tags = {"chat"} },
    { id = "ph.1380", en = "none of them",                  tr = "Hi\195\167biri",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1381", en = "none of us",                    tr = "Hi\195\167birimiz",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1382", en = "none of you",                   tr = "Hi\195\167biriniz",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1383", en = "none of us survived",           tr = "Hi\195\167birimiz hayatta kalmad\196\177.",   direction = "forward", tags = {"chat"} },
    { id = "ph.1384", en = "both of us",                    tr = "\196\176kimiz de",                              direction = "forward", tags = {"chat"} },
    { id = "ph.1385", en = "both of you",                   tr = "\196\176kiniz de",                              direction = "forward", tags = {"chat"} },
    { id = "ph.1386", en = "both of them",                  tr = "\196\176kisi de",                               direction = "forward", tags = {"chat"} },
    { id = "ph.1387", en = "both of us are here",           tr = "\196\176kimiz de buraday\196\177z.",          direction = "forward", tags = {"chat"} },
    { id = "ph.1388", en = "half of them",                  tr = "Yar\196\177s\196\177",                        direction = "forward", tags = {"chat"} },
    { id = "ph.1389", en = "half of them are infected",     tr = "Yar\196\177s\196\177 enfekte.",               direction = "forward", tags = {"chat"} },
    { id = "ph.1390", en = "most of them",                  tr = "\195\135o\196\159u",                            direction = "forward", tags = {"chat"} },
    { id = "ph.1391", en = "most of them ran",              tr = "\195\135o\196\159u ka\195\167t\196\177.",     direction = "forward", tags = {"chat"} },
    { id = "ph.1392", en = "some of us",                    tr = "Baz\196\177lar\196\177m\196\177z",            direction = "forward", tags = {"chat"} },
    { id = "ph.1393", en = "some of us stayed",             tr = "Baz\196\177lar\196\177m\196\177z kald\196\177.", direction = "forward", tags = {"chat"} },
    { id = "ph.1394", en = "some of them",                  tr = "Baz\196\177lar\196\177",                      direction = "forward", tags = {"chat"} },
    -- Are you X? copular question fixes
    { id = "ph.1395", en = "are you okay",                  tr = "\196\176yi misin?",                            direction = "both", tags = {"question"} },
    { id = "ph.1396", en = "are you ok",                    tr = "\196\176yi misin?",                            direction = "forward", tags = {"question"} },
    { id = "ph.1397", en = "you look pale",                 tr = "Solgun g\195\182r\195\188n\195\188yorsun.",   direction = "forward", tags = {"chat"} },
    { id = "ph.1398", en = "you look tired",                tr = "Yorgun g\195\182r\195\188n\195\188yorsun.",   direction = "forward", tags = {"chat"} },
    { id = "ph.1399", en = "you look sick",                 tr = "Hasta g\195\182r\195\188n\195\188yorsun.",    direction = "forward", tags = {"chat"} },
    { id = "ph.1400", en = "you look scared",               tr = "Korkmu\197\159 g\195\182r\195\188n\195\188yorsun.", direction = "forward", tags = {"chat"} },
    { id = "ph.1401", en = "you look worried",              tr = "End\196\177\197\159eli g\195\182r\195\188n\195\188yorsun.", direction = "forward", tags = {"chat"} },
    { id = "ph.1402", en = "did something happen",          tr = "Bir \197\159ey mi oldu?",                     direction = "forward", tags = {"question"} },
    -- Now look at us
    { id = "ph.1403", en = "now look at us",                tr = "\197\158imdi bize bak.",                       direction = "forward", tags = {"chat"} },
    { id = "ph.1404", en = "look at us",                    tr = "Bize bak.",                                     direction = "forward", tags = {"chat"} },
    -- "I told you not to V"
    { id = "ph.1405", en = "i told you not to go",          tr = "Sana gitme demi\197\159tim.",                 direction = "forward", tags = {"chat"} },
    { id = "ph.1406", en = "i told you not to do that",     tr = "Sana onu yapma demi\197\159tim.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1407", en = "i told you",                    tr = "Sana s\195\182ylemi\197\159tim.",             direction = "forward", tags = {"chat"} },
    { id = "ph.1408", en = "you did not listen",            tr = "Dinlemedin.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1409", en = "you didn't listen",             tr = "Dinlemedin.",                                   direction = "forward", tags = {"chat"} },
    { id = "ph.1410", en = "you didnt listen",              tr = "Dinlemedin.",                                   direction = "forward", tags = {"chat"} },
    -- Dialogue continuity fixes
    { id = "ph.1411", en = "pack your things",              tr = "E\197\159yalar\196\177n\196\177 topla.",      direction = "forward", tags = {"chat"} },
    { id = "ph.1412", en = "pack your stuff",               tr = "E\197\159yalar\196\177n\196\177 topla.",      direction = "forward", tags = {"chat"} },
    { id = "ph.1413", en = "meet me at the car",            tr = "Arabada bulu\197\159al\196\177m.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1414", en = "meet at the car",               tr = "Arabada bulu\197\159al\196\177m.",            direction = "forward", tags = {"chat"} },
    { id = "ph.1415", en = "just breathe",                  tr = "Sadece nefes al.",                              direction = "forward", tags = {"chat"} },
    { id = "ph.1416", en = "everything will be fine",       tr = "Her \197\159ey iyi olacak.",                   direction = "both", tags = {"chat"} },
    { id = "ph.1417", en = "everything is fine",            tr = "Her \197\159ey iyi.",                          direction = "both", tags = {"chat"} },
}

-- ---------------------------------------------------------------------------
-- Build the lookup index. Keys are normalised: lowercased, terminator stripped.
-- ---------------------------------------------------------------------------

-- Contraction expansion. Both contracted ("i'm at the base") and expanded
-- ("i am at the base") forms normalize to the same canonical key, so a
-- single phrasebook entry catches both. Without this, players who write
-- the expanded form miss every entry stored in contracted form (and vice
-- versa) -- the most frequent gap surfaced by the 8.9.14+ audit pushes.
--
-- Applied after lowercasing, before terminator strip. English-only by
-- intent: Turkish doesn't use these patterns. (Turkish does use ' as a
-- proper-noun suffix marker, e.g. "Istanbul'da", but none of the
-- contraction patterns below match Turkish strings.)
--
-- Where a contraction is ambiguous (e.g. "he's" = "he is" OR "he has"),
-- we expand to the far more common reading ("he is"). The other reading
-- can still be addressed by a phrasebook entry written in the rarer
-- expanded form if needed.
local CONTRACTIONS = {
    ["i'm"]       = "i am",
    ["you're"]    = "you are",
    ["we're"]     = "we are",
    ["they're"]   = "they are",
    ["he's"]      = "he is",
    ["she's"]     = "she is",
    ["it's"]      = "it is",
    ["that's"]    = "that is",
    ["what's"]    = "what is",
    ["where's"]   = "where is",
    ["there's"]   = "there is",
    ["here's"]    = "here is",
    ["how's"]     = "how is",
    ["who's"]     = "who is",
    ["let's"]     = "let us",
    ["can't"]     = "cannot",
    ["won't"]     = "will not",
    ["don't"]     = "do not",
    ["doesn't"]   = "does not",
    ["didn't"]    = "did not",
    ["shouldn't"] = "should not",
    ["wouldn't"]  = "would not",
    ["couldn't"]  = "could not",
    ["mustn't"]   = "must not",
    ["isn't"]     = "is not",
    ["aren't"]    = "are not",
    ["wasn't"]    = "was not",
    ["weren't"]   = "were not",
    ["haven't"]   = "have not",
    ["hasn't"]    = "has not",
    ["hadn't"]    = "had not",
    ["i'll"]      = "i will",
    ["you'll"]    = "you will",
    ["we'll"]     = "we will",
    ["they'll"]   = "they will",
    ["he'll"]     = "he will",
    ["she'll"]    = "she will",
    ["it'll"]     = "it will",
    ["i've"]      = "i have",
    ["you've"]    = "you have",
    ["we've"]     = "we have",
    ["they've"]   = "they have",
    ["i'd"]       = "i would",
    ["you'd"]     = "you would",
    ["we'd"]      = "we would",
    ["they'd"]    = "they would",
    ["he'd"]      = "he would",
    ["she'd"]     = "she would",
    ["ain't"]     = "is not",
}

local function normalise(text)
    text = text:lower()
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Expand contractions BEFORE terminator strip so "i'm tired." -> "i am tired."
    -- (then terminator drop gives "i am tired"). Both contracted and expanded
    -- forms collapse to the same key, freeing entries to use either form.
    for contracted, expanded in pairs(CONTRACTIONS) do
        text = text:gsub(contracted, expanded)
    end
    -- 9.0+ Mosaic: chat-style 'in' for 'ing' canonicalization. Patterns
    -- like "kiddin'", "goin'", "doin'", "huntin'" — the trailing
    -- apostrophe stands in for the dropped 'g'. Re-add the 'g' before
    -- terminator strip so phrasebook entries written with full "-ing"
    -- (e.g. "no kidding") match chat-input.
    text = text:gsub("(%a)in'", "%1ing")
    -- 9.0+ Mosaic: also strip a trailing standalone apostrophe (chat
    -- decoration like "yeah'" or "right'") which would otherwise prevent
    -- canonical lookup.
    if text:sub(-1) == "'" then
        text = text:sub(1, -2)
    end
    -- Strip trailing . ? ! (and any apostrophe before/after that snuck in)
    local last = text:sub(-1)
    if last == "." or last == "?" or last == "!" then
        text = text:sub(1, -2)
    end
    if text:sub(-1) == "'" then
        text = text:sub(1, -2)
    end
    -- Collapse internal whitespace
    text = text:gsub("%s+", " ")
    return text
end

M.normalise = normalise

local index = {}
local reverseIndex = {}
for _, entry in ipairs(M.entries) do
    -- Respect the direction field: "both" (default) indexes in both
    -- directions; "forward" only en->tr; "reverse" only tr->en. This
    -- lets us add forward-only entries (e.g. contractions like "i'm
    -- tired" or short forms like "morning") without shadowing existing
    -- reverse routes ("Yorgunum." -> "I am tired." stays clean from
    -- productive, "Günaydın." reverses to the canonical "Good morning.").
    local dir = entry.direction or "both"
    if dir == "both" or dir == "forward" then
        index[normalise(entry.en)] = entry
    end
    if dir == "both" or dir == "reverse" then
        reverseIndex[normalise(entry.tr)] = entry
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.lookup(text)
    if type(text) ~= "string" then return nil end
    return index[normalise(text)]
end

-- 8.9.20+: Prefix matching. Returns the entry whose en matches as a
-- whole-word PREFIX of text (after normalization), preferring the longest
-- such match when multiple candidates exist. Also returns the length of
-- the matched prefix (in normalized form) so the caller can split the
-- input into "matched + remainder".
--
-- This lets the engine translate inputs like "turn off the lamp": the
-- phrasebook entry "turn off" matches as a prefix, the productive engine
-- handles "the lamp", and the two get composed into "Lambayı kapat" (with
-- the phrasebook output's leading capital + trailing terminator stripped
-- for mid-sentence inlining).
--
-- Returns: { entry, matchLen, matchStr } | nil
--   entry    = the matched phrasebook entry
--   matchLen = length of the normalised input prefix that was consumed
--   matchStr = the normalised matched string (for debugging / trace)
function M.lookupPrefix(text)
    if type(text) ~= "string" then return nil end
    local norm = normalise(text)
    -- Try progressively shorter prefixes, longest first.
    -- We split on word boundaries: find each space position, and try the
    -- prefix up to (but not including) that space.
    --
    -- Single-word matches are excluded here: the whole-input lookup
    -- already covers those cleanly, and a single-word prefix would
    -- otherwise fire on any input starting with "hello" / "hi" / "ok"
    -- and overwhelm the productive path.
    local positions = {}
    local pos = 1
    while true do
        local s = norm:find(" ", pos, true)
        if not s then break end
        table.insert(positions, s - 1)  -- end of word just before space
        pos = s + 1
    end
    -- Also try the full string as a final candidate (matches a multi-word
    -- entry where the entire input IS the phrasebook entry; same as full
    -- lookup, but included here for completeness when called standalone).
    table.insert(positions, #norm)
    -- Iterate longest-first.
    for i = #positions, 1, -1 do
        local endIdx = positions[i]
        local prefix = norm:sub(1, endIdx)
        local entry = index[prefix]
        if entry then
            -- Skip entries tagged "modal": these are PRON+MODAL stop-gaps
            -- (e.g. "we should" -> "Yapmalıyız.") from before modal
            -- morphology shipped. They still serve as whole-input matches
            -- (handled by M.lookup), but as prefix matches they shadow
            -- the productive modal pipeline. After this gate, "we should
            -- leave" correctly routes to MODAL morphology -> Ayrılmalıyız.
            --
            -- Also skip "response" tagged entries: those are short
            -- conversational replies ("I see", "OK", "really") meant
            -- as complete utterances. As prefix matches they hijack
            -- literal uses ("I see it" should NOT become "Anlıyorum"
            -- + "Onu" = "Onu anlıyorum"; the productive path handles
            -- "I see it" -> "Onu görüyorum" correctly).
            local skip = false
            if entry.tags then
                for _, tag in ipairs(entry.tags) do
                    if tag == "modal" or tag == "response" then
                        skip = true; break
                    end
                end
            end
            if not skip then
                return { entry = entry, matchLen = endIdx, matchStr = prefix }
            end
        end
    end
    return nil
end

function M.lookupReverse(text)
    if type(text) ~= "string" then return nil end
    return reverseIndex[normalise(text)]
end

function M.count()
    return #M.entries
end

return M
