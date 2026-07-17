/**
 * k6 Spike Test: Sudden Traffic Burst
 *
 * Simulates a sudden spike in traffic (e.g., Hacker News effect).
 * Ramps from 10 to 500 concurrent users in 30 seconds, holds for 1 minute,
 * then drops back to 10.
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - Test user with valid JWT (set via JWT env var)
 *   - Database seeded with indexes and usage data
 *
 * Run:
 *   k6 run --env JWT=<token> tests/load/spike-test.js
 *
 * Interpreting results:
 *   - Error rate should be < 5% during spike
 *   - http_req_duration p(99) should be < 2s
 *   - No 502/503 errors after spike subsides
 *   - Check "post_spike_healthy" rate is 100%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const JWT = __ENV.JWT || '';

const postSpikeHealthy = new Rate('post_spike_healthy');

export const options = {
	stages: [
		{ duration: '15s', target: 10 },     // baseline
		{ duration: '30s', target: 500 },     // spike up
		{ duration: '1m', target: 500 },      // hold spike
		{ duration: '30s', target: 10 },      // spike down
		{ duration: '1m', target: 10 },       // recovery (monitor for errors)
	],
	thresholds: {
		http_req_failed: ['rate<0.05'],
		http_req_duration: ['p(99)<2000'],
	},
};

export default function () {
	const headers = {
		'Authorization': `Bearer ${JWT}`,
		'Content-Type': 'application/json',
	};

	// Mix of realistic requests weighted by frequency
	const rand = Math.random();

	if (rand < 0.4) {
		// 40%: List indexes (most common read)
		const res = http.get(`${BASE_URL}/indexes`, { headers });
		check(res, {
			'list indexes ok': (r) => r.status === 200 || r.status === 429,
		});
		postSpikeHealthy.add(res.status !== 502 && res.status !== 503);
	} else if (rand < 0.7) {
		// 30%: Billing estimate
		const res = http.get(`${BASE_URL}/billing/estimate`, { headers });
		check(res, {
			'billing estimate ok': (r) => r.status === 200 || r.status === 429,
		});
		postSpikeHealthy.add(res.status !== 502 && res.status !== 503);
	} else if (rand < 0.85) {
		// 15%: Usage data
		const res = http.get(`${BASE_URL}/usage`, { headers });
		check(res, {
			'usage ok': (r) => r.status === 200 || r.status === 429,
		});
		postSpikeHealthy.add(res.status !== 502 && res.status !== 503);
	} else if (rand < 0.95) {
		// 10%: Profile
		const res = http.get(`${BASE_URL}/account/profile`, { headers });
		check(res, {
			'profile ok': (r) => r.status === 200 || r.status === 429,
		});
		postSpikeHealthy.add(res.status !== 502 && res.status !== 503);
	} else {
		// 5%: Health check (public, no auth)
		const res = http.get(`${BASE_URL}/health`);
		check(res, {
			'health ok': (r) => r.status === 200,
		});
		postSpikeHealthy.add(res.status !== 502 && res.status !== 503);
	}

	sleep(0.1);
}
