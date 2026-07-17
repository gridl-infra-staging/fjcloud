import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock, toastSuccessMock } = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	}),
	toastSuccessMock: vi.fn()
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

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			success: toastSuccessMock
		}
	};
});

import IndexDetailPage from './+page.svelte';
import {
	samplePersonalizationProfile,
	samplePersonalizationStrategy,
	createMockPageData
} from './detail.test.shared';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

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
	'personalization-strategy-state-error'
] as const;

const PROFILE_STATE_TEST_IDS = [
	'personalization-profile-state-untouched',
	'personalization-profile-state-loading',
	'personalization-profile-state-found',
	'personalization-profile-state-empty',
	'personalization-profile-state-error'
] as const;

const PERSONALIZATION_HELP_TOOLTIPS = [
	{
		triggerLabel: 'What personalization impact means',
		message: 'Controls how strongly personalization reorders matching results.'
	},
	{
		triggerLabel: 'What event scoring rows mean',
		message: 'Event rows map user behavior events to scores used by the strategy.'
	},
	{
		triggerLabel: 'What facet scoring rows mean',
		message: 'Facet rows weight profile facets that influence personalized ranking.'
	},
	{
		triggerLabel: 'What profile lookup userToken means',
		message: 'Lookup requires the same stable userToken sent with search and event requests.'
	}
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
		expect(screen.getByTestId('personalization-section')).toHaveAttribute('data-index', 'products');
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

	it('personalization tab renders customer-facing invalid strategy recovery and keeps save disabled', async () => {
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
		const invalidState = screen.getByTestId('personalization-strategy-invalid-state');
		expect(invalidState).toHaveTextContent(
			'The saved personalization strategy could not be loaded.'
		);
		expect(invalidState).toHaveTextContent(
			'The editor is showing a default strategy so you can repair and save a valid version.'
		);
		expect(invalidState).not.toHaveTextContent('invalid-event-type');
		expect(invalidState).not.toHaveTextContent('Strategy validation error');
		expect(screen.getByTestId('personalization-strategy-example-json').textContent).toBe(
			JSON.stringify(samplePersonalizationStrategy, null, 2)
		);
		expect(
			screen.getByRole('button', { name: 'Copy example personalization strategy' })
		).toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-save')).toBeDisabled();
	});

	it('personalization tab treats a missing saved strategy as an unchanged default draft', async () => {
		renderPage({ personalizationStrategy: null });

		await openTab('Personalization');
		expect(screen.queryByTestId('personalization-strategy-invalid-state')).not.toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-state-untouched')).toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-summary-impact')).toHaveTextContent('75');
		expect(screen.getByTestId('personalization-strategy-summary-events')).toHaveTextContent('2');
		expect(screen.getByTestId('personalization-strategy-summary-facets')).toHaveTextContent('2');
		expect(screen.getByTestId('personalization-strategy-save')).toBeDisabled();
	});

	it('personalization tab renders audited advanced-control tooltip triggers', async () => {
		renderPage();

		await openTab('Personalization');
		for (const tooltip of PERSONALIZATION_HELP_TOOLTIPS) {
			const trigger = screen.getByRole('button', { name: tooltip.triggerLabel });
			expect(trigger).toHaveAttribute('aria-describedby');
			expect(trigger).toHaveAttribute('aria-controls');
			expect(
				screen.getByText(tooltip.message, { selector: '[role="tooltip"]' })
			).toBeInTheDocument();
		}
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

	it('personalization strategy keeps error inline and routes success form state to toasts', async () => {
		const view = renderPage();
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-untouched');

		await view.rerender({
			data: createMockPageData(),
			form: { personalizationStrategySaved: true } as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-untouched');
		expect(screen.queryByTestId('personalization-strategy-state-saved')).not.toBeInTheDocument();
		expect(screen.queryByText('Strategy saved.')).not.toBeInTheDocument();
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Strategy saved.', {
				duration: TOAST_DURATION_MS
			});
		});

		await view.rerender({
			data: createMockPageData(),
			form: { personalizationStrategyDeleted: true } as DetailPageForm
		});
		await openTab('Personalization');
		expectOnlyVisibleState(STRATEGY_STATE_TEST_IDS, 'personalization-strategy-state-untouched');
		expect(screen.queryByTestId('personalization-strategy-state-deleted')).not.toBeInTheDocument();
		expect(screen.queryByText('Strategy deleted.')).not.toBeInTheDocument();
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Strategy deleted.', {
				duration: TOAST_DURATION_MS
			});
		});

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
		expect(screen.queryByText('Profile deleted.')).not.toBeInTheDocument();
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Profile deleted.', {
				duration: TOAST_DURATION_MS
			});
		});

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
		expect(screen.getByTestId('personalization-strategy-state-untouched')).toBeInTheDocument();
		expect(screen.queryByTestId('personalization-strategy-state-saved')).not.toBeInTheDocument();
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Delete Strategy' }));
		const strategyDialog = screen.getByTestId('confirm-dialog');
		expect(strategyDialog).toBeInTheDocument();
		expect(within(strategyDialog).getByText('Delete strategy?')).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByTestId('confirm-cancel-btn'));
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expect(screen.getByTestId('personalization-strategy-state-untouched')).toBeInTheDocument();
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
		expect(screen.getByTestId('recommendations-section')).toHaveAttribute('data-index', 'products');
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
		expect(screen.getByTestId('chat-section')).toHaveAttribute('data-index', 'products');
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
