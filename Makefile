CARGO := cargo
NPM := npm

# --- Infra (Rust) ---

.PHONY: infra-build infra-test infra-check

infra-build:
	cd infra && $(CARGO) build

infra-test:
	cd infra && $(CARGO) test

# SQL integration tests require DATABASE_URL pointing to a real Postgres instance.
# Example: DATABASE_URL=postgres://user:pass@localhost/flapjack_test make infra-test-integration
infra-test-integration:
	cd infra && $(CARGO) test -p api --test pg_index_replica_repo_test

infra-check:
	cd infra && $(CARGO) check

# --- Web (SvelteKit) ---

.PHONY: web-install web-dev web-build web-test web-check web-lint web-format web-test-e2e web-lint-e2e

web-install:
	cd web && $(NPM) install

web-dev:
	cd web && $(NPM) run dev

web-build:
	cd web && $(NPM) run build

web-test:
	cd web && $(NPM) test

web-test-e2e:
	cd web && $(NPM) run test:e2e

web-lint-e2e:
	cd web && $(NPM) run lint:e2e

web-check:
	cd web && $(NPM) run check

web-lint:
	cd web && $(NPM) run lint

web-format:
	cd web && $(NPM) run format

# --- All ---

.PHONY: build test check lint

build: infra-build web-build

test: infra-test web-test

check: infra-check web-check

lint: web-lint web-lint-e2e
