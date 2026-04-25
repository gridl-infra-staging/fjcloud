<!-- [scrai:start] -->
## provisioner

| File | Summary |
| --- | --- |
| aws.rs | Stub summary for aws.rs. |
| cloud_init.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/cloud_init.rs. |
| env_config.rs | Shared environment-variable parsing helpers for provisioner configuration.



Every provisioner (OCI, GCP, Hetzner) needs to read typed values from env

vars with consistent trimming, empty-value rejection, and error messages.

This module is the single source of truth for that logic. |
| hetzner.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/hetzner.rs. |
| mock.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/mock.rs. |
| multi.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/multi.rs. |
| region_map.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/region_map.rs. |
| ssh.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/ssh.rs. |

| Directory | Summary |
| --- | --- |
| gcp | The gcp module provides Google Compute Engine VM provisioning, handling instance creation, deletion, and lifecycle management (start/stop) through the GCP Compute API. |
| oci | This directory contains OCI (Oracle Cloud Infrastructure) provisioner integration code, with an API client module for OCI interactions. |
<!-- [scrai:end] -->
