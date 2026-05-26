# Flapjack Cloud (fjcloud)

Managed hosting platform for the flapjack open-source search engine.
Drop-in Algolia replacement for cost-sensitive ecommerce — 10x cost reduction, 99% feature parity.

## What This Is

**→ [Project Roadmap](ROADMAP.md)**
**→ [Local Launch Readiness](docs/LOCAL_LAUNCH_READINESS.md)**

- **flapjack** — open-source search engine (separate repo: `flapjack_dev`)
- **fjcloud** — managed cloud hosting layer: multi-tenant infrastructure, billing, web portal, admin tools
- **Target customers** — Shopify/WooCommerce merchants paying Algolia $50-500/month
- **Pricing** — usage-based pricing with plan-specific minimums. No feature-gated subscription tiers
- **URL** — cloud.flapjack.foo

## Core Architectural Principle

**The fjcloud web portal is the unified cloud console.** It is the single abstraction layer
between human customers and all their flapjack servers scattered across regions worldwide.
A customer's project may span any number of servers in any number of regions — the console
makes it feel like one single thing. The customer's mental model should be as clean and simple
as using open-source flapjack on one local server.

The flapjack engine has its own built-in dashboard, but that is **only for open-source
single-server usage**. It talks to exactly one server instance. The fjcloud web portal must
**never** proxy, embed, or link to the engine dashboard. Every feature page in the cloud
console is a native Svelte implementation that talks to the fjcloud API, which handles routing
to the correct flapjack instances behind the scenes.

This is the core purpose and challenge of the entire fjcloud project.

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────────┐
│  SvelteKit Web  │────▶│  Axum API    │────▶│  flapjack engine │
│  Portal (:5173) │     │  Server      │     │  (per-VM)        │
└─────────────────┘     │  (:3001)     │     └──────────────────┘
                        │              │
                        │  S3 Listener │     ┌──────────────────┐
┌─────────────────┐     │  (:3002)     │────▶│  Garage (S3)     │
│  S3 Clients     │────▶│              │     └──────────────────┘
└─────────────────┘     │  ┌─────────┐ │     ┌──────────────────┐
                        │  │Scheduler│ │────▶│  PostgreSQL 16   │
                        │  │Health   │ │     └──────────────────┘
                        │  │Repl Orch│ │
                        │  └─────────┘ │     ┌──────────────────┐
                        └──────────────┘────▶│  Stripe API      │
                                             └──────────────────┘
┌─────────────────┐
│ Metering Agent  │  (sidecar on each VM — usage capture + aggregation)
└─────────────────┘
```

The API server exposes two listeners: REST API on `:3001` and S3-compatible object storage on `:3002`.
Storage provisioning (buckets, access keys) is handled by `StorageService` via the REST API.
S3 data-plane operations (PUT/GET/DELETE objects) use SigV4 authentication and proxy to Garage.
Background services (scheduler, health monitor, replication orchestrator, region failover)
run as tokio tasks inside the API server process.

## Tech Stack

- **Backend** — Rust, Axum, SQLx, tokio
- **Frontend** — SvelteKit 5, Tailwind CSS v4, TypeScript
- **Database** — PostgreSQL 16
- **Billing** — Stripe (checkout, subscriptions, webhooks, usage-based invoicing)
- **Provisioning** — AWS EC2, Hetzner Cloud, GCP, OCI, bare-metal SSH
- **Object Storage** — Garage (S3-compatible, cold tier + Flapjack Cloud Storage)
- **Email** — AWS SES
- **Testing** — cargo test, vitest, Playwright

## Repo Structure

```
fjcloud_dev/
├── infra/                    # Rust workspace
│   ├── api/                  # Main API server
│   │   ├── src/
│   │   │   ├── routes/       # HTTP handlers (indexes/, admin/, auth, billing, ...)
│   │   │   ├── services/     # Business logic (scheduler/, cold_tier/, migration/, storage/, ...)
│   │   │   ├── provisioner/  # VM providers (aws, hetzner, gcp, oci, ssh, multi)
│   │   │   └── dns/          # DNS management
│   │   └── tests/            # Integration tests
│   ├── billing/              # Plan registry + pricing engine
│   ├── pricing-calculator/   # Public provider comparison engine (`compare_all`, presets, freshness)
│   ├── metering-agent/       # Usage capture sidecar
│   ├── aggregation-job/      # Batch billing aggregation
│   └── migrations/           # PostgreSQL schema migrations
├── web/                      # SvelteKit web portal
│   └── src/
│       ├── lib/              # API client, admin client, utilities
│       └── routes/
│           ├── dashboard/    # Customer portal (indexes, billing, settings, ...)
│           └── admin/        # Admin panel (fleet, customers, migrations, ...)
├── ops/                      # Infrastructure (Terraform, Packer, deploy scripts)
│   └── garage/               # Garage object storage ops tooling (S3 bridge backend)
│       ├── scripts/          # install-garage.sh, init-cluster.sh, health-check.sh
│       ├── garage.toml.template
│       ├── garage.service
│       └── sysctl-garage.conf
├── scripts/                  # Integration test scripts, CI helpers, seed_local.sh
├── docs/                     # Runbooks, env vars, security, launch docs
├── docker-compose.yml        # Local dev stack (Postgres, API, web)
├── .env.local.example        # Environment template for local development
└── tests/                    # Load tests (k6)
```

## Related Repos

| Repo | Purpose | Visibility |
|------|---------|------------|
| `flapjack_dev` | OSS search engine (core indexing, search, settings, analytics) | Public |
| `fjcloud_dev` | This repo — SaaS infra + cloud web portal | Private (dev) |
| `fjcloud` | Production mirror | Private |

## Pre-push validation

Run `bash scripts/local-ci.sh` before pushing to `main`. It mirrors every
gate the staging `deploy-staging` job depends on (rust-lint, web-lint,
web-test, check-sizes, secret-scan, migration-test) in parallel — fast mode
finishes in ~20 seconds vs. ~15 minutes for staging CI. Use `--full` to
also run `cargo test --workspace`, `--gate <name>` to run a single gate.

## Key Files

- `ROADMAP.md` — complete feature inventory with implementation status
- `scripts/local-ci.sh` — local mirror of the staging deploy-staging gate (run before every push)
- `docs/LOCAL_QUICKSTART.md` — one-command local demo startup and walkthrough
- `docs/LOCAL_LAUNCH_READINESS.md` — local-only launch validation scope, pass bars, and evidence expectations
- `docs/LOCAL_DEV.md` — local stack setup and troubleshooting
- `docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md` — exact local-only signoff run order
- `scripts/api-dev.sh` — local API launcher that exports `.env.local` correctly
- `CLAUDE.md` / `AGENTS.md` — AI assistant instructions
- `BROWSER_TESTING_STANDARDS_2.md` — E2E test standards
- `docs/env-vars.md` — all environment variables
- `docs/runbooks/pricing-audit.md` — pricing calculator maintenance and freshness gate workflow
- `docs/runbooks/` — operational procedures

## Current Status (April 2026)

Core API, portal, billing, provisioning, local-dev, and admin-support flows are implemented.
P0 local simulation is complete and staging infrastructure is deployed with public DNS/HTTPS/SES
evidence. Remaining pre-launch work is concentrated in credentialed staging billing evidence,
live credential validation, AWS live-E2E spend/cleanup guardrails, and any additional
cross-browser parity required by launch signoff.

Use `docs/LOCAL_LAUNCH_READINESS.md` for the local-only validation bar and `ROADMAP.md`
for the complete feature-by-feature breakdown.

<!-- stage7_provenance_sync_marker_2026_05_25T2230Z -->
