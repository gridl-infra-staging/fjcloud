<!-- [scrai:start] -->
## services

| File | Summary |
| --- | --- |
| alerting.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/alerting.rs. |
| ayb_admin.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/ayb_admin.rs. |
| discovery.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/discovery.rs. |
| email.rs | Stub summary for email.rs. |
| health_monitor.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/health_monitor.rs. |
| metrics.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/metrics.rs. |
| object_store.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/object_store.rs. |
| placement.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/placement.rs. |
| prometheus_parser.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/prometheus_parser.rs. |
| provisioning.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/provisioning.rs. |
| region_failover.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/region_failover.rs. |
| replica.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replica.rs. |
| replication.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replication.rs. |
| replication_error.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replication_error.rs. |
| restore.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/restore.rs. |
| tenant_quota.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/tenant_quota.rs. |

| Directory | Summary |
| --- | --- |
| cold_tier | The cold_tier module implements an automatic data tiering system that detects idle indexes (inactive beyond a configurable threshold) and moves them from hot Flapjack nodes to cold object storage via snapshots, including retry logic, alerting, and state rollback on failure. |
| flapjack_proxy | The flapjack_proxy service proxies management operations from the fjcloud API to individual flapjack VMs, authenticating with node admin keys cached from SSM. |
| migration | The migration service module provides comprehensive data migration capabilities including replication, validation, recovery, and alerting mechanisms. |
| provisioning | The provisioning directory contains automatic VM provisioning logic that handles shared VM creation across multiple cloud providers (AWS, Hetzner, GCP, OCI), including VM inventory management, secret delivery, and cloud initialization. |
| scheduler | The scheduler service manages resource allocation and workload distribution across nodes, handling initial placement decisions, detecting noisy neighbors and overload/underload conditions, and executing scheduling cycles to optimize resource utilization. |
| storage | The storage service module provides S3-compatible object storage integration through Garage, implementing authentication, request proxying, XML API handling, and object usage metering for the API server. |
<!-- [scrai:end] -->
