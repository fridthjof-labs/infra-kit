.PHONY: check lint test pins

check: lint test

lint: pins
	bash -n hack/*.sh hack/lib/*.sh bootstrap/*.sh tests/*.sh
	shellcheck -x -P hack -P bootstrap -P tests --shell=bash \
	  hack/*.sh hack/lib/*.sh bootstrap/*.sh tests/*.sh

test:
	@for t in tests/*_test.sh; do bash "$$t" || exit 1; done

# A tag can be moved to point at different code. These jobs hold a token that
# can write to this repository, so every action stays pinned to a commit SHA.
pins:
	@bad=$$(grep -rhoE '^\s*-?\s*uses: [^ ]+' .github/workflows/ \
	  | grep -vE '@[0-9a-f]{40}$$' || true); \
	if [ -n "$$bad" ]; then \
	  echo "error: unpinned action(s):" >&2; echo "$$bad" >&2; exit 1; \
	fi; \
	echo "all actions pinned to a commit SHA"
