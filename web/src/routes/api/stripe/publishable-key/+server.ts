import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { getApiBaseUrl } from '$lib/config';

export const GET: RequestHandler = async ({ locals }) => {
	if (!locals.user) {
		return json({ error: 'unauthorized' }, { status: 401 });
	}

	let upstreamResponse: Response;
	try {
		upstreamResponse = await globalThis.fetch(`${getApiBaseUrl()}/billing/publishable-key`, {
			method: 'GET',
			headers: {
				Authorization: `Bearer ${locals.user.token}`
			}
		});
	} catch {
		return json({ error: 'stripe_publishable_key_unavailable' }, { status: 503 });
	}

	return new Response(await upstreamResponse.text(), {
		status: upstreamResponse.status,
		headers: {
			'Content-Type': upstreamResponse.headers.get('content-type') ?? 'application/json'
		}
	});
};
