import type { Page, Route } from '@playwright/test';
import { expect } from '../../fixtures/fixtures';
import { stringify, uneval } from 'devalue';
import {
	availableAvailability,
	publicWarnings,
	WARNING_GROUPS
} from '../../../src/lib/components/migration/migration_fixtures_data';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaIndexMetadata,
	AlgoliaMigrationCapabilities,
	CreateMigrationImportJobRequest,
	ListMigrationSourceIndexesRequest,
	PublicAlgoliaImportError,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage,
	SourceProvider,
	VerifySourceMigrationResponse
} from '../../../src/lib/api/types';

const JOB_ID = 'job_123';
const SOURCE_NAME = 'source_products';
const REGION = 'us-east-1';
const PROVIDER_TOKEN = 'provider-token-stage4';
const TARGET_TOKEN = 'target-token-stage4';
const DOCUMENT_UNAVAILABLE_START = 'data:{availability:{available:false';
const DOCUMENT_UNAVAILABLE_END = ',recentImports:{page:null,error:null}}';

const SOURCE_PROVIDER_LABELS = {
	algolia: 'Algolia',
	meilisearch: 'Meilisearch',
	typesense: 'Typesense'
} satisfies Record<SourceProvider, string>;

const MOCKED_ENGINE_PREVIEW_SUPPORT = {
	algolia: true,
	meilisearch: true,
	typesense: false
} satisfies Record<SourceProvider, boolean>;

// Mirrors `engine_supports_source_verification` in
// infra/api/src/routes/migration/capabilities.rs, which owns the Algolia-only rule and
// keeps its match exhaustive so a new provider cannot silently inherit verification.
// Publishing verify:true for every provider here would mock a state the API cannot
// produce, and the console would render the Algolia credential form for a Meilisearch or
// Typesense job. Move this together with the Rust owner if verification widens.
const MOCKED_ENGINE_VERIFY_SUPPORT = {
	algolia: true,
	meilisearch: false,
	typesense: false
} satisfies Record<SourceProvider, boolean>;

const SOURCE_PROVIDER_CREDENTIALS = {
	algolia: {
		appId: 'algolia_app_id_canary_stage4',
		apiKey: 'algolia_api_key_canary_stage4'
	},
	meilisearch: {
		host: 'https://meilisearch-host-canary-stage4.example.test',
		apiKey: 'meilisearch_api_key_canary_stage4'
	},
	typesense: {
		host: 'https://typesense-host-canary-stage4.example.test',
		apiKey: 'typesense_api_key_canary_stage4'
	}
} satisfies Record<SourceProvider, { apiKey: string; appId?: string; host?: string }>;

type JobScenario =
	| 'progression'
	| 'cancel'
	| 'cutover_completed'
	| 'invalid_credentials'
	| 'source_provider_unsupported'
	| 'warning_detail';

type CutoverVerificationScenario =
	| 'idle'
	| 'running'
	| 'high_agreement'
	| 'differences'
	| 'invalid_credentials'
	| 'missing_source_permission'
	| 'source_not_found'
	| 'backend_unavailable'
	| 'internal';

export const WARNING_DETAIL_GROUPS = WARNING_GROUPS;
export const CUTOVER_VERIFICATION_INPUT = {
	appId: SOURCE_PROVIDER_CREDENTIALS.algolia.appId,
	apiKey: SOURCE_PROVIDER_CREDENTIALS.algolia.apiKey,
	queries: ['running shoes', 'boots'],
	resultLimit: 3
} as const;

export const CUTOVER_HIGH_AGREEMENT_REPORT = {
	sourceIndex: SOURCE_NAME,
	destinationIndex: SOURCE_NAME,
	resultLimit: 3,
	queries: [
		{
			query: 'running shoes',
			overlapCount: 3,
			sourceOnly: [],
			destinationOnly: [],
			hits: [
				{ objectID: 's1', sourceRank: 1, destinationRank: 1, rankDelta: 0 },
				{ objectID: 's2', sourceRank: 2, destinationRank: 2, rankDelta: 0 },
				{ objectID: 's3', sourceRank: 3, destinationRank: 3, rankDelta: 0 }
			]
		}
	]
} satisfies VerifySourceMigrationResponse;

export const CUTOVER_DIFFERENCES_REPORT = {
	sourceIndex: SOURCE_NAME,
	destinationIndex: SOURCE_NAME,
	resultLimit: CUTOVER_VERIFICATION_INPUT.resultLimit,
	queries: [
		{
			query: 'running shoes',
			overlapCount: 2,
			sourceOnly: ['s1'],
			destinationOnly: ['z9'],
			hits: [
				{ objectID: 's2', sourceRank: 2, destinationRank: 1, rankDelta: -1 },
				{ objectID: 's3', sourceRank: 3, destinationRank: 2, rankDelta: -1 }
			]
		},
		{
			query: 'boots',
			overlapCount: 1,
			sourceOnly: ['b2'],
			destinationOnly: [],
			hits: [{ objectID: 'b1', sourceRank: 1, destinationRank: 1, rankDelta: 0 }]
		}
	]
} satisfies VerifySourceMigrationResponse;

export const CUTOVER_VERIFICATION_ERRORS = {
	invalid_credentials: {
		code: 'invalid_credentials',
		message: 'redacted invalid credentials fixture'
	},
	missing_source_permission: {
		code: 'missing_source_permission',
		message: 'redacted missing source permission fixture'
	},
	source_not_found: {
		code: 'source_not_found',
		message: 'redacted source not found fixture'
	},
	backend_unavailable: {
		code: 'backend_unavailable',
		message: 'redacted backend unavailable fixture'
	},
	internal: {
		code: 'internal',
		message: 'redacted internal engine failure fixture'
	}
} satisfies Record<
	Exclude<CutoverVerificationScenario, 'idle' | 'running' | 'high_agreement' | 'differences'>,
	{ code: PublicAlgoliaImportError['code']; message: string }
>;

export type MigrationConsoleFlowFixture = {
	sourceProvider: SourceProvider;
	providerLabel: string;
	sourceIdentity: string;
	appId: string;
	host: string;
	apiKey: string;
	jobId: string;
	sourceName: string;
	counts: {
		availability: number;
		providerEligibility: number;
		listSourceIndexes: number;
		checkDestinationEligibility: number;
		previewImport: number;
		createImportJob: number;
		verify: number;
		cancel: number;
		migrateDataRewrites: number;
		documentRewrites: number;
		jobDataRewrites: number;
	};
	createIdempotencyKeys: string[];
	credentialRequestBodies: string[];
	actionPayloads: Array<{ action: string; payload: unknown }>;
	jobNavigationSearchParams: string[];
	publicResponseBodies: string[];
	completePendingVerification: () => void;
};

type FixtureOptions = {
	sourceProvider?: SourceProvider;
	jobScenario?: JobScenario;
	cutoverVerificationScenario?: CutoverVerificationScenario;
	publishedVerifyCapability?: boolean;
};

function jobCapabilitiesFor(
	sourceProvider: SourceProvider,
	publishedVerifyCapability: boolean
): AlgoliaMigrationCapabilities {
	return {
		cancel: true,
		resume: false,
		replace: true,
		preview: MOCKED_ENGINE_PREVIEW_SUPPORT[sourceProvider],
		verify: publishedVerifyCapability
	};
}

const sourceIndex = {
	name: SOURCE_NAME,
	entries: 1234,
	dataSize: 2048,
	fileSize: 2048,
	updatedAt: '2026-07-24T23:59:43Z',
	lastBuildTimeS: 17,
	pendingTask: false,
	primary: null,
	replicas: []
} satisfies AlgoliaIndexMetadata;

function providerEligibilityFor(
	sourceProvider: SourceProvider
): AlgoliaDestinationEligibilityResponse {
	return {
		phase: 'provider',
		mode: 'create',
		provider: 'aws',
		target: { kind: 'create', region: REGION },
		eligibilityToken: `${sourceProvider}-${PROVIDER_TOKEN}`,
		expiresAt: '2099-07-18T10:15:00Z'
	};
}

function targetEligibilityFor(
	sourceProvider: SourceProvider
): AlgoliaDestinationEligibilityResponse {
	return {
		phase: 'target',
		mode: 'create',
		provider: 'aws',
		target: { kind: 'create', region: REGION, name: SOURCE_NAME },
		eligibilityToken: `${sourceProvider}-${TARGET_TOKEN}`,
		expiresAt: '2099-07-18T10:20:00Z'
	};
}

function availabilityFor(sourceProvider: SourceProvider) {
	return {
		...availableAvailability,
		capabilities: {
			...availableAvailability.capabilities,
			preview: MOCKED_ENGINE_PREVIEW_SUPPORT[sourceProvider]
		}
	};
}

export async function installMigrationConsoleFlowFixture(
	page: Page,
	options: FixtureOptions = {}
): Promise<MigrationConsoleFlowFixture> {
	const sourceProvider = options.sourceProvider ?? 'algolia';
	const credentials = SOURCE_PROVIDER_CREDENTIALS[sourceProvider];
	const state: MigrationConsoleFlowFixture = {
		sourceProvider,
		providerLabel: SOURCE_PROVIDER_LABELS[sourceProvider],
		sourceIdentity: 'appId' in credentials ? credentials.appId : credentials.host,
		appId: 'appId' in credentials ? credentials.appId : '',
		host: 'host' in credentials ? credentials.host : '',
		apiKey: credentials.apiKey,
		jobId: JOB_ID,
		sourceName: SOURCE_NAME,
		counts: {
			availability: 0,
			providerEligibility: 0,
			listSourceIndexes: 0,
			checkDestinationEligibility: 0,
			previewImport: 0,
			createImportJob: 0,
			verify: 0,
			cancel: 0,
			migrateDataRewrites: 0,
			documentRewrites: 0,
			jobDataRewrites: 0
		},
		createIdempotencyKeys: [],
		credentialRequestBodies: [],
		actionPayloads: [],
		jobNavigationSearchParams: [],
		publicResponseBodies: [],
		completePendingVerification: () => {
			throw new Error('no cutover verification request is pending');
		}
	};
	const scenario = options.jobScenario ?? 'progression';
	const cutoverVerificationScenario = options.cutoverVerificationScenario ?? 'idle';
	// Default to what the engine actually supports for this provider; an explicit option
	// still lets a spec force the published capability to prove the fail-closed path.
	const publishedVerifyCapability =
		options.publishedVerifyCapability ?? MOCKED_ENGINE_VERIFY_SUPPORT[sourceProvider];
	let progressionIndex = 0;
	let cancelled = false;

	await page.route('**/console/migrate', async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		await fulfillMigrateDocument(route, state, { scenario });
	});

	await page.route('**/console/migrate/__data.json**', async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		await fulfillMigrateData(route, state, { scenario });
	});

	await page.route(`**/console/migrate/${JOB_ID}/__data.json**`, async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		state.jobNavigationSearchParams.push(new URL(route.request().url()).search);
		const job =
			scenario === 'cutover_completed'
				? importJob(state, {
						status: 'completed',
						terminalOutcomeObserved: true,
						publicationDisposition: 'promoted'
					})
				: scenario === 'invalid_credentials'
					? importJob(state, { status: 'failed', error: { code: 'invalid_credentials' } })
					: scenario === 'source_provider_unsupported'
						? importJob(state, {
								status: 'failed',
								error: { code: 'source_provider_unsupported' }
							})
						: scenario === 'warning_detail'
							? warningDetailJob(state)
							: cancelled
								? importJob(state, { status: 'cancelled', publicationDisposition: 'unchanged' })
								: nextProgressionJob(state, progressionIndex++);
		await fulfillJobData(route, state, job, { publishedVerifyCapability });
	});

	await page.route('**/console/migrate**', async (route) => {
		const request = route.request();
		if (request.method() !== 'POST') {
			await route.fallback();
			return;
		}
		const url = request.url();
		if (url.includes('?/providerEligibility')) {
			state.counts.providerEligibility += 1;
			const payload = actionPayload(request.postData() ?? '', 'providerEligibility');
			state.actionPayloads.push({ action: 'providerEligibility', payload });
			expect(payload).toEqual({ source_provider: sourceProvider, region: REGION });
			await fulfillAction(route, { providerEligibility: providerEligibilityFor(sourceProvider) });
			return;
		}
		if (url.includes('?/availability')) {
			state.counts.availability += 1;
			const payload = actionPayload(request.postData() ?? '', 'availability');
			state.actionPayloads.push({ action: 'availability', payload });
			expect(payload).toEqual({ source_provider: sourceProvider });
			await fulfillAction(route, { availability: availabilityFor(sourceProvider) });
			return;
		}
		if (url.includes('?/listSourceIndexes')) {
			state.counts.listSourceIndexes += 1;
			const rawBody = request.postData() ?? '';
			state.credentialRequestBodies.push(rawBody);
			const payload = actionPayload(
				rawBody,
				'listSourceIndexes'
			) as ListMigrationSourceIndexesRequest & {
				source_provider?: SourceProvider;
			};
			state.actionPayloads.push({ action: 'listSourceIndexes', payload });
			expect(payload).toEqual(expectedSourceListPayload(sourceProvider));
			await fulfillAction(route, {
				sourceIndexes: { items: [sourceIndex], nextCursor: null }
			});
			return;
		}
		if (url.includes('?/checkDestinationEligibility')) {
			state.counts.checkDestinationEligibility += 1;
			const payload = actionPayload(
				request.postData() ?? '',
				'checkDestinationEligibility'
			) as AlgoliaDestinationEligibilityRequest & { source_provider?: SourceProvider };
			state.actionPayloads.push({ action: 'checkDestinationEligibility', payload });
			expect(payload).toEqual({
				source_provider: sourceProvider,
				phase: 'target',
				mode: 'create',
				target: { region: REGION, name: SOURCE_NAME },
				eligibilityToken: `${sourceProvider}-${PROVIDER_TOKEN}`
			});
			await fulfillAction(route, { targetEligibility: targetEligibilityFor(sourceProvider) });
			return;
		}
		if (url.includes('?/previewImport')) {
			state.counts.previewImport += 1;
			const rawBody = request.postData() ?? '';
			state.credentialRequestBodies.push(rawBody);
			const payload = actionPayload(rawBody, 'previewImport');
			state.actionPayloads.push({ action: 'previewImport', payload });
			expect(sourceProvider).not.toBe('typesense');
			expect(payload).toEqual(expectedPreviewPayload(sourceProvider));
			await fulfillAction(route, {
				preview: {
					sourceCounts: { indexes: 3, records: 42 },
					report: {
						summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
						entries: [],
						reportDigest: 'sha256:mocked-browser-preview'
					}
				}
			});
			return;
		}
		if (url.includes('?/createImportJob')) {
			state.counts.createImportJob += 1;
			const rawBody = request.postData() ?? '';
			state.credentialRequestBodies.push(rawBody);
			const form = parseMultipartForm(rawBody);
			const idempotencyKey = form.idempotencyKey?.trim() ?? '';
			expect(idempotencyKey).not.toBe('');
			state.createIdempotencyKeys.push(idempotencyKey);
			const payload = actionPayload(
				rawBody,
				'createImportJob'
			) as CreateMigrationImportJobRequest & {
				source_provider?: SourceProvider;
			};
			state.actionPayloads.push({ action: 'createImportJob', payload });
			expect(payload).toEqual(expectedCreatePayload(sourceProvider));
			await fulfillAction(route, { job: importJob(state, { status: 'queued' }) });
			return;
		}
		if (url.includes('?/verify')) {
			state.counts.verify += 1;
			const rawBody = request.postData() ?? '';
			state.credentialRequestBodies.push(rawBody);
			const payload = verificationPayload(rawBody);
			state.actionPayloads.push({ action: 'verify', payload });
			expect(payload).toEqual(expectedVerificationPayload(sourceProvider));
			if (cutoverVerificationScenario === 'running') {
				await new Promise<void>((resolve) => {
					state.completePendingVerification = resolve;
				});
			}
			const verificationError =
				cutoverVerificationScenario in CUTOVER_VERIFICATION_ERRORS
					? CUTOVER_VERIFICATION_ERRORS[
							cutoverVerificationScenario as keyof typeof CUTOVER_VERIFICATION_ERRORS
						]
					: null;
			if (verificationError !== null) {
				await fulfillActionFailure(route, state, verificationError);
				return;
			}
			await fulfillAction(
				route,
				{
					report:
						cutoverVerificationScenario === 'differences'
							? CUTOVER_DIFFERENCES_REPORT
							: CUTOVER_HIGH_AGREEMENT_REPORT
				},
				state
			);
			return;
		}
		await route.fallback();
	});

	await page.route(`**/console/migrate/${JOB_ID}**`, async (route) => {
		const request = route.request();
		if (request.method() !== 'POST' || !request.url().includes('?/cancel')) {
			await route.fallback();
			return;
		}
		state.counts.cancel += 1;
		cancelled = true;
		await fulfillAction(route, {
			job: importJob(state, { status: 'cancelled', publicationDisposition: 'unchanged' })
		});
	});

	return state;
}

export async function assertMigrationFixtureSatisfied(
	state: MigrationConsoleFlowFixture,
	options: {
		checked?: boolean;
		create?: boolean;
		cancel?: boolean;
		jobLoads?: boolean | number;
		preview?: boolean;
		verify?: boolean;
	} = {}
): Promise<void> {
	expect(state.counts.documentRewrites).toBe(1);
	expect(state.counts.migrateDataRewrites).toBe(0);
	expect(state.counts.availability).toBe(1);
	expect(actionPayloads(state, 'availability')).toEqual([
		{ source_provider: state.sourceProvider }
	]);
	expect(state.counts.providerEligibility).toBe(1);
	expect(actionPayloads(state, 'providerEligibility')).toEqual([
		{ source_provider: state.sourceProvider, region: REGION }
	]);
	if (options.checked || options.create) {
		expect(state.counts.listSourceIndexes).toBe(1);
		expect(state.counts.checkDestinationEligibility).toBe(1);
		expect(actionPayloads(state, 'listSourceIndexes')).toEqual([
			expectedSourceListPayload(state.sourceProvider)
		]);
		expect(actionPayloads(state, 'checkDestinationEligibility')).toEqual([
			{
				source_provider: state.sourceProvider,
				phase: 'target',
				mode: 'create',
				target: { region: REGION, name: SOURCE_NAME },
				eligibilityToken: `${state.sourceProvider}-${PROVIDER_TOKEN}`
			}
		]);
	} else {
		expect(state.counts.listSourceIndexes).toBe(0);
		expect(state.counts.checkDestinationEligibility).toBe(0);
	}
	if (options.create) {
		expect(state.counts.createImportJob).toBe(1);
		expect(state.createIdempotencyKeys).toHaveLength(1);
		expect(new Set(state.createIdempotencyKeys).size).toBe(1);
		expect(actionPayloads(state, 'createImportJob')).toEqual([
			expectedCreatePayload(state.sourceProvider)
		]);
	} else {
		expect(state.counts.createImportJob).toBe(0);
		expect(state.createIdempotencyKeys).toHaveLength(0);
	}
	if (options.preview) {
		expect(state.counts.previewImport).toBe(1);
		expect(actionPayloads(state, 'previewImport')).toEqual([
			expectedPreviewPayload(state.sourceProvider)
		]);
	} else {
		expect(state.counts.previewImport).toBe(0);
	}
	if (options.verify) {
		expect(state.counts.verify).toBe(1);
		expect(actionPayloads(state, 'verify')).toEqual([
			expectedVerificationPayload(state.sourceProvider)
		]);
	} else {
		expect(state.counts.verify).toBe(0);
	}
	if (options.cancel) {
		expect(state.counts.cancel).toBe(1);
	}
	if (options.jobLoads) {
		const expectedJobLoads =
			typeof options.jobLoads === 'number'
				? options.jobLoads
				: options.create
					? 4
					: options.cancel
						? 2
						: 1;
		expect(state.counts.jobDataRewrites).toBe(expectedJobLoads);
		expect(state.jobNavigationSearchParams).toHaveLength(expectedJobLoads);
		for (const searchParams of state.jobNavigationSearchParams) {
			expect(new URLSearchParams(searchParams).get('source_provider')).toBe(state.sourceProvider);
		}
	}
	for (const body of state.credentialRequestBodies) {
		expect(body).toContain(state.apiKey);
		if (state.sourceProvider === 'algolia') {
			expect(body).toContain(state.appId);
			expect(body).not.toContain('host');
		} else {
			expect(body).toContain(state.host);
			expect(body).not.toContain('appId');
		}
	}
	for (const body of state.publicResponseBodies) {
		expect(body).not.toContain(state.apiKey);
		if (state.appId !== '') {
			expect(body).not.toContain(state.appId);
		}
		if (state.host !== '') {
			expect(body).not.toContain(state.host);
		}
	}
}

function actionPayloads(state: MigrationConsoleFlowFixture, action: string): unknown[] {
	return state.actionPayloads
		.filter((entry) => entry.action === action)
		.map((entry) => entry.payload);
}

function expectedSourceListPayload(sourceProvider: SourceProvider): {
	source_provider: SourceProvider;
	apiKey: string;
	appId?: string;
	host?: string;
} {
	const credentials = SOURCE_PROVIDER_CREDENTIALS[sourceProvider];
	return sourceProvider === 'algolia'
		? {
				source_provider: sourceProvider,
				appId: 'appId' in credentials ? credentials.appId : '',
				apiKey: credentials.apiKey
			}
		: {
				source_provider: sourceProvider,
				host: 'host' in credentials ? credentials.host : '',
				apiKey: credentials.apiKey
			};
}

function expectedCreatePayload(sourceProvider: SourceProvider): {
	mode: 'create';
	source_provider: SourceProvider;
	apiKey: string;
	sourceName: string;
	target: { eligibilityToken: string };
	appId?: string;
	host?: string;
} {
	const credentials = SOURCE_PROVIDER_CREDENTIALS[sourceProvider];
	return sourceProvider === 'algolia'
		? {
				source_provider: sourceProvider,
				mode: 'create',
				appId: 'appId' in credentials ? credentials.appId : '',
				apiKey: credentials.apiKey,
				sourceName: SOURCE_NAME,
				target: { eligibilityToken: `${sourceProvider}-${TARGET_TOKEN}` }
			}
		: {
				source_provider: sourceProvider,
				mode: 'create',
				host: 'host' in credentials ? credentials.host : '',
				apiKey: credentials.apiKey,
				sourceName: SOURCE_NAME,
				target: { eligibilityToken: `${sourceProvider}-${TARGET_TOKEN}` }
			};
}

function expectedPreviewPayload(sourceProvider: SourceProvider): Record<string, unknown> {
	const credentials = SOURCE_PROVIDER_CREDENTIALS[sourceProvider];
	if (sourceProvider === 'algolia') {
		return {
			source_provider: sourceProvider,
			appId: 'appId' in credentials ? credentials.appId : '',
			apiKey: credentials.apiKey,
			sourceIndex: SOURCE_NAME,
			targetIndex: SOURCE_NAME,
			overwrite: false
		};
	}
	return {
		source_provider: sourceProvider,
		endpoint: 'host' in credentials ? credentials.host : '',
		apiKey: credentials.apiKey,
		sourceIndex: SOURCE_NAME,
		targetIndex: SOURCE_NAME,
		overwrite: false
	};
}

function expectedVerificationPayload(sourceProvider: SourceProvider): Record<string, string> {
	return {
		source_provider: sourceProvider,
		appId: CUTOVER_VERIFICATION_INPUT.appId,
		apiKey: CUTOVER_VERIFICATION_INPUT.apiKey,
		queries: CUTOVER_VERIFICATION_INPUT.queries.join('\n'),
		resultLimit: String(CUTOVER_VERIFICATION_INPUT.resultLimit)
	};
}

function recentImportsPage(
	state: MigrationConsoleFlowFixture,
	job: PublicAlgoliaImportJob = importJob(state)
): PublicAlgoliaImportJobPage {
	return { jobs: [job], nextCursor: null };
}

function migratePayload(
	state: MigrationConsoleFlowFixture,
	options: { scenario?: JobScenario } = {}
) {
	return {
		availability: availableAvailability,
		recentImports: {
			page: recentImportsPage(state, retainedListJob(state, options.scenario)),
			error: null
		}
	};
}

async function fulfillMigrateDocument(
	route: Route,
	state: MigrationConsoleFlowFixture,
	options: { scenario?: JobScenario } = {}
): Promise<void> {
	const response = await route.fetch();
	const body = await response.text();
	const replacement = `data:${uneval(migratePayload(state, options))}`;
	const rewritten = rewriteUnavailableDocumentPayload(body, replacement);
	state.counts.documentRewrites += 1;
	state.publicResponseBodies.push(rewritten);
	await route.fulfill({ response, body: rewritten });
}

async function fulfillMigrateData(
	route: Route,
	state: MigrationConsoleFlowFixture,
	options: { scenario?: JobScenario } = {}
): Promise<void> {
	const response = await route.fetch();
	const payload = (await response.json()) as {
		type: 'data';
		nodes: Array<null | { type: 'data'; data: unknown; uses: Record<string, unknown> }>;
	};
	const pageNode = payload.nodes.find(
		(node) =>
			node?.type === 'data' &&
			JSON.stringify(node.data).includes('temporarily_unavailable') &&
			JSON.stringify(node.data).includes('recentImports')
	);
	if (!pageNode) {
		throw new Error('migration __data payload marker was not rewritten');
	}
	pageNode.data = JSON.parse(stringify(migratePayload(state, options)));
	state.counts.migrateDataRewrites += 1;
	const body = JSON.stringify(payload);
	state.publicResponseBodies.push(body);
	await route.fulfill({
		status: response.status(),
		headers: response.headers(),
		body
	});
}

async function fulfillJobData(
	route: Route,
	state: MigrationConsoleFlowFixture,
	job: PublicAlgoliaImportJob,
	options: { publishedVerifyCapability: boolean }
): Promise<void> {
	const payload = {
		type: 'data',
		nodes: [
			null,
			null,
			{
				type: 'data',
				data: JSON.parse(
					stringify({
						job,
						capabilities: jobCapabilitiesFor(
							state.sourceProvider,
							options.publishedVerifyCapability
						)
					})
				),
				uses: { params: ['jobId'] }
			}
		]
	};
	state.counts.jobDataRewrites += 1;
	const body = JSON.stringify(payload);
	state.publicResponseBodies.push(body);
	await route.fulfill({
		status: 200,
		contentType: 'application/json',
		body
	});
}

async function fulfillAction(
	route: Route,
	data: Record<string, unknown>,
	state?: MigrationConsoleFlowFixture
): Promise<void> {
	const body = JSON.stringify({
		type: 'success',
		status: 200,
		data: stringify(data)
	});
	if (state) {
		state.publicResponseBodies.push(body);
	}
	await route.fulfill({
		status: 200,
		contentType: 'application/json',
		body
	});
}

async function fulfillActionFailure(
	route: Route,
	state: MigrationConsoleFlowFixture,
	data: Record<string, unknown>
): Promise<void> {
	const body = JSON.stringify({
		type: 'failure',
		status: 400,
		data: stringify(data)
	});
	state.publicResponseBodies.push(body);
	await route.fulfill({
		status: 200,
		contentType: 'application/json',
		body
	});
}

function rewriteUnavailableDocumentPayload(body: string, replacement: string): string {
	const start = body.indexOf(DOCUMENT_UNAVAILABLE_START);
	if (start === -1) {
		throw new Error('migration document payload marker start was not found');
	}
	const end = body.indexOf(DOCUMENT_UNAVAILABLE_END, start);
	if (end === -1) {
		throw new Error('migration document payload marker end was not found');
	}
	return `${body.slice(0, start)}${replacement}${body.slice(end + DOCUMENT_UNAVAILABLE_END.length)}`;
}

function actionPayload(body: string, actionName: string): unknown {
	const payload = parseMultipartForm(body).payload ?? '';
	expect(payload, `${actionName} multipart payload`).not.toBe('');
	return JSON.parse(payload) as unknown;
}

function verificationPayload(body: string): Record<string, string> {
	const form = parseMultipartForm(body);
	return {
		source_provider: form.source_provider ?? '',
		appId: form.appId ?? '',
		apiKey: form.apiKey ?? '',
		queries: form.queries ?? '',
		resultLimit: form.resultLimit ?? ''
	};
}

function nextProgressionJob(
	state: MigrationConsoleFlowFixture,
	index: number
): PublicAlgoliaImportJob {
	const statuses = ['queued', 'copying_documents', 'verifying', 'completed'] as const;
	return importJob(state, {
		status: statuses[Math.min(index, statuses.length - 1)],
		terminalOutcomeObserved: index >= statuses.length - 1,
		publicationDisposition: index >= statuses.length - 1 ? 'promoted' : 'not_started'
	});
}

function retainedListJob(
	state: MigrationConsoleFlowFixture,
	scenario: JobScenario = 'progression'
): PublicAlgoliaImportJob {
	if (scenario === 'invalid_credentials') {
		return importJob(state, { status: 'failed', error: { code: 'invalid_credentials' } });
	}
	if (scenario === 'source_provider_unsupported') {
		return importJob(state, {
			status: 'failed',
			error: { code: 'source_provider_unsupported' }
		});
	}
	if (scenario === 'warning_detail') {
		return warningDetailJob(state);
	}
	if (scenario === 'cutover_completed') {
		return importJob(state, {
			status: 'completed',
			terminalOutcomeObserved: true,
			publicationDisposition: 'promoted'
		});
	}
	return importJob(state);
}

function warningDetailJob(state: MigrationConsoleFlowFixture): PublicAlgoliaImportJob {
	return importJob(state, {
		status: 'completed_with_warnings',
		terminalOutcomeObserved: true,
		publicationDisposition: 'promoted',
		warnings: publicWarnings(WARNING_DETAIL_GROUPS)
	});
}

function importJob(
	state: MigrationConsoleFlowFixture,
	overrides: Partial<PublicAlgoliaImportJob> & { error?: PublicAlgoliaImportError | null } = {}
): PublicAlgoliaImportJob {
	return {
		id: JOB_ID,
		status: 'copying_documents',
		mode: 'create',
		sourceProvider: state.sourceProvider,
		destination: { kind: 'create', target: SOURCE_NAME, region: REGION },
		source: { name: SOURCE_NAME },
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
		terminalOutcomeObserved: false,
		warnings: [],
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

function parseMultipartForm(body: string): Record<string, string> {
	const values: Record<string, string> = {};
	const normalized = body.replace(/\r\n/g, '\n');
	for (const part of normalized.split(/^--[-A-Za-z0-9]+(?:--)?$/m)) {
		const name = part.match(/name="([^"]+)"/)?.[1];
		if (!name) continue;
		const value = part.split('\n\n').slice(1).join('\n\n').trimEnd();
		values[name] = value.replace(/\n$/, '');
	}
	return values;
}
