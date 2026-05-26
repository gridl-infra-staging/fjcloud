# Snapshot Row-Parity Interpretation

The snapshot restore path itself worked: AWS accepted the request, the target reached `available`, the source SG was attached, the restored target was reachable from `fjcloud-api-staging` via SSM, and migration parity passed (`live_max_mig=54 restored_max_mig=54`).

The `row_count_parity` check against current live failed because the latest automated snapshot was created at `2026-05-25T02:13:29Z`, roughly 19 hours before verification. Current live counts therefore include a full business day of writes that the snapshot could not possibly contain. The observed drift was:

- `customers`: live `1034`, restored `957`, drift `77` (> 5% ceiling `51`)
- `customer_deployments`: live `538`, restored `467`, drift `71` (> 5% ceiling `26`)

That result does **not** imply a partial restore. It shows the verification rule is invalid when the snapshot-to-live gap is measured in many hours. Tight row-parity should be asserted on a near-live PITR restore instead, where the requested restore point is within minutes of live.
