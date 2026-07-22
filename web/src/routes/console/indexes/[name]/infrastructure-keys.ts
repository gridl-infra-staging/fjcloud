/** Canonical dependency key for index-detail Infrastructure payload invalidation. */
export function infrastructureDependencyKey(indexName: string): string {
	return `app:index-infrastructure:${indexName}`;
}
