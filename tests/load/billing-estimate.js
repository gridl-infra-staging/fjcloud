/**
 * k6 Load Test: Billing Estimate
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - Test user with valid JWT (set via JWT env var)
 *   - Usage data seeded for the test user
 *
 * Run:
 *   k6 run --env JWT=<token> tests/load/billing-estimate.js
 *
 * Interpreting results:
 *   - http_req_duration p(95) should be < 100ms
 *   - http_req_failed rate should be < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const JWT = __ENV.JWT || '';

export const options = {
	stages: [
		{ duration: '30s', target: 100 },
		{ duration: '2m', target: 200 },
		{ duration: '30s', target: 0 },
	],
	thresholds: {
		http_req_duration: ['p(95)<100'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const res = http.get(`${BASE_URL}/billing/estimate`, {
		headers: {
			'Authorization': `Bearer ${JWT}`,
		},
	});

	check(res, {
		'billing estimate returns 200': (r) => r.status === 200,
		'response has amount field': (r) => {
			try {
				const body = JSON.parse(r.body);
				return body.total_amount !== undefined || body.estimate !== undefined;
			} catch {
				return false;
			}
		},
	});

	sleep(0.5);
}
