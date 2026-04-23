/**
 * k6 Load Test: Health
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *
 * Run:
 *   k6 run tests/load/health.js
 *   k6 run --env BASE_URL=http://localhost:3001 tests/load/health.js
 *
 * Interpreting results:
 *   - http_req_duration p(95) should be < 200ms
 *   - http_req_failed rate should be < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';

export const options = {
	stages: [
		{ duration: '15s', target: 10 },
		{ duration: '30s', target: 20 },
		{ duration: '15s', target: 0 },
	],
	thresholds: {
		http_req_duration: ['p(95)<200'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const res = http.get(`${BASE_URL}/health`);

	check(res, {
		'health returns 200': (r) => r.status === 200,
		'health reports ok': (r) => {
			try {
				const parsed = JSON.parse(r.body);
				return parsed.status === 'ok';
			} catch {
				return false;
			}
		},
	});

	sleep(1);
}
