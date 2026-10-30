# 参与贡献 MiMo TTS 语音听书

欢迎参与！本文档描述开发与协作流程。
[English](CONTRIBUTING.md)

## 贡献方式

- **反馈 Bug** —— 见「反馈问题」
- **翻译** —— 见「翻译」
- **代码与文档** —— 见下文

## Pull Request 工作流

所有变更都通过 PR 进入 `main`（分支保护已禁止直接推送）：

1. **Fork 并从最新的 `main` 拉分支**：

   ```sh
   git switch -c feat/my-change
   ```

   分支命名：`feat/*`、`fix/*`、`docs/*`、`test/*`、`i18n/*`、`refactor/*`

2. **提交使用[约定式提交](https://www.conventionalcommits.org/zh-hans/)**前缀——
   changelog 由提交历史自动生成：

   ```
   feat: 为听书增加睡眠定时
   fix: 修复多栏 EPUB 下划线偏移
   docs: 说明播放后端矩阵
   ```

   用于分组的前缀：`feat`、`fix`、`perf`、`refactor`、`docs`、`test`、
   `build`、`ci`；其余归入「Changes」。

3. **本地 CI 在每次提交前自动执行**（`make install-hooks` 安装的 pre-commit
   钩子会跑 `make ci`：Lua 语法、翻译编译、完整测试）。**GitHub 上不跑 CI**——
   门禁就在本地。

4. **推送分支并开 PR**（目标 `main`），按模板勾选检查项。

5. **评审与合并** —— 推荐 squash 合并；squash 提交的标题就是 changelog 条目，
   请把 PR 标题写成一条好的约定式提交信息。

## 开发环境

| 依赖 | 用途 |
| --- | --- |
| [KOReader](https://github.com/koreader/koreader) 安装 | 测试套件驱动真实插件代码（`KOREADER_DIR`，默认 `/usr/lib/koreader`） |
| luajit（KOReader 自带） | 语法检查 |
| GNU gettext | 翻译工具链 |
| python3 | fixtures、mock API、release 说明生成 |
| gcc | 为安卓播放后端测试编译 mock `libOpenSLES.so` |

```sh
git clone https://github.com/<you>/mimo-tts.koplugin.git
cd mimo-tts.koplugin
make install-hooks    # pre-commit 钩子：提交前自动跑 make ci
make ci               # 语法 + 翻译 + 8 套测试（约 2 秒）
```

| 目标 | 作用 |
| --- | --- |
| `make ci` | 提交门禁：`check` + `mo` + `test` |
| `make test` | 单元与集成测试（8 套） |
| `make e2e` | 端到端测试（command 与 opensles 两个播放场景） |
| `make check` | 仅 Lua 语法 |
| `make pot` / `make mo` / `make po-update` | 翻译工作流 |
| `make changelog` | 从 git 历史重新生成 `CHANGELOG.md` |
| `make release` | 本地构建 `dist/mimo-tts.koplugin-vX.Y.Z.zip` |
| `make release-bump BUMP=patch` | 维护者：一键发版（见下） |

测试套件在 `tests/` 且自包含（`/tmp/mimottest` 沙盒、fixtures、mock MiMo API、
mock `libOpenSLES.so`）。

## 代码规范

- Lua 风格与 KOReader 一致；注释用英文
- **界面文案**：用 `_("English source string")` 包裹（**源串是英文**——KOReader 的
  `en_US` 直接显示源串）；通过 `make pot` → 翻译 `l10n/<lang>/mimo_tts.po` →
  `make mo` 补翻译，至少保持 `zh_CN` 最新
- **行为变更需要测试**：加到 `tests/`，保持 `make test` 绿；`make e2e` 也要保持绿
- **文档**：行为变更时同步更新 `README.md` 与 `README.zh-CN.md`
- **绝不提交密钥**：API Key 放在用户的 KOReader 设置里，不进仓库

## 反馈问题

请提供：

- 插件版本 —— 菜单 →「关于 MiMo TTS」（如 `1.0.3-2-gabc1234`）
- KOReader 版本与设备 / 系统
- 播放后端与格式 —— 菜单 →「播放器诊断…」
- 复现步骤、期望与实际结果
- 日志：终端或 KOReader 日志中 `MiMoTTS:` 开头的行

## 翻译

1. `mkdir l10n/<lang> && cp l10n/mimo_tts.pot l10n/<lang>/mimo_tts.po`
2. 翻译 `msgstr`（msgid 是英文）
3. `make mo`，把 KOReader 语言设为 `<lang>` 验证
4. 带上新的 `l10n/<lang>/` 目录开 PR

## 发布（维护者）

从最新的 `main` 执行：

```sh
make release-bump BUMP=patch   # 或 minor / major
```

它会根据最新 tag 自动计算下一个版本号、打标签并推送；Release Action
（[`.github/workflows/release.yml`](.github/workflows/release.yml)）随后构建
（构建时注入版本号）、按 git 历史生成说明并发布 GitHub Release。
也支持手动推送 `v*` 标签指定明确版本。
