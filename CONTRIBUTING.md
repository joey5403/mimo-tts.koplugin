# Contributing to MiMo TTS Read-aloud

Thanks for helping! This document describes the development workflow.
[简体中文版](CONTRIBUTING.zh-CN.md)

## Ways to contribute

- **Bug reports** — see [Reporting bugs](#reporting-bugs)
- **Translations** — see [Translations](#translations)
- **Code & docs** — everything below

## Pull request workflow

All changes land on `main` through pull requests — direct pushes are blocked
by branch protection.

1. **Fork and branch** from an up-to-date `main`:

   ```sh
   git switch -c feat/my-change
   ```

   Branch naming: `feat/*`, `fix/*`, `docs/*`, `test/*`, `i18n/*`, `refactor/*`

2. **Commit** with [Conventional Commits](https://www.conventionalcommits.org/)
   prefixes — the changelog is generated from them:

   ```
   feat: add sleep timer for listening sessions
   fix: underline no longer drifts on multi-column EPUBs
   docs: explain the playback backend matrix
   ```

   Full list used for grouping: `feat`, `fix`, `perf`, `refactor`, `docs`,
   `test`, `build`, `ci`; anything else is listed under "Changes".

3. **Local CI runs before every commit** (a git pre-commit hook installed by
   `make install-hooks` runs `make ci`: Lua syntax, translation catalogs, the
   full test battery). No CI runs on GitHub — the gate is local by design.

4. **Push and open a PR** against `main`, filling in the PR template
   checklist.

5. **Review & merge** — squash-merge is preferred; the squash commit subject
   becomes the changelog entry, so keep the PR title a good conventional
   commit message.

## Development setup

| Requirement | Why |
| --- | --- |
| [KOReader](https://github.com/koreader/koreader) install | the test battery drives the real plugin code against it (`KOREADER_DIR`, default `/usr/lib/koreader`) |
| luajit (ships with KOReader) | syntax checks |
| GNU gettext | translation tooling |
| python3 | fixtures, mock API, release notes |
| gcc | mock `libOpenSLES.so` for the Android playback backend tests |

```sh
git clone https://github.com/<you>/mimo-tts.koplugin.git
cd mimo-tts.koplugin
make install-hooks    # pre-commit hook: runs 'make ci' before every commit
make ci               # syntax + catalogs + 8 test suites (~2s)
```

| Target | What it does |
| --- | --- |
| `make ci` | the pre-commit gate: `check` + `mo` + `test` |
| `make test` | unit & integration battery (8 suites) |
| `make e2e` | end-to-end battery (command **and** opensles playback scenarios) |
| `make check` | Lua syntax only |
| `make pot` / `make mo` / `make po-update` | translation workflow |
| `make changelog` | regenerate `CHANGELOG.md` from git history |
| `make release` | build `dist/mimo-tts.koplugin-vX.Y.Z.zip` locally |
| `make release-bump BUMP=patch` | maintainers: cut a release (see below) |

The suites live in `tests/` and are self-contained (scratch area under
`/tmp/mimottest`, fixtures, mock MiMo API, mock `libOpenSLES.so`).

## Code guidelines

- Lua style consistent with KOReader's; comments in English
- **UI strings**: wrap in `_("English source string")` (English is the source
  language — `en_US` shows source strings in KOReader); add translations via
  `make pot` → edit `l10n/<lang>/mimo_tts.po` → `make mo`. At minimum keep
  `zh_CN` up to date
- **tests** for behavior changes: add to `tests/` and keep `make test` green;
  `make e2e` is expected to stay green as well
- **docs**: update `README.md` *and* `README.zh-CN.md` when behavior changes
- **never commit secrets**: API keys live in the user's KOReader settings,
  not in the repository

## Reporting bugs

Include:

- plugin version — menu → *About MiMo TTS* (e.g. `1.0.3-2-gabc1234`)
- KOReader version and device / OS
- playback backend and formats — menu → *Playback diagnostics…*
- steps to reproduce, expected vs actual
- logs: lines starting with `MiMoTTS:` from the terminal or the KOReader log

## Translations

1. `mkdir l10n/<lang> && cp l10n/mimo_tts.pot l10n/<lang>/mimo_tts.po`
2. translate the `msgstr` entries (the msgids are English)
3. `make mo`, test with KOReader's language set to `<lang>`
4. open a PR with the new `l10n/<lang>/` directory

## Releases (maintainers)

From an up-to-date `main`:

```sh
make release-bump BUMP=patch   # or minor / major
```

This computes the next version from the latest tag, tags it and pushes; the
release action ([`.github/workflows/release.yml`](.github/workflows/release.yml))
then builds the zip (version stamped at build time) and publishes the GitHub
release with notes generated from the git history.

Alternatively run the action itself (Actions → Release → Run workflow, pick
`patch`/`minor`/`major`): it generates the version **and the tag** and
publishes in a single run. (A tag pushed with `GITHUB_TOKEN` would not
trigger a second workflow run — GitHub's anti-recursion rule — which is why
the flow does everything in one run.) Manual `v*` tags are supported too for
explicit versions.
