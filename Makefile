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

.PHONY: pot mo po-update
