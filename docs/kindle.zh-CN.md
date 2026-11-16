# Kindle 支持状态与路线图

插件在 Kindle 版 KOReader 上的支持现状、缺失部分，以及让越狱 Kindle 出声的计划。

[English](kindle.md) | **简体中文**

## 当前状态

| 环节 | 状态 | 说明 |
| --- | --- | --- |
| 插件安装 / 菜单 / 设置 | ✅ 可用 | 纯 KOReader API |
| 文本提取（当前页 / 选中 / 整本） | ✅ 可用 | `textprovider.lua` 走 document API |
| MiMo 合成（含流式） | ✅ 可用 | `socket`/`http`，只需联网 |
| 分段、句级缓存、划线 | ✅ 可用 | 文件 I/O |
| 手势 / 调度器绑定 | ✅ 可用 | 平台无关 |
| **播放出声** | ✅ 可用（捆绑助手） | 蓝牙经固件 mixersink 输出；老固件（≤ 5.16.2.1.1）见下方「软浮点固件」 |

一句话：合成、缓存以及（在已验证机型上）播放出声都已跑通——捆绑的 GStreamer 助手把音频喂进固件私有 `mixersink` 管道，再由固件路由到蓝牙 A2DP。老固件（软浮点）的处理见下一节。

## 关卡 1：没有播放器二进制

命令行后端会自动检测 mpv / ffplay / mpg123 / madplay / ogg123 / sox `play` / aplay / paplay / afplay——Kindle 固件一个都不带。此时 `Player:play()` 会给出明确报错，而不是静默失败。

逃生口已经留好：**播放与分段设置 → 播放器命令**。任何"能播 mp3/wav 且播完退出"的命令都可以填进去——所以只要往设备里拷一个静态链接的播放器二进制即可，**不需要改任何代码**。

## 关卡 2：音频路由（已破解）

现代 Kindle（PW4/PW5/KT10 及之后）唯一的音频出口是固件蓝牙栈（`com.lab126.btfd` / `com.lab126.btService`）。亚马逊**不把蓝牙耳机暴露为 ALSA 设备**——即使耳机已连接，`/proc/asound/cards` 也报 "no soundcards"。但 [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin) 项目的硬核逆向（见其 `docs/PLATFORM_AUDIO.md`）找到了私有通道：

```
WAV → GStreamer 0.10 私有 "mixersink" → audiomgrd → audio.a2dp.default.so → 蓝牙耳机
（备选：LIPC com.lab126.playermgr Open/Play/InPlayback，同一管道）
```

本插件捆绑了他们项目的 `kindle-gst-play` 小工具（AGPL-3.0，原样不改动——见 `bin/NOTICE.md`），负责把 PCM 喂进 `mixersink`，并附带 glibc 运行时以兼容 Kindle 较旧的系统 glibc。它会被自动识别为 wav-only 播放后端；该方案已在 Kindle Basic 2022（11 代）上验证。

## 软浮点固件（FW ≤ 5.16.2.1.1）

**5.16.3** 之前的 Kindle 固件使用**软浮点**用户态（亚马逊从 5.16.3 起才切到硬浮点 ABI）。在这类设备上，随包捆绑的 `kindle-gst-play`（硬浮点，Nix glibc 2.42 loader）仍然能启动、`--version` 也能通过，所以自动检测会选中它——但真正播放时，它要 `dlopen()` 系统里**软浮点**的 `libgstreamer-0.10.so`，ABI 不匹配导致管道立即失败；表现就是：合成、缓存都正常，但完全没有声音。

解决办法是额外随包提供一个**软浮点**版本的小工具：

* `bin/kindle-gst-play-pw2`——来自 audiobook.koplugin 的 `kindle/gst-play-native-pw2`，用 `kindlepw2`（软浮点）工具链构建，走 Kindle 系统 loader `/lib/ld-linux.so.3`（GLIBC_2.4 符号），直接链接固件自带的软浮点 GStreamer 0.10；
* `player.lua` 在探测通过时优先使用它，失败后才回退到原来的硬浮点 loader 链；
* 播放器的 stdout/stderr 改为追加写入 `cache/mimo_tts/mimo_tts_player.log`（不再是 `/dev/null`），静默失败也能查。

已在 **Kindle Oasis（8 代，2016），固件 5.16.2.1.1**（该机型最后一个固件）上验证，蓝牙耳机需先在 Kindle 系统设置里配对；软浮点助手把 WAV 喂进同一套固件 `mixersink` 管道，由固件（`audiomgrd`）路由到 A2DP。

排查：如果 `mimo_tts_player.log` 出现 `cannot load libgstreamer`，确认 `bin/kindle-gst-play-pw2` 是软浮点版本——ELF 解释器应为 `/lib/ld-linux.so.3`，而不是 `/lib/ld-linux-armhf.so.3`。

## 情景与计划

| 真机验证结果 | 路线 | 代码工作 |
| --- | --- | --- |
| A. 蓝牙栈暴露标准音频接口（ALSA/OSS/BlueZ） | 静态播放器（如 mpg123），在「播放器命令」里指向它 | **零改动** |
| B. 存在 GStreamer `mixersink`（**已知解法**） | 捆绑的 `kindle-gst-play` 自动识别，wav 格式自动协商 | **无需改动——已随包发布** |
| C. 某些机型没有 GStreamer/mixersink | (1) LIPC `playermgr` 路线（上游已实现，可移植）；(2) HTTP 推流后端：合成音频推给手机播放 | 新后端 |

无论结果如何，C(2) 都值得做："Kindle 看屏幕 + 手机出声"正好匹配人们真实的听书习惯。

## 测试机检查清单

- [ ] 记录机型 + 固件（设置 → 设备选项 → 设备信息）
- [ ] 用 [Find my Jailbreak 向导](https://kindlemodding.org/jailbreak-wizard.html) 越狱
      （`jailbreaks.json` 覆盖情况：PW4 终点固件 5.18.1.1.1 → SpringBreak / Sanctuary；
      PW5 任意固件至 5.19.2 → Véra / SpringBreak / SpiderCat）
- [ ] 安装 KOReader（固件 ≥ 5.16.3 用 **KindleHF** 构建；较新的越狱自带 Kindle Package Manager）
- [ ] 安装本插件，确认合成与缓存正常
- [ ] 打开「播放器诊断」，记录音频环境各项状态
- [ ] 探测音频路由：`bin/kindle-gst-play --probe`（看是否有 `mixersink`）、`lipc-probe com.lab126.playermgr`，结合诊断里的 ALSA/OSS/蓝牙报告，判定情景 A/B/C
- [ ] 若为 B：直接播放即可——捆绑后端自动识别（wav-only，合成格式自动协商）
- [ ] 若为 A：构建/上传静态 armv7l 播放器，在「播放器命令」中接好

## 致谢

Kindle 音频路线（`mixersink → audiomgrd → A2DP`）和 `gst-play` 小工具来自
[stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
（AGPL-3.0）——这项逆向工程的全部功劳属于该项目的作者们。该工具以原样（未修改）
形式随附于 `bin/` 目录并附带其许可证，详见 [`bin/NOTICE.md`](../bin/NOTICE.md)。
