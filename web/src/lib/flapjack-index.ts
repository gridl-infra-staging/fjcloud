export function buildTenantScopedIndexUid(customerId: string, indexName: string): string {
	return `${customerId.replace(/-/g, '').toLowerCase()}_${indexName}`;
}
