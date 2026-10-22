# Include after setting INFRA_KIT and INFRA_KIT_ROOT in the consumer Makefile.
# FILE is the plaintext path; edit uses FILE.enc. No infrastructure layout is assumed.
FILE ?= $(INFRA_KIT_ROOT)/$(or $(INFRA_KIT_DEFAULT_SECRETS),secrets.env)
INFRA_KIT_OPS_PLAINTEXT ?=
INFRA_KIT_OPS_VALIDATE_HOOK ?=
export INFRA_KIT INFRA_KIT_ROOT INFRA_KIT_VERSION FILE
export INFRA_KIT_OPS_PLAINTEXT INFRA_KIT_OPS_VALIDATE_HOOK

.PHONY: verify-infra-kit sync-infra-kit encrypt edit encrypt-ops edit-ops
verify-infra-kit:
	@bash "$$INFRA_KIT/bootstrap/verify.sh" "$$INFRA_KIT"

sync-infra-kit:
	@bash "$$INFRA_KIT/bootstrap/sync.sh" --version "$$INFRA_KIT_VERSION" --vendor-dir "$$INFRA_KIT"

encrypt: verify-infra-kit
	@bash "$$INFRA_KIT/scripts/encrypt.sh" "$$FILE"

edit: verify-infra-kit
	@bash "$$INFRA_KIT/scripts/edit-encrypted.sh" "$$FILE.enc"

encrypt-ops: verify-infra-kit
	@test -n "$$INFRA_KIT_OPS_PLAINTEXT" || { echo 'Set INFRA_KIT_OPS_PLAINTEXT' >&2; exit 2; }
	@INFRA_KIT_VALIDATE_HOOK="$$INFRA_KIT_OPS_VALIDATE_HOOK" bash "$$INFRA_KIT/scripts/encrypt.sh" "$$INFRA_KIT_OPS_PLAINTEXT"

edit-ops: verify-infra-kit
	@test -n "$$INFRA_KIT_OPS_PLAINTEXT" || { echo 'Set INFRA_KIT_OPS_PLAINTEXT' >&2; exit 2; }
	@INFRA_KIT_VALIDATE_HOOK="$$INFRA_KIT_OPS_VALIDATE_HOOK" bash "$$INFRA_KIT/scripts/edit-encrypted.sh" "$$INFRA_KIT_OPS_PLAINTEXT.enc"

# op resolves references at runtime; no vault values are copied into this repository.
OP_ENV_FILE ?=
export OP_ENV_FILE COMMAND
.PHONY: op-run
op-run: verify-infra-kit
	@test -n "$$COMMAND" || { echo 'Set COMMAND to the command to run' >&2; exit 2; }
	@if test -n "$$OP_ENV_FILE"; then \
		exec op run --env-file="$$OP_ENV_FILE" -- sh -c "$$COMMAND"; \
	else \
		exec op run -- sh -c "$$COMMAND"; \
	fi
