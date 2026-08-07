import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/svelte';
import type {
	AlgoliaImportJobStatus,
	AlgoliaMigrationCapabilities,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import { getAccessibilityViolations } from '../../../../tests/a11y';
import { describeUnsupportedCutoverVerification } from '$lib/components/migration/job_presentation';

const { applyActionMock, deserializeMock, fetchMock, invalidateAllMock } = vi.hoisted(() => ({
	applyActionMock: vi.fn(),
	deserializeMock: vi.fn(),
	fetchMock: vi.fn(),
	invalidateAllMock: vi.fn()
}));

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	deserialize: deserializeMock
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: invalidateAllMock
}));

import JobDetailPage from './+page.svelte';

const RUNNING_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: true,
	resume: false,
	replace: true,
	preview: false,
	verify: false
};
const NO_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false,
	preview: false,
	verify: false
};

// Server-published capability set for a job whose provider supports cutover
// verification. Distinct from NO_CAPABILITIES so the fail-closed default stays
// exercised by the tests that do not opt in.
const VERIFY_CAPABILITIES: AlgoliaMigrationCapabilities = {
	...NO_CAPABILITIES,
	verify: true
};
const CLOSED_SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
type SourceProvider = (typeof CLOSED_SOURCE_PROVIDERS)[number];
type PublicJobWithSourceProvider = PublicAlgoliaImportJob & { sourceProvider: SourceProvider };

function publicJob(
	overrides: Partial<PublicAlgoliaImportJob> & { sourceProvider?: SourceProvider } = {}
): PublicJobWithSourceProvider {
	return {
		id: 'job_123',
		status: 'copying_documents',
		mode: 'create',
		sourceProvider: 'algolia',
		destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' },
		source: { name: 'products' },
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
		terminalOutcomeObserved: false,
		warnings: [],
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	} as PublicJobWithSourceProvider;
}

function renderJobPage(
	job: PublicAlgoliaImportJob = publicJob(),
	capabilities: AlgoliaMigrationCapabilities = NO_CAPABILITIES
) {
	return render(JobDetailPage, { data: { job, capabilities } });
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
});

describe('[jobId] job detail page presentation', () => {
	it('renders running document progress without premature terminal outcome rows', () => {
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Copying documents');
		expect(screen.getByTestId('migration-job-phase')).toHaveTextContent('Copying records');

		const documents = screen.getByTestId('migration-summary-documents');
		expect(documents).toHaveTextContent('13 imported');
		expect(documents).toHaveTextContent('17 expected');
		expect(documents).toHaveTextContent('4 rejected');

		expect(screen.queryByTestId('migration-summary-settings')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-summary-synonyms')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-summary-rules')).not.toBeInTheDocument();
	});

	it('renders the typed failure message and no cancel control for a failed job', () => {
		renderJobPage(
			publicJob({ status: 'failed', error: { code: 'invalid_credentials' } }),
			RUNNING_CAPABILITIES
		);

		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'Algolia credentials were rejected. Reconnect with a valid key.'
		);
		expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-capability-actions')).not.toBeInTheDocument();
	});

	it('renders source-provider unsupported copy distinct from destination-provider unsupported copy', () => {
		renderJobPage(
			publicJob({
				status: 'failed',
				error: { code: 'source_provider_unsupported' } as PublicAlgoliaImportJob['error']
			}),
			NO_CAPABILITIES
		);

		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'This source provider is not supported for search imports yet.'
		);
		expect(screen.getByTestId('migration-job-error')).not.toHaveTextContent(
			'This destination provider does not support migration imports.'
		);
		cleanup();

		renderJobPage(
			publicJob({ status: 'failed', error: { code: 'migration_provider_unsupported' } }),
			NO_CAPABILITIES
		);

		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'This destination provider does not support migration imports.'
		);
		expect(screen.getByTestId('migration-job-error')).not.toHaveTextContent(
			'This source provider is not supported for search imports yet.'
		);
	});

	it('renders cancel inside capability actions and no resume affordances when only cancel is enabled', () => {
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		const actions = screen.getByTestId('migration-job-capability-actions');
		expect(actions).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeInTheDocument();

		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-resume-deadline')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-retry-panel')).not.toBeInTheDocument();
	});

	it('has no structural accessibility violations for running and failed job states', async () => {
		const { container } = renderJobPage(
			publicJob({ status: 'copying_documents' }),
			RUNNING_CAPABILITIES
		);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		cleanup();

		const { container: failedContainer } = renderJobPage(
			publicJob({ status: 'failed', error: { code: 'invalid_credentials' } }),
			RUNNING_CAPABILITIES
		);

		await expect(getAccessibilityViolations(failedContainer)).resolves.toEqual([]);
	});

	it.each([
		{
			sourceProvider: 'algolia',
			label: /algolia api key/i,
			excludedLabels: [/meilisearch api key/i, /typesense api key/i]
		},
		{
			sourceProvider: 'meilisearch',
			label: /meilisearch api key/i,
			excludedLabels: [/algolia api key/i, /typesense api key/i]
		},
		{
			sourceProvider: 'typesense',
			label: /typesense api key/i,
			excludedLabels: [/algolia api key/i, /meilisearch api key/i]
		}
	] as const)(
		'has no structural accessibility violations while showing the $sourceProvider resumable credential panel',
		async ({ sourceProvider, label, excludedLabels }) => {
			const { container } = renderJobPage(
				publicJob({
					status: 'interrupted',
					error: { code: 'interrupted' },
					resumable: true,
					resumeDeadline: '2099-07-18T11:02:00Z',
					resumeProvenance: 'engine_checkpoint',
					sourceProvider,
					source: { name: `${sourceProvider}_products` }
				}),
				{ cancel: false, resume: true, replace: false, preview: false, verify: false }
			);

			expect(screen.getByTestId('migration-job-detail')).toHaveTextContent(sourceProvider);
			expect(screen.getByTestId('migration-job-retry-panel')).toBeInTheDocument();
			expect(screen.getByLabelText(label)).toHaveAttribute('type', 'password');
			for (const excludedLabel of excludedLabels) {
				expect(screen.queryByLabelText(excludedLabel)).not.toBeInTheDocument();
			}
			await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		}
	);
});

describe('[jobId] job detail live refresh', () => {
	beforeEach(() => {
		invalidateAllMock.mockResolvedValue(undefined);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it('reloads the server load data on an interval while the job is running', async () => {
		vi.useFakeTimers();
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(invalidateAllMock).not.toHaveBeenCalled();

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(2);
	});

	it('never schedules a reload for a terminal job', async () => {
		vi.useFakeTimers();
		renderJobPage(publicJob({ status: 'completed' }), NO_CAPABILITIES);

		await vi.advanceTimersByTimeAsync(20000);
		expect(invalidateAllMock).not.toHaveBeenCalled();
	});

	it('stops reloading once the page is destroyed', async () => {
		vi.useFakeTimers();
		const { unmount } = renderJobPage(
			publicJob({ status: 'copying_documents' }),
			RUNNING_CAPABILITIES
		);

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);

		unmount();
		await vi.advanceTimersByTimeAsync(12000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
	});
});

describe('[jobId] job detail actions', () => {
	beforeEach(() => {
		fetchMock.mockResolvedValue(new Response('serialized-action-result'));
		vi.stubGlobal('fetch', fetchMock);
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'submits the cancel action with exact source_provider %s FormData and refreshes on success',
		async (sourceProvider) => {
			deserializeMock.mockReturnValue({
				type: 'success',
				status: 200,
				data: { job: publicJob({ sourceProvider }) }
			});
			invalidateAllMock.mockResolvedValue(undefined);
			vi.spyOn(window, 'confirm').mockReturnValue(true);

			renderJobPage(
				publicJob({ status: 'copying_documents', sourceProvider }),
				RUNNING_CAPABILITIES
			);

			await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));

			expect(fetchMock).toHaveBeenCalledWith(
				'?/cancel',
				expect.objectContaining({
					method: 'POST',
					headers: { 'x-sveltekit-action': 'true' }
				})
			);
			const submittedBody = fetchMock.mock.calls[0][1].body as FormData;
			expect(Array.from(submittedBody.entries())).toEqual([['source_provider', sourceProvider]]);
			await vi.waitFor(() => expect(invalidateAllMock).toHaveBeenCalled());
		}
	);

	it('surfaces the reloading marker during a post-action refresh, then clears it', async () => {
		deserializeMock.mockReturnValue({ type: 'success', status: 200, data: { job: publicJob() } });
		let resolveInvalidate: () => void = () => {};
		invalidateAllMock.mockReturnValue(
			new Promise<void>((resolve) => {
				resolveInvalidate = resolve;
			})
		);
		vi.spyOn(window, 'confirm').mockReturnValue(true);

		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(screen.getByTestId('migration-job-safe-reload')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-reloading')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));
		await vi.waitFor(() => expect(invalidateAllMock).toHaveBeenCalled());
		await vi.waitFor(() =>
			expect(screen.getByTestId('migration-job-reloading')).toBeInTheDocument()
		);

		resolveInvalidate();
		await vi.waitFor(() =>
			expect(screen.queryByTestId('migration-job-reloading')).not.toBeInTheDocument()
		);
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'submits the resume action with exact source_provider %s FormData and no retained key',
		async (sourceProvider) => {
			const resumableJob = publicJob({
				status: 'interrupted',
				error: { code: 'interrupted' },
				resumable: true,
				sourceProvider
			});
			deserializeMock.mockReturnValue({
				type: 'success',
				status: 200,
				data: { job: resumableJob }
			});
			invalidateAllMock.mockResolvedValue(undefined);

			const { container } = renderJobPage(resumableJob, {
				cancel: false,
				resume: true,
				replace: false,
				preview: false,
				verify: false
			});

			const apiKey = `${sourceProvider}-resume-secret-key-canary-0007`;
			const apiKeyInput = screen.getByLabelText(new RegExp(`${sourceProvider} api key`, 'i'));
			await fireEvent.input(apiKeyInput, { target: { value: apiKey } });
			await fireEvent.click(screen.getByRole('button', { name: /resume import/i }));

			expect(fetchMock).toHaveBeenCalledWith(
				'?/resume',
				expect.objectContaining({ method: 'POST' })
			);
			const submittedBody = fetchMock.mock.calls[0][1].body as FormData;
			expect(Array.from(submittedBody.entries())).toEqual([
				['source_provider', sourceProvider],
				['apiKey', apiKey]
			]);
			expect(container.innerHTML).not.toContain(apiKey);
		}
	);
});

const TERMINAL_STATUSES: AlgoliaImportJobStatus[] = [
	'completed',
	'completed_with_warnings',
	'failed',
	'cancelled'
];

describe('[jobId] job detail terminal statuses never poll', () => {
	it.each(TERMINAL_STATUSES)('does not reload load data for terminal status %s', async (status) => {
		vi.useFakeTimers();
		invalidateAllMock.mockResolvedValue(undefined);
		renderJobPage(publicJob({ status }), NO_CAPABILITIES);

		await vi.advanceTimersByTimeAsync(20000);
		expect(invalidateAllMock).not.toHaveBeenCalled();
		vi.useRealTimers();
	});
});

describe('[jobId] cutover verification panel', () => {
	beforeEach(() => {
		fetchMock.mockResolvedValue(new Response('serialized-action-result'));
		deserializeMock.mockReturnValue({
			type: 'success',
			status: 200,
			data: {
				report: {
					sourceIndex: 'source_products',
					destinationIndex: 'products_migrated',
					resultLimit: 4,
					queries: [
						{
							query: 'running shoes',
							overlapCount: 3,
							sourceOnly: ['p2'],
							destinationOnly: ['p5'],
							hits: [{ objectID: 'p3', sourceRank: 3, destinationRank: 1, rankDelta: -2 }]
						}
					]
				}
			}
		});
		invalidateAllMock.mockResolvedValue(undefined);
		vi.stubGlobal('fetch', fetchMock);
	});

	it.each(['completed', 'completed_with_warnings'] as const)(
		'mounts the verification panel for %s retained jobs',
		(status) => {
			renderJobPage(
				publicJob({
					status,
					source: { name: 'source_products' },
					destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' }
				}),
				NO_CAPABILITIES
			);

			expect(screen.getByRole('region', { name: /cutover verification/i })).toBeInTheDocument();
			expect(screen.getByTestId('cutover-verification-source-index')).toHaveTextContent(
				'source_products'
			);
			expect(screen.getByTestId('cutover-verification-destination-index')).toHaveTextContent(
				'products_migrated'
			);
		}
	);

	// The server-published capability, not the job's provider, decides whether
	// the console offers verification. A false `capabilities.verify` must reach
	// the panel as the unsupported state even for an Algolia job.
	it('renders the unsupported state when the server does not publish capabilities.verify', () => {
		renderJobPage(publicJob({ status: 'completed', sourceProvider: 'algolia' }), NO_CAPABILITIES);

		expect(screen.getByRole('region', { name: /cutover verification/i })).toBeInTheDocument();
		expect(screen.getByText(describeUnsupportedCutoverVerification('algolia'))).toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /run verification/i })).not.toBeInTheDocument();
	});

	it('renders the verification form when the server publishes capabilities.verify', () => {
		renderJobPage(
			publicJob({ status: 'completed', sourceProvider: 'algolia' }),
			VERIFY_CAPABILITIES
		);

		expect(screen.getByLabelText(/algolia api key/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /run verification/i })).toBeEnabled();
	});

	it.each(['queued', 'copying_documents', 'failed', 'cancelled'] as const)(
		'does not mount the verification panel for %s retained jobs',
		(status) => {
			renderJobPage(publicJob({ status }), NO_CAPABILITIES);

			expect(
				screen.queryByRole('region', { name: /cutover verification/i })
			).not.toBeInTheDocument();
		}
	);

	it('submits verification through the verify action without source or destination form fields', async () => {
		renderJobPage(
			publicJob({
				status: 'completed',
				sourceProvider: 'algolia',
				source: { name: 'source_products' },
				destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' }
			}),
			VERIFY_CAPABILITIES
		);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'algolia_app_id_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'algolia_api_key_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/queries/i), {
			target: { value: 'running shoes' }
		});
		await fireEvent.input(screen.getByLabelText(/result limit/i), {
			target: { value: '4' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		expect(fetchMock).toHaveBeenCalledWith(
			'?/verify',
			expect.objectContaining({
				method: 'POST',
				headers: { 'x-sveltekit-action': 'true' }
			})
		);
		const submittedBody = fetchMock.mock.calls[0][1].body as FormData;
		expect(Array.from(submittedBody.entries())).toEqual([
			['source_provider', 'algolia'],
			['appId', 'algolia_app_id_canary'],
			['apiKey', 'algolia_api_key_canary'],
			['queries', 'running shoes'],
			['resultLimit', '4']
		]);
		expect(submittedBody.has('sourceIndex')).toBe(false);
		expect(submittedBody.has('destinationIndex')).toBe(false);
	});

	it('renders code-owned copy from a flat SvelteKit verify failure payload', async () => {
		deserializeMock.mockReturnValue({
			type: 'failure',
			status: 401,
			data: {
				error: true,
				code: 'invalid_credentials',
				message: 'The supplied credentials were rejected.'
			}
		});
		const { container } = renderJobPage(
			publicJob({ status: 'completed', sourceProvider: 'algolia' }),
			VERIFY_CAPABILITIES
		);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'algolia_app_id_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'algolia_api_key_canary' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		await vi.waitFor(() =>
			expect(screen.getByRole('alert')).toHaveTextContent(
				'Algolia credentials were rejected. Enter a valid key and run verification again.'
			)
		);
		expect(screen.getByRole('alert')).not.toHaveTextContent(
			'Cutover verification could not be completed.'
		);
		expect(container.textContent).not.toContain('algolia_app_id_canary');
		expect(container.textContent).not.toContain('algolia_api_key_canary');
	});

	it('renders sanitized detail from a shared error-only verification failure payload', async () => {
		deserializeMock.mockReturnValue({
			type: 'failure',
			status: 404,
			data: { error: 'Destination algolia_api_key_canary is not ready for comparison.' }
		});
		const { container } = renderJobPage(
			publicJob({ status: 'completed', sourceProvider: 'algolia' }),
			VERIFY_CAPABILITIES
		);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'algolia_app_id_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'algolia_api_key_canary' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		await vi.waitFor(() =>
			expect(screen.getByRole('alert')).toHaveTextContent(
				'Destination [redacted] is not ready for comparison.'
			)
		);
		expect(container.textContent).not.toContain('algolia_api_key_canary');
	});

	it('passes dashboard session expiry failures to the shared action handler', async () => {
		const sessionFailure = {
			type: 'failure' as const,
			status: 401,
			data: { _authSessionExpired: true, error: 'Unauthorized' }
		};
		deserializeMock.mockReturnValue(sessionFailure);
		renderJobPage(
			publicJob({ status: 'completed', sourceProvider: 'algolia' }),
			VERIFY_CAPABILITIES
		);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'algolia_app_id_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'algolia_api_key_canary' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		await vi.waitFor(() => expect(applyActionMock).toHaveBeenCalledWith(sessionFailure));
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it.each([
		{ outcome: 'report', bindingChange: 'queries' },
		{ outcome: 'report', bindingChange: 'result limit' },
		{ outcome: 'report', bindingChange: 'retained job' },
		{ outcome: 'error', bindingChange: 'queries' },
		{ outcome: 'error', bindingChange: 'result limit' },
		{ outcome: 'error', bindingChange: 'retained job' }
	] as const)(
		'hides a settled $outcome after the $bindingChange binding changes',
		async ({ outcome, bindingChange }) => {
			if (outcome === 'error') {
				deserializeMock.mockReturnValue({
					type: 'failure',
					status: 404,
					data: { error: 'Prior destination is not ready.' }
				});
			}
			const job = publicJob({
				status: 'completed',
				sourceProvider: 'algolia',
				source: { name: 'source_products' },
				destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' }
			});
			const view = renderJobPage(job, VERIFY_CAPABILITIES);

			await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
				target: { value: 'algolia_app_id_canary' }
			});
			await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
				target: { value: 'algolia_api_key_canary' }
			});
			await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

			if (outcome === 'report') {
				await vi.waitFor(() =>
					expect(screen.getByLabelText('Cutover verification report')).toBeInTheDocument()
				);
			} else {
				await vi.waitFor(() =>
					expect(screen.getByRole('alert')).toHaveTextContent('Prior destination is not ready.')
				);
			}

			if (bindingChange === 'queries') {
				await fireEvent.input(screen.getByLabelText(/queries/i), { target: { value: 'boots' } });
			} else if (bindingChange === 'result limit') {
				await fireEvent.input(screen.getByLabelText(/result limit/i), {
					target: { value: '5' }
				});
			} else {
				await view.rerender({
					data: { job: publicJob({ ...job, id: 'job_456' }), capabilities: VERIFY_CAPABILITIES }
				});
			}

			expect(screen.queryByLabelText('Cutover verification report')).not.toBeInTheDocument();
			expect(screen.queryByRole('alert')).not.toBeInTheDocument();
			expect(screen.queryByText('p2')).not.toBeInTheDocument();
			expect(screen.queryByText('Prior destination is not ready.')).not.toBeInTheDocument();
		}
	);

	it.each([
		{ inputName: 'queries', changedLabel: /queries/i, changedValue: 'boots' },
		{ inputName: 'result limit', changedLabel: /result limit/i, changedValue: '5' }
	])(
		'discards an in-flight verification response after $inputName changes',
		async ({ changedLabel, changedValue }) => {
			let resolveFetch: (response: Response) => void = () => {};
			fetchMock.mockReturnValue(
				new Promise<Response>((resolve) => {
					resolveFetch = resolve;
				})
			);
			renderJobPage(
				publicJob({
					status: 'completed',
					sourceProvider: 'algolia',
					source: { name: 'source_products' },
					destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' }
				}),
				VERIFY_CAPABILITIES
			);

			await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
				target: { value: 'algolia_app_id_canary' }
			});
			await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
				target: { value: 'algolia_api_key_canary' }
			});
			await fireEvent.input(screen.getByLabelText(/queries/i), {
				target: { value: 'running shoes' }
			});
			await fireEvent.input(screen.getByLabelText(/result limit/i), {
				target: { value: '4' }
			});
			await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));
			await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());

			await fireEvent.input(screen.getByLabelText(changedLabel), {
				target: { value: changedValue }
			});
			resolveFetch(new Response('serialized-action-result'));

			await vi.waitFor(() =>
				expect(screen.getByRole('button', { name: /run verification/i })).toBeEnabled()
			);
			expect(screen.queryByLabelText('Cutover verification report')).not.toBeInTheDocument();
		}
	);
});
