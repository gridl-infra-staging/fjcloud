import { json } from '@sveltejs/kit';

// Public health endpoint for outside-AWS health probes
// (scripts/canary/outside_aws_health_check.sh, external monitoring).
// Returns 200 with a small JSON payload so probes can verify both
// connectivity and a parseable response without depending on
// internal admin endpoints.
export const GET = () => json({ status: 'ok', service: 'fjcloud-web' });
