# Stage 1 Contract Inventory — Metering Agent Cleanup

## Scope and Method
- Stage objective: inventory all `fj-metering-agent` and `metering-env` assertions from:
  - `ops/terraform/tests_stage3_static.sh`
  - `ops/terraform/tests_deploy_scripts_static.sh`
  - `ops/terraform/tests_stage5_static.sh`
  - `scripts/tests/ci_workflow_test.sh`
- Classification semantics:
  - `retain`: assertion remains in current seam/owner.
  - `remove`: assertion removed with no replacement seam.
  - `retarget`: assertion migrates to a different seam/owner.

## Baseline Evidence (captured before analysis)
- `bash ops/terraform/tests_stage3_static.sh` -> `baseline_tests_stage3_static.log` (83/83 passed)
- `bash ops/terraform/tests_deploy_scripts_static.sh` -> `baseline_tests_deploy_scripts_static.log` (84/84 passed)
- `bash ops/terraform/tests_stage5_static.sh` -> `baseline_tests_stage5_static.log` (65/65 passed)
- `bash scripts/tests/ci_workflow_test.sh` -> `baseline_ci_workflow_test.log` (127/127 passed)

## Canonical Assertion Inventory
| assertion_id | source_file:line | exact assertion text/regex | protected property | current owner | classification | destination assertion seam (retarget only) |
|---|---|---|---|---|---|---|
| S1-A01 | `ops/terraform/tests_stage3_static.sh:157` | `ConditionPathExists=/etc/fjcloud/metering-env` | Metering service gates startup on metering-env file presence | `ops/systemd/fj-metering-agent.service` | retain | |
| S1-A02 | `ops/terraform/tests_stage3_static.sh:158` | `EnvironmentFile=-/etc/fjcloud/metering-env` | Metering service env contract file path | `ops/systemd/fj-metering-agent.service` | retain | |
| S1-A03 | `ops/terraform/tests_deploy_scripts_static.sh:77` | `/etc/fjcloud/metering-env` | Deploy path contains metering env contract path | `ops/scripts/deploy.sh` | retarget | `ops/user-data/bootstrap.sh` assertion seam via `ops/terraform/test_helpers.sh::assert_file_contains` |
| S1-A04 | `ops/terraform/tests_deploy_scripts_static.sh:78` | `aws s3 cp.*fj-metering-agent\.service` | Deploy downloads metering unit from release artifact | `ops/scripts/deploy.sh` | remove | |
| S1-A05 | `ops/terraform/tests_deploy_scripts_static.sh:79` | `install -m 0644.*fj-metering-agent\.service.*\/etc\/systemd\/system\/fj-metering-agent\.service` | Deploy installs metering unit on API host | `ops/scripts/deploy.sh` | remove | |
| S1-A06 | `ops/terraform/tests_deploy_scripts_static.sh:86` | `systemctl restart fj-metering-agent` | Deploy restarts metering agent on API host | `ops/scripts/deploy.sh` | remove | |
| S1-A07 | `ops/terraform/tests_deploy_scripts_static.sh:152` | `aws s3 cp.*fj-metering-agent\.service` | Rollback downloads metering unit from release artifact | `ops/scripts/rollback.sh` | remove | |
| S1-A08 | `ops/terraform/tests_deploy_scripts_static.sh:153` | `install -m 0644.*fj-metering-agent\.service.*\/etc\/systemd\/system\/fj-metering-agent\.service` | Rollback reinstalls metering unit on API host | `ops/scripts/rollback.sh` | remove | |
| S1-A09 | `ops/terraform/tests_deploy_scripts_static.sh:157` | `systemctl restart fj-metering-agent` | Rollback restarts metering agent on API host | `ops/scripts/rollback.sh` | remove | |
| S1-A10 | `ops/terraform/tests_deploy_scripts_static.sh:189` | `fjcloud-api fjcloud-aggregation-job fj-metering-agent` | Deploy binary set includes metering agent | `ops/scripts/deploy.sh` | retarget | `ops/user-data/bootstrap.sh` ownership seam; Stage 2 red tests should target bootstrap service lifecycle lines via `assert_file_contains` |
| S1-A11 | `ops/terraform/tests_deploy_scripts_static.sh:190` | `fjcloud-api fjcloud-aggregation-job fj-metering-agent` | Rollback binary set includes metering agent | `ops/scripts/rollback.sh` | remove | |
| S1-A12 | `ops/terraform/tests_stage5_static.sh:72` | `BINARIES=\(fjcloud-api fjcloud-aggregation-job fj-metering-agent\)` | Stage5 static contract pins deploy binary set incl. metering | `ops/scripts/deploy.sh` | retarget | `ops/user-data/bootstrap.sh` seam; Stage5 deploy-binary assertion should stop owning metering binary membership |
| S1-A13 | `ops/terraform/tests_stage5_static.sh:74` | `systemctl restart fj-metering-agent` | Stage5 static contract pins deploy metering restart | `ops/scripts/deploy.sh` | remove | |
| S1-A14 | `ops/terraform/tests_stage5_static.sh:124` | `BINARIES=\(fjcloud-api fjcloud-aggregation-job fj-metering-agent\)` | Stage5 static contract pins rollback binary set incl. metering | `ops/scripts/rollback.sh` | remove | |
| S1-A15 | `ops/terraform/tests_stage5_static.sh:126` | `systemctl restart fj-metering-agent` | Stage5 static contract pins rollback metering restart | `ops/scripts/rollback.sh` | remove | |
| S1-A16 | `scripts/tests/ci_workflow_test.sh:331` | `aws s3 cp infra/fj-metering-agent s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fj-metering-agent` | CI publishes metering-agent binary artifact keyed by SHA | `.github/workflows/ci.yml` deploy-staging job | retain | |
| S1-A17 | `scripts/tests/ci_workflow_test.sh:336` | `aws s3 cp ops/systemd/fj-metering-agent\.service s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/systemd/fj-metering-agent\.service` | CI publishes metering-agent unit artifact keyed by SHA | `.github/workflows/ci.yml` deploy-staging job | retain | |

## De-duplication and Single-Owner Check
- 17 assertion rows captured.
- 0 merged rows.
- Every row has exactly one current owner.

## Ownership Boundary Confirmation
- Customer-VM bootstrap owner is `ops/user-data/bootstrap.sh`:
  - writes `/etc/fjcloud/metering-env` (`ops/user-data/bootstrap.sh:119`)
  - enables/starts `flapjack` and `fj-metering-agent` (`ops/user-data/bootstrap.sh:145-146`)
- API deploy/rollback owner today is explicit and separate:
  - deploy metering handling in `ops/scripts/deploy.sh` (`BINARIES`, unit install, enable/restart at lines `127`, `154-157`, `200`)
  - rollback metering handling in `ops/scripts/rollback.sh` (`BINARIES`, unit install, enable/restart at lines `73`, `88-91`, `109`)

## Stage 3 Removal Map (exact sections)
- `ops/scripts/deploy.sh`:
  - `BINARIES=(fjcloud-api fjcloud-aggregation-job fj-metering-agent)`
  - unit copy/install + `systemctl enable fj-metering-agent`
  - `systemctl restart fj-metering-agent` in both success and rollback paths
  - metering-env validation branch (`METERING_ENV_FILE=/etc/fjcloud/metering-env` and conditional checks)
- `ops/scripts/rollback.sh`:
  - `BINARIES=(fjcloud-api fjcloud-aggregation-job fj-metering-agent)`
  - unit copy/install + `systemctl enable fj-metering-agent`
  - `systemctl restart fj-metering-agent` in both success and restore paths

## Unit-File Contract Cross-check
- Test assertions in `ops/terraform/tests_stage3_static.sh:157-158` match real unit file lines:
  - `ConditionPathExists=/etc/fjcloud/metering-env` (`ops/systemd/fj-metering-agent.service:6`)
  - `EnvironmentFile=-/etc/fjcloud/metering-env` (`ops/systemd/fj-metering-agent.service:13`)
- These unit-file assertions remain `retain` and keep ownership at `ops/systemd/fj-metering-agent.service`.

## Stage 2-Ready Backlog (for red-test authoring)
| target_file | assertion helper | regex/text |
|---|---|---|
| `ops/terraform/tests_stage3_static.sh` (or stage-specific successor) | `assert_file_contains` | `ConditionPathExists=/etc/fjcloud/metering-env` |
| `ops/terraform/tests_stage3_static.sh` (or stage-specific successor) | `assert_file_contains` | `EnvironmentFile=-/etc/fjcloud/metering-env` |
| `ops/terraform/tests_deploy_scripts_static.sh` | `assert_file_contains` | `/etc/fjcloud/metering-env` (retarget from deploy contract to bootstrap owner assertions) |
| `scripts/tests/ci_workflow_test.sh` | `assert_job_contains_regex` | `aws s3 cp infra/fj-metering-agent ...` |
| `scripts/tests/ci_workflow_test.sh` | `assert_job_contains_regex` | `aws s3 cp ops/systemd/fj-metering-agent\.service ...` |

## Guardrails for Stage 2
- Stage 2 adds failing assertions only; no deploy/rollback behavior edits.

## Open Questions
- Should `ops/terraform/tests_stage5_static.sh` continue to own any metering-specific deploy/rollback assertions once Stage 3 removal lands, or should all metering runtime ownership be concentrated in bootstrap + systemd static contracts?
- Should a dedicated static test be added for `ops/user-data/bootstrap.sh` metering lifecycle ownership, or should ownership be folded into an existing static test file?

## Sources
- `ops/terraform/tests_stage3_static.sh`
- `ops/terraform/tests_deploy_scripts_static.sh`
- `ops/terraform/tests_stage5_static.sh`
- `scripts/tests/ci_workflow_test.sh`
- `ops/user-data/bootstrap.sh`
- `ops/scripts/deploy.sh`
- `ops/scripts/rollback.sh`
- `ops/systemd/fj-metering-agent.service`
- Baseline command logs in this artifact directory.
