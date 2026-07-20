export function buildQueryString(entries: Array<[string, string | number | undefined]>): string {
	const params = new URLSearchParams();
	for (const [key, value] of entries) {
		if (value !== undefined) {
			params.set(key, String(value));
		}
	}
	const query = params.toString();
	return query ? `?${query}` : '';
}

export function pathSegment(value: string | number): string {
	return encodeURIComponent(String(value));
}

export function indexPath(indexName: string, suffix = ''): string {
	return `/indexes/${pathSegment(indexName)}${suffix}`;
}

export function experimentPath(indexName: string, id: number | string, suffix = ''): string {
	return indexPath(indexName, `/experiments/${pathSegment(id)}${suffix}`);
}

export function dictionaryPath(indexName: string, dictionaryName: string, suffix = ''): string {
	return indexPath(indexName, `/dictionaries/${pathSegment(dictionaryName)}${suffix}`);
}
