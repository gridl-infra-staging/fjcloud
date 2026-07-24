#!/usr/bin/env bash
# Shared rollback compatibility proof for Algolia import persisted truth.

# Run the fail-closed compatibility proof and emit one typed JSON result.
# Validate candidate metadata before booting the artifact and running protocol fixtures.
# Return a typed JSON error for every rejected argument or failed compatibility check.
# TODO: Document rollback_contract_probe.
# TODO: Document rollback_contract_probe.
rollback_contract_probe() {
  local candidate_artifact="" database_copy="" candidate_manifest="" expected_served_sha=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --candidate-artifact)
        candidate_artifact="${2:-}"
        shift 2
        ;;
      --database-copy)
        database_copy="${2:-}"
        shift 2
        ;;
      --candidate-manifest)
        candidate_manifest="${2:-}"
        shift 2
        ;;
      --expected-served-sha)
        expected_served_sha="${2:-}"
        shift 2
        ;;
      *)
        rollback_contract_json "error" "unknown_argument" "unknown contract-probe argument: $1"
        return 64
        ;;
    esac
  done

  rollback_require_absolute "candidate_artifact" "$candidate_artifact" || return $?
  rollback_require_absolute "database_copy" "$database_copy" || return $?
  rollback_require_absolute "candidate_manifest" "$candidate_manifest" || return $?
  rollback_require_nonempty "expected_served_sha" "$expected_served_sha" || return $?
  [[ -e "$candidate_artifact" ]] || { rollback_contract_json "error" "missing_artifact" "candidate artifact not found"; return 66; }
  [[ -f "$database_copy" ]] || { rollback_contract_json "error" "missing_database_copy" "database copy not found"; return 66; }
  [[ -f "$candidate_manifest" ]] || { rollback_contract_json "error" "missing_manifest" "candidate manifest not found"; return 66; }
  jq -e 'type == "object"' "$candidate_manifest" >/dev/null || { rollback_contract_json "error" "invalid_manifest" "candidate manifest must be a JSON object"; return 65; }
  [[ "$expected_served_sha" =~ ^[0-9a-f]{40}$ ]] || {
    rollback_contract_json "error" "invalid_expected_sha" "expected served SHA must be 40 lowercase hexadecimal characters"
    return 64
  }

  rollback_manifest_fresh_enough "$candidate_manifest" || return $?
  rollback_require_hash_command || return $?
  rollback_verify_components "$candidate_manifest" "$candidate_artifact" || return $?

  local epoch
  epoch=$(rollback_manifest_value "$candidate_manifest" '.rollback_epoch')
  case "$epoch" in
    pre_admission)
      rollback_probe_pre_admission "$candidate_manifest" "$expected_served_sha" || return $?
      ;;
    migration_aware_required)
      rollback_verify_floors "$candidate_manifest" || return $?
      rollback_verify_required_features "$candidate_manifest" || return $?
      rollback_verify_job_phase_contract "$candidate_manifest" || return $?
      rollback_verify_ack_outage_contract "$candidate_manifest" || return $?
      rollback_verify_protocol_fixture_manifest "$candidate_manifest" || return $?
      ;;
    *)
      rollback_contract_json "error" "invalid_epoch" "rollback epoch must be pre_admission or migration_aware_required"
      return 65
      ;;
  esac

  local before_hash after_hash
  before_hash=$(rollback_file_sha256 "$database_copy")
  rollback_probe_candidate_runtime \
    "$candidate_artifact" \
    "$database_copy" \
    "$candidate_manifest" \
    "$expected_served_sha" \
    "$epoch" || return $?
  after_hash=$(rollback_file_sha256 "$database_copy")
  if [[ "$before_hash" != "$after_hash" ]]; then
    rollback_contract_json "error" "schema_mutated_snapshot" "candidate schema probe changed the database copy"
    return 70
  fi

  if [[ "$epoch" == "pre_admission" ]]; then
    rollback_contract_json "ok" "legacy_safe_mirror" "pre-admission rollback uses the frozen legacy safe mirror"
  else
    rollback_contract_json "ok" "contract_green" "candidate rollback contract proof passed"
  fi
}

rollback_probe_pre_admission() {
  local manifest="$1" expected_served_sha="$2"
  local legacy_mirror manifest_mirror manifest_dev frozen_mirror
  legacy_mirror=$(rollback_manifest_value "$manifest" '.legacy_safe_mirror_sha')
  manifest_mirror=$(rollback_manifest_value "$manifest" '.mirror_sha')
  manifest_dev=$(rollback_manifest_value "$manifest" '.dev_sha')
  frozen_mirror="${ROLLBACK_FROZEN_LEGACY_SAFE_MIRROR_SHA:-}"
  if [[ ! "$frozen_mirror" =~ ^[0-9a-f]{40}$ || -z "$legacy_mirror" || "$legacy_mirror" == "null" ]]; then
    rollback_contract_json "error" "missing_legacy_safe_mirror" "pre-admission rollback requires the frozen legacy safe mirror"
    return 65
  fi
  if [[ "$legacy_mirror" != "$frozen_mirror" || "$manifest_mirror" != "$frozen_mirror" ]]; then
    rollback_contract_json "error" "wrong_legacy_safe_mirror" "candidate is not the frozen legacy safe mirror"
    return 65
  fi
  if [[ "$manifest_dev" != "$expected_served_sha" ]]; then
    rollback_contract_json "error" "wrong_dev_sha" "legacy candidate dev SHA does not match expected SHA"
    return 65
  fi
}

# Reject release contracts whose time-bound proof window is absent or expired.
rollback_manifest_fresh_enough() {
  local manifest="$1"
  local generated_at max_age now
  generated_at=$(jq -r '.generated_at_epoch // empty' "$manifest")
  max_age=$(jq -r '.max_manifest_age_seconds // empty' "$manifest")
  [[ "$generated_at" =~ ^[0-9]+$ && "$max_age" =~ ^[1-9][0-9]*$ ]] || {
    rollback_contract_json "error" "invalid_manifest_freshness" "manifest freshness fields must be integer seconds"
    return 65
  }
  now=$(date +%s)
  if (( generated_at > now )); then
    rollback_contract_json "error" "invalid_manifest_freshness" "candidate manifest cannot be dated in the future"
    return 65
  fi
  if (( now - generated_at > max_age )); then
    rollback_contract_json "error" "stale_manifest" "candidate manifest is stale"
    return 65
  fi
}

# Prove that the candidate can open the minimum retained schema and protocol.
rollback_verify_floors() {
  local manifest="$1"
  local schema_floor required_schema protocol_floor required_protocol
  schema_floor=$(jq -r '.schema_floor // empty' "$manifest")
  required_schema=$(jq -r '.required_schema_floor // empty' "$manifest")
  protocol_floor=$(jq -r '.protocol_floor // empty' "$manifest")
  required_protocol=$(jq -r '.required_protocol_floor // empty' "$manifest")
  for value in "$schema_floor" "$required_schema" "$protocol_floor" "$required_protocol"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
      rollback_contract_json "error" "invalid_floor" "schema and protocol floors must be integers"
      return 65
    }
  done
  if (( schema_floor < required_schema )); then
    rollback_contract_json "error" "schema_floor_too_low" "candidate schema floor is below required floor"
    return 65
  fi
  if (( protocol_floor < required_protocol )); then
    rollback_contract_json "error" "protocol_floor_too_low" "candidate protocol floor is below required floor"
    return 65
  fi
}

# Bind every swapped executable to its release-contract digest.
rollback_verify_components() {
  local manifest="$1" artifact="$2"
  local missing component rel_path expected actual full_path
  missing=$(jq -r '
    ["fjcloud-api","fjcloud-aggregation-job","fjcloud-retention-job"] as $required
    | (.components // {}) as $components
    | [$required[] | select($components[.] == null)]
    | join(",")
  ' "$manifest")
  if [[ -n "$missing" ]]; then
    rollback_contract_json "error" "missing_component_digest" "candidate manifest lacks required component digest(s): $missing"
    return 65
  fi
  while IFS=$'\t' read -r component rel_path expected; do
    [[ -n "$component" ]] || continue
    [[ -n "$expected" && "$expected" != "null" ]] || {
      rollback_contract_json "error" "missing_component_digest" "candidate component digest missing: $component"
      return 65
    }
    [[ "$rel_path" != /* && "$rel_path" != *".."* ]] || {
      rollback_contract_json "error" "invalid_component_path" "component path must stay inside the candidate artifact"
      return 65
    }
    full_path="${artifact%/}/${rel_path}"
    [[ -f "$full_path" ]] || {
      rollback_contract_json "error" "missing_component" "candidate component missing: $component"
      return 66
    }
    actual="sha256:$(rollback_file_sha256 "$full_path")"
    if [[ "$actual" != "$expected" ]]; then
      rollback_contract_json "error" "wrong_component_digest" "candidate component digest mismatch: $component"
      return 65
    fi
  done < <(jq -r '.components // {} | to_entries[] | [.key, (.value.path // .key), .value.sha256] | @tsv' "$manifest")
}

rollback_verify_required_features() {
  local manifest="$1"
  local missing required
  required=$(rollback_required_features_json)
  missing=$(jq -r --argjson required "$required" '
    $required as $required
    | (.features // []) as $features
    | [$required[] | select(. as $feature | $features | index($feature) | not)]
    | join(",")
  ' "$manifest")
  if [[ -n "$missing" ]]; then
    rollback_contract_json "error" "missing_protocol_feature" "candidate manifest lacks required protocol feature(s): $missing"
    return 65
  fi
}

rollback_verify_job_phase_contract() {
  local manifest="$1"
  local missing phases
  phases=$(rollback_job_phases_json)
  missing=$(jq -r --argjson phases "$phases" '
    $phases as $phases
    | (.job_phase_contract // {}) as $contract
    | [$phases[] | select($contract[.] != "safe")]
    | join(",")
  ' "$manifest")
  if [[ -n "$missing" ]]; then
    rollback_contract_json "error" "missing_job_phase_contract" "candidate does not prove every persisted job phase: $missing"
    return 65
  fi
}

rollback_verify_ack_outage_contract() {
  local manifest="$1"
  if [[ "$(jq -r '.ack_outage_safe // false' "$manifest")" != "true" ]]; then
    rollback_contract_json "error" "ack_outage_unproven" "candidate does not prove ACK outage safety"
    return 65
  fi
}

rollback_verify_protocol_fixture_manifest() {
  local manifest="$1"
  local missing invalid required canonical
  required=$(rollback_required_features_json)
  canonical=$(rollback_protocol_fixtures_json)
  missing=$(jq -r --argjson required "$required" '
    $required as $required
    | (.protocol_fixtures // []) as $fixtures
    | [$required[] | select(. as $feature | [$fixtures[].feature] | index($feature) | not)]
    | join(",")
  ' "$manifest")
  if [[ -n "$missing" ]]; then
    rollback_contract_json "error" "missing_protocol_fixture" "candidate manifest lacks known-answer fixture(s): $missing"
    return 65
  fi

  invalid=$(jq -r '
    [(.protocol_fixtures // [])[]
      | select(
          (.feature | type != "string")
          or ((.method // "") | IN("GET", "POST") | not)
          or ((.url // "") | type != "string")
          or ((.expected_status // 0) | type != "number")
          or (has("expected_body") | not)
        )
      | .feature // "unknown"]
    | join(",")
  ' "$manifest")
  if [[ -n "$invalid" ]]; then
    rollback_contract_json "error" "invalid_protocol_fixture" "candidate manifest has invalid known-answer fixture(s): $invalid"
    return 65
  fi
  if ! jq -e --argjson canonical "$canonical" \
    '[.protocol_fixtures[] | del(.url)] == $canonical' "$manifest" >/dev/null; then
    rollback_contract_json "error" "invalid_protocol_fixture" "candidate manifest changed the canonical known-answer protocol contract"
    return 65
  fi

  local version_url state_url version_origin state_origin fixture_path fixture_url fixture_origin
  version_url=$(rollback_manifest_value "$manifest" '.served_version_url')
  state_url=$(rollback_manifest_value "$manifest" '.served_state_url')
  rollback_require_loopback_url "$version_url" || return $?
  rollback_require_loopback_url "$state_url" || return $?
  version_origin=$(rollback_loopback_origin "$version_url") || {
    rollback_contract_json "error" "candidate_port_missing" "candidate proof URLs must include an explicit loopback port"
    return 65
  }
  state_origin=$(rollback_loopback_origin "$state_url") || {
    rollback_contract_json "error" "candidate_port_missing" "candidate proof URLs must include an explicit loopback port"
    return 65
  }
  if [[ "$version_origin" != "$state_origin" ]]; then
    rollback_contract_json "error" "candidate_origin_mismatch" "candidate proof URLs must share one loopback origin"
    return 65
  fi
  while IFS=$'\t' read -r fixture_path fixture_url; do
    rollback_require_loopback_url "$fixture_url" || return $?
    fixture_origin=$(rollback_loopback_origin "$fixture_url") || {
      rollback_contract_json "error" "candidate_port_missing" "candidate proof URLs must include an explicit loopback port"
      return 65
    }
    if [[ "$fixture_origin" != "$version_origin" ]]; then
      rollback_contract_json "error" "candidate_origin_mismatch" "protocol fixtures must target the artifact-bound candidate origin"
      return 65
    fi
    if [[ "$fixture_url" != "http://${version_origin}${fixture_path}" ]]; then
      rollback_contract_json "error" "invalid_protocol_fixture" "protocol fixture URL does not match its canonical path"
      return 65
    fi
  done < <(jq -r '.protocol_fixtures[] | [.path, .url] | @tsv' "$manifest")
}

rollback_required_features_json() {
  jq -nc '["algolia_import_get", "algolia_import_list", "algolia_import_reconcile", "algolia_import_ack", "algolia_import_scrub"]'
}

rollback_job_phases_json() {
  jq -nc '["queued", "validating_source", "copying_configuration", "copying_documents", "verifying", "promoting", "cancelling", "cancelled", "resuming", "completed", "completed_with_warnings", "failed", "interrupted"]'
}

rollback_protocol_fixtures_json() {
  jq -nc '[
    {feature: "algolia_import_get", method: "GET", path: "/internal/algolia-import/jobs/fixture", expected_status: 200, expected_body: {contract: "algolia_import_get", result: "safe"}},
    {feature: "algolia_import_list", method: "GET", path: "/internal/algolia-import/jobs", expected_status: 200, expected_body: {contract: "algolia_import_list", result: "safe"}},
    {feature: "algolia_import_reconcile", method: "POST", path: "/internal/algolia-import/reconcile", expected_status: 200, request_body: {job_id: "fixture", phase: "queued"}, expected_body: {contract: "algolia_import_reconcile", phase: "queued", result: "safe"}},
    {feature: "algolia_import_ack", method: "POST", path: "/internal/algolia-import/ack", expected_status: 200, repeat: 2, request_body: {job_id: "fixture"}, expected_body: {contract: "algolia_import_ack", result: "safe"}},
    {feature: "algolia_import_scrub", method: "POST", path: "/internal/algolia-import/scrub", expected_status: 200, request_body: {job_id: "fixture"}, expected_body: {contract: "algolia_import_scrub", result: "safe"}}
  ]'
}

rollback_write_release_manifest() {
  local output_path="$1" dev_sha="$2" mirror_sha="$3" artifact="$4"
  [[ "$dev_sha" =~ ^[0-9a-f]{40}$ && "$mirror_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: rollback release manifest SHAs must be 40 lowercase hexadecimal characters" >&2
    return 64
  }
  local api_digest aggregation_digest retention_digest features phases protocol_fixtures
  for component in fjcloud-api fjcloud-aggregation-job fjcloud-retention-job; do
    [[ -f "${artifact%/}/${component}" ]] || {
      echo "ERROR: rollback release component missing: $component" >&2
      return 66
    }
  done
  api_digest="sha256:$(rollback_file_sha256 "${artifact%/}/fjcloud-api")"
  aggregation_digest="sha256:$(rollback_file_sha256 "${artifact%/}/fjcloud-aggregation-job")"
  retention_digest="sha256:$(rollback_file_sha256 "${artifact%/}/fjcloud-retention-job")"
  features=$(rollback_required_features_json)
  phases=$(rollback_job_phases_json)
  protocol_fixtures=$(rollback_protocol_fixtures_json)

  jq -n \
    --arg dev_sha "$dev_sha" \
    --arg mirror_sha "$mirror_sha" \
    --arg api_digest "$api_digest" \
    --arg aggregation_digest "$aggregation_digest" \
    --arg retention_digest "$retention_digest" \
    --argjson features "$features" \
    --argjson phases "$phases" \
    --argjson protocol_fixtures "$protocol_fixtures" \
    '{
      dev_sha: $dev_sha,
      mirror_sha: $mirror_sha,
      schema_floor: 56,
      protocol_floor: 1,
      served_state_path: "/internal/algolia-import/rollback-state",
      features: $features,
      ack_outage_safe: true,
      job_phase_contract: (reduce $phases[] as $phase ({}; .[$phase] = "safe")),
      components: {
        "fjcloud-api": {path: "fjcloud-api", sha256: $api_digest},
        "fjcloud-aggregation-job": {path: "fjcloud-aggregation-job", sha256: $aggregation_digest},
        "fjcloud-retention-job": {path: "fjcloud-retention-job", sha256: $retention_digest}
      },
      protocol_fixtures: $protocol_fixtures
    }' > "$output_path"
}

rollback_probe_candidate_runtime() {
  local artifact="$1" database_copy="$2" manifest="$3" expected_sha="$4" epoch="$5"
  rollback_require_runtime_commands || return $?
  if ! pg_restore --list "$database_copy" >/dev/null 2>&1; then
    rollback_contract_json "error" "invalid_database_archive" "database copy must be a readable PostgreSQL snapshot archive"
    return 65
  fi

  ROLLBACK_PROOF_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-rollback-proof.XXXXXX") || {
    rollback_contract_json "error" "proof_workspace_failed" "could not create isolated proof workspace"
    return 73
  }
  ROLLBACK_DATABASE_DIR="$ROLLBACK_PROOF_ROOT/postgres"
  ROLLBACK_DATABASE_SOCKET_DIR="$ROLLBACK_PROOF_ROOT/socket"
  ROLLBACK_CANDIDATE_LOG="$ROLLBACK_PROOF_ROOT/candidate.log"
  ROLLBACK_DATABASE_PORT=$(rollback_free_loopback_port) || {
    rollback_cleanup_candidate_runtime
    rollback_contract_json "error" "proof_port_failed" "could not allocate an isolated PostgreSQL port"
    return 69
  }
  ROLLBACK_CANDIDATE_PID=""
  ROLLBACK_POSTGRES_STARTED=false

  mkdir -p "$ROLLBACK_DATABASE_DIR" "$ROLLBACK_DATABASE_SOCKET_DIR"
  rollback_prepare_proof_ownership || {
    rollback_cleanup_candidate_runtime
    rollback_contract_json "error" "proof_workspace_failed" "could not prepare the isolated proof workspace"
    return 73
  }
  rollback_restore_postgres_snapshot "$database_copy" || {
    rollback_cleanup_candidate_runtime
    rollback_contract_json "error" "database_restore_failed" "could not restore the snapshot into isolated PostgreSQL"
    return 70
  }

  local schema_before schema_after status=0
  schema_before=$(rollback_schema_hash) || {
    rollback_cleanup_candidate_runtime
    rollback_contract_json "error" "schema_probe_failed" "could not read the restored schema before candidate startup"
    return 70
  }
  rollback_start_artifact_candidate "$artifact" "$manifest" || {
    status=$?
    rollback_cleanup_candidate_runtime
    return "$status"
  }
  rollback_wait_for_candidate "$manifest" || status=$?
  if [[ "$status" -eq 0 ]]; then
    rollback_verify_served_identity "$manifest" "$expected_sha" || status=$?
  fi
  if [[ "$status" -eq 0 && "$epoch" == "migration_aware_required" ]]; then
    rollback_verify_served_state "$manifest" || status=$?
  fi
  if [[ "$status" -eq 0 && "$epoch" == "migration_aware_required" ]]; then
    rollback_verify_protocol_fixtures "$manifest" || status=$?
  fi
  schema_after=$(rollback_schema_hash) || {
    if [[ "$status" -eq 0 ]]; then
      rollback_contract_json "error" "schema_probe_failed" "could not read the restored schema after candidate startup"
      status=70
    fi
  }
  if [[ "$status" -eq 0 && "$schema_before" != "$schema_after" ]]; then
    rollback_contract_json "error" "schema_mutated_snapshot" "candidate startup changed the restored database schema"
    status=70
  fi
  rollback_cleanup_candidate_runtime
  return "$status"
}

rollback_require_runtime_commands() {
  local command
  for command in curl jq mktemp python3 pg_restore initdb pg_ctl createdb pg_dump; do
    if ! command -v "$command" >/dev/null 2>&1; then
      rollback_contract_json "error" "missing_probe_dependency" "rollback proof requires command: $command"
      return 69
    fi
  done
  rollback_require_hash_command
}

rollback_require_hash_command() {
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    rollback_contract_json "error" "missing_probe_dependency" "rollback proof requires command: sha256sum or shasum"
    return 69
  fi
}

rollback_prepare_proof_ownership() {
  if [[ "$(id -u)" -eq 0 ]]; then
    id "${ROLLBACK_PROOF_USER:-fjcloud}" >/dev/null 2>&1 || return 1
    chown -R "${ROLLBACK_PROOF_USER:-fjcloud}:${ROLLBACK_PROOF_GROUP:-fjcloud}" "$ROLLBACK_PROOF_ROOT"
  fi
}

rollback_pg_command() {
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${ROLLBACK_PROOF_USER:-fjcloud}" -- "$@"
  else
    "$@"
  fi
}

rollback_restore_postgres_snapshot() {
  local database_copy="$1"
  rollback_pg_command initdb \
    -D "$ROLLBACK_DATABASE_DIR" \
    --auth=trust \
    --no-locale \
    --encoding=UTF8 >/dev/null || return 1
  rollback_pg_command pg_ctl \
    -D "$ROLLBACK_DATABASE_DIR" \
    -o "-h 127.0.0.1 -p $ROLLBACK_DATABASE_PORT -k $ROLLBACK_DATABASE_SOCKET_DIR" \
    -w start >/dev/null || return 1
  ROLLBACK_POSTGRES_STARTED=true
  rollback_pg_command createdb \
    -h 127.0.0.1 \
    -p "$ROLLBACK_DATABASE_PORT" \
    rollback_contract >/dev/null || return 1
  rollback_pg_command pg_restore \
    --exit-on-error \
    --no-owner \
    --no-privileges \
    -h 127.0.0.1 \
    -p "$ROLLBACK_DATABASE_PORT" \
    -d rollback_contract \
    "$database_copy" >/dev/null || return 1
  ROLLBACK_DATABASE_URL="postgresql://127.0.0.1:${ROLLBACK_DATABASE_PORT}/rollback_contract"
}

rollback_schema_hash() {
  rollback_pg_command pg_dump \
    --schema-only \
    --no-owner \
    --no-privileges \
    "$ROLLBACK_DATABASE_URL" \
    | rollback_stream_sha256
}

rollback_start_artifact_candidate() {
  local artifact="$1" manifest="$2"
  local component_path candidate_api candidate_exec origin port s3_port
  component_path=$(jq -r '.components["fjcloud-api"].path // "fjcloud-api"' "$manifest")
  candidate_api="${artifact%/}/${component_path}"
  [[ -x "$candidate_api" ]] || {
    rollback_contract_json "error" "candidate_not_executable" "artifact-bound candidate API is not executable"
    return 66
  }
  local version_url
  version_url=$(rollback_manifest_value "$manifest" '.served_version_url')
  rollback_require_loopback_url "$version_url" || return $?
  origin=$(rollback_loopback_origin "$version_url") || {
    rollback_contract_json "error" "candidate_port_missing" "candidate proof URLs must include an explicit loopback port"
    return 65
  }
  port="${origin##*:}"
  s3_port=$(rollback_free_loopback_port) || {
    rollback_contract_json "error" "proof_port_failed" "could not allocate candidate listener ports"
    return 69
  }

  rollback_load_candidate_environment || return $?
  candidate_exec="$candidate_api"
  if [[ "$(id -u)" -eq 0 ]]; then
    candidate_exec="$ROLLBACK_PROOF_ROOT/fjcloud-api"
    install \
      -o "${ROLLBACK_PROOF_USER:-fjcloud}" \
      -g "${ROLLBACK_PROOF_GROUP:-fjcloud}" \
      -m 0500 \
      "$candidate_api" \
      "$candidate_exec"
    if ! cmp -s "$candidate_api" "$candidate_exec"; then
      rollback_contract_json "error" "candidate_copy_mismatch" "service-user candidate copy differs from the verified release component"
      return 70
    fi
    runuser -u "${ROLLBACK_PROOF_USER:-fjcloud}" -- env \
      DATABASE_URL="$ROLLBACK_DATABASE_URL" \
      LISTEN_ADDR="127.0.0.1:${port}" \
      S3_LISTEN_ADDR="127.0.0.1:${s3_port}" \
      "$candidate_exec" >"$ROLLBACK_CANDIDATE_LOG" 2>&1 &
  else
    DATABASE_URL="$ROLLBACK_DATABASE_URL" \
      LISTEN_ADDR="127.0.0.1:${port}" \
      S3_LISTEN_ADDR="127.0.0.1:${s3_port}" \
      "$candidate_exec" >"$ROLLBACK_CANDIDATE_LOG" 2>&1 &
  fi
  ROLLBACK_CANDIDATE_PID=$!
}

rollback_load_candidate_environment() {
  local env_file="${ROLLBACK_CANDIDATE_ENV_FILE:-}"
  [[ -z "$env_file" ]] && return 0
  [[ -r "$env_file" ]] || {
    rollback_contract_json "error" "candidate_environment_unreadable" "candidate environment file is not readable"
    return 66
  }
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      rollback_contract_json "error" "candidate_environment_invalid" "candidate environment contains an invalid variable name"
      return 65
    }
    export "$key=$value"
  done < "$env_file"
}

rollback_wait_for_candidate() {
  local manifest="$1" url
  url=$(rollback_manifest_value "$manifest" '.served_version_url')
  local remaining_attempts=150
  while (( remaining_attempts > 0 )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$ROLLBACK_CANDIDATE_PID" 2>/dev/null; then
      break
    fi
    sleep 0.2
    remaining_attempts=$((remaining_attempts - 1))
  done
  rollback_contract_json "error" "candidate_start_failed" "artifact-bound candidate did not become ready on loopback"
  return 69
}

rollback_verify_protocol_fixtures() {
  local manifest="$1" fixture feature repeat
  while IFS= read -r fixture; do
    feature=$(jq -r '.feature' <<<"$fixture")
    repeat=$(jq -r '.repeat // 1' <<<"$fixture")
    while (( repeat > 0 )); do
      rollback_run_known_answer_fixture "$feature" "$fixture" || return $?
      repeat=$((repeat - 1))
    done
  done < <(jq -c '.protocol_fixtures[]' "$manifest")
  rollback_verify_job_phase_fixtures "$manifest"
}

rollback_verify_job_phase_fixtures() {
  local manifest="$1" reconcile_url phase fixture
  reconcile_url=$(jq -r '.protocol_fixtures[] | select(.feature == "algolia_import_reconcile") | .url' "$manifest")
  while IFS= read -r phase; do
    fixture=$(jq -nc \
      --arg url "$reconcile_url" \
      --arg phase "$phase" \
      '{
        method: "POST",
        url: $url,
        expected_status: 200,
        request_body: {job_id: "fixture", phase: $phase},
        expected_body: {contract: "algolia_import_reconcile", phase: $phase, result: "safe"}
      }')
    rollback_run_known_answer_fixture "algolia_import_reconcile:$phase" "$fixture" || return $?
  done < <(rollback_job_phases_json | jq -r '.[]')
}

rollback_run_known_answer_fixture() {
  local feature="$1" fixture="$2"
  local method url expected_status request_body expected_body response_file actual_status
  method=$(jq -r '.method' <<<"$fixture")
  url=$(jq -r '.url' <<<"$fixture")
  expected_status=$(jq -r '.expected_status' <<<"$fixture")
  request_body=$(jq -c '.request_body // {}' <<<"$fixture")
  expected_body=$(jq -c '.expected_body' <<<"$fixture")
  response_file="$ROLLBACK_PROOF_ROOT/protocol-response.json"
  rollback_require_loopback_url "$url" || return $?
  if [[ "$method" == "GET" ]]; then
    actual_status=$(curl -sS -o "$response_file" -w '%{http_code}' -X GET "$url") || {
      rollback_contract_json "error" "protocol_fixture_unreachable" "known-answer fixture was unreachable: $feature"
      return 69
    }
  else
    actual_status=$(curl -sS -o "$response_file" -w '%{http_code}' \
      -X POST \
      -H 'content-type: application/json' \
      --data-binary "$request_body" \
      "$url") || {
      rollback_contract_json "error" "protocol_fixture_unreachable" "known-answer fixture was unreachable: $feature"
      return 69
    }
  fi
  if [[ "$actual_status" != "$expected_status" ]]; then
    rollback_contract_json "error" "protocol_fixture_status_mismatch" "known-answer fixture returned the wrong status: $feature"
    return 65
  fi
  if ! jq -e --argjson expected "$expected_body" '. == $expected' "$response_file" >/dev/null 2>&1; then
    rollback_contract_json "error" "protocol_fixture_body_mismatch" "known-answer fixture returned the wrong body: $feature"
    return 65
  fi
}

rollback_cleanup_candidate_runtime() {
  if [[ -n "${ROLLBACK_CANDIDATE_PID:-}" ]]; then
    kill "$ROLLBACK_CANDIDATE_PID" 2>/dev/null || true
    wait "$ROLLBACK_CANDIDATE_PID" 2>/dev/null || true
    ROLLBACK_CANDIDATE_PID=""
  fi
  if [[ "${ROLLBACK_POSTGRES_STARTED:-false}" == "true" ]]; then
    rollback_pg_command pg_ctl -D "$ROLLBACK_DATABASE_DIR" -m immediate -w stop >/dev/null 2>&1 || true
    ROLLBACK_POSTGRES_STARTED=false
  fi
  [[ -z "${ROLLBACK_PROOF_ROOT:-}" ]] || rm -rf "$ROLLBACK_PROOF_ROOT"
}

rollback_free_loopback_port() {
  python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

# Bind the running candidate to both development and published mirror identities.
rollback_verify_served_identity() {
  local manifest="$1" expected_served_sha="$2"
  local url response dev_sha mirror_sha
  url=$(rollback_manifest_value "$manifest" '.served_version_url')
  rollback_require_loopback_url "$url" || return $?
  response=$(curl -fsS "$url") || {
    rollback_contract_json "error" "served_identity_unreachable" "candidate /version endpoint was unreachable"
    return 69
  }
  dev_sha=$(printf '%s' "$response" | jq -r '.dev_sha // empty')
  mirror_sha=$(printf '%s' "$response" | jq -r '.mirror_sha // empty')
  if [[ "$dev_sha" != "$expected_served_sha" ]]; then
    rollback_contract_json "error" "wrong_dev_sha" "served dev SHA does not match expected SHA"
    return 65
  fi
  if [[ "$mirror_sha" != "$(rollback_manifest_value "$manifest" '.mirror_sha')" ]]; then
    rollback_contract_json "error" "wrong_mirror_sha" "served mirror SHA does not match manifest mirror SHA"
    return 65
  fi
}

# Verify the running candidate reports the durable rollback epoch and floors.
rollback_verify_served_state() {
  local manifest="$1"
  local url response state_epoch state_schema state_protocol
  url=$(rollback_manifest_value "$manifest" '.served_state_url')
  rollback_require_loopback_url "$url" || return $?
  response=$(curl -fsS "$url") || {
    rollback_contract_json "error" "served_state_unreachable" "candidate state endpoint was unreachable"
    return 69
  }
  state_epoch=$(printf '%s' "$response" | jq -r '.rollback_epoch // empty')
  state_schema=$(printf '%s' "$response" | jq -r '.schema_floor // empty')
  state_protocol=$(printf '%s' "$response" | jq -r '.protocol_floor // empty')
  if [[ "$state_epoch" != "migration_aware_required" ]]; then
    rollback_contract_json "error" "wrong_served_state" "served rollback epoch is not migration-aware"
    return 65
  fi
  if [[ ! "$state_schema" =~ ^[0-9]+$ || ! "$state_protocol" =~ ^[0-9]+$ ]]; then
    rollback_contract_json "error" "wrong_served_state" "served schema and protocol floors must be integers"
    return 65
  fi
  if (( state_schema < $(jq -r '.required_schema_floor' "$manifest") )); then
    rollback_contract_json "error" "wrong_served_state" "served schema floor is below required floor"
    return 65
  fi
  if (( state_protocol < $(jq -r '.required_protocol_floor' "$manifest") )); then
    rollback_contract_json "error" "wrong_served_state" "served protocol floor is below required floor"
    return 65
  fi
}

rollback_require_absolute() {
  local name="$1" value="$2"
  rollback_require_nonempty "$name" "$value" || return $?
  if [[ "$value" != /* ]]; then
    rollback_contract_json "error" "relative_path" "$name must be an absolute path"
    return 64
  fi
}

rollback_require_nonempty() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    rollback_contract_json "error" "missing_argument" "$name is required"
    return 64
  fi
}

rollback_require_loopback_url() {
  local url="$1"
  if [[ ! "$url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/ ]]; then
    rollback_contract_json "error" "non_loopback_candidate" "candidate proof URLs must use loopback HTTP"
    return 65
  fi
}

rollback_loopback_origin() {
  local url="$1"
  if [[ "$url" =~ ^http://(127\.0\.0\.1|localhost):([0-9]+)/ ]]; then
    printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

rollback_manifest_value() {
  local manifest="$1" query="$2"
  jq -r "$query // empty" "$manifest"
}

rollback_file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

rollback_stream_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

rollback_contract_json() {
  local status="$1" code="$2" message="$3"
  jq -n --arg status "$status" --arg code "$code" --arg message "$message" \
    '{status: $status, code: $code, message: $message}'
}
