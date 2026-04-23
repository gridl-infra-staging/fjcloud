import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { AybInstance } from '$lib/api/types';
import { formatDate, indexStatusBadgeColor, statusLabel } from '$lib/format';
import { layoutTestDefaults } from '../layout-test-context';

let resolveEnhanceUpdate: (() => void) | null = null;

vi.mock('$app/forms', () => ({
	enhance: (form: HTMLFormElement, submit?: (...args: unknown[]) => unknown) => {
		const handleSubmit = (event: Event) => {
			event.preventDefault();
			const submitCallback = submit?.({
				action: new URL(form.getAttribute('action') ?? '', 'http://localhost'),
				cancel: () => {},
				formData: new FormData(form),
				formElement: form,
				submitter: (event as SubmitEvent).submitter ?? null
			});

			if (typeof submitCallback === 'function') {
				void submitCallback({
					result: { type: 'success', status: 200, data: {} },
					update: () =>
						new Promise<void>((resolve) => {
							resolveEnhanceUpdate = resolve;
						})
				});
			}
		};

		form.addEventListener('submit', handleSubmit);
		return {
			destroy: () => form.removeEventListener('submit', handleSubmit)
		};
	}
}));

import DatabasePage from './+page.svelte';

afterEach(() => {
	resolveEnhanceUpdate?.();
	resolveEnhanceUpdate = null;
	cleanup();
	vi.clearAllMocks();
});

function sampleInstance(overrides: Partial<AybInstance> = {}): AybInstance {
	return {
		id: '8df00b9f-cf30-4300-bfd4-8f25ca5da39b',
		ayb_slug: 'acme-primary',
		ayb_cluster_id: 'cluster-01',
		ayb_url: 'https://acme-primary.allyourbase.cloud',
		status: 'ready',
		plan: 'starter',
		created_at: '2026-03-17T00:00:00Z',
		updated_at: '2026-03-17T01:00:00Z',
		...overrides
	};
}

type DatabasePageData = {
	instance: AybInstance | null;
	provisioningUnavailable: boolean;
	loadError: string;
	loadErrorCode: 'duplicate_instances' | 'request_failed';
};

function renderDatabasePage(
	data: Partial<DatabasePageData> = {},
	form: { error: string } | null = null
) {
	const pageData =
		data.loadError === undefined || data.loadErrorCode === undefined
			? {
					...layoutTestDefaults,
					user: null,
					instance: data.instance ?? null,
					provisioningUnavailable: data.provisioningUnavailable ?? false
				}
			: {
					...layoutTestDefaults,
					user: null,
					instance: null,
					provisioningUnavailable: data.provisioningUnavailable ?? false,
					loadError: data.loadError,
					loadErrorCode: data.loadErrorCode
				};

	render(DatabasePage, {
		data: pageData,
		form
	});
}

describe('Database dashboard page', () => {
	it('renders the create form when no persisted instance exists', () => {
		renderDatabasePage({ provisioningUnavailable: true });

		expect(screen.getByRole('heading', { name: 'Database' })).toBeInTheDocument();
		expect(screen.getByText(/create a new database instance to get started/i)).toBeInTheDocument();
		expect(screen.getByTestId('create-instance-form')).toBeInTheDocument();
		expect(screen.getByTestId('create-name')).toBeInTheDocument();
		expect(screen.getByTestId('create-slug')).toBeInTheDocument();
		expect(screen.getByTestId('create-plan')).toBeInTheDocument();
		expect(screen.getByTestId('create-submit')).toHaveTextContent('Create Database');
		expect(screen.queryByRole('button', { name: /delete database/i })).not.toBeInTheDocument();
	});

	it('renders the default empty-state copy when no instance is persisted and provisioning controls are unavailable', () => {
		renderDatabasePage();

		expect(
			screen.getByText('No persisted database instance found for this account.')
		).toBeInTheDocument();
		expect(screen.queryByTestId('create-instance-form')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /delete database/i })).not.toBeInTheDocument();
	});

	it('renders a duplicate-instance error instead of an arbitrary database card', () => {
		renderDatabasePage({
			loadError: 'Multiple active database instances were found for this account.',
			loadErrorCode: 'duplicate_instances'
		});

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText(/multiple active database instances/i)).toBeInTheDocument();
		expect(
			screen.queryByText(/no persisted database instance found for this account/i)
		).not.toBeInTheDocument();
		expect(
			screen.getByText(
				/resolve the duplicate active database instances for this account before continuing/i
			)
		).toBeInTheDocument();
		expect(screen.queryByTestId('create-instance-form')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /delete database/i })).not.toBeInTheDocument();
	});

	it('renders a general load error when the persisted instance status cannot be fetched', () => {
		renderDatabasePage({
			loadError: 'Unable to load database instance status right now. Please try again later.',
			loadErrorCode: 'request_failed'
		});

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(
			screen.getByText(/unable to load database instance status right now/i)
		).toBeInTheDocument();
		expect(
			screen.getByText(/we couldn't load the persisted database instance state for this account/i)
		).toBeInTheDocument();
		expect(
			screen.queryByText(/resolve the duplicate active database instances/i)
		).not.toBeInTheDocument();
		expect(screen.queryByTestId('create-instance-form')).not.toBeInTheDocument();
	});

	it('renders labeled persisted AYB fields for a ready instance', () => {
		const instance = sampleInstance();
		renderDatabasePage({ instance });

		expect(screen.getByText('Database URL')).toBeInTheDocument();
		const readyBadge = screen.getByText(statusLabel(instance.status));
		expect(readyBadge).toBeInTheDocument();
		expect(readyBadge).toHaveClass(...indexStatusBadgeColor(instance.status).split(' '));
		expect(screen.getByText(instance.ayb_url)).toBeInTheDocument();
		expect(screen.getByText('Slug')).toBeInTheDocument();
		expect(screen.getByText(instance.ayb_slug)).toBeInTheDocument();
		expect(screen.getByText('Cluster ID')).toBeInTheDocument();
		expect(screen.getByText(instance.ayb_cluster_id)).toBeInTheDocument();
		expect(screen.getByText('Plan')).toBeInTheDocument();
		expect(screen.getByText(instance.plan)).toBeInTheDocument();
		expect(screen.getByText('Created')).toBeInTheDocument();
		expect(screen.getByText('Updated')).toBeInTheDocument();
		const createdField = screen.getByText('Created').closest('div');
		const updatedField = screen.getByText('Updated').closest('div');
		expect(createdField).not.toBeNull();
		expect(updatedField).not.toBeNull();
		expect(
			within(createdField as HTMLElement).getByText(formatDate(instance.created_at))
		).toBeInTheDocument();
		expect(
			within(updatedField as HTMLElement).getByText(formatDate(instance.updated_at))
		).toBeInTheDocument();
	});

	it('does not render the create form when an instance already exists', () => {
		renderDatabasePage({ instance: sampleInstance() });

		expect(screen.queryByTestId('create-instance-form')).toBeNull();
	});

	it('renders deleting state and disables delete action', () => {
		const instance = sampleInstance({ status: 'deleting' });
		renderDatabasePage({ instance });

		expect(screen.getByText('Deleting')).toBeInTheDocument();
		const deleteButton = screen.getByRole('button', { name: 'Deleting...' });
		expect(deleteButton).toBeDisabled();
	});

	it('disables delete action while a confirmed submission is pending', async () => {
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);
		renderDatabasePage({ instance: sampleInstance() });

		await fireEvent.click(screen.getByRole('button', { name: /delete database/i }));

		expect(await screen.findByRole('button', { name: 'Deleting...' })).toBeDisabled();

		resolveEnhanceUpdate?.();
		resolveEnhanceUpdate = null;
		confirmSpy.mockRestore();
	});

	it('disables create action while a submission is pending', async () => {
		renderDatabasePage({ provisioningUnavailable: true });

		await fireEvent.input(screen.getByTestId('create-name'), {
			target: { value: 'Acme Primary' }
		});
		await fireEvent.input(screen.getByTestId('create-slug'), {
			target: { value: 'acme-primary' }
		});
		await fireEvent.change(screen.getByTestId('create-plan'), {
			target: { value: 'starter' }
		});
		await fireEvent.click(screen.getByTestId('create-submit'));

		expect(await screen.findByRole('button', { name: 'Creating...' })).toBeDisabled();

		resolveEnhanceUpdate?.();
		resolveEnhanceUpdate = null;
	});

	it('renders delete error banner from form action result', () => {
		renderDatabasePage(
			{ instance: sampleInstance() },
			{ error: 'Failed to delete database instance' }
		);

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText('Failed to delete database instance')).toBeInTheDocument();
	});

	it('renders create error banner from form action result', () => {
		renderDatabasePage(
			{ provisioningUnavailable: true },
			{ error: 'A database instance already exists for this account.' }
		);

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(
			screen.getByText('A database instance already exists for this account.')
		).toBeInTheDocument();
	});

	it('requires confirmation before deletion form submit', async () => {
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
		renderDatabasePage({ instance: sampleInstance() });

		const deleteButton = screen.getByRole('button', { name: /delete database/i });
		await fireEvent.click(deleteButton);
		expect(confirmSpy).toHaveBeenCalledWith(
			expect.stringMatching(/delete this database instance/i)
		);
		confirmSpy.mockRestore();
	});
});
