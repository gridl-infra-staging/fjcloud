#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

script_file="ops/scripts/rds_restore_drill.sh"

echo ""
echo "=== RDS Restore Drill Static Tests ==="
echo ""

assert_file_exists "$script_file" "rds_restore_drill.sh exists"
assert_file_contains "$script_file" 'set -euo pipefail' "rds_restore_drill.sh uses strict mode"
assert_file_contains "$script_file" 'Usage: rds_restore_drill\.sh <env>' "rds_restore_drill.sh documents usage"
assert_file_contains "$script_file" '"staging" && "\$ENV" != "prod"' "rds_restore_drill.sh validates env is staging|prod"
assert_file_contains "$script_file" 'REGION=' "rds_restore_drill.sh sets explicit REGION assignment"
assert_file_contains "$script_file" 'RDS_RESTORE_DRILL_EXECUTE' "rds_restore_drill.sh uses canonical execute gate"
assert_file_contains "$script_file" '\-\-source-db-instance-id' "rds_restore_drill.sh supports source DB instance arg"
assert_file_contains "$script_file" '\-\-target-db-instance-id' "rds_restore_drill.sh supports target DB instance arg"
assert_file_contains "$script_file" '\-\-snapshot-id' "rds_restore_drill.sh supports snapshot restore selector"
assert_file_contains "$script_file" '\-\-restore-time' "rds_restore_drill.sh supports PITR restore selector"
assert_file_contains "$script_file" 'has_snapshot" == true && "\$has_restore_time" == true' "rds_restore_drill.sh rejects simultaneous snapshot and PITR selectors"
assert_file_contains "$script_file" 'has_snapshot" == false && "\$has_restore_time" == false' "rds_restore_drill.sh rejects missing restore selector"
assert_file_contains "$script_file" 'provide exactly one restore mode selector \(\-\-snapshot-id or \-\-restore-time\)' "rds_restore_drill.sh documents exactly-one restore selector contract"
assert_file_contains "$script_file" 'not supported because CLI arguments can leak secrets via process inspection' "rds_restore_drill.sh rejects password-bearing CLI args to avoid argv secret exposure"
assert_file_contains "$script_file" 'restore-db-instance-from-db-snapshot' "rds_restore_drill.sh wires snapshot restore API"
assert_file_contains "$script_file" 'restore-db-instance-to-point-in-time' "rds_restore_drill.sh wires PITR restore API"

assert_file_not_contains "$script_file" 'systemctl restart' "rds_restore_drill.sh never restarts services"
assert_file_not_contains "$script_file" 'aws ssm put-parameter' "rds_restore_drill.sh never mutates SSM parameters"
assert_file_not_contains "$script_file" 'DATABASE_URL=' "rds_restore_drill.sh never mutates DATABASE_URL"
assert_file_not_contains "$script_file" '\-\-execute' "rds_restore_drill.sh keeps env var as the only live-dispatch gate"

test_summary "RDS restore drill static checks"
