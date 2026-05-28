import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/svelte';
import type { Index } from '$lib/api/types';
import {
	buildCreateExperimentPayload,
	estimateRuntimeDays,
	SAMPLE_SIZE_ROWS
} from '$lib/experiment_helpers';

const formsMockState = vi.hoisted(() => ({
	applyActionMock: vi.fn(async () => {}),
	updateMock: vi.fn(async () => {}),
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
				action: new URL(form.action, 'http://localhost'),
				cancel: () => {}
			});
			if (typeof callback !== 'function') return;
			await callback({
				result: formsMockState.nextEnhanceResult,
				update: formsMockState.updateMock
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
	page: { url: new URL('http://localhost/console/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

import CreateExperimentDialog from '../CreateExperimentDialog.svelte';

const controlIndex = 'products';
const allIndexes: Index[] = [
	{
		name: 'products',
		region: 'us-east-1',
		endpoint: null,
		entries: 100,
		data_size_bytes: 0,
		status: 'ready',
		tier: 'active',
		created_at: '2026-01-01T00:00:00Z'
	},
	{
		name: 'products_v2',
		region: 'us-east-1',
		endpoint: null,
		entries: 50,
		data_size_bytes: 0,
		status: 'ready',
		tier: 'active',
		created_at: '2026-01-02T00:00:00Z'
	},
	{
		name: 'orders',
		region: 'us-east-1',
		endpoint: null,
		entries: 200,
		data_size_bytes: 0,
		status: 'ready',
		tier: 'active',
		created_at: '2026-01-03T00:00:00Z'
	}
];

function renderDialog(overrides: Record<string, unknown> = {}) {
	return render(CreateExperimentDialog, {
		open: true,
		controlIndex,
		allIndexes,
		onCancel: vi.fn(),
		onSubmitted: vi.fn(),
		...overrides
	});
}

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	formsMockState.applyActionMock.mockClear();
	formsMockState.updateMock.mockClear();
	formsMockState.lastSubmitFormData = null;
	formsMockState.nextEnhanceResult = { type: 'success', data: {} };
});

describe('CreateExperimentDialog', () => {
	describe('Step 1 — Basics', () => {
		it('renders Step 1 of 4 indicator and Next is disabled until name and metric set', () => {
			renderDialog();

			expect(screen.getByText(/Step 1 of 4/)).toBeInTheDocument();
			const nextBtn = screen.getByRole('button', { name: /Next/ });
			expect(nextBtn).toBeDisabled();
		});

		it('enables Next once name is non-blank and metric is selected', async () => {
			renderDialog();

			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'My Experiment' } });

			const nextBtn = screen.getByRole('button', { name: /Next/ });
			expect(nextBtn).not.toBeDisabled();
		});

		it('shows inline validation error when Next clicked with blank name', async () => {
			renderDialog();

			const nextBtn = screen.getByRole('button', { name: /Next/ });
			await fireEvent.click(nextBtn);

			expect(screen.getByText(/name is required/i)).toBeInTheDocument();
			expect(screen.getByText(/Step 1 of 4/)).toBeInTheDocument();
		});
	});

	describe('Step 2 — Variants', () => {
		async function goToStep2() {
			renderDialog();
			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'Test' } });
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument());
		}

		it('Mode-B select excludes the control index', async () => {
			await goToStep2();

			const modeBRadio = screen.getByLabelText(/Mode B/i);
			await fireEvent.click(modeBRadio);

			const select = screen.getByRole('combobox');
			const options = within(select).getAllByRole('option');
			const optionValues = options.map((o) => (o as HTMLOptionElement).value);

			expect(optionValues).not.toContain('products');
			expect(optionValues).toContain('products_v2');
			expect(optionValues).toContain('orders');
		});

		it('shows alert when no variant index selected in Mode B', async () => {
			await goToStep2();

			const modeBRadio = screen.getByLabelText(/Mode B/i);
			await fireEvent.click(modeBRadio);

			const nextBtn = screen.getByRole('button', { name: /Next/ });
			await fireEvent.click(nextBtn);

			expect(screen.getByRole('alert')).toHaveTextContent(/variant index must differ/i);
			expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument();
		});
	});

	describe('Step 3 — Allocation', () => {
		async function goToStep3() {
			renderDialog();
			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'Test' } });
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 3 of 4/)).toBeInTheDocument());
		}

		it('renders runtime estimate table with correct values at 50/50 default', async () => {
			await goToStep3();

			const table = screen.getByTestId('runtime-estimate-table');
			expect(table).toBeInTheDocument();

			for (const row of SAMPLE_SIZE_ROWS) {
				const expected = estimateRuntimeDays(row.baseDays, 50);
				expect(table.textContent).toContain(`${expected}`);
			}
		});

		it('recomputes runtime estimate when traffic split changes', async () => {
			await goToStep3();

			const slider = screen.getByLabelText(/traffic split/i);
			await fireEvent.input(slider, { target: { value: '80' } });

			const table = screen.getByTestId('runtime-estimate-table');
			const typicalAt80 = estimateRuntimeDays(25, 80);
			expect(table.textContent).toContain(`${typicalAt80}`);
		});

		it('shows runtime-warning when typical row exceeds 90 days', async () => {
			await goToStep3();

			const slider = screen.getByLabelText(/traffic split/i);
			await fireEvent.input(slider, { target: { value: '90' } });

			expect(screen.getByTestId('runtime-warning')).toBeInTheDocument();
		});

		it('shows runtime-danger when typical row exceeds 365 days', async () => {
			await goToStep3();

			const slider = screen.getByLabelText(/traffic split/i);
			await fireEvent.input(slider, { target: { value: '98' } });

			expect(screen.getByTestId('runtime-danger')).toBeInTheDocument();
		});
	});

	describe('Step 4 — Review', () => {
		async function goToStep4() {
			renderDialog();
			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'My Test' } });
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 3 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 4 of 4/)).toBeInTheDocument());
		}

		it('shows user-token-warning callout', async () => {
			await goToStep4();

			expect(screen.getByTestId('user-token-warning')).toBeInTheDocument();
			expect(screen.getByTestId('user-token-warning').textContent).toContain('stable userToken');
		});

		it('displays review summary with experiment name and metric', async () => {
			await goToStep4();

			expect(screen.getByText('My Test')).toBeInTheDocument();
			expect(screen.getByText(/CTR/)).toBeInTheDocument();
		});

		it('Create Experiment button is present on step 4', async () => {
			await goToStep4();

			expect(screen.getByRole('button', { name: /Create Experiment/ })).toBeInTheDocument();
		});
	});

	describe('Dirty cancel confirm', () => {
		it('opens discard confirm dialog when cancelling with dirty state', async () => {
			const onCancel = vi.fn();
			renderDialog({ onCancel });

			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'dirty' } });

			const cancelBtn = screen.getByRole('button', { name: /Cancel/ });
			await fireEvent.click(cancelBtn);

			expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
			expect(onCancel).not.toHaveBeenCalled();
		});

		it('treats primary metric changes as dirty state for discard confirmation', async () => {
			const onCancel = vi.fn();
			renderDialog({ onCancel });

			await fireEvent.click(screen.getByLabelText(/Conversion Rate/i));
			await fireEvent.click(screen.getByRole('button', { name: /Cancel/ }));

			expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
			expect(onCancel).not.toHaveBeenCalled();
		});

		it('Keep editing returns to wizard without closing', async () => {
			const onCancel = vi.fn();
			renderDialog({ onCancel });

			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'dirty' } });

			await fireEvent.click(screen.getByRole('button', { name: /Cancel/ }));
			await waitFor(() => expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument());

			const confirmDialog = screen.getByTestId('confirm-dialog');
			const keepBtn = within(confirmDialog).getByRole('button', { name: /Keep editing/i });
			await fireEvent.click(keepBtn);

			expect(onCancel).not.toHaveBeenCalled();
			expect(screen.getByText(/Step 1 of 4/)).toBeInTheDocument();
		});

		it('Discard closes the wizard', async () => {
			const onCancel = vi.fn();
			renderDialog({ onCancel });

			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'dirty' } });

			await fireEvent.click(screen.getByRole('button', { name: /Cancel/ }));
			await waitFor(() => expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument());

			const confirmDialog = screen.getByTestId('confirm-dialog');
			const discardBtn = within(confirmDialog).getByRole('button', { name: /Discard/i });
			await fireEvent.click(discardBtn);

			expect(onCancel).toHaveBeenCalledTimes(1);
		});

		it('cancelling with no dirty state closes immediately', async () => {
			const onCancel = vi.fn();
			renderDialog({ onCancel });

			const cancelBtn = screen.getByRole('button', { name: /Cancel/ });
			await fireEvent.click(cancelBtn);

			expect(onCancel).toHaveBeenCalledTimes(1);
		});
	});

	describe('Form submission', () => {
		async function goToStep4WithModeA(overrides: Record<string, unknown> = {}) {
			renderDialog(overrides);
			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'My Test' } });
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 3 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 4 of 4/)).toBeInTheDocument());
		}

		it('submits Mode-A payload through ?/createExperiment and applies the action result', async () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));
			const onSubmitted = vi.fn();
			await goToStep4WithModeA({ onSubmitted });

			const createForm = document.querySelector(
				'form[action="?/createExperiment"]'
			) as HTMLFormElement | null;
			expect(createForm).not.toBeNull();
			await fireEvent.submit(createForm!);

			const submittedRaw = formsMockState.lastSubmitFormData?.get('experiment');
			expect(typeof submittedRaw).toBe('string');
			expect(JSON.parse(String(submittedRaw))).toEqual(
				buildCreateExperimentPayload({
					name: 'My Test',
					primaryMetric: 'ctr',
					controlIndex: 'products',
					variantMode: 'modeA',
					variantIndex: '',
					modeAOverrides: {
						enableSynonyms: false,
						enableRules: false,
						filters: ''
					},
					trafficSplit: 50,
					minimumRuntimeDays: 7
				})
			);
			expect(formsMockState.applyActionMock).toHaveBeenCalledWith({
				type: 'success',
				data: {}
			});
			expect(onSubmitted).toHaveBeenCalledTimes(1);

			vi.useRealTimers();
		});

		it('submits Mode-B payload through ?/createExperiment and applies the action result', async () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));
			const onSubmitted = vi.fn();
			renderDialog({ onSubmitted });

			const nameInput = screen.getByLabelText(/name/i);
			await fireEvent.input(nameInput, { target: { value: 'Mode B Test' } });
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 2 of 4/)).toBeInTheDocument());

			const modeBRadio = screen.getByLabelText(/Mode B/i);
			await fireEvent.click(modeBRadio);

			const select = screen.getByRole('combobox');
			await fireEvent.change(select, { target: { value: 'products_v2' } });

			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 3 of 4/)).toBeInTheDocument());
			await fireEvent.click(screen.getByRole('button', { name: /Next/ }));
			await waitFor(() => expect(screen.getByText(/Step 4 of 4/)).toBeInTheDocument());

			const createForm = document.querySelector(
				'form[action="?/createExperiment"]'
			) as HTMLFormElement | null;
			expect(createForm).not.toBeNull();
			await fireEvent.submit(createForm!);

			const submittedRaw = formsMockState.lastSubmitFormData?.get('experiment');
			expect(typeof submittedRaw).toBe('string');
			expect(JSON.parse(String(submittedRaw))).toEqual(
				buildCreateExperimentPayload({
					name: 'Mode B Test',
					primaryMetric: 'ctr',
					controlIndex: 'products',
					variantMode: 'modeB',
					variantIndex: 'products_v2',
					modeAOverrides: {
						enableSynonyms: false,
						enableRules: false,
						filters: ''
					},
					trafficSplit: 50,
					minimumRuntimeDays: 7
				})
			);
			expect(formsMockState.applyActionMock).toHaveBeenCalledWith({
				type: 'success',
				data: {}
			});
			expect(onSubmitted).toHaveBeenCalledTimes(1);

			vi.useRealTimers();
		});

		it('keeps step 4 open and surfaces server experimentError on create failure', async () => {
			formsMockState.nextEnhanceResult = {
				type: 'failure',
				data: { experimentError: 'Experiment name already exists' }
			};
			await goToStep4WithModeA();

			const submitButton = screen.getByRole('button', { name: /Create Experiment/ });
			const createForm = document.querySelector(
				'form[action="?/createExperiment"]'
			) as HTMLFormElement | null;
			expect(createForm).not.toBeNull();
			await fireEvent.submit(createForm!);

			expect(formsMockState.applyActionMock).not.toHaveBeenCalled();
			expect(screen.getByText(/Step 4 of 4/)).toBeInTheDocument();
			expect(screen.getByRole('alert')).toHaveTextContent('Experiment name already exists');
			expect(submitButton).not.toBeDisabled();
			vi.useRealTimers();
		});
	});
});
