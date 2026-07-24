# VM Autorepair Runbook

## Purpose

This is the canonical operator runbook for VM autorepair detection and
replacement admission. It documents current behavior only: autonomous
replacement is still disabled in local, staging, and production until
`jul23_11am_12_vm_autorepair_enabled_replacement_proof` enables and proves the
end-to-end replacement path. Do not use this runbook as enablement authority for
staging or production.

## Current Rollout State

Staging and prod ship with autonomous replacement disabled. The default and
current safe value is `FJCLOUD_VM_AUTOREPAIR_ENABLED=false`; when the variable is
absent it also parses as `false`. This stage does not add AWS mutation, tenant
replacement proof, runtime config rollout, or SSM pointer changes.

## Trigger Semantics

`VmAutorepairReconciler::observe_vm` in
`infra/api/src/services/vm_autorepair.rs` owns the per-VM observation decision.
The reconciliation loop still observes VMs while replacement is disabled.

Liveness outcomes are admitted as follows:

| Liveness | Replacement behavior |
| --- | --- |
| `Live` | Clears the in-memory dead-observation state. No replacement is attempted. |
| `EngineDown` | Clears the in-memory dead-observation state. No replacement is attempted. |
| `Indeterminate` | No replacement is attempted. If there is concrete-dead evidence, the first observed timestamp is retained for the host-dead window. |
| `HostDead` | The only path into `handle_host_dead`, which records the dead-host lifecycle trail and then consults `replacement_enabled` plus the guardrails before any replacement admission. |

`replacement_enabled` reads the kill switch through
`parse_vm_autorepair_enabled_from_env`. Invalid kill-switch values fail closed:
the reconciler logs the parse error and refuses replacement as disabled.

## Liveness Meanings

`infra/api/src/services/vm_autorepair/rules.rs` owns the liveness classifier.

- `Live`: provider status is `Running` and the engine health check is healthy.
- `EngineDown`: provider status is `Running` and the engine health check is
  unhealthy or unreachable.
- `HostDead`: the provider reports the VM missing, stopped, or terminated; the
  engine is not healthy; concrete-dead evidence has been observed continuously
  for at least `FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS` seconds.
- `Indeterminate`: the provider VM id is unavailable, provider lookup/status is
  inconclusive, the provider reports pending/unknown, the provider-dead evidence
  has not yet satisfied the dead window, or the engine is still healthy while the
  provider appears dead.

The default dead window is `900` seconds. `HostDead` requires concrete-dead
evidence from the provider side and an unhealthy or unreachable engine. An engine
outage alone remains `EngineDown`, not a replacement signal.

## Guardrails

`VmAutorepairSettings::default` and `docs/env-vars.md` own the default values.

| Guardrail | Variable | Default | Runtime meaning |
| --- | --- | --- | --- |
| Kill switch | `FJCLOUD_VM_AUTOREPAIR_ENABLED` | `false` | Disabled or invalid values refuse replacement with `kill_switch_disabled`. |
| Check interval | `FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS` | `60` | Reconciliation interval. |
| Host-dead window | `FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS` | `900` | Continuous concrete-dead evidence window before `HostDead`. |
| Replacement cooldown | `FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COOLDOWN_SECONDS` | `1800` | Refuses new admission while the latest `replacement_booted` remains inside the cooldown window. |
| Region dampening window | `FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_WINDOW_SECONDS` | `900` | Lookback window for regional dead-host detections. |
| Region dampening limit | `FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_LIMIT` | `2` | Refuses replacement with `region_dampening` when detections in the window exceed this limit. |
| Concurrent replacement cap | `FJCLOUD_VM_AUTOREPAIR_CONCURRENT_REPLACEMENT_CAP` | `1` | Refuses replacement with `concurrent_replacement_cap` when unfinished replacements meet or exceed this cap. |
| Spend window | `FJCLOUD_VM_AUTOREPAIR_SPEND_WINDOW_SECONDS` | `86400` | Lookback window for committed replacement spend. |
| Replacement cost | `FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COST_CENTS` | `1000` | Planned cents added to projected spend for each admitted replacement attempt. |
| Spend ceiling | `FJCLOUD_VM_AUTOREPAIR_SPEND_CEILING_CENTS` | `0` | Default `0` fail-closes enabled replacements with `spend_ceiling` until a positive ceiling is configured. |

## Lifecycle Trail

`VmLifecycleEventRepo` persists lifecycle events, and
`GET /admin/vms/:id/lifecycle-events` exposes the trail for a known VM. The
repository returns events in chronological order by `created_at` and then `id`.

Event types are serialized from `VmLifecycleEventType`:

- `detected_dead`
- `replacement_refused`
- `replacement_provisioning`
- `replacement_booted`
- `tenants_replaced`
- `replacement_completed`
- `replacement_failed`

`replacement_refused.detail.guardrail` values are:

- `kill_switch_disabled`
- `replacement_cooldown`
- `region_dampening`
- `concurrent_replacement_cap`
- `spend_ceiling`

While replacement is disabled, a dead-host incident should record
`detected_dead` followed by `replacement_refused` with
`detail.guardrail=kill_switch_disabled`. Repeated observations with the same
guardrail do not append duplicate refusal rows unless a fresh incident is being
recorded.

## Incident Disable Procedure

1. Set or leave `FJCLOUD_VM_AUTOREPAIR_ENABLED=false` in the existing
   environment-management path for the target environment.
2. Restart or redeploy the target environment through its normal environment
   management path so the API process reloads the value.
3. For the next dead-host incident, verify
   `GET /admin/vms/:id/lifecycle-events` includes `replacement_refused` with
   `detail.guardrail` set to `kill_switch_disabled`.

Do not add staging or prod enablement instructions here. Enablement belongs to
`jul23_11am_12_vm_autorepair_enabled_replacement_proof`.

## Evidence

Stage 4 evidence under `docs/runbooks/evidence/vm-autorepair/` is
disabled-detection evidence only. It proves the disabled detection/refusal shape
when current and complete; it is not proof that autonomous replacement is enabled
or that provisioning, tenant movement, retirement, and teardown are safe.
