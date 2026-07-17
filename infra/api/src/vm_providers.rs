pub const AWS_VM_PROVIDER: &str = "aws";
pub const HETZNER_VM_PROVIDER: &str = "hetzner";
pub const GCP_VM_PROVIDER: &str = "gcp";
pub const OCI_VM_PROVIDER: &str = "oci";
pub const BARE_METAL_VM_PROVIDER: &str = "bare_metal";

pub const VALID_VM_PROVIDERS: &[&str] = &[
    AWS_VM_PROVIDER,
    HETZNER_VM_PROVIDER,
    GCP_VM_PROVIDER,
    OCI_VM_PROVIDER,
    BARE_METAL_VM_PROVIDER,
];
