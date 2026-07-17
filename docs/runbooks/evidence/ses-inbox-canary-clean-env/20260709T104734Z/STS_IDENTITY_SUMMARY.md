# STS Identity Summary

Bundle: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260709T104734Z/`

Purpose: prove the Stage 1-3 probes in this clean-env lane used the canonical
`stuart-cli` AWS identity for account `213880904778` without re-running AWS
commands during Stage 4.

## Source Evidence

| Stage | Source file | Account | ARN |
| --- | --- | --- | --- |
| Stage 1 SES bounce/complaint | `ses/sts_get_caller_identity.stdout` | `213880904778` | `arn:aws:iam::213880904778:user/stuart-cli` |
| Stage 2 inbound roundtrip | `inbound-roundtrip/sts_get_caller_identity.stdout` | `213880904778` | `arn:aws:iam::213880904778:user/stuart-cli` |
| Stage 3 customer-loop canary | `canary/aws_sts_get_caller_identity.stdout` | `213880904778` | `arn:aws:iam::213880904778:user/stuart-cli` |

## Verdict

All three probe-owned STS captures identify the same canonical user:
`arn:aws:iam::213880904778:user/stuart-cli`.

Stage 4 did not execute new AWS identity commands. The files listed above remain
the source of truth for credential proof.
