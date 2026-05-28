export type SearchPreviewEvent = {
	type: string;
	query: string;
	indexName: string;
	metadata: Record<string, unknown>;
};

type InsightsEvent = {
	eventType: 'click';
	eventName: string;
	index: string;
	userToken: string;
	objectIDs: string[];
	positions: number[];
	timestamp: number;
};

export async function postSearchPreviewEvent(
	endpoint: string,
	apiKey: string,
	event: SearchPreviewEvent
): Promise<void> {
	const eventsUrl = `${endpoint.replace(/\/+$/, '')}/1/events`;
	const objectID =
		typeof event.metadata.objectID === 'string' && event.metadata.objectID.length > 0
			? event.metadata.objectID
			: 'missing-object-id';
	const position =
		typeof event.metadata.position === 'number' && Number.isFinite(event.metadata.position)
			? Math.max(1, Math.floor(event.metadata.position))
			: 1;
	const insightsPayload: { events: [InsightsEvent] } = {
		events: [
			{
				eventType: 'click',
				eventName: event.type,
				index: event.indexName,
				userToken: 'search-preview',
				objectIDs: [objectID],
				positions: [position],
				timestamp: Date.now()
			}
		]
	};

	// Search preview analytics go directly to the Flapjack engine endpoint.
	// Reusing dashboard API clients here would duplicate API-layer concerns.
	const response = await fetch(eventsUrl, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'X-Algolia-API-Key': apiKey,
			'X-Algolia-Application-Id': 'flapjack',
			Authorization: `Bearer ${apiKey}`
		},
		body: JSON.stringify(insightsPayload)
	});

	if (!response.ok) {
		throw new Error(`Search preview analytics failed: ${response.status}`);
	}
}
