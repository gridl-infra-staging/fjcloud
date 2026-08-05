import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';

import MigrationCreateFlow from './MigrationCreateFlow.svelte';
import type { SourceProvider } from '$lib/api/types';
import {
	API_KEY_CANARY,
	APP_ID_CANARY,
	availableAvailability,
	ELIGIBLE_AWS_PROVIDER,
	connect,
	importJob,
	listResponse,
	renderFlow,
	sourceIndex,
	waitForDiscoveryToSettle,
	type MigrationFlowClient
} from './migration_test_fixtures';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

function expectSecretRedacted(text: string, secrets: readonly string[]) {
	expect(text).toContain('[redacted]');
	for (const secret of secrets) {
		expect(text).not.toContain(secret);
	}
}

describe('MigrationCreateFlow - error and retry', () => {
	it('redacts discovery errors before showing them in the source alert', async () => {
		const list = vi
			.fn()
			.mockRejectedValueOnce(
				new Error(`connect_failed ${APP_ID_CANARY} ${API_KEY_CANARY} other-context`)
			);
		renderFlow(list);

		await connect(list);

		const error = await screen.findByTestId('migration-source-error');
		expectSecretRedacted(error.textContent ?? '', [APP_ID_CANARY, API_KEY_CANARY]);
		expect(error).toHaveTextContent('other-context');
	});

	it('surfaces the producer error message and retries the same discovery request', async () => {
		const list = vi
			.fn()
			.mockRejectedValueOnce(
				Object.assign(new Error('invalid_algolia_credentials'), { status: 400 })
			)
			.mockResolvedValueOnce(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);

		const error = await screen.findByTestId('migration-source-error');
		expect(screen.getByRole('alert')).toBe(error);
		expect(error).toHaveTextContent('invalid_algolia_credentials');
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /retry/i }));

		await screen.findByTestId('migration-source-row-source_products');
		expect(list).toHaveBeenCalledTimes(2);
		expect(screen.queryByTestId('migration-source-error')).not.toBeInTheDocument();
	});

	it('clears a stale source list when a later discovery attempt fails', async () => {
		const list = vi
			.fn()
			.mockResolvedValueOnce(listResponse([sourceIndex()], 'opaque-cursor-1'))
			.mockRejectedValueOnce(new Error('algolia_discovery_unavailable'));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		await fireEvent.click(screen.getByRole('button', { name: /load more source indexes/i }));

		expect(await screen.findByTestId('migration-source-error')).toHaveTextContent(
			'algolia_discovery_unavailable'
		);
	});

	it('rebuilds the whole catalog from the first page when retrying a failed cursor page', async () => {
		// A failed page clears the accumulated list, so replaying the failed cursor
		// would append page two onto nothing and present it as the complete
		// catalog — a customer would silently lose every page-one index.
		const list = vi
			.fn()
			.mockResolvedValueOnce(listResponse([sourceIndex()], 'opaque-cursor-1'))
			.mockRejectedValueOnce(new Error('algolia_discovery_unavailable'))
			.mockResolvedValueOnce(listResponse([sourceIndex()], 'opaque-cursor-1'));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		await fireEvent.click(screen.getByRole('button', { name: /load more source indexes/i }));
		await screen.findByTestId('migration-source-error');
		await waitForDiscoveryToSettle();

		await fireEvent.click(screen.getByRole('button', { name: /retry/i }));

		await screen.findByTestId('migration-source-row-source_products');
		await waitForDiscoveryToSettle();
		expect(list).toHaveBeenLastCalledWith({ appId: APP_ID_CANARY, apiKey: API_KEY_CANARY });
		// Page one is present again and load-more is offered, so the customer can
		// walk the full catalog rather than a truncated tail of it.
		expect(screen.getByRole('button', { name: /load more source indexes/i })).toBeInTheDocument();
	});

	it('redacts provider eligibility tokens from target-eligibility errors', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockRejectedValue(
				new Error(
					`eligibility_rejected ${ELIGIBLE_AWS_PROVIDER.eligibilityToken} keep-visible-context`
				)
			);
		render(MigrationCreateFlow, {
			client: {
				listAlgoliaSourceIndexes: list,
				checkAlgoliaDestinationEligibility,
				createAlgoliaImportJob: vi.fn(),
				previewMigrationImport: vi.fn()
			},
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			capabilities: availableAvailability.capabilities
		});

		await connect(list);
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));

		const error = await screen.findByTestId('migration-target-eligibility-error');
		expectSecretRedacted(error.textContent ?? '', [ELIGIBLE_AWS_PROVIDER.eligibilityToken]);
		expect(error).toHaveTextContent('keep-visible-context');
	});

	it('redacts source credentials and target tokens from submit errors', async () => {
		const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		const createAlgoliaImportJob = vi
			.fn()
			.mockRejectedValue(
				new Error(`submit_failed ${APP_ID_CANARY} ${API_KEY_CANARY} target-token-canary retryable`)
			);
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue({
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'source_products' },
			eligibilityToken: 'target-token-canary',
			expiresAt: '2099-07-18T10:20:00Z'
		});
		render(MigrationCreateFlow, {
			client: {
				listAlgoliaSourceIndexes,
				checkAlgoliaDestinationEligibility,
				previewMigrationImport: vi.fn().mockRejectedValue(new Error('preview_failed retryable')),
				createAlgoliaImportJob
			},
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			capabilities: availableAvailability.capabilities
		});

		await connect(listAlgoliaSourceIndexes);
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));
		await screen.findByRole('button', { name: /start import/i });
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		const error = await screen.findByTestId('migration-start-error');
		expectSecretRedacted(error.textContent ?? '', [
			APP_ID_CANARY,
			API_KEY_CANARY,
			'target-token-canary'
		]);
		expect(error).toHaveTextContent('retryable');
	});
});

describe('MigrationCreateFlow - credential containment', () => {
	it('keeps credentials out of markup, storage, and the URL after discovery', async () => {
		// Spying on the prototype covers localStorage and sessionStorage together,
		// and does not depend on either global accessor being exposed by jsdom.
		const setItem = vi.spyOn(Storage.prototype, 'setItem');
		const pushState = vi.spyOn(window.history, 'pushState');
		const replaceState = vi.spyOn(window.history, 'replaceState');
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		// The only sanctioned homes are the two live input values and the
		// credential-bearing discovery request body.
		const appIdInput = screen.getByLabelText(/algolia application id/i);
		const apiKeyInput = screen.getByLabelText(/algolia api key/i);
		expect(appIdInput).toHaveValue(APP_ID_CANARY);
		expect(apiKeyInput).toHaveValue(API_KEY_CANARY);
		expect(list).toHaveBeenCalledWith({ appId: APP_ID_CANARY, apiKey: API_KEY_CANARY });

		// Serialized markup catches credentials leaked into text nodes, attributes,
		// data-* attributes, or any other rendered state outside live input values.
		for (const canary of [APP_ID_CANARY, API_KEY_CANARY]) {
			expect(document.body).not.toHaveTextContent(canary);
			expect(document.body.innerHTML).not.toContain(canary);
			expect(window.location.href).not.toContain(canary);
		}
		expect(setItem).not.toHaveBeenCalled();
		expect(pushState).not.toHaveBeenCalled();
		expect(replaceState).not.toHaveBeenCalled();
	});

	it('masks the api key input and never renders it as readable text', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);

		expect(screen.getByLabelText(/algolia application id/i)).toHaveAttribute('autocomplete', 'off');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveAttribute('type', 'password');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveAttribute('autocomplete', 'off');
		expect(screen.queryByText(API_KEY_CANARY)).not.toBeInTheDocument();
	});

	it('does not submit credentials through a form action', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		const { container } = renderFlow(list);

		await connect(list);

		expect(container.querySelector('form')).not.toBeInTheDocument();
	});

	it('starts blank after remount so credentials do not survive component destruction', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);
		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		cleanup();
		renderFlow(list);

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
	});
});

describe('MigrationCreateFlow - neutral source provider invalidation', () => {
	function neutralClient(overrides: Partial<Record<string, ReturnType<typeof vi.fn>>> = {}) {
		const listMigrationSourceIndexes = vi
			.fn()
			.mockResolvedValue(listResponse([sourceIndex()], 'opaque-cursor-1'));
		const checkMigrationDestinationEligibility = vi.fn().mockResolvedValue({
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'source_products' },
			eligibilityToken: 'target-token-canary',
			expiresAt: '2099-07-18T10:20:00Z'
		});
		const createMigrationImportJob = vi.fn().mockResolvedValue(importJob());
		const previewMigrationImport = vi.fn().mockResolvedValue({
			sourceCounts: { indexes: 1, records: 2 },
			report: {
				summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
				entries: [],
				reportDigest: 'sha256:neutral-preview'
			}
		});
		const client = {
			listMigrationSourceIndexes,
			checkMigrationDestinationEligibility,
			previewMigrationImport,
			createMigrationImportJob,
			listAlgoliaSourceIndexes: vi.fn(),
			checkAlgoliaDestinationEligibility: vi.fn(),
			createAlgoliaImportJob: vi.fn(),
			...overrides
		};
		const resolvedListMigrationSourceIndexes =
			client.listMigrationSourceIndexes ?? listMigrationSourceIndexes;
		const resolvedCheckMigrationDestinationEligibility =
			client.checkMigrationDestinationEligibility ?? checkMigrationDestinationEligibility;
		const resolvedCreateMigrationImportJob =
			client.createMigrationImportJob ?? createMigrationImportJob;
		const resolvedPreviewMigrationImport = client.previewMigrationImport ?? previewMigrationImport;
		return {
			client: client as unknown as MigrationFlowClient,
			listMigrationSourceIndexes: resolvedListMigrationSourceIndexes,
			checkMigrationDestinationEligibility: resolvedCheckMigrationDestinationEligibility,
			previewMigrationImport: resolvedPreviewMigrationImport,
			createMigrationImportJob: resolvedCreateMigrationImportJob
		};
	}

	async function connectNeutralSource(
		sourceProvider: SourceProvider,
		client: ReturnType<typeof neutralClient>,
		apiKey = API_KEY_CANARY
	) {
		await fireEvent.click(screen.getByRole('radio', { name: new RegExp(sourceProvider, 'i') }));
		if (sourceProvider === 'algolia') {
			await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
				target: { value: APP_ID_CANARY }
			});
			await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
				target: { value: apiKey }
			});
		} else {
			await fireEvent.input(screen.getByLabelText(new RegExp(`${sourceProvider} host url`, 'i')), {
				target: { value: `https://${sourceProvider}.example.test` }
			});
			await fireEvent.input(screen.getByLabelText(new RegExp(`${sourceProvider} api key`, 'i')), {
				target: { value: apiKey }
			});
		}
		await fireEvent.click(
			screen.getByRole('button', { name: new RegExp(`connect to ${sourceProvider}`, 'i') })
		);
		await waitFor(() => expect(client.listMigrationSourceIndexes).toHaveBeenCalledOnce());
		await screen.findByTestId('migration-source-row-source_products');
	}

	async function establishNeutralSubmitIntent(
		sourceProvider: SourceProvider,
		client: ReturnType<typeof neutralClient>
	) {
		await connectNeutralSource(sourceProvider, client);
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));
		await screen.findByRole('button', { name: /start import/i });
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await waitFor(() => expect(client.createMigrationImportJob).toHaveBeenCalledOnce());
		const [, , idempotencyKey] = client.createMigrationImportJob.mock.calls[0] ?? [];
		expect(idempotencyKey).toEqual(expect.any(String));
		expect(idempotencyKey).not.toBe('');
		return idempotencyKey as string;
	}

	async function completeNeutralPreviewAttempt() {
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));
		await screen.findByRole('button', { name: /start import/i });
	}

	function expectNeutralDownstreamStateCleared(client: ReturnType<typeof neutralClient>) {
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-selected-source')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/target eligible/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /start import/i })).not.toBeInTheDocument();
		expect(client.checkMigrationDestinationEligibility).toHaveBeenCalledOnce();
		expect(client.createMigrationImportJob).toHaveBeenCalledOnce();
	}

	it.each([
		{
			name: 'source provider',
			mutate: async () => {
				await fireEvent.click(screen.getByRole('radio', { name: /meilisearch/i }));
			},
			assertCredentialState: () => {
				expect(screen.getByLabelText(/meilisearch host url/i)).toHaveValue('');
				expect(screen.getByLabelText(/meilisearch api key/i)).toHaveValue('');
			}
		},
		{
			name: 'host',
			mutate: async () => {
				await fireEvent.input(screen.getByLabelText(/typesense host url/i), {
					target: { value: 'https://typesense-edited.example.test' }
				});
			},
			assertCredentialState: () => {
				expect(screen.getByLabelText(/typesense host url/i)).toHaveValue(
					'https://typesense-edited.example.test'
				);
				expect(screen.getByLabelText(/typesense api key/i)).toHaveValue(API_KEY_CANARY);
			}
		},
		{
			name: 'credential',
			mutate: async () => {
				await fireEvent.input(screen.getByLabelText(/typesense api key/i), {
					target: { value: 'typesense-edited-secret-key-0009' }
				});
			},
			assertCredentialState: () => {
				expect(screen.getByLabelText(/typesense host url/i)).toHaveValue(
					'https://typesense.example.test'
				);
				expect(screen.getByLabelText(/typesense api key/i)).toHaveValue(
					'typesense-edited-secret-key-0009'
				);
			}
		}
	])(
		'clears connection, catalog, cursor, selection, key fingerprint, submit intent, and target eligibility when $name changes',
		async ({ mutate, assertCredentialState }) => {
			const client = neutralClient({
				createMigrationImportJob: vi.fn().mockRejectedValue(new Error('backend_unavailable'))
			});
			render(MigrationCreateFlow, {
				client: client.client,
				providerEligibility: ELIGIBLE_AWS_PROVIDER,
				capabilities: availableAvailability.capabilities
			});

			await establishNeutralSubmitIntent('typesense', client);
			expect(screen.getByTestId('migration-start-error')).toHaveTextContent('backend_unavailable');
			await mutate();

			assertCredentialState();
			expectNeutralDownstreamStateCleared(client);
			expect(JSON.stringify(client.checkMigrationDestinationEligibility.mock.calls)).not.toContain(
				API_KEY_CANARY
			);
		}
	);

	it('keeps a seeded source credential canary only in live inputs and credential-bearing requests after neutral submit', async () => {
		const setItem = vi.spyOn(Storage.prototype, 'setItem');
		const pushState = vi.spyOn(window.history, 'pushState');
		const replaceState = vi.spyOn(window.history, 'replaceState');
		const publicStateCanary = 'neutral-secret-canary-0008';
		const onImportCreated = vi.fn();
		const client = neutralClient();
		render(MigrationCreateFlow, {
			client: client.client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			capabilities: availableAvailability.capabilities,
			onImportCreated
		});

		await connectNeutralSource('typesense', client, publicStateCanary);
		expect(screen.getByLabelText(/typesense api key/i)).toHaveValue(publicStateCanary);
		expect(client.listMigrationSourceIndexes).toHaveBeenCalledWith('typesense', {
			host: 'https://typesense.example.test',
			apiKey: publicStateCanary
		});

		await completeNeutralPreviewAttempt();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await waitFor(() => expect(client.createMigrationImportJob).toHaveBeenCalledOnce());
		expect(client.createMigrationImportJob).toHaveBeenCalledWith(
			'typesense',
			{
				mode: 'create',
				host: 'https://typesense.example.test',
				apiKey: publicStateCanary,
				sourceName: 'source_products',
				target: { eligibilityToken: 'target-token-canary' }
			},
			expect.any(String)
		);
		await waitFor(() => expect(onImportCreated).toHaveBeenCalledOnce());

		expect(document.body.innerHTML).not.toContain(publicStateCanary);
		expect(window.location.href).not.toContain(publicStateCanary);
		expect(JSON.stringify(onImportCreated.mock.calls)).not.toContain(publicStateCanary);
		for (const call of setItem.mock.calls) {
			expect(JSON.stringify(call)).not.toContain(publicStateCanary);
		}
		for (const call of [...pushState.mock.calls, ...replaceState.mock.calls]) {
			expect(JSON.stringify(call)).not.toContain(publicStateCanary);
		}
	});

	it('zeroizes volatile source credentials before the success callback runs', async () => {
		const publicStateCanary = 'neutral-secret-canary-0010';
		const onImportCreated = vi.fn(() => {
			expect(screen.getByLabelText(/typesense host url/i)).toHaveValue('');
			expect(screen.getByLabelText(/typesense api key/i)).toHaveValue('');
			expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
			expect(document.body.innerHTML).not.toContain(publicStateCanary);
		});
		const client = neutralClient();
		render(MigrationCreateFlow, {
			client: client.client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			capabilities: availableAvailability.capabilities,
			onImportCreated
		});

		await connectNeutralSource('typesense', client, publicStateCanary);
		await completeNeutralPreviewAttempt();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(client.createMigrationImportJob).toHaveBeenCalledOnce());
		await waitFor(() => expect(onImportCreated).toHaveBeenCalledOnce());
	});

	it('zeroizes volatile source credentials after success without a callback', async () => {
		const publicStateCanary = 'neutral-secret-canary-0011';
		const client = neutralClient();
		render(MigrationCreateFlow, {
			client: client.client,
			providerEligibility: ELIGIBLE_AWS_PROVIDER,
			capabilities: availableAvailability.capabilities
		});

		await connectNeutralSource('typesense', client, publicStateCanary);
		await completeNeutralPreviewAttempt();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(client.createMigrationImportJob).toHaveBeenCalledOnce());
		await waitFor(() => {
			expect(screen.getByLabelText(/typesense host url/i)).toHaveValue('');
			expect(screen.getByLabelText(/typesense api key/i)).toHaveValue('');
		});
		expect(document.body.innerHTML).not.toContain(publicStateCanary);
	});
});
