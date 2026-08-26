.PHONY: check lint test

check: lint test

lint:
	bash -n hack/*.sh hack/lib/*.sh bootstrap/*.sh tests/*.sh
	shellcheck -x -P hack -P bootstrap -P tests --shell=bash \
	  hack/*.sh hack/lib/*.sh bootstrap/*.sh tests/*.sh

test:
	@for t in tests/*_test.sh; do bash "$$t" || exit 1; done
