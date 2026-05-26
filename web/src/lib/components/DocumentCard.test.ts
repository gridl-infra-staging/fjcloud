import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

import DocumentCard from './DocumentCard.svelte';

afterEach(() => {
	cleanup();
});

describe('DocumentCard', () => {
	it('renders fields in stable order with objectID first', () => {
		const { container } = render(DocumentCard, {
			hit: {
				objectID: 'doc-1',
				title: 'Rust',
				price: 42,
				category: 'books'
			}
		});

		const renderedFieldNames = Array.from(
			container.querySelectorAll('[data-testid="document-card-field"]')
		).map((element) => element.getAttribute('data-field-name'));

		expect(renderedFieldNames).toEqual(['objectID', 'category', 'price', 'title']);
	});

	it('prefers _highlightResult HTML rendering path for matching fields', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-2',
				title: 'Rust',
				_highlightResult: {
					title: { value: '<mark>Rust</mark> language' }
				}
			}
		});

		expect(screen.getByTestId('document-card-highlight-title').innerHTML).toContain(
			'<mark>Rust</mark>'
		);
		expect(screen.getByTestId('document-card-highlight-title')).toHaveTextContent('Rust language');
	});

	it('sanitizes highlight HTML with DOMPurify before rendering', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-3',
				body: 'safe',
				_highlightResult: {
					body: {
						value: '<img src=x onerror="alert(1)"><script>alert(2)</script><em>safe fragment</em>'
					}
				}
			}
		});

		const highlight = screen.getByTestId('document-card-highlight-body');
		expect(highlight.innerHTML).toContain('<em>safe fragment</em>');
		expect(highlight.innerHTML).not.toContain('onerror');
		expect(highlight.innerHTML).not.toContain('<script>');
		expect(highlight.querySelector('img')).toBeNull();
	});
});
