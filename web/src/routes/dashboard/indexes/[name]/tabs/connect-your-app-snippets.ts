/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/tabs/connect-your-app-snippets.ts.
 */
import {
	FLAPJACK_SEARCH_APP_ID,
	parseFlapjackSearchEndpoint,
	type FlapjackSearchProtocol
} from '$lib/flapjack-search-client';

export type FrameworkId = 'react' | 'vue' | 'vanilla';

export type SnippetContext = {
	host: string;
	protocol: FlapjackSearchProtocol;
	indexName: string;
	appId: string;
};

export type FrameworkSnippet = {
	id: FrameworkId;
	label: string;
	clientSetup: string;
	instantSearchSetup: string;
};

/**
 * Mirrors DEFAULT_CORS_ALLOWED_ORIGINS from infra/api/src/router.rs.
 * Keep in sync until the backend exposes this via a shared config endpoint.
 */
export const CORS_ALLOWED_ORIGINS = ['http://localhost:5173', 'https://cloud.flapjack.foo'] as const;

export function buildSnippetContext(endpoint: string, indexName: string): SnippetContext {
	const { host, protocol } = parseFlapjackSearchEndpoint(endpoint);

	return {
		host,
		protocol,
		indexName,
		appId: FLAPJACK_SEARCH_APP_ID
	};
}

export function buildFrameworkSnippets(ctx: SnippetContext): FrameworkSnippet[] {
	const clientSetup = `import { liteClient as algoliasearch } from 'algoliasearch/lite';

const searchClient = algoliasearch('${ctx.appId}', 'YOUR_API_KEY', {
  hosts: [{ url: '${ctx.host}', accept: 'readWrite', protocol: '${ctx.protocol}' }],
  baseHeaders: {
    Authorization: 'Bearer YOUR_API_KEY',
  },
});`;

	return [
		{
			id: 'react',
			label: 'React',
			clientSetup,
			instantSearchSetup: `import { InstantSearch, SearchBox, Hits } from 'react-instantsearch';

<InstantSearch searchClient={searchClient} indexName="${ctx.indexName}">
  <SearchBox />
  <Hits />
</InstantSearch>`
		},
		{
			id: 'vue',
			label: 'Vue',
			clientSetup,
			instantSearchSetup: `import { AisInstantSearch, AisSearchBox, AisHits } from 'vue-instantsearch';

<AisInstantSearch :search-client="searchClient" index-name="${ctx.indexName}">
  <AisSearchBox />
  <AisHits />
</AisInstantSearch>`
		},
		{
			id: 'vanilla',
			label: 'Vanilla JS',
			clientSetup,
			instantSearchSetup: `import instantsearch from 'instantsearch.js';
import { searchBox, hits } from 'instantsearch.js/es/widgets';

const search = instantsearch({
  indexName: '${ctx.indexName}',
  searchClient,
});

search.addWidgets([
  searchBox({ container: '#searchbox' }),
  hits({ container: '#hits' }),
]);

search.start();`
		}
	];
}
