/**
 * k6 Load Test: Admin Fleet Overview
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - ADMIN_KEY env var set
 *   - Database seeded with 100+ deployments for realistic load
 *
 * Run:
 *   k6 run --env ADMIN_KEY=<key> tests/load/admin-fleet.js
 *
 * Interpreting results:
 *   - Local signoff targets assume the debug local stack, not production tuning.
 *   - http_req_duration p(95) should be < 1200ms with 100+ deployments
 *   - http_req_failed rate should be < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const ADMIN_KEY = __ENV.ADMIN_KEY || '';

export const options = {
	stages: [
		{ duration: '15s', target: 5 },
		{ duration: '90s', target: 10 },
		{ duration: '15s', target: 0 },
	],
	thresholds: {
		http_req_duration: ['p(95)<1200'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const headers = {
		'X-Admin-Key': ADMIN_KEY,
	};

	// Fleet overview
	const fleetRes = http.get(`${BASE_URL}/admin/fleet`, { headers });

	check(fleetRes, {
		'fleet returns 200': (r) => r.status === 200,
		'fleet returns array': (r) => {
			try {
				return Array.isArray(JSON.parse(r.body));
			} catch {
				return false;
			}
		},
	});

	// Tenant list
	const tenantsRes = http.get(`${BASE_URL}/admin/tenants`, { headers });

	check(tenantsRes, {
		'tenants returns 200': (r) => r.status === 200,
	});

	// Recent alerts
	const alertsRes = http.get(`${BASE_URL}/admin/alerts?limit=50`, { headers });

	check(alertsRes, {
		'alerts returns 200': (r) => r.status === 200,
	});

	sleep(3);
}
