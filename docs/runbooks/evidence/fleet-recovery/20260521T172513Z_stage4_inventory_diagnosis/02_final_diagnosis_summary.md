# Stage 4 Final Inventory Diagnosis Summary (2026-05-21 UTC)

## 1) Scope and Stage 4 Source of Truth
- Canonical Stage 4 bundle (only source of truth for this lane closeout):
  - `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/`
- Incomplete background bundle (not authoritative for cleanup input):
  - `docs/runbooks/evidence/fleet-recovery/20260521T171423Z_stage4_inventory_diagnosis/`
  - Evidence of incompleteness: `reconciliation_summary.json` is empty in this sibling directory.

## 2) Exact-Count Findings From the Frozen Bundle
### 2.1 Reconciliation buckets (from `reconciliation_summary.json`)
- `inventory_rows_without_nonterminated_ec2_match`: `0`
- `managed_instances_without_inventory_match`: `0`
- `stuck_shared_provisioning_rows`: `0`
- `deployment_linkage_mismatches`: `0`

### 2.2 Inventory/deployment status totals
- `vm_inventory_status_counts.csv`:
  - `active=46`
- `customer_deployments_status_counts.csv`:
  - `provisioning=131`
  - `running=88`
  - `terminated=4`

### 2.3 Provisioning age buckets (from `provisioning_age_distribution.csv`)
- `lt_15m=1`
- `15m_to_1h=4`
- `1h_to_6h=27`
- `6h_to_24h=70`
- `gte_24h=29`

## 3) AWS-only vs Multi-provider Conclusion (Bounded)
Measured facts from `provisioning_rows_detailed.csv`:
- Detailed extract row count: `77`
- `vm_provider` distribution in detailed extract:
  - `aws=73`
  - `bare_metal=4`
- Top repeated host/provider tuple in detailed extract:
  - `(aws, 84f62708-e895-4fd9-a4c6-21f01d811b36, vm-shared-480b5169.flapjack.foo) => 40 rows`

Interpretation limits from owner seams:
- `scripts/tests/validate_vm_inventory_ec2_consistency_test.sh` codifies an EC2-scoped reconciliation seam.
- Therefore this frozen bundle proves AWS dominance in the EC2-scoped reconciliation and the detailed provisioning sample, but does **not** prove global backlog exclusivity across every provider path.
- Stage 4 diagnosis: backlog evidence is **multi-provider present with AWS-dominant concentration**, not strictly AWS-exclusive.

## 4) `usage_records` Exposure Quantification (Measured vs Inference)
Measured facts:
- `provisioning_rows_detailed.csv` includes `77` affected provisioning deployment rows and `64` distinct `customer_id` values.
- `tenant_id` is blank for all `77/77` detailed rows in this export.
- `inventory_vm_id` is present for all `77/77` detailed rows.
- `infra/api/src/routes/internal.rs::tenant_map` owner comment documents that missing/incorrect `flapjack_url` mapping can cause metering-agent filtering and `usage_records` non-writes.
- `infra/migrations/003_usage_records.sql` defines `usage_records` as the raw metering write table.

Bounded inference (explicit):
- This bundle does not directly prove missed `usage_records` writes because it does not contain raw metering scrape logs nor direct `usage_records` row deltas.
- Tightest upper bound supportable by this bundle for potentially impacted provisioning-linked units is:
  - at most `77` provisioning deployment rows across at most `64` customers in the detailed extract,
  - and at most `131` provisioning rows at fleet snapshot level (`customer_deployments_status_counts.csv`).
- Treat this as risk-envelope sizing, not proof of realized billing loss.

## 5) Repeated Deferral/Systemic Risk (Not a One-off Spike)
Measured indicators of recurrence:
- Age distribution is backlog-shaped rather than burst-shaped (`6h_to_24h=70`, `gte_24h=29`, versus `lt_15m=1`).
- `provisioning_by_customer_cohort.csv` shows `created_last_7d: provisioning_count=131` across `customer_count=116`, indicating repeat events across many customers instead of a single incident.
- Stage 2 (`state_machine_diagnosis.md`) already surfaced repeated shared-host concentration; Stage 4 detailed counts confirm continued concentration on repeated shared identities (top tuple count `40`, second tuple `9`).

Diagnosis conclusion:
- The provisioning backlog pattern in this frozen dataset is recurring and shared-host concentrated, with AWS-dominant evidence in the EC2-scoped seam and non-zero multi-provider presence in detailed rows.

## 6) Evidence Citations
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/reconciliation_summary.json`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/vm_inventory_status_counts.csv`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/customer_deployments_status_counts.csv`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/provisioning_age_distribution.csv`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/provisioning_rows_detailed.csv`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/provisioning_by_customer_cohort.csv`
- `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/state_machine_diagnosis.md`
- `scripts/tests/validate_vm_inventory_ec2_consistency_test.sh`
- `infra/api/src/routes/internal.rs`
- `infra/migrations/003_usage_records.sql`
