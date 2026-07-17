/**
 * k6 Load Test: Document Ingestion
 *
 * Write workload against a pre-provisioned ready index.
 * Exercises POST /indexes/:name/batch (BatchDocumentsRequest) and
 * DELETE /indexes/:name/objects/:object_id from
 * infra/api/src/routes/indexes/documents.rs.
 *
 * Prerequisites:
 *   - k6 installed (https://k6.io/docs/get-started/installation/)
 *   - API running at BASE_URL (default: http://localhost:3001)
 *   - Test user with valid JWT (set via JWT env var)
 *   - A ready index exists (set via INDEX_NAME env var)
 *
 * Run:
 *   k6 run --env JWT=<token> --env INDEX_NAME=my-index tests/load/document-ingestion.js
 *
 * Interpreting results:
 *   - Local signoff targets assume the debug local stack, not production tuning.
 *   - batch_add p(95) should be < 600ms
 *   - delete_object p(95) should be < 2000ms
 *   - http_req_failed rate should be < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';
const JWT = __ENV.JWT || '';
const INDEX_NAME = __ENV.INDEX_NAME || '';

export const options = {
	stages: [
		{ duration: '15s', target: 5 },
		{ duration: '2m', target: 15 },
		{ duration: '15s', target: 0 },
	],
	thresholds: {
		'http_req_duration{action:batch_add}': ['p(95)<600'],
		'http_req_duration{action:delete_object}': ['p(95)<2000'],
		http_req_failed: ['rate<0.01'],
	},
};

export default function () {
	const headers = {
		'Content-Type': 'application/json',
		'Authorization': `Bearer ${JWT}`,
	};

	// Keep per-iteration fixture IDs together so write and cleanup stay in sync.
	const objectIds = [
		`loadtest-${__VU}-${__ITER}-1`,
		`loadtest-${__VU}-${__ITER}-2`,
	];

	// BatchDocumentsRequest contract (camelCase, deny_unknown_fields):
	//   { requests: [{ action, body?, indexName?, createIfNotExists? }] }
	// Payload shape from infra/api/tests/indexes_test.rs
	const batchBody = JSON.stringify({
		requests: objectIds.map((objectID, index) => ({
			action: 'addObject',
			body: { objectID, title: `Load test doc ${index + 1}` },
		})),
	});

	const batchRes = http.post(
		`${BASE_URL}/indexes/${INDEX_NAME}/batch`,
		batchBody,
		{ headers, tags: { action: 'batch_add', name: 'POST /indexes/:name/batch' } },
	);

	check(batchRes, {
		'batch returns 2xx': (r) => r.status >= 200 && r.status < 300,
	});

	// Clean up every created document so repeated runs do not grow the index.
	for (const objectID of objectIds) {
		const deleteRes = http.del(
			`${BASE_URL}/indexes/${INDEX_NAME}/objects/${objectID}`,
			null,
			{
				headers,
				tags: { action: 'delete_object', name: 'DELETE /indexes/:name/objects/:object_id' },
			},
		);

		check(deleteRes, {
			'delete returns 2xx': (r) => r.status >= 200 && r.status < 300,
		});
	}

	sleep(1);
}
