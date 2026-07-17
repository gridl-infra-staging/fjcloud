# Reconciled Counts vs roadmap note (chatting/may20_post_merge_roadmap_reconciliation.md:327-339)

| Metric | Fresh count | Roadmap-note reference |
| --- | ---: | --- |
| Dead-but-running deployments (running EC2 + non-200 health) | 37 | note claimed 41/43 VMs unhealthy in sample probe |
| Inventory rows without non-terminated EC2 match | 14 | note claimed ~10 inventory rows mapped to terminated instances |
| Deployments stuck in provisioning | 41 | note claimed 32 stuck in provisioning |

Deployment status distribution from SQL:
- provisioning: 41
- running: 33
