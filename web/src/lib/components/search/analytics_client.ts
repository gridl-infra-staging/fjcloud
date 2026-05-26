export type SearchPreviewEvent = {
	type: string;
	query: string;
	indexName: string;
	metadata: Record<string, unknown>;
};

export async function postSearchPreviewEvent(
	endpoint: string,
	apiKey: string,
	event: SearchPreviewEvent
): Promise<void> {
	const eventsUrl = `${endpoint.replace(/\/+$/, '')}/1/events`;

	// Search preview analytics go directly to the Flapjack engine endpoint.
	// Reusing dashboard API clients here would duplicate API-layer concerns.
	const response = await fetch(eventsUrl, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${apiKey}`
		},
		body: JSON.stringify(event)
	});

	if (!response.ok) {
		throw new Error(`Search preview analytics failed: ${response.status}`);
	}
}
