# Flapjack Cloud (fjcloud)

Managed hosting platform for the flapjack open-source search engine.
Drop-in Algolia replacement for cost-sensitive ecommerce.

## Start Here

`PROJECT_OVERVIEW.md` owns the stable mission, scope, and non-goals for this
repo. Use this README as the entrypoint and key-file map.

Core references:

- `PROJECT_OVERVIEW.md` - mission, scope, non-goals, and planning-doc ownership
- `LAUNCH.md` - launch sentence, blocker list, and launch verdict owner
- `ROADMAP.md` - broad open-work and shipped-feature ledger
- `docs/DIRMAP.md` - directory-level summaries for docs ownership
- `docs/LOCAL_DEV.md` and `docs/runbooks/local-dev.md` - local setup, strict signoff, and troubleshooting
- `docs/LOCAL_QUICKSTART.md` - one-command local demo startup and walkthrough

## Tech Stack

- **Backend** — Rust, Axum, SQLx, tokio
- **Frontend** — SvelteKit 5, Tailwind CSS v4, TypeScript
- **Database** — PostgreSQL 16
- **Billing** — Stripe (checkout, subscriptions, webhooks, usage-based invoicing)
- **Provisioning** — AWS EC2, Hetzner Cloud, GCP, OCI, bare-metal SSH
- **Object Storage** — Garage (S3-compatible, cold tier + Flapjack Cloud Storage)
- **Email** — AWS SES
- **Testing** — cargo test, vitest, Playwright

## Related Repos

| Repo           | Purpose                                                        | Visibility    |
| -------------- | -------------------------------------------------------------- | ------------- |
| `flapjack_dev` | OSS search engine (core indexing, search, settings, analytics) | Public        |
| `fjcloud_dev`  | This repo — SaaS infra + cloud web portal                      | Private (dev) |
| `fjcloud`      | Production mirror                                              | Private       |

## Pre-push validation

Run `bash scripts/local-ci.sh` before pushing to `main`. It mirrors every
gate the staging `deploy-staging` job depends on (rust-lint, web-lint,
web-test, check-sizes, secret-scan, migration-test) in parallel — fast mode
finishes in ~20 seconds vs. ~15 minutes for staging CI. Use `--full` to
also run `cargo test --workspace`, `--gate <name>` to run a single gate.

## Key Files

- `scripts/local-ci.sh` — local mirror of the staging deploy-staging gate (run before every push)
- `infra/retention-job` / `fjcloud-retention-job` — batch job that enumerates soft-deleted customers through `CustomerRepo::list_deleted_before_cutoff` and calls `POST /admin/customers/:id/hard-erase`; operator detail lives in `docs/runbooks/account_data_policy.md`
- `docs/LOCAL_DEV.md` — local stack setup and troubleshooting
- `docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md` — exact local-only signoff run order
- `scripts/api-dev.sh` — local API launcher that exports `.env.local` correctly
- `CLAUDE.md` / `AGENTS.md` — AI assistant instructions
- `BROWSER_TESTING_STANDARDS_2.md` — E2E test standards
- `docs/env-vars.md` — all environment variables
- `docs/runbooks/pricing-audit.md` — pricing calculator maintenance and freshness gate workflow
- `docs/runbooks/` — operational procedures

<!-- stage7_provenance_sync_marker_2026_05_25T2230Z -->
