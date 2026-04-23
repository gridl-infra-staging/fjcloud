/**
 * k6 Load Test: Auth Flow
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - PostgreSQL database with migrations applied
 *
 * Run:
 *   k6 run tests/load/auth-flow.js
 *   k6 run --env BASE_URL=https://api.flapjack.foo tests/load/auth-flow.js
 *
 * Interpreting results:
 *   - http_req_duration p(95) should be < 200ms
 *   - http_req_failed rate should be < 1% (excludes expected 4xx)
 *   - Checks should be near 100%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';

export const options = {
	stages: [
		{ duration: '30s', target: 50 },   // ramp up
		{ duration: '4m', target: 100 },    // steady state
		{ duration: '30s', target: 0 },     // ramp down
	],
	thresholds: {
		http_req_duration: ['p(95)<200'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const uniqueId = randomString(8);
	const email = `loadtest-${uniqueId}@example.com`;
	const password = 'LoadTest123!';

	// Register
	const registerRes = http.post(`${BASE_URL}/auth/register`, JSON.stringify({
		email: email,
		password: password,
		name: `Load Test User ${uniqueId}`,
	}), { headers: { 'Content-Type': 'application/json' } });

	check(registerRes, {
		'register returns 2xx': (r) => r.status >= 200 && r.status < 300,
	});

	// Login
	const loginRes = http.post(`${BASE_URL}/auth/login`, JSON.stringify({
		email: email,
		password: password,
	}), { headers: { 'Content-Type': 'application/json' } });

	check(loginRes, {
		'login returns 200': (r) => r.status === 200,
		'login returns JWT': (r) => {
			try {
				const body = JSON.parse(r.body);
				return body.token && body.token.length > 0;
			} catch {
				return false;
			}
		},
	});

	if (loginRes.status === 200) {
		const token = JSON.parse(loginRes.body).token;
		const authHeaders = {
			'Content-Type': 'application/json',
			'Authorization': `Bearer ${token}`,
		};

		// Authenticated request: get profile
		const profileRes = http.get(`${BASE_URL}/account/profile`, {
			headers: authHeaders,
		});

		check(profileRes, {
			'profile returns 200': (r) => r.status === 200,
		});

		// Authenticated request: billing estimate
		const estimateRes = http.get(`${BASE_URL}/billing/estimate`, {
			headers: authHeaders,
		});

		check(estimateRes, {
			'billing estimate returns 200': (r) => r.status === 200,
		});
	}

	sleep(1);
}
