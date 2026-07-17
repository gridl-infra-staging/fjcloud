# LB-8 fixed — metering pipeline GREEN again

**Date:** 2026-05-01 21:30 UTC
**Result:** GREEN — `usage_records` rows resumed flowing after a stale-key
ops fix on staging Flapjack VM.

## Root cause

`/etc/flapjack/metering-env` on Flapjack VM `vm-shared-f2b9c8a6.flapjack.foo`
(EC2 `i-00a3b28ba4c00433a`) was generated 2026-04-24 10:05 UTC and contained
`INTERNAL_KEY=Z…` (the value of staging SSM
`/fjcloud/staging/internal_auth_token` at that time).

SSM `/fjcloud/staging/internal_auth_token` was rotated on 2026-04-29 04:21 EDT
(2026-04-29 08:21 UTC) to `oyUuTRkE…`. The fjcloud API process picked up the
new value (per its env-from-SSM regen path on deploy/restart). The metering
agent's `/etc/flapjack/metering-env` was NOT regenerated, so the agent kept
sending the old key.

Result: every `GET /internal/tenant-map` and `GET /internal/storage` from
the agent returned HTTP 401, the agent's tenant-map cache was empty, and
no `usage_records` rows were written.

The agent's pre-Apr-26-restart logs explicitly showed `403 Forbidden` then
`401 Unauthorized` errors. After the Apr 26 5:41 restart, the new tracing
config (or a code change in the binary build) silenced those errors —
which is why the journal showed *no entries at all* for 5 days despite
the auth failures continuing. That silencing is itself a regression
worth filing separately ("agent must log auth failures, not just succeed
silently").

## Verification

Probe before fix (against the agent's actual env):
```
curl -H "x-internal-key: $INTERNAL_KEY" "$TENANT_MAP_URL"
HTTP 401
```

Fix:
```
NEW_KEY=$(aws ssm get-parameter --region us-east-1 \
  --name /fjcloud/staging/internal_auth_token \
  --with-decryption --query Parameter.Value --output text)
sed -i "s|^INTERNAL_KEY=.*|INTERNAL_KEY=$NEW_KEY|" /etc/flapjack/metering-env
systemctl restart fj-metering-agent
```

Verification post-fix (within 90 seconds of restart):
```
SELECT tenant_id, count(*), MAX(recorded_at) FROM usage_records
WHERE recorded_at > now() - interval '10 minutes'
GROUP BY tenant_id ORDER BY MAX(recorded_at) DESC;

        tenant_id        | count |              max
-------------------------+-------+-------------------------------
 demo-shared-free        |     3 | 2026-05-01 21:27:47.763525+00
 stage3_20260424t093459z |     3 | 2026-05-01 21:27:47.763525+00
```

Rows for both tenants now flowing. Pipeline GREEN end-to-end.

## What this proves

- The metering agent → API → DB path is intact in code.
- The chain was broken purely by stale env config, not a code bug.
- Tenant attribution still works (tenant_id, customer_id correct in rows).
- The metering scrape interval is producing rows on schedule (3 rows in the
  ~80 seconds since restart, consistent with `SCRAPE_INTERVAL_SECS=60`
  default + `STORAGE_POLL_INTERVAL_SECS=300` default).

## Durable fix (recommended, separate session)

The runtime config drift between SSM and `/etc/flapjack/metering-env` is the
class of bug here. Recommend one of:

1. **Regen-on-restart hook** in the metering-agent systemd unit:
   `ExecStartPre=/usr/local/bin/generate_metering_env.sh staging`
   so a simple `systemctl restart` brings it back in sync. The script
   already exists in repo as `ops/scripts/lib/generate_ssm_env.sh`.

2. **Drift alert** — a probe that compares SSM `/fjcloud/staging/internal_auth_token`
   against the value the agent is using (via `/internal/tenant-map` 401 detection),
   and pages on drift > 1 hour.

3. **SSM rotation runbook update** — `docs/runbooks/secret_rotation.md` should
   include a step "after rotating internal_auth_token, regen metering-env on
   every Flapjack VM and restart fj-metering-agent" so future rotations don't
   silently break metering for days.

(3) is cheapest. Recommend doing it now while context is fresh.

## Closes (proposed) LB-8

This fix unblocks LB-5 downstream evidence (tenants A + B + C
usage_records). Tenant A is already producing rows. Tenants B and C still
need to be re-provisioned onto a real Flapjack VM (currently placed on a
fake VM record with `flapjack_url=https://api.flapjack.foo`). That's a
separate small step — captured in a follow-up bundle.
