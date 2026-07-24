# SSM Source Chain Handoff

## Candidate

- `CANDIDATE_SHA=1597d28ecd704e2976dba1e34043928d5d854b8c`
- Behavior owner: `infra/api/src/secrets/aws.rs::SsmNodeSecretManager::map_get_parameter_error`
- Focused source-chain test: `maps_dispatch_failure_with_nested_source_context`
- Neighboring modeled-missing test: `maps_parameter_not_found_get_error_to_missing_secret_error`

This candidate preserves nested AWS SDK dispatch source context at the existing SSM get-parameter error mapper. It does not add an AWS client, retry/config seam, endpoint override, credential change, IAM change, deployment action, service restart, registration stimulus, or claim that the staging signup/runtime defect is repaired.

Modeled `ParameterNotFound` still maps through the missing-secret recovery predicate: the focused `secrets::aws::tests` run includes `maps_parameter_not_found_get_error_to_missing_secret_error`, which proves the mapper still returns the missing-secret class for modeled SSM misses.

## Validation Commands

Focused source-chain command:

```bash
cargo test --manifest-path infra/api/Cargo.toml --locked secrets::aws::tests::maps_dispatch_failure_with_nested_source_context -- --nocapture
```

Neighboring SSM mapper command:

```bash
cargo test --manifest-path infra/api/Cargo.toml --locked secrets::aws::tests -- --nocapture
```

Full API validation command:

```bash
bash -lc 'source scripts/lib/env.sh; load_env_file .env.local; env -u SKIP_EMAIL_VERIFICATION -u LOCAL_DEV_FLAPJACK_URL -u FLAPJACK_URL DATABASE_URL="$DATABASE_URL" cargo test --manifest-path infra/api/Cargo.toml --all-features --locked --no-fail-fast'
```

Formatting and whitespace commands:

```bash
cargo fmt --manifest-path infra/Cargo.toml --all -- --check
git diff --check
```

Evidence hygiene commands:

```bash
bash scripts/check_evidence_secret_hygiene.sh
```

Local CI command:

```bash
bash scripts/local-ci.sh --fast
```

Handoff contract commands:

```bash
test -s docs/runbooks/evidence/staging-aws-sdk-dispatch-recovery/SOURCE_CHAIN_HANDOFF.md
test "$(rg -o 'SOURCE_CHAIN_PROBE=(ready|blocked)' docs/runbooks/evidence/staging-aws-sdk-dispatch-recovery/SOURCE_CHAIN_HANDOFF.md | wc -l | tr -d ' ')" = 1
```

## Later Staging Probe

Only a later staging-only lane should deploy the merged SHA, issue one unique registration stimulus, and capture the nested source chain. That lane must define these probe bounds before the request:

```bash
PROBE_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REGISTRATION_NONCE="SOURCE_CHAIN_STAGE2_NONCE_$(date -u +%Y%m%dT%H%M%SZ)"
# Issue exactly one registration stimulus carrying "$REGISTRATION_NONCE".
PROBE_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
scripts/launch/ssm_exec_staging.sh "journalctl -u fjcloud-api --since '$PROBE_START_UTC' --until '$PROBE_END_UTC' --no-pager" |
  rg -F -e "$REGISTRATION_NONCE" -e 'SSM GetParameter failed'
```

Before persisting any later staging evidence, apply the same classes named in `docs/runbooks/evidence/staging-aws-sdk-dispatch-recovery/20260724T183534Z/redaction_rules.txt`: raw environment values, AWS access-key IDs, AWS secret/session-token assignments, SigV4 signature values, AWS token header values, webhook URLs, email addresses, AWS account IDs in JSON or ARN output, registration response bodies, and journal evidence outside the nonce-bounded request window.

SOURCE_CHAIN_PROBE=ready
