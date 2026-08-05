import { afterEach, describe, expect, it, type Mock, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

import type {
	AlgoliaDestinationEligibilityResponse,
	MigrationPreviewResponse,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';
import {
	API_KEY_CANARY,
	APP_ID_CANARY,
	availableAvailability,
	ELIGIBLE_AWS_PROVIDER,
	ELIGIBLE_AWS_REPLACE_PROVIDER,
	importJob,
	listResponse,
	previewResponse,
	REPLACE_CAPABILITY,
	REPLACE_TARGET_ELIGIBILITY,
	sourceIndex,
	TARGET_ELIGIBILITY
} from './migration_test_fixtures';
import {
	INDEX_NAME_MAX_LENGTH,
	proposeDestinationIndexName,
	validateIndexName
} from '$lib/index-name';

afterEach(() => {
	cleanup();
	vi.useRealTimers();
	vi.restoreAllMocks();
});

type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];
const REPLACE_PREVIEW_CAPABILITY = { ...REPLACE_CAPABILITY, preview: true };

function migrationClient(overrides: Partial<MigrationFlowClient> = {}): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes: vi.fn(),
		checkAlgoliaDestinationEligibility: vi.fn(),
		previewMigrationImport: vi.fn().mockResolvedValue(previewResponse()),
		createAlgoliaImportJob: vi.fn(),
		...overrides
	};
}

function renderFlow(
	listAlgoliaSourceIndexes = vi.fn(),
	overrides: Partial<MigrationFlowClient> = {},
	props: Partial<ComponentProps<typeof MigrationCreateFlow>> = {}
) {
	const client = migrationClient({ listAlgoliaSourceIndexes, ...overrides });
	const result = render(MigrationCreateFlow, {
		client,
		providerEligibility: ELIGIBLE_AWS_PROVIDER,
		capabilities: availableAvailability.capabilities,
		...props
	});
	return { ...result, client, listAlgoliaSourceIndexes };
}

async function connect() {
	await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
		target: { value: APP_ID_CANARY }
	});
	await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
		target: { value: API_KEY_CANARY }
	});
	await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
}

async function selectSource(name: string) {
	const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue(listResponse([sourceIndex({ name })]));
	renderFlow(listAlgoliaSourceIndexes);
	await connect();
	await screen.findByTestId('migration-source-list');
	await fireEvent.change(screen.getByRole('radio', { name: new RegExp(name, 'i') }));
	return screen.getByLabelText(/destination index name/i) as HTMLInputElement;
}

async function connectAndSelectSource(
	name = 'source_products',
	overrides: Partial<MigrationFlowClient> = {},
	props: Partial<ComponentProps<typeof MigrationCreateFlow>> = {}
) {
	const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue(listResponse([sourceIndex({ name })]));
	const result = renderFlow(listAlgoliaSourceIndexes, overrides, props);
	await connect();
	await screen.findByTestId('migration-source-list');
	await fireEvent.change(screen.getByRole('radio', { name: new RegExp(name, 'i') }));
	return result;
}

async function previewImport() {
	await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));
	await screen.findByTestId('migration-preview-counts');
}

async function checkDestinationEligibility() {
	await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
	return screen.findByTestId('migration-create-review');
}

async function checkDestinationEligibilityAndPreview() {
	await checkDestinationEligibility();
	await previewImport();
}
function expectSecretRedacted(text: string, secrets: readonly string[]) {
	expect(text).toContain('[redacted]');
	for (const secret of secrets) expect(text).not.toContain(secret);
}

function expectEligibilityRequest(checkEligibility: Mock, expectedRequest: unknown) {
	expect(checkEligibility).toHaveBeenCalledOnce();
	expect(checkEligibility).toHaveBeenCalledWith(expectedRequest);
	const serializedCalls = JSON.stringify(checkEligibility.mock.calls);
	expect(serializedCalls).not.toContain(APP_ID_CANARY);
	expect(serializedCalls).not.toContain(API_KEY_CANARY);
}

function expectCompatibilityWarning(resource: string, expectedText: readonly string[]) {
	const warningList = screen.getByRole('list', { name: `${resource} compatibility warnings` });
	for (const text of expectedText) expect(warningList).toHaveTextContent(text);
}

function cleanPreviewResponse(): MigrationPreviewResponse {
	return previewResponse({
		report: {
			summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
			entries: [],
			reportDigest: 'sha256:clean-preview'
		}
	});
}
describe('MigrationCreateFlow - destination name proposal', () => {
	it('offers no destination field until a source is selected', async () => {
		const listAlgoliaSourceIndexes = vi
			.fn()
			.mockResolvedValue(listResponse([sourceIndex({ name: 'source_products' })]));
		renderFlow(listAlgoliaSourceIndexes);
		await connect();
		await screen.findByTestId('migration-source-list');

		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
	});

	it('seeds the destination field with a valid proposal derived from the source name', async () => {
		const destinationInput = await selectSource('source_products');
		expect(destinationInput).toHaveValue('source_products');
	});

	it('moves focus to the destination step heading after source selection', async () => {
		await selectSource('source_products');

		const destinationHeading = screen.getByRole('heading', {
			name: 'Review destination',
			level: 4
		});
		await waitFor(() => expect(destinationHeading).toHaveFocus());
	});

	it('proposes a valid name for a source whose name is not directly usable', async () => {
		const destinationInput = await selectSource('Café Products 2026!');
		expect(destinationInput).toHaveValue('Cafe-Products-2026');
	});

	it('displays the exact source name alongside the normalized proposal', async () => {
		const rawSourceName = 'Café Products 2026!';
		await selectSource(rawSourceName);

		expect(screen.getByTestId('migration-selected-source')).toHaveTextContent(rawSourceName);
	});

	it('preserves a user edit to the proposed destination name', async () => {
		const destinationInput = await selectSource('source_products');

		await fireEvent.input(destinationInput, { target: { value: 'my_chosen_name' } });

		expect(screen.getByLabelText(/destination index name/i)).toHaveValue('my_chosen_name');
	});

	it('re-proposes from the newly selected source when the source changes', async () => {
		const listAlgoliaSourceIndexes = vi
			.fn()
			.mockResolvedValue(
				listResponse([
					sourceIndex({ name: 'first_source' }),
					sourceIndex({ name: 'second_source' })
				])
			);
		renderFlow(listAlgoliaSourceIndexes);
		await connect();
		await screen.findByTestId('migration-source-list');

		await fireEvent.change(screen.getByRole('radio', { name: /first_source/i }));
		await fireEvent.input(screen.getByLabelText(/destination index name/i), {
			target: { value: 'edited_for_first' }
		});
		await fireEvent.change(screen.getByRole('radio', { name: /second_source/i }));

		expect(screen.getByLabelText(/destination index name/i)).toHaveValue('second_source');
	});

	it('surfaces the validation message for an invalid user-edited name', async () => {
		const destinationInput = await selectSource('source_products');

		await fireEvent.input(destinationInput, { target: { value: 'bad name' } });

		expect(destinationInput).toHaveAttribute('aria-invalid', 'true');
		expect(destinationInput).toHaveAttribute('aria-describedby', 'migration-destination-error');
		expect(screen.getByTestId('migration-destination-error')).toHaveTextContent(
			'Only letters, numbers, hyphens, and underscores allowed'
		);
	});

	it('moves focus to the destination validation message when an invalid edit is committed', async () => {
		const destinationInput = await selectSource('source_products');

		await fireEvent.input(destinationInput, { target: { value: 'bad name' } });
		await fireEvent.change(destinationInput);

		await waitFor(() => expect(screen.getByTestId('migration-destination-error')).toHaveFocus());
	});

	it('shows no validation message while the edited name is valid', async () => {
		const destinationInput = await selectSource('source_products');

		await fireEvent.input(destinationInput, { target: { value: 'still_valid' } });

		expect(destinationInput).toHaveAttribute('aria-invalid', 'false');
		expect(destinationInput).not.toHaveAttribute('aria-describedby');
		expect(screen.queryByTestId('migration-destination-error')).not.toBeInTheDocument();
	});

	it('does not consult any destination catalog to build the proposal', async () => {
		const { listAlgoliaSourceIndexes } = renderFlow(
			vi.fn().mockResolvedValue(listResponse([sourceIndex({ name: 'source_products' })]))
		);
		await connect();
		await screen.findByTestId('migration-source-list');
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));

		expect(listAlgoliaSourceIndexes).toHaveBeenCalledTimes(1);
	});

	it.each([
		['Unicode folding', 'Café Products', 'Cafe-Products'],
		['spaces and punctuation', '  Sales / UK & EU! ', 'Sales-UK-EU'],
		['reserved name', 'health', 'health-import'],
		[
			'long source truncation',
			'a'.repeat(INDEX_NAME_MAX_LENGTH + 10),
			'a'.repeat(INDEX_NAME_MAX_LENGTH)
		],
		[
			'truncation collision remains catalog-independent',
			`${'a'.repeat(INDEX_NAME_MAX_LENGTH)}-tenant-b`,
			'a'.repeat(INDEX_NAME_MAX_LENGTH)
		]
	])('uses the canonical proposal and validation rules for %s', (_name, source, expected) => {
		const proposal = proposeDestinationIndexName(source);

		expect(proposal).toBe(expected);
		expect(validateIndexName(proposal)).toBeNull();
	});

	it('keeps replica source rows disabled and directs customers to import the primary whose replicas are reconstructed as Flapjack virtual replicas', async () => {
		const listAlgoliaSourceIndexes = vi
			.fn()
			.mockResolvedValue(
				listResponse([
					sourceIndex({ name: 'source_products', primary: null }),
					sourceIndex({ name: 'source_products_price_asc', primary: 'source_products' })
				])
			);
		renderFlow(listAlgoliaSourceIndexes);

		await connect();
		const replicaRow = await screen.findByTestId('migration-source-row-source_products_price_asc');
		const replicaInput = screen.getByRole('radio', {
			name: /source_products_price_asc/i
		}) as HTMLInputElement;

		expect(replicaInput).toBeDisabled();
		expect(replicaRow).toHaveTextContent(
			'Import the primary index instead. Its Algolia replicas are reconstructed as Flapjack virtual replicas. If one cannot be reconstructed, the imported primary remains in place.'
		);
		expect(replicaRow).not.toHaveTextContent('replica indices are not copied');
		expect(replicaRow).not.toHaveTextContent(
			'alternate sort orders built on replicas do not carry over'
		);
	});
});

describe('MigrationCreateFlow - target eligibility and start', () => {
	it('checks final target eligibility without Algolia credential bytes and renders the review step', async () => {
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(TARGET_ELIGIBILITY);
		await connectAndSelectSource('source_products', { checkAlgoliaDestinationEligibility });
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await waitFor(() =>
			expectEligibilityRequest(checkAlgoliaDestinationEligibility, {
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: 'source_products' },
				eligibilityToken: 'provider-eligibility-token'
			})
		);

		const preview = screen.getByTestId('migration-create-preview');
		expect(preview).toHaveTextContent('Preview import');
		expect(screen.getByTestId('migration-create-review')).toHaveTextContent('Review import');
		expect(screen.queryByRole('button', { name: /^start import$/i })).not.toBeInTheDocument();
	});

	it('previews exact counts and shared warning fields before enabling import creation', async () => {
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(TARGET_ELIGIBILITY);
		const previewMigrationImport = vi.fn().mockResolvedValue(previewResponse());
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			previewMigrationImport,
			createAlgoliaImportJob
		});

		await checkDestinationEligibility();
		expect(screen.queryByRole('button', { name: /^start import$/i })).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));

		await waitFor(() => expect(previewMigrationImport).toHaveBeenCalledOnce());
		expect(previewMigrationImport).toHaveBeenCalledWith('algolia', {
			appId: APP_ID_CANARY,
			apiKey: API_KEY_CANARY,
			sourceIndex: 'source_products',
			targetIndex: 'source_products',
			overwrite: false
		});
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();
		expect(await screen.findByTestId('migration-preview-counts')).toHaveTextContent(
			'3 source indexes · 42 records'
		);
		expect(screen.getByTestId('migration-job-warning-summary')).toHaveTextContent(
			'Preview found 2 compatibility findings: 1 hard rejection and 1 warning.'
		);
		expectCompatibilityWarning('Settings', [
			'Compatibility warning',
			'Warning',
			'UnsupportedSourceField',
			'item 0, path $.settings.attributesForFaceting[0]'
		]);
		expectCompatibilityWarning('Document', [
			'MalformedDocumentPayload',
			'page 1, item 7, path $.hits[7]'
		]);

		const review = await screen.findByTestId('migration-create-review');
		expect(review).toHaveTextContent('source_products');
		expect(review).toHaveTextContent('us-east-1');
		expect(review).toHaveTextContent('Create a new destination index');
		expect(review).toHaveTextContent(
			'Create a new destination index. Primary index records, settings, synonyms, and rules are imported. Algolia replicas are reconstructed as Flapjack virtual replicas. If one cannot be reconstructed, the imported primary remains in place.'
		);
		expect(review).not.toHaveTextContent('replica indices are not copied');
		expect(review).toHaveTextContent('Imports available');
		expect(review.textContent).not.toMatch(/\d+%/);

		// The report carries a hard rejection, so the advisory label must warn that
		// the import may fail or omit data while still allowing an explicit start.
		expect(screen.queryByRole('button', { name: /^start import$/i })).not.toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: /^start import anyway$/i }));
		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
	});

	it('renders the exact clean preview copy when the preview has no compatibility entries', async () => {
		const previewMigrationImport = vi.fn().mockResolvedValue(cleanPreviewResponse());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility: vi.fn().mockResolvedValue(TARGET_ELIGIBILITY),
			previewMigrationImport
		});

		await checkDestinationEligibility();
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));

		expect(await screen.findByTestId('migration-preview-clean')).toHaveTextContent(
			'No compatibility issues found'
		);
		// Nothing was rejected, so the plain label stays — the advisory wording is
		// reserved for reports that actually warn the import may fail.
		expect(screen.getByRole('button', { name: /^start import$/i })).toBeInTheDocument();
		expect(
			screen.queryByRole('button', { name: /^start import anyway$/i })
		).not.toBeInTheDocument();
	});

	it('treats sanitized preview request errors as advisory before explicit start', async () => {
		const previewMigrationImport = vi
			.fn()
			.mockRejectedValue(new Error(`preview_failed ${APP_ID_CANARY} ${API_KEY_CANARY} retryable`));
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility: vi.fn().mockResolvedValue(TARGET_ELIGIBILITY),
			previewMigrationImport,
			createAlgoliaImportJob
		});

		await checkDestinationEligibility();
		expect(screen.queryByRole('button', { name: /start import/i })).not.toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));

		const error = await screen.findByTestId('migration-preview-error');
		expectSecretRedacted(error.textContent ?? '', [APP_ID_CANARY, API_KEY_CANARY]);
		expect(error).toHaveTextContent('retryable');
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByRole('button', { name: /start import anyway/i }));

		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
	});

	it('states no preview completed and no job was created, and offers Retry preview', async () => {
		const previewMigrationImport = vi
			.fn()
			.mockRejectedValueOnce(new Error('invalid_credentials'))
			.mockResolvedValueOnce(cleanPreviewResponse());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility: vi.fn().mockResolvedValue(TARGET_ELIGIBILITY),
			previewMigrationImport,
			createAlgoliaImportJob: vi.fn().mockResolvedValue(importJob())
		});

		await checkDestinationEligibility();
		await fireEvent.click(screen.getByRole('button', { name: /^preview import$/i }));

		const error = await screen.findByTestId('migration-preview-error');
		expect(error).toHaveTextContent(
			'Algolia credentials were rejected. Reconnect with a valid key. No preview was completed and no import job was created.'
		);
		expect(screen.queryByRole('button', { name: /^preview import$/i })).not.toBeInTheDocument();

		// Retrying stays inside the same step: credentials and selections survive.
		await fireEvent.click(screen.getByRole('button', { name: /^retry preview$/i }));

		expect(await screen.findByTestId('migration-preview-clean')).toHaveTextContent(
			'No compatibility issues found'
		);
		expect(screen.queryByTestId('migration-preview-error')).not.toBeInTheDocument();
		expect(previewMigrationImport).toHaveBeenCalledTimes(2);
	});

	it('expires the final review and blocks start as soon as the target token expires', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:00:00Z'));
		const expiringTarget = {
			...TARGET_ELIGIBILITY,
			expiresAt: '2026-07-18T10:01:00Z'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(expiringTarget);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});

		await checkDestinationEligibility();

		await vi.advanceTimersByTimeAsync(60_001);

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue(API_KEY_CANARY);
		expect(screen.getByTestId('migration-selected-source')).toHaveTextContent('source_products');

		await fireEvent.click(startButton);
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();
	});

	it('invalidates final eligibility when the destination is edited and blocks submit until refreshed', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValueOnce(TARGET_ELIGIBILITY)
			.mockResolvedValueOnce({
				...TARGET_ELIGIBILITY,
				target: { ...TARGET_ELIGIBILITY.target, name: 'edited_destination' },
				eligibilityToken: 'edited-target-token'
			} satisfies AlgoliaDestinationEligibilityResponse);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});

		await checkDestinationEligibility();
		await fireEvent.input(screen.getByLabelText(/destination index name/i), {
			target: { value: 'edited_destination' }
		});

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /start import/i })).toBeDisabled();

		await checkDestinationEligibilityAndPreview();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
		expect(createAlgoliaImportJob.mock.calls[0]?.[0]).toMatchObject({
			target: { eligibilityToken: 'edited-target-token' }
		});
	});

	it('invalidates the prior target token while a manual eligibility refresh is in flight', async () => {
		let resolveRefresh!: (eligibility: AlgoliaDestinationEligibilityResponse) => void;
		const refreshedTarget = {
			...TARGET_ELIGIBILITY,
			eligibilityToken: 'refreshed-target-token'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValueOnce(TARGET_ELIGIBILITY)
			.mockImplementationOnce(
				() =>
					new Promise<AlgoliaDestinationEligibilityResponse>((resolve) => {
						resolveRefresh = resolve;
					})
			);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		await checkDestinationEligibility();

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2));

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();
		await fireEvent.click(startButton);
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();

		resolveRefresh(refreshedTarget);
		await screen.findByTestId('migration-create-review');
		await previewImport();
		expect(screen.getByRole('button', { name: /start import/i })).toBeEnabled();
	});

	it('submits the canonical create request once per intent and emits one durable navigation intent', async () => {
		let resolveCreate!: (job: PublicAlgoliaImportJob) => void;
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(TARGET_ELIGIBILITY);
		const createAlgoliaImportJob = vi.fn<
			NonNullable<MigrationFlowClient['createAlgoliaImportJob']>
		>(
			() =>
				new Promise<PublicAlgoliaImportJob>((resolve) => {
					resolveCreate = resolve;
				})
		);
		const onImportCreated = vi.fn();
		await connectAndSelectSource(
			'source_products',
			{ checkAlgoliaDestinationEligibility, createAlgoliaImportJob },
			{ onImportCreated }
		);
		await checkDestinationEligibilityAndPreview();

		const startButton = screen.getByRole('button', { name: /start import/i });
		await fireEvent.click(startButton);
		await fireEvent.click(startButton);

		expect(createAlgoliaImportJob).toHaveBeenCalledOnce();
		const [request, idempotencyKey] = createAlgoliaImportJob.mock.calls[0] ?? [];
		expect(request).toEqual({
			mode: 'create',
			appId: APP_ID_CANARY,
			apiKey: API_KEY_CANARY,
			sourceName: 'source_products',
			target: { eligibilityToken: 'target-eligibility-token' }
		});
		expect(idempotencyKey).toEqual(expect.any(String));
		expect(idempotencyKey).not.toBe('');

		resolveCreate(importJob({ id: 'job_created_1' }));
		await waitFor(() =>
			expect(onImportCreated).toHaveBeenCalledWith({
				jobId: 'job_created_1',
				href: '/console/migrate/job_created_1?source_provider=algolia'
			})
		);

		expect(startButton).toBeDisabled();
		await fireEvent.click(startButton);
		expect(createAlgoliaImportJob).toHaveBeenCalledOnce();
		expect(onImportCreated).toHaveBeenCalledOnce();
	});

	it('reuses the idempotency key for retry of the same submit intent and rotates after target eligibility changes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValueOnce(TARGET_ELIGIBILITY)
			.mockResolvedValueOnce({
				...TARGET_ELIGIBILITY,
				target: { ...TARGET_ELIGIBILITY.target, name: 'second_destination' },
				eligibilityToken: 'second-target-token'
			} satisfies AlgoliaDestinationEligibilityResponse);
		const createAlgoliaImportJob = vi
			.fn()
			.mockRejectedValueOnce(new Error('backend_unavailable'))
			.mockRejectedValueOnce(new Error('backend_unavailable'))
			.mockResolvedValueOnce(importJob({ id: 'job_created_2' }));
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		await checkDestinationEligibilityAndPreview();

		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await screen.findByTestId('migration-start-error');
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledTimes(2));
		const firstKey = createAlgoliaImportJob.mock.calls[0]?.[1];
		expect(createAlgoliaImportJob.mock.calls[1]?.[1]).toBe(firstKey);

		await fireEvent.input(screen.getByLabelText(/destination index name/i), {
			target: { value: 'second_destination' }
		});
		await checkDestinationEligibilityAndPreview();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledTimes(3));

		expect(createAlgoliaImportJob.mock.calls[2]?.[1]).not.toBe(firstKey);
		expect(createAlgoliaImportJob.mock.calls[2]?.[0]).toMatchObject({
			target: { eligibilityToken: 'second-target-token' }
		});
	});

	it('requires another preview after refreshing an expired target token before submit', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:00:00Z'));
		const expiredTarget = {
			...TARGET_ELIGIBILITY,
			eligibilityToken: 'expired-target-token',
			expiresAt: '2026-07-18T10:01:00Z'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const refreshedTarget = {
			...TARGET_ELIGIBILITY,
			eligibilityToken: 'refreshed-target-token',
			expiresAt: '2026-07-18T10:10:00Z'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValueOnce(expiredTarget)
			.mockResolvedValueOnce(refreshedTarget);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		await checkDestinationEligibilityAndPreview();

		vi.setSystemTime(new Date('2026-07-18T10:02:00Z'));
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2));
		expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2);
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls[1])).not.toContain(
			API_KEY_CANARY
		);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue(API_KEY_CANARY);
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();
		expect(screen.queryByRole('button', { name: /start import/i })).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /^preview import$/i })).toBeEnabled();

		await previewImport();
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
		expect(createAlgoliaImportJob.mock.calls[0]?.[0]).toMatchObject({
			target: { eligibilityToken: 'refreshed-target-token' }
		});
	});

	it('rejects a refreshed target eligibility envelope that does not match the current inputs', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:00:00Z'));
		const expiringTarget = {
			...TARGET_ELIGIBILITY,
			eligibilityToken: 'expiring-target-token',
			expiresAt: '2026-07-18T10:01:00Z'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const mismatchedRefresh = {
			...TARGET_ELIGIBILITY,
			target: { ...TARGET_ELIGIBILITY.target, name: 'other_destination' },
			eligibilityToken: 'wrong-target-token',
			expiresAt: '2026-07-18T10:10:00Z'
		} satisfies AlgoliaDestinationEligibilityResponse;
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValueOnce(expiringTarget)
			.mockResolvedValueOnce(mismatchedRefresh);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob());
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		await checkDestinationEligibilityAndPreview();

		vi.setSystemTime(new Date('2026-07-18T10:02:00Z'));
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2));
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();
		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /start import/i })).toBeDisabled();
	});

	it('announces target eligibility failures without exposing credential bytes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockRejectedValue(new Error('destination already exists'));
		await connectAndSelectSource('source_products', { checkAlgoliaDestinationEligibility });

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));

		const alert = await screen.findByRole('alert');
		expect(alert).toHaveAttribute('data-testid', 'migration-target-eligibility-error');
		expect(alert).toHaveTextContent('destination already exists');
		expect(alert).not.toHaveTextContent(APP_ID_CANARY);
		expect(alert).not.toHaveTextContent(API_KEY_CANARY);
		expect(screen.getByRole('button', { name: /start import/i })).toBeDisabled();
	});
});

async function connectAndSelectReplaceSource(
	name = 'source_products',
	overrides: Partial<MigrationFlowClient> = {},
	sourceNames: string[] = [name]
) {
	const listAlgoliaSourceIndexes = vi
		.fn()
		.mockResolvedValue(
			listResponse(sourceNames.map((sourceName) => sourceIndex({ name: sourceName })))
		);
	const result = renderFlow(listAlgoliaSourceIndexes, overrides, {
		providerEligibility: ELIGIBLE_AWS_REPLACE_PROVIDER,
		capabilities: REPLACE_PREVIEW_CAPABILITY
	});
	await connect();
	await screen.findByTestId('migration-source-list');
	await fireEvent.change(screen.getByRole('radio', { name: new RegExp(name, 'i') }));
	return result;
}

describe('MigrationCreateFlow - replace target eligibility and start', () => {
	it('renders the fixed replace target review without credentials and warns about cutover writes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		await connectAndSelectReplaceSource('source_products', { checkAlgoliaDestinationEligibility });
		const review = await checkDestinationEligibility();
		await waitFor(() =>
			expectEligibilityRequest(checkAlgoliaDestinationEligibility, {
				phase: 'target',
				mode: 'replace',
				target: { region: 'us-west-2', name: 'existing_products' },
				eligibilityToken: 'replace-provider-eligibility-token'
			})
		);

		expect(review).toHaveTextContent('existing_products');
		expect(review).toHaveTextContent('us-west-2');
		expect(review).toHaveTextContent(/replace/i);
		expect(review).toHaveTextContent(
			'Replace the existing destination index. Primary index records, settings, synonyms, and rules are imported. Algolia replicas are reconstructed as Flapjack virtual replicas. If one cannot be reconstructed, the imported primary remains in place.'
		);
		expect(review).not.toHaveTextContent('replica indices are not copied');
		expect(review).toHaveTextContent(/pause writes/i);
		expect(review).toHaveTextContent(/cutover/i);
		expect(screen.queryByLabelText(/^destination index name$/i)).not.toBeInTheDocument();
	});

	it('requires exact destination-name typing before Start and submits one mode:replace request', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob({ mode: 'replace' }));
		const onImportCreated = vi.fn();
		const result = await connectAndSelectReplaceSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		result.rerender({
			client: result.client,
			providerEligibility: ELIGIBLE_AWS_REPLACE_PROVIDER,
			capabilities: REPLACE_PREVIEW_CAPABILITY,
			onImportCreated
		});

		await checkDestinationEligibilityAndPreview();

		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();

		const confirmation = screen.getByLabelText(/type the destination index name/i);
		await fireEvent.input(confirmation, { target: { value: 'EXISTING_PRODUCTS' } });
		expect(startButton).toBeDisabled();
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();

		await fireEvent.input(confirmation, { target: { value: 'existing_produc' } });
		expect(startButton).toBeDisabled();

		await fireEvent.input(confirmation, { target: { value: 'existing_products' } });
		expect(startButton).toBeEnabled();

		await fireEvent.click(startButton);
		await fireEvent.click(startButton);

		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
		expect(createAlgoliaImportJob.mock.calls[0]?.[0]).toEqual({
			mode: 'replace',
			appId: APP_ID_CANARY,
			apiKey: API_KEY_CANARY,
			sourceName: 'source_products',
			target: { eligibilityToken: 'replace-target-eligibility-token' }
		});
	});

	it('invalidates replace eligibility and confirmation when the source changes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		await connectAndSelectReplaceSource('source_products', { checkAlgoliaDestinationEligibility }, [
			'source_products',
			'other_source'
		]);

		await checkDestinationEligibility();
		await fireEvent.input(screen.getByLabelText(/type the destination index name/i), {
			target: { value: 'existing_products' }
		});

		await fireEvent.change(screen.getByRole('radio', { name: /other_source/i }));

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
	});
});
