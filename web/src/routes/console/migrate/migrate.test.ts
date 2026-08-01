import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, fireEvent, waitFor, within } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';
import type {
	AlgoliaMigrationAvailabilityResponse,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage
} from '$lib/api/types';
import {
	availableAvailability,
	unavailableAvailability
} from '$lib/components/migration/migration_test_fixtures';
import { getAccessibilityViolations } from '../../../tests/a11y';

const { applyActionMock, deserializeMock, fetchMock, gotoMock, invalidateAllMock } = vi.hoisted(
	() => ({
		applyActionMock: vi.fn(),
		deserializeMock: vi.fn(),
		fetchMock: vi.fn(),
		gotoMock: vi.fn(),
		invalidateAllMock: vi.fn()
	})
);

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	deserialize: deserializeMock
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock,
	invalidateAll: invalidateAllMock
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/migrate') }
}));

vi.mock('$app/environment', () => ({
	browser: true
}));

import MigratePage from './+page.svelte';

beforeEach(() => {
	fetchMock.mockImplementation(async () => new Response('serialized-action-result'));
	deserializeMock.mockReturnValue({
		type: 'success',
		status: 200,
		data: {
			providerEligibility: {
				phase: 'provider',
				mode: 'create',
				provider: 'aws',
				target: {
					kind: 'create',
					region: 'us-east-1'
				},
				eligibilityToken: 'provider-token',
				expiresAt: '2099-07-18T10:15:00Z'
			}
		}
	});
	vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
});

type RecentImportsData = { page: PublicAlgoliaImportJobPage | null; error: string | null };
const CLOSED_SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
type SourceProvider = (typeof CLOSED_SOURCE_PROVIDERS)[number];
type PublicJobWithSourceProvider = PublicAlgoliaImportJob & { sourceProvider: SourceProvider };

const SOURCE_PROVIDER_LABELS: Record<SourceProvider, string> = {
	algolia: 'Algolia',
	meilisearch: 'Meilisearch',
	typesense: 'Typesense'
};

function renderMigratePage(
	availability: AlgoliaMigrationAvailabilityResponse = unavailableAvailability,
	recentImports: RecentImportsData = { page: null, error: null }
) {
	return render(MigratePage, {
		data: {
			...layoutTestDefaults,
			availability,
			recentImports
		}
	});
}

function recentImportJob(
	overrides: Partial<PublicAlgoliaImportJob> & { sourceProvider?: SourceProvider } = {}
): PublicJobWithSourceProvider {
	return {
		id: 'job_123',
		sourceProvider: 'algolia',
		status: 'copying_documents',
		mode: 'create',
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
	};
}

function submittedActionFormData(actionName: string, callIndex = 0): FormData {
	const call = fetchMock.mock.calls.filter(([url]) => url === `?/${actionName}`)[callIndex];
	expect(call).toBeDefined();
	const body = (call?.[1] as RequestInit | undefined)?.body;
	expect(body).toBeInstanceOf(FormData);
	return body as FormData;
}

function submittedActionPayload(actionName: string, callIndex = 0): Record<string, unknown> {
	const payload = submittedActionFormData(actionName, callIndex).get('payload');
	expect(typeof payload).toBe('string');
	return JSON.parse(payload as string) as Record<string, unknown>;
}

function expectNoDormantMigrationControls(container: HTMLElement) {
	expect(container.querySelector('form')).not.toBeInTheDocument();
	expect(screen.queryByLabelText(/app.*id/i)).not.toBeInTheDocument();
	expect(screen.queryByLabelText(/api key/i)).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /source index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /target index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /destination index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /browse indexes/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /migrate/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /resume/i })).not.toBeInTheDocument();
}

describe('Migrate page unavailable state', () => {
	it('renders the connected create flow when availability.available is true', async () => {
		const { container } = renderMigratePage(availableAvailability);
		const available = screen.getByTestId('migration-available');

		expect(available).toHaveTextContent('Search data migration is available');
		expect(screen.queryByTestId('migration-unavailable')).not.toBeInTheDocument();
		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(await screen.findByLabelText(/algolia application id/i)).toHaveValue('');
		expect(await screen.findByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
		expect(container.innerHTML).not.toContain('provider-token');
		await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
		expect(fetchMock).toHaveBeenCalledWith(
			'?/providerEligibility',
			expect.objectContaining({
				method: 'POST',
				headers: { 'x-sveltekit-action': 'true' }
			})
		);
		expect(submittedActionPayload('providerEligibility')).toEqual({
			source_provider: 'algolia',
			region: 'us-east-1'
		});
	});

	it('renders the authenticated unavailable explanation page', () => {
		const { container } = renderMigratePage();

		expect(screen.getByRole('heading', { name: /migrate search data/i })).toBeInTheDocument();
		expect(screen.getByTestId('migration-unavailable')).toHaveTextContent(
			'Algolia migration is temporarily unavailable while we replace the importer.'
		);
		expect(
			screen.getByText(/We have temporarily turned off new search data imports/i)
		).toBeInTheDocument();
		expect(container.querySelector('form')).not.toBeInTheDocument();
	});

	it('refreshes provider eligibility with the newly selected source provider', async () => {
		renderMigratePage(availableAvailability);

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		await waitFor(() =>
			expect(fetchMock.mock.calls.filter(([url]) => url === '?/providerEligibility')).toHaveLength(
				1
			)
		);
		await fireEvent.click(await screen.findByRole('radio', { name: /typesense/i }));
		await waitFor(() =>
			expect(fetchMock.mock.calls.filter(([url]) => url === '?/providerEligibility')).toHaveLength(
				2
			)
		);

		expect(submittedActionPayload('providerEligibility', 1)).toEqual({
			source_provider: 'typesense',
			region: 'us-east-1'
		});
	});

	it('does not render migration credentials, source controls, or import CTAs', () => {
		const { container } = renderMigratePage();

		expectNoDormantMigrationControls(container);
	});

	it('does not mount the dormant migration create flow component', () => {
		renderMigratePage();

		// The create-mode flow exists as an unmounted component cluster. The served
		// route must stay on the unavailable state until activation mounts it.
		expect(screen.queryByTestId('migration-create-flow')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/search source indexes/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
	});

	it('renders no dormant preview, job-history, or operation links', () => {
		const { container } = renderMigratePage();

		expect(screen.getByTestId('migration-unavailable')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-recent-imports')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-detail')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /open import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /preview/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /start a new import/i })).not.toBeInTheDocument();

		const renderedLinks = Array.from(container.querySelectorAll('a')).map((link) =>
			link.getAttribute('href')
		);
		expect(renderedLinks).toEqual(['mailto:support@flapjack.foo']);
		expect(container.innerHTML).not.toMatch(/\/migration\/|\/console\/migrate\/job_|preview/i);
	});
});

describe('Migrate page recent imports on the available surface', () => {
	it.each(CLOSED_SOURCE_PROVIDERS)(
		'renders %s recent import rows with exact provider, status, destination, date, and provider-bearing reopen link',
		(sourceProvider) => {
			const job = recentImportJob({ sourceProvider });
			renderMigratePage(availableAvailability, {
				page: { jobs: [job], nextCursor: null },
				error: null
			});

			const recent = screen.getByTestId('migration-recent-imports');
			const row = within(recent).getByTestId(`migration-recent-import-${job.id}`);
			expect(row).toHaveTextContent(`Source provider ${SOURCE_PROVIDER_LABELS[sourceProvider]}`);
			expect(row).toHaveTextContent('products to products_migrated');
			expect(row).toHaveTextContent('Copying documents');
			expect(row).toHaveTextContent('us-east-1');
			expect(row).toHaveTextContent('Updated Jul 18, 2026');

			const reopenLink = within(row).getByRole('link', { name: /open import job_123/i });
			expect(reopenLink).toHaveAttribute(
				'href',
				`/console/migrate/job_123?source_provider=${sourceProvider}`
			);
		}
	);

	it('keeps the create flow visible when the recent-import list is empty', async () => {
		renderMigratePage(availableAvailability, { page: { jobs: [], nextCursor: null }, error: null });

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-imports-empty')).toHaveTextContent(
			'No Algolia imports yet'
		);
	});

	it('keeps the create flow visible when the recent-import list failed to load', async () => {
		renderMigratePage(availableAvailability, {
			page: null,
			error: 'Recent imports could not be loaded'
		});

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-imports-error')).toHaveTextContent(
			'Recent imports could not be loaded'
		);
		expect(screen.getByRole('button', { name: /retry recent imports/i })).toBeInTheDocument();
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'submits selected %s source_provider when retrying or loading more recent imports',
		async (sourceProvider) => {
			const providerEligibilityResult = {
				type: 'success',
				status: 200,
				data: {
					providerEligibility: {
						phase: 'provider',
						mode: 'create',
						provider: 'aws',
						target: { kind: 'create', region: 'us-east-1' },
						eligibilityToken: 'provider-token',
						expiresAt: '2099-07-18T10:15:00Z'
					}
				}
			};
			const recentImportsResult = {
				type: 'success',
				status: 200,
				data: {
					recentImports: {
						jobs: [recentImportJob({ id: `${sourceProvider}-next`, sourceProvider })],
						nextCursor: null
					}
				}
			};

			deserializeMock
				.mockReset()
				.mockReturnValueOnce(providerEligibilityResult)
				.mockReturnValueOnce({
					...recentImportsResult,
					data: {
						recentImports: {
							jobs: [recentImportJob({ id: `${sourceProvider}-retried`, sourceProvider })],
							nextCursor: null
						}
					}
				});
			const retryRender = renderMigratePage(availableAvailability, {
				page: {
					jobs: [recentImportJob({ id: `${sourceProvider}-current`, sourceProvider })],
					nextCursor: `${sourceProvider}-retry-cursor`
				},
				error: 'Recent imports could not be loaded'
			});

			expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
			await fireEvent.click(screen.getByRole('button', { name: /retry recent imports/i }));
			await waitFor(() =>
				expect(fetchMock).toHaveBeenCalledWith(
					'?/recentImports',
					expect.objectContaining({ method: 'POST' })
				)
			);
			expect(Array.from(submittedActionFormData('recentImports').entries())).toEqual([
				['source_provider', sourceProvider],
				['cursor', `${sourceProvider}-retry-cursor`],
				['limit', '10']
			]);

			retryRender.unmount();
			fetchMock.mockClear();
			deserializeMock
				.mockReset()
				.mockReturnValueOnce(providerEligibilityResult)
				.mockReturnValueOnce({
					...recentImportsResult,
					data: {
						recentImports: {
							jobs: [recentImportJob({ id: `${sourceProvider}-loaded-more`, sourceProvider })],
							nextCursor: null
						}
					}
				});
			renderMigratePage(availableAvailability, {
				page: {
					jobs: [recentImportJob({ id: `${sourceProvider}-current`, sourceProvider })],
					nextCursor: `${sourceProvider}-load-more-cursor`
				},
				error: null
			});

			expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
			await fireEvent.click(screen.getByRole('button', { name: /load more imports/i }));

			await waitFor(() =>
				expect(fetchMock).toHaveBeenCalledWith(
					'?/recentImports',
					expect.objectContaining({ method: 'POST' })
				)
			);
			expect(Array.from(submittedActionFormData('recentImports').entries())).toEqual([
				['source_provider', sourceProvider],
				['cursor', `${sourceProvider}-load-more-cursor`],
				['limit', '10']
			]);
		}
	);

	it('keeps a changed create-flow provider through automatic reload and subsequent pagination', async () => {
		const providerEligibilityResult = {
			type: 'success',
			status: 200,
			data: {
				providerEligibility: {
					phase: 'provider',
					mode: 'create',
					provider: 'aws',
					target: { kind: 'create', region: 'us-east-1' },
					eligibilityToken: 'provider-token',
					expiresAt: '2099-07-18T10:15:00Z'
				}
			}
		};
		deserializeMock
			.mockReset()
			.mockReturnValueOnce(providerEligibilityResult)
			.mockReturnValueOnce(providerEligibilityResult)
			.mockReturnValueOnce({
				type: 'success',
				status: 200,
				data: {
					recentImports: {
						jobs: [recentImportJob({ id: 'typesense-retried', sourceProvider: 'typesense' })],
						nextCursor: 'typesense-next-cursor'
					}
				}
			})
			.mockReturnValueOnce({
				type: 'success',
				status: 200,
				data: {
					recentImports: {
						jobs: [recentImportJob({ id: 'typesense-loaded-more', sourceProvider: 'typesense' })],
						nextCursor: null
					}
				}
			});
		renderMigratePage(availableAvailability, {
			page: null,
			error: 'Recent imports could not be loaded'
		});

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		await waitFor(() =>
			expect(fetchMock).toHaveBeenCalledWith(
				'?/providerEligibility',
				expect.objectContaining({ method: 'POST' })
			)
		);
		await fireEvent.click(await screen.findByRole('radio', { name: /algolia/i }));
		await fireEvent.click(screen.getByRole('radio', { name: /typesense/i }));

		await waitFor(() =>
			expect(fetchMock).toHaveBeenCalledWith(
				'?/recentImports',
				expect.objectContaining({ method: 'POST' })
			)
		);
		expect(Array.from(submittedActionFormData('recentImports', 0).entries())).toEqual([
			['source_provider', 'typesense'],
			['limit', '10']
		]);

		await fireEvent.click(await screen.findByRole('button', { name: /load more imports/i }));
		await waitFor(() =>
			expect(fetchMock.mock.calls.filter(([url]) => url === '?/recentImports')).toHaveLength(2)
		);
		expect(Array.from(submittedActionFormData('recentImports', 1).entries())).toEqual([
			['source_provider', 'typesense'],
			['cursor', 'typesense-next-cursor'],
			['limit', '10']
		]);
		expect(screen.getByTestId('migration-recent-import-typesense-retried')).toBeInTheDocument();
		expect(
			await screen.findByTestId('migration-recent-import-typesense-loaded-more')
		).toBeInTheDocument();
	});

	it('replaces populated recent imports when the source provider changes', async () => {
		const providerEligibilityResult = {
			type: 'success',
			status: 200,
			data: {
				providerEligibility: {
					phase: 'provider',
					mode: 'create',
					provider: 'aws',
					target: { kind: 'create', region: 'us-east-1' },
					eligibilityToken: 'provider-token',
					expiresAt: '2099-07-18T10:15:00Z'
				}
			}
		};
		deserializeMock
			.mockReset()
			.mockReturnValueOnce(providerEligibilityResult)
			.mockReturnValueOnce(providerEligibilityResult)
			.mockReturnValueOnce({
				type: 'success',
				status: 200,
				data: {
					recentImports: {
						jobs: [recentImportJob({ id: 'typesense-current', sourceProvider: 'typesense' })],
						nextCursor: null
					}
				}
			});
		renderMigratePage(availableAvailability, {
			page: {
				jobs: [recentImportJob({ id: 'algolia-stale' })],
				nextCursor: 'algolia-next-cursor'
			},
			error: null
		});

		expect(await screen.findByTestId('migration-recent-import-algolia-stale')).toBeInTheDocument();
		await fireEvent.click(await screen.findByRole('radio', { name: /typesense/i }));

		await waitFor(() =>
			expect(fetchMock).toHaveBeenCalledWith(
				'?/recentImports',
				expect.objectContaining({ method: 'POST' })
			)
		);
		expect(Array.from(submittedActionFormData('recentImports').entries())).toEqual([
			['source_provider', 'typesense'],
			['limit', '10']
		]);
		expect(screen.queryByTestId('migration-recent-import-algolia-stale')).not.toBeInTheDocument();
		expect(
			await screen.findByTestId('migration-recent-import-typesense-current')
		).toBeInTheDocument();
	});

	it('resyncs recent imports from refreshed route data', async () => {
		const firstJob = recentImportJob();
		const rerenderedJob = recentImportJob({
			id: 'job_456',
			source: { name: 'products_archive' },
			destination: { kind: 'create', target: 'products_archive_migrated', region: 'us-west-2' }
		});
		const { rerender } = renderMigratePage(availableAvailability, {
			page: { jobs: [firstJob], nextCursor: null },
			error: null
		});

		expect(screen.getByTestId(`migration-recent-import-${firstJob.id}`)).toHaveTextContent(
			'products to products_migrated'
		);

		await rerender({
			data: {
				...layoutTestDefaults,
				availability: availableAvailability,
				recentImports: {
					page: { jobs: [rerenderedJob], nextCursor: null },
					error: null
				}
			}
		});

		expect(screen.queryByTestId(`migration-recent-import-${firstJob.id}`)).not.toBeInTheDocument();
		expect(screen.getByTestId(`migration-recent-import-${rerenderedJob.id}`)).toHaveTextContent(
			'products_archive to products_archive_migrated'
		);
	});

	it('has no structural accessibility violations for the connected migration wizard', async () => {
		const { container } = renderMigratePage(availableAvailability, {
			page: { jobs: [], nextCursor: null },
			error: null
		});

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it.each([
		[/algolia/i, /algolia application id/i, /algolia api key/i],
		[/meilisearch/i, /meilisearch host url/i, /meilisearch api key/i],
		[/typesense/i, /typesense host url/i, /typesense api key/i]
	])(
		'has no structural accessibility violations with the %s source-provider panel mounted',
		async (providerName, hostOrAppLabel, apiKeyLabel) => {
			const { container } = renderMigratePage(availableAvailability, {
				page: { jobs: [], nextCursor: null },
				error: null
			});

			expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
			await fireEvent.click(await screen.findByRole('radio', { name: providerName }));
			expect(await screen.findByLabelText(hostOrAppLabel)).toBeInTheDocument();
			expect(await screen.findByLabelText(apiKeyLabel)).toBeInTheDocument();
			await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		}
	);
});

describe('Migrate page neutral browser action bridge', () => {
	it.each([
		{
			sourceProvider: 'algolia',
			hostOrAppLabel: /algolia application id/i,
			hostOrAppValue: 'ALGOLIA_BROWSER_APP',
			apiKeyLabel: /algolia api key/i,
			apiKey: 'algolia-browser-key',
			credentials: {
				appId: 'ALGOLIA_BROWSER_APP',
				apiKey: 'algolia-browser-key'
			}
		},
		{
			sourceProvider: 'meilisearch',
			hostOrAppLabel: /meilisearch host url/i,
			hostOrAppValue: 'https://meilisearch.example.test',
			apiKeyLabel: /meilisearch api key/i,
			apiKey: 'meilisearch-browser-key',
			credentials: {
				host: 'https://meilisearch.example.test',
				apiKey: 'meilisearch-browser-key'
			}
		},
		{
			sourceProvider: 'typesense',
			hostOrAppLabel: /typesense host url/i,
			hostOrAppValue: 'https://typesense.example.test',
			apiKeyLabel: /typesense api key/i,
			apiKey: 'typesense-browser-key',
			credentials: {
				host: 'https://typesense.example.test',
				apiKey: 'typesense-browser-key'
			}
		}
	] as const)(
		'preserves selected $sourceProvider through discovery, eligibility, and create FormData payloads',
		async ({
			sourceProvider,
			hostOrAppLabel,
			hostOrAppValue,
			apiKeyLabel,
			apiKey,
			credentials
		}) => {
			const providerEligibilityResult = {
				type: 'success',
				status: 200,
				data: {
					providerEligibility: {
						phase: 'provider',
						mode: 'create',
						provider: 'aws',
						target: { kind: 'create', region: 'us-east-1' },
						eligibilityToken: 'provider-token',
						expiresAt: '2099-07-18T10:15:00Z'
					}
				}
			};
			deserializeMock.mockReset().mockReturnValueOnce(providerEligibilityResult);
			if (sourceProvider !== 'algolia') {
				deserializeMock.mockReturnValueOnce(providerEligibilityResult).mockReturnValueOnce({
					type: 'success',
					status: 200,
					data: { recentImports: { jobs: [], nextCursor: null } }
				});
			}
			deserializeMock
				.mockReturnValueOnce({
					type: 'success',
					status: 200,
					data: {
						sourceIndexes: {
							items: [
								{
									name: 'source_products',
									entries: 17,
									dataSize: 2048,
									fileSize: 4096,
									updatedAt: '2026-07-18T10:00:00Z',
									lastBuildTimeS: 3,
									pendingTask: false,
									primary: null,
									replicas: []
								}
							],
							nextCursor: null
						}
					}
				})
				.mockReturnValueOnce({
					type: 'success',
					status: 200,
					data: {
						targetEligibility: {
							phase: 'target',
							mode: 'create',
							provider: 'aws',
							target: {
								kind: 'create',
								region: 'us-east-1',
								name: 'source_products'
							},
							eligibilityToken: 'target-token',
							expiresAt: '2099-07-18T10:20:00Z'
						}
					}
				})
				.mockReturnValueOnce({
					type: 'success',
					status: 200,
					data: { job: { id: `${sourceProvider}-job`, sourceProvider } }
				});
			gotoMock.mockResolvedValue(undefined);

			renderMigratePage(availableAvailability, {
				page: { jobs: [], nextCursor: null },
				error: null
			});

			expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
			await fireEvent.click(
				await screen.findByRole('radio', { name: new RegExp(sourceProvider, 'i') })
			);
			await fireEvent.input(await screen.findByLabelText(hostOrAppLabel), {
				target: { value: hostOrAppValue }
			});
			await fireEvent.input(await screen.findByLabelText(apiKeyLabel), {
				target: { value: apiKey }
			});
			const connectButton = screen.getByRole('button', {
				name: new RegExp(`connect to ${sourceProvider}`, 'i')
			});
			expect(connectButton).toBeEnabled();
			await fireEvent.click(connectButton);
			await screen.findByTestId('migration-source-row-source_products');

			expect(submittedActionPayload('listSourceIndexes')).toEqual({
				source_provider: sourceProvider,
				...credentials
			});

			await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
			await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
			await screen.findByTestId('migration-create-review');

			expect(submittedActionPayload('checkDestinationEligibility')).toEqual({
				source_provider: sourceProvider,
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: 'source_products' },
				eligibilityToken: 'provider-token'
			});

			await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
			await waitFor(() =>
				expect(fetchMock).toHaveBeenCalledWith(
					'?/createImportJob',
					expect.objectContaining({ method: 'POST' })
				)
			);

			expect(submittedActionPayload('createImportJob')).toEqual({
				source_provider: sourceProvider,
				mode: 'create',
				...credentials,
				sourceName: 'source_products',
				target: { eligibilityToken: 'target-token' }
			});
			expect(submittedActionFormData('createImportJob').get('idempotencyKey')).toEqual(
				expect.any(String)
			);
			await waitFor(() =>
				expect(gotoMock).toHaveBeenCalledWith(
					`/console/migrate/${sourceProvider}-job?source_provider=${sourceProvider}`
				)
			);
		}
	);
});
