# Metering pipeline stall — finding 2026-05-01

**Date:** 2026-05-01 21:09 UTC
**Result:** RED — no `usage_records` rows have been written for ANY tenant on
staging since 2026-04-28 20:46:42 UTC. Three days dark.

## Symptoms

Latest `usage_records` rows for any tenant on staging:

```
        tenant_id        | count |              max
-------------------------+-------+-------------------------------
 stage3_20260424t093459z |  4579 | 2026-04-28 20:46:42.035472+00
 demo-shared-free        |  4151 | 2026-04-28 20:46:42.035472+00
```

Both tenants stopped at the *exact same instant* (`2026-04-28 20:46:42.035472+00`).
That timestamp coincidence indicates a single shared-pipeline failure, not
a per-tenant data-loss event.

## What is alive

- **Flapjack server on `vm-shared-f2b9c8a6.flapjack.foo:7700`** — reachable from laptop and EC2; `/internal/storage` returns 200 with both tenant indexes (27 MB / 31 MB respectively). Indexes are intact.
- **fj-metering-agent on the same VM** — systemd reports `active (running) since Sun 2026-04-26 05:41:41 UTC`. Process PID confirmed via `ps`. `netstat` shows established connections to staging RDS (`10.0.10.94:5432`) and to Flapjack (`44.220.133.5:7700`). `strace` confirms HTTP scrapes are happening (Prometheus-style metrics: `flapjack_search`, `flapjack_*_total{index=...}`).
- **API ingest endpoints** — process is up; `/health` is 200; the broader API is producing `alerts` rows on demand.

## What is dead

- **`usage_records` writes** — no rows for any tenant since Apr 28 20:46:42 UTC.
- **Metering agent journald output** — only systemd start/stop lines are present in `journalctl -u fj-metering-agent`; no application log lines at all since the Apr 26 restart, despite confirmed network activity.
- **API logs for metering ingest** — no entries matching `metering|usage_record|internal/usage` in the last hour of `journalctl -u fjcloud-api`.

## Hypothesis

The agent IS scraping Flapjack's Prometheus endpoint (strace evidence) but
either:
1. Failing to resolve `tenant_id` / `customer_id` from the scraped metrics,
   so it has nothing to write.
2. Failing to authenticate against the API or the DB write path silently.
3. Writing to a different code path that bypasses `usage_records`.

The agent's lack of journald output is itself suspicious — `tracing::error!`
calls reached journald before Apr 26 (we have a cluster of 403 Forbidden
errors from before the Apr 26 restart). After the restart, even errors
appear silenced. This may indicate a logger config drift introduced in the
Apr 26 deploy.

## Why this matters for launch

Per LAUNCH.md launch sentence: "...watch billing accrue (metering agent
scraping, aggregation job crunching, invoices generated)..." If
`usage_records` aren't being written, the entire billing chain
(metering agent → usage_records → aggregation → invoices) is broken on
staging.

This was not on LAUNCH.md's blocker list (which focused on RC, browser
proof, alert delivery, seeder, canaries, and legal). It is now plausibly
a missing blocker. Recommend adding LB-8: "Metering pipeline produces
fresh usage_records on current-main".

LB-5 (seeder closes for tenants A+B+C) is downstream of this. The
seeder gate is lifted (commit `943c4580`), `--provision-only` is in
place (`6d134103`), and tenants B + C are provisioned in DB. But
`usage_records` won't appear for them until the metering pipeline is
unblocked.

## Diagnostics already captured

- staging RDS query showing 2-tenant only results, both stalling at
  `2026-04-28 20:46:42.035472+00`
- `/etc/flapjack/metering-env` exists with required env vars
- `systemctl status` and `ps`/`netstat` confirming agent process state
- `strace` confirming live network activity to RDS and Flapjack

## Next steps for whoever picks this up

1. Run `journalctl -u fj-metering-agent` immediately after a manual
   restart — see if any log lines appear at all (currently zero
   post-restart). If still silent, the binary's tracing config has
   drifted and needs investigation.
2. Add a `tracing::info!` checkpoint at the start of each scrape cycle
   in `infra/metering-agent/src/` — confirm whether the scrape loop is
   running silently or not running.
3. Inspect the tenant_map fetch: `infra/metering-agent/src/tenant_map.rs`
   (assumed) — if the API endpoint changed shape, the agent may be
   getting empty maps and silently writing nothing.
4. Run an integration test that drives the full pipeline end-to-end
   against a mock tenant index — add to the launch RC if missing.

This finding is committed to the tree as evidence; LAUNCH.md STATUS
will note it as a likely missing LB.
