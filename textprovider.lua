--[[--
Text extraction and text location for the currently opened document.

Works for reflowable documents (CreDocument: EPUB/FB2/TXT/HTML...) as well as
paged documents (PDF/DjVu via MuPDF/Kopt).

NOTE: crengine keeps a rendered-page buffer, and any of `findText`,
`getTextFromXPointers`, `getTextFromPositions`, `getWordFromPosition`,
`clearSelection` and `highlightXPointer` invalidates it (c.f. the call cache
wrapper in credocument.lua): using them forces a full page re-render, which
freezes the UI for seconds on complex EPUBs. All the hot paths below therefore
only use rendering-safe calls (`getTextFromXPointer`, `getNextVisibleWordEnd`,
`compareXPointers`, `getPageXPointer`, `getScreenBoxesFromPositions`...).
]]

local Device = require("device")
local logger = require("logger")

local TextProvider = {}

local function utf8len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- Byte offset right after `n_chars` UTF-8 characters of `s`.
local function utf8_offset_after(s, n_chars)
    local count, pos = 0, 1
    for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        if count >= n_chars then
            return pos
        end
        count = count + 1
        pos = pos + #ch
    end
    return pos
end

-- Keep the characters of `text` in [from_char, to_char) (0-based, exclusive).
local function slice_chars(text, from_char, to_char)
    local s = utf8_offset_after(text, from_char or 0)
    local e = to_char and (utf8_offset_after(text, to_char) - 1) or #text
    if e < s then
        return ""
    end
    return text:sub(s, e)
end

-- Page maps (byte-offset -> xpointer) built from safe calls, keyed by the
-- page's start xpointer (which changes when the document is re-laid out).
local page_maps = {}

--- Extract the text of one page of a reflowable document, with node offsets.
-- Walks the page's text nodes via `getNextVisibleWordEnd` (rendering-safe).
-- Nodes are sliced to the page's actual range (a page often starts/ends in
-- the middle of a text node).
-- @treturn table|nil `{ text, nodes = { {prefix, text, skip, s, e}, ... } }`
local function buildPageMap(doc, page)
    local ok_xp, start_xp = pcall(doc.getPageXPointer, doc, page)
    if not ok_xp or type(start_xp) ~= "string" or start_xp == "" then
        return nil
    end
    local key = page .. "|" .. start_xp
    local cached = page_maps[key]
    if cached ~= nil then
        return cached
    end
    -- drop stale entries (keep the cache tiny)
    for k in pairs(page_maps) do
        page_maps[k] = nil
    end

    local okn, end_xp = pcall(doc.getPageXPointer, doc, page + 1)
    end_xp = (okn and type(end_xp) == "string") and end_xp or ""
    -- a page regularly starts/ends in the middle of a text node: the chars
    -- outside [start_char, end_char) of those nodes belong to other pages
    local start_prefix = start_xp:match("^(.*)%.%d+$") or start_xp
    local start_char = tonumber(start_xp:match("%.([%d]+)$")) or 0
    local end_prefix = end_xp ~= "" and (end_xp:match("^(.*)%.%d+$") or end_xp) or nil
    local end_char = tonumber(end_xp:match("%.([%d]+)$")) or 0

    local nodes, parts = {}, {}
    local offset = 1
    local xp = start_xp
    local last_prefix
    for _ = 1, 100000 do
        if type(xp) ~= "string" or xp == "" then
            break
        end
        -- stop at the beginning of the next page (or at EOF)
        if end_xp ~= "" then
            local okc, cmp = pcall(doc.compareXPointers, doc, xp, end_xp)
            if okc and type(cmp) == "number" and cmp ~= 1 then
                break
            end
        end
        local prefix = xp:match("^(.*)%.%d+$") or xp
        if prefix ~= last_prefix then
            local okt, full = pcall(doc.getTextFromXPointer, doc, prefix)
            full = (okt and type(full) == "string") and full or ""
            local skip = (prefix == start_prefix) and start_char or 0
            local to_char = (prefix == end_prefix) and end_char or nil
            local text = slice_chars(full, skip, to_char)
            nodes[#nodes + 1] = { prefix = prefix, text = text, skip = skip, s = offset, e = offset + #text - 1 }
            parts[#parts + 1] = text
            offset = offset + #text
            last_prefix = prefix
        end
        local okw, next_wp = pcall(doc.getNextVisibleWordEnd, doc, xp)
        if not okw or type(next_wp) ~= "string" or next_wp == "" or next_wp == xp then
            break
        end
        xp = next_wp
    end
    if #nodes == 0 then
        page_maps[key] = false
        return nil
    end
    local map = { text = table.concat(parts), nodes = nodes }
    page_maps[key] = map
    return map
end

--- XPointer for a byte offset inside the page map text.
local function xpointerForOffset(map, byte_off)
    for _, n in ipairs(map.nodes) do
        if byte_off <= n.e + 1 then
            local rel = byte_off - n.s -- bytes of node text before this offset
            if rel <= 0 then
                return n.prefix .. "." .. n.skip
            end
            return n.prefix .. "." .. (n.skip + utf8len(n.text:sub(1, rel)))
        end
    end
    local last = map.nodes[#map.nodes]
    return last and (last.prefix .. "." .. (last.skip + utf8len(last.text))) or nil
end

-- Paged (MuPDF/DjVu) word boxes -------------------------------------------

--- Flatten MuPDF/DjVu word boxes (`lines of { {word=...}, ... }`) into text,
-- also returning each word box's byte range in the flattened text.
local function flattenTextBoxesWithOffsets(boxes)
    if type(boxes) ~= "table" then
        return "", {}
    end
    local lines = {}
    for _, line in ipairs(boxes) do
        if type(line) == "table" then
            local pieces, rel = {}, {}
            local rel_offset = 1
            for _, box in ipairs(line) do
                if type(box) == "table" and box.word then
                    if #pieces > 0 then
                        pieces[#pieces + 1] = " "
                        rel_offset = rel_offset + 1
                    end
                    rel[#rel + 1] = { s = rel_offset, e = rel_offset + #box.word - 1, box = box }
                    pieces[#pieces + 1] = box.word
                    rel_offset = rel_offset + #box.word
                end
            end
            if #pieces > 0 then
                lines[#lines + 1] = { text = table.concat(pieces), words = rel }
            end
        end
    end
    local out, words = {}, {}
    local offset = 1
    for i, ln in ipairs(lines) do
        if i > 1 then
            out[#out + 1] = "\n"
            offset = offset + 1
        end
        for _, w in ipairs(ln.words) do
            words[#words + 1] = { s = w.s + offset - 1, e = w.e + offset - 1, box = w.box }
        end
        out[#out + 1] = ln.text
        offset = offset + #ln.text
    end
    return table.concat(out), words
end

local function flattenTextBoxes(boxes)
    local text = flattenTextBoxesWithOffsets(boxes)
    return text
end

--- Text of a page in a paged (PDF/DjVu) document.
local function pagingPageText(doc, page)
    if doc.getTextBoxes then
        local ok, boxes = pcall(doc.getTextBoxes, doc, page)
        if ok then
            local text = flattenTextBoxes(boxes)
            if text:find("%S") then
                return text
            end
        end
    end
    if doc.getPageText then
        local ok, boxes = pcall(doc.getPageText, doc, page)
        if ok then
            local text = flattenTextBoxes(boxes)
            if text:find("%S") then
                return text
            end
        end
    end
    return ""
end

--- Current page number (1-based), as KOReader sees it.
function TextProvider.getCurrentPage(ui)
    if ui.getCurrentPage then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok and type(page) == "number" then
            return page
        end
    end
    return 1
end

--- Total number of pages of the opened document.
function TextProvider.getPageCount(ui)
    local doc = ui.document
    if doc and doc.getPageCount then
        local ok, count = pcall(doc.getPageCount, doc)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 0
end

--- Extract the text of `page` (defaults to the current page).
-- @treturn string extracted text (may be empty)
function TextProvider.getPageText(ui, page)
    local doc = ui.document
    if not doc then
        return ""
    end
    page = page or TextProvider.getCurrentPage(ui)
    if ui.rolling then
        local map = buildPageMap(doc, page)
        if map and map.text:find("%S") then
            return map.text
        end
        return ""
    end
    local ok, text = pcall(pagingPageText, doc, page)
    if not ok then
        logger.warn("MiMoTTS: page text extraction failed:", text)
        return ""
    end
    return text or ""
end

--- Text of the current selection, if any.
function TextProvider.getSelectionText(ui)
    local highlight = ui.highlight
    if highlight and type(highlight.selected_text) == "table"
        and type(highlight.selected_text.text) == "string" then
        local text = highlight.selected_text.text
        if text:find("%S") then
            return text
        end
    end
    return ""
end

--- Get the boxes covering a chunk of text, for underlining what is being read.
-- @table chunk chunk object from `Chunker.split` (`text`, `orig`, `range`)
-- @int page page the chunk was extracted from
-- @string mode "selection" when the chunk comes from a text selection
-- @treturn table|nil boxes suitable for `view.highlight.temp[page]`
--   (`{x, y, w, h}`; screen coordinates for reflowable documents,
--   page coordinates for paged documents -- `drawTempHighlight` transforms them)
function TextProvider.getChunkBoxes(ui, chunk, page, mode)
    local doc = ui.document
    if not doc or not chunk then
        return nil
    end
    page = page or TextProvider.getCurrentPage(ui)

    if ui.rolling then
        -- Locate the chunk inside the page map and convert its byte range to
        -- an xpointer range (all rendering-safe calls).
        local map = buildPageMap(doc, page)
        if not map then
            return nil
        end
        local s, e
        if mode ~= "selection" and chunk.range then
            s, e = chunk.range.s, chunk.range.e
        else
            -- selection chunks: find the raw chunk text inside the page map
            local pattern = chunk.orig or chunk.text
            local ps, pe = map.text:find(pattern, 1, true)
            if not ps then
                -- last resort: try a short prefix of the raw text
                ps = map.text:find((pattern or ""):sub(1, 24), 1, true)
                if ps then
                    pe = ps + #pattern - 1
                end
            end
            if not ps then
                return nil
            end
            s, e = ps, pe
        end
        local start_xp = xpointerForOffset(map, s)
        local end_xp = xpointerForOffset(map, e + 1)
        if not (start_xp and end_xp) then
            return nil
        end
        local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, start_xp, end_xp, true)
        if ok and type(boxes) == "table" and #boxes > 0 then
            return boxes
        end
        return nil
    end

    -- Paged documents: the chunk's byte range maps directly to word boxes
    if mode == "selection" then
        -- selection text does not use page offsets: use the document search
        -- (Kopt's findText -- paged documents have no crengine render buffer)
        local pattern = chunk.orig or chunk.text
        local ok, res = pcall(doc.findText, doc, pattern, 0, 1, true, page, false, 8, 0)
        if ok and type(res) == "table" and #res > 0 then
            return res
        end
        return nil
    end
    local ok, boxes = pcall(doc.getTextBoxes, doc, page)
    if not ok or type(boxes) ~= "table" then
        return nil
    end
    local _, words = flattenTextBoxesWithOffsets(boxes)
    local range = chunk.range
    if not range then
        return nil
    end
    local out = {}
    for _, w in ipairs(words) do
        if w.e >= range.s and w.s <= range.e then
            local native_box = {
                x = w.box.x0, y = w.box.y0,
                w = w.box.x1 - w.box.x0, h = w.box.y1 - w.box.y0,
            }
            local ok2, rect = pcall(doc.nativeToPageRectTransform, doc, page, native_box)
            if ok2 and rect then
                out[#out + 1] = rect
            end
        end
    end
    return #out > 0 and out or nil
end

return TextProvider
