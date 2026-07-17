# Diagnostics Scope Note

- Date: 2026-04-27
- Stage: Stage 1 inbound roundtrip timeout diagnosis
- Scope: read-only diagnostics only (script execution, code-owner inspection, Terraform-owner inspection, SES/DNS describe probes)
- SSOT rule: repo-owned runtime configuration remains in `scripts/lib/test_inbox_helpers.sh` and Terraform canary inputs; live SES `describe-*` results are diagnostic evidence only and do not supersede repository configuration owners.
- Redaction policy: redact email local-parts, message IDs, AWS account IDs, and caller identity fields from captured evidence.
