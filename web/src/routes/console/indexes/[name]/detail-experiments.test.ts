import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} }),
	applyAction: vi.fn(async () => {})
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

import IndexDetailPage from './+page.svelte';
import ExperimentDetailChildPage from './experiments/[experimentId]/+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import {
	sampleExperiments,
	sampleExperimentResults,
	sampleExperimentResultsNotReady,
	sampleExperimentResultsDaysGate,
	sampleExperimentResultsWithSignals,
	sampleConcludedExperimentResults,
	createMockPageData
} from './detail.test.shared';

afterEach(() => {
	cleanup();
	clearLog();
	vi.clearAllMocks();
});

describe('Index detail page — Experiments', () => {
	function renderExperimentDetail(overrides: Record<string, unknown> = {}) {
		const selectedExperiment = sampleExperiments.abtests[0];
		const selectedExperimentResults = sampleExperimentResults;

		return render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment,
				selectedExperimentResults,
				experimentDetailBackHref: '?tab=experiments',
				...overrides
			}),
			form: null
		});
	}

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
		expect(screen.getByRole('link', { name: 'Ranking test' })).toHaveAttribute(
			'href',
			'/console/indexes/products/experiments/7'
		);
	});

	it('experiments table uses fallback labels for blank-name rows', async () => {
		const blankNameExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				sampleExperiments.abtests[1]
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: blankNameExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));

		expect(screen.getByRole('link', { name: 'Unnamed experiment #77' })).toHaveAttribute(
			'href',
			'/console/indexes/products/experiments/77'
		);
	});

	it('create experiment button opens wizard dialog at step 1', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Create Experiment' }));

		expect(screen.getByTestId('create-experiment-dialog')).toBeInTheDocument();
		expect(screen.getByText(/Step 1 of 4/)).toBeInTheDocument();
		expect(screen.getByLabelText('Experiment name')).toBeInTheDocument();
		expect(screen.getByText('Primary metric')).toBeInTheDocument();
	});

	it('create experiment payload includes endAt after navigating wizard to step 4', async () => {
		vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));
		const { container } = render(IndexDetailPage, {
			data: createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Create Experiment' }));

		await fireEvent.input(screen.getByLabelText('Experiment name'), {
			target: { value: 'runtime-window-test' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
		await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
		await fireEvent.click(screen.getByRole('button', { name: /Next/ }));

		expect(screen.getByText(/Step 4 of 4/)).toBeInTheDocument();
		const hiddenPayloadInput = container.querySelector<HTMLInputElement>(
			'input[name="experiment"]'
		);
		expect(hiddenPayloadInput).not.toBeNull();
		const payload = JSON.parse(hiddenPayloadInput!.value) as { endAt?: string };
		expect(payload.endAt).toBeDefined();
		expect(new Date(payload.endAt!).toString()).not.toBe('Invalid Date');

		vi.useRealTimers();
	});

	it('direct detail render does not depend on in-tab openExperiment state', () => {
		renderExperimentDetail();

		expect(screen.getByTestId('experiment-detail-name')).toBeInTheDocument();
		expect(screen.getByTestId('experiment-detail-status')).toBeInTheDocument();
		expect(screen.getByTestId('experiment-detail-index')).toBeInTheDocument();
		expect(screen.getByTestId('experiment-detail-primary-metric')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Back to experiments' })).toBeInTheDocument();
		expect(screen.getByText('Primary Metric: ctr')).toBeInTheDocument();
		const controlArm = screen.getByTestId('experiment-arm-control');
		const variantArm = screen.getByTestId('experiment-arm-variant');
		expect(controlArm).toBeInTheDocument();
		expect(variantArm).toBeInTheDocument();
		expect(controlArm).toHaveTextContent('Searches: 1,200');
		expect(controlArm).toHaveTextContent('Users: 500');
		expect(controlArm).toHaveTextContent('Clicks: 140');
		expect(controlArm).toHaveTextContent('CTR: 12.0%');
		expect(controlArm).toHaveTextContent('Conversion: 4.0%');
		expect(controlArm).toHaveTextContent('Revenue/Search: $0.00');
		expect(controlArm).toHaveTextContent('Mean click rank: 3.20');
		expect(variantArm).toHaveTextContent('Searches: 1,200');
		expect(variantArm).toHaveTextContent('Users: 490');
		expect(variantArm).toHaveTextContent('Clicks: 160');
		expect(variantArm).toHaveTextContent('CTR: 13.0%');
		expect(variantArm).toHaveTextContent('Conversion: 5.0%');
		expect(variantArm).toHaveTextContent('Revenue/Search: $0.00');
		expect(variantArm).toHaveTextContent('Mean click rank: 2.80');
		expect(controlArm).toHaveTextContent('CUPED adjusted');
		expect(variantArm).toHaveTextContent('CUPED adjusted');
		expect(screen.getAllByText('Declare Winner').length).toBeGreaterThanOrEqual(1);
		const significanceCard = screen.getByTestId('experiment-significance-card');
		expect(significanceCard).toHaveTextContent('97.0% confidence');
		expect(significanceCard).toHaveTextContent('Winner: variant');
		expect(significanceCard).toHaveTextContent('Relative improvement: 8.0%');
	});

	it('direct detail render uses fallback labels for blank-name experiments', () => {
		const blankNameExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				sampleExperiments.abtests[1]
			],
			count: 2,
			total: 2
		};

		renderExperimentDetail({
			experiments: blankNameExperiments,
			selectedExperiment: blankNameExperiments.abtests[0]
		});

		expect(screen.getByTestId('experiment-detail-name')).toHaveTextContent(
			'Unnamed experiment #77'
		);
	});

	it('experiment detail back control is a real link', () => {
		renderExperimentDetail();
		expect(screen.getByRole('link', { name: 'Back to experiments' })).toHaveAttribute(
			'href',
			'?tab=experiments'
		);
	});

	it('experiment detail shows status and progress bar when minimum sample is not ready', () => {
		renderExperimentDetail({
			selectedExperimentResults: sampleExperimentResultsNotReady
		});

		expect(screen.getByText(/Status:/i)).toBeInTheDocument();
		expect(screen.getByTestId('experiment-progress')).toBeInTheDocument();
		expect(screen.getByRole('progressbar', { name: 'Experiment progress' })).toBeInTheDocument();
		expect(screen.getByText(/420 \/ 1000/)).toBeInTheDocument();
	});

	it('concluded experiment shows conclusion summary card', async () => {
		const concludedExperiments = {
			abtests: [{ ...sampleExperiments.abtests[0], status: 'concluded' }],
			count: 1,
			total: 1
		};

		renderExperimentDetail({
			experiments: concludedExperiments,
			selectedExperiment: concludedExperiments.abtests[0],
			selectedExperimentResults: sampleConcludedExperimentResults,
			experimentResults: { '7': sampleConcludedExperimentResults }
		});

		const conclusionCard = screen.getByTestId('experiment-conclusion-card');
		expect(conclusionCard).toBeInTheDocument();
		expect(conclusionCard).toHaveTextContent('Winner: control');
		expect(conclusionCard).toHaveTextContent('Confidence: 91.0%');
		expect(conclusionCard).toHaveTextContent(
			'Metric comparison (Revenue/Search): Control $2.05 vs Variant $1.75'
		);
		expect(conclusionCard).toHaveTextContent('Promoted: Yes');
		expect(conclusionCard).toHaveTextContent('Ended: Mar 21, 2026');
		expect(screen.getByText(/rolled out b; mobile lift was 8%/i)).toBeInTheDocument();
		expect(screen.getByTestId('experiment-recommendation')).toBeInTheDocument();
		expect(screen.getByText('Recommendation')).toBeInTheDocument();
		expect(screen.getByText(/variant has higher ctr and should be promoted/i)).toBeInTheDocument();
	});

	it('non-concluded experiment with recommendation renders recommendation text', async () => {
		const resultsWithRecommendation = {
			...sampleExperimentResults,
			recommendation: 'Variant has higher CTR and should be promoted'
		};

		renderExperimentDetail({
			selectedExperimentResults: resultsWithRecommendation,
			experimentResults: { '7': resultsWithRecommendation }
		});

		expect(screen.getByTestId('experiment-recommendation')).toBeInTheDocument();
		expect(screen.getByText('Variant has higher CTR and should be promoted')).toBeInTheDocument();
	});

	it('signal cards and banners render with spec test ids', () => {
		renderExperimentDetail({
			selectedExperimentResults: sampleExperimentResultsWithSignals,
			experimentResults: { '7': sampleExperimentResultsWithSignals }
		});

		const srmBanner = screen.getByTestId('experiment-srm-banner');
		const guardrailBanner = screen.getByTestId('experiment-guardrail-banner');
		const significanceCard = screen.getByTestId('experiment-significance-card');
		const interleavingCard = screen.getByTestId('experiment-interleaving-card');
		expect(srmBanner).toBeInTheDocument();
		expect(guardrailBanner).toBeInTheDocument();
		expect(significanceCard).toBeInTheDocument();
		expect(interleavingCard).toBeInTheDocument();
		expect(screen.getByText('Traffic split mismatch detected.')).toBeInTheDocument();
		expect(guardrailBanner).toHaveTextContent(
			'conversion_rate: control 4.2% vs variant 3.1% (26.2% drop)'
		);
		expect(significanceCard).toHaveTextContent('Winner: variant');
		expect(significanceCard).toHaveTextContent('Relative improvement: 8.0%');
		expect(interleavingCard).toHaveTextContent('Variant wins interleaving');
		expect(interleavingCard).toHaveTextContent('Wins: control 45, variant 63, ties 8');
		expect(interleavingCard).toHaveTextContent('P-value: 3.0%');
	});

	it('renders outlier-users notice text when outlierUsersExcluded is present', () => {
		renderExperimentDetail({
			selectedExperimentResults: {
				...sampleExperimentResults,
				outlierUsersExcluded: 12
			} as never
		});
		expect(screen.getByTestId('experiment-outlier-notice')).toHaveTextContent(
			'12 users excluded as outliers (bot-like traffic patterns).'
		);
	});

	it('renders unstable-userToken notice when unstableIdFraction exceeds threshold', () => {
		renderExperimentDetail({
			selectedExperimentResults: {
				...sampleExperimentResults,
				unstableIdFraction: 0.12
			} as never
		});
		expect(screen.getByTestId('experiment-unstable-token-notice')).toHaveTextContent(
			'unstable userToken'
		);
	});

	it('shows CUPED badge on significance card surface when cupedApplied is true', () => {
		renderExperimentDetail();
		const significanceCard = screen.getByTestId('experiment-significance-card');
		expect(within(significanceCard).getByText('CUPED')).toBeInTheDocument();
	});

	it('renders bayesian and mean-click-rank cards for running results', () => {
		renderExperimentDetail();
		const bayesianCard = screen.getByTestId('experiment-bayesian-card');
		const meanClickRankCard = screen.getByTestId('experiment-mean-click-rank');
		expect(bayesianCard).toBeInTheDocument();
		expect(meanClickRankCard).toBeInTheDocument();
		expect(meanClickRankCard).toHaveTextContent('control 3.20 vs variant 2.80');
	});

	it('does not render significance card when significance data is unavailable', () => {
		renderExperimentDetail({
			selectedExperimentResults: {
				...sampleExperimentResults,
				significance: undefined
			}
		});
		expect(screen.queryByTestId('experiment-significance-card')).not.toBeInTheDocument();
	});

	it('declare winner opens conclude dialog with winner controls', async () => {
		const { container } = renderExperimentDetail();

		await fireEvent.click(screen.getByRole('button', { name: 'Declare Winner' }));

		expect(screen.getAllByText('Declare Winner').length).toBeGreaterThanOrEqual(1);
		expect(screen.getByLabelText('Control')).toBeInTheDocument();
		expect(screen.getByLabelText('Variant')).toBeInTheDocument();
		expect(screen.getByLabelText('No Winner')).toBeInTheDocument();
		expect(screen.getByLabelText('Reason')).toBeInTheDocument();
		expect(container.querySelector('form[action="../../?/concludeExperiment"]')).not.toBeNull();
	});

	it('detail stop confirmation remains open after confirm submit until server response', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		renderExperimentDetail();

		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment' }));
		await fireEvent.input(screen.getByTestId('confirm-input'), {
			target: { value: 'Ranking test' }
		});
		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));

		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
	});

	it('shows minimum-days warning and gate dialog before declare winner dialog', async () => {
		renderExperimentDetail({
			selectedExperimentResults: sampleExperimentResultsDaysGate,
			experimentResults: { '7': sampleExperimentResultsDaysGate }
		});

		expect(screen.getByTestId('minimum-days-warning')).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Declare Winner' }));
		expect(screen.getAllByText(/minimum runtime days are not complete/i).length).toBeGreaterThan(0);
		expect(screen.queryByTestId('declare-winner-dialog')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
		expect(screen.getByTestId('declare-winner-dialog')).toBeInTheDocument();
	});

	it('stop experiment requires typed confirmation before submit', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment 7' }));

		expect(screen.getByText('Stop experiment "Ranking test"?')).toBeInTheDocument();
		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		expect(confirmButton).toBeDisabled();

		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		const confirmInput = screen.getByTestId('confirm-input');
		await fireEvent.input(confirmInput, { target: { value: 'wrong name' } });
		expect(confirmButton).toBeDisabled();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.input(confirmInput, { target: { value: ' Ranking test ' } });
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
	});

	it('lifecycle confirm does not auto-submit when experiment name is whitespace-only', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const blankNameExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				sampleExperiments.abtests[1]
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: blankNameExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment 77' }));

		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).not.toHaveBeenCalled();
	});

	it('blank-name stop confirmation stays target-specific with experiment ID fallback', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const blankNameExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				sampleExperiments.abtests[1]
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: blankNameExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment 77' }));

		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		const confirmInput = screen.getByTestId('confirm-input');

		expect(screen.getByText('Stop experiment "Unnamed experiment #77"?')).toBeInTheDocument();
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'STOP' } });
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment #77' } });
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
	});

	it('blank-name stop confirmation phrase does not collide with a named experiment', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const potentiallyCollidingExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				{
					...sampleExperiments.abtests[1],
					abTestID: 13,
					status: 'running',
					name: 'Unnamed experiment #77'
				}
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: potentiallyCollidingExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment 77' }));

		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		const confirmInput = screen.getByTestId('confirm-input');

		expect(screen.getByText('Stop experiment "Unnamed experiment ID 77"?')).toBeInTheDocument();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment #77' } });
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment ID 77' } });
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
	});

	it('blank-name stop confirmation phrase treats padded collisions as taken', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const paddedCollisionExperiments = {
			abtests: [
				{ ...sampleExperiments.abtests[0], abTestID: 77, name: '   ' },
				{
					...sampleExperiments.abtests[1],
					abTestID: 13,
					status: 'running',
					name: 'Unnamed experiment #77 '
				}
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: paddedCollisionExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Stop experiment 77' }));

		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		const confirmInput = screen.getByTestId('confirm-input');

		expect(screen.getByText('Stop experiment "Unnamed experiment ID 77"?')).toBeInTheDocument();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment #77' } });
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment ID 77' } });
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
	});

	it('blank-name delete confirmation stays target-specific with experiment ID fallback', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const blankNameExperiments = {
			abtests: [
				sampleExperiments.abtests[0],
				{ ...sampleExperiments.abtests[1], abTestID: 88, name: '' }
			],
			count: 2,
			total: 2
		};

		render(IndexDetailPage, {
			data: createMockPageData({ experiments: blankNameExperiments }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Delete experiment 88' }));

		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		const confirmInput = screen.getByTestId('confirm-input');

		expect(screen.getByText('Delete experiment "Unnamed experiment #88"?')).toBeInTheDocument();
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'DELETE' } });
		expect(confirmButton).toBeDisabled();
		await fireEvent.input(confirmInput, { target: { value: 'Unnamed experiment #88' } });
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
	});

	it('delete experiment requires typed confirmation before submit', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Experiments' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Delete experiment 9' }));

		expect(screen.getByText('Delete experiment "Stopped test"?')).toBeInTheDocument();
		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		expect(confirmButton).toBeDisabled();

		await fireEvent.input(screen.getByTestId('confirm-input'), {
			target: { value: ' Stopped test ' }
		});
		expect(confirmButton).not.toBeDisabled();
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
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
