# Kindle support status & roadmap

**English** | [简体中文](kindle.zh-CN.md)

Where the plugin stands on Kindle's KOReader, what is missing, and the plan
for getting audio out of a jailbroken Kindle.

## Status today

| Stage | Status | Notes |
| --- | --- | --- |
| Plugin install / menus / settings | Works | Pure KOReader API |
| Text extraction (page / selection / book) | Works | `textprovider.lua` via the document API |
| MiMo synthesis (incl. streaming) | Works | `socket`/`http` -- network only |
| Segmentation, sentence cache, underline | Works | File I/O |
| Gestures / dispatcher bindings | Works | Platform independent |
| **Playback** | **Blocked** | Two gates below |

In short: everything up to and including synthesis works; the audio file is
produced and cached, and the last mile -- getting sound out of the device --
is what remains.

## Gate 1: no player binary

The command backend auto-detects mpv / ffplay / mpg123 / madplay / ogg123 /
sox `play` / aplay / paplay / afplay -- none of which a Kindle firmware
ships. `Player:play()` reports a clear error instead of failing silently.

The escape hatch already exists: **Playback settings → Player command**. Any
command that plays mp3/wav and exits can be plugged in there, so dropping a
statically linked player binary onto the device is enough -- no code changes
required.

## Gate 2: the audio route (now known)

On modern Kindles (PW4/PW5/KT10 and later) the only audio output is the
firmware Bluetooth stack (`com.lab126.btfd` / `com.lab126.btService`).
Amazon does not expose BT headphones as an ALSA device -- `/proc/asound/cards`
reports "no soundcards" even with headphones connected.  But the hard
reverse-engineering done by
[stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
(see its `docs/PLATFORM_AUDIO.md`) found the private path:

```
WAV → GStreamer 0.10 private "mixersink" → audiomgrd → audio.a2dp.default.so → BT headphones
(alternative: LIPC com.lab126.playermgr Open/Play/InPlayback, same pipeline)
```

This plugin bundles their `kindle-gst-play` helper (AGPL-3.0, unmodified --
see `bin/NOTICE.md`) which feeds PCM into `mixersink`, plus a glibc runtime so
it runs on the Kindle's older system glibc.  It is auto-detected as a
wav-only player backend; verified on Kindle Basic 2022 (11th gen) by the
upstream project.

## Scenarios and plan

| Result of on-device testing | Path | Code work |
| --- | --- | --- |
| A. The BT stack exposes a standard audio API (ALSA/OSS/BlueZ) | Static player (e.g. mpg123), point *Player command* at it | None |
| B. GStreamer `mixersink` present (**known solution**) | Bundled `kindle-gst-play` -- auto-detected, wav negotiated automatically | **None -- shipped** |
| C. No GStreamer/mixersink on some models | (1) LIPC `playermgr` route (implemented upstream, can be ported); (2) HTTP-stream backend: serve synthesized audio and play it on the phone | New backend |

Scenario C(2) is attractive regardless: a Kindle screen + phone speaker/
earbuds pairing matches how people actually listen.

## Test device checklist

- [ ] Record model + firmware (Settings → Device Options → Device Info)
- [ ] Jailbreak via the [Find my Jailbreak wizard](https://kindlemodding.org/jailbreak-wizard.html)
      (`jailbreaks.json` coverage: PW4 terminal fw 5.18.1.1.1 → SpringBreak /
      Sanctuary; PW5 any fw up to 5.19.2 → Véra / SpringBreak / SpiderCat)
- [ ] Install KOReader (KindleHF build for fw ≥ 5.16.3; modern jailbreaks
      bundle Kindle Package Manager)
- [ ] Install the plugin, confirm synthesis + caching work
- [ ] Open Playback diagnostics -- note the audio environment lines
- [ ] Probe the audio route: `bin/kindle-gst-play --probe` (look for
      `mixersink`), `lipc-probe com.lab126.playermgr`, and the diagnostics'
      ALSA/OSS/Bluetooth report; decide scenario A/B/C
- [ ] If B: just play -- the bundled backend is auto-detected (wav-only, so
      the plugin negotiates the synthesis format automatically)
- [ ] If A: build/upload a static armv7l player, wire it via *Player command*

## Acknowledgements

The Kindle audio route (`mixersink → audiomgrd → A2DP`) and the `gst-play`
helper come from [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
(AGPL-3.0) -- all credit for that reverse engineering belongs to its authors.
The helper is redistributed unmodified under `bin/` with its license; see
[`bin/NOTICE.md`](../bin/NOTICE.md).
