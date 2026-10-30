# Changelog

All notable changes to this project are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
Versioning: [Semantic Versioning](https://semver.org/)

## [1.0.2] - 2026-10-30

### Added
- release GitHub Action: pushing a `v*` tag builds and publishes the GitHub
  release automatically (changelog section as notes, plugin zip attached)
- local-only CI gate: `make ci` (syntax + catalogs + test battery) installed as
  a git pre-commit hook via `make install-hooks`
- the full test battery now lives in `tests/` (unit/integration suites, E2E
  runner and driver, mock MiMo API, mock `libOpenSLES.so`) with
  `make test` / `make e2e`

### Fixed
- release notes extraction is self-contained so tags that predate
  `tools/release-notes.py` build correctly

## [1.0.0] - 2026-10-30

Initial release.

### Added

- **Listening**: continuous listening from the current page to the end of the
  book (automatic page turns), current page only, or the text selection;
  next/previous segment navigation; dispatcher actions for gestures and keys
- **Read-aloud underline**: the sentence currently being spoken is underlined;
  the underline is removed as soon as it has been read and moves to the next
  sentence (EPUB/TXT/PDF/DjVu)
- **MiMo TTS models**: `mimo-v2.5-tts` (9 preset voices), `mimo-v2.5-tts-voicedesign`
  (voice from a text description), `mimo-v2.5-tts-voiceclone` (voice from an
  mp3/wav sample) — with style tags, natural-language style prompts and speed
  control, optional streaming synthesis (`pcm16`)
- **Gapless playback**: sentence-level segments with 3-sentence look-ahead
  synthesis and cross-page prefetching; content-hashed audio cache
- **Playback on every device**: Android native OpenSL ES backend (LuaJIT FFI
  over `libOpenSLES.so`, no external binaries), command line player
  auto-detection (mpv / ffplay / mpg123 / madplay / ogg123 / sox / aplay /
  paplay / afplay), custom command override, automatic mp3/wav format
  negotiation, playback diagnostics
- **Top menu icon**: 🔊 icon in the reader's top menu opening the plugin menu
  (registered via KOReader's `reader_menu_order.lua`, non-destructive)
- **i18n**: menus and settings follow KOReader's language; English source
  strings with a shipped `zh_CN` catalog and a gettext workflow
  (`make pot` / `make po-update` / `make mo`)
- **Docs**: README.md (English) and README.zh-CN.md (简体中文)
- **Quality gates**: unit/integration suites (chunking, API payloads, playback
  backends, text location, i18n, menu wiring) and E2E runs against a real
  KOReader process with a contract-validating mock MiMo API (command and
  opensles scenarios)
