/**
 * k6 Load Test: Index CRUD
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - Test user exists with valid JWT (set via JWT env var or use setup)
 *   - At least one deployment running (for proxy operations)
 *
 * Run:
 *   k6 run --env JWT=<token> tests/load/index-crud.js
 *   k6 run --env BASE_URL=https://api.flapjack.foo --env JWT=<token> tests/load/index-crud.js
 *
 * Interpreting results:
 *   - Local signoff targets assume the debug local stack, not production tuning.
 *   - create_index p(95) should be < 700ms (includes proxy to flapjack)
 *   - list_indexes p(95) should be < 100ms
 *   - get_index p(95) should be < 400ms
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const JWT = __ENV.JWT || '';
const CREATE_INDEX_P95_MS = Number(__ENV.INDEX_CREATE_P95_MS || '700');
const LIST_INDEXES_P95_MS = Number(__ENV.LIST_INDEXES_P95_MS || '100');
const GET_INDEX_P95_MS = Number(__ENV.GET_INDEX_P95_MS || '400');

export const options = {
	stages: [
		{ duration: '30s', target: 20 },
		{ duration: '3m', target: 40 },
		{ duration: '30s', target: 0 },
	],
	thresholds: {
		'http_req_duration{action:create_index}': [`p(95)<${CREATE_INDEX_P95_MS}`],
		'http_req_duration{action:list_indexes}': [`p(95)<${LIST_INDEXES_P95_MS}`],
		'http_req_duration{action:get_index}': [`p(95)<${GET_INDEX_P95_MS}`],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const authHeaders = {
		'Content-Type': 'application/json',
		'Authorization': `Bearer ${JWT}`,
	};

	const indexName = `loadtest-${randomString(8)}`;

	// List indexes
	const listRes = http.get(`${BASE_URL}/indexes`, {
		headers: authHeaders,
		tags: { action: 'list_indexes', name: 'GET /indexes' },
	});

	check(listRes, {
		'list indexes returns 200': (r) => r.status === 200,
	});

	// Create index
	const createRes = http.post(`${BASE_URL}/indexes`, JSON.stringify({
		name: indexName,
		region: 'us-east-1',
	}), {
		headers: authHeaders,
		tags: { action: 'create_index', name: 'POST /indexes' },
	});

	check(createRes, {
		'create index returns 2xx': (r) => r.status >= 200 && r.status < 300,
	});

	if (createRes.status >= 200 && createRes.status < 300) {
		// Get index detail
		const getRes = http.get(`${BASE_URL}/indexes/${indexName}`, {
			headers: authHeaders,
			tags: { action: 'get_index', name: 'GET /indexes/:name' },
		});

		check(getRes, {
			'get index returns 200': (r) => r.status === 200,
		});

		// Get index settings
		const settingsRes = http.get(`${BASE_URL}/indexes/${indexName}/settings`, {
			headers: authHeaders,
			tags: { action: 'get_index', name: 'GET /indexes/:name/settings' },
		});

		check(settingsRes, {
			'get settings returns 200': (r) => r.status === 200,
		});

		// Delete index
		const deleteRes = http.del(`${BASE_URL}/indexes/${indexName}`, JSON.stringify({
			confirm: true,
		}), {
			headers: authHeaders,
			tags: { action: 'delete_index', name: 'DELETE /indexes/:name' },
		});

		check(deleteRes, {
			'delete index returns 2xx': (r) => r.status >= 200 && r.status < 300,
		});
	}

	sleep(2);
}
