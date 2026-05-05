# Cloudflare AI Bot Block Restore Gate Evidence

## Restore-owned context (single source of truth)
- Source owner: `ops/runbooks/site_takedown_20260503/restore.sh` (ZONE=`fafbf95a076d7e8ee984dbd18a62c933`, ACCOUNT=`99deba6554f68cb3544bd9ecfd08ff06`, project=`flapjack-cloud`, hostname=`cloud.flapjack.foo`, zone name=`flapjack.foo`).
- Observation UTC: 2026-05-04T04:53:58Z

## Dashboard path and API endpoint
- dashboard path: Cloudflare Dashboard -> Security -> Settings -> Bot traffic -> Block AI bots.
- API endpoint used for readback: `GET /client/v4/zones/<ZONE>/bot_management`.
- Readback field: `result.ai_bots_protection`.

## Observed state and action
- observed state: `ai_bots_protection = disabled` from API readback.
- action taken: no AI-bot toggle change in this session (read-only gate evidence capture).
- blocker: none from the repo-owned global-key auth path (`success=true`, `HTTP_STATUS:200`).

## Raw evidence file
- cloudflare_ai_block_readback: `cloudflare_ai_block_readback.txt` (same run directory).
- This artifact is the restore gate owner for later launch evidence stages; Stage 5 must append evidence in this same run directory.

## Post-restore re-check commands
1. `dig +short @bailey.ns.cloudflare.com cloud.flapjack.foo`
- Expected success signal: output contains `flapjack-cloud.pages.dev.`

2. `curl -sI https://cloud.flapjack.foo/`
- Expected success signal: HTTP status line indicates `200` (allowing brief propagation delay after restore).

3. Cloudflare AI block gate readback command:
```bash
curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" \
  -H "X-Auth-Email: ${CLOUDFLARE_X_Auth_Email}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/fafbf95a076d7e8ee984dbd18a62c933/bot_management"
```
- Expected success signal: JSON has `"success": true` and `"ai_bots_protection": "block"|"disabled"|"only_on_ad_pages"` plus `HTTP_STATUS:200`.
- Expected permission-failure signal: JSON has `"success": false` with non-empty `errors[]`, or non-200 HTTP status.
