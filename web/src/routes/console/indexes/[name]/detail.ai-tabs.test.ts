import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
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
	page: { url: new URL('http://localhost/console/indexes/products') }
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
import { samplePersonalizationProfile, createMockPageData } from './detail.test.shared';

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

const STRATEGY_STATE_TEST_IDS = [
	'personalization-strategy-state-untouched',
	'personalization-strategy-state-saved',
	'personalization-strategy-state-deleted',
	'personalization-strategy-state-error'
] as const;

const PROFILE_STATE_TEST_IDS = [
	'personalization-profile-state-untouched',
	'personalization-profile-state-loading',
	'personalization-profile-state-found',
	'personalization-profile-state-empty',
	'personalization-profile-state-error'
] as const;

function expectOnlyVisibleState(testIds: readonly string[], visibleTestId: string) {
	for (const testId of testIds) {
		if (testId === visibleTestId) {
			expect(screen.getByTestId(testId)).toBeInTheDocument();
		} else {
			expect(screen.queryByTestId(testId)).not.toBeInTheDocument();
		}
	}
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

	it('personalization tab uses structured editor dialog instead of raw strategy textarea', async () => {
		const view = renderPage();

		await openTab('Personalization');
		expect(view.container.querySelector('textarea[name="strategy"]')).toBeNull();
		expect(screen.getByRole('button', { name: /edit strategy/i })).toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-save')).toBeDisabled();
	});

	it('personalization tab keeps save disabled for unchanged strategy and enables after dialog edits', async () => {
		renderPage();

		await openTab('Personalization');
		const saveButton = screen.getByTestId('personalization-strategy-save');
		expect(saveButton).toBeDisabled();

		await fireEvent.click(screen.getByRole('button', { name: /edit strategy/i }));
		expect(screen.getByTestId('personalization-strategy-editor-dialog')).toBeInTheDocument();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-personalizationImpact'), {
			target: { value: '80' }
		});
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(screen.queryByTestId('personalization-strategy-editor-dialog')).not.toBeInTheDocument();
		expect(saveButton).toBeEnabled();
	});

	it('personalization tab renders explicit invalid strategy message and keeps save disabled', async () => {
		renderPage({
			personalizationStrategy: {
				eventsScoring: [
					{ eventName: 'Product viewed', eventType: 'invalid-event-type', score: 10 }
				],
				facetsScoring: [{ facetName: 'brand', score: 70 }],
				personalizationImpact: 75
			}
		});

		await openTab('Personalization');
		expect(screen.getByTestId('personalization-strategy-invalid-state')).toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-save')).toBeDisabled();
	});

	it('personalization tab has profile lookup form wired to getPersonalizationProfile action', async () => {
		const { container } = renderPage();

		await openTab('Personalization');
		const form = container.querySelector('form[action="?/getPersonalizationProfile"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: /load profile/i })).toBeInTheDocument();
	});

	it('personalization tab renders loaded profile data from action result', async () => {
		const view = renderPage(
			{},
			{
				personalizationProfile: samplePersonalizationProfile,
				personalizationProfileLookupAttempted: true
			}
		);

		await openTab('Personalization');
		const foundState = screen.getByTestId('personalization-profile-state-found');
		expect(within(foundState).getByText('User token')).toBeInTheDocument();
		expect(within(foundState).getByTestId('personalization-profile-user-token')).toHaveTextContent(
			'user_abc'
		);
		expect(within(foundState).getByText('Last event at')).toBeInTheDocument();
		expect(within(foundState).getByText('2026-02-25T00:00:00Z')).toBeInTheDocument();
		expect(within(foundState).getByText('brand')).toBeInTheDocument();
		expect(within(foundState).getByText('category')).toBeInTheDocument();
		expect(within(foundState).getByText('apple')).toBeInTheDocument();
		expect(within(foundState).getByText('20')).toBeInTheDocument();
		expect(within(foundState).getByText('shoes')).toBeInTheDocument();
		expect(within(foundState).getByText('12')).toBeInTheDocument();
		expect(
			view.container.querySelector('[data-testid="personalization-profile-state-found"] pre')
		).toBeNull();
		expect(within(foundState).getByRole('button', { name: /delete profile/i })).toBeInTheDocument();
	});

	it('personalization tab generates unique non-empty score test ids for arbitrary labels', async () => {
		const toTestIdSegment = (value: string): string => {
			const bytes = new TextEncoder().encode(value);
			return `u${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
		};
		const collisionProneProfile = {
			userToken: 'collision_user',
			lastEventAt: '2026-02-25T00:00:00Z',
			scores: {
				Brand: { Nike: 20, '!!!': 12, 'Shared Facet': 4 },
				'brand!!!': { nike: 7, '   ': 3, 'Shared Facet': 5 },
				'!!!': { Å: 11 },
				Å: { '?': 2 }
			}
		};
		const view = renderPage(
			{},
			{
				personalizationProfile: collisionProneProfile,
				personalizationProfileLookupAttempted: true
			}
		);

		await openTab('Personalization');
		const foundState = screen.getByTestId('personalization-profile-state-found');
		const categoryPrefix = 'personalization-profile-score-category-';
		const categoryCards = Array.from(
			view.container.querySelectorAll<HTMLElement>(`[data-testid^="${categoryPrefix}"]`)
		).filter((card) => card.dataset.testid !== 'personalization-profile-score-category-title');
		const categoryTestIds = categoryCards.map((card) => card.dataset.testid ?? '');
		expect(categoryCards).toHaveLength(4);
		expect(new Set(categoryTestIds).size).toBe(4);
		for (const testId of categoryTestIds) {
			expect(testId.length).toBeGreaterThan(categoryPrefix.length);
		}

		const entryPrefix = 'personalization-profile-score-entry-';
		const scoreEntries = Array.from(
			view.container.querySelectorAll<HTMLElement>(`[data-testid^="${entryPrefix}"]`)
		);
		const entryTestIds = scoreEntries.map((entry) => entry.dataset.testid ?? '');
		expect(scoreEntries).toHaveLength(8);
		expect(new Set(entryTestIds).size).toBe(8);
		for (const testId of entryTestIds) {
			expect(testId.length).toBeGreaterThan(entryPrefix.length);
		}
		const brandSegment = toTestIdSegment('Brand');
		const noisyBrandSegment = toTestIdSegment('brand!!!');
		const sharedFacetSegment = toTestIdSegment('Shared Facet');
		expect(
			within(foundState).getByTestId(
				`personalization-profile-score-entry-${brandSegment}-${sharedFacetSegment}`
			)
		).toHaveTextContent('Shared Facet');
		expect(
			within(foundState).getByTestId(
				`personalization-profile-score-value-${brandSegment}-${sharedFacetSegment}`
			)
		).toHaveTextContent('4');
		expect(
			within(foundState).getByTestId(
				`personalization-profile-score-entry-${noisyBrandSegment}-${sharedFacetSegment}`
			)
		).toHaveTextContent('Shared Facet');
		expect(
			within(foundState).getByTestId(
				`personalization-profile-score-value-${noisyBrandSegment}-${sharedFacetSegment}`
			)
		).toHaveTextContent('5');
		expect(within(foundState).getByRole('button', { name: /delete profile/i })).toBeInTheDocument();
	});

	it('personalization strategy state uses explicit canonical branches and precedence', async () => {
		const view = renderPage();
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-untouched');

		await view.rerender({
			data: createMockPageData(),
			form: { personalizationStrategySaved: true } as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-saved');

		await view.rerender({
			data: createMockPageData(),
			form: { personalizationStrategyDeleted: true } as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-deleted');

		await view.rerender({
			data: createMockPageData(),
			form: {
				personalizationError: 'failed to persist strategy'
			} as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-error');
	});

	it('personalization profile state uses explicit canonical branches and precedence', async () => {
		const view = renderPage();
		await openTab('Personalization');
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-untouched');

		const profileForm = view.container.querySelector(
			'form[action="?/getPersonalizationProfile"]'
		) as HTMLFormElement | null;
		expect(profileForm).not.toBeNull();
		await fireEvent.submit(profileForm as HTMLFormElement);
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-loading');

		await view.rerender({
			data: createMockPageData(),
			form: {
				personalizationProfileLookupAttempted: true,
				personalizationProfile: samplePersonalizationProfile
			} as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-found');

		await view.rerender({
			data: createMockPageData(),
			form: {
				personalizationProfileLookupAttempted: true,
				personalizationProfile: null
			} as unknown as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-empty');

		await view.rerender({
			data: createMockPageData(),
			form: {
				personalizationProfileDeleted: true,
				personalizationProfile: null
			} as unknown as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-untouched');

		await view.rerender({
			data: createMockPageData(),
			form: {
				personalizationProfileLookupAttempted: true,
				personalizationProfile: samplePersonalizationProfile,
				personalizationError: 'Failed to load personalization profile'
			} as unknown as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(PROFILE_STATE_TEST_IDS, 'personalization-profile-state-error');
	});

	it('personalization strategy delete uses ConfirmDialog cancel/confirm before submitting delete action', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const view = renderPage({}, { personalizationStrategySaved: true } as DetailPageForm);
		await openTab('Personalization');
		const strategyState = screen.getByTestId('personalization-strategy-state-saved');
		expect(strategyState).toBeInTheDocument();
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Delete Strategy' }));
		const strategyDialog = screen.getByTestId('confirm-dialog');
		expect(strategyDialog).toBeInTheDocument();
		expect(within(strategyDialog).getByText('Delete strategy?')).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByTestId('confirm-cancel-btn'));
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expect(strategyState).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByRole('button', { name: 'Delete Strategy' }));
		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();

		requestSubmitSpy.mockRestore();
		view.unmount();
	});

	it('personalization profile delete uses ConfirmDialog cancel/confirm before submitting delete action', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		renderPage({}, {
			personalizationProfileLookupAttempted: true,
			personalizationProfile: samplePersonalizationProfile
		} as unknown as DetailPageForm);
		await openTab('Personalization');
		const foundState = screen.getByTestId('personalization-profile-state-found');
		expect(foundState).toBeInTheDocument();
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();

		await fireEvent.click(within(foundState).getByRole('button', { name: 'Delete Profile' }));
		const profileDialog = screen.getByTestId('confirm-dialog');
		expect(profileDialog).toBeInTheDocument();
		expect(within(profileDialog).getByText('Delete profile?')).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByTestId('confirm-cancel-btn'));
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expect(screen.getByTestId('personalization-profile-state-found')).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(
			within(screen.getByTestId('personalization-profile-state-found')).getByRole('button', {
				name: 'Delete Profile'
			})
		);
		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
		requestSubmitSpy.mockRestore();
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
