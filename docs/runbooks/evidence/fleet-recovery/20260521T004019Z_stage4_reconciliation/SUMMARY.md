# Stage 4 Reconciliation Summary

## Mutation Sets
- No missing shared `vm_inventory` rows required insertion in this run; `class2_shared_managed_missing_inventory.csv` was header-only and `10_insert_missing_shared_inventory.out.txt` recorded `inserted_rows = 0`.
- No deployment/tenant status transitions were applied in this run because the stale shared-provisioning bucket was already zero in pre-state.

## Probe Buckets (Pre -> Post)
- `inventory_rows_without_nonterminated_ec2_match`: 0 -> 0
- `managed_instances_without_inventory_match`: 0 -> 0
- `deployment_linkage_mismatches`: 0 -> 0
- `stuck_shared_provisioning_rows`: 0 -> 0

## Residual Deferred Rows (Stage 5)
- None.

## Evidence Index
- `pre/summary.json`, `post/summary.json`
- `pre/32_bookkeeping_hypothesis.sql.txt`, `post/32_bookkeeping_hypothesis.sql.txt`
- `pre/24_customer_deployments_by_status.csv`, `post/24_customer_deployments_by_status.csv`
- `sql/class2_shared_managed_missing_inventory.csv`, `sql/class3_nonshared_managed_missing_inventory.csv`
- `batches/10_insert_missing_shared_inventory.out.txt`
