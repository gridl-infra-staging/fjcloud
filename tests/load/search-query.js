/**
 * k6 Load Test: Search Query
 *
 * Read-only workload against a pre-provisioned ready index.
 * Exercises POST /indexes/:name/search with the SearchRequest contract
 * from infra/api/src/routes/indexes/search.rs.
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - Test user with valid JWT (set via JWT env var)
 *   - A ready index exists (set via INDEX_NAME env var)
 *
 * Run:
 *   k6 run --env JWT=<token> --env INDEX_NAME=my-index tests/load/search-query.js
 *
 * Interpreting results:
 *   - search p(95) should be < 200ms
 *   - http_req_failed rate should be < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const JWT = __ENV.JWT || '';
const INDEX_NAME = __ENV.INDEX_NAME || '';

// Sample queries rotated across VUs for realistic variation
const QUERIES = ['hello', 'world', 'test', 'search', 'product', 'item'];

export const options = {
	stages: [
		{ duration: '15s', target: 10 },
		{ duration: '2m', target: 30 },
		{ duration: '15s', target: 0 },
	],
	thresholds: {
		'http_req_duration{action:search}': ['p(95)<200'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const headers = {
		'Content-Type': 'application/json',
		'Authorization': `Bearer ${JWT}`,
	};

	// Pick a query string — rotate by VU iteration for variation
	const query = QUERIES[__ITER % QUERIES.length];

	// SearchRequest contract: { query: string, ...extra }
	// Minimal valid payload per infra/api/src/routes/indexes/mod.rs:67
	const body = JSON.stringify({ query });

	const res = http.post(`${BASE_URL}/indexes/${INDEX_NAME}/search`, body, {
		headers,
		tags: { action: 'search' },
	});

	check(res, {
		'search returns 200': (r) => r.status === 200,
		'response has hits': (r) => {
			try {
				const parsed = JSON.parse(r.body);
				return parsed.hits !== undefined;
			} catch {
				return false;
			}
		},
	});

	sleep(1);
}
