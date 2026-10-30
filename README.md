# MiMo TTS Read-aloud — a KOReader plugin

**English** | [简体中文](README.zh-CN.md)

Turn KOReader into an audiobook player with **Xiaomi MiMo TTS (MiMo-V2.5-TTS
series)**: the plugin extracts text from the current page, the text selection
or the whole book, synthesizes speech with the MiMo TTS API, and plays it back
with the best audio backend available on your device.

Supports continuous listening with automatic page turns, preset voices, style
tags / natural-language style control, voice design and voice cloning,
streaming synthesis, sentence-level caching, and next/previous navigation.

Implementation follows the official documentation
(in Chinese): <https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/speech-synthesis-v2.5>

## Features

- **Continuous listening**: from the current page to the end of the book,
  with automatic page turns
- **Read current page / selected text**: read one page, or long-press to select
  text and read just the selection
- **Preset voices**: Bingtang / Jasmine / Soda / Birch / Mia / Chloe / Milo /
  Dean / mimo_default
- **All three models**:
  - `mimo-v2.5-tts`: preset voices (default)
  - `mimo-v2.5-tts-voicedesign`: design a voice from a text description
  - `mimo-v2.5-tts-voiceclone`: clone a voice from an mp3/wav sample (≤10MB)
- **Style control** (both documented mechanisms):
  - natural language: a *style prompt* goes into the user message
    (e.g. "a warm audiobook narrator"); playback speed is controlled there too
  - audio tags: an optional *style tag* is prepended to the text, e.g.
    `(gentle)`, `(magnetic)`, `(singing)`
- **Sentence-level reading with precise underline**: one sentence per segment;
  the sentence being spoken gets an underline, which is removed as soon as it
  has been read and moves to the next one
- **Streaming synthesis**: optional `stream=true` + `pcm16` (24kHz mono), more
  robust for long texts
- **Gapless playback**: the next sentences are synthesized while the current
  one plays (with look-ahead and cross-page prefetching)
- **Audio caching**: segments are cached by content hash under
  `koreader data dir/cache/mimo_tts/` — re-listening costs no extra requests
- **Playback on every device**: Android's native OpenSL ES backend plus
  auto-detected command line players (mpv / ffplay / mpg123 / madplay /
  sox `play` / aplay / paplay / afplay), fully customizable
- **Top menu icon**: a 🔊 icon in the reader's top menu opens the plugin menu
  (toggleable from the menu)
- **Gestures / keys / dispatcher**: every action is registered with the
  dispatcher and can be bound to gestures or keyboard shortcuts

## Installation

Copy the whole `mimo-tts.koplugin` directory into KOReader's plugin directory:

- generic: `<koreader data dir>/plugins/` (desktop/multi-user builds use
  `~/.config/koreader/plugins/`)
- or `<koreader install dir>/plugins/` (next to the bundled plugins)
- or anywhere, adding that location to `extra_plugin_paths` in
  `settings.reader.lua`
- Android: `/sdcard/koreader/plugins/`

Then restart KOReader: menu → More tools → **MiMo TTS Read-aloud**.

## Settings

### API & model settings

| Setting | Default | Notes |
| --- | --- | --- |
| API base URL | `https://token-plan-cn.xiaomimimo.com/v1` | Requests go to `{API base URL}/chat/completions` (Token Plan CN endpoint; `https://api.xiaomimimo.com/v1` also works) |
| API key | (empty) | Required; sent in the `api-key` request header |
| TTS model | `mimo-v2.5-tts` | or `mimo-v2.5-tts-voicedesign` / `mimo-v2.5-tts-voiceclone` |
| Audio format (mp3 / wav) | `mp3` | streaming mode always uses `pcm16` |

### Voice & style settings

| Setting | Default | Notes |
| --- | --- | --- |
| Style tag (e.g. gentle; optional) | (empty) | Prepended to each segment: `gentle` → `(gentle)text…`; never duplicated when the text already carries a tag |
| Style prompt (natural-language instruction; optional) | (empty) | Style instruction sent as the user message, e.g. "a deep late-night radio voice" |
| Voice description (required for voice design) | (empty) | e.g. "a mellow, deep middle-aged male voice speaking slowly" |
| Voice sample file (voice clone mode, mp3/wav) | (empty) | Local mp3/wav file, ≤10MB |

The *Choose preset voice* submenu switches between the official voices
(only with `mimo-v2.5-tts`). The *Streaming synthesis* menu toggle controls the
`stream=true` / `pcm16` requests.

### Playback & segmentation settings

| Setting | Default | Notes |
| --- | --- | --- |
| Speed (1.0 = normal) | `1.0` | Natural-language speed control via the user message (1.25 → "Speak at approximately 1.25x speed.") |
| Max segment length (longer ones are split) | `300` | Upper bound for overlong sentences |
| Player command (empty = auto-detect) | (empty) | e.g. `mpv --no-video`; the file name is appended to the command |
| Playback backend (auto/command/opensles) | `auto` | Force a specific backend if needed |

### Request example (matches the official docs)

```http
POST https://token-plan-cn.xiaomimimo.com/v1/chat/completions
api-key: <API key>
Content-Type: application/json

{
  "model": "mimo-v2.5-tts",
  "messages": [
    {"role": "user", "content": "a warm audiobook narrator Speak at approximately 1.25x speed."},
    {"role": "assistant", "content": "(gentle)the text to be spoken"}
  ],
  "audio": {"format": "mp3", "voice": "mimo_default"}
}
```

- voice clone: `audio.voice` carries the sample as
  `data:audio/mpeg;base64,...`
- voice design: the user message is the voice description and `audio` has no
  `voice` field
- streaming: `"audio": {"format": "pcm16", ...}, "stream": true`; audio arrives
  base64-encoded in `choices[1].delta.audio.data` (24kHz mono PCM16LE)
- non-streaming responses carry audio in `choices[1].message.audio.data`
  (base64)

## Usage

Open a book, then menu → **MiMo TTS Read-aloud**:

- **Listen to the whole book (auto page turn)**: read from the current page to
  the end of the book
- **Read current page**: read only the visible page
- **Read selected text**: long-press to select text first
- **Next segment / Previous segment**: jump between sentences (across pages)
- **Stop reading**: stop playback and end the session
- **Test reading**: synthesize and play one test sentence
- **Playback diagnostics…**: show the active backend, supported formats and
  available players
- **Clear audio cache**: delete the cached audio files

All actions are registered with the **dispatcher**, so they can be bound to
gestures or shortcuts:

- `MiMo TTS: start/stop reading`
- `MiMo TTS: read current page`
- `MiMo TTS: read the whole book`
- `MiMo TTS: stop reading`
- `MiMo TTS: next segment` / `MiMo TTS: previous segment`

You can turn pages and open menus while listening; after a manual page turn,
continuous listening resumes from the new position.

### Read-aloud underline

While listening, the **sentence currently being spoken** is underlined on the
page (via KOReader's temporary-highlight pipeline, `underscore` style). The
underline is removed as soon as the sentence has been read and moves to the
next one. Implementation notes:

- reading is segmented **per sentence**, so the spoken sentence *is* the
  underline range; look-ahead synthesis (3 sentences ahead, cross-page
  prefetching) keeps playback gapless
- segments keep their **byte range** in the source text, used to locate them
- reflowable documents (EPUB/TXT…): the page's text nodes (including those
  inside inline tags) are walked at startup with `getNextVisibleWordEnd` to
  build a byte-offset → xpointer map; PDF/DjVu: extracted text offsets map
  directly to word boxes
- **performance**: crengine keeps a rendered-page buffer, and calls such as
  `findText` / `getTextFromXPointers` / `clearSelection` invalidate it and
  force a full re-layout (seconds on complex EPUBs — this once froze the UI
  while listening). The whole listening path now uses rendering-safe calls,
  guarded by a "zero render invalidation" test (buffer-trashing APIs are
  replaced with erroring stubs and the full pipeline is exercised)
- the underline is cleared/moved on segment change, stop and manual page turns;
  the *Underline text while reading* menu toggle turns the feature off

### Top menu icon

Tap the top of the reader screen (or the menu key) to open the top menu: the
icon bar gains a **🔊 speaker icon** at the right end. Tapping it shows the
plugin menu natively in the top menu (checkmarks, submenus, toggles all work).
How it works:

- the plugin ships `icons/mimo_tts.svg`, copied at startup into
  `koreader data dir/icons/` (KOReader's user icon directory, searched before
  the bundled icons)
- the reading tab is registered through KOReader's official menu ordering
  config `koreader data dir/settings/reader_menu_order.lua` — only its own
  entries are appended, existing menu customizations are kept
- the *Top menu icon* menu toggle removes/restores it (reopen the menu to see
  the change)

## Internationalization (i18n)

The menu and settings UI follow KOReader's language setting:

- **source strings are English** (KOReader convention: `en_US` shows source
  strings); Chinese translations live in `l10n/zh_CN/mimo_tts.po` / `.mo`;
  other languages fall back to English
- at load time `translations.lua` merges `l10n/<lang>/mimo_tts.mo` into
  KOReader's gettext tables (language switches need a restart, like KOReader
  itself); **core koreader.mo translations win for shared msgids**, so common
  words (e.g. "Cancel") are never overwritten globally
- workflow:
  - `make pot` — extract translatable strings into `l10n/mimo_tts.pot`
  - add a language: `mkdir l10n/<lang>`, copy the pot to `mimo_tts.po`,
    translate, then `make mo`
  - `make po-update` — refresh all po files from the pot
  - `tools/i18n-convert.py` — the Chinese→English migration map (a handy
    translation reference)
- current coverage: **menus and settings dialogs** (including voice labels and
  dispatcher action names); player/API error messages are still Chinese-only
  and will follow later

## Playback architecture (all device types)

The playback manager picks the best backend automatically (force one via
*Playback & segmentation settings → Playback backend*):

| Priority | Backend | Devices | Notes |
| --- | --- | --- | --- |
| 1 | custom command `player_cmd` | any | explicit user configuration wins over everything |
| 2 | **OpenSL ES (LuaJIT FFI)** | **all Android** | talks to the NDK public library `libOpenSLES.so` (shipped with Android 2.3+): no external binaries, no KOReader changes, no root |
| 3 | command line player auto-detection | desktop Linux / Kobo / Kindle / PocketBook / reMarkable / macOS | `mpv → ffplay → mpg123 → madplay → ogg123 → sox play → aplay → paplay → afplay` |
| 4 | clear error + playback diagnostics | — | *Playback diagnostics…* shows the active backend, formats and available players |

- **format negotiation**: backends declare the formats they accept and the
  synthesizer adapts — e.g. the Android OpenSL ES backend only takes WAV, so
  audio is synthesized as `wav` automatically
- **OpenSL ES backend**: WAV parsing (RIFF/fmt/data) → PCM straight into the
  buffer queue; the PCM buffer is pinned during playback (OpenSL `Enqueue`
  does not copy memory); the buffer queue count is the "still playing" signal
  (the command line backend polls `/proc` the same way, keeping sentence
  transitions gapless)
- **testability**: the Android backend is fully exercised on the desktop
  against a mock `libOpenSLES.so` (same ABI); the E2E suite runs two
  scenarios (command / opensles) with 39 assertions each

## Requirements & notes

- **network**: synthesis calls the MiMo TTS API
- **audio output**:
  - **Android**: works out of the box (native OpenSL ES backend)
  - **desktop Linux / macOS**: mpv/ffplay are usually present; install one
    otherwise
  - **Kobo / Kindle / PocketBook / reMarkable**: any supported command line
    player must exist on the device (pair Bluetooth headsets at the system
    level); or specify `player_cmd` yourself
  - if none of these apply, *Playback diagnostics…* explains what is missing
  - devices without any audio hardware (e.g. speaker-less Kobos) obviously
    cannot produce sound
- **caching**: one segment per sentence, synthesized on demand (3-sentence
  look-ahead); audio is cached by "text + voice + style + model" hash, so
  re-listening sends no duplicate requests
- **streaming synthesis**: streaming requests use `pcm16` as documented; the
  plugin assembles the PCM chunks into a WAV and plays that (playback still
  needs the complete file — streaming mainly adds robustness for long texts)
- **singing mode**: the `(唱歌)歌词` tag works with `mimo-v2.5-tts` — just set
  the style tag to `唱歌`/`sing`

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| synthesis fails with an authentication error | check the API key |
| synthesis fails with "cannot connect" | check network and the API base URL |
| voice design complains about a missing voice description | fill in *Voice description* under *Voice & style settings* |
| voice sample file not found | fix the mp3/wav path under *Voice & style settings* |
| no audio player found | install mpv (or friends), or set *Player command* |
| no readable text found | the page may be a scanned image (PDFs need a text layer); use *Read selected text* after long-pressing |
| no sound | check volume/Bluetooth, then try *Test reading* |

## Versioning & releases

- **[SemVer](https://semver.org/)**: `MAJOR` = incompatible changes (settings
  format, request contract), `MINOR` = backwards-compatible features,
  `PATCH` = fixes
- the version lives in `main.lua` (`version = "x.y.z"`) and is shown in
  *About MiMo TTS*; git tags `vX.Y.Z` must match it (enforced by the release
  script)
- every release has an entry in [CHANGELOG.md](CHANGELOG.md)
- cutting a release:
  1. bump `version` in `main.lua` and add a `CHANGELOG.md` entry
  2. `make release` — syntax check, translation compile,
     `dist/mimo-tts.koplugin-vX.Y.Z.zip` (plus `dist/vX.Y.Z-notes.md`)
  3. `git commit -am "Release vX.Y.Z" && git tag vX.Y.Z && git push origin main --tags`
- **CI releases**: pushing a `v*` tag runs
  [`.github/workflows/release.yml`](.github/workflows/release.yml), which
  re-runs the checks in a clean environment, rebuilds the zip and publishes a
  GitHub release with the changelog section as notes; it can also be triggered
  manually for an existing tag (Actions → Release → Run workflow), and re-runs
  just refresh the release assets
- end users install either from the release zip (extract `mimo-tts.koplugin`
  into their plugins directory) or via `install.sh`

## Development & testing

- pure Lua, no external Lua dependencies; `base64.lua` / `chunker.lua` /
  `mimoapi.lua` / `player.lua` / `textprovider.lua` are independently testable
- end-to-end testing: launch a real KOReader process with
  `KO_HOME=<temp dir>`, drive the plugin through the complete listening flow
  with a user patch, and validate every request shape (model / messages /
  voice / streaming format) against a mock MiMo API implementing the official
  contract; assertions cover automatic page turns, caching and all three
  models
- i18n tooling: `make pot` / `make mo` / `make po-update` (GNU gettext)
