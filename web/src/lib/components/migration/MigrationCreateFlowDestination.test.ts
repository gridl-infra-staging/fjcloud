import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

import type {
	AlgoliaDestinationEligibilityResponse,
	AlgoliaIndexMetadata,
	AlgoliaSourceListResponse,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';
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

const APP_ID_CANARY = 'CANARYAPPID0001';
const API_KEY_CANARY = 'canary-secret-key-0002';
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
const TARGET_ELIGIBILITY = {
	phase: 'target',
	mode: 'create',
	provider: 'aws',
	target: {
		kind: 'create',
		region: 'us-east-1',
		name: 'source_products'
	},
	eligibilityToken: 'target-eligibility-token',
	expiresAt: '2099-07-18T10:20:00Z'
} as const;

type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];

function sourceIndex(overrides: Partial<AlgoliaIndexMetadata> = {}): AlgoliaIndexMetadata {
	return {
		name: 'source_products',
		entries: 1234,
		dataSize: 2048,
		fileSize: 4096,
		updatedAt: '2026-07-18T10:00:00Z',
		lastBuildTimeS: 17,
		pendingTask: false,
		primary: null,
		replicas: [],
		...overrides
	};
}

function listResponse(
	items: AlgoliaIndexMetadata[],
	nextCursor: string | null = null
): AlgoliaSourceListResponse {
	return { items, nextCursor };
}

function importJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'queued',
		mode: 'create',
		destination: { kind: 'create', target: 'source_products', region: 'us-east-1' },
		source: { appId: APP_ID_CANARY, name: 'source_products' },
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
		warnings: {},
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'not_started',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:00:00Z',
		...overrides
	};
}

function migrationClient(overrides: Partial<MigrationFlowClient> = {}): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes: vi.fn(),
		checkAlgoliaDestinationEligibility: vi.fn(),
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

	it('disables replica selection in v1 and renders the exact consequence copy', async () => {
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
			'The primary index is imported, replica indices are not copied, and alternate sort orders built on replicas do not carry over.'
		);
	});
});

describe('MigrationCreateFlow - target eligibility and start', () => {
	it('checks final target eligibility without Algolia credential bytes and renders the review step', async () => {
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(TARGET_ELIGIBILITY);
		await connectAndSelectSource('source_products', { checkAlgoliaDestinationEligibility });

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));

		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledOnce());
		expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledWith({
			phase: 'target',
			mode: 'create',
			target: { region: 'us-east-1', name: 'source_products' },
			eligibilityToken: 'provider-eligibility-token'
		});
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls)).not.toContain(
			APP_ID_CANARY
		);
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls)).not.toContain(
			API_KEY_CANARY
		);

		const review = await screen.findByTestId('migration-create-review');
		expect(review).toHaveTextContent('source_products');
		expect(review).toHaveTextContent('us-east-1');
		expect(review).toHaveTextContent('Create a new destination index');
		expect(review).toHaveTextContent('Imports available');
		expect(review.textContent).not.toMatch(/\d+%/);
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

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

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

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.input(screen.getByLabelText(/destination index name/i), {
			target: { value: 'edited_destination' }
		});

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /start import/i })).toBeDisabled();

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
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
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2));

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();
		await fireEvent.click(startButton);
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();

		resolveRefresh(refreshedTarget);
		await screen.findByTestId('migration-create-review');
		expect(screen.getByRole('button', { name: /start import/i })).toBeEnabled();
	});

	it('submits the canonical create request once per intent and emits one durable navigation intent', async () => {
		let resolveCreate!: (job: PublicAlgoliaImportJob) => void;
		const checkAlgoliaDestinationEligibility = vi.fn().mockResolvedValue(TARGET_ELIGIBILITY);
		const createAlgoliaImportJob = vi.fn<MigrationFlowClient['createAlgoliaImportJob']>(
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
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

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
				href: '/console/migrate/job_created_1'
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
			.mockResolvedValueOnce(importJob())
			.mockResolvedValueOnce(importJob({ id: 'job_created_2' }));
		await connectAndSelectSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		await screen.findByTestId('migration-start-error');
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));
		const firstKey = createAlgoliaImportJob.mock.calls[0]?.[1];
		expect(createAlgoliaImportJob.mock.calls[1]?.[1]).toBe(firstKey);

		await fireEvent.input(screen.getByLabelText(/destination index name/i), {
			target: { value: 'second_destination' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		expect(createAlgoliaImportJob.mock.calls[2]?.[1]).not.toBe(firstKey);
		expect(createAlgoliaImportJob.mock.calls[2]?.[0]).toMatchObject({
			target: { eligibilityToken: 'second-target-token' }
		});
	});

	it('refreshes an expired target token before submit without resending or clearing the Algolia key', async () => {
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
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

		vi.setSystemTime(new Date('2026-07-18T10:02:00Z'));
		await fireEvent.click(screen.getByRole('button', { name: /start import/i }));

		await waitFor(() => expect(createAlgoliaImportJob).toHaveBeenCalledOnce());
		expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledTimes(2);
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls[1])).not.toContain(
			API_KEY_CANARY
		);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue(API_KEY_CANARY);
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
		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

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

const ELIGIBLE_AWS_REPLACE_PROVIDER = {
	phase: 'provider',
	mode: 'replace',
	provider: 'aws',
	target: {
		kind: 'replace',
		region: 'us-west-2',
		name: 'existing_products'
	},
	eligibilityToken: 'replace-provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;
const REPLACE_TARGET_ELIGIBILITY = {
	phase: 'target',
	mode: 'replace',
	provider: 'aws',
	target: {
		kind: 'replace',
		region: 'us-west-2',
		name: 'existing_products'
	},
	eligibilityToken: 'replace-target-eligibility-token',
	expiresAt: '2099-07-18T10:20:00Z'
} as const;
const REPLACE_CAPABILITY = { cancel: false, resume: false, replace: true } as const;

async function connectAndSelectReplaceSource(
	name = 'source_products',
	overrides: Partial<MigrationFlowClient> = {},
	sourceNames: string[] = [name]
) {
	const listAlgoliaSourceIndexes = vi
		.fn()
		.mockResolvedValue(listResponse(sourceNames.map((sourceName) => sourceIndex({ name: sourceName }))));
	const result = renderFlow(listAlgoliaSourceIndexes, overrides, {
		providerEligibility: ELIGIBLE_AWS_REPLACE_PROVIDER,
		capabilities: REPLACE_CAPABILITY
	});
	await connect();
	await screen.findByTestId('migration-source-list');
	await fireEvent.change(screen.getByRole('radio', { name: new RegExp(name, 'i') }));
	return result;
}

describe('MigrationCreateFlow - replace target eligibility and start', () => {
	it('checks replace target eligibility for the fixed existing identity without credential bytes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		await connectAndSelectReplaceSource('source_products', { checkAlgoliaDestinationEligibility });

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));

		await waitFor(() => expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledOnce());
		expect(checkAlgoliaDestinationEligibility).toHaveBeenCalledWith({
			phase: 'target',
			mode: 'replace',
			target: { region: 'us-west-2', name: 'existing_products' },
			eligibilityToken: 'replace-provider-eligibility-token'
		});
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls)).not.toContain(APP_ID_CANARY);
		expect(JSON.stringify(checkAlgoliaDestinationEligibility.mock.calls)).not.toContain(API_KEY_CANARY);

		const review = await screen.findByTestId('migration-create-review');
		expect(review).toHaveTextContent('existing_products');
		expect(review).toHaveTextContent('us-west-2');
		expect(review).toHaveTextContent(/replace/i);
		// The editable create-destination slug must never appear in replace mode;
		// only the exact-typing confirmation field is shown.
		expect(screen.queryByLabelText(/^destination index name$/i)).not.toBeInTheDocument();
	});

	it('warns that source and destination writes must be paused for the cutover', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		await connectAndSelectReplaceSource('source_products', { checkAlgoliaDestinationEligibility });

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		const review = await screen.findByTestId('migration-create-review');

		expect(review).toHaveTextContent(/pause writes/i);
		expect(review).toHaveTextContent(/cutover/i);
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
			capabilities: REPLACE_CAPABILITY,
			onImportCreated
		});

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();

		const confirmation = screen.getByLabelText(/type the destination index name/i);
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

	it('blocks the replace start when the confirmation does not match exactly', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		const createAlgoliaImportJob = vi.fn().mockResolvedValue(importJob({ mode: 'replace' }));
		await connectAndSelectReplaceSource('source_products', {
			checkAlgoliaDestinationEligibility,
			createAlgoliaImportJob
		});

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');

		await fireEvent.input(screen.getByLabelText(/type the destination index name/i), {
			target: { value: 'EXISTING_PRODUCTS' }
		});
		const startButton = screen.getByRole('button', { name: /start import/i });
		expect(startButton).toBeDisabled();
		await fireEvent.click(startButton);
		expect(createAlgoliaImportJob).not.toHaveBeenCalled();
	});

	it('invalidates replace eligibility and confirmation when the source changes', async () => {
		const checkAlgoliaDestinationEligibility = vi
			.fn()
			.mockResolvedValue(REPLACE_TARGET_ELIGIBILITY);
		await connectAndSelectReplaceSource('source_products', { checkAlgoliaDestinationEligibility }, [
			'source_products',
			'other_source'
		]);

		await fireEvent.click(screen.getByRole('button', { name: /check destination eligibility/i }));
		await screen.findByTestId('migration-create-review');
		await fireEvent.input(screen.getByLabelText(/type the destination index name/i), {
			target: { value: 'existing_products' }
		});

		await fireEvent.change(screen.getByRole('radio', { name: /other_source/i }));

		expect(screen.queryByTestId('migration-create-review')).not.toBeInTheDocument();
	});
});
