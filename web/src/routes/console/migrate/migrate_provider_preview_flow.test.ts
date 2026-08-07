import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';
import { availableAvailability } from '$lib/components/migration/migration_test_fixtures';

const { applyActionMock, deserializeMock, fetchMock, gotoMock, invalidateAllMock } = vi.hoisted(
	() => ({
		applyActionMock: vi.fn(),
		deserializeMock: vi.fn(),
		fetchMock: vi.fn(),
		gotoMock: vi.fn(),
		invalidateAllMock: vi.fn()
	})
);

vi.mock('$app/forms', () => ({ applyAction: applyActionMock, deserialize: deserializeMock }));
vi.mock('$app/navigation', () => ({ goto: gotoMock, invalidateAll: invalidateAllMock }));
vi.mock('$app/state', () => ({ page: { url: new URL('http://localhost/console/migrate') } }));
vi.mock('$app/environment', () => ({ browser: true }));

import MigratePage from './+page.svelte';

type SourceProvider = 'algolia' | 'meilisearch' | 'typesense';
const PREVIEW_SUPPORT: Record<SourceProvider, boolean> = {
	algolia: true,
	meilisearch: true,
	typesense: false
};
const PREVIEW_UNAVAILABLE_COPY =
	'Preview is not available for the selected source. The migration can still run, and compatibility warnings appear once the job starts.';

beforeEach(() => {
	fetchMock.mockImplementation(async (url) => new Response(String(url)));
	vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
});

function submittedActionFormData(actionName: string): FormData {
	const call = fetchMock.mock.calls.find(([url]) => url === `?/${actionName}`);
	expect(call).toBeDefined();
	const body = (call?.[1] as RequestInit | undefined)?.body;
	expect(body).toBeInstanceOf(FormData);
	return body as FormData;
}

function submittedActionPayload(actionName: string): Record<string, unknown> {
	const payload = submittedActionFormData(actionName).get('payload');
	expect(typeof payload).toBe('string');
	return JSON.parse(payload as string) as Record<string, unknown>;
}

function actionFetchCalls(actionName: string) {
	return fetchMock.mock.calls.filter(([url]) => url === `?/${actionName}`);
}

function installActionResponses(sourceProvider: SourceProvider) {
	deserializeMock.mockImplementation((serialized: string) => {
		if (serialized === '?/providerEligibility') {
			return {
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
		}
		if (serialized === '?/availability') {
			return {
				type: 'success',
				status: 200,
				data: {
					availability: {
						...availableAvailability,
						capabilities: {
							cancel: true,
							resume: false,
							replace: true,
							preview: PREVIEW_SUPPORT[sourceProvider]
						}
					}
				}
			};
		}
		if (serialized === '?/recentImports') {
			return {
				type: 'success',
				status: 200,
				data: { recentImports: { jobs: [], nextCursor: null } }
			};
		}
		if (serialized === '?/listSourceIndexes') {
			return {
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
			};
		}
		if (serialized === '?/checkDestinationEligibility') {
			return {
				type: 'success',
				status: 200,
				data: {
					targetEligibility: {
						phase: 'target',
						mode: 'create',
						provider: 'aws',
						target: { kind: 'create', region: 'us-east-1', name: 'source_products' },
						eligibilityToken: 'target-token',
						expiresAt: '2099-07-18T10:20:00Z'
					}
				}
			};
		}
		if (serialized === '?/previewImport') {
			return {
				type: 'success',
				status: 200,
				data: {
					preview: {
						sourceCounts: { indexes: 3, records: 42 },
						report: {
							summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
							entries: [],
							reportDigest: 'sha256:neutral-bridge-preview'
						}
					}
				}
			};
		}
		if (serialized === '?/createImportJob') {
			return {
				type: 'success',
				status: 200,
				data: { job: { id: `${sourceProvider}-job`, sourceProvider } }
			};
		}
		throw new Error(`Unexpected action response: ${serialized}`);
	});
}

describe('Migrate page provider preview flow', () => {
	it.each([
		{
			sourceProvider: 'algolia',
			hostOrAppLabel: /algolia application id/i,
			hostOrAppValue: 'ALGOLIA_BROWSER_APP',
			apiKeyLabel: /algolia api key/i,
			apiKey: 'algolia-browser-key',
			discoveryCredentials: { appId: 'ALGOLIA_BROWSER_APP', apiKey: 'algolia-browser-key' },
			credentials: { appId: 'ALGOLIA_BROWSER_APP', apiKey: 'algolia-browser-key' }
		},
		{
			sourceProvider: 'meilisearch',
			hostOrAppLabel: /meilisearch host url/i,
			hostOrAppValue: 'https://meilisearch.example.test',
			apiKeyLabel: /meilisearch api key/i,
			apiKey: 'meilisearch-browser-key',
			discoveryCredentials: {
				endpoint: 'https://meilisearch.example.test',
				apiKey: 'meilisearch-browser-key'
			},
			credentials: { host: 'https://meilisearch.example.test', apiKey: 'meilisearch-browser-key' }
		},
		{
			sourceProvider: 'typesense',
			hostOrAppLabel: /typesense host url/i,
			hostOrAppValue: 'https://typesense.example.test',
			apiKeyLabel: /typesense api key/i,
			apiKey: 'typesense-browser-key',
			discoveryCredentials: {
				node: 'https://typesense.example.test',
				apiKey: 'typesense-browser-key'
			},
			credentials: { host: 'https://typesense.example.test', apiKey: 'typesense-browser-key' }
		}
	] as const)(
		'preserves selected $sourceProvider through discovery, preview, and create',
		async ({
			sourceProvider,
			hostOrAppLabel,
			hostOrAppValue,
			apiKeyLabel,
			apiKey,
			discoveryCredentials,
			credentials
		}) => {
			installActionResponses(sourceProvider);
			gotoMock.mockResolvedValue(undefined);
			render(MigratePage, {
				data: {
					...layoutTestDefaults,
					availability: availableAvailability,
					recentImports: { page: { jobs: [], nextCursor: null }, error: null }
				}
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
			await fireEvent.click(
				screen.getByRole('button', { name: new RegExp(`connect to ${sourceProvider}`, 'i') })
			);
			await screen.findByTestId('migration-source-row-source_products');
			expect(submittedActionPayload('listSourceIndexes')).toEqual({
				source_provider: sourceProvider,
				...discoveryCredentials
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

			if (PREVIEW_SUPPORT[sourceProvider]) {
				await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));
				await screen.findByTestId('migration-preview-counts');
			} else {
				expect(screen.getByText(PREVIEW_UNAVAILABLE_COPY)).toBeInTheDocument();
				expect(screen.queryByRole('button', { name: /^preview import$/i })).not.toBeInTheDocument();
				expect(actionFetchCalls('previewImport')).toHaveLength(0);
			}

			await fireEvent.click(await screen.findByRole('button', { name: /start import/i }));
			await waitFor(() => expect(actionFetchCalls('createImportJob')).toHaveLength(1));
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
