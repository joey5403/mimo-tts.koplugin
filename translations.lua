--[[--
Plugin translations.

KOReader's gettext keeps one global translation table, filled from
``l10n/<lang>/koreader.mo`` when the UI language is set. This module merges
the plugin's own catalogs (``l10n/<lang>/mimo_tts.mo``) into it, so plugin
strings follow the very same language setting.

Notes:
- English (``en_US`` / ``C``) disables localization in KOReader and simply
  shows the source strings -- which is why source strings are English.
- Translations already provided by KOReader itself always win: shared words
  (e.g. "Cancel") keep the core's wording everywhere in the UI.
- Language changes require a KOReader restart, so loading once at plugin
  load time is enough.
]]

local GetText = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local translations = {}

-- directory of this module == plugin root
local plugin_root = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

--- Merge one .mo catalog, keeping any pre-existing (core) translations.
local function loadCatalog(path)
    local before = {}
    for k, v in pairs(GetText.translation) do
        before[k] = v
    end
    if not GetText.loadMO(path) then
        return false
    end
    for k, v in pairs(before) do
        GetText.translation[k] = v -- core wins on shared msgids
    end
    return true
end

--- Load the plugin translations for the current UI language.
-- Falls back from e.g. ``zh_CN`` to ``zh`` when only the base language exists.
-- @treturn string the catalog actually loaded ("" when none)
function translations.load()
    local lang = GetText.current_lang
    if not lang or lang == "C" then
        -- English, or a language KOReader itself has no catalog for (in which
        -- case changeLang() leaves current_lang at "C"): ask the setting.
        lang = (G_reader_settings and G_reader_settings:readSetting("language")) or ""
    end
    if lang == "" or lang == "C" or lang:match("^en_US") then
        return "" -- English: source strings
    end
    for _, code in ipairs({ lang, lang:match("^(%a+)") }) do
        if code then
            local path = plugin_root .. "/l10n/" .. code .. "/mimo_tts.mo"
            if lfs.attributes(path, "mode") == "file" and loadCatalog(path) then
                return code
            end
        end
    end
    return ""
end

--- Where the catalogs live (for tooling / tests).
function translations.getDir()
    return plugin_root .. "/l10n"
end

return translations
