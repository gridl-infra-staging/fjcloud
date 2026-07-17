export function buildAddObjectBatchPayload(records: Record<string, unknown>[]): string {
	return JSON.stringify({
		requests: records.map((record) => ({
			action: 'addObject',
			body: record
		}))
	});
}
