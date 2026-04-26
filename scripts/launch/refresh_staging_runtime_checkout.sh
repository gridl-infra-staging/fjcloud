#!/usr/bin/env bash
# refresh_staging_runtime_checkout.sh — clone the latest staging mirror
# commit into /opt/fjcloud-runtime-fix/<sha>/src on the staging EC2 host
# so subsequent SSM-driven operator commands (the staging billing
# rehearsal, in particular) run against the most-recent code rather than
# whatever stale checkout was last left in /opt/fjcloud-runtime-fix.
#
# Convention: the deploy.sh path only refreshes the API binary +
# migrate.sh + generate_ssm_env.sh. Operator scripts (staging billing
# rehearsal, validate-stripe, the synthetic-traffic seeder, etc.) live
# under /opt/fjcloud-runtime-fix/<sha>/src/scripts/ and need a manual
# clone refresh whenever you want them to match `main` of the public
# staging mirror.
#
# Usage:
#   set -a; source .secret/.env.secret; set +a
#   bash scripts/launch/refresh_staging_runtime_checkout.sh
#
# Effect: clones https://github.com/gridl-infra-staging/fjcloud at the
# remote HEAD, places it at /opt/fjcloud-runtime-fix/<short-sha>/src/,
# and prints the resulting path so the caller can pin it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING_REPO_URL="${STAGING_RUNTIME_GIT_URL:-https://github.com/gridl-infra-staging/fjcloud.git}"

REMOTE_CMD=$(cat <<EOF
set -euo pipefail
TMPDIR=\$(mktemp -d)
echo "==> cloning ${STAGING_REPO_URL} into \$TMPDIR"
git clone --depth 1 ${STAGING_REPO_URL} "\$TMPDIR/fjcloud"
cd "\$TMPDIR/fjcloud"
SHA=\$(git rev-parse HEAD)
SHORT_SHA=\${SHA:0:40}
TARGET="/opt/fjcloud-runtime-fix/\${SHORT_SHA}/src"
echo "==> staging at \$TARGET"
mkdir -p "\$(dirname \$TARGET)"
rm -rf "\$TARGET"
mkdir -p "\$TARGET"
cp -R . "\$TARGET/"
cd /
rm -rf "\$TMPDIR"
echo "REFRESHED_RUNTIME_PATH=\$TARGET"
EOF
)

echo "==> dispatching git clone via SSM..."
bash "$SCRIPT_DIR/ssm_exec_staging.sh" "$REMOTE_CMD"
