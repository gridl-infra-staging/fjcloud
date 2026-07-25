import type { Page, Route } from '@playwright/test';
import { expect } from '../../fixtures/fixtures';
import { stringify, uneval } from 'devalue';
import { availableAvailability } from '../../../src/lib/components/migration/migration_test_fixtures';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaIndexMetadata,
	AlgoliaMigrationCapabilities,
	CreateAlgoliaImportJobRequest,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage
} from '../../../src/lib/api/types';

const APP_ID_CANARY = 'algolia_app_id_canary_stage4';
const API_KEY_CANARY = 'algolia_api_key_canary_stage4';
const JOB_ID = 'job_123';
const SOURCE_NAME = 'source_products';
const REGION = 'us-east-1';
const PROVIDER_TOKEN = 'provider-token-stage4';
const TARGET_TOKEN = 'target-token-stage4';
const DOCUMENT_UNAVAILABLE_MARKER =
	'data:{availability:{available:false,message:"Algolia migration is temporarily unavailable while we replace the importer.",capabilities:{cancel:false,resume:false,replace:false},reason:"temporarily_unavailable"},recentImports:{page:null,error:null}}';

type JobScenario = 'progression' | 'cancel' | 'invalid_credentials';

export type MigrationConsoleFlowFixture = {
	appId: string;
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
};

type FixtureOptions = {
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

const providerEligibility = {
	phase: 'provider',
	mode: 'create',
	provider: 'aws',
	target: { kind: 'create', region: REGION },
	eligibilityToken: PROVIDER_TOKEN,
	expiresAt: '2099-07-18T10:15:00Z'
} satisfies AlgoliaDestinationEligibilityResponse;

const targetEligibility = {
	phase: 'target',
	mode: 'create',
	provider: 'aws',
	target: { kind: 'create', region: REGION, name: SOURCE_NAME },
	eligibilityToken: TARGET_TOKEN,
	expiresAt: '2099-07-18T10:20:00Z'
} satisfies AlgoliaDestinationEligibilityResponse;

export async function installMigrationConsoleFlowFixture(
	page: Page,
	options: FixtureOptions = {}
): Promise<MigrationConsoleFlowFixture> {
	const state: MigrationConsoleFlowFixture = {
		appId: APP_ID_CANARY,
		apiKey: API_KEY_CANARY,
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
		credentialRequestBodies: []
	};
	const scenario = options.jobScenario ?? 'progression';
	let progressionIndex = 0;
	let cancelled = false;

	await page.route('**/console/migrate', async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		await fulfillMigrateDocument(route, state);
	});

	await page.route('**/console/migrate/__data.json**', async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		await fulfillMigrateData(route, state);
	});

	await page.route(`**/console/migrate/${JOB_ID}/__data.json**`, async (route) => {
		if (route.request().method() !== 'GET') {
			await route.fallback();
			return;
		}
		const job =
			scenario === 'invalid_credentials'
				? importJob({ status: 'failed', error: { code: 'invalid_credentials' } })
				: cancelled
					? importJob({ status: 'cancelled', publicationDisposition: 'unchanged' })
					: nextProgressionJob(progressionIndex++);
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
			const payload = JSON.parse(parseMultipartForm(request.postData() ?? '').payload ?? '{}') as {
				region?: string;
			};
			expect(payload).toEqual({ region: REGION });
			await fulfillAction(route, { providerEligibility });
			return;
		}
		if (url.includes('?/listSourceIndexes')) {
			state.counts.listSourceIndexes += 1;
			const rawBody = request.postData() ?? '';
			state.credentialRequestBodies.push(rawBody);
			const payload = JSON.parse(parseMultipartForm(rawBody).payload ?? '{}') as {
				appId?: string;
				apiKey?: string;
				cursor?: string;
			};
			expect(payload).toEqual({ appId: APP_ID_CANARY, apiKey: API_KEY_CANARY });
			await fulfillAction(route, {
				sourceIndexes: { items: [sourceIndex], nextCursor: null }
			});
			return;
		}
		if (url.includes('?/checkDestinationEligibility')) {
			state.counts.checkDestinationEligibility += 1;
			const payload = JSON.parse(
				parseMultipartForm(request.postData() ?? '').payload ?? '{}'
			) as AlgoliaDestinationEligibilityRequest;
			expect(payload).toEqual({
				phase: 'target',
				mode: 'create',
				target: { region: REGION, name: SOURCE_NAME },
				eligibilityToken: PROVIDER_TOKEN
			});
			await fulfillAction(route, { targetEligibility });
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
			const payload = JSON.parse(form.payload ?? '{}') as CreateAlgoliaImportJobRequest;
			expect(payload).toEqual({
				mode: 'create',
				appId: APP_ID_CANARY,
				apiKey: API_KEY_CANARY,
				sourceName: SOURCE_NAME,
				target: { eligibilityToken: TARGET_TOKEN }
			});
			await fulfillAction(route, { job: importJob({ status: 'queued' }) });
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
			job: importJob({ status: 'cancelled', publicationDisposition: 'unchanged' })
		});
	});

	return state;
}

export async function assertMigrationFixtureSatisfied(
	state: MigrationConsoleFlowFixture,
	options: { create?: boolean; cancel?: boolean; jobLoads?: boolean } = {}
): Promise<void> {
	expect(state.counts.documentRewrites).toBeGreaterThan(0);
	if (options.create) {
		expect(state.counts.createImportJob).toBe(1);
		expect(state.createIdempotencyKeys).toHaveLength(1);
	}
	if (options.cancel) {
		expect(state.counts.cancel).toBe(1);
	}
	if (options.jobLoads) {
		expect(state.counts.jobDataRewrites).toBeGreaterThan(0);
	}
	for (const body of state.credentialRequestBodies) {
		expect(body).toContain(APP_ID_CANARY);
		expect(body).toContain(API_KEY_CANARY);
	}
}

function recentImportsPage(job: PublicAlgoliaImportJob = importJob()): PublicAlgoliaImportJobPage {
	return { jobs: [job], nextCursor: null };
}

function migratePayload() {
	return {
		availability: availableAvailability,
		recentImports: { page: recentImportsPage(), error: null }
	};
}

async function fulfillMigrateDocument(
	route: Route,
	state: MigrationConsoleFlowFixture
): Promise<void> {
	const response = await route.fetch();
	const body = await response.text();
	const replacement = `data:${uneval(migratePayload())}`;
	const rewritten = body.replace(DOCUMENT_UNAVAILABLE_MARKER, replacement);
	if (rewritten === body) {
		throw new Error('migration document payload marker was not rewritten');
	}
	state.counts.documentRewrites += 1;
	await route.fulfill({ response, body: rewritten });
}

async function fulfillMigrateData(route: Route, state: MigrationConsoleFlowFixture): Promise<void> {
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
	pageNode.data = JSON.parse(stringify(migratePayload()));
	state.counts.migrateDataRewrites += 1;
	await route.fulfill({
		status: response.status(),
		headers: response.headers(),
		body: JSON.stringify(payload)
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
	await route.fulfill({
		status: 200,
		contentType: 'application/json',
		body: JSON.stringify(payload)
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

function nextProgressionJob(index: number): PublicAlgoliaImportJob {
	const statuses = ['queued', 'copying_documents', 'verifying', 'completed'] as const;
	return importJob({
		status: statuses[Math.min(index, statuses.length - 1)],
		publicationDisposition: index >= statuses.length - 1 ? 'promoted' : 'not_started'
	});
}

function importJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: JOB_ID,
		status: 'copying_documents',
		mode: 'create',
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
