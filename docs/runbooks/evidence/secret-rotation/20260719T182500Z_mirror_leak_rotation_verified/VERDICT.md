# Mirror-leak credential rotation — VERIFIED ROTATED (read-only probe 2026-07-19 ~14:25 EDT)

Probe (root creds, read-only metadata, us-east-1):
- SSM /fjcloud/prod/db_password: Version 2, LastModified 2026-07-17T16:35:10-04:00
- SSM /fjcloud/staging/db_password: Version 2, LastModified 2026-07-17T16:19:23-04:00
- EC2 key pair fjcloud-api-prod: CreateTime 2026-07-17T20:39:01Z (recreated)
- EC2 key pair fjcloud-api-staging: CreateTime 2026-07-17T20:29:46Z (recreated)
- RDS fjcloud-prod / fjcloud-staging: available (created 2026-05-14 / 2026-02-26 — not wiped)

Verdict: the credentials named LIVE by
docs/runbooks/evidence/mirror-leak-scan/20260716T233251Z_credential_scan/ were ROTATED
2026-07-17 evening (after the 20260717T173005Z live-state snapshot — that ordering explains the
stale docs). The GAP_SPEC escalations in 20260717T000002Z_mirror_leak_stage4/ are DISCHARGED at
the issuing layer.

RESIDUAL (open, owned by the parked prod fleet-rebuild track): instances launched BEFORE
2026-07-17T20:29Z may still carry the old SSH public key in authorized_keys; full closure of the
"EC2 authorization-path absence" clause lands with the fleet rebuild. Old-password live-rejection
test not run (root session, metadata only); SSM Version 2 is the issuing-layer proof.
