import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock, applyActionMock, deserializeMock, instantSearchMockFn, invalidateAllMock } =
	vi.hoisted(() => ({
		enhanceMock: vi.fn((form: HTMLFormElement) => {
			void form;
			return { destroy: () => {} };
		}),
		applyActionMock: vi.fn(),
		deserializeMock: vi.fn(),
		instantSearchMockFn: vi.fn(),
		invalidateAllMock: vi.fn()
	}));

vi.mock('$app/forms', () => ({
	enhance: enhanceMock,
	applyAction: applyActionMock,
	deserialize: deserializeMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: invalidateAllMock
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
		instantSearchMockFn(anchor, props);
	}
}));

import IndexDetailPage from './+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import { sampleSecuritySources, createMockPageData } from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
	clearLog();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
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

	it('renders load error state and retries via invalidateAll', async () => {
		renderPage({ securitySourcesLoadError: 'Failed to load security sources' });
		await openTab('Security Sources');

		expect(screen.getByTestId('security-sources-error-state')).toBeInTheDocument();
		expect(screen.queryByText(/no security sources/i)).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('security-sources-retry-btn'));
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
	});

	it('keeps load error state for validation-only append failures', async () => {
		renderPage({ securitySourcesLoadError: 'Failed to load security sources' }, {
			securitySourceAppendError: 'source is required',
			securitySources: { sources: [] }
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByTestId('security-sources-error-state')).toBeInTheDocument();
		expect(screen.queryByText(/no security sources/i)).not.toBeInTheDocument();
		expect(screen.getByText('source is required')).toBeInTheDocument();
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

	it('renders source count badge from loaded sources', async () => {
		renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		expect(screen.getByTestId('security-sources-entry-count')).toHaveTextContent('2');
	});

	it('renders Add Source trigger and hides add inputs before dialog opens', async () => {
		renderPage();
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		expect(within(section).getByTestId('add-security-source-btn')).toBeInTheDocument();
		expect(within(section).queryByLabelText(/^source$/i)).not.toBeInTheDocument();
		expect(within(section).queryByLabelText(/^description$/i)).not.toBeInTheDocument();
	});

	it('keeps Add Source trigger visible but disabled during load errors', async () => {
		renderPage({ securitySourcesLoadError: 'Failed to load security sources' });
		await openTab('Security Sources');

		const addSourceButton = screen.getByTestId('add-security-source-btn');
		expect(addSourceButton).toBeInTheDocument();
		expect(addSourceButton).toBeDisabled();
	});

	it('opens Add Security Source editor dialog with source fields and submit label', async () => {
		renderPage();
		await openTab('Security Sources');

		await fireEvent.click(screen.getByTestId('add-security-source-btn'));

		const dialog = screen.getByRole('dialog', { name: 'Add Security Source' });
		expect(dialog).toBeInTheDocument();
		expect(within(dialog).getByTestId('editor-dialog-field-source')).toBeInTheDocument();
		expect(within(dialog).getByTestId('editor-dialog-field-description')).toBeInTheDocument();
		expect(within(dialog).getByRole('button', { name: 'Add Source' })).toBeInTheDocument();
	});

	it('shows inline source required validation for whitespace-only source input', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);
		renderPage();
		await openTab('Security Sources');
		await fireEvent.click(screen.getByTestId('add-security-source-btn'));

		const dialog = screen.getByRole('dialog', { name: 'Add Security Source' });
		const sourceField = within(dialog).getByTestId('editor-dialog-field-source');
		await fireEvent.input(sourceField, {
			target: { value: '   ' }
		});
		await fireEvent.blur(sourceField);

		const dialogAlert = within(dialog).getByRole('alert');
		expect(dialogAlert).toHaveTextContent('Source is required.');
		expect(fetchMock).not.toHaveBeenCalled();
		expect(screen.queryByTestId('security-sources-section')).toBeInTheDocument();
		expect(screen.queryByText('source is required')).not.toBeInTheDocument();
	});

	it('clears inline source validation once non-whitespace input is entered', async () => {
		renderPage();
		await openTab('Security Sources');
		await fireEvent.click(screen.getByTestId('add-security-source-btn'));

		const dialog = screen.getByRole('dialog', { name: 'Add Security Source' });
		const sourceField = within(dialog).getByTestId('editor-dialog-field-source');
		await fireEvent.input(sourceField, { target: { value: '   ' } });
		await fireEvent.blur(sourceField);
		expect(within(dialog).getByRole('alert')).toHaveTextContent('Source is required.');

		await fireEvent.input(sourceField, { target: { value: ' 1' } });
		await waitFor(() => {
			expect(within(dialog).queryByRole('alert')).not.toBeInTheDocument();
		});
		expect(dialog).toBeInTheDocument();
	});

	it('applies failed append action results before surfacing dialog error', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			text: vi.fn().mockResolvedValue('serialized-failure')
		});
		vi.stubGlobal('fetch', fetchMock);
		deserializeMock.mockReturnValue({
			type: 'failure',
			status: 403,
			data: {
				_authSessionExpired: true,
				securitySourceAppendError: 'Session expired',
				securitySources: sampleSecuritySources,
				securitySourcesReloaded: false,
				securitySourcesLoadError: 'Failed to reload security sources'
			}
		});

		renderPage();
		await openTab('Security Sources');
		await fireEvent.click(screen.getByTestId('add-security-source-btn'));
		await fireEvent.input(screen.getByTestId('editor-dialog-field-source'), {
			target: { value: '172.16.0.0/12' }
		});
		const dialog = screen.getByRole('dialog', { name: 'Add Security Source' });
		await fireEvent.click(within(dialog).getByRole('button', { name: 'Add Source' }));

		await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
		await waitFor(() => expect(applyActionMock).toHaveBeenCalledTimes(1));
		expect(screen.getByRole('alert')).toHaveTextContent('Session expired');
		expect(dialog).toBeInTheDocument();
	});

	it('renders delete button for each source row', async () => {
		renderPage({ securitySources: sampleSecuritySources });
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		const deleteButtons = within(section).getAllByRole('button', { name: /delete/i });
		expect(deleteButtons).toHaveLength(2);
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

		// Delete forms remain enhanced for action posts.
		const enhancedForms = enhanceMock.mock.calls.map((c: unknown[]) => c[0] as HTMLFormElement);
		const actions = enhancedForms.map((f) => f.getAttribute('action'));
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
			securitySources: { sources: [] },
			securitySourcesReloaded: true
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

	it('shows action-level reload error instead of clearing back to the stale loaded state', async () => {
		renderPage({ securitySources: sampleSecuritySources }, {
			securitySourceAppended: true,
			securitySourcesLoadError: 'Failed to reload security sources'
		} as DetailPageForm);
		await openTab('Security Sources');

		expect(screen.getByText(/security source added/i)).toBeInTheDocument();
		expect(screen.getByTestId('security-sources-error-state')).toBeInTheDocument();
		expect(screen.getByText('Failed to reload security sources')).toBeInTheDocument();
		expect(screen.queryByText('No security sources configured')).not.toBeInTheDocument();
	});

	it('derives security sources from formResult when available', async () => {
		const formSources = {
			sources: [{ source: '172.16.0.0/12', description: 'Form override' }]
		};
		renderPage({ securitySources: sampleSecuritySources }, {
			securitySources: formSources
		} as DetailPageForm);
		await openTab('Security Sources');

		const section = screen.getByTestId('security-sources-section');
		// formResult sources should override data sources
		expect(within(section).getByText('172.16.0.0/12')).toBeInTheDocument();
		expect(within(section).getByText('Form override')).toBeInTheDocument();
		// original data sources should not appear
		expect(within(section).queryByText('192.168.1.0/24')).not.toBeInTheDocument();
	});
});
