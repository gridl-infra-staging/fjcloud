import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

import MigrationCreateFlow from './MigrationCreateFlow.svelte';
import ImportJobDetail from './ImportJobDetail.svelte';
import RecentImports from './RecentImports.svelte';
import type {
	AlgoliaIndexMetadata,
	AlgoliaSourceListResponse,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage
} from '$lib/api/types';

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
		status: 'failed',
		mode: 'create',
		destination: {
			kind: 'create',
			target: 'products_migrated',
			region: 'us-east-1'
		},
		source: {
			appId: 'ALGOLIA_APP',
			name: 'products'
		},
		summary: {
			documentsExpected: 0,
			documentsImported: 0,
			documentsRejected: 0,
			settingsApplied: 0,
			settingsUnsupported: 0,
			synonymsExpected: 0,
			synonymsImported: 0,
			synonymsRejected: 0,
			rulesExpected: 0,
			rulesImported: 0,
			rulesRejected: 0
		},
		warnings: null,
		error: { code: 'backend_unavailable', message: null },
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: true,
		resumeCount: 0,
		publicationDisposition: 'unchanged',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

function page(jobs: PublicAlgoliaImportJob[]): PublicAlgoliaImportJobPage {
	return { jobs, nextCursor: null };
}

function sourceIndex(): AlgoliaIndexMetadata {
	return {
		name: 'products',
		entries: 17,
		dataSize: 2048,
		fileSize: 4096,
		updatedAt: '2026-07-18T10:00:00Z',
		lastBuildTimeS: 3,
		pendingTask: false,
		primary: null,
		replicas: []
	};
}

describe('Algolia import admission presentation', () => {
	it.each([
		['runtime_backpressure', 'Import workers are saturated.', 90],
		['repository_backpressure', 'Repository ACKs are delayed.', 45]
	] as const)(
		'returns the connect CTA after %s clears without duplicate events',
		async (reason, message, retryAfterSeconds) => {
			let resolveList: (value: AlgoliaSourceListResponse) => void = () => {};
			const listAlgoliaSourceIndexes = vi.fn().mockReturnValue(
				new Promise<AlgoliaSourceListResponse>((resolve) => {
					resolveList = resolve;
				})
			);
			const { rerender } = render(MigrationCreateFlow, {
				client: migrationClient(listAlgoliaSourceIndexes),
				providerEligibility: ELIGIBLE_AWS_PROVIDER,
				admission: { admitted: true }
			});

			await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
				target: { value: 'APPID' }
			});
			await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
				target: { value: 'secret-key' }
			});
			expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeEnabled();

			await rerender({
				client: migrationClient(listAlgoliaSourceIndexes),
				providerEligibility: ELIGIBLE_AWS_PROVIDER,
				admission: {
					admitted: false,
					reason,
					message,
					retryAfterSeconds
				}
			});
			expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(message);
			expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(
				`Retry after ${retryAfterSeconds} seconds.`
			);
			await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
			expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
			expect(listAlgoliaSourceIndexes).not.toHaveBeenCalled();

			await rerender({
				client: migrationClient(listAlgoliaSourceIndexes),
				providerEligibility: ELIGIBLE_AWS_PROVIDER,
				admission: { admitted: true }
			});
			const connectButton = screen.getByRole('button', { name: /connect to algolia/i });
			expect(connectButton).toBeEnabled();

			await fireEvent.click(connectButton);
			await fireEvent.click(connectButton);
			expect(listAlgoliaSourceIndexes).toHaveBeenCalledOnce();

			resolveList({ items: [], nextCursor: null });
		}
	);

	it('keeps the create workflow mounted through history loading, empty, and retryable error', async () => {
		render(MigrationCreateFlow, {
			client: migrationClient(),
			providerEligibility: ELIGIBLE_AWS_PROVIDER
		});
		const actions = { onRetry: vi.fn(), onLoadMore: vi.fn() };
		const { rerender } = render(RecentImports, {
			page: null,
			loading: true,
			error: null,
			...actions
		});

		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();
		await rerender({ page: page([]), loading: false, error: null, ...actions });
		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();
		await rerender({ page: null, loading: false, error: 'History unavailable.', ...actions });
		expect(screen.getByTestId('migration-create-flow')).toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: /retry recent imports/i }));
		expect(actions.onRetry).toHaveBeenCalledExactlyOnceWith(null);
	});

	it('restores Start after repository backpressure without emitting duplicate intents', async () => {
		const createAlgoliaImportJob = vi.fn(
			() => new Promise<PublicAlgoliaImportJob>(() => undefined)
		);
		const client: MigrationFlowClient = {
			listAlgoliaSourceIndexes: vi.fn().mockResolvedValue({
				items: [sourceIndex()],
				nextCursor: null
			}),
			checkAlgoliaDestinationEligibility: vi.fn().mockResolvedValue({
				phase: 'target',
				mode: 'create',
				provider: 'aws',
				target: { kind: 'create', region: 'us-east-1', name: 'products' },
				eligibilityToken: 'target-eligibility-token',
				expiresAt: '2099-07-18T10:20:00Z'
			}),
			createAlgoliaImportJob
		};
		const { rerender } = render(MigrationCreateFlow, {
			client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			admission: { admitted: true }
		});
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'APPID' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'secret-key' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		await screen.findByTestId('migration-source-list');
		await fireEvent.change(screen.getByRole('radio', { name: /products/i }));
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		expect(screen.getByRole('button', { name: /start import/i })).toBeEnabled();

		await rerender({
			client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			admission: {
				admitted: false,
				reason: 'repository_backpressure',
				message: 'Repository ACKs are delayed.',
				retryAfterSeconds: 45
			}
		});
		expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(
			'Repository ACKs are delayed. Retry after 45 seconds.'
		);
		expect(screen.getByRole('button', { name: /start import/i })).toBeDisabled();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();

		await rerender({
			client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			admission: { admitted: true }
		});
		const start = screen.getByRole('button', { name: /start import/i });
		expect(start).toBeEnabled();
		await fireEvent.click(start);
		await fireEvent.click(start);
		expect(createAlgoliaImportJob).toHaveBeenCalledOnce();
	});

	it('keeps migrate help, recent imports, and reopen intents available while backpressure disables starts', async () => {
		const listAlgoliaSourceIndexes = vi.fn();
		const recentImportActions = {
			onRetry: vi.fn(),
			onLoadMore: vi.fn()
		};
		render(MigrationCreateFlow, {
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			admission: {
				admitted: false,
				reason: 'runtime_backpressure',
				message: 'Import workers are saturated.',
				retryAfterSeconds: 90
			}
		});
		render(RecentImports, {
			page: page([publicJob({ id: 'job_retry' })]),
			loading: false,
			error: null,
			...recentImportActions
		});

		expect(screen.getByTestId('migration-algolia-key-instructions')).toBeInTheDocument();
		expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(
			'Imports are temporarily busy'
		);
		expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(
			'Retry after 90 seconds'
		);
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'APPID' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'secret-key' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
		expect(listAlgoliaSourceIndexes).not.toHaveBeenCalled();
		expect(screen.getByTestId('migration-recent-imports')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /open import job_retry/i })).toHaveAttribute(
			'href',
			'/console/migrate/job_retry'
		);
	});

	it('renders New imports paused for an operational guard without implying an admitted job was cancelled', () => {
		render(MigrationCreateFlow, {
			client: migrationClient(),
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			admission: {
				admitted: false,
				reason: 'operational_pause',
				message: 'Operators paused new Algolia imports.',
				retryAfterSeconds: null
			}
		});
		render(RecentImports, {
			page: page([publicJob({ id: 'job_admitted', status: 'copying_documents', error: null })]),
			loading: false,
			error: null,
			onRetry: vi.fn(),
			onLoadMore: vi.fn()
		});
		render(ImportJobDetail, {
			job: publicJob({ id: 'job_admitted', status: 'copying_documents', error: null })
		});

		expect(screen.getByTestId('migration-admission-notice')).toHaveTextContent(
			'New imports paused'
		);
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
		expect(screen.getByTestId('migration-recent-import-job_admitted')).toHaveTextContent(
			'Copying documents'
		);
		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Copying documents');
		expect(screen.queryByText(/cancelled/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/canceled/i)).not.toBeInTheDocument();
	});
});
