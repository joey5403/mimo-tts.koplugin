# Third-party components in `bin/`

## kindle-gst-play

- **Source**: [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
  (`kindle/gst-play`, build `kindle-gst-play 0.6.2-compat`)
- **License**: AGPL-3.0-only — see [LICENSE-gst-play.txt](LICENSE-gst-play.txt)
- **Changes**: none. The binary is redistributed unmodified.
- **Why**: on jailbroken Kindles, Amazon does not expose Bluetooth audio as an
  ALSA device, but its private GStreamer `mixersink` element routes PCM to
  Bluetooth headphones (`mixersink → audiomgrd → audio.a2dp.default.so → A2DP`).
  `gst-play` feeds WAV audio into that pipeline. The reverse engineering of
  this audio path is documented in that project's `docs/PLATFORM_AUDIO.md`;
  all credit for the discovery and the helper belongs to its authors.

This plugin only invokes the program as a separate process; the two works are
not linked.

## glibc runtime (`bin/lib/`)

- **Source**: Debian 12 "bookworm" armhf package
  `libc6_2.36-9+deb12u14` (files: `ld-linux-armhf.so.3`, `libc.so.6`,
  `libdl.so.2`) — <https://deb.debian.org/debian/pool/main/g/glibc/>
- **License**: LGPL-2.1-or-later — see [LICENSE-glibc.txt](LICENSE-glibc.txt)
- **Why**: `kindle-gst-play` requires GLIBC ≥ 2.34 while Kindle's system
  glibc is older, so the plugin runs it through the bundled loader:

  ```
  LD_LIBRARY_PATH=bin/lib bin/lib/ld-linux-armhf.so.3 bin/kindle-gst-play <file.wav>
  ```
