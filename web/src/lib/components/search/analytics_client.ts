/** Same-origin delivery for correlated search-preview analytics events. */
import type { PreviewEventRequest } from '$lib/api/types';

export type SearchPreviewEvent = Omit<PreviewEventRequest, 'timestamp'>;

const PREVIEW_SESSION_TOKEN_KEY = 'search_preview_analytics_token';

/** Return one non-PII token per browser tab so events can be correlated safely. */
export function getSearchPreviewSessionToken(): string {
	const existing = globalThis.sessionStorage?.getItem(PREVIEW_SESSION_TOKEN_KEY);
	if (existing) return existing;
	const token = `preview-${globalThis.crypto.randomUUID()}`;
	globalThis.sessionStorage?.setItem(PREVIEW_SESSION_TOKEN_KEY, token);
	return token;
}

/** Post one event through the authenticated control-plane route. */
export async function postSearchPreviewEvent(
	routeIndexName: string,
	event: SearchPreviewEvent
): Promise<void> {
	const response = await fetch(`/api/search/${encodeURIComponent(routeIndexName)}/events`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			...event,
			timestamp: Date.now()
		})
	});

	if (!response.ok) {
		throw new Error(`Search preview analytics failed: ${response.status}`);
	}
}
