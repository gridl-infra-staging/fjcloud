import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';

const formsMockState = vi.hoisted(() => ({
	applyActionMock: vi.fn(async () => {}),
	lastSubmitFormData: null as FormData | null,
	nextEnhanceResult: {
		type: 'success' as 'success' | 'failure' | 'redirect' | 'error',
		data: {} as Record<string, unknown>
	}
}));

vi.mock('$app/forms', () => ({
	enhance: (form: HTMLFormElement, submit?: (...args: unknown[]) => unknown) => {
		const handleSubmit = async (event: Event) => {
			event.preventDefault();
			if (!submit) return;
			const formData = new FormData(form);
			formsMockState.lastSubmitFormData = formData;
			const callback = submit({
				formElement: form,
				formData,
				action: new URL(form.action),
				cancel: () => {}
			});
			if (typeof callback !== 'function') return;
			await callback({
				result: formsMockState.nextEnhanceResult,
				update: async () => {}
			});
		};
		form.addEventListener('submit', handleSubmit);
		return {
			destroy: () => form.removeEventListener('submit', handleSubmit)
		};
	},
	applyAction: formsMockState.applyActionMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/indexes/products/experiments/7') }
}));

vi.mock('$app/environment', () => ({
	browser: true
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

import ExperimentDetailChildPage from './+page.svelte';
import { goto } from '$app/navigation';
import {
	createMockPageData,
	sampleExperiments,
	sampleExperimentResults
} from '../../detail.test.shared';

describe('Experiment detail child route page', () => {
	beforeEach(() => {
		formsMockState.nextEnhanceResult = { type: 'success', data: {} };
		formsMockState.lastSubmitFormData = null;
		formsMockState.applyActionMock.mockClear();
	});

	afterEach(() => {
		cleanup();
	});

	function setNextConcludeFailure(message: string): void {
		formsMockState.nextEnhanceResult = {
			type: 'failure',
			data: { experimentError: message }
		};
	}

	it('renders through the shared index shell with the experiments tab active', () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults,
				experimentDetailBackHref: '../../?tab=experiments'
			}),
			form: null
		});

		expect(screen.getByRole('tab', { name: 'Experiments' })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		expect(screen.getByRole('link', { name: 'Back to experiments' })).toHaveAttribute(
			'href',
			'../../?tab=experiments'
		);
		expect(screen.getByText('Primary Metric: ctr')).toBeInTheDocument();
	});

	it('falls back to experiments tab query href when parent does not provide a back link', () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults,
				experimentDetailBackHref: undefined
			}),
			form: null
		});

		const backLinks = screen.getAllByRole('link', { name: 'Back to experiments' });
		expect(backLinks.length).toBeGreaterThanOrEqual(1);
		expect(backLinks[0]).toHaveAttribute('href', '../../?tab=experiments');
	});

	it('targets conclude submit at the parent action owner', async () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults,
				experimentDetailBackHref: '../../?tab=experiments'
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);
		const concludeForm = document.querySelector('form[action*="concludeExperiment"]');
		expect(concludeForm).toBeTruthy();
		expect(concludeForm).toHaveAttribute('action', '../../?/concludeExperiment');
	});

	it('targets lifecycle submits at the parent action owner', () => {
		const createdExperiment = { ...sampleExperiments.abtests[0], status: 'created' as const };
		const runningExperiment = { ...sampleExperiments.abtests[0], status: 'running' as const };
		const stoppedExperiment = { ...sampleExperiments.abtests[0], status: 'stopped' as const };

		const createdView = render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: createdExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});
		expect(
			createdView.container.querySelector('form[action="../../?/startExperiment"]')
		).not.toBeNull();
		expect(
			createdView.container.querySelector('form[action="../../?/deleteExperiment"]')
		).not.toBeNull();
		createdView.unmount();

		const runningView = render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: runningExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});
		expect(
			runningView.container.querySelector('form[action="../../?/stopExperiment"]')
		).not.toBeNull();
		runningView.unmount();

		const stoppedView = render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: stoppedExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});
		expect(
			stoppedView.container.querySelector('form[action="../../?/deleteExperiment"]')
		).not.toBeNull();
	});

	it('keeps created-experiment delete flow available on the detail route', async () => {
		const createdExperiment = { ...sampleExperiments.abtests[0], status: 'created' as const };
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: createdExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Delete experiment' }));
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
		expect(screen.getByText('Delete experiment "Ranking test"?')).toBeInTheDocument();
	});

	it('prefills declare-winner reason and renders inline error from action failure', async () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);

		expect(screen.getByLabelText('Reason')).toHaveValue(
			'Statistically significant: variant wins on CTR with 97.0% confidence.'
		);
		expect(
			within(screen.getByTestId('declare-winner-dialog')).getByRole('button', {
				name: 'Declare Winner'
			})
		).toBeInTheDocument();
		setNextConcludeFailure('Failed to conclude experiment');
		await fireEvent.submit(screen.getByTestId('declare-winner-dialog'));
		expect(formsMockState.applyActionMock).toHaveBeenCalled();
		expect(screen.getByTestId('declare-winner-error')).toHaveTextContent(
			'Failed to conclude experiment'
		);
	});

	it('defaults to no winner and serializes winner null when significance winner is unavailable', async () => {
		const winnerlessResults = {
			...sampleExperimentResults,
			significance: {
				...sampleExperimentResults.significance,
				winner: undefined
			}
		};

		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: winnerlessResults
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);
		expect(screen.getByLabelText('No Winner')).toBeChecked();
		expect(screen.getByLabelText('Reason')).toHaveValue(
			'No statistically significant winner yet on CTR.'
		);

		await fireEvent.submit(screen.getByTestId('declare-winner-dialog'));
		const submittedConclusion = formsMockState.lastSubmitFormData?.get('conclusion');
		expect(typeof submittedConclusion).toBe('string');
		expect(JSON.parse(String(submittedConclusion))).toEqual(
			expect.objectContaining({
				winner: null,
				reason: 'No statistically significant winner yet on CTR.'
			})
		);
	});

	it('keeps the default conclude reason aligned with winner radio changes', async () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);
		expect(screen.getByLabelText('Reason')).toHaveValue(
			'Statistically significant: variant wins on CTR with 97.0% confidence.'
		);

		await fireEvent.click(screen.getByLabelText('Control'));
		expect(screen.getByLabelText('Reason')).toHaveValue(
			'Statistically significant: control wins on CTR with 97.0% confidence.'
		);

		await fireEvent.submit(screen.getByTestId('declare-winner-dialog'));
		const submittedConclusion = formsMockState.lastSubmitFormData?.get('conclusion');
		expect(typeof submittedConclusion).toBe('string');
		expect(JSON.parse(String(submittedConclusion))).toEqual(
			expect.objectContaining({
				winner: 'control',
				reason: 'Statistically significant: control wins on CTR with 97.0% confidence.'
			})
		);
	});

	it('renders settings diff and promote checkbox for mode-a overrides in declare-winner dialog', async () => {
		const modeAExperiment = {
			...sampleExperiments.abtests[0],
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{
					index: 'products',
					trafficPercentage: 50,
					customSearchParameters: { enableSynonyms: true, filters: 'category:shoes' }
				}
			]
		};

		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: modeAExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);

		const settingsDiff = screen.getByTestId('settings-diff');
		expect(settingsDiff).toBeInTheDocument();
		expect(settingsDiff).toHaveTextContent('enableSynonyms: true');
		expect(settingsDiff).toHaveTextContent('filters: "category:shoes"');
		expect(screen.getByLabelText('Promote winner settings to the base index')).toBeInTheDocument();
	});

	it('hides promote checkbox when declare-winner has no promotable settings', async () => {
		const modeBExperiment = {
			...sampleExperiments.abtests[0],
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products_mode_b', trafficPercentage: 50 }
			]
		};

		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: modeBExperiment,
				selectedExperimentResults: sampleExperimentResults
			}),
			form: null
		});

		await fireEvent.click(screen.getAllByRole('button', { name: 'Declare Winner' }).at(-1)!);

		expect(
			screen.queryByLabelText('Promote winner settings to the base index')
		).not.toBeInTheDocument();
	});

	it('navigates back to experiments tab after successful delete from child route', () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: sampleExperimentResults
			}),
			form: { experimentDeleted: true }
		});

		expect(vi.mocked(goto)).toHaveBeenCalledWith('/console/indexes/products?tab=experiments');
	});

	it('renders variant-index-missing guard-rail alert when result flag is present', () => {
		render(ExperimentDetailChildPage, {
			data: createMockPageData({
				selectedExperiment: sampleExperiments.abtests[0],
				selectedExperimentResults: {
					...sampleExperimentResults,
					variantIndexMissing: true
				} as never
			}),
			form: null
		});

		expect(screen.getByRole('alert')).toHaveTextContent('Variant index');
		expect(screen.queryByRole('button', { name: 'Declare Winner' })).not.toBeInTheDocument();
	});
});
