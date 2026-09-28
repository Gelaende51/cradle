SHELL := bash
SH_FILES := bin/cradle bin/cradle-testd bin/cradle-request $(wildcard lib/*.sh) $(wildcard image/*.sh) $(wildcard tests/integration/*.sh)

.PHONY: check lint test integration proxy-smoke testd-integration
check: lint test
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
