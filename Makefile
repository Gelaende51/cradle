SHELL := bash
SH_FILES := bin/cradle $(wildcard lib/*.sh) $(wildcard image/*.sh) $(wildcard tests/integration/*.sh)

.PHONY: check lint test integration
check: lint test
lint:
	shellcheck -x $(SH_FILES)
test:
	bats tests
integration:
	bash tests/integration/foundation.sh
