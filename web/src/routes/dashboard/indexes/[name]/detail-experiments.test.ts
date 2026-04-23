import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
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

import IndexDetailPage from './+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import {
	sampleExperiments,
	sampleExperimentResults,
	sampleExperimentResultsNotReady,
	sampleConcludedExperimentResults,
	createMockPageData
} from './detail.test.shared';

afterEach(() => {
	cleanup();
	clearLog();
	vi.clearAllMocks();
});

describe('Index detail page — Experiments', () => {
	it('experiments tab is available in tab layout', () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 }
			}),
			form: null
		});

		expect(screen.getByRole('tab', { name: 'Experiments' })).toBeInTheDocument();
	});

	it('experiments tab empty state shows create button', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		expect(screen.getByText('No experiments yet')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Create Experiment' })).toBeInTheDocument();
	});

	it('experiments table renders columns and lifecycle actions', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));

		expect(screen.getByText('Name')).toBeInTheDocument();
		expect(screen.getByText('Status')).toBeInTheDocument();
		expect(screen.getByText('Metric')).toBeInTheDocument();
		expect(screen.getByText('Traffic Split')).toBeInTheDocument();
		expect(screen.getByText('Created')).toBeInTheDocument();

		expect(screen.getByRole('button', { name: 'Stop experiment 7' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Delete experiment 9' })).toBeInTheDocument();
		expect(container.querySelector('form[action="?/stopExperiment"]')).not.toBeNull();
		expect(container.querySelector('form[action="?/deleteExperiment"]')).not.toBeNull();
	});

	it('create experiment button opens wizard form', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Create Experiment' }));

		expect(screen.getByLabelText('Experiment name')).toBeInTheDocument();
		expect(screen.getByLabelText('Primary metric')).toBeInTheDocument();
		expect(screen.getByLabelText('Variant mode')).toBeInTheDocument();
		expect(screen.getByLabelText('Traffic split %')).toBeInTheDocument();
		expect(screen.getByLabelText('Minimum runtime days')).toBeInTheDocument();
	});

	it('clicking experiment name shows detail view and metric cards', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Ranking test' }));

		expect(screen.getByText('Back to experiments')).toBeInTheDocument();
		expect(screen.getByText('Primary Metric: ctr')).toBeInTheDocument();
		expect(screen.getByText('Control arm')).toBeInTheDocument();
		expect(screen.getByText('Variant arm')).toBeInTheDocument();
		expect(screen.getAllByText('Declare Winner').length).toBeGreaterThanOrEqual(1);
		expect(screen.getByText(/97.0% confidence/)).toBeInTheDocument();
	});

	it('experiment detail shows status and progress bar when minimum sample is not ready', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experimentResults: { '7': sampleExperimentResultsNotReady }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Ranking test' }));

		expect(screen.getByText(/Status:/i)).toBeInTheDocument();
		expect(screen.getByRole('progressbar', { name: 'Experiment progress' })).toBeInTheDocument();
		expect(screen.getByText(/420 \/ 1000/)).toBeInTheDocument();
	});

	it('concluded experiment shows conclusion summary card', async () => {
		const concludedExperiments = {
			abtests: [{ ...sampleExperiments.abtests[0], status: 'concluded' }],
			count: 1,
			total: 1
		};

		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: concludedExperiments,
				experimentResults: { '7': sampleConcludedExperimentResults }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Ranking test' }));

		expect(screen.getByText('Conclusion')).toBeInTheDocument();
		expect(screen.getAllByText(/Winner: variant/i).length).toBeGreaterThanOrEqual(1);
		expect(screen.getByText(/should be promoted/i)).toBeInTheDocument();
	});

	it('sample ratio mismatch shows warning banner', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experimentResults: { '7': { ...sampleExperimentResults, sampleRatioMismatch: true } }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Ranking test' }));

		expect(screen.getByText('Traffic split mismatch detected.')).toBeInTheDocument();
	});

	it('declare winner opens conclude dialog with winner controls', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Ranking test' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Declare Winner' }));

		expect(screen.getAllByText('Declare Winner').length).toBeGreaterThanOrEqual(1);
		expect(screen.getByLabelText('Control')).toBeInTheDocument();
		expect(screen.getByLabelText('Variant')).toBeInTheDocument();
		expect(screen.getByLabelText('No Winner')).toBeInTheDocument();
		expect(screen.getByLabelText('Reason')).toBeInTheDocument();
		expect(container.querySelector('form[action="?/concludeExperiment"]')).not.toBeNull();
	});
});

describe('Index detail page — Search Log', () => {
	function getSearchLogDataRows(): HTMLTableRowElement[] {
		const panel = screen.getByTestId('search-log-panel');
		return Array.from(panel.querySelectorAll<HTMLTableRowElement>('tbody tr')).filter(
			(row) => row.querySelector('td')?.getAttribute('colspan') !== '4'
		);
	}

	it('shows Search Log toggle button in the header', () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				debugEvents: { events: [], count: 0 }
			}),
			form: null
		});

		expect(screen.getByRole('button', { name: /search log/i })).toBeInTheDocument();
	});

	it('toggling Search Log shows log table headers', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				debugEvents: { events: [], count: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('button', { name: /search log/i }));
		expect(screen.getByText('Method')).toBeInTheDocument();
		expect(screen.getByText('URL')).toBeInTheDocument();
		expect(screen.getByText('Status')).toBeInTheDocument();
		expect(screen.getByText('Duration')).toBeInTheDocument();
	});

	it('Search Log panel starts with empty state message', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				debugEvents: { events: [], count: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('button', { name: /search log/i }));
		expect(screen.getByText('No API calls recorded')).toBeInTheDocument();
	});

	it('records settings and suggestions form results in the shared search log', async () => {
		const data = createMockPageData({
			experiments: { abtests: [], count: 0, total: 0 },
			experimentResults: {},
			debugEvents: { events: [], count: 0 }
		});

		const { rerender } = render(IndexDetailPage, {
			data,
			form: { settingsSaved: true }
		});

		await rerender({
			data,
			form: { qsConfigSaved: true }
		});

		await fireEvent.click(screen.getByRole('button', { name: /search log/i }));

		const dataRows = getSearchLogDataRows();
		expect(dataRows).toHaveLength(2);
		expect(within(dataRows[0]).getByText('?/saveQsConfig')).toBeInTheDocument();
		expect(within(dataRows[1]).getByText('?/saveSettings')).toBeInTheDocument();
	});

	it('records repeated identical form results as separate search log entries', async () => {
		const data = createMockPageData({
			experiments: { abtests: [], count: 0, total: 0 },
			experimentResults: {},
			debugEvents: { events: [], count: 0 }
		});

		const { rerender } = render(IndexDetailPage, {
			data,
			form: { settingsSaved: true }
		});

		await rerender({ data, form: null });
		await rerender({ data, form: { settingsSaved: true } });

		await fireEvent.click(screen.getByRole('button', { name: /search log/i }));

		const dataRows = getSearchLogDataRows();
		expect(dataRows).toHaveLength(2);
		expect(within(dataRows[0]).getByText('?/saveSettings')).toBeInTheDocument();
		expect(within(dataRows[1]).getByText('?/saveSettings')).toBeInTheDocument();
	});

	it('does not duplicate logs when rerendering with the same form-result reference', async () => {
		const data = createMockPageData({
			experiments: { abtests: [], count: 0, total: 0 },
			experimentResults: {},
			debugEvents: { events: [], count: 0 }
		});
		const sharedFormResult = { settingsSaved: true };

		const { rerender } = render(IndexDetailPage, {
			data,
			form: sharedFormResult
		});

		await rerender({ data, form: sharedFormResult });

		await fireEvent.click(screen.getByRole('button', { name: /search log/i }));

		const dataRows = getSearchLogDataRows();
		expect(dataRows).toHaveLength(1);
		expect(within(dataRows[0]).getByText('?/saveSettings')).toBeInTheDocument();
	});
});
