import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { TOAST_DURATION_MS } from '$lib/toast';

const pageState = vi.hoisted(() => ({
	url: new URL('http://localhost/console/indexes/products?tab=rules')
}));
const toastSuccessMock = vi.hoisted(() => vi.fn());

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	pushState: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/environment', () => ({
	browser: true
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
	const actual = await vi.importActual<typeof import('$lib/toast')>('$lib/toast');
	return {
		...actual,
		toast: {
			...actual.toast,
			success: toastSuccessMock
		}
	};
});

import IndexDetailPage from './+page.svelte';
import { createMockPageData } from './detail.test.shared';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	pageState.url = new URL('http://localhost/console/indexes/products?tab=rules');
});

describe('Index detail page browser tab state', () => {
	it('renders Search as the second index detail tab without changing its slug', () => {
		pageState.url = new URL('http://localhost/console/indexes/products?tab=search');
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		const tabs = screen.getAllByRole('tab');
		expect(tabs[0]).toHaveTextContent('Overview');
		expect(tabs[1]).toHaveTextContent('Search');
		expect(tabs[1]).toHaveAttribute('aria-selected', 'true');
		expect(pageState.url.searchParams.get('tab')).toBe('search');
	});

	it('does not revert a clicked tab against the stale page URL during pushState navigation', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await waitFor(() => {
			expect(screen.queryByRole('tab', { name: 'Rules' })).not.toBeInTheDocument();
			expect(screen.getByRole('tab', { name: 'Merchandising' })).toHaveAttribute(
				'aria-selected',
				'true'
			);
		});
		await fireEvent.click(screen.getByRole('tab', { name: 'Suggestions' }));

		await waitFor(() => {
			expect(screen.getByRole('tab', { name: 'Suggestions' })).toHaveAttribute(
				'aria-selected',
				'true'
			);
		});
		expect(screen.getByTestId('suggestions-section')).toBeVisible();
	});

	it('keeps suggestions form results visible when the page URL still names the previous tab', async () => {
		const view = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await waitFor(() =>
			expect(screen.getByRole('tab', { name: 'Merchandising' })).toHaveAttribute(
				'aria-selected',
				'true'
			)
		);
		await view.rerender({
			data: createMockPageData(),
			form: { qsConfigSaved: true }
		});

		await waitFor(() => {
			expect(screen.getByRole('tab', { name: 'Suggestions' })).toHaveAttribute(
				'aria-selected',
				'true'
			);
		});
		expect(screen.queryByText('Suggestions config saved.')).not.toBeInTheDocument();
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Suggestions config saved.', {
				duration: TOAST_DURATION_MS
			});
		});
	});

	it.each([
		['ruleSaved', { ruleSaved: true }],
		['ruleDeleted', { ruleDeleted: true }],
		['rulesCleared', { rulesCleared: true }],
		['ruleError', { ruleError: 'Rule JSON is invalid' }],
		['rulesClearError', { rulesClearError: 'Failed to clear rules' }]
	])('routes %s form results to Merchandising over a stale tab URL', async (_name, form) => {
		pageState.url = new URL('http://localhost/console/indexes/products?tab=settings');
		const view = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await waitFor(() =>
			expect(screen.getByRole('tab', { name: 'Settings' })).toHaveAttribute('aria-selected', 'true')
		);
		await view.rerender({
			data: createMockPageData(),
			form
		});

		await waitFor(() => {
			expect(screen.getByRole('tab', { name: 'Merchandising' })).toHaveAttribute(
				'aria-selected',
				'true'
			);
		});
		expect(screen.getByTestId('merchandising-section')).toBeVisible();
	});
});
