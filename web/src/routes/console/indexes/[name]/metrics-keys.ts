/**
 * Canonical dependency key for index-detail metrics SSR payload invalidation.
 * Keeping this in one helper prevents route/component key drift.
 */
export function metricsDependencyKey(indexName: string): string {
	return `app:index-metrics:${indexName}`;
}
