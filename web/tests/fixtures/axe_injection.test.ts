import { describe, expect, it, vi } from 'vitest';

// Same idiom as src/svelte_config.test.ts: importing svelte.config.js pulls in
// the Cloudflare adapter, whose wrangler/esbuild dependency asserts a TextEncoder
// invariant that jsdom does not satisfy. The adapter is irrelevant to the CSP
// directive map, so stub it rather than splitting the config into a new module.
vi.mock('@sveltejs/adapter-cloudflare', () => ({
	default: vi.fn((options: unknown) => ({ name: 'mock-cloudflare-adapter', options }))
}));

import { createDocumentCspDirectives } from '../../svelte.config.js';
import { AXE_SAME_ORIGIN_PATH, documentCspHeaderValue, formatCspHeader } from './axe_injection';

// The directive MAP is owned by src/svelte_config.test.ts, which asserts it
// exactly for production, development and test. These tests own only the
// serialization of that map into a header, and the same-origin path shape.

describe('formatCspHeader', () => {
	it('quotes CSP keywords and leaves host and scheme sources bare', () => {
		// Hand-calculated. Getting the quoting backwards yields a policy no
		// browser enforces the way production does, which would make the browser
		// contract spec pass vacuously.
		expect(
			formatCspHeader({
				'default-src': ['self'],
				'object-src': ['none'],
				'img-src': ['self', 'https:'],
				'frame-src': ['https://js.stripe.com'],
				'style-src-attr': ['unsafe-inline']
			})
		).toBe(
			"default-src 'self'; object-src 'none'; img-src 'self' https:; " +
				"frame-src https://js.stripe.com; style-src-attr 'unsafe-inline'"
		);
	});

	it('renders every directive the production owner declares', () => {
		// Catches a directive added to the owner that the serializer silently
		// drops, which would leave the contract spec testing a weaker policy
		// than the one that ships.
		const directives = createDocumentCspDirectives('production');
		const header = documentCspHeaderValue('production');
		for (const directive of Object.keys(directives)) {
			expect(header).toContain(`${directive} `);
		}
	});
});

describe('documentCspHeaderValue', () => {
	it('renders the exact script-src that refuses inline scanner injection', () => {
		// This is the whole reason the same-origin loader exists. If
		// 'unsafe-inline' ever appears in script-src the enforced policy has been
		// weakened -- fix the policy, do not relax this assertion.
		const header = documentCspHeaderValue('production');
		expect(header).toContain("script-src 'self' https://*.js.stripe.com https://js.stripe.com");
		expect(header).not.toMatch(/script-src[^;]*'unsafe-inline'/);
	});
});

describe('AXE_SAME_ORIGIN_PATH', () => {
	it('is a root-relative path so it resolves same-origin on every scanned route', () => {
		// A protocol-relative or absolute URL would resolve cross-origin and be
		// refused by script-src 'self' -- the exact failure being fixed.
		expect(AXE_SAME_ORIGIN_PATH.startsWith('/')).toBe(true);
		expect(AXE_SAME_ORIGIN_PATH.startsWith('//')).toBe(false);
		expect(AXE_SAME_ORIGIN_PATH).not.toMatch(/^[a-z]+:/i);
	});
});
