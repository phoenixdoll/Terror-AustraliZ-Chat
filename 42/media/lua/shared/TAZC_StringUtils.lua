-- ============================================================================
-- TAZC_StringUtils -- VM-portable UTF-8 character iteration.
--
-- Two runtimes, two string storage models. Lua 5.4 (offline tests): strings
-- are byte arrays -- "ç" is the 2-byte UTF-8 sequence 0xC3 0xA7, #s = 2.
-- Kahlua (PZ Build 42 at runtime): strings are Java-backed codepoint arrays --
-- the lexer composes adjacent \ddd escapes forming valid UTF-8 into one Java
-- char, so "ç" becomes a 1-character string at codepoint U+00E7, #s = 1.
--
-- Three modules (TAZC_Translate, TAZC_TranslateMorphology, TAZC_TranslateReverseParser)
-- used to each keep a private byte-walking utf8chars() -- correct on Lua 5.4,
-- wrong on Kahlua (a composed codepoint like U+00E7/231 misread as a UTF-8
-- lead byte, over-slicing and dropping characters); tests passed on 5.4 while
-- the v3 translator silently mis-produced morphology on Kahlua. This module
-- detects the active storage model at load and dispatches the iterator
-- accordingly, so both VMs yield the same one-character-substring sequence.
--
-- Detection: "\195\167" (U+00E7) is 2 bytes under byte storage, 1 under
-- Kahlua's codepoint composition -- a clean discriminator.
-- ============================================================================

-- Default: the runtime probe below. test_string_utils.py forces the codepoint
-- branch via _G.TAZC_FORCE_KAHLUA_CODEPOINTS = true (set before require), then
-- drives synthetic string.char() bytes through it -- forcing the branch changes
-- which ALGORITHM runs, not how the offline host VM stores strings, but that's
-- enough to pin the historical lead-byte-misread bug entirely offline.
local _utf8probe = "\195\167"
local KAHLUA_CODEPOINTS
if _G.TAZC_FORCE_KAHLUA_CODEPOINTS == true then
    KAHLUA_CODEPOINTS = true
else
    KAHLUA_CODEPOINTS = (#_utf8probe == 1)
end

local M = {}
-- Internal contract: test_string_utils.py reads this to confirm the forced
-- global actually engaged the codepoint branch.
M.KAHLUA_CODEPOINTS = KAHLUA_CODEPOINTS

-- ----------------------------------------------------------------------------
-- utf8chars(s) -- character iterator; dispatches per the storage model above.
-- ----------------------------------------------------------------------------
function M.utf8chars(s)
    local i = 1
    local len = #s
    if KAHLUA_CODEPOINTS then
        return function()
            if i > len then return nil end
            local ch = s:sub(i, i)
            i = i + 1
            return ch
        end
    else
        return function()
            if i > len then return nil end
            local b1 = s:byte(i)
            local sz
            if     b1 < 0x80 then sz = 1
            elseif b1 < 0xC0 then sz = 1  -- malformed continuation; consume 1
            elseif b1 < 0xE0 then sz = 2
            elseif b1 < 0xF0 then sz = 3
            else                  sz = 4
            end
            local ch = s:sub(i, i + sz - 1)
            i = i + sz
            return ch
        end
    end
end

-- ----------------------------------------------------------------------------
-- utf8len(s) -- character count, not byte count.
-- ----------------------------------------------------------------------------
function M.utf8len(s)
    local n = 0
    for _ in M.utf8chars(s) do n = n + 1 end
    return n
end

-- ----------------------------------------------------------------------------
-- utf8charLen(s) -- byte/codepoint span of the FIRST char, mirroring the
-- per-VM iterator step. Used by TAZC_Translate's diacritic-stripping to know
-- how much of the leading char to slice.
-- ----------------------------------------------------------------------------
function M.utf8charLen(s)
    if #s == 0 then return 0 end
    if KAHLUA_CODEPOINTS then return 1 end
    local b1 = s:byte(1)
    if     b1 < 0x80 then return 1
    elseif b1 < 0xC0 then return 1
    elseif b1 < 0xE0 then return 2
    elseif b1 < 0xF0 then return 3
    else                  return 4
    end
end

-- ----------------------------------------------------------------------------
-- lastChar(s) -- final UTF-8 character; nil for empty strings.
-- ----------------------------------------------------------------------------
function M.lastChar(s)
    local last
    for ch in M.utf8chars(s) do last = ch end
    return last
end

-- ----------------------------------------------------------------------------
-- dropLast(s, n) -- s minus its last n UTF-8 chars (n defaults 1); empty
-- string if n >= the character count of s.
-- ----------------------------------------------------------------------------
function M.dropLast(s, n)
    n = n or 1
    local total = M.utf8len(s)
    if n >= total then return "" end
    local out = {}
    local i = 0
    for ch in M.utf8chars(s) do
        i = i + 1
        if i <= total - n then table.insert(out, ch) end
    end
    return table.concat(out)
end

return M
