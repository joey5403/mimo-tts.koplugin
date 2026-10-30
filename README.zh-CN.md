# MiMo TTS 语音听书（KOReader 插件）

[English](README.md) | **简体中文**

用 **小米 MiMo TTS（MiMo-V2.5-TTS 系列）** 给 KOReader 做“语音听书”：把当前页 / 选中文字 /
整本书的文字提取出来，调用 MiMo TTS 合成语音，再用设备上最合适的音频后端播放。
支持自动翻页连续听书、预置音色选择、风格标签/自然语言风格控制、音色设计与音色复刻、
流式合成、分段合成缓存、上一段/下一段导航。

功能实现遵循官方文档：
<https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/speech-synthesis-v2.5>

## 功能

- **连续听书**：从当前页开始自动翻页，逐句朗读直到书末
- **朗读当前页 / 选中文字**：只读一页或长按选中的文字
- **预置音色**：冰糖 / 茉莉 / 苏打 / 白桦 / Mia / Chloe / Milo / Dean / mimo_default
- **三种模型**：
  - `mimo-v2.5-tts`：预置精品音色合成（默认）
  - `mimo-v2.5-tts-voicedesign`：用一段文字描述定制音色
  - `mimo-v2.5-tts-voiceclone`：用 mp3/wav 音频样本复刻音色（≤10MB）
- **风格控制**（官方两种方式都支持）：
  - 自然语言控制：`风格提示` 写进 user 消息（如“温柔的有声书旁白”），语速也在此控制
  - 音频标签控制：`风格标签` 自动加在文本开头，如 `(温柔)`、`(磁性)`、`(东北话)`、`(唱歌)`
- **按句朗读 + 精确划线**：一句一段，正在朗读的那句画下划线，读完立即取消并
  移到下一句
- **流式合成**：可选 `stream=true` + `pcm16`（24kHz 单声道），长文本更稳
- **句间无缝**：播放当前句时预合成后续句子（前瞻 3 句、跨页预热）
- **语音缓存**：音频按内容哈希缓存，重听零流量
- **全设备播放**：安卓原生 OpenSL ES 后端 + 命令行播放器自动检测
  （mpv / ffplay / mpg123 / madplay / sox `play` / aplay / paplay / afplay），可自定义
- **顶部菜单图标**：阅读页顶部菜单栏新增 🔊 图标，点击直接打开插件菜单（可在菜单里开关）
- **手势 / 快捷键 / 调度器**：所有操作都注册为 Dispatcher 动作，可绑定手势或快捷键

## 安装

把整个 `mimo-tts.koplugin` 目录复制到 KOReader 的插件目录即可：

- 通用：`<koreader 数据目录>/plugins/`（桌面版/多用户模式是 `~/.config/koreader/plugins/`）
- 或 `<koreader 安装目录>/plugins/`（与内置插件同级）
- 或任意位置 + 在 `settings.reader.lua` 配置 `extra_plugin_paths`
- Android：`/sdcard/koreader/plugins/`

重启 KOReader 后，菜单 → 更多工具（More tools）→ **MiMo TTS 语音听书**。

## 设置

### 接口与模型设置

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| API 地址 | `https://token-plan-cn.xiaomimimo.com/v1` | 请求发往 `{API 地址}/chat/completions`（Token Plan 中国区端点；也可用 `https://api.xiaomimimo.com/v1`） |
| API Key | （空） | 必填，通过 `api-key` 请求头发送 |
| 模型 | `mimo-v2.5-tts` | 或 `mimo-v2.5-tts-voicedesign` / `mimo-v2.5-tts-voiceclone` |
| 音频格式（mp3 / wav） | `mp3` | 流式模式自动使用 `pcm16` |

### 音色与风格设置

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| 风格标签（如 温柔/磁性，可留空） | （空） | 加在每段文本开头，如 `温柔` → `(温柔)文本…`；文本已带标签时不重复添加 |
| 风格提示（自然语言指令，可留空） | （空） | 自然语言风格指令（user 消息），如“低沉磁性的深夜电台男声” |
| 音色描述（音色设计模式必填） | （空） | **音色设计模式必填**，如“丝滑醇厚的中年男声，语速缓慢沉稳” |
| 音色样本文件（音色复刻模式，mp3/wav） | （空） | **音色复刻模式必填**，本地 mp3/wav 文件（≤10MB） |

“选择预置音色”子菜单可直接切换官方音色（仅 `mimo-v2.5-tts` 模式有效）。
菜单里的“流式合成”开关控制 `stream=true`/`pcm16` 请求。

### 播放与分段设置

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| 语速（1.0 为正常语速） | `1.0` | 通过 user 消息自然语言控制（如 1.25 → “语速约为正常的 1.25 倍。”） |
| 单句最大字数（超长句自动切分） | `300` | 超长句自动切分的上限 |
| 播放器命令（留空自动检测） | （空） | 留空自动检测；可填 `mpv --no-video` 等，文件名会追加在命令后 |
| 播放后端（auto/command/opensles） | `auto` | 有特殊需要时强制指定后端 |

### 请求示例（与官方文档一致）

```http
POST https://token-plan-cn.xiaomimimo.com/v1/chat/completions
api-key: <API Key>
Content-Type: application/json

{
  "model": "mimo-v2.5-tts",
  "messages": [
    {"role": "user", "content": "温柔的有声书旁白 语速约为正常的 1.25 倍。"},
    {"role": "assistant", "content": "(温柔)要朗读的文字"}
  ],
  "audio": {"format": "mp3", "voice": "mimo_default"}
}
```

- 音色复刻时 `audio.voice` 为 `data:audio/mpeg;base64,...` 形式的音频样本
- 音色设计时 user 消息为音色描述，`audio` 不带 `voice`
- 流式模式下 `"audio": {"format": "pcm16", ...}, "stream": true`，
  音频在 `choices[1].delta.audio.data`（base64, 24kHz PCM16LE 单声道）
- 非流式响应的音频位于 `choices[1].message.audio.data`（base64）

## 使用

打开一本书后，菜单 → **MiMo TTS 语音听书**：

- **连续听书（自动翻页）**：从当前页读到书末
- **朗读当前页**：只读当前页
- **朗读选中文字**：先长按选择文字再触发
- **下一段 / 上一段**：跳到下一段或上一段（跨页自动切换）
- **停止朗读**：停止播放并结束会话
- **测试朗读**：合成并播放一句测试音频，用于排查配置问题
- **播放器诊断…**：查看当前后端、支持格式与可用播放器
- **清除语音缓存**：删除 `koreader 数据目录/cache/mimo_tts/` 下的音频文件

所有动作都注册到了 **调度器（Dispatcher）**，可以在“手势”设置或快捷键里绑定：

- `MiMo TTS: 开始/停止听书`
- `MiMo TTS: 朗读本页`
- `MiMo TTS: 连续听书`
- `MiMo TTS: 停止朗读`
- `MiMo TTS: 下一段` / `MiMo TTS: 上一段`

听书过程中可以正常翻页、打开菜单；手动翻页后连续听书会从新的位置继续。

### 朗读下划线

听书时，**正在朗读的句子**会在页面上画下划线（复用 KOReader 的临时高亮管线，
样式为 `underscore`）；句子读完后下划线立即取消并移向下一句。实现要点：

- 朗读按**单句**分段，播放中的那一句就是划线范围；前瞻合成（预热后续 3 句、
  跨页预热）保证句与句之间无停顿
- 分段时保留每段在原文中的**字节范围**，据此定位文段位置
- 重排文档（EPUB/TXT…）：启动时用
  `getNextVisibleWordEnd` 遍历当前页的文本节点（含内联标签内的节点），
  构建“字节偏移 → xpointer”映射，段落范围直接转成屏幕行框；
  PDF/DjVu：按提取文本的字节范围映射到词框
- **性能要点**：crengine 有渲染缓存，`findText`/`getTextFromXPointers`/
  `clearSelection` 等调用会使缓存失效并触发整页重排（复杂 EPUB 上要几秒，
  曾导致听书时界面假死）。听书链路全部改用渲染安全的调用，且有
  “零渲染失效”测试（把这些 API 换成报错桩跑完整流程）守卫
- 播放下一段、停止、手动翻页时自动清除/移动；菜单里的
  “播放时给文字加下划线”开关可关闭该效果

### 顶部菜单图标

阅读页里点顶部（或菜单键）打开顶部菜单，图标栏最右侧多了一个 **🔊 喇叭图标**，
点击后在顶部菜单里直接显示插件菜单（原生渲染：音色可勾选、开关保持打开）。实现方式：

- 插件自带 `icons/mimo_tts.svg`，启动时自动复制到 `koreader 数据目录/icons/`
  （KOReader 的用户图标目录，优先于内置图标）
- 通过 KOReader 官方的菜单排序配置
  `koreader 数据目录/settings/reader_menu_order.lua` 把听书 tab 注册进顶部菜单，
  只追加自己的条目，不影响你已有的菜单定制
- 菜单里的“顶部菜单图标”开关可随时移除/恢复（重新打开菜单生效）

## 国际化（i18n）

菜单与设置界面跟随 KOReader 的语言设置（简体中文 / English 等）：

- **源字符串为英文**（KOReader 约定：`en_US` 直接显示源串）；中文翻译在
  `l10n/zh_CN/mimo_tts.po` / `.mo`，其他语言缺失时显示英文
- 运行时 `translations.lua` 把 `l10n/<lang>/mimo_tts.mo` 合并进 KOReader 的
  gettext 翻译表（语言切换需重启，与 KOReader 本身一致）；**核心 koreader.mo
  的同名翻译优先**，避免共享词（如 Cancel）在全局被覆盖
- 工作流：
  - `make pot` —— 提取可翻译串到 `l10n/mimo_tts.pot`
  - 添加语言：`mkdir l10n/<lang>`，把 pot 复制为 `mimo_tts.po` 翻译后 `make mo`
  - `make po-update` —— 用新 pot 刷新所有 po
  - `tools/i18n-convert.py` —— 本次中→英迁移的映射表（可作翻译参考）
- 当前覆盖范围：**菜单与设置界面**（含音色列表、调度器动作名）；
  播放器/API 错误消息等后续再翻

## 播放架构（支持所有设备类型）

播放管理器按优先级自动选择后端（`播放与分段设置 → 播放后端` 可强制指定）：

| 优先级 | 后端 | 适用设备 | 说明 |
| --- | --- | --- | --- |
| 1 | 自定义命令 `player_cmd` | 任意 | 显式配置的命令行播放器，最高优先级 |
| 2 | **OpenSL ES（LuaJIT FFI）** | **所有 Android** | 直接调用 NDK 公共库 `libOpenSLES.so`（Android 2.3+ 自带）：无需外部二进制、无需改 KOReader、无需 root |
| 3 | 命令行播放器自动检测 | 桌面 Linux / Kobo / Kindle / PocketBook / reMarkable / macOS | `mpv → ffplay → mpg123 → madplay → ogg123 → sox play → aplay → paplay → afplay` |
| 4 | 明确报错 + 播放器诊断 | — | 菜单“播放器诊断…”显示当前后端、支持格式、可用播放器 |

- **格式协商**：后端声明支持的音频格式，合成输出自动适配——例如安卓 OpenSL 后端只接受
  WAV，就自动以 `wav` 合成（无需手动改设置）
- **OpenSL ES 后端要点**：WAV 解析（RIFF/fmt/data）→ PCM 直喂缓冲队列；播放期间
  pin 住 PCM 缓冲（OpenSL `Enqueue` 不拷贝内存）；缓冲队列计数即“是否在播”
  （`/proc` 轮询同理用于命令行后端，句间衔接零缝隙）
- **测试性**：安卓后端在桌面可用 mock `libOpenSLES.so`（同一 ABI）完整回归，
  E2E 有 command / opensles 两个场景各 39 项断言

## 依赖与注意

- **网络**：合成需要联网访问 MiMo TTS API
- **音频输出**：
  - **Android**：开箱即用（OpenSL ES 原生后端）
  - **桌面 Linux / macOS**：通常已有 mpv/ffplay；没有则装一个即可
  - **Kobo / Kindle / PocketBook / reMarkable**：需要设备上有任一受支持的命令行播放器
    （蓝牙耳机需系统侧配对好）；也可用 `player_cmd` 自己指定
  - 全部不满足时，菜单“播放器诊断…”会说明缺什么；没有任何音频硬件的设备
    （如无扬声器的 Kobo）自然无法出声
- **缓存**：一句一段、按需合成（前瞻预热 3 句），音频按“文本 + 音色 + 风格 + 模型”哈希存放在
  `koreader 数据目录/cache/mimo_tts/`，重复朗读同一段文字不会重复请求
- **流式合成**：流式请求按官方要求使用 `pcm16`，插件把收到的 PCM 分片拼装成 WAV
  再播放（播放仍需完整文件，流式主要用于长文本合成的稳定性）
- **唱歌模式**：`(唱歌)歌词` 标签可用（`mimo-v2.5-tts` 支持），把风格标签填 `唱歌` 即可

## 故障排查

| 现象 | 处理 |
| --- | --- |
| “合成失败：认证失败” | 检查 API Key |
| “合成失败：无法连接” | 检查网络、API 地址 |
| “音色设计模式…需要填写音色描述” | 在“音色与风格设置”里填写音色描述 |
| “找不到音色样本文件” | 在“音色与风格设置”里填正确的 mp3/wav 路径 |
| “找不到音频播放器” | 安装 mpv 等，或在“播放与分段设置”里指定播放器命令 |
| “没有提取到可朗读的文字” | 该页可能是图片/扫描版（PDF 需要文字层），可长按选中文字后“朗读选中文字” |
| 播放没有声音 | 检查设备音量/蓝牙；先用“测试朗读”验证 |

## 版本与发布

- **[语义化版本](https://semver.org/)**：`MAJOR` = 不兼容变更（设置格式、请求契约），
  `MINOR` = 向后兼容的新功能，`PATCH` = 修复
- 版本号唯一来源是 `main.lua`（`version = "x.y.z"`），菜单「关于 MiMo TTS」可见；
  git tag `vX.Y.Z` 必须与之一致（发布脚本强制校验）
- 每个版本在 [CHANGELOG.md](CHANGELOG.md) 有对应记录
- 发布流程：
  1. 修改 `main.lua` 的 `version` 并补 `CHANGELOG.md` 条目
  2. `make release` —— 语法检查、翻译编译、生成
     `dist/mimo-tts.koplugin-vX.Y.Z.zip`
  3. `git commit -am "Release vX.Y.Z" && git tag vX.Y.Z && git push origin main --tags`
  4. 在 GitHub 为 `vX.Y.Z` 创建 Release 并附上 zip
- 用户安装方式：下载 Release zip 解压到插件目录，或用 `install.sh`

## 开发与测试

- 纯 Lua 实现，无外部 Lua 依赖；`base64.lua` / `chunker.lua` / `mimoapi.lua` /
  `player.lua` / `textprovider.lua` 均可独立测试
- 端到端测试（E2E）思路：用 `KO_HOME=<临时目录>` 启动真实 KOReader 进程，
  通过 user patch 驱动插件完整跑一遍听书流程，mock MiMo API 按官方文档校验
  请求形状（模型 / 消息 / 音色 / 流式格式），并断言自动翻页、缓存与三种模型请求
- i18n 工具链：`make pot` / `make mo` / `make po-update`（GNU gettext）
