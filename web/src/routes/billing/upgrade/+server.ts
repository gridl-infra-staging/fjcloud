import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
const UPGRADE_PROXY_UNAVAILABLE = 'billing_upgrade_unavailable';

export const POST: RequestHandler = async ({ locals, fetch }) => {
	if (!locals.user) {
		return json({ error: 'unauthorized' }, { status: 401 });
	}

	let upstreamResponse: Response;
	try {
		upstreamResponse = await fetch(`${locals.apiBaseUrl}/billing/upgrade`, {
			method: 'POST',
			headers: {
				Authorization: `Bearer ${locals.user.token}`,
				'Content-Type': 'application/json'
			},
			body: '{}'
		});
	} catch {
		return json({ error: UPGRADE_PROXY_UNAVAILABLE }, { status: 503 });
	}

	return new Response(await upstreamResponse.text(), {
		status: upstreamResponse.status,
		headers: {
			'Content-Type': upstreamResponse.headers.get('content-type') ?? 'application/json'
		}
	});
};
