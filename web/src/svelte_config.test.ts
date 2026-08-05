import { describe, expect, it, vi } from 'vitest';

vi.mock('@sveltejs/adapter-cloudflare', () => ({
	default: vi.fn((options: unknown) => ({ name: 'mock-cloudflare-adapter', options }))
}));

import config, { createDocumentCspDirectives } from '../svelte.config.js';

const EXPECTED_PRODUCTION_DOCUMENT_CSP_DIRECTIVES = {
	'base-uri': ['none'],
	'connect-src': [
		'self',
		'https://api.flapjack.foo',
		'https://api.staging.flapjack.foo',
		'https://api.stripe.com'
	],
	'default-src': ['self'],
	'font-src': ['self'],
	'form-action': ['self'],
	'frame-ancestors': ['none'],
	'frame-src': ['https://*.js.stripe.com', 'https://js.stripe.com', 'https://hooks.stripe.com'],
	'img-src': ['self', 'https:'],
	'object-src': ['none'],
	'script-src': ['self', 'https://*.js.stripe.com', 'https://js.stripe.com'],
	'style-src': ['self'],
	'style-src-attr': ['unsafe-inline']
} as const;

const EXPECTED_LOCAL_DOCUMENT_CSP_DIRECTIVES = {
	...EXPECTED_PRODUCTION_DOCUMENT_CSP_DIRECTIVES,
	'connect-src': [
		'self',
		'http://localhost:*',
		'http://127.0.0.1:*',
		'https://api.flapjack.foo',
		'https://api.staging.flapjack.foo',
		'https://api.stripe.com'
	]
} as const;

describe('SvelteKit document CSP configuration', () => {
	it('excludes local service origins from the exact production policy', () => {
		expect(createDocumentCspDirectives('production')).toEqual(
			EXPECTED_PRODUCTION_DOCUMENT_CSP_DIRECTIVES
		);
	});

	it('retains loopback OAuth status checks only in the exact local policy', () => {
		expect(createDocumentCspDirectives('development')).toEqual(
			EXPECTED_LOCAL_DOCUMENT_CSP_DIRECTIVES
		);
		expect(createDocumentCspDirectives('test')).toEqual(EXPECTED_LOCAL_DOCUMENT_CSP_DIRECTIVES);
	});

	it('owns the exact locally enforced policy without retaining report-only configuration', () => {
		expect(config.kit?.csp).toEqual({
			mode: 'auto',
			directives: EXPECTED_LOCAL_DOCUMENT_CSP_DIRECTIVES
		});
		expect(config.kit?.csp).not.toHaveProperty('reportOnly');
	});
});
