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
| gcp | GCP provisioning module for the fjcloud API infrastructure with client and module definitions for Google Cloud Platform interactions. |
| oci | The oci directory contains OCI (Oracle Cloud Infrastructure) provisioning client code for the API server, including the module definition and API client implementation for interacting with Oracle Cloud Infrastructure resources. |
| gcp | The gcp directory contains Google Cloud Platform provisioning support for the API layer, with an api_client module for GCP API interactions and a module definition file. |
| oci | The oci directory contains provisioner integration code for Oracle Cloud Infrastructure, with an api_client module for OCI API interactions and a module root file. |
<!-- [scrai:end] -->
