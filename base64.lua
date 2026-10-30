--[[--
Minimal pure-Lua Base64 decoder.

Used to decode the audio payloads returned by the MiMo TTS API
(``choices[1].message.audio.data`` is base64 encoded).
]]

local Base64 = {}

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}
for i = 1, #ALPHA do
    LOOKUP[ALPHA:byte(i)] = i - 1
end
-- Also accept URL-safe variants
LOOKUP[string.byte("-")] = 62
LOOKUP[string.byte("_")] = 63

--- Decode a base64 string into raw bytes.
-- Whitespace and any invalid characters are skipped; ``=`` padding stops decoding.
-- @string data base64 encoded payload
-- @treturn string raw bytes
function Base64.decode(data)
    local out, buf, bits = {}, 0, 0
    for i = 1, #data do
        local b = data:byte(i)
        if b == 61 then -- "=" padding
            break
        end
        local v = LOOKUP[b]
        if v then
            buf = buf * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(math.floor(buf / 2 ^ bits) % 256)
                buf = buf % 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

--- Encode raw bytes into a base64 string.
-- @string data raw bytes
-- @treturn string base64 encoded payload (with `=` padding)
function Base64.encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        b2 = b2 or 0
        b3 = b3 or 0
        local n = b1 * 65536 + b2 * 256 + b3
        out[#out + 1] = ALPHA:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = ALPHA:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (i + 1 <= #data) and ALPHA:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
        out[#out + 1] = (i + 2 <= #data) and ALPHA:sub(n % 64 + 1, n % 64 + 1) or "="
    end
    return table.concat(out)
end

return Base64
