# Exact Commands

EVIDENCE_DIR=docs/runbooks/evidence/staging-aws-sdk-dispatch-recovery/20260724T183534Z

- unset AWS_SESSION_TOKEN; set -a; source .secret/.env.secret; set +a; aws sts get-caller-identity --output json
- aws ec2 describe-instances --region $AWS_DEFAULT_REGION --filters Name=tag:Name,Values=fjcloud-api-staging Name=instance-state-name,Values=running --output json
- scripts/launch/ssm_exec_staging.sh '<remote metadata/version/systemctl/env redacted probe>'
- scripts/launch/ssm_exec_staging.sh '<remote service-user DNS/route/proxy/IMDS/AWS CLI debug and known-answer probes with remote redaction filter>'
- scripts/launch/ssm_exec_staging.sh '<remote host-context DNS/route/proxy/IMDS/AWS CLI debug and known-answer comparison with remote redaction filter>'
- source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging); curl -sS -X POST \"$API_URL/auth/register\" ... one generated test-inbox registration
- scripts/launch/ssm_exec_staging.sh 'journalctl -u fjcloud-api --since <start> --until <end> | redaction filter'
- bash scripts/check_evidence_secret_hygiene.sh
- test -s \"$EVIDENCE_DIR/diagnosis.md\"
- rg -n 'root_cause=|service_user=|instance_id=|deployed_sha=|registration_nonce=|registration_status=' \"$EVIDENCE_DIR/diagnosis.md\"
- ! rg -n -i --glob '!exact_commands.md' 'AKIA[0-9A-Z]{16}|AWS_SECRET_KEY_ENV=|AWS_TEMP_SESSION_ENV=|AWS_AUTH_HEADER_NAME_REDACTED:|AWS_TOKEN_HEADER_REDACTED,}' \"$EVIDENCE_DIR\"
- ! rg -n -U --glob '!exact_commands.md' 'Signature:\\n[0-9a-f]{64}' \"$EVIDENCE_DIR\"
