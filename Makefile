# i18n tooling for the MiMo TTS plugin
#
#   make pot   -- extract translatable strings into l10n/mimo_tts.pot
#   make mo    -- compile every l10n/<lang>/mimo_tts.po into mimo_tts.mo
#   make po-update -- refresh l10n/<lang>/mimo_tts.po from the pot
#
# Requires the GNU gettext tools (xgettext, msgfmt, msgmerge).

LUA_SRC = _meta.lua main.lua mimoapi.lua player.lua openslesplayer.lua \
          textprovider.lua chunker.lua base64.lua translations.lua
DOMAIN  = mimo_tts
POT     = l10n/$(DOMAIN).pot

pot:
	mkdir -p l10n
	xgettext --from-code=UTF-8 --language=Lua \
	    --keyword=_ --keyword=N_:1,2 --keyword=C_:1c,2 \
	    --package-name=mimo-tts --package-version=1.0 \
	    --output=$(POT) $(LUA_SRC)
	@echo "wrote $(POT)"

mo:
	@for po in l10n/*/*.po; do \
	    lang=$$(dirname $$po | xargs basename); \
	    msgfmt --check --output-file=l10n/$$lang/$(DOMAIN).mo $$po && \
	        echo "compiled l10n/$$lang/$(DOMAIN).mo"; \
	done

po-update:
	@for po in l10n/*/*.po; do \
	    msgmerge --update --backup=none $$po $(POT) && echo "updated $$po"; \
	done

check:
	@for f in *.lua; do $(LUAJIT) -bl $$f >/dev/null || exit 1; done
	@echo "syntax OK"

# unit/integration battery (local; needs a KOReader install, see tests/run.sh)
test:
	sh tests/run.sh

# end-to-end battery against a real KOReader process (slower; command and
# opensles playback scenarios)
e2e:
	sh tests/run.sh >/dev/null
	sh tests/run_e2e.sh dummy
	SCENARIO=opensles sh tests/run_e2e.sh dummy

# local CI gate, run by the pre-commit hook (make install-hooks)
ci: check mo test
	@echo "ci: all checks passed"

install-hooks:
	cp tools/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "pre-commit hook installed (runs 'make ci' before every commit)"

# regenerate CHANGELOG.md from git history
changelog:
	python3 tools/release-notes.py --changelog > CHANGELOG.md
	@echo "CHANGELOG.md regenerated from git history"

# build a release zip locally (version from the tag / --version / --bump)
release: check mo
	sh tools/release.sh $(RELEASE_ARGS)

# one-command release: compute the next version, tag it and push; the
# release action builds and publishes when it sees the new tag
release-bump:
	@V=$$(sh tools/next-version.sh $(BUMP)); \
	git tag -a v$$V -m "MiMo TTS Read-aloud v$$V" && \
	git push origin v$$V && \
	echo "tagged v$$V -- the release action will build and publish it"

LUAJIT ?= luajit

.PHONY: pot mo po-update check test e2e ci install-hooks changelog release release-bump

BUMP ?= patch
