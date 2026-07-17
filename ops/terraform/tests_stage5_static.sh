#!/usr/bin/env bash
# Static validation tests for Stage 5: Deploy & Migration Scripts
# TDD: these tests define the contract; scripts must satisfy them.
# Run from the repo root: bash ops/terraform/tests_stage5_static.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

# Shell-script comment stripper (# comments only, no block comments).
strip_shell_comments() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print }
  ' "$file"
}

check_contains_active() {
  local file="$1" pattern="$2" desc="$3"
  if strip_shell_comments "$file" | rg -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc (pattern: $pattern)"
  fi
}

check_not_contains_active() {
  local file="$1" pattern="$2" desc="$3"
  if strip_shell_comments "$file" | rg -q "$pattern"; then
    fail "$desc (pattern found but should not be: $pattern)"
  else
    pass "$desc"
  fi
}

assert_executable() {
  local file="$1"
  if [[ -x "$file" ]]; then
    pass "$file is executable"
  else
    fail "$file is not executable"
  fi
}

echo ""
echo "=== Stage 5 Static Tests: Deploy & Migration Scripts ==="
echo ""

# -----------------------------------------------------------------------
# deploy.sh
# -----------------------------------------------------------------------
DEPLOY="ops/scripts/deploy.sh"
echo "--- deploy.sh ---"
assert_file_exists      "$DEPLOY" "$DEPLOY exists"
assert_executable       "$DEPLOY"
assert_file_contains    "$DEPLOY" '^#!/usr/bin/env bash'                "deploy.sh: shebang is #!/usr/bin/env bash"
check_contains_active   "$DEPLOY" 'set -euo pipefail'                  "deploy.sh: set -euo pipefail"
check_contains_active   "$DEPLOY" 'Usage:'                             "deploy.sh: usage message"
check_contains_active   "$DEPLOY" '\$#'                                "deploy.sh: argument count check"
check_contains_active   "$DEPLOY" '"\$ENV" != "staging" && "\$ENV" != "prod"' \
  "deploy.sh: validates env is staging or prod"
check_contains_active   "$DEPLOY" '\[\[ ! "\$SHA" =~ \^\[0-9a-f\]\{40\}\$ \]\]' \
  "deploy.sh: validates SHA format (40 lowercase hex chars)"
check_contains_active   "$DEPLOY" 'fjcloud-releases'                   "deploy.sh: S3 releases bucket name"
check_contains_active   "$DEPLOY" 'fjcloud-api-'                       "deploy.sh: instance tag name prefix"
check_contains_active   "$DEPLOY" 'describe-instances'                 "deploy.sh: EC2 instance discovery via tags"
check_contains_active   "$DEPLOY" 'ssm send-command'                   "deploy.sh: uses SSM send-command (no SSH)"
check_contains_active   "$DEPLOY" 'AWS-RunShellScript'                 "deploy.sh: SSM RunShellScript document"
check_contains_active   "$DEPLOY" 'migrate\.sh'                        "deploy.sh: calls migrate.sh"
# Replaces the former three-binary assertion: metering-agent lifecycle now
# belongs only to customer flapjack VMs via bootstrap.sh.
check_contains_active   "$DEPLOY" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job\)' \
  "deploy.sh: target contract expects exactly two API-host binaries"
check_not_contains_active "$DEPLOY" 'systemctl restart fj-metering-agent' \
  "deploy.sh: target contract must not restart fj-metering-agent on API host"
check_contains_active   "$DEPLOY" '/health'                            "deploy.sh: health check endpoint"
check_contains_active   "$DEPLOY" '127\.0\.0\.1:3001'                 "deploy.sh: health check on port 3001"
check_contains_active   "$DEPLOY" 'last_deploy_sha'                    "deploy.sh: saves previous SHA for rollback"
check_contains_active   "$DEPLOY" 'delete-parameter'                   "deploy.sh: deletes last_deploy_sha on first-deploy failure"
check_not_contains_active "$DEPLOY" 'AWS_ACCESS_KEY_ID\s*='            "deploy.sh: no hardcoded AWS credentials"
check_not_contains_active "$DEPLOY" 'AWS_SECRET_ACCESS_KEY\s*='        "deploy.sh: no hardcoded AWS secret key"

echo ""

# -----------------------------------------------------------------------
# migrate.sh
# -----------------------------------------------------------------------
MIGRATE="ops/scripts/migrate.sh"
echo "--- migrate.sh ---"
assert_file_exists      "$MIGRATE" "$MIGRATE exists"
assert_executable       "$MIGRATE"
assert_file_contains    "$MIGRATE" '^#!/usr/bin/env bash'               "migrate.sh: shebang is #!/usr/bin/env bash"
check_contains_active   "$MIGRATE" 'set -euo pipefail'                 "migrate.sh: set -euo pipefail"
check_contains_active   "$MIGRATE" '"\$ENV" != "staging" && "\$ENV" != "prod"' \
  "migrate.sh: validates env is staging or prod"
check_contains_active   "$MIGRATE" 'ssm get-parameter'                 "migrate.sh: fetches DATABASE_URL from SSM"
check_contains_active   "$MIGRATE" 'with-decryption'                   "migrate.sh: uses --with-decryption for SSM"
check_contains_active   "$MIGRATE" 'database_url'                      "migrate.sh: reads database_url from SSM"
check_contains_active   "$MIGRATE" 'sqlx migrate run'                  "migrate.sh: runs sqlx migrate run"
check_contains_active   "$MIGRATE" 'DATABASE_URL'                      "migrate.sh: passes DATABASE_URL to sqlx"
check_contains_active   "$MIGRATE" '\-\-source'                        "migrate.sh: passes --source dir to sqlx"
check_not_contains_active "$MIGRATE" 'postgres://.*:.*@'               "migrate.sh: no hardcoded database credentials"

echo ""

# -----------------------------------------------------------------------
# rollback.sh
# -----------------------------------------------------------------------
ROLLBACK="ops/scripts/rollback.sh"
echo "--- rollback.sh ---"
assert_file_exists      "$ROLLBACK" "$ROLLBACK exists"
assert_executable       "$ROLLBACK"
assert_file_contains    "$ROLLBACK" '^#!/usr/bin/env bash'              "rollback.sh: shebang is #!/usr/bin/env bash"
check_contains_active   "$ROLLBACK" 'set -euo pipefail'                "rollback.sh: set -euo pipefail"
check_contains_active   "$ROLLBACK" 'Usage:'                           "rollback.sh: usage message"
check_contains_active   "$ROLLBACK" '\$#'                              "rollback.sh: argument count check"
check_contains_active   "$ROLLBACK" '"\$ENV" != "staging" && "\$ENV" != "prod"' \
  "rollback.sh: validates env is staging or prod"
check_contains_active   "$ROLLBACK" '\[\[ ! "\$SHA" =~ \^\[0-9a-f\]\{40\}\$ \]\]' \
  "rollback.sh: validates SHA format (40 lowercase hex chars)"
check_contains_active   "$ROLLBACK" 'fjcloud-releases'                 "rollback.sh: S3 releases bucket name"
check_contains_active   "$ROLLBACK" 'describe-instances'               "rollback.sh: EC2 instance discovery via tags"
check_contains_active   "$ROLLBACK" 'ssm send-command'                 "rollback.sh: uses SSM send-command"
# Replaces the former three-binary assertion: metering-agent lifecycle now
# belongs only to customer flapjack VMs via bootstrap.sh.
check_contains_active   "$ROLLBACK" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job\)' \
  "rollback.sh: target contract expects exactly two API-host binaries"
check_not_contains_active "$ROLLBACK" 'systemctl restart fj-metering-agent' \
  "rollback.sh: target contract must not restart fj-metering-agent on API host"
check_contains_active   "$ROLLBACK" '/health'                          "rollback.sh: health check endpoint"
check_not_contains_active "$ROLLBACK" 'migrate\.sh'                    "rollback.sh: does NOT call migrate.sh"
check_not_contains_active "$ROLLBACK" 'AWS_ACCESS_KEY_ID\s*='          "rollback.sh: no hardcoded AWS credentials"

echo ""

# -----------------------------------------------------------------------
# BOOTSTRAP.md Stage 5 documentation
# -----------------------------------------------------------------------
BOOTSTRAP="ops/BOOTSTRAP.md"
echo "--- BOOTSTRAP.md ---"
assert_file_exists      "$BOOTSTRAP" "$BOOTSTRAP exists"
assert_file_contains    "$BOOTSTRAP" 'fjcloud-releases'                "BOOTSTRAP.md: S3 releases bucket documented"
assert_file_contains    "$BOOTSTRAP" 'sqlx'                            "BOOTSTRAP.md: sqlx-cli prerequisite documented"

echo ""

# -----------------------------------------------------------------------
# Packer AMI prerequisites for deploy/migrate runtime
# -----------------------------------------------------------------------
PACKER_AMI="ops/packer/flapjack-ami.pkr.hcl"
echo "--- flapjack-ami.pkr.hcl ---"
assert_file_exists      "$PACKER_AMI" "$PACKER_AMI exists"
assert_file_contains    "$PACKER_AMI" 'dnf install -y aws-cli jq gcc cargo' \
  "packer: installs gcc + cargo toolchain prerequisites for sqlx build"
assert_file_contains    "$PACKER_AMI" 'cargo install sqlx-cli --version 0\.8\.3 --no-default-features --features postgres,rustls' \
  "packer: installs pinned sqlx-cli via cargo with postgres+rustls"
assert_file_contains    "$PACKER_AMI" '/usr/local/bin/sqlx'            "packer: places sqlx in /usr/local/bin"
check_not_contains_active "$PACKER_AMI" 'github\.com/launchbadge/sqlx/releases/download' \
  "packer: does not depend on non-existent sqlx release tarballs"
assert_file_contains    "$PACKER_AMI" '../systemd/fjcloud-api.service' "packer: copies fjcloud-api systemd unit"
assert_file_contains    "$PACKER_AMI" '../systemd/fjcloud-aggregation-job.service' \
  "packer: copies fjcloud aggregation-job service"
assert_file_contains    "$PACKER_AMI" '../systemd/fjcloud-aggregation-job.timer' \
  "packer: copies fjcloud aggregation-job timer"
assert_file_contains    "$PACKER_AMI" '/etc/systemd/system/fjcloud-api.service' \
  "packer: installs fjcloud-api systemd unit"
assert_file_contains    "$PACKER_AMI" '/etc/systemd/system/fjcloud-aggregation-job.service' \
  "packer: installs fjcloud aggregation-job service unit"
assert_file_contains    "$PACKER_AMI" '/etc/systemd/system/fjcloud-aggregation-job.timer' \
  "packer: installs fjcloud aggregation-job timer unit"
assert_file_contains    "$PACKER_AMI" 'systemctl enable fjcloud-api fjcloud-aggregation-job.timer' \
  "packer: enables fjcloud-api and aggregation timer"

echo ""

test_summary "Stage 5 static checks"
