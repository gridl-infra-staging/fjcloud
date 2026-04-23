import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock, instantSearchMockFn } = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	}),
	instantSearchMockFn: vi.fn()
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
		instantSearchMockFn(anchor, props);
	}
}));

import IndexDetailPage from './+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import {
	sampleSecuritySources,
	createMockPageData
} from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
	clearLog();
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

describe('Index detail page — Security Sources tab', () => {
	it('Security Sources tab is available in tab layout', () => {
		renderPage();

		expect(screen.getByRole('tab', { name: 'Security Sources' })).toBeInTheDocument();
	});

	it('renders empty state when no sources are loaded', async () => {
		renderPage({ securitySources: { sources: [] } });
		await openTab('Security Sources');

		expect(screen.getByText(/no security sources/i)).toBeInTheDocument();
	});

	it('renders source rows with CIDR values and descriptions', async () => {
		renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		expect(within(section).getByText('192.168.1.0/24')).toBeInTheDocument();
		expect(within(section).getByText('Office network')).toBeInTheDocument();
		expect(within(section).getByText('10.0.0.0/8')).toBeInTheDocument();
		expect(within(section).getByText('VPN range')).toBeInTheDocument();
	});

	it('renders append form with source and description inputs', async () => {
		renderPage();
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		expect(within(section).getByLabelText(/^source$/i)).toBeInTheDocument();
		expect(within(section).getByLabelText(/^description$/i)).toBeInTheDocument();
		expect(within(section).getByRole('button', { name: /add source/i })).toBeInTheDocument();
	});

	it('renders delete button for each source row', async () => {
		renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		const deleteButtons = within(section).getAllByRole('button', { name: /delete/i });
		expect(deleteButtons).toHaveLength(2);
	});

	it('append form posts to appendSecuritySource action', async () => {
		const { container } = renderPage();
		await openTab('Security Sources');

		const form = container.querySelector('form[action="?/appendSecuritySource"]');
		expect(form).not.toBeNull();
		// Form contains source and description named inputs
		expect(form!.querySelector('input[name="source"]')).not.toBeNull();
		expect(form!.querySelector('input[name="description"]')).not.toBeNull();
	});

	it('delete forms post to deleteSecuritySource with hidden source value', async () => {
		const { container } = renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		const deleteForms = container.querySelectorAll('form[action="?/deleteSecuritySource"]');
		expect(deleteForms).toHaveLength(2);

		// Each delete form carries the raw CIDR value in a hidden source input
		const hiddenInputs = Array.from(deleteForms).map(
			(f) => (f.querySelector('input[type="hidden"][name="source"]') as HTMLInputElement)?.value
		);
		expect(hiddenInputs).toContain('192.168.1.0/24');
		expect(hiddenInputs).toContain('10.0.0.0/8');
	});

	it('wires forms with the enhance directive', async () => {
		enhanceMock.mockClear();
		renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		// One append form + two delete forms = 3 enhanced forms
		const enhancedForms = enhanceMock.mock.calls.map((c: unknown[]) => c[0] as HTMLFormElement);
		const actions = enhancedForms.map((f) => f.getAttribute('action'));
		expect(actions).toContain('?/appendSecuritySource');
		expect(actions.filter((a) => a === '?/deleteSecuritySource')).toHaveLength(2);
	});

	it('shows success message when a source is appended', async () => {
		renderPage({}, {
			securitySourceAppended: true,
			securitySources: sampleSecuritySources
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByText(/security source added/i)).toBeInTheDocument();
	});

	it('shows success message when a source is deleted', async () => {
		renderPage({}, {
			securitySourceDeleted: true,
			securitySources: { sources: [] }
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByText(/security source deleted/i)).toBeInTheDocument();
	});

	it('shows append error message', async () => {
		renderPage({}, {
			securitySourceAppendError: 'source is required',
			securitySources: { sources: [] }
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByText('source is required')).toBeInTheDocument();
	});

	it('shows delete error message', async () => {
		renderPage({}, {
			securitySourceDeleteError: 'Failed to delete security source',
			securitySources: { sources: [] }
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByText('Failed to delete security source')).toBeInTheDocument();
	});

	it('derives security sources from formResult when available', async () => {
		const formSources = {
			sources: [{ source: '172.16.0.0/12', description: 'Form override' }]
		};
		renderPage(
			{ securitySources: sampleSecuritySources },
			{ securitySources: formSources } as DetailPageForm
		);
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		// formResult sources should override data sources
		expect(within(section).getByText('172.16.0.0/12')).toBeInTheDocument();
		expect(within(section).getByText('Form override')).toBeInTheDocument();
		// original data sources should not appear
		expect(within(section).queryByText('192.168.1.0/24')).not.toBeInTheDocument();
	});
});
