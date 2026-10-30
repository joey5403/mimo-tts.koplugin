--[[--
Text chunking for TTS synthesis.

Splits extracted book text into sentence-aware chunks that stay under a
maximum character count, so each synthesis request stays small and playback
can start/advance quickly.

Chunks keep their byte range in the source text (``range = {s, e}``) and the
raw source substring (``orig``), so the UI can underline the text that is
currently being played. ``text`` is the normalized version actually sent to
the TTS engine.
]]

local Chunker = {}

-- One UTF-8 character (lead byte + continuation bytes)
local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

local SENTENCE_END = {
    ["。"] = true, ["！"] = true, ["？"] = true, ["…"] = true, ["；"] = true,
    ["."] = true, ["!"] = true, ["?"] = true, [";"] = true, ["\n"] = true,
}

-- Characters that may follow a sentence end and belong to the same sentence
local TRAILING = {
    ["”"] = true, ["’"] = true, ["』"] = true, ["」"] = true, ["）"] = true,
    [")"] = true, ["]"] = true, ['"'] = true, ["'"] = true,
    ["。"] = true, ["！"] = true, ["？"] = true, ["…"] = true,
    [" "] = true, ["\t"] = true,
}

local CJK_CHAR = "[\228-\233][\128-\191][\128-\191]"

local function utf8len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Normalize extracted text before sending it to the TTS engine.
function Chunker.normalize(text)
    if not text then
        return ""
    end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[\t\v\f ]+", " ")
    text = text:gsub(" *\n *", "\n")
    text = text:gsub("\n\n+", "\n")
    -- Remove artificial spaces between CJK characters (word boxes are
    -- often joined with spaces in PDF/DjVu text extraction)
    for _ = 1, 5 do
        local new = text:gsub("(" .. CJK_CHAR .. ") +(" .. CJK_CHAR .. ")", "%1%2")
        if new == text then
            break
        end
        text = new
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

--- Split text into sentences with byte ranges in the source text.
-- @treturn table array of `{ text, s, e }` (byte offsets, inclusive)
function Chunker.splitSentences(text)
    local chars, positions = {}, {}
    for pos, ch in text:gmatch("()(" .. UTF8_CHAR .. ")") do
        chars[#chars + 1] = ch
        positions[#positions + 1] = pos
    end
    local n = #chars
    local sentences = {}
    local i, start_idx = 1, 1
    while i <= n do
        if SENTENCE_END[chars[i]] then
            -- swallow trailing quotes/brackets/punctuation of the same sentence
            while i < n and TRAILING[chars[i + 1]] do
                i = i + 1
            end
            local s = positions[start_idx]
            local e = positions[i] + #chars[i] - 1
            sentences[#sentences + 1] = { text = text:sub(s, e), s = s, e = e }
            i = i + 1
            start_idx = i
        else
            i = i + 1
        end
    end
    if start_idx <= n then
        local s = positions[start_idx]
        local e = positions[n] + #chars[n] - 1
        sentences[#sentences + 1] = { text = text:sub(s, e), s = s, e = e }
    end
    return sentences
end

--- Split text into chunks, one sentence per chunk.
-- Each chunk is exactly what is being spoken at a given time, so the UI can
-- underline only the current sentence and drop the previous one's underline
-- as soon as it has been read. Sentences longer than `max_chars` are cut.
-- @string text source text (as extracted from the document)
-- @int max_chars maximum chunk size in characters (defaults to 300)
-- @treturn table array of `{ text, orig, range = {s, e} }`
function Chunker.split(text, max_chars)
    max_chars = tonumber(max_chars) or 300
    if max_chars < 20 then
        max_chars = 20
    end
    if not text or text == "" then
        return {}
    end
    local chunks = {}

    local function addChunk(s, e)
        local orig = text:sub(s, e)
        local normalized = Chunker.normalize(orig)
        if normalized:find("%S") then
            chunks[#chunks + 1] = {
                text = normalized,
                orig = orig,
                range = { s = s, e = e },
            }
        end
    end

    for _, sentence in ipairs(Chunker.splitSentences(text)) do
        local slen = utf8len(sentence.text)
        if slen > max_chars then
            -- hard cut overlong sentences, keeping byte ranges
            local piece_start, piece_len = sentence.s, 0
            local pos = sentence.s
            for ch in sentence.text:gmatch(UTF8_CHAR) do
                piece_len = piece_len + 1
                local next_pos = pos + #ch
                if piece_len >= max_chars then
                    addChunk(piece_start, next_pos - 1)
                    piece_start = next_pos
                    piece_len = 0
                end
                pos = next_pos
            end
            if piece_len > 0 then
                addChunk(piece_start, sentence.e)
            end
        else
            addChunk(sentence.s, sentence.e)
        end
    end
    return chunks
end

return Chunker
