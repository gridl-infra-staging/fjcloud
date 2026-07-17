import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent, within } from '@testing-library/dom';
import type { InternalRegion } from '$lib/api/types';
import CreateIndexDialog from './CreateIndexDialog.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const sampleRegions: InternalRegion[] = [
	{
		id: 'us-east-1',
		display_name: 'US East (Virginia)',
		provider: 'aws',
		provider_location: 'us-east-1',
		available: true
	}
];

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

function renderDialog(
	overrides: Partial<{
		regions: InternalRegion[];
		existingIndexNames: string[];
		selectedRegion: string;
		form: {
			error?: string;
			failedPhase?: string;
			partialIndexName?: string;
		};
	}> = {}
) {
	const onCancel = vi.fn();
	const onRegionChange = vi.fn();
	const onSubmitEnhance = vi.fn();

	render(CreateIndexDialog, {
		regions: overrides.regions ?? sampleRegions,
		existingIndexNames: overrides.existingIndexNames ?? ['products'],
		selectedRegion: overrides.selectedRegion ?? sampleRegions[0].id,
		onRegionChange,
		onCancel,
		form: overrides.form ?? null,
		onSubmitEnhance
	});

	return { onCancel, onRegionChange, onSubmitEnhance };
}

describe('CreateIndexDialog', () => {
	it('defaults to empty template and updates name when template changes', async () => {
		renderDialog();
		const form = screen.getByTestId('create-index-form');
		const q = within(form);
		const nameInput = q.getByLabelText(/index name/i) as HTMLInputElement;

		expect(q.getByText(/pick a template to seed the index/i)).toBeInTheDocument();
		expect(q.getByText(/name is the stable handle your app will use/i)).toBeInTheDocument();
		expect(q.getByText(/choose the region closest to your users/i)).toBeInTheDocument();

		const emptyTemplate = q.getByLabelText(/empty index/i) as HTMLInputElement;
		const moviesTemplate = q.getByLabelText(/movies/i) as HTMLInputElement;
		const emptyTemplateCard = emptyTemplate.closest('label');
		const defaultRegionCard = form
			.querySelector('input[name="region"][value="us-east-1"]')
			?.closest('label');

		expect(emptyTemplate.checked).toBe(true);
		expect(emptyTemplateCard).toHaveClass('border-flapjack-mint', 'bg-flapjack-mint/25');
		expect(emptyTemplateCard).not.toHaveClass('border-flapjack-rose', 'bg-flapjack-rose/10');
		expect(defaultRegionCard).toHaveClass('border-flapjack-mint', 'bg-flapjack-mint/25');
		expect(defaultRegionCard).not.toHaveClass('border-flapjack-rose', 'bg-flapjack-rose/10');
		expect(nameInput.value).toBe('');

		await fireEvent.click(moviesTemplate);
		expect(nameInput.value).toBe('movies');
		const moviesTemplateCard = moviesTemplate.closest('label');
		expect(moviesTemplateCard).toHaveClass('border-flapjack-mint', 'bg-flapjack-mint/25');
		expect(emptyTemplateCard).toHaveClass('border-flapjack-ink/20');
		expect(emptyTemplateCard).not.toHaveClass('border-flapjack-mint');

		await fireEvent.click(emptyTemplate);
		expect(nameInput.value).toBe('');
	});

	it('renders Create and Cancel buttons with their brand token classes', () => {
		renderDialog();
		const createButton = screen.getByRole('button', { name: /^create$/i });
		const cancelButton = screen.getByRole('button', { name: /cancel/i });
		expect(createButton).toHaveClass('bg-flapjack-rose');
		expect(cancelButton).toHaveClass('border-flapjack-ink/30');
	});

	it('submits template_id and does not use stale template field name', () => {
		renderDialog();
		const form = screen.getByTestId('create-index-form');
		const templateInput = form.querySelector('input[name="template_id"]');
		const staleTemplateInput = form.querySelector('input[name="template"]');
		expect(templateInput).toBeInTheDocument();
		expect(staleTemplateInput).not.toBeInTheDocument();
	});

	it('disables submit when no region is selected', () => {
		renderDialog({ regions: [], selectedRegion: '' });
		expect(screen.getByRole('button', { name: /^create$/i })).toBeDisabled();
	});

	it('shows client-side validation for invalid and duplicate index names', async () => {
		renderDialog({ existingIndexNames: ['products'] });
		const form = screen.getByTestId('create-index-form');
		const q = within(form);
		const nameInput = q.getByLabelText(/index name/i) as HTMLInputElement;

		await fireEvent.input(nameInput, { target: { value: 'bad name' } });
		await fireEvent.submit(form.querySelector('form') as HTMLFormElement);
		expect(q.getByText(/letters, numbers, underscores, and hyphens/i)).toBeInTheDocument();

		await fireEvent.input(nameInput, { target: { value: 'products' } });
		await fireEvent.submit(form.querySelector('form') as HTMLFormElement);
		expect(q.getByText(/already exists/i)).toBeInTheDocument();
	});

	it('renders seed-phase errors with partial create context', () => {
		const phaseCases = ['create', 'settings', 'docs', 'synonyms', 'rules'] as const;
		for (const phase of phaseCases) {
			renderDialog({
				form: {
					error: `Failure in ${phase}`,
					failedPhase: phase,
					partialIndexName: 'movies-seeded'
				}
			});

			expect(screen.getByTestId('create-index-server-error')).toBeInTheDocument();
			expect(screen.getByText(/movies-seeded/)).toBeInTheDocument();
			expect(screen.getByText(/partially created/i)).toBeInTheDocument();
			expect(screen.getByText(`Failure in ${phase}`)).toBeInTheDocument();
			cleanup();
		}
	});

	it('renders dedicated quota callout and hides raw quota_exceeded token', () => {
		renderDialog({
			form: {
				error: 'quota_exceeded'
			}
		});

		const quotaCallout = screen.getByTestId('create-index-quota-callout');
		expect(quotaCallout).toBeInTheDocument();
		expect(quotaCallout.textContent).toMatch(/free plan.*limit/i);
		expect(screen.getByRole('link', { name: /upgrade your plan/i })).toHaveAttribute(
			'href',
			'/console/billing'
		);
		expect(screen.queryByText('quota_exceeded')).not.toBeInTheDocument();
		expect(screen.queryByTestId('create-index-server-error')).not.toBeInTheDocument();
	});
});
