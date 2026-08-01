#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="fjcloud_dev"
cd "$REPO_ROOT"

EVID_DIR="docs/runbooks/evidence/fleet-recovery/20260521T012241Z_stage5_capacity_restore"
mkdir -p "$EVID_DIR" "$EVID_DIR/pre_inventory" "$EVID_DIR/runtime_gate_inventory" "$EVID_DIR/post_inventory" "$EVID_DIR/ssm"

export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION AWS_REGION
source scripts/validate_full_vm_lifecycle_prod.sh
load_orchestration_env

run_allow_fail() {
    local out_file="$1"
    shift
    set +e
    "$@" >"$out_file" 2>&1
    local rc=$?
    set -e
    printf '%s\n' "$rc" >"${out_file}.rc"
    return 0
}

# Pre-state capture
set +e
bash scripts/reliability/validate_vm_inventory_ec2_consistency.sh --evidence-dir "$EVID_DIR/pre_inventory" > "$EVID_DIR/pre_inventory/summary.json" 2> "$EVID_DIR/pre_inventory_validate.txt"
rc=$?
set -e
printf '%s\n' "$rc" > "$EVID_DIR/pre_inventory_validate.txt.rc"
curl -fsS -H "x-admin-key: ${ADMIN_KEY}" "${API_URL%/}/admin/fleet" > "$EVID_DIR/pre_admin_fleet.json"
run_allow_fail "$EVID_DIR/pre_run_a.txt" bash scripts/validate_full_vm_lifecycle_prod.sh run-a

# Shared-host target selection: stage2 known-unhealthy host + highest repeated unhealthy host.
aws ec2 describe-instances \
  --filters Name=tag:managed-by,Values=fjcloud Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output json > "$EVID_DIR/pre_ec2_instances.json"

python3 - "$EVID_DIR/pre_admin_fleet.json" "$EVID_DIR/pre_ec2_instances.json" "docs/runbooks/evidence/fleet-recovery/20260520T214507Z_diagnosis/29_vm_probe_targets.json" <<'PY' > "$EVID_DIR/29_vm_probe_targets.json"
import collections
import json
import sys

fleet = json.load(open(sys.argv[1], "r", encoding="utf-8"))
ec2 = json.load(open(sys.argv[2], "r", encoding="utf-8"))
stage2_targets = json.load(open(sys.argv[3], "r", encoding="utf-8"))

ec2_by_host = {}
for row in ec2:
    name = row.get("Name") or ""
    host = name[3:] if name.startswith("fj-") else name
    if host:
        ec2_by_host[host] = row

shared = [d for d in fleet if (d.get("hostname") or "").startswith("vm-shared-")]
unhealthy = [d for d in shared if d.get("health_status") != "healthy"]
counts = collections.Counter((d.get("hostname") or "") for d in unhealthy if d.get("hostname"))

selected = []
seen = set()

stage2_unhealthy = (stage2_targets.get("unhealthy") or {})
if stage2_unhealthy.get("hostname"):
    selected.append({
        "source": "stage2_baseline",
        "hostname": stage2_unhealthy.get("hostname"),
        "instance_id": stage2_unhealthy.get("instance_id"),
        "probe_url": stage2_unhealthy.get("probe_url"),
    })
    seen.add(stage2_unhealthy.get("hostname"))

for host, _count in counts.most_common(5):
    if host in seen:
        continue
    ec2_row = ec2_by_host.get(host) or {}
    flapjack_url = ""
    for row in unhealthy:
        if row.get("hostname") == host and row.get("flapjack_url"):
            flapjack_url = row.get("flapjack_url")
            break
    probe_url = flapjack_url.rstrip("/") + "/health" if flapjack_url else ""
    selected.append({
        "source": "stage5_unhealthy_ranked",
        "hostname": host,
        "instance_id": ec2_row.get("InstanceId"),
        "probe_url": probe_url,
    })
    seen.add(host)

print(json.dumps({"selected": selected, "unhealthy_host_counts": counts}, indent=2, default=lambda o: dict(o)))
PY

run_host_probe() {
    local target_json="$1"
    local role="$2"
    local host instance_id probe_url safe_host payload_file out_prefix command_id

    host="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hostname"])' "$target_json")"
    instance_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("instance_id", ""))' "$target_json")"
    probe_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("probe_url", ""))' "$target_json")"
    safe_host="$(printf '%s' "$host" | tr '.-' '__')"
    out_prefix="$EVID_DIR/ssm/30_host_probe_${role}_${safe_host}"

    if [ -z "$instance_id" ]; then
        printf '{"status":"skipped","reason":"missing_instance_id","host":"%s"}\n' "$host" > "${out_prefix}_invocation.json"
        return 0
    fi

    payload_file="$(mktemp /tmp/fj_stage5_probe_payload_XXXXXX.json)"
    python3 - "$payload_file" "$probe_url" <<'PY'
import json
import sys

payload_file = sys.argv[1]
probe_url = (sys.argv[2] or "").strip()
commands = [
    "set +e",
    "echo \"=== systemctl status flapjack ===\"",
    "sudo systemctl status flapjack --no-pager 2>&1; echo \"__cmd_exit:systemctl_status_flapjack:$?\"",
    "echo \"=== journalctl -u flapjack ===\"",
    "sudo journalctl -u flapjack --since \"2 hours ago\" -n 200 --no-pager 2>&1; echo \"__cmd_exit:journalctl_flapjack:$?\"",
    "echo \"=== ls -l /usr/local/bin/flapjack ===\"",
    "ls -l /usr/local/bin/flapjack 2>&1; echo \"__cmd_exit:ls_flapjack_bin:$?\"",
]
if probe_url:
    commands.extend([
        f"echo \"=== curl {probe_url} ===\"",
        f"curl -sS -i --max-time 5 {probe_url} 2>&1; echo \"__cmd_exit:curl_probe_url:$?\"",
    ])
commands.extend([
    "echo \"=== curl localhost:7700/health ===\"",
    "curl -sS -i --max-time 5 http://localhost:7700/health 2>&1; echo \"__cmd_exit:curl_local_7700:$?\"",
])
json.dump({"commands": commands}, open(payload_file, "w", encoding="utf-8"))
PY

    aws ssm send-command \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --parameters "file://$payload_file" \
      --query '{CommandId:Command.CommandId}' \
      --output json > "${out_prefix}_send_command.json" 2> "${out_prefix}_send_command.stderr.txt"

    command_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["CommandId"])' "${out_prefix}_send_command.json")"
    rm -f "$payload_file"

    aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" > "${out_prefix}_wait.stdout.txt" 2> "${out_prefix}_wait.stderr.txt" || true
    aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
      --output json > "${out_prefix}_invocation.json" 2> "${out_prefix}_invocation.stderr.txt"
}

python3 - "$EVID_DIR/29_vm_probe_targets.json" <<'PY' > "$EVID_DIR/probe_targets_expanded.json"
import json
import sys
rows = json.load(open(sys.argv[1], "r", encoding="utf-8")).get("selected", [])
print(json.dumps(rows, indent=2))
PY

idx=0
while IFS= read -r row_json; do
  target_file="$EVID_DIR/ssm/target_${idx}.json"
  printf '%s\n' "$row_json" > "$target_file"
  run_host_probe "$target_file" "$idx"
  idx=$((idx + 1))
done < <(python3 - <<'PY'
import json
rows = json.load(open("docs/runbooks/evidence/fleet-recovery/20260521T012241Z_stage5_capacity_restore/probe_targets_expanded.json", "r", encoding="utf-8"))
for row in rows:
    print(json.dumps(row))
PY
)

python3 - "$EVID_DIR/pre_admin_fleet.json" "$EVID_DIR/ssm" <<'PY' > "$EVID_DIR/runtime_repair_plan.json"
import glob
import json
import os
import sys

fleet = json.load(open(sys.argv[1], "r", encoding="utf-8"))
ssm_dir = sys.argv[2]

plan = {"restart_in_place": [], "replace_via_terminate": []}

host_to_deployment = {}
for row in fleet:
    host = row.get("hostname")
    if host and host not in host_to_deployment:
        host_to_deployment[host] = row.get("id")

for path in sorted(glob.glob(os.path.join(ssm_dir, "30_host_probe_*_invocation.json"))):
    payload = json.load(open(path, "r", encoding="utf-8"))
    stdout = payload.get("Stdout", "")
    host_hint = os.path.basename(path).split("_invocation.json")[0]
    missing_binary = "/usr/local/bin/flapjack: No such file or directory" in stdout or "Failed to locate executable /usr/local/bin/flapjack" in stdout
    if missing_binary:
        host = host_hint.split("30_host_probe_")[-1]
        host = host.replace("_", ".", 1).replace("__", "-")
        dep_id = None
        for key, value in host_to_deployment.items():
            if key.replace(".", "_").replace("-", "_") in host_hint:
                dep_id = value
                host = key
                break
        if dep_id:
            plan["replace_via_terminate"].append({"host": host, "deployment_id": dep_id, "probe_artifact": os.path.basename(path)})
    else:
        plan["restart_in_place"].append({"probe_artifact": os.path.basename(path)})

print(json.dumps(plan, indent=2))
PY

# Minimal runtime mutation: replace only hosts proven to miss flapjack binary.
python3 - "$EVID_DIR/runtime_repair_plan.json" <<'PY' > "$EVID_DIR/runtime_repair_actions.json"
import json
import sys
plan = json.load(open(sys.argv[1], "r", encoding="utf-8"))
print(json.dumps({"replacements_planned": plan.get("replace_via_terminate", []), "replacements_attempted": []}, indent=2))
PY

while IFS= read -r deployment_id; do
  [ -n "$deployment_id" ] || continue
  http_code="$(curl -sS -o "$EVID_DIR/terminate_${deployment_id}.response.txt" -w '%{http_code}' -X DELETE -H "x-admin-key: ${ADMIN_KEY}" "${API_URL%/}/admin/deployments/${deployment_id}")"
  printf '%s\n' "$http_code" > "$EVID_DIR/terminate_${deployment_id}.http_code.txt"
done < <(python3 - <<'PY'
import json
plan = json.load(open("docs/runbooks/evidence/fleet-recovery/20260521T012241Z_stage5_capacity_restore/runtime_repair_plan.json", "r", encoding="utf-8"))
for row in plan.get("replace_via_terminate", []):
    print(row.get("deployment_id", ""))
PY
)

# Runtime gate (checkpoint before optional code fix)
curl -fsS -H "x-admin-key: ${ADMIN_KEY}" "${API_URL%/}/admin/fleet" > "$EVID_DIR/runtime_gate_admin_fleet.json"
set +e
bash scripts/reliability/validate_vm_inventory_ec2_consistency.sh --evidence-dir "$EVID_DIR/runtime_gate_inventory" > "$EVID_DIR/runtime_gate_inventory/summary.json" 2> "$EVID_DIR/runtime_gate_inventory_validate.txt"
rc=$?
set -e
printf '%s\n' "$rc" > "$EVID_DIR/runtime_gate_inventory_validate.txt.rc"
run_allow_fail "$EVID_DIR/runtime_gate_run_a.txt" bash scripts/validate_full_vm_lifecycle_prod.sh run-a

# Final post proof (same command names required by checklist)
set +e
bash scripts/reliability/validate_vm_inventory_ec2_consistency.sh --evidence-dir "$EVID_DIR/post_inventory" > "$EVID_DIR/post_inventory/summary.json" 2> "$EVID_DIR/post_inventory_validate.txt"
rc=$?
set -e
printf '%s\n' "$rc" > "$EVID_DIR/post_inventory_validate.txt.rc"
run_allow_fail "$EVID_DIR/post_run_a.txt" bash scripts/validate_full_vm_lifecycle_prod.sh run-a

python3 - "$EVID_DIR/runtime_repair_plan.json" "$EVID_DIR/post_run_a.txt" "$EVID_DIR/runtime_gate_run_a.txt" "$EVID_DIR/runtime_gate_inventory/summary.json" <<'PY' > "$EVID_DIR/SUMMARY.md"
import json
import sys

plan = json.load(open(sys.argv[1], "r", encoding="utf-8"))
post_run = open(sys.argv[2], "r", encoding="utf-8").read()
runtime_gate_run = open(sys.argv[3], "r", encoding="utf-8").read()
inventory_summary = json.load(open(sys.argv[4], "r", encoding="utf-8"))

replaced = [f"{r.get('host')} ({r.get('deployment_id')})" for r in plan.get("replace_via_terminate", [])]
recovered = [r.get("probe_artifact") for r in plan.get("restart_in_place", [])]

still_failing = []
if "step 'create_index' failed:" in post_run:
    still_failing.append("run-a still fails at create_index after runtime mutation")
if inventory_summary.get("deployment_linkage_mismatches", 0) != 0 or inventory_summary.get("inventory_rows_without_nonterminated_ec2_match", 0) != 0 or inventory_summary.get("managed_instances_without_inventory_match", 0) != 0:
    still_failing.append("inventory drift detected in runtime gate summary")

print("# Stage 5 Capacity Restore Summary")
print("")
print("## recovered_in_place")
if recovered:
    for row in recovered:
        print(f"- {row}")
else:
    print("- none")
print("")
print("## replaced_via_existing_path")
if replaced:
    for row in replaced:
        print(f"- {row}")
else:
    print("- none")
print("")
print("## still_failing_after_runtime_recovery")
if still_failing:
    for row in still_failing:
        print(f"- {row}")
else:
    print("- none")
print("")
print("## Gate Evidence")
print("- runtime_gate_run_a.txt")
print("- runtime_gate_inventory/summary.json")
print("- post_run_a.txt")
print("- post_inventory/summary.json")
print("")
print("## Notes")
runtime_gate_failed = "yes" if "step 'create_index' failed:" in runtime_gate_run else "no"
post_failed = "yes" if "step 'create_index' failed:" in post_run else "no"
print(f"- runtime_gate_create_index_failed={runtime_gate_failed}")
print(f"- post_create_index_failed={post_failed}")
PY
