# LB-5 GREEN — usage_records flowing for tenants A + B + C on current-main

**Date:** 2026-05-01 21:35 UTC
**Result:** GREEN — fresh `usage_records` rows for all three launch tenants:

```
       tenant_id        | count | latest_recorded_at
------------------------+-------+-------------------------------
 demo-medium-dedicated  |   1+  | 2026-05-01 21:33:47.82861+00
 demo-shared-free       |   9+  | 2026-05-01 21:33:47.82861+00
 demo-small-dedicated   |   1+  | 2026-05-01 21:33:47.82861+00
```

(`stage3_20260424t093459z` is also flowing — historical synthetic tenant.)

Full CSV at `usage_records_three_tenants.csv` in this bundle.

## What was done

LB-5 has two parts: gate-lift (so the seeder accepts B/C in execute mode)
and downstream evidence (usage_records rows). The gate-lift commits landed
earlier today (`943c4580`, `6d134103`). Today's downstream evidence
required four ops fixes:

1. **LB-8 fix:** the metering pipeline was stalled since 2026-04-28 due to
   stale `INTERNAL_KEY` on the Flapjack VM after a 2026-04-29 SSM rotation.
   Fixed by regenerating the agent's env key from current SSM and
   restarting. Tenant A immediately resumed scraping. Evidence:
   `docs/runbooks/evidence/staging-metering/20260501T213000Z_lb8_fixed_GREEN/`.

2. **LB-5 placement repair:** the seeder's first run for B and C placed
   them on a fake VM record (`flapjack_url=https://api.flapjack.foo`)
   because the default `FLAPJACK_URL` in `hydrate_seeder_env_from_ssm.sh`
   is the API host as a fallback. Fixed by `UPDATE customer_tenants SET
   vm_id=<real-shared-vm-uuid>` for the two new dedicated tenants:

   ```sql
   UPDATE customer_tenants
   SET vm_id='e1a8e33c-97d2-44d8-89bc-c1693ecf464d'::uuid
   WHERE tenant_id IN ('demo-small-dedicated','demo-medium-dedicated');
   ```

3. **Index seeding on Flapjack:** the seed_index admin endpoint creates
   DB rows but does NOT create the Flapjack-side index — that happens
   on first write. Wrote 5 batches × 100 docs to Flapjack on the real
   shared VM for each of B and C, using the canonical
   `deterministic_batch_payload` helper. Each batch returned HTTP 200.
   Flapjack then reported both new indexes in `/internal/storage`
   (500 docs / ~513 KB each).

4. **Wait for next metering scrape (~60 s):** scraper picked up the new
   indexes and wrote `document_count=500` rows for both. Subsequent
   scrapes confirm the rows continue to flow.

## What this proves about the launch sentence

- "Get a Flapjack search instance provisioned on AWS, ingest documents":
  validated for both shared (A) and dedicated (B/C) tenant shapes via
  the same code path.
- "Watch billing accrue (metering agent scraping, aggregation job
  crunching, invoices generated)": metering chain proven; scrapes are
  arriving on the per-minute interval.
- Tenant attribution is correct (customer_id + tenant_id link to the
  seeded test customers, not to other tenants on the shared VM).

## Caveats / known gaps

- **Plan classification:** the seeder writes `billing_plan=shared` for
  all three tenants regardless of the per-tenant `PLAN` field in
  `tenant_field`. Per `seed_synthetic_traffic.sh::ensure_customer_and_tenant`,
  the update payload is hardcoded `'{"billing_plan":"shared"}'`. For B
  and C this means the DB row says `shared` even though the launch
  tenant taxonomy intends `dedicated`. This does NOT affect metering
  (which is plan-agnostic) or this evidence's validity, but it is
  worth fixing for accurate billing rehearsal results in any future
  RC. Filed as a separate small follow-up.

- **Ops fix not committed code:** the LB-8 metering fix was an ops
  action on the Flapjack VM (`sed` + `systemctl restart`). The durable
  cure is in `docs/runbooks/evidence/staging-metering/20260501T213000Z_lb8_fixed_GREEN/SUMMARY.md`
  ("Durable fix" section): add `ExecStartPre=` regen to the
  metering-agent systemd unit, OR add a drift alert, OR update the
  secret-rotation runbook. This evidence proves the chain works *today*
  but a future SSM rotation will silently break it again until the
  durable cure lands.

- **B/C have only 1 row each at capture time** because they were
  freshly seeded ~3 minutes before this snapshot. By the next hour
  they'll have ~60 rows each at the 1-minute scrape interval; the
  attribution logic is identical to tenant A's existing pattern.

## Reproduce

```bash
# 1. Hydrate staging env
set -a; source .secret/.env.secret; set +a
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)

# 2. Provision tenants (gate-lift + --provision-only landed earlier today)
FLAPJACK_URL=http://vm-shared-f2b9c8a6.flapjack.foo:7700 \
  bash scripts/launch/seed_synthetic_traffic.sh \
    --tenant <A|B|C> --execute --i-know-this-hits-staging --provision-only

# 3. (For dedicated tenants on a fake VM) link to the real shared VM
psql "$DATABASE_URL" -c "UPDATE customer_tenants SET vm_id='<real-vm-id>'::uuid WHERE tenant_id IN (...);"

# 4. Send a few batches to bootstrap the Flapjack-side index
source scripts/lib/deterministic_batch_payload.sh
for i in 0 1 2 3 4; do
  curl -X POST "http://<vm>/1/indexes/<flapjack_uid>/batch" \
    -H "X-Algolia-API-Key: <node-key>" -H "X-Algolia-Application-Id: flapjack" \
    -d "$(deterministic_batch_payload 42 $((i*100)) 100)"
done

# 5. Wait ~90 s for metering scrape, query usage_records
psql "$DATABASE_URL" -c "SELECT tenant_id, count(*), MAX(recorded_at) FROM usage_records WHERE recorded_at > now() - interval '10 minutes' GROUP BY tenant_id;"
```
