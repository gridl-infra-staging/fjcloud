#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "infra" / "api" / "tests"
INTEGRATION_DIR = TESTS_DIR / "integration"
LEGACY_INTEGRATION_ROOT = TESTS_DIR / "integration.rs"
ROOT_GROUPS: dict[str, tuple[str, ...]] = {
    # index/search/replica/discovery/restore/analytics stems
    "indexes": (
        "admin_indexes_test",
        "admin_replicas_test",
        "discovery_test",
        "flapjack_proxy_analytics_experiments_debug_test",
        "index_metrics_scrape_test",
        "index_replica_repo_test",
        "indexes_ai_routes_test",
        "indexes_security_sources_routes_test",
        "indexes_test",
        "pg_index_replica_repo_test",
        "reliability_replication_test",
        "replication_test",
        "restore_endpoints_test",
        "restore_job_repo_test",
    ),
    # billing/stripe/invoice/quota/usage stems
    "billing": (
        "billing_endpoints_test",
        "billing_estimate_test",
        "billing_regression_test",
        "cross_region_billing_test",
        "integration_stripe_test",
        "invoice_email_test",
        "invoices_test",
        "quota_enforcement_test",
        "stripe_billing_test",
        "stripe_local_dispatch_test",
        "stripe_pay_invoice_test",
        "stripe_test_clock_full_cycle_test",
        "stripe_webhook_event_matrix_test",
        "stripe_webhook_idempotency_test",
        "stripe_webhook_signature_test",
        "usage_test",
    ),
    # auth/oauth/admin/security/audit stems
    "auth_admin": (
        "admin_alerts_test",
        "admin_audit_view_test",
        "admin_broadcast_test",
        "admin_cold_test",
        "admin_deployments_test",
        "admin_migrations_test",
        "admin_providers_test",
        "admin_token_audit_test",
        "admin_vm_kill_test",
        "admin_vms_test",
        "admin_webhook_events_test",
        "api_key_auth_test",
        "auth_endpoints_test",
        "auth_lockout_test",
        "auth_test",
        "flapjack_proxy_security_sources_test",
        "garage_admin_client_test",
        "internal_auth_test",
        "migration_048_oauth_identities_test",
        "migration_052_auth_lockout_state_test",
        "oauth_start_routes_test",
        "reliability_security_test",
        "security_test",
        "storage_s3_auth_test",
    ),
    # Everything else currently known; newly added unmapped stems fail safe here.
    "platform": (
        "access_tracker_test",
        "account_test",
        "alerting_test",
        "alerting_webhook_smoke_test",
        "algolia_import_job_domain",
        "algolia_import_job_domain_reservation",
        "algolia_import_job_domain_reservation_accounting",
        "algolia_import_job_domain_transitions",
        "api_key_endpoints_test",
        "api_key_repo_test",
        "aws_provisioner_test",
        "browser_error_reporting_test",
        "catalog_lifecycle_leases",
        "cold_snapshot_repo_test",
        "cold_tier_integration_test",
        "cold_tier_test",
        "cross_repo_contract_test",
        "cross_tenant_isolation_test",
        "customer_hard_delete_test",
        "customer_metrics_test",
        "deployment_repo_test",
        "deployments_route_removed_test",
        "deployments_test",
        "dns_test",
        "email_service_test",
        "email_test",
        "engine_index_identity",
        "flapjack_proxy_ai_methods_test",
        "flapjack_proxy_domain_methods_test",
        "flapjack_proxy_migration_test",
        "flapjack_proxy_routing_edge_cases_test",
        "flapjack_proxy_test",
        "free_tier_caps_test",
        "garage_object_store_test",
        "gcp_provisioner_test",
        "ha_demo_integration_test",
        "health_monitor_alert_test",
        "health_monitor_test",
        "health_test",
        "heartbeat_publisher_test",
        "hetzner_provisioner_test",
        "input_validation_test",
        "integration_cold_tier_test",
        "integration_flapjack_proxy_test",
        "integration_health_monitor_test",
        "integration_metering_pipeline_test",
        "integration_metrics_test",
        "integration_smoke_test",
        "invoicing_compute_test",
        "logging_test",
        "metering_multitenant_test",
        "metrics_endpoint_test",
        "migration_046_drops_subscriptions_test",
        "migration_053_disputes_test",
        "migration_054_password_reset_resend_cooldown_test",
        "migration_058_deployment_failure_reason_test",
        "migration_routes_test",
        "migration_test",
        "multi_provisioner_test",
        "node_secret_test",
        "noisy_neighbor_test",
        "object_store_test",
        "oci_provisioner_test",
        "onboarding_credentials_test",
        "onboarding_test",
        "openapi_spec_final_test",
        "openapi_spec_stages3_5_test",
        "openapi_spec_test",
        "panics_publisher_test",
        "pg_customer_repo_schema_harness_test",
        "pg_customer_repo_test",
        "pg_dispute_repo_test",
        "pg_webhook_event_repo_test",
        "placement_test",
        "pricing_compare_test",
        "provisioner_test",
        "provisioning_service_test",
        "public_site_test",
        "rate_card_test",
        "region_failover_test",
        "reliability_api_crash_test",
        "reliability_cold_tier_test",
        "reliability_failure_injection_test",
        "reliability_migration_test",
        "reliability_profile_freshness_test",
        "retention_job_test",
        "replica_service_test",
        "restore_test",
        "scheduler_test",
        "ses_bounce_complaint_handler_test",
        "signup_abuse_test",
        "ssh_provisioner_test",
        "storage_bucket_repo_test",
        "storage_key_repo_test",
        "storage_load_test",
        "storage_s3_bucket_lifecycle_integration_test",
        "storage_s3_bucket_routes_test",
        "storage_s3_concurrent_metering_test",
        "storage_s3_error_test",
        "storage_s3_extractor_test",
        "storage_s3_integration_test",
        "storage_s3_object_metering_concurrency_test",
        "storage_s3_object_routes_test",
        "storage_s3_proxy_test",
        "storage_s3_xml_test",
        "storage_service_test",
        "tenant_isolation_proptest",
        "tenant_repo_test",
        "tenants_test",
        "version_test",
        "vm_inventory_test",
        "webhook_alert_test",
        "webhook_dunning_email_test",
        "webhook_lag_publisher_test",
    ),
}
GROUPED_ROOTS = {
    group_name: TESTS_DIR / f"{group_name}.rs" for group_name in ROOT_GROUPS
}


def module_cfg(source_path: Path) -> str | None:
    text = source_path.read_text(encoding="utf-8")
    match = re.search(r"(?m)^#!\[(cfg\([^\]]+\))\]\s*$", text)
    if match:
        return match.group(1)
    return None


def integration_module_stems() -> set[str]:
    return {
        path.stem for path in INTEGRATION_DIR.glob("*.rs")
    } - path_included_child_stems()


def path_included_child_stems() -> set[str]:
    included: set[str] = set()
    for source_path in INTEGRATION_DIR.glob("*.rs"):
        lines = source_path.read_text(encoding="utf-8").splitlines()
        for line in lines:
            stripped = line.strip()
            if not stripped.startswith("#[path = \"") or not stripped.endswith("\"]"):
                continue
            relative_path = stripped.removeprefix("#[path = \"").removesuffix("\"]")
            included.add(Path(relative_path).stem)
    return included


def grouped_modules() -> dict[str, list[str]]:
    remaining = integration_module_stems()
    grouped: dict[str, list[str]] = {}

    for group_name, explicit_stems in ROOT_GROUPS.items():
        modules = sorted(stem for stem in explicit_stems if stem in remaining)
        grouped[group_name] = modules
        remaining.difference_update(modules)

    grouped["platform"].extend(sorted(remaining))
    grouped["platform"] = sorted(grouped["platform"])
    return grouped


def render_root(module_names: list[str]) -> str:
    unconditional: list[str] = []
    conditional: dict[str, list[str]] = defaultdict(list)

    for module_name in module_names:
        cfg_expr = module_cfg(INTEGRATION_DIR / f"{module_name}.rs")
        if cfg_expr is None:
            unconditional.append(module_name)
        else:
            conditional[cfg_expr].append(module_name)

    lines: list[str] = [
        "//! Generated by scripts/dev/regenerate_integration_test_root.py. Do not edit by hand.",
        "",
        "mod common;",
        "",
    ]

    for module_name in unconditional:
        lines.append(f"#[path = \"integration/{module_name}.rs\"]")
        lines.append(f"mod {module_name};")

    for cfg_expr in sorted(conditional):
        lines.append("")
        lines.append(f"#[{cfg_expr}]")
        for module_name in conditional[cfg_expr]:
            lines.append(f"#[path = \"integration/{module_name}.rs\"]")
            lines.append(f"mod {module_name};")

    lines.append("")
    return "\n".join(lines)


def render_roots() -> dict[Path, str]:
    return {
        GROUPED_ROOTS[group_name]: render_root(module_names)
        for group_name, module_names in grouped_modules().items()
    }


def cmd_print() -> int:
    rendered = render_roots()
    for root_path in sorted(rendered):
        print(f"--- {root_path.relative_to(REPO_ROOT)} ---")
        sys.stdout.write(rendered[root_path])
    return 0


def cmd_write() -> int:
    for root_path, content in render_roots().items():
        root_path.write_text(content, encoding="utf-8")
    if LEGACY_INTEGRATION_ROOT.exists():
        LEGACY_INTEGRATION_ROOT.unlink()
    return 0


def cmd_check() -> int:
    expected = render_roots()
    errors: list[str] = []
    explicitly_grouped = {
        stem for explicit_stems in ROOT_GROUPS.values() for stem in explicit_stems
    }
    ungrouped_modules = sorted(integration_module_stems() - explicitly_grouped)

    if LEGACY_INTEGRATION_ROOT.exists():
        errors.append(
            f"legacy generated root exists: {LEGACY_INTEGRATION_ROOT.relative_to(REPO_ROOT)}"
        )

    for module_name in ungrouped_modules:
        errors.append(
            "integration module missing explicit ROOT_GROUPS ownership: "
            f"integration/{module_name}.rs"
        )

    for root_path, expected_content in sorted(expected.items()):
        if not root_path.exists():
            errors.append(f"missing generated root: {root_path.relative_to(REPO_ROOT)}")
            continue
        actual_content = root_path.read_text(encoding="utf-8")
        if actual_content != expected_content:
            errors.append(f"stale generated root: {root_path.relative_to(REPO_ROOT)}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        if ungrouped_modules:
            print(
                "assign every integration module to an explicit ROOT_GROUPS entry, "
                "then run python3 scripts/dev/regenerate_integration_test_root.py --write",
                file=sys.stderr,
            )
        else:
            print(
                "grouped integration test roots are stale; run "
                "python3 scripts/dev/regenerate_integration_test_root.py --write",
                file=sys.stderr,
            )
        return 1
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--print", dest="print_mode", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.write:
        return cmd_write()
    if args.check:
        return cmd_check()
    if args.print_mode:
        return cmd_print()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
