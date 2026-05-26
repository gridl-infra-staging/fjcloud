export type SearchUrlState = {
	query: string;
	page: number;
	filters: string[];
	hitsPerPage: number;
};

const SEARCH_QUERY_KEY = 'q';
const SEARCH_PAGE_KEY = 'p';
const SEARCH_FILTERS_KEY = 'f';
const SEARCH_HITS_PER_PAGE_KEY = 'hr';

export function serializeSearchUrlState(state: SearchUrlState): string {
	const params = new URLSearchParams();
	params.set(SEARCH_QUERY_KEY, state.query);
	params.set(SEARCH_PAGE_KEY, String(state.page));
	if (state.filters.length > 0) {
		params.set(SEARCH_FILTERS_KEY, state.filters.join(','));
	}
	params.set(SEARCH_HITS_PER_PAGE_KEY, String(state.hitsPerPage));
	return params.toString();
}

export function parseSearchUrlState(params: URLSearchParams): SearchUrlState {
	const query = params.get(SEARCH_QUERY_KEY) ?? '';
	const parsedPage = Number.parseInt(params.get(SEARCH_PAGE_KEY) ?? '1', 10);
	const rawFilters = params.get(SEARCH_FILTERS_KEY) ?? '';
	const parsedHitsPerPage = Number.parseInt(params.get(SEARCH_HITS_PER_PAGE_KEY) ?? '20', 10);

	return {
		query,
		page: Number.isFinite(parsedPage) && parsedPage > 0 ? parsedPage : 1,
		filters: rawFilters ? rawFilters.split(',').filter(Boolean) : [],
		hitsPerPage:
			Number.isFinite(parsedHitsPerPage) && parsedHitsPerPage > 0 ? parsedHitsPerPage : 20
	};
}

export function buildSearchUrlWithState(currentUrl: string, state: SearchUrlState): string {
	const url = new URL(currentUrl);
	const mergedParams = new URLSearchParams(url.search);

	mergedParams.set(SEARCH_QUERY_KEY, state.query);
	mergedParams.set(SEARCH_PAGE_KEY, String(state.page));
	if (state.filters.length > 0) {
		mergedParams.set(SEARCH_FILTERS_KEY, state.filters.join(','));
	} else {
		mergedParams.delete(SEARCH_FILTERS_KEY);
	}
	mergedParams.set(SEARCH_HITS_PER_PAGE_KEY, String(state.hitsPerPage));

	url.search = mergedParams.toString();
	return url.toString();
}
