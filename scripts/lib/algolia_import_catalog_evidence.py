#!/usr/bin/env python3
"""Validate production catalog-lifecycle caller evidence against its inventory."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, NoReturn


CATALOG_PHASE = "catalog"
LIFECYCLE_PHASE = "lifecycle_exclusion"
ACTIVE_JOB_STATUSES = {
    "queued",
    "validating_source",
    "copying_configuration",
    "copying_documents",
    "verifying",
    "promoting",
    "cancelling",
}
PRE_TERMINAL_DISPOSITIONS = {"not_started", "unchanged", "unknown"}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
INVARIANT_SURFACES = {"catalog", "public_indexes", "quota", "routing"}
LIFECYCLE_CHECK_SELECTIONS = {
    "soft_delete_pre_promotion": (
        "algolia_import_catalog_finalize::soft_delete_boundaries::"
        "soft_delete_pre_promotion_retains_target_and_fences_ack"
    ),
    "soft_delete_cancelling": (
        "algolia_import_catalog_finalize::soft_delete_boundaries::"
        "soft_delete_cancelling_retains_target_and_fences_ack"
    ),
    "soft_delete_cancelled_before_ack": (
        "algolia_import_catalog_finalize::soft_delete_boundaries::"
        "soft_delete_cancelled_before_ack_retains_target_and_fences_ack"
    ),
    "soft_delete_terminal_failed": (
        "algolia_import_catalog_finalize::soft_delete_boundaries::"
        "soft_delete_terminal_failed_retains_target_and_fences_ack"
    ),
    "soft_delete_post_promotion": (
        "algolia_import_catalog_finalize::soft_delete_boundaries::"
        "soft_delete_post_promotion_retains_target_and_fences_ack"
    ),
    "hidden_while_deleted_authorization": (
        "catalog_lifecycle_leases::catalog_lifecycle_lease_invariants::"
        "soft_deleted_customer_snapshot_eligibility_refuses_while_target_retained"
    ),
    "ack_release_active_reservation_predicate": (
        "algolia_import_catalog_finalize::"
        "catalog_lifecycle_write_is_excluded_until_terminal_ack_releases_reservation"
    ),
    "deleted_reactivation_refused_400_no_mutation": (
        "admin_audit_view_test::"
        "post_admin_customers_reactivate_deleted_writes_no_audit_row"
    ),
    "suspended_reactivation_active_200": (
        "admin_audit_view_test::"
        "post_admin_customers_reactivate_writes_customer_reactivated_audit_row"
    ),
}


def fail(reason: str) -> NoReturn:
    print(reason, file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path, reason: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        fail(reason)
    if not isinstance(payload, dict):
        fail(reason)
    return payload


def requested_phases(value: str) -> set[str]:
    phases = set(value.split(","))
    if not phases or not phases <= {CATALOG_PHASE, LIFECYCLE_PHASE}:
        fail("caller_evidence_invalid")
    return phases


def expected_rows(inventory: dict[str, Any], phases: set[str]) -> list[dict[str, Any]]:
    writers = inventory.get("writers")
    if not isinstance(writers, list):
        fail("caller_evidence_invalid")
    rows = [
        row
        for row in writers
        if isinstance(row, dict) and row.get("live_phase") in phases
    ]
    if not rows:
        fail("accepted_refused_count_drift")
    return rows


def validate_observations(evidence: dict[str, Any], rows: list[dict[str, Any]]) -> None:
    observations = evidence.get("observations")
    if not isinstance(observations, list) or any(
        not isinstance(observation, dict) for observation in observations
    ):
        fail("caller_evidence_invalid")

    observed_ids = [observation.get("writer_id") for observation in observations]
    if any(count > 1 for count in Counter(observed_ids).values()):
        fail("repeated_writer_observation")

    expected_by_id = {row["id"]: row for row in rows}
    if set(observed_ids) != set(expected_by_id):
        fail("accepted_refused_count_drift")

    for observation in observations:
        row = expected_by_id[observation["writer_id"]]
        if observation.get("caller_key") != row.get("live_caller_key"):
            fail("accepted_refused_count_drift")
        if observation.get("caller_command") != row.get("live_caller_command"):
            fail("accepted_refused_count_drift")
        if observation.get("scenario_key") != row.get("live_scenario_key"):
            fail("accepted_refused_count_drift")
        expected_outcome = (
            "refused" if row["live_phase"] == CATALOG_PHASE else "retained"
        )
        if observation.get("outcome") != expected_outcome:
            if row["live_phase"] == CATALOG_PHASE:
                fail("catalog_mutation_accepted")
            fail("lifecycle_policy_drift")


def validate_scenario_ledger(
    evidence: dict[str, Any], rows: list[dict[str, Any]]
) -> None:
    ledger = evidence.get("scenario_ledger")
    if not isinstance(ledger, list) or any(
        not isinstance(scenario, str) for scenario in ledger
    ):
        fail("caller_evidence_invalid")
    if len(ledger) != len(set(ledger)):
        fail("repeated_scenario_coverage")
    expected = {row["live_scenario_key"] for row in rows}
    if set(ledger) != expected:
        fail("accepted_refused_count_drift")


def validate_executed_scenarios(
    evidence: dict[str, Any], rows: list[dict[str, Any]], phases: set[str]
) -> None:
    executed = evidence.get("executed_scenarios")
    if (
        not isinstance(executed, list)
        or any(not isinstance(selection, str) for selection in executed)
        or len(executed) != len(set(executed))
    ):
        fail("caller_evidence_invalid")
    expected = {row["live_scenario_key"] for row in rows}
    if LIFECYCLE_PHASE in phases:
        expected.update(LIFECYCLE_CHECK_SELECTIONS.values())
    if set(executed) != expected:
        fail("accepted_refused_count_drift")


def validate_live_reservation_checks(
    evidence: dict[str, Any], rows: list[dict[str, Any]], phases: set[str]
) -> None:
    checks = evidence.get("live_reservation_checks")
    if (
        not isinstance(checks, list)
        or any(not isinstance(check, dict) for check in checks)
    ):
        fail("active_reservation_not_observed")

    expected = {
        (row["live_scenario_key"], row["live_caller_key"], checkpoint)
        for row in rows
        if row["live_phase"] == CATALOG_PHASE
        for checkpoint in {"before", "after"}
    }
    if LIFECYCLE_PHASE in phases:
        lifecycle_selections = {
            row["live_scenario_key"]
            for row in rows
            if row["live_phase"] == LIFECYCLE_PHASE
        }
        lifecycle_selections.update(LIFECYCLE_CHECK_SELECTIONS.values())
        expected.update(
            (selection, "", checkpoint)
            for selection in lifecycle_selections
            for checkpoint in {"before", "after"}
        )
    catalog_rows_by_caller = {
        row["live_caller_key"]: row
        for row in rows
        if row["live_phase"] == CATALOG_PHASE
    }
    observed: set[tuple[str, str, str]] = set()
    customer_id = None
    target_index = None
    for check in checks:
        selection = check.get("selection")
        caller_key = check.get("caller_key")
        checkpoint = check.get("checkpoint")
        check_customer = check.get("customer_id")
        check_target = check.get("target_index")
        if (
            not isinstance(selection, str)
            or not isinstance(caller_key, str)
            or not isinstance(checkpoint, str)
            or not isinstance(check_customer, str)
            or not isinstance(check_target, str)
            or check.get("reservation_state") != "active"
        ):
            fail("active_reservation_not_observed")
        key = (selection, caller_key, checkpoint)
        if key in observed:
            fail("active_reservation_not_observed")
        observed.add(key)
        customer_id = check_customer if customer_id is None else customer_id
        target_index = check_target if target_index is None else target_index
        if check_customer != customer_id or check_target != target_index:
            fail("active_reservation_not_observed")
        if (
            checkpoint in {"before", "after"}
            and caller_key in catalog_rows_by_caller
            and selection != catalog_rows_by_caller[caller_key].get("live_scenario_key")
        ):
            fail("writer_invocation_identity_drift")
    if observed != expected:
        fail("active_reservation_not_observed")


def validate_invariants(
    evidence: dict[str, Any], rows: list[dict[str, Any]], phases: set[str]
) -> None:
    if CATALOG_PHASE not in phases:
        return
    invariants = evidence.get("invariants")
    if not isinstance(invariants, dict):
        fail("catalog_invariant_drift")
    production_scenarios = invariants.get("production_scenarios")
    expected_scenarios = {
        row["live_scenario_key"] for row in rows if row["live_phase"] == CATALOG_PHASE
    }
    if (
        not isinstance(production_scenarios, list)
        or len(production_scenarios) != len(set(production_scenarios))
        or set(production_scenarios) != expected_scenarios
    ):
        fail("catalog_invariant_drift")
    surfaces = invariants.get("surfaces")
    if (
        not isinstance(surfaces, list)
        or len(surfaces) != len(set(surfaces))
        or set(surfaces) != INVARIANT_SURFACES
    ):
        fail("catalog_invariant_drift")
    snapshots = evidence.get("invariant_snapshots")
    if not isinstance(snapshots, list) or any(
        not isinstance(snapshot, dict) for snapshot in snapshots
    ):
        fail("catalog_invariant_drift")
    expected_rows = {
        row["id"]: row for row in rows if row["live_phase"] == CATALOG_PHASE
    }
    observed: set[tuple[str, str]] = set()
    for snapshot in snapshots:
        writer_id = snapshot.get("writer_id")
        caller_key = snapshot.get("caller_key")
        scenario_key = snapshot.get("scenario_key")
        surface = snapshot.get("surface")
        before = snapshot.get("before_sha256")
        after = snapshot.get("after_sha256")
        if (
            not isinstance(writer_id, str)
            or not isinstance(caller_key, str)
            or writer_id not in expected_rows
            or caller_key != expected_rows[writer_id].get("live_caller_key")
            or scenario_key != expected_rows[writer_id].get("live_scenario_key")
            or not isinstance(surface, str)
            or not isinstance(before, str)
            or not isinstance(after, str)
            or surface not in INVARIANT_SURFACES
            or SHA256_PATTERN.fullmatch(before) is None
            or SHA256_PATTERN.fullmatch(after) is None
            or before != after
        ):
            fail("catalog_invariant_drift")
        key = (writer_id, surface)
        if key in observed:
            fail("catalog_invariant_drift")
        observed.add(key)
    expected = {
        (writer_id, surface)
        for writer_id in expected_rows
        for surface in INVARIANT_SURFACES
    }
    if observed != expected:
        fail("catalog_invariant_drift")


def validate_ack_release(evidence: dict[str, Any]) -> None:
    ledger = evidence.get("job_state_ledger")
    if (
        not isinstance(ledger, list)
        or len(ledger) != 2
        or any(not isinstance(observation, dict) for observation in ledger)
    ):
        fail("ack_release_not_observed")
    before, after = ledger
    if before.get("checkpoint") != "before_writer_execution":
        fail("ack_release_not_observed")
    if (
        before.get("reservation_state") != "active"
        or after.get("reservation_state") != "released"
        or not isinstance(before.get("customer_id"), str)
        or not isinstance(before.get("target_index"), str)
        or before.get("customer_id") != after.get("customer_id")
        or before.get("target_index") != after.get("target_index")
    ):
        fail("ack_release_not_observed")
    if (
        before.get("engine_ack_state") == "acknowledged"
        or before.get("terminal_at") == "present"
    ):
        fail("early_reservation_release")
    if (
        before.get("status") not in ACTIVE_JOB_STATUSES
        or before.get("publication_disposition") not in PRE_TERMINAL_DISPOSITIONS
        or before.get("engine_ack_state") != "pending"
        or before.get("terminal_at") != "absent"
        or before.get("dispatch_intent_state") != "committed"
        or before.get("engine_job_id") != "present"
        or after.get("checkpoint") != "after_reconciliation"
        or after.get("status") not in {"completed", "completed_with_warnings"}
        or after.get("publication_disposition") != "promoted"
        or after.get("engine_ack_state") != "acknowledged"
        or after.get("terminal_at") != "present"
        or after.get("dispatch_intent_state") != "committed"
        or after.get("engine_job_id") != "present"
    ):
        fail("ack_release_not_observed")


def validate_lifecycle(evidence: dict[str, Any]) -> None:
    lifecycle = evidence.get("lifecycle")
    if not isinstance(lifecycle, dict):
        fail("soft_delete_boundary_missing")
    checks = lifecycle.get("checks")
    if not isinstance(checks, list) or any(
        not isinstance(check, dict) for check in checks
    ):
        fail("soft_delete_boundary_missing")
    observed_pairs = [
        (check.get("contract"), check.get("selection")) for check in checks
    ]
    if any(
        not isinstance(contract, str) or not isinstance(selection, str)
        for contract, selection in observed_pairs
    ):
        fail("lifecycle_policy_drift")
    observed = dict(observed_pairs)
    if len(observed) != len(observed_pairs):
        fail("lifecycle_policy_drift")
    soft_delete_contracts = {
        contract: selection
        for contract, selection in LIFECYCLE_CHECK_SELECTIONS.items()
        if contract.startswith("soft_delete_")
    }
    if any(
        observed.get(contract) != selection
        for contract, selection in soft_delete_contracts.items()
    ):
        fail("soft_delete_boundary_missing")
    if (
        observed.get("hidden_while_deleted_authorization")
        != LIFECYCLE_CHECK_SELECTIONS["hidden_while_deleted_authorization"]
    ):
        fail("lifecycle_policy_drift")
    if (
        observed.get("ack_release_active_reservation_predicate")
        != LIFECYCLE_CHECK_SELECTIONS["ack_release_active_reservation_predicate"]
    ):
        fail("ack_release_not_observed")
    if (
        observed.get("deleted_reactivation_refused_400_no_mutation")
        != LIFECYCLE_CHECK_SELECTIONS["deleted_reactivation_refused_400_no_mutation"]
    ):
        fail("deleted_reactivation_accepted")
    if (
        observed.get("suspended_reactivation_active_200")
        != LIFECYCLE_CHECK_SELECTIONS["suspended_reactivation_active_200"]
    ):
        fail("suspended_reactivation_control_failed")
    if observed != LIFECYCLE_CHECK_SELECTIONS:
        fail("lifecycle_policy_drift")


def emit_evidence(phases: set[str], rows: list[dict[str, Any]], job_id: str) -> None:
    phase_counts = Counter(row["live_phase"] for row in rows)
    if CATALOG_PHASE in phases:
        print(
            "PHASE|name=catalog|expected=block_without_change:"
            f"{phase_counts[CATALOG_PHASE]}|observed=refused:"
            f"{phase_counts[CATALOG_PHASE]}|pass=true"
        )
    if LIFECYCLE_PHASE in phases:
        print(
            "PHASE|name=lifecycle_exclusion|"
            "expected=privacy_transition_soft_delete:"
            f"{phase_counts[LIFECYCLE_PHASE]}|observed=retained:"
            f"{phase_counts[LIFECYCLE_PHASE]}|pass=true"
        )
    print("EVIDENCE|invariants=catalog,quota,routing,public_indexes|unchanged=true")
    if CATALOG_PHASE in phases:
        print(
            "EVIDENCE|invariant_snapshots=surfaces:"
            f"{','.join(sorted(INVARIANT_SURFACES))}|per_catalog_writer=true"
        )
    print(f"EVIDENCE|ack_release=active_reservation_predicate|job_id={job_id}")
    print("EVIDENCE|live_reservation_binding=active_before_after_each_source_selection")
    if LIFECYCLE_PHASE in phases:
        print(
            "EVIDENCE|soft_delete_boundaries=5|"
            "deleted_reactivation=refused_400_no_mutation|"
            "suspended_reactivation=active_200"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list-lifecycle-checks", action="store_true")
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--phases")
    parser.add_argument("--job-id")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.list_lifecycle_checks:
        for contract, selection in LIFECYCLE_CHECK_SELECTIONS.items():
            print(f"{contract}\t{selection}")
        return
    if None in {args.inventory, args.evidence, args.phases, args.job_id}:
        fail("caller_evidence_invalid")
    phases = requested_phases(args.phases)
    inventory = load_json(args.inventory, "caller_evidence_invalid")
    evidence = load_json(args.evidence, "caller_evidence_invalid")
    if evidence.get("version") != 1 or evidence.get("job_id") != args.job_id:
        fail("caller_evidence_invalid")
    rows = expected_rows(inventory, phases)
    validate_observations(evidence, rows)
    validate_scenario_ledger(evidence, rows)
    validate_invariants(evidence, rows, phases)
    validate_ack_release(evidence)
    if LIFECYCLE_PHASE in phases:
        validate_lifecycle(evidence)
    validate_executed_scenarios(evidence, rows, phases)
    validate_live_reservation_checks(evidence, rows, phases)
    emit_evidence(phases, rows, args.job_id)


if __name__ == "__main__":
    main()
