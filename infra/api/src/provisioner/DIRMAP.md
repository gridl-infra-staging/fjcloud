<!-- [scrai:start] -->
## provisioner

| File | Summary |
| --- | --- |
| aws.rs | Stub summary for aws.rs. |
| cloud_init.rs | Stub summary for cloud_init.rs. |
| env_config.rs | Shared environment-variable parsing helpers for provisioner configuration.



Every provisioner (OCI, GCP, Hetzner) needs to read typed values from env

vars with consistent trimming, empty-value rejection, and error messages.

This module is the single source of truth for that logic. |
| hetzner.rs | Stub summary for hetzner.rs. |
| mock.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/mock.rs. |
| multi.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/multi.rs. |
| region_map.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/region_map.rs. |
| ssh.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/ssh.rs. |

| Directory | Summary |
| --- | --- |
| gcp | The gcp directory provides a GCP Compute Engine provisioner for the fjcloud API that implements VM lifecycle operations (create, destroy, stop, start, status) with configuration from environment variables and HTTP client abstraction for the GCP Compute API. |
| oci | The oci directory contains Oracle Cloud Infrastructure provisioner integration, with an API client module and module exports. |
<!-- [scrai:end] -->
