import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/logs') }
}));

import LogsPage from './+page.svelte';
import { appendLogEntry, clearLog } from '$lib/api-logs/store';
import type { SanitizedLogEntry } from '$lib/api-logs/sanitization';

afterEach(() => {
	cleanup();
	clearLog();
	vi.clearAllMocks();
});

function makeSanitizedEntry(overrides: Partial<SanitizedLogEntry> = {}): SanitizedLogEntry {
	return {
		method: 'POST',
		url: '?/search',
		status: 200,
		duration: 12,
		body: { query: 'shoes' },
		response: { hits: [], nbHits: 0 },
		...overrides
	};
}

describe('Dashboard logs page', () => {
	it('renders the page heading', () => {
		render(LogsPage);
		expect(screen.getByRole('heading', { name: /api logs/i })).toBeInTheDocument();
	});

	it('shows empty state when no log entries exist', () => {
		render(LogsPage);
		expect(screen.getByText('No API calls recorded')).toBeInTheDocument();
	});

	it('renders seeded store entries in newest-first order', () => {
		appendLogEntry(
			makeSanitizedEntry({ url: '?/search', method: 'POST', status: 200, duration: 12 })
		);
		appendLogEntry(
			makeSanitizedEntry({ url: '?/saveSettings', method: 'PATCH', status: 503, duration: 47 })
		);

		render(LogsPage);

		const panel = screen.getByTestId('search-log-panel');
		expect(within(panel).getByRole('columnheader', { name: 'Method' })).toBeInTheDocument();
		expect(within(panel).getByRole('columnheader', { name: 'URL' })).toBeInTheDocument();
		expect(within(panel).getByRole('columnheader', { name: 'Status' })).toBeInTheDocument();
		expect(within(panel).getByRole('columnheader', { name: 'Duration' })).toBeInTheDocument();

		const rows = within(panel).getAllByRole('row');
		// header row + 2 data rows
		expect(rows).toHaveLength(3);
		// Newest first: saveSettings before search.
		const firstDataRow = within(panel).getByTestId('api-log-row-0');
		const secondDataRow = within(panel).getByTestId('api-log-row-1');
		expect(within(firstDataRow).getByText('PATCH')).toBeInTheDocument();
		expect(within(firstDataRow).getByText('?/saveSettings')).toBeInTheDocument();
		expect(within(firstDataRow).getByText('503')).toBeInTheDocument();
		expect(within(firstDataRow).getByText('47 ms')).toBeInTheDocument();
		expect(within(secondDataRow).getByText('POST')).toBeInTheDocument();
		expect(within(secondDataRow).getByText('?/search')).toBeInTheDocument();
		expect(within(secondDataRow).getByText('200')).toBeInTheDocument();
		expect(within(secondDataRow).getByText('12 ms')).toBeInTheDocument();
	});

	it('expands request detail when a row is clicked', async () => {
		appendLogEntry(
			makeSanitizedEntry({
				url: '?/search',
				status: 200,
				body: { query: 'shoes', filters: 'brand:nike' },
				response: { hits: [{ objectID: 'doc-1' }], nbHits: 1 }
			})
		);

		render(LogsPage);

		const panel = screen.getByTestId('search-log-panel');
		const dataRow = within(panel).getAllByRole('row')[1];
		await fireEvent.click(dataRow);

		expect(screen.getByText('Request')).toBeInTheDocument();
		const requestJson = panel.querySelector('pre')?.textContent;
		expect(requestJson).toBeTruthy();

		const parsedDetail = JSON.parse(requestJson ?? '{}');
		expect(parsedDetail).toMatchObject({
			method: 'POST',
			url: '?/search',
			status: 200,
			duration: 12,
			body: { query: 'shoes', filters: 'brand:nike' }
		});
		expect(parsedDetail.response).toEqual({ hits: [{ objectID: 'doc-1' }], nbHits: 1 });
	});

	it('clears all entries when clear button is clicked', async () => {
		appendLogEntry(makeSanitizedEntry({ url: '?/search' }));
		appendLogEntry(makeSanitizedEntry({ url: '?/deleteRule' }));

		render(LogsPage);

		expect(within(screen.getByTestId('search-log-panel')).getAllByRole('row')).toHaveLength(3);
		await fireEvent.click(within(screen.getByTestId('search-log-panel')).getAllByRole('row')[1]);
		expect(screen.getByText(/Request/i)).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /clear/i }));

		expect(screen.getByText('No API calls recorded')).toBeInTheDocument();
		expect(screen.queryByText(/Request/i)).not.toBeInTheDocument();
		expect(within(screen.getByTestId('search-log-panel')).getAllByRole('row')).toHaveLength(2);
	});
});
