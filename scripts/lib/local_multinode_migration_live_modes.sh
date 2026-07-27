#!/usr/bin/env bash
# Scenario runner and finalizers for the local multinode migration live probe.

validate_captured_live_evidence() {
    local candidate_path="$1" evidence_path="$2"
    local out_path
    if [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ]; then
        out_path="$(algolia_import_probe_secure_temp_file "$RUNTIME_DIR")"
        OWNED_RUNTIME_FILES+=("$out_path")
    else
        out_path="$(mktemp "${TMPDIR:-/tmp}/local_multinode_migration_probe.assert.XXXXXX")"
    fi

    if classify_evidence "$candidate_path" > "$out_path"; then
        [ "$candidate_path" = "$evidence_path" ] || cp "$candidate_path" "$evidence_path"
        cat "$out_path"
        rm -f "$out_path" 2>/dev/null || true
        return 0
    fi
    cat "$out_path" >&2; log "captured evidence failed validation"
    : > "$evidence_path"
    rm -f "$out_path" 2>/dev/null || true
    return 1
}

require_live_ha_no_auth_opt_in() {
    [ "${LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND:-0}" = "1" ] && return 0
    log "refusing unauthenticated HA bind without LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1"
    exit 2
}

finalize_positive_live_evidence() {
    local evidence_path="$1"
    validate_captured_live_evidence "$evidence_path" "$evidence_path"
}

finalize_expected_red_evidence() {
    local evidence_path="$1" out_path classifier_rc
    if [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ]; then
        out_path="$(algolia_import_probe_secure_temp_file "$RUNTIME_DIR")"
        OWNED_RUNTIME_FILES+=("$out_path")
    else
        out_path="$(mktemp "${TMPDIR:-/tmp}/local_multinode_migration_probe.assert.XXXXXX")"
    fi

    set +e
    classify_evidence "$evidence_path" > "$out_path"
    classifier_rc=$?
    set -e
    case "$classifier_rc" in
        1)
            cat "$out_path"
            rm -f "$out_path" 2>/dev/null || true
            return 1
            ;;
        0)
            cat "$out_path" >&2
            log "expected RED evidence unexpectedly passed"
            rm -f "$out_path" 2>/dev/null || true
            return 2
            ;;
        *)
            rm -f "$out_path" 2>/dev/null || true
            return 2
            ;;
    esac
}

preserve_negative_ha_vs_standalone_evidence() {
    [ "$STANDALONE_PEER_COUNT" -eq 0 ] || return 1
    [ "$HA_PEER_COUNT" -ge 1 ] || return 1
    HA_CREATE_REFUSAL_JSON="$(
        python3 "$LIVE_JSON_HELPER" rebind-ha-refusal-peer-count \
            "$HA_CREATE_REFUSAL_JSON" "$STANDALONE_PEER_COUNT"
    )"
}

preserve_negative_stale_survivor_evidence() {
    STALE_DESTINATION_OBJECT_IDS_JSON='["stale-destination-doc"]'
}

configure_live_scenario() {
    local scenario_mode="$1"
    LIVE_SCENARIO_MODE="$scenario_mode"
    EXPECT_STALE_DESTINATION_SURVIVOR=false
    STALE_DESTINATION_OBJECT_IDS_JSON='[]'
    case "$scenario_mode" in
        positive|negative_ha_vs_standalone) ;;
        negative_stale_survivor) EXPECT_STALE_DESTINATION_SURVIVOR=true ;;
        *) return 1 ;;
    esac
}

apply_live_scenario_evidence() {
    local scenario_mode="$1"
    case "$scenario_mode" in
        positive) return 0 ;;
        negative_ha_vs_standalone) preserve_negative_ha_vs_standalone_evidence ;;
        negative_stale_survivor) preserve_negative_stale_survivor_evidence ;;
        *) return 1 ;;
    esac
}

finalize_live_evidence() {
    local scenario_mode="$1" evidence_path="$2"
    case "$scenario_mode" in
        positive) finalize_positive_live_evidence "$evidence_path" ;;
        negative_ha_vs_standalone|negative_stale_survivor)
            finalize_expected_red_evidence "$evidence_path"
            ;;
        *) return 2 ;;
    esac
}

run_live_sequence() {
    local scenario_mode="$1" evidence_path="$2"

    configure_live_scenario "$scenario_mode" || return 1
    prepare_live_plan || live_fail "selected Flapjack identity is invalid"
    validate_flapjack_migration_contract \
        || live_fail "Flapjack migration contract is incompatible"
    seed_live_algolia_sources || live_fail "Algolia source seeding failed"
    start_standalone_flapjack || live_fail "standalone Flapjack failed to start"
    measure_standalone_topology || live_fail "standalone topology measurement failed"
    run_standalone_specimens || live_fail "standalone migration specimen failed"
    start_peer_connected_flapjack || live_fail "peer-connected Flapjack failed to start"
    run_ha_refusal_specimens || live_fail "HA refusal specimen failed"
    apply_live_scenario_evidence "$scenario_mode" || {
        live_fail "negative evidence assembly failed"
    }
    set_cleanup_counts_json 0 0 0 0 0
    write_live_evidence "$evidence_path" || live_fail "live evidence assembly failed"
    cleanup_owned_resources || live_fail "cleanup failed"
    python3 "$LIVE_JSON_HELPER" stamp-cleanup \
        "$evidence_path" "$CLEANUP_COUNTS_JSON" || {
        live_fail "live evidence cleanup stamping failed"
    }
}

run_live_mode() {
    local evidence_path="$1" scenario_mode="${2:-positive}" rc

    validate_live_evidence_output_path "$evidence_path"
    prepare_live_runtime
    require_live_docker_daemon
    require_live_flapjack_binary
    require_live_algolia_credentials
    require_live_ha_no_auth_opt_in

    run_live_sequence "$scenario_mode" "$evidence_path" || exit 2
    finalize_live_evidence "$scenario_mode" "$evidence_path"
    rc=$?
    exit "$rc"
}
