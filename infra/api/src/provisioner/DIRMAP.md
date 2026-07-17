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

| Directory | Summary |
| --- | --- |
| gcp | — |
| oci | — |
<!-- [scrai:end] -->
