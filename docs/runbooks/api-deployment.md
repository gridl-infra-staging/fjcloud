# API Deployment

> **DEPRECATED**: This runbook describes the legacy manual deploy process (cargo build + SSH).
> The current SSM-based deploy procedure is documented in [`infra-deploy-rollback.md`](infra-deploy-rollback.md).
> Use `ops/scripts/deploy.sh`, `ops/scripts/rollback.sh`, and `ops/scripts/migrate.sh` instead.

## Pre-deployment checklist

- [ ] All tests pass: `cargo test -p api` (Rust) + `npm --prefix web test` (SvelteKit)
- [ ] Migrations are up to date and applied: check `infra/migrations/` for new migration files
- [ ] Environment variables are set (see `docs/env-vars.md`)
- [ ] No breaking API changes without versioning or migration plan
- [ ] Build succeeds: `cargo build --release -p api` + `npm --prefix web run build`

## Deployment steps

### 1. Build

```bash
# Rust API
cd infra
cargo build --release -p api

# SvelteKit web app
cd web
npm run build
```

### 2. Apply database migrations

```bash
# Run pending migrations against production DB
# Migrations are in infra/migrations/ (001-010+)
# Use sqlx-cli or apply manually via psql
sqlx migrate run --source infra/migrations/
```

### 3. Deploy

Deploy the built artifacts to the production server. The Axum API binary is at `target/release/fjcloud-api`. The SvelteKit build output is in `web/build/`.

### 4. Verify

```bash
# Health check
curl -s https://api.flapjack.foo/health

# Quick smoke test
curl -s https://api.flapjack.foo/admin/fleet \
  -H "X-Admin-Key: $ADMIN_KEY"
```

## Rollback procedure

If a deploy introduces a regression:

1. **Immediate**: Revert to the previous binary/build artifacts
2. **Database**: If a migration was applied, run the corresponding down migration (if available). Otherwise, write a compensating migration
3. **Verify**: Run the same smoke tests after rollback
4. **Communicate**: Update status page if customers were affected

## Zero-downtime deployment

The API has graceful shutdown wired in `main.rs`:
- `axum::serve().with_graceful_shutdown()` + SIGINT handler
- In-flight requests are completed before the process exits
- Deploy new version alongside old, then signal old process to shut down

Process:
1. Start new API process on a different port (or behind a load balancer)
2. Verify new process is healthy
3. Switch traffic to new process (update load balancer or reverse proxy)
4. Send SIGINT to old process — it will finish in-flight requests then exit

## Environment variables

See `docs/env-vars.md` for the complete list of required and optional environment variables.
