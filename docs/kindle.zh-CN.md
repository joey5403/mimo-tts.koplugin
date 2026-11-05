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
| **播放出声** | ❌ **受阻** | 见下面两道关 |

一句话：到合成为止的全链路都能跑——音频文件会正常生成并缓存，剩下的就是"让设备发出声音"这最后一公里。

## 关卡 1：没有播放器二进制

命令行后端会自动检测 mpv / ffplay / mpg123 / madplay / ogg123 / sox `play` / aplay / paplay / afplay——Kindle 固件一个都不带。此时 `Player:play()` 会给出明确报错，而不是静默失败。

逃生口已经留好：**播放与分段设置 → 播放器命令**。任何"能播 mp3/wav 且播完退出"的命令都可以填进去——所以只要往设备里拷一个静态链接的播放器二进制即可，**不需要改任何代码**。

## 关卡 2：音频路由未知

现代 Kindle（PW4/PW5/KT10 及之后）唯一的音频出口是固件的蓝牙栈（`com.lab126.btService` / `com.lab126.btfd`），且按亚马逊官方说明仅限 VoiceView（屏幕朗读）和 Audible 用途。越狱后用户态播放器能否把 PCM 送进这个蓝牙栈，**全网没有任何人验证过**——这正是测试机的任务。

插件的"播放器诊断"菜单会在 Kindle 上探测环境（ALSA `/dev/snd`、OSS `/dev/dsp`、蓝牙硬件、`btService` 进程），让第一次实验一眼就能得到答案。

## 情景与计划

| 真机验证结果 | 路线 | 代码工作 |
| --- | --- | --- |
| A. 蓝牙栈暴露标准音频接口（ALSA/OSS/BlueZ） | 交叉编译一个小的静态播放器（如 mpg123），在「播放器命令」里指向它 | **零改动** |
| B. 蓝牙音频只认 Audible 私有通道 | 逆向 `btService`，或向它投喂伪装的 Audible 文件 | 新增 `kindle` 后端 |
| C. 蓝牙完全锁死 | (1) 回退到 Kindle Touch/Keyboard 的有线音频（内核音频，有 mplayer 移植先例）；(2) 新增 **HTTP 推流后端**：合成音频通过网络推给手机播放——反正 Kindle 要戴耳机，这个体验可能才是对的 | 新增推流后端 |

无论结果如何，C(2) 都值得做："Kindle 看屏幕 + 手机出声"正好匹配人们真实的听书习惯。

## 测试机检查清单

- [ ] 记录机型 + 固件（设置 → 设备选项 → 设备信息）
- [ ] 用 [Find my Jailbreak 向导](https://kindlemodding.org/jailbreak-wizard.html) 越狱
      （`jailbreaks.json` 覆盖情况：PW4 终点固件 5.18.1.1.1 → SpringBreak / Sanctuary；
      PW5 任意固件至 5.19.2 → Véra / SpringBreak / SpiderCat）
- [ ] 安装 KOReader（固件 ≥ 5.16.3 用 **KindleHF** 构建；较新的越狱自带 Kindle Package Manager）
- [ ] 安装本插件，确认合成与缓存正常
- [ ] 打开「播放器诊断」，记录音频环境各项状态
- [ ] 探测音频路由：查看 `/dev/snd`、`/dev/dsp`、BlueZ socket、`btService` 暴露的接口，判定属于情景 A/B/C
- [ ] 若为 A：构建/上传静态 armv7l 播放器，在「播放器命令」中接好
