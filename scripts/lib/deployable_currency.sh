#!/usr/bin/env bash
# Classify whether a deployed SHA is stale in ways that can actually change the
# API release artifact.

print_unknown_deployable_currency() {
  echo "deployable_drift=unknown"
  echo "doc_only_ahead=unknown"
}

is_missing_currency_ref() {
  local repo="$1"
  local ref="$2"

  if [[ -z "$ref" ]] || [[ "$ref" == "unknown" ]] || [[ "$ref" == "local-dev" ]]; then
    return 0
  fi
  ! git -C "$repo" cat-file -e "${ref}^{commit}" 2>/dev/null
}

is_deployable_currency_path() {
  local path="$1"

  # This allowlist is the single source of truth because deployable currency is
  # defined by the release artifact owners in .github/workflows/ci.yml, not by
  # commit messages or broad repo drift.
  case "$path" in
    infra/api/src/* | \
    infra/billing/src/* | \
    infra/metering-agent/src/* | \
    infra/aggregation-job/src/* | \
    infra/retention-job/src/* | \
    infra/pricing-calculator/src/* | \
    infra/Cargo.toml | \
    infra/Cargo.lock | \
    infra/migrations/* | \
    ops/scripts/migrate.sh | \
    ops/scripts/lib/generate_ssm_env.sh | \
    ops/systemd/fj-metering-agent.service)
      return 0
      ;;
    infra/*/Cargo.toml)
      [[ "$path" != */*/*/Cargo.toml ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

is_doc_only_currency_path() {
  local path="$1"

  # Exclusions stay filename-level only. Commit-subject heuristics are not used:
  # subject text cannot prove what artifact inputs changed.
  case "$path" in
    *.md | docs/* | docs/** | chats/* | chats/** | chatting/* | chatting/**)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

classify_deployable_currency() {
  local repo="$1"
  local deployed_sha="$2"
  local target_sha="$3"

  # scripts/canary/deploy_currency_check.sh remains a mirror-liveness concern.
  # This library answers only whether repo paths between two dev SHAs affect the
  # deployable API artifact inputs.
  if is_missing_currency_ref "$repo" "$deployed_sha" || \
     is_missing_currency_ref "$repo" "$target_sha"; then
    print_unknown_deployable_currency
    return 0
  fi

  local ahead_count
  if ! ahead_count="$(git -C "$repo" rev-list --count "${deployed_sha}..${target_sha}" 2>/dev/null)"; then
    print_unknown_deployable_currency
    return 0
  fi

  if [[ "$ahead_count" == "0" ]]; then
    echo "deployable_drift=false"
    echo "doc_only_ahead=false"
    return 0
  fi

  local changed_paths
  if ! changed_paths="$(git -C "$repo" diff --name-only "${deployed_sha}..${target_sha}" 2>/dev/null)"; then
    print_unknown_deployable_currency
    return 0
  fi

  local has_deployable="false"
  local has_non_doc="false"
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if is_deployable_currency_path "$path"; then
      has_deployable="true"
    fi
    if ! is_doc_only_currency_path "$path"; then
      has_non_doc="true"
    fi
  done <<< "$changed_paths"

  echo "deployable_drift=$has_deployable"
  if [[ "$has_deployable" == "false" && "$has_non_doc" == "false" ]]; then
    echo "doc_only_ahead=true"
  else
    echo "doc_only_ahead=false"
  fi
}

deployable_currency_json_value() {
  case "$1" in
    true|false) printf '%s\n' "$1" ;;
    *) python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" ;;
  esac
}

unknown_deployable_currency_probe_result() {
  local detail="$1"

  printf 'unknown|unknown|unknown|%s\n' "$detail"
}

serialize_deployable_currency_verdict_json() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import re
import sys

source_sha, dev_sha, deployable_drift, doc_only_ahead = sys.argv[1:5]
sha_re = re.compile(r"^[0-9a-f]{40}$")
if not sha_re.fullmatch(source_sha):
    raise SystemExit("source_sha must be lowercase 40-hex")
if not sha_re.fullmatch(dev_sha):
    raise SystemExit("dev_sha must be lowercase 40-hex")
if deployable_drift not in ("true", "false"):
    raise SystemExit("deployable_drift must be a JSON boolean")
if doc_only_ahead not in ("true", "false"):
    raise SystemExit("doc_only_ahead must be a JSON boolean")
deployable = deployable_drift == "true"
doc_only = doc_only_ahead == "true"
if deployable and doc_only:
    raise SystemExit("deployable_drift and doc_only_ahead cannot both be true")

payload = {
    "schema_version": "1",
    "source_sha": source_sha,
    "dev_sha": dev_sha,
    "deployable_drift": deployable,
    "doc_only_ahead": doc_only,
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

deployable_currency_verdict_fields_from_file() {
  local verdict_file="$1"

  if [ -z "$verdict_file" ]; then
    printf 'FJCLOUD_DEPLOYABLE_CURRENCY_JSON must name a verdict file.\n' >&2
    return 1
  fi
  if [ ! -e "$verdict_file" ]; then
    printf 'Deployable-currency verdict file does not exist: %s\n' "$verdict_file" >&2
    return 1
  fi
  if [ ! -f "$verdict_file" ]; then
    printf 'Deployable-currency verdict path is not a file: %s\n' "$verdict_file" >&2
    return 1
  fi
  if [ ! -r "$verdict_file" ]; then
    printf 'Deployable-currency verdict file is not readable: %s\n' "$verdict_file" >&2
    return 1
  fi

  python3 - "$verdict_file" <<'PY'
import json
import re
import sys

verdict_file = sys.argv[1]
required_keys = {
    "schema_version",
    "source_sha",
    "dev_sha",
    "deployable_drift",
    "doc_only_ahead",
}
sha_re = re.compile(r"^[0-9a-f]{40}$")

def reject_duplicate_keys(pairs):
    payload = {}
    duplicate_keys = []
    for key, value in pairs:
        if key in payload:
            duplicate_keys.append(key)
        payload[key] = value
    if duplicate_keys:
        keys = ",".join(sorted(set(duplicate_keys)))
        raise ValueError(f"duplicate keys: {keys}")
    return payload

try:
    with open(verdict_file, encoding="utf-8") as handle:
        payload = json.load(handle, object_pairs_hook=reject_duplicate_keys)
except Exception as exc:
    raise SystemExit(f"Deployable-currency verdict JSON could not be parsed: {exc}")

if not isinstance(payload, dict):
    raise SystemExit("Deployable-currency verdict must be a JSON object.")

actual_keys = set(payload)
if actual_keys != required_keys:
    missing = sorted(required_keys - actual_keys)
    extra = sorted(actual_keys - required_keys)
    detail = []
    if missing:
        detail.append("missing keys: " + ",".join(missing))
    if extra:
        detail.append("extra keys: " + ",".join(extra))
    raise SystemExit("Deployable-currency verdict has invalid keys: " + "; ".join(detail))

if payload["schema_version"] != "1":
    raise SystemExit('Deployable-currency verdict schema_version must be string "1".')

source_sha = payload["source_sha"]
dev_sha = payload["dev_sha"]
if not isinstance(source_sha, str) or not sha_re.fullmatch(source_sha):
    raise SystemExit("Deployable-currency verdict source_sha must be lowercase 40-hex.")
if not isinstance(dev_sha, str) or not sha_re.fullmatch(dev_sha):
    raise SystemExit("Deployable-currency verdict dev_sha must be lowercase 40-hex.")

deployable_drift = payload["deployable_drift"]
doc_only_ahead = payload["doc_only_ahead"]
if type(deployable_drift) is not bool:
    raise SystemExit("Deployable-currency verdict deployable_drift must be a JSON boolean.")
if type(doc_only_ahead) is not bool:
    raise SystemExit("Deployable-currency verdict doc_only_ahead must be a JSON boolean.")
if deployable_drift and doc_only_ahead:
    raise SystemExit("Deployable-currency verdict cannot set deployable_drift and doc_only_ahead both true.")

print(
    "|".join(
        (
            source_sha,
            dev_sha,
            str(deployable_drift).lower(),
            str(doc_only_ahead).lower(),
        )
    )
)
PY
}

staging_deployable_currency_fields_from_status_json() {
  python3 - "$1" <<'PY' || true
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("unknown|unknown|unknown")
    raise SystemExit(0)

staging = payload.get("envs", {}).get("staging", {})

def normalize(value):
    if type(value) is bool:
        return str(value).lower()
    if isinstance(value, str) and value:
        return value
    return "unknown"

fields = ("dev_sha", "deployable_drift", "doc_only_ahead")
print("|".join(normalize(staging.get(field)) for field in fields))
PY
}

probe_staging_deployable_currency() {
  local deploy_status_script="$1"
  local deploy_status_output="" deploy_status_exit=0
  local injection_file="${FJCLOUD_DEPLOYABLE_CURRENCY_JSON:-}"
  local injection_source_sha="${FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA:-}"

  # 2026-07 postmortem: the in-VPC rehearsal runner extracts a git archive onto
  # the VM, so it has no .git directory and may not have git installed. The
  # frozen source SHA and deployable-currency verdict are dev-repo facts captured
  # before transport. If an injected verdict is invalid, failing closed here is
  # required; falling back to ambient VM Git would reintroduce the archive-only
  # failure and could classify an unrelated checkout.
  if [ -n "$injection_file" ] || [ -n "$injection_source_sha" ]; then
    if [ -z "$injection_file" ] || [ -z "$injection_source_sha" ]; then
      unknown_deployable_currency_probe_result \
        "FJCLOUD_DEPLOYABLE_CURRENCY_JSON and FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA must be configured together."
      return 1
    fi

    local verdict_fields verdict_source_sha verdict_triple
    if ! verdict_fields="$(deployable_currency_verdict_fields_from_file "$injection_file" 2>&1)"; then
      unknown_deployable_currency_probe_result "$verdict_fields"
      return 1
    fi

    verdict_source_sha="${verdict_fields%%|*}"
    verdict_triple="${verdict_fields#*|}"
    if [ "$verdict_source_sha" != "$injection_source_sha" ]; then
      unknown_deployable_currency_probe_result \
        "Deployable-currency verdict source_sha does not match FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA."
      return 1
    fi

    printf '%s\n' "$verdict_triple"
    return 0
  fi

  set +e
  deploy_status_output="$(bash "$deploy_status_script" --json --env staging 2>&1)"
  deploy_status_exit=$?
  set -e
  if [ "$deploy_status_exit" -ne 0 ]; then
    if [ "$deploy_status_exit" -eq 127 ]; then
      unknown_deployable_currency_probe_result \
        "Deployable-currency probe failed before live rehearsal: deploy_status dependency unavailable."
    else
      unknown_deployable_currency_probe_result \
        "Deployable-currency probe failed before live rehearsal: deploy_status exited with status ${deploy_status_exit}."
    fi
    return 1
  fi

  staging_deployable_currency_fields_from_status_json "$deploy_status_output"
}
