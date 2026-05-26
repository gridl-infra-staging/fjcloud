import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

const clipboardMocks = vi.hoisted(() => ({
	writeTextToClipboard: vi.fn()
}));

const routeMocks = vi.hoisted(() => ({
	goto: vi.fn(),
	url: new URL('http://localhost/console/logs')
}));

vi.mock('$app/environment', () => ({
	browser: true
}));

vi.mock('$lib/clipboard', () => ({
	writeTextToClipboard: clipboardMocks.writeTextToClipboard
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: routeMocks.goto
}));

vi.mock('$app/state', () => ({
	page: {
		get url() {
			return routeMocks.url;
		}
	}
}));

import LogsPage from './+page.svelte';
import { appendLogEntry, clearLog } from '$lib/api-logs/store';
import type { SanitizedLogEntry } from '$lib/api-logs/sanitization';

function setRouteUrl(pathAndQuery: string): void {
	routeMocks.url = new URL(pathAndQuery, 'http://localhost');
}

function renderLogsPageAt(pathAndQuery: string): void {
	setRouteUrl(pathAndQuery);
	render(LogsPage);
}

function expectViewToggleState(expectedCompact: boolean): void {
	const compactButton = screen.getByRole('button', { name: 'Compact view' });
	const detailedButton = screen.getByRole('button', { name: 'Detailed view' });
	if (expectedCompact) {
		expect(compactButton).toHaveAttribute('aria-pressed', 'true');
		expect(detailedButton).toHaveAttribute('aria-pressed', 'false');
		return;
	}
	expect(compactButton).toHaveAttribute('aria-pressed', 'false');
	expect(detailedButton).toHaveAttribute('aria-pressed', 'true');
}

function expectGotoCalledWithPath(pathAndQuery: string): void {
	expect(routeMocks.goto).toHaveBeenCalledTimes(1);
	expect(routeMocks.goto).toHaveBeenCalledWith(pathAndQuery, {
		keepFocus: true,
		noScroll: true
	});
}

afterEach(() => {
	cleanup();
	clearLog();
	clipboardMocks.writeTextToClipboard.mockReset();
	vi.clearAllMocks();
	setRouteUrl('/console/logs');
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

	it('uses compact mode when URL has view=compact', () => {
		renderLogsPageAt('/console/logs?view=compact');
		expectViewToggleState(true);
	});

	it('uses detailed mode when URL has view=detailed', () => {
		renderLogsPageAt('/console/logs?view=detailed');
		expectViewToggleState(false);
	});

	it('defaults to detailed mode when view query is missing', () => {
		renderLogsPageAt('/console/logs');
		expectViewToggleState(false);
	});

	it('falls back to detailed mode when view query is invalid', () => {
		renderLogsPageAt('/console/logs?view=invalid');
		expectViewToggleState(false);
	});

	it('canonicalizes invalid view query to detailed when detailed is selected', async () => {
		renderLogsPageAt('/console/logs?view=invalid&source=dashboard');

		await fireEvent.click(screen.getByRole('button', { name: 'Detailed view' }));

		expectGotoCalledWithPath('/console/logs?view=detailed&source=dashboard');
	});

	it('merges query params while changing only view mode', async () => {
		renderLogsPageAt('/console/logs?source=dashboard&debug=1');

		await fireEvent.click(screen.getByRole('button', { name: 'Compact view' }));

		expectGotoCalledWithPath('/console/logs?source=dashboard&debug=1&view=compact');
	});

	it('persists mode on reload by re-reading it from URL', () => {
		renderLogsPageAt('/console/logs?view=compact');
		expectViewToggleState(true);
		cleanup();

		renderLogsPageAt('/console/logs?view=detailed');
		expectViewToggleState(false);
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
		expect(rows).toHaveLength(3);
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

	it('toggles row-local request and response details without reordering rows', async () => {
		appendLogEntry(
			makeSanitizedEntry({
				url: '?/search',
				method: 'POST',
				status: 200,
				body: { query: 'shoes', filters: 'brand:nike' },
				response: { hits: [{ objectID: 'doc-1' }], nbHits: 1 }
			})
		);
		appendLogEntry(
			makeSanitizedEntry({
				url: '?/saveSettings',
				method: 'PATCH',
				status: 204,
				body: { disableTypoToleranceOnAttributes: ['name'] },
				response: { updatedAt: '2026-05-26T00:00:00.000Z' }
			})
		);

		render(LogsPage);

		const panel = screen.getByTestId('search-log-panel');
		const firstDataRow = within(panel).getByTestId('api-log-row-0');
		const secondDataRow = within(panel).getByTestId('api-log-row-1');
		expect(within(firstDataRow).getByText('?/saveSettings')).toBeInTheDocument();
		expect(within(secondDataRow).getByText('?/search')).toBeInTheDocument();

		await fireEvent.click(firstDataRow);
		expect(screen.getByText('Request')).toBeInTheDocument();
		expect(screen.getByText('Response')).toBeInTheDocument();
		const details = panel.querySelectorAll('pre');
		expect(details).toHaveLength(2);
		expect(details[0]?.textContent).toContain('"disableTypoToleranceOnAttributes"');
		expect(details[1]?.textContent).toContain('"updatedAt"');

		await fireEvent.click(firstDataRow);
		expect(screen.queryByText('Request')).not.toBeInTheDocument();
		expect(screen.queryByText('Response')).not.toBeInTheDocument();

		await fireEvent.click(secondDataRow);
		expect(screen.getByText('Request')).toBeInTheDocument();
		expect(screen.getByText('Response')).toBeInTheDocument();
		const movedDetails = panel.querySelectorAll('pre');
		expect(movedDetails).toHaveLength(2);
		expect(movedDetails[0]?.textContent).toContain('"filters": "brand:nike"');
		expect(movedDetails[1]?.textContent).toContain('"objectID": "doc-1"');

		const firstDataRowAfterExpand = within(panel).getByTestId('api-log-row-0');
		const secondDataRowAfterExpand = within(panel).getByTestId('api-log-row-1');
		expect(within(firstDataRowAfterExpand).getByText('?/saveSettings')).toBeInTheDocument();
		expect(within(secondDataRowAfterExpand).getByText('?/search')).toBeInTheDocument();
	});

	it('clears all entries when clear button is clicked', async () => {
		appendLogEntry(makeSanitizedEntry({ url: '?/search' }));
		appendLogEntry(makeSanitizedEntry({ url: '?/deleteRule' }));

		render(LogsPage);

		expect(within(screen.getByTestId('search-log-panel')).getAllByRole('row')).toHaveLength(3);
		await fireEvent.click(within(screen.getByTestId('search-log-panel')).getAllByRole('row')[1]);
		expect(screen.getByText(/Request/i)).toBeInTheDocument();
		expect(screen.getByText(/Response/i)).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /clear/i }));

		expect(screen.getByText('No API calls recorded')).toBeInTheDocument();
		expect(screen.queryByText(/Request/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/Response/i)).not.toBeInTheDocument();
		expect(within(screen.getByTestId('search-log-panel')).getAllByRole('row')).toHaveLength(2);
	});

	it('renders a copy-as-curl control for each row and shows redaction disclaimer text', () => {
		appendLogEntry(makeSanitizedEntry({ url: '?/search' }));
		appendLogEntry(makeSanitizedEntry({ url: '?/saveSettings', method: 'PATCH' }));

		render(LogsPage);

		expect(screen.getAllByRole('button', { name: 'Copy as curl' })).toHaveLength(2);
		expect(
			screen.getByText('Copied curl commands always redact authorization credentials.')
		).toBeInTheDocument();
	});

	it('copies the expected curl string for a row', async () => {
		clipboardMocks.writeTextToClipboard.mockResolvedValue('success');
		appendLogEntry(
			makeSanitizedEntry({
				url: '?/saveSettings',
				method: 'PATCH',
				body: { enabled: true, feature: 'typoTolerance' }
			})
		);

		render(LogsPage);

		await fireEvent.click(screen.getByRole('button', { name: 'Copy as curl' }));

		expect(clipboardMocks.writeTextToClipboard).toHaveBeenCalledWith(
			`curl -X PATCH '?/saveSettings' -H 'Authorization: [REDACTED]' -H 'Content-Type: application/json' -d '{"enabled":true,"feature":"typoTolerance"}'`
		);
	});

	it('preserves row-selection behavior when copy control is clicked', async () => {
		clipboardMocks.writeTextToClipboard.mockResolvedValue('success');
		appendLogEntry(makeSanitizedEntry({ url: '?/search' }));

		render(LogsPage);

		await fireEvent.click(screen.getByRole('button', { name: 'Copy as curl' }));
		expect(screen.queryByText('Request')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('api-log-row-0'));
		expect(screen.getByText('Request')).toBeInTheDocument();
	});

	it('renders export controls in the logs panel', () => {
		render(LogsPage);
		expect(screen.getByTestId('api-log-export-controls')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Export JSON' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Export CSV' })).toBeInTheDocument();
	});

	it('exports all stored rows as json with exact filename and content type', async () => {
		appendLogEntry(makeSanitizedEntry({ url: '?/search', method: 'POST' }));
		appendLogEntry(makeSanitizedEntry({ url: '?/saveSettings', method: 'PATCH' }));
		render(LogsPage);

		await fireEvent.click(screen.getByTestId('api-log-row-0'));
		expect(screen.getByText('Request')).toBeInTheDocument();

		const createObjectURL = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:json');
		const revokeObjectURL = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
		const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});

		await fireEvent.click(screen.getByRole('button', { name: 'Export JSON' }));

		expect(createObjectURL).toHaveBeenCalledTimes(1);
		const firstCall = createObjectURL.mock.calls[0];
		expect(firstCall).toBeDefined();
		const blobArg = firstCall?.[0] as Blob;
		expect(blobArg.type).toBe('application/json');
		const payload = await blobArg.text();
		const parsed = JSON.parse(payload) as Array<{ url: string }>;
		expect(parsed).toHaveLength(2);
		expect(parsed[0]?.url).toBe('?/saveSettings');
		expect(parsed[1]?.url).toBe('?/search');

		expect(clickSpy).toHaveBeenCalledTimes(1);
		const anchor = clickSpy.mock.instances[0] as HTMLAnchorElement;
		expect(anchor.download).toBe('api_logs.json');
		expect(anchor.href).toBe('blob:json');
		expect(revokeObjectURL).toHaveBeenCalledWith('blob:json');
		clickSpy.mockRestore();
		createObjectURL.mockRestore();
		revokeObjectURL.mockRestore();
	});

	it('exports all stored rows as csv with exact filename and content type', async () => {
		appendLogEntry(makeSanitizedEntry({ url: '?/search', method: 'POST' }));
		appendLogEntry(makeSanitizedEntry({ url: '?/saveSettings', method: 'PATCH' }));
		render(LogsPage);

		await fireEvent.click(screen.getByRole('button', { name: 'Compact view' }));

		const createObjectURL = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:csv');
		const revokeObjectURL = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
		const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});

		await fireEvent.click(screen.getByRole('button', { name: 'Export CSV' }));

		expect(createObjectURL).toHaveBeenCalledTimes(1);
		const firstCall = createObjectURL.mock.calls[0];
		expect(firstCall).toBeDefined();
		const blobArg = firstCall?.[0] as Blob;
		expect(blobArg.type).toBe('text/csv;charset=utf-8');
		const payload = await blobArg.text();
		const [header, firstRow, secondRow] = payload.trimEnd().split('\n');
		expect(header).toBe('id,timestamp,method,url,status,duration,body,response');
		expect(firstRow?.includes('?/saveSettings')).toBe(true);
		expect(secondRow?.includes('?/search')).toBe(true);

		expect(clickSpy).toHaveBeenCalledTimes(1);
		const anchor = clickSpy.mock.instances[0] as HTMLAnchorElement;
		expect(anchor.download).toBe('api_logs.csv');
		expect(anchor.href).toBe('blob:csv');
		expect(revokeObjectURL).toHaveBeenCalledWith('blob:csv');
		clickSpy.mockRestore();
		createObjectURL.mockRestore();
		revokeObjectURL.mockRestore();
	});
});
