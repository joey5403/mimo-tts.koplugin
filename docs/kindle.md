# Kindle support status & roadmap

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

## Gate 2: the audio route is unknown

On modern Kindles (PW4/PW5/KT10 and later) the only audio output is the
firmware Bluetooth stack (`com.lab126.btService` / `com.lab126.btfd`), and
per Amazon's own docs it is limited to VoiceView and Audible. Whether a
userspace player can push PCM into it on a jailbroken device is **unverified
by anyone** -- that is exactly what the test device is for.

The plugin's diagnostics menu probes the environment on Kindle (ALSA
`/dev/snd`, OSS `/dev/dsp`, Bluetooth hardware, `btService` running) to make
that first experiment a one-look answer.

## Scenarios and plan

| Result of on-device testing | Path | Code work |
| --- | --- | --- |
| A. The BT stack exposes a standard audio API (ALSA/OSS/BlueZ) | Cross-compile a small static player (e.g. mpg123), point *Player command* at it | None |
| B. BT audio only accepts the proprietary Audible path | Reverse `btService`, or feed it disguised Audible files | New `kindle` backend |
| C. BT is fully locked | (1) fall back to Kindle Touch/Keyboard for the wired-audio path (kernel audio, mplayer ports exist); (2) add an **HTTP stream backend**: serve synthesized audio and play it on the phone -- arguably the right UX for Kindle anyway | New streaming backend |

Scenario C(2) is attractive regardless: a Kindle screens + phone speaker/
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
- [ ] Probe the audio route: look for `/dev/snd`, `/dev/dsp`, BlueZ sockets,
      and what `btService` exposes; decide scenario A/B/C
- [ ] If A: build/upload a static armv7l player, wire it via *Player command*
