# Local mirror of .github/workflows/ci.yml, plus the day-to-day commands.
# `make` (or `make help`) lists everything.
#
# The PVE API token is env-only, never in a file: export TF_VAR_pve_api_token
# before any target that touches the host (plan, apply). Static checks do not
# need it.
.DEFAULT_GOAL := help

TOFU := tofu -chdir=tofu
ANSIBLE_DIR := ansible

.PHONY: help
help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- static checks: exactly what CI runs ------------------------------------

.PHONY: ci
ci: tofu-check lint check-stacks compose-check ## Run every static check CI runs

.PHONY: tofu-check
tofu-check: ## tofu fmt -check + init + validate (no host contact)
	tofu fmt -check -recursive -diff
	$(TOFU) init -backend=false
	TF_VAR_pve_api_token=ci-placeholder $(TOFU) validate

.PHONY: tofu-fmt
tofu-fmt: ## Rewrite .tf files in canonical form
	tofu fmt -recursive

.PHONY: lint
lint: ## ansible-lint (without needing the age key)
	cd $(ANSIBLE_DIR) && ANSIBLE_VARS_PLUGINS=host_group_vars ansible-lint

.PHONY: check-stacks
check-stacks: ## stacks/ and komodo/stacks.toml agree, and their files exist
	python3 .github/scripts/check_stack_declarations.py

.PHONY: compose-check
compose-check: ## docker stack config over every stack file
	@set -e; \
	for f in stacks/*/docker-compose.yaml; do \
		echo "== $$f"; \
		docker stack config -c "$$f" >/dev/null; \
	done

# --- OpenTofu ---------------------------------------------------------------

.PHONY: plan
plan: ## tofu plan (needs TF_VAR_pve_api_token)
	$(TOFU) plan

.PHONY: apply
apply: ## tofu apply (needs TF_VAR_pve_api_token)
	$(TOFU) apply

.PHONY: inventory
inventory: ## What tofu exposes to Ansible right now
	cd $(ANSIBLE_DIR) && ansible-inventory --graph

# --- Ansible ----------------------------------------------------------------

.PHONY: ping
ping: ## Smoke-test the chain: tofu state -> inventory -> SSH -> become
	cd $(ANSIBLE_DIR) && ansible-playbook ping.yml

.PHONY: site
site: ## Provision every VM: hardening -> tailscale -> docker -> swarm -> komodo
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

.PHONY: secrets
secrets: ## Seed the Swarm secrets from SOPS (run before deploying stacks)
	cd $(ANSIBLE_DIR) && ansible-playbook secrets.yml
