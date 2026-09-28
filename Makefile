SHELL := bash
SH_FILES := bin/cradle bin/cradle-testd bin/cradle-request $(wildcard lib/*.sh) $(wildcard image/*.sh) $(wildcard tests/integration/*.sh)

.PHONY: check lint test integration proxy-smoke testd-integration pot po mo i18n-check
check: lint i18n-check test
lint:
	shellcheck -x $(SH_FILES)
test:
	bats tests
integration:
	bash tests/integration/foundation.sh

proxy-smoke:
	bash tests/integration/proxy.sh

testd-integration:
	bash tests/integration/testd.sh

SRC_I18N := bin/cradle bin/cradle-testd $(wildcard lib/*.sh)
XGETTEXT = python3 dev/pot.py

pot:
	mkdir -p po && $(XGETTEXT) $(SRC_I18N) > po/cradle.pot
po: pot
	msgmerge -q -U --backup=none po/de.po po/cradle.pot
mo:
	mkdir -p locale/de/LC_MESSAGES && msgfmt -o locale/de/LC_MESSAGES/cradle.mo po/de.po
# one recipe, so the temporary directory is made and removed by the same shell
i18n-check:
	@t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	$(XGETTEXT) $(SRC_I18N) > "$$t/cradle.pot" \
	&& { msgcmp po/de.po "$$t/cradle.pot" || { echo "i18n: po/de.po misses messages; run: make po, translate, make mo"; exit 1; }; } \
	&& python3 dev/po-check.py po/de.po \
	&& msgfmt -o "$$t/de.mo" po/de.po \
	&& { cmp -s <(msgunfmt "$$t/de.mo") <(msgunfmt locale/de/LC_MESSAGES/cradle.mo) || { echo "i18n: cradle.mo is stale; run: make mo"; exit 1; }; }
