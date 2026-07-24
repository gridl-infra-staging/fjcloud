import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

import type { PublicAlgoliaImportJob, PublicAlgoliaImportJobPage } from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';
import RecentImports from './RecentImports.svelte';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

const ELIGIBLE_AWS_PROVIDER = {
	phase: 'provider',
	mode: 'create',
	provider: 'aws',
	target: {
		kind: 'create',
		region: 'us-east-1',
		name: 'products_migration'
	},
	eligibilityToken: 'provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;

type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];

function migrationClient(listAlgoliaSourceIndexes = vi.fn()): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes,
		checkAlgoliaDestinationEligibility: vi.fn(),
		createAlgoliaImportJob: vi.fn()
	};
}

function publicJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'copying_documents',
		mode: 'create',
		destination: {
			kind: 'create',
			target: 'products_migrated',
			region: 'us-east-1'
		},
		source: {
			name: 'products'
		},
		summary: {
			documentsExpected: 17,
			documentsImported: 13,
			documentsRejected: 4,
			settingsApplied: 2,
			settingsUnsupported: 1,
			synonymsExpected: 5,
			synonymsImported: 3,
			synonymsRejected: 2,
			rulesExpected: 7,
			rulesImported: 6,
			rulesRejected: 1
		},
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'not_started',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

function page(
	jobs: PublicAlgoliaImportJob[],
	nextCursor: string | null = null
): PublicAlgoliaImportJobPage {
	return { jobs, nextCursor };
}

function recentImportActions() {
	return {
		onRetry: vi.fn(),
		onLoadMore: vi.fn()
	};
}

describe('Recent Algolia imports', () => {
	it('renders loading, empty, and error states without owning or hiding the create flow', async () => {
		const actions = recentImportActions();
		render(MigrationCreateFlow, {
			client: migrationClient(),
			providerEligibility: ELIGIBLE_AWS_PROVIDER
		});
		const { rerender } = render(RecentImports, {
			page: null,
			loading: true,
			error: null,
			...actions
		});

		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-imports-loading')).toHaveTextContent(
			'Loading recent imports'
		);
		expect(screen.getByTestId('migration-recent-imports-loading')).toHaveAttribute(
			'role',
			'status'
		);

		await rerender({ page: page([]), loading: false, error: null, ...actions });
		expect(screen.getByTestId('migration-recent-imports-empty')).toHaveTextContent(
			'No Algolia imports yet'
		);
		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();

		await rerender({
			page: null,
			loading: false,
			error: 'Unable to load recent imports.',
			...actions
		});
		expect(screen.getByRole('alert')).toHaveTextContent('Unable to load recent imports.');
		await fireEvent.click(screen.getByRole('button', { name: /retry recent imports/i }));
		expect(actions.onRetry).toHaveBeenCalledExactlyOnceWith(null);
		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();
	});

	it('renders exact canonical fields and encoded durable links for each backend job ID', () => {
		const actions = recentImportActions();
		render(RecentImports, {
			page: page([
				publicJob({
					id: 'job alpha/tenant',
					status: 'completed_with_warnings',
					source: { name: 'products' },
					destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' },
					updatedAt: '2026-07-18T10:05:00Z'
				}),
				publicJob({
					id: 'job_beta',
					status: 'verifying',
					source: { name: 'products_migrated' },
					destination: { kind: 'replace', target: 'products', region: 'us-west-2' },
					updatedAt: '2026-07-19T11:05:00Z'
				})
			]),
			loading: false,
			error: null,
			...actions
		});

		const first = screen.getByTestId('migration-recent-import-job alpha/tenant');
		expect(within(first).getByText('products to products_migrated')).toBeInTheDocument();
		expect(
			within(first).getByText('Completed with warnings · us-east-1 · Updated Jul 18, 2026')
		).toBeInTheDocument();
		expect(
			within(first).getByRole('link', { name: /open import job alpha\/tenant/i })
		).toHaveAttribute('href', '/console/migrate/job%20alpha%2Ftenant');

		const second = screen.getByTestId('migration-recent-import-job_beta');
		expect(within(second).getByText('products_migrated to products')).toBeInTheDocument();
		expect(
			within(second).getByText('Verifying · us-west-2 · Updated Jul 19, 2026')
		).toBeInTheDocument();
		expect(within(second).getByRole('link', { name: /open import job_beta/i })).toHaveAttribute(
			'href',
			'/console/migrate/job_beta'
		);
	});

	it('uses structural responsive classes for long retained import rows', () => {
		const longName = 'products_with_a_customer_owned_long_source_name_for_wrapping';
		const longTarget = 'products_migrated_with_a_customer_owned_long_destination_name';
		const actions = recentImportActions();
		render(RecentImports, {
			page: page([
				publicJob({
					id: 'job_long',
					source: { name: longName },
					destination: { kind: 'create', target: longTarget, region: 'us-east-1' }
				})
			]),
			loading: false,
			error: null,
			...actions
		});

		const row = screen.getByTestId('migration-recent-import-job_long');
		const rowBody = row.querySelector('div');
		expect(rowBody).toHaveClass('flex');
		expect(rowBody).toHaveClass('flex-col');
		expect(rowBody).toHaveClass('sm:flex-row');
		expect(rowBody).toHaveClass('sm:justify-between');
		expect(row).toHaveTextContent(longName);
		expect(row).toHaveTextContent(longTarget);
		expect(within(row).getByRole('link', { name: /open import job_long/i })).toBeInTheDocument();
	});

	it('emits one opaque cursor intent and retains accumulated rows through loading and error', async () => {
		const actions = recentImportActions();
		const first = publicJob({ id: 'job_first', source: { name: 'first' } });
		const second = publicJob({
			id: 'job_second',
			source: { name: 'second' }
		});
		const { rerender } = render(RecentImports, {
			page: page([first], 'opaque/cursor?2'),
			loading: false,
			error: null,
			...actions
		});

		const loadMore = screen.getByRole('button', { name: /load more imports/i });
		await fireEvent.click(loadMore);
		await fireEvent.click(loadMore);
		expect(actions.onLoadMore).toHaveBeenCalledExactlyOnceWith('opaque/cursor?2');
		expect(loadMore).toBeDisabled();

		await rerender({
			page: page([first], 'opaque/cursor?2'),
			loading: true,
			error: null,
			...actions
		});
		expect(screen.getByTestId('migration-recent-import-job_first')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /load more imports/i })).toBeDisabled();

		await rerender({
			page: page([first], 'opaque/cursor?2'),
			loading: false,
			error: 'Unable to load the next page.',
			...actions
		});
		expect(screen.getByTestId('migration-recent-import-job_first')).toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: /retry recent imports/i }));
		expect(actions.onRetry).toHaveBeenCalledExactlyOnceWith('opaque/cursor?2');

		await rerender({
			page: page([first, second], null),
			loading: false,
			error: null,
			...actions
		});
		expect(screen.getByTestId('migration-recent-import-job_first')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-import-job_second')).toBeInTheDocument();
		expect(screen.getAllByTestId('migration-recent-import-job_first')).toHaveLength(1);
		expect(screen.getAllByTestId('migration-recent-import-job_second')).toHaveLength(1);
		expect(screen.queryByRole('button', { name: /load more imports/i })).not.toBeInTheDocument();
	});

	it('keeps the retained-row retry disabled while its next-page request is in flight', async () => {
		const actions = recentImportActions();
		const first = publicJob({ id: 'job_first', source: { name: 'first' } });
		const { rerender } = render(RecentImports, {
			page: page([first], 'opaque/cursor?2'),
			loading: false,
			error: 'Unable to load the next page.',
			...actions
		});

		const retry = screen.getByRole('button', { name: /retry recent imports/i });
		await fireEvent.click(retry);
		expect(actions.onRetry).toHaveBeenCalledExactlyOnceWith('opaque/cursor?2');

		// The adapter preserves the prior page error while the retry request is in flight.
		await rerender({
			page: page([first], 'opaque/cursor?2'),
			loading: true,
			error: 'Unable to load the next page.',
			...actions
		});

		const inFlightRetry = screen.getByRole('button', { name: /retry recent imports/i });
		expect(inFlightRetry).toBeDisabled();
		await fireEvent.click(inFlightRetry);
		expect(actions.onRetry).toHaveBeenCalledExactlyOnceWith('opaque/cursor?2');
	});
});
