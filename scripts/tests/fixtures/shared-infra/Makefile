SHELL := /bin/sh

PROJECTS_FILE ?= $(CURDIR)/projects.yaml
CALL_LOG ?= $(CURDIR)/calls.log

.PHONY: validate doctor propose register reconcile preflight

validate:
	@printf 'validate PROJECT=%s PROJECTS_FILE=%s\n' "$(PROJECT)" "$(PROJECTS_FILE)" >> "$(CALL_LOG)"
	@test -f "$(PROJECTS_FILE)" || { echo "fixture validate: manifest missing: $(PROJECTS_FILE)" >&2; exit 1; }
	@if grep -q 'INVALID' "$(PROJECTS_FILE)"; then echo "fixture validate: induced validation failure" >&2; exit 1; fi

doctor:
	@printf 'doctor PROJECT=%s REGISTRY_FILE=%s\n' "$(PROJECT)" "$(REGISTRY_FILE)" >> "$(CALL_LOG)"
	@$(MAKE) --no-print-directory validate PROJECT="$(PROJECT)" PROJECTS_FILE="$(PROJECTS_FILE)" CALL_LOG="$(CALL_LOG)"
	@if [ -e "$(CURDIR)/drift" ]; then echo "fixture doctor: deliberate drift remains" >&2; exit 1; fi

propose:
	@printf 'propose PROJECT=%s SOURCE=%s OUTPUT=%s\n' "$(PROJECT)" "$(SOURCE)" "$(OUTPUT)" >> "$(CALL_LOG)"
	@test -n "$(PROJECT)" && test -d "$(SOURCE)" || { echo "fixture propose: PROJECT and SOURCE are required" >&2; exit 2; }
	@printf 'services: {}\nports: {}\n# evidence: static files under %s\n' "$(SOURCE)"

register:
	@printf 'register PROJECT=%s ENTRY=%s\n' "$(PROJECT)" "$(ENTRY)" >> "$(CALL_LOG)"
	@test -n "$(PROJECT)" && test -f "$(ENTRY)" || { echo "fixture register: PROJECT and ENTRY are required" >&2; exit 2; }
	@tmp="$(PROJECTS_FILE).tmp.$$$$"; \
	trap 'rm -f "'"'"$$tmp"'"'"' EXIT HUP INT TERM; \
	awk -v project="$(PROJECT)" '\
	  BEGIN { skip = 0 } \
	  $$0 == "  " project ":" { skip = 1; next } \
	  skip && $$0 ~ /^  [a-z0-9][a-z0-9.-]*:$$/ { skip = 0 } \
	  !skip { print } \
	' "$(PROJECTS_FILE)" > "$$tmp"; \
	printf '\n  %s:\n' "$(PROJECT)" >> "$$tmp"; \
	sed 's/^/    /' "$(ENTRY)" >> "$$tmp"; \
	if $(MAKE) --no-print-directory validate PROJECT="$(PROJECT)" PROJECTS_FILE="$$tmp" CALL_LOG="$(CALL_LOG)"; then \
	  mv "$$tmp" "$(PROJECTS_FILE)"; \
	else \
	  exit 1; \
	fi

reconcile:
	@printf 'reconcile PROJECT=%s\n' "$(PROJECT)" >> "$(CALL_LOG)"
	@test -n "$(PROJECT)" || { echo "fixture reconcile: PROJECT is required" >&2; exit 2; }

preflight:
	@printf 'preflight PROJECT=%s\n' "$(PROJECT)" >> "$(CALL_LOG)"
	@test -n "$(PROJECT)" || { echo "fixture preflight: PROJECT is required" >&2; exit 2; }
	@if [ -e "$(CURDIR)/occupied-port" ]; then echo "fixture preflight: declared port occupied for $(PROJECT)" >&2; exit 1; fi
