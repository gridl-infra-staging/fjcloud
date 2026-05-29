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
| gcp | The gcp directory contains provisioner modules for Google Cloud Platform integration, with api_client.rs providing stub functionality for GCP API interactions and mod.rs serving as the module entrypoint. |
| oci | The oci directory contains provisioner code for Oracle Cloud Infrastructure integration, with an API client and module definition. |
| gcp | The gcp directory contains the Google Cloud Platform provisioner implementation, including an API client for interacting with GCP services and the module definition that orchestrates GCP-specific provisioning operations. |
| oci | The oci directory implements an Oracle Cloud Infrastructure (OCI) compute provisioner, with api_client.rs handling RSA-SHA256 request signing and OCI API communication, and mod.rs providing VM provisioning configuration and instance lifecycle state management. |
<!-- [scrai:end] -->
