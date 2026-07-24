#!/usr/bin/env bash
# Contract coverage for the VM autorepair operator docs and successor UI spec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])


def read_relative(path: str) -> str:
    full_path = repo_root / path
    if not full_path.is_file():
        raise AssertionError(f"{path} is missing")
    return full_path.read_text(encoding="utf-8")


def assert_contains(path: str, needles: list[str]) -> None:
    text = read_relative(path)
    missing = [needle for needle in needles if needle not in text]
    if missing:
        rendered = "\n".join(f"- {needle}" for needle in missing)
        raise AssertionError(f"{path} missing required contract text:\n{rendered}")


runbook_needles = [
    "VmAutorepairReconciler::observe_vm",
    "handle_host_dead",
    "replacement_enabled",
    "Live",
    "EngineDown",
    "HostDead",
    "Indeterminate",
    "FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS",
    "concrete-dead evidence",
    "FJCLOUD_VM_AUTOREPAIR_ENABLED",
    "kill_switch_disabled",
    "replacement_cooldown",
    "region_dampening",
    "concurrent_replacement_cap",
    "spend_ceiling",
    "detected_dead",
    "replacement_refused",
    "replacement_provisioning",
    "replacement_booted",
    "tenants_replaced",
    "replacement_completed",
    "replacement_failed",
    "docs/runbooks/evidence/vm-autorepair/",
    "disabled-detection evidence",
    "jul23_11am_12_vm_autorepair_enabled_replacement_proof",
]

env_needles = [
    "`FJCLOUD_VM_AUTOREPAIR_ENABLED`",
    "absent or `false`",
    "Values must be `true` or `false`.",
    "`FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS` | No | `60`",
    "`FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS` | No | `900`",
    "`FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COOLDOWN_SECONDS` | No | `1800`",
    "`FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_WINDOW_SECONDS` | No | `900`",
    "`FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_LIMIT` | No | `2`",
    "`FJCLOUD_VM_AUTOREPAIR_CONCURRENT_REPLACEMENT_CAP` | No | `1`",
    "`FJCLOUD_VM_AUTOREPAIR_SPEND_WINDOW_SECONDS` | No | `86400`",
    "`FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COST_CENTS` | No | `1000`",
    "`FJCLOUD_VM_AUTOREPAIR_SPEND_CEILING_CENTS` | No | `0`",
]

detail_needles = [
    "VM autorepair lifecycle timeline",
    "GET /admin/vms/:id/lifecycle-events",
    "web/src/lib/admin-client.ts",
    "web/src/routes/admin/fleet/[id]/+page.server.ts",
    "web/src/routes/admin/fleet/[id]/+page.svelte",
    "created_at`/`id",
    "VmLifecycleEventType",
    "detail.guardrail",
    "known VM with no lifecycle events returns an empty array",
    "unknown VM returns 404",
    "unavailable rather than a false-empty timeline",
]

fleet_needles = [
    "VM autorepair lifecycle timeline",
    "docs/screen_specs/admin_vm_detail.md",
]

coverage_needles = [
    "`/admin/fleet/[id]`",
    "VM autorepair lifecycle timeline contract",
]

dirmap_needles = [
    "vm_autorepair.md",
    "canonical operator runbook",
]

assert_contains("docs/runbooks/vm_autorepair.md", runbook_needles)
assert_contains("docs/env-vars.md", env_needles)
assert_contains("docs/screen_specs/admin_vm_detail.md", detail_needles)
assert_contains("docs/screen_specs/admin_fleet.md", fleet_needles)
assert_contains("docs/screen_specs/coverage.md", coverage_needles)
assert_contains("docs/runbooks/DIRMAP.md", dirmap_needles)

print("OK: VM autorepair docs contract is current")
PY
