import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import DocumentCard from './DocumentCard.svelte';

afterEach(() => {
	cleanup();
});

describe('DocumentCard', () => {
	it('renders fields in stable order with objectID first when no slots configured', () => {
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

		expect(screen.getByTestId('document-card')).toHaveClass('border-flapjack-ink/15');
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

		const titleHighlight = screen.getByTestId('document-card-highlight-title');
		expect(titleHighlight.querySelector('mark')).toHaveTextContent('Rust');
		expect(titleHighlight).toHaveClass('text-flapjack-ink');
		expect(titleHighlight).toHaveTextContent('Rust language');
	});

	it('renders sanitized engine emphasis as bold yellow mark text', () => {
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
		const mark = highlight.querySelector('mark');
		expect(mark).not.toBeNull();
		expect(mark).toHaveTextContent('safe fragment');
		expect(mark).toHaveAttribute('data-testid', 'search-highlight');
		expect(mark).toHaveClass('bg-flapjack-yellow', 'font-bold', 'not-italic');
		expect(highlight.querySelector('em')).toBeNull();
		expect(highlight.innerHTML).not.toContain('onerror');
		expect(highlight.innerHTML).not.toContain('<script>');
		expect(highlight.querySelector('img')).toBeNull();
	});

	it('renders configured title/subtitle/image/tags slots with stable testids', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-slot-1',
				title: 'The Matrix',
				director: 'Lana Wachowski',
				image: 'https://image.tmdb.org/poster.jpg',
				genre: ['Action', 'Sci-Fi']
			},
			titleField: 'title',
			subtitleField: 'director',
			imageField: 'image',
			tagsField: 'genre'
		});

		expect(screen.getByTestId('document-card-title')).toHaveTextContent('The Matrix');
		expect(screen.getByTestId('document-card-subtitle')).toHaveTextContent('Lana Wachowski');

		const image = screen.getByTestId('document-card-image') as HTMLImageElement;
		expect(image.tagName).toBe('IMG');
		expect(image.src).toBe('https://image.tmdb.org/poster.jpg');
		expect(screen.getByTestId('document-card-layout')).toHaveClass('flex', 'items-start');
		expect(image).toHaveClass('shrink-0', 'object-cover');
		expect(screen.getByTestId('document-card-content')).toHaveClass('min-w-0', 'flex-1');

		const tags = screen.getAllByTestId('document-card-tag').map((element) => element.textContent);
		expect(tags).toEqual(['Action', 'Sci-Fi']);
	});

	it('prefers sanitized highlight HTML for configured title and subtitle slots when _highlightResult is present', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-slot-highlight',
				title: 'Rust',
				subtitle: 'Systems programming',
				_highlightResult: {
					title: {
						value: '<mark>Rust</mark><img src=x onerror="alert(1)">'
					},
					subtitle: {
						value: '<em>Systems</em> programming<script>alert(1)</script>'
					}
				}
			},
			titleField: 'title',
			subtitleField: 'subtitle'
		});

		const titleSlot = screen.getByTestId('document-card-title');
		expect(titleSlot.querySelector('mark')).toHaveTextContent('Rust');
		expect(titleSlot.innerHTML).not.toContain('onerror');
		expect(titleSlot.querySelector('img')).toBeNull();
		const subtitleSlot = screen.getByTestId('document-card-subtitle');
		expect(subtitleSlot.innerHTML).toContain('<mark');
		expect(subtitleSlot.querySelector('mark')).toHaveTextContent('Systems');
		expect(subtitleSlot.innerHTML).not.toContain('<script>');
	});

	it('prefers sanitized highlight HTML for configured tag slot fields when available', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-tag-highlight',
				genre: ['Action', 'Sci-Fi'],
				_highlightResult: {
					genre: [
						{
							value: '<mark>Action</mark><img src=x onerror="alert(1)">'
						},
						{
							value: '<mark>Sci-Fi</mark>'
						}
					]
				}
			},
			tagsField: 'genre'
		});

		const tags = screen.getAllByTestId('document-card-tag');
		expect(tags).toHaveLength(2);
		expect(tags[0].querySelector('mark')).toHaveTextContent('Action');
		expect(tags[0].innerHTML).not.toContain('onerror');
		expect(tags[0].querySelector('img')).toBeNull();
		expect(tags[1].querySelector('mark')).toHaveTextContent('Sci-Fi');
	});

	it('omits a slot whose configured field is null or missing on the hit', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-omit',
				title: 'Rust'
			},
			titleField: 'title',
			subtitleField: 'director',
			imageField: null,
			tagsField: 'genre'
		});

		expect(screen.getByTestId('document-card-title')).toHaveTextContent('Rust');
		expect(screen.queryByTestId('document-card-subtitle')).toBeNull();
		expect(screen.queryByTestId('document-card-image')).toBeNull();
		expect(screen.queryByTestId('document-card-tag')).toBeNull();
	});

	it('renders a JSON view block when showJsonView prop is true', () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-json',
				title: 'JSON test'
			},
			showJsonView: true
		});

		const jsonBlock = screen.getByTestId('document-card-json');
		expect(jsonBlock.tagName).toBe('PRE');
		const parsed = JSON.parse(jsonBlock.textContent ?? '');
		expect(parsed).toEqual({ objectID: 'doc-json', title: 'JSON test' });
	});

	it('hides details by default and reveals JSON through an explicit action', async () => {
		const onOpenDetails = vi.fn();
		render(DocumentCard, {
			hit: {
				objectID: 'doc-json-toggle',
				title: 'Toggle me'
			},
			onOpenDetails
		});

		expect(screen.queryByTestId('document-card-json')).toBeNull();

		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(screen.getByTestId('document-card-json')).toBeInTheDocument();
		expect(onOpenDetails).toHaveBeenCalledTimes(1);
	});

	it('renders a pinned-position badge when pinnedAt is a positive integer', () => {
		render(DocumentCard, {
			hit: { objectID: 'doc-pinned', title: 'Pinned item' },
			pinnedAt: 3
		});

		const badge = screen.getByTestId('card-pinned-badge');
		expect(badge).toBeInTheDocument();
		expect(badge.textContent).toMatch(/3/);
	});

	it('omits the pinned-position badge when pinnedAt is null or omitted', () => {
		render(DocumentCard, {
			hit: { objectID: 'doc-no-pin', title: 'Unpinned item' },
			pinnedAt: null
		});

		expect(screen.queryByTestId('card-pinned-badge')).toBeNull();
	});

	it('allows the per-card toggle to hide JSON when showJsonView is true by default', async () => {
		render(DocumentCard, {
			hit: {
				objectID: 'doc-json-hide',
				title: 'Hide me'
			},
			showJsonView: true
		});

		expect(screen.getByTestId('document-card-json')).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Close details' }));

		expect(screen.queryByTestId('document-card-json')).toBeNull();
	});
});
