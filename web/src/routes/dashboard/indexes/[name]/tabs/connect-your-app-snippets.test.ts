import { describe, it, expect } from 'vitest';
import {
	buildSnippetContext,
	buildFrameworkSnippets,
	CORS_ALLOWED_ORIGINS
} from './connect-your-app-snippets';

describe('buildSnippetContext', () => {
	it('parses https endpoint correctly', () => {
		const ctx = buildSnippetContext('https://api.flapjack.foo', 'my-index');
		expect(ctx.host).toBe('api.flapjack.foo');
		expect(ctx.protocol).toBe('https');
		expect(ctx.indexName).toBe('my-index');
		expect(ctx.appId).toBe('griddle');
	});

	it('parses http endpoint correctly', () => {
		const ctx = buildSnippetContext('http://localhost:3001', 'test-idx');
		expect(ctx.host).toBe('localhost:3001');
		expect(ctx.protocol).toBe('http');
		expect(ctx.indexName).toBe('test-idx');
	});

	it('includes port in host when present', () => {
		const ctx = buildSnippetContext('https://api.example.com:8443', 'idx');
		expect(ctx.host).toBe('api.example.com:8443');
	});

	it('throws for unsupported protocol', () => {
		expect(() => buildSnippetContext('ftp://files.example.com', 'idx')).toThrow(
			'Unsupported endpoint protocol'
		);
	});

	it('throws for invalid URL', () => {
		expect(() => buildSnippetContext('not-a-url', 'idx')).toThrow();
	});
});

describe('buildFrameworkSnippets', () => {
	const ctx = buildSnippetContext('https://api.flapjack.foo', 'products');

	it('returns exactly three framework snippets', () => {
		const snippets = buildFrameworkSnippets(ctx);
		expect(snippets).toHaveLength(3);
	});

	it('returns react, vue, and vanilla in order', () => {
		const snippets = buildFrameworkSnippets(ctx);
		expect(snippets.map((s) => s.id)).toEqual(['react', 'vue', 'vanilla']);
	});

	it('labels match framework names', () => {
		const snippets = buildFrameworkSnippets(ctx);
		expect(snippets.map((s) => s.label)).toEqual(['React', 'Vue', 'Vanilla JS']);
	});

	it('all snippets include the host in clientSetup', () => {
		const snippets = buildFrameworkSnippets(ctx);
		for (const snippet of snippets) {
			expect(snippet.clientSetup).toContain('api.flapjack.foo');
		}
	});

	it('all snippets include the protocol in clientSetup', () => {
		const snippets = buildFrameworkSnippets(ctx);
		for (const snippet of snippets) {
			expect(snippet.clientSetup).toContain("protocol: 'https'");
		}
	});

	it('all snippets include the appId in clientSetup', () => {
		const snippets = buildFrameworkSnippets(ctx);
		for (const snippet of snippets) {
			expect(snippet.clientSetup).toContain("algoliasearch('griddle'");
		}
	});

	it('all snippets include the index name in instantSearchSetup', () => {
		const snippets = buildFrameworkSnippets(ctx);
		for (const snippet of snippets) {
			expect(snippet.instantSearchSetup).toContain('products');
		}
	});

	it('react snippet uses react-instantsearch imports', () => {
		const snippets = buildFrameworkSnippets(ctx);
		const react = snippets.find((s) => s.id === 'react')!;
		expect(react.instantSearchSetup).toContain('react-instantsearch');
		expect(react.instantSearchSetup).toContain('<InstantSearch');
	});

	it('vue snippet uses vue-instantsearch imports', () => {
		const snippets = buildFrameworkSnippets(ctx);
		const vue = snippets.find((s) => s.id === 'vue')!;
		expect(vue.instantSearchSetup).toContain('vue-instantsearch');
		expect(vue.instantSearchSetup).toContain('<AisInstantSearch');
	});

	it('vanilla snippet uses instantsearch.js imports', () => {
		const snippets = buildFrameworkSnippets(ctx);
		const vanilla = snippets.find((s) => s.id === 'vanilla')!;
		expect(vanilla.instantSearchSetup).toContain("instantsearch.js");
		expect(vanilla.instantSearchSetup).toContain('search.start()');
	});

	it('all snippets share the same clientSetup code', () => {
		const snippets = buildFrameworkSnippets(ctx);
		const setups = snippets.map((s) => s.clientSetup);
		expect(setups[0]).toBe(setups[1]);
		expect(setups[1]).toBe(setups[2]);
	});
});

describe('CORS_ALLOWED_ORIGINS', () => {
	it('includes localhost dev server', () => {
		expect(CORS_ALLOWED_ORIGINS).toContain('http://localhost:5173');
	});

	it('includes canonical Flapjack Cloud console origin', () => {
		expect(CORS_ALLOWED_ORIGINS).toContain('https://cloud.flapjack.foo');
		expect(CORS_ALLOWED_ORIGINS).not.toContain('https://griddle.io');
	});
});
