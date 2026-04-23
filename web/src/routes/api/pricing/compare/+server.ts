/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_1_frontend_test_suite/fjcloud_dev/web/src/routes/api/pricing/compare/+server.ts.
 */
import { json } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient, createCanonicalPublicApiClient } from '$lib/server/api';
import type { RequestHandler } from './$types';
import type { PricingCompareRequest } from '$lib/api/types';

function isNetworkFailure(error: unknown): boolean {
	// Node/undici reports failed fetches as TypeError. Keep the public fallback
	// narrow so programming errors or malformed response handling still fail
	// closed instead of being hidden by a second API request.
	return error instanceof TypeError;
}

export const POST: RequestHandler = async ({ request }) => {
	let workload: PricingCompareRequest;
	try {
		workload = (await request.json()) as PricingCompareRequest;
	} catch {
		return json({ error: 'invalid pricing compare payload' }, { status: 400 });
	}

	const api = createApiClient();
	const fallbackError = 'pricing compare failed';

	try {
		const response = await api.comparePricing(workload);
		return json(response);
	} catch (error) {
		if (isNetworkFailure(error)) {
			try {
				// The landing page is public and read-only. In web-only local
				// development the configured API often points at 127.0.0.1:3001,
				// which may not be running; use the canonical public API so the
				// calculator remains useful without booting the full backend stack.
				const response = await createCanonicalPublicApiClient().comparePricing(workload);
				return json(response);
			} catch {
				return json({ error: fallbackError }, { status: 500 });
			}
		}
		if (error instanceof ApiRequestError) {
			if (error.status >= 500) {
				return json({ error: fallbackError }, { status: error.status });
			}
			return json({ error: error.message }, { status: error.status });
		}
		return json({ error: fallbackError }, { status: 500 });
	}
};
