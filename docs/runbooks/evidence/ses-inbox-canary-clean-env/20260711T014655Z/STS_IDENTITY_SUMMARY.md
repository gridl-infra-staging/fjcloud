# STS Identity Summary

Bundle: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711T014655Z/`

Purpose: prove the fresh Stage 4 live probes used the canonical staging AWS identity before SES sends and Lambda invokes.

## Source Evidence

| Source file | Account | ARN | Exit |
| --- | --- | --- | --- |
| `STS_IDENTITY.json` | `213880904778` | `arn:aws:iam::213880904778:user/stuart-cli` | `0` |
| `ses/production_access.stdout` | n/a | n/a | `0` |

## Verdict

STS identified `arn:aws:iam::213880904778:user/stuart-cli` in account `213880904778`. SES `ProductionAccessEnabled` returned `True`.
