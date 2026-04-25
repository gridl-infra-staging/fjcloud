import { describe, expect, it } from 'vitest';

import { escapeInstantSearchHtml, renderInstantSearchHit } from './instantsearch-render';

describe('escapeInstantSearchHtml', () => {
	it('escapes ampersands', () => {
		expect(escapeInstantSearchHtml('a&b')).toBe('a&amp;b');
	});

	it('escapes angle brackets', () => {
		expect(escapeInstantSearchHtml('<div>')).toBe('&lt;div&gt;');
	});

	it('escapes double quotes', () => {
		expect(escapeInstantSearchHtml('"hello"')).toBe('&quot;hello&quot;');
	});

	it('escapes single quotes', () => {
		expect(escapeInstantSearchHtml("it's")).toBe('it&#39;s');
	});

	it('escapes all special characters together', () => {
		expect(escapeInstantSearchHtml('<a href="x">&\'end')).toBe(
			'&lt;a href=&quot;x&quot;&gt;&amp;&#39;end'
		);
	});

	it('returns plain text unchanged', () => {
		expect(escapeInstantSearchHtml('hello world 123')).toBe('hello world 123');
	});

	it('handles empty string', () => {
		expect(escapeInstantSearchHtml('')).toBe('');
	});
});

describe('renderInstantSearchHit', () => {
	it('escapes objectID and JSON payload HTML characters before interpolation', () => {
		const html = renderInstantSearchHit({
			objectID: '<img src=x onerror=alert(1)>',
			title: '<script>alert("owned")</script>',
			special: `'"&`
		});

		expect(html).not.toContain('<img src=x onerror=alert(1)>');
		expect(html).not.toContain('<script>alert("owned")</script>');
		expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
		expect(html).toContain('&lt;script&gt;alert(\\&quot;owned\\&quot;)&lt;/script&gt;');
		expect(html).toContain('&#39;\\&quot;&amp;');
	});
});
