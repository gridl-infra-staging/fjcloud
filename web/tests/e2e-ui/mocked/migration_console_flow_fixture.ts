import type { Page, Route } from '@playwright/test';
import { expect } from '../../fixtures/fixtures';
import { stringify, uneval } from 'devalue';
import {
	availableAvailability,
	publicWarnings,
	WARNING_GROUPS
} from '../../../src/lib/components/migration/migration_test_fixtures';
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
	SourceProvider
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
	| 'invalid_credentials'
	| 'source_provider_unsupported'
	| 'warning_detail';

export const WARNING_DETAIL_GROUPS = WARNING_GROUPS;

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
		providerEligibility: number;
		listSourceIndexes: number;
		checkDestinationEligibility: number;
		createImportJob: number;
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
};

type FixtureOptions = {
	sourceProvider?: SourceProvider;
	jobScenario?: JobScenario;
};

const runningCapabilities = {
	cancel: true,
	resume: false,
	replace: true
} satisfies AlgoliaMigrationCapabilities;

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
			providerEligibility: 0,
			listSourceIndexes: 0,
			checkDestinationEligibility: 0,
			createImportJob: 0,
			cancel: 0,
			migrateDataRewrites: 0,
			documentRewrites: 0,
			jobDataRewrites: 0
		},
		createIdempotencyKeys: [],
		credentialRequestBodies: [],
		actionPayloads: [],
		jobNavigationSearchParams: [],
		publicResponseBodies: []
	};
	const scenario = options.jobScenario ?? 'progression';
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
			scenario === 'invalid_credentials'
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
		await fulfillJobData(route, state, job);
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
	options: { create?: boolean; cancel?: boolean; jobLoads?: boolean | number } = {}
): Promise<void> {
	expect(state.counts.documentRewrites).toBe(1);
	expect(state.counts.migrateDataRewrites).toBe(0);
	expect(state.counts.providerEligibility).toBe(1);
	expect(actionPayloads(state, 'providerEligibility')).toEqual([
		{ source_provider: state.sourceProvider, region: REGION }
	]);
	if (options.create) {
		expect(state.counts.listSourceIndexes).toBe(1);
		expect(state.counts.checkDestinationEligibility).toBe(1);
		expect(state.counts.createImportJob).toBe(1);
		expect(state.createIdempotencyKeys).toHaveLength(1);
		expect(new Set(state.createIdempotencyKeys).size).toBe(1);
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
		expect(actionPayloads(state, 'createImportJob')).toEqual([
			expectedCreatePayload(state.sourceProvider)
		]);
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
	job: PublicAlgoliaImportJob
): Promise<void> {
	const payload = {
		type: 'data',
		nodes: [
			null,
			null,
			{
				type: 'data',
				data: JSON.parse(stringify({ job, capabilities: runningCapabilities })),
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

async function fulfillAction(route: Route, data: Record<string, unknown>): Promise<void> {
	await route.fulfill({
		status: 200,
		contentType: 'application/json',
		body: JSON.stringify({
			type: 'success',
			status: 200,
			data: stringify(data)
		})
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
