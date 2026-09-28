SHELL := bash
SH_FILES := bin/cradle $(wildcard lib/*.sh) $(wildcard image/*.sh) $(wildcard tests/integration/*.sh)

.PHONY: check lint test integration proxy-smoke
check: lint test
lint:
	shellcheck -x $(SH_FILES)
test:
	bats tests
integration:
	bash tests/integration/foundation.sh

proxy-smoke:
	bash tests/integration/proxy.sh
