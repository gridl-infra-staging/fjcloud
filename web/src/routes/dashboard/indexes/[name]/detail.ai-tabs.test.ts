import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock } = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	})
}));

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

vi.mock('$lib/components/InstantSearch.svelte', () => ({
	default: function (anchor: unknown, props: unknown) {
		void anchor;
		void props;
	}
}));

import IndexDetailPage from './+page.svelte';
import {
	sampleIndex,
	samplePersonalizationProfile,
	createMockPageData
} from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

function renderPage(overrides: DetailPageOverrides = {}, form: DetailPageForm = null) {
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

async function openTab(name: string): Promise<void> {
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page — AI/search tabs', () => {
	it('personalization tab is available in tab layout', () => {
		renderPage();

		expect(screen.getByRole('tab', { name: 'Personalization' })).toBeInTheDocument();
	});

	it('personalization tab has save-strategy form wired to savePersonalizationStrategy action', async () => {
		const { container } = renderPage();

		await openTab('Personalization');
		const form = container.querySelector('form[action="?/savePersonalizationStrategy"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: /save strategy/i })).toBeInTheDocument();
	});

	it('personalization tab editor uses flapjack strategy array shape', async () => {
		renderPage();

		await openTab('Personalization');
		const strategyTextarea = screen.getByRole('textbox', {
			name: /strategy json/i
		}) as HTMLTextAreaElement;

		expect(strategyTextarea.value).toContain('"eventName": "Product viewed"');
		expect(strategyTextarea.value).toContain('"facetName": "brand"');
	});

	it('personalization tab has profile lookup form wired to getPersonalizationProfile action', async () => {
		const { container } = renderPage();

		await openTab('Personalization');
		const form = container.querySelector('form[action="?/getPersonalizationProfile"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: /load profile/i })).toBeInTheDocument();
	});

	it('personalization tab renders loaded profile data from action result', async () => {
		renderPage({}, { personalizationProfile: samplePersonalizationProfile });

		await openTab('Personalization');
		expect(screen.getByText('user_abc')).toBeInTheDocument();
		expect(screen.getByText(/delete profile/i)).toBeInTheDocument();
	});

	it('recommendations tab is available in tab layout', () => {
		renderPage();

		expect(screen.getByRole('tab', { name: 'Recommendations' })).toBeInTheDocument();
	});

	it('recommendations tab has form wired to recommend action', async () => {
		const { container } = renderPage();

		await openTab('Recommendations');
		const form = container.querySelector('form[action="?/recommend"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: /get recommendations/i })).toBeInTheDocument();
	});

	it('recommendations tab seeds a valid default request body', async () => {
		renderPage();

		await openTab('Recommendations');
		const requestTextarea = screen.getByRole('textbox', {
			name: /recommendations json/i
		}) as HTMLTextAreaElement;

		expect(requestTextarea.value).toContain('"model": "trending-items"');
		expect(requestTextarea.value).toContain('"threshold": 0');
		expect(requestTextarea.value).not.toContain('"objectID": ""');
	});

	it('recommendations tab renders recommendation hits from action result', async () => {
		renderPage(
			{},
			{
				recommendationsResponse: {
					results: [
						{
							hits: [{ objectID: 'shoe-1' }, { objectID: 'shoe-2' }],
							processingTimeMS: 4
						}
					]
				}
			}
		);

		await openTab('Recommendations');
		expect(screen.getByText('shoe-1')).toBeInTheDocument();
		expect(screen.getByText('shoe-2')).toBeInTheDocument();
	});

	it('rehydrates recommendations draft when the index changes', async () => {
		const view = renderPage();

		await openTab('Recommendations');
		let requestTextarea = screen.getByRole('textbox', {
			name: /recommendations json/i
		}) as HTMLTextAreaElement;
		expect(requestTextarea.value).toContain('"indexName": "products"');

		await view.rerender({
			data: createMockPageData({
				index: { ...sampleIndex, name: 'products-v2' }
			}),
			form: null
		});

		await openTab('Recommendations');
		requestTextarea = screen.getByRole('textbox', {
			name: /recommendations json/i
		}) as HTMLTextAreaElement;
		expect(requestTextarea.value).toContain('"indexName": "products-v2"');
	});

	it('chat tab is available in tab layout', () => {
		renderPage();

		expect(screen.getByRole('tab', { name: 'Chat' })).toBeInTheDocument();
	});

	it('chat tab has form wired to chat action', async () => {
		const { container } = renderPage();

		await openTab('Chat');
		const form = container.querySelector('form[action="?/chat"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: /send message/i })).toBeInTheDocument();
	});

	it('chat tab renders answer from action result', async () => {
		renderPage(
			{},
			{
				chatQuery: 'What should I buy next?',
				chatResponse: {
					answer: 'Try shoe-2',
					sources: [{ objectID: 'shoe-2' }],
					conversationId: 'conv-1',
					queryID: 'q-1'
				}
			}
		);

		await openTab('Chat');
		expect(screen.getByText('Try shoe-2')).toBeInTheDocument();
	});

	it('chat tab keeps conversationId wired for follow-up turns', async () => {
		const view = renderPage(
			{},
			{
				chatQuery: 'What should I buy next?',
				chatResponse: {
					answer: 'Try shoe-2',
					sources: [{ objectID: 'shoe-2' }],
					conversationId: 'conv-1',
					queryID: 'q-1'
				}
			}
		);

		await openTab('Chat');
		let conversationIdInput = view.container.querySelector(
			'input[name="conversationId"]'
		) as HTMLInputElement | null;
		expect(conversationIdInput?.value).toBe('conv-1');

		await view.rerender({
			data: createMockPageData(),
			form: {
				chatQuery: 'Follow up question',
				chatError: 'upstream failed'
			} as unknown as DetailPageForm
		});

		await openTab('Chat');
		conversationIdInput = view.container.querySelector(
			'input[name="conversationId"]'
		) as HTMLInputElement | null;
		expect(conversationIdInput?.value).toBe('conv-1');
	});
});
