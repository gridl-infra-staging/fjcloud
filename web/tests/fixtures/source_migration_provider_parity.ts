import { randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Page } from '@playwright/test';
import { parseDotenvFile } from '../../playwright.config.contract';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';
import {
	assertEvidenceContainsBundleValues,
	assertUniqueStrings,
	getNumber,
	getObject,
	getString,
	isJsonObject,
	objectArray,
	readJsonObject,
	stringArray,
	type JsonObject
} from './source_migration_expected_bundle';
export type SourceMigrationProviderParityProvider = 'meilisearch' | 'typesense' | 'algolia';

export type SourceMigrationProviderParityExpectation = {
	label: string;
	testId: string;
	expectedText: string | RegExp;
};

export type SourceMigrationProviderParityConnection = {
	hostUrl: string;
	apiKey: string;
	sourceName: string;
	sourceLabel: string;
	destinationName: string;
};

export type SourceMigrationLocalDestinationNames = {
	completed: string;
	cancelled: string;
	sourceChanged: string;
};

type SourceMigrationProviderParityBaseContract = {
	provider: SourceMigrationProviderParityProvider;
	sourceProof: 'local-container' | 'live-probe-owner';
	sourceOwner: string;
	connection: SourceMigrationProviderParityConnection;
	targetNames: readonly string[];
	cleanupSource?: () => Promise<void>;
};

export type SourceMigrationLocalProviderParityContract =
	SourceMigrationProviderParityBaseContract & {
		provider: 'meilisearch' | 'typesense';
		sourceProof: 'local-container';
		destinations: SourceMigrationLocalDestinationNames;
		canaryNames: readonly string[];
		expectations: readonly SourceMigrationProviderParityExpectation[];
		// Every compatibility warning the import renders must carry a code attributed to
		// this provider. ImportJobDetail renders the engine's own `ReportCode` variant
		// verbatim under `migration-warning-code`, so the pattern matches that spelling.
		warningCodePattern: RegExp;
		// Restore before the create case; then deterministically trigger source_changed.
		restoreSourceBeforeMutation: () => Promise<void>;
		mutateSourceAfterEligibility: () => Promise<void>;
		// Leakage guard scans DOM, URL, storage, cookies, and retained __data.json payload.
		assertNoCanaryInBrowserArtifacts: (page: Page) => Promise<void>;
	};

export type SourceMigrationAlgoliaParityContract = SourceMigrationProviderParityBaseContract & {
	provider: 'algolia';
	sourceProof: 'live-probe-owner';
	assertNoCredentialLeakInBrowserArtifacts: (page: Page) => Promise<void>;
};

export type SourceMigrationProviderParityContract =
	| SourceMigrationLocalProviderParityContract
	| SourceMigrationAlgoliaParityContract;

export type SourceMigrationProviderParityFixture = {
	(provider: 'meilisearch' | 'typesense'): Promise<SourceMigrationLocalProviderParityContract>;
	(provider: 'algolia'): Promise<SourceMigrationAlgoliaParityContract>;
};

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const CREDENTIAL_ROOT = path.join(REPO_ROOT, '.local/source-migration/credentials');

export function escapeRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function sourceLabelWithRecordCount(sourceName: string, recordCount: number): string {
	return `${sourceName} ${recordCount} records`;
}

// Producer-native source record count: the source's own reported document count,
// never a re-derived length of the captured document sample. Meilisearch reports it
// as stats `numberOfDocuments` and Typesense as collection `num_documents`; both are
// normalized into `documentCount` by scripts/lib/local_source_provider_evidence.py.
// Reading `documentCount` here keeps the chooser label the same value that flows
// engine -> Rust passthrough -> normalizeHostedSourceIndex (documentCount ?? entries).
export function meilisearchSourceRecordCount(bundle: JsonObject): number {
	return getNumber(getObject(getObject(bundle, 'indexes'), 'configured'), 'documentCount');
}

export function typesenseSourceRecordCount(productCollection: JsonObject): number {
	return getNumber(productCollection, 'documentCount');
}

type AlgoliaCredentials = { appId: string; adminKey: string; origin: string };

export function algoliaOriginForApplicationId(appId: string): string {
	const hostLabel = appId.toLowerCase();
	if (hostLabel.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(hostLabel)) {
		throw new Error('ALGOLIA_APP_ID must be a single DNS host label');
	}
	return `https://${hostLabel}.algolia.net`;
}

function algoliaCredentials(): AlgoliaCredentials {
	const secretPath = process.env.FJCLOUD_SECRET_FILE?.trim()
		? path.resolve(process.env.FJCLOUD_SECRET_FILE)
		: path.join(REPO_ROOT, '.secret/.env.secret');
	const secretEnv = parseDotenvFile(secretPath);
	// The live probe's project-local secret is canonical when present. Ambient values may
	// belong to a different Algolia application and must not shadow the shared Arrange owner.
	const appId = secretEnv.ALGOLIA_APP_ID?.trim() || process.env.ALGOLIA_APP_ID?.trim();
	const adminKey = secretEnv.ALGOLIA_ADMIN_KEY?.trim() || process.env.ALGOLIA_ADMIN_KEY?.trim();
	if (!appId || !adminKey) {
		throw new Error(
			'Algolia provider-neutral browser lifecycle requires ALGOLIA_APP_ID and ALGOLIA_ADMIN_KEY through the live-probe secret owner'
		);
	}
	return { appId, adminKey, origin: algoliaOriginForApplicationId(appId) };
}

async function algoliaRequest(
	credentials: AlgoliaCredentials,
	pathName: string,
	init: RequestInit = {}
): Promise<Response> {
	return fetch(`${credentials.origin}${pathName}`, {
		...init,
		headers: {
			'X-Algolia-Application-Id': credentials.appId,
			'X-Algolia-API-Key': credentials.adminKey,
			'Content-Type': 'application/json',
			...init.headers
		}
	});
}

async function requireAlgoliaTaskId(response: Response, context: string): Promise<number> {
	if (!response.ok) {
		throw new Error(`${context} failed with HTTP ${response.status}`);
	}
	const task = (await response.json()) as { taskID?: number };
	if (typeof task.taskID !== 'number') {
		throw new Error(`${context} did not return taskID`);
	}
	return task.taskID;
}

async function waitForAlgoliaTask(
	credentials: AlgoliaCredentials,
	indexName: string,
	taskId: number
): Promise<void> {
	for (let attempt = 0; attempt < 60; attempt += 1) {
		const response = await algoliaRequest(
			credentials,
			`/1/indexes/${encodeURIComponent(indexName)}/task/${taskId}`
		);
		if (!response.ok) {
			throw new Error(
				`Algolia live-probe-owned source task poll failed with HTTP ${response.status}`
			);
		}
		const task = (await response.json()) as { status?: string };
		if (task.status === 'published') return;
		await new Promise((resolve) => setTimeout(resolve, 250));
	}
	throw new Error('Algolia live-probe-owned source task did not publish within 60 polls');
}

function algoliaSourceDocuments(): readonly JsonObject[] {
	const fixturePath = path.join(
		REPO_ROOT,
		'scripts/tests/fixtures/algolia_migration_parity_source.json'
	);
	const documents = JSON.parse(readFileSync(fixturePath, 'utf8')) as unknown;
	if (!Array.isArray(documents) || !documents.every(isJsonObject)) {
		throw new Error('Algolia live-probe source fixture must be an array of objects');
	}
	return documents;
}

async function deleteAlgoliaSource(
	credentials: AlgoliaCredentials,
	sourceName: string
): Promise<void> {
	const response = await algoliaRequest(
		credentials,
		`/1/indexes/${encodeURIComponent(sourceName)}`,
		{
			method: 'DELETE'
		}
	);
	if (response.status === 404) return;
	const taskId = await requireAlgoliaTaskId(response, 'Algolia browser Arrange cleanup');
	await waitForAlgoliaTask(credentials, sourceName, taskId);
}

async function seedAlgoliaSource(
	credentials: AlgoliaCredentials,
	sourceName: string,
	documents: readonly JsonObject[]
): Promise<void> {
	const response = await algoliaRequest(
		credentials,
		`/1/indexes/${encodeURIComponent(sourceName)}/batch`,
		{
			method: 'POST',
			body: JSON.stringify({
				requests: documents.map((body) => ({ action: 'addObject', body }))
			})
		}
	);
	const taskId = await requireAlgoliaTaskId(response, 'Algolia live-probe-owned source Arrange');
	await waitForAlgoliaTask(credentials, sourceName, taskId);
}

async function algoliaContract(): Promise<SourceMigrationAlgoliaParityContract> {
	const credentials = algoliaCredentials();
	const documents = algoliaSourceDocuments();
	const suffix = `${process.pid}_${randomBytes(4).toString('hex')}`;
	const sourceName = `fjcloud_browser_algolia_${suffix}_source`;
	const destinationName = `fjcloud_browser_algolia_${suffix}_target`;
	const cleanupSource = () => deleteAlgoliaSource(credentials, sourceName);

	try {
		await seedAlgoliaSource(credentials, sourceName, documents);
	} catch (error) {
		await cleanupSource().catch(() => {});
		throw error;
	}

	return {
		provider: 'algolia',
		sourceProof: 'live-probe-owner',
		sourceOwner:
			'scripts/algolia_migration_parity_live_probe.sh + docs/live-state/2026_07_25_algolia_migration_correctness.md',
		connection: {
			hostUrl: credentials.appId,
			apiKey: credentials.adminKey,
			sourceName,
			sourceLabel: sourceLabelWithRecordCount(sourceName, documents.length),
			destinationName
		},
		targetNames: [destinationName],
		assertNoCredentialLeakInBrowserArtifacts: (page) =>
			assertValuesAbsentInBrowserArtifacts(
				page,
				[
					{ name: 'ALGOLIA_APP_ID', value: credentials.appId },
					{ name: 'ALGOLIA_ADMIN_KEY', value: credentials.adminKey }
				],
				'algolia'
			),
		cleanupSource
	};
}

// Resolve the seeded canary values, not their public environment-variable names.
export function seededCanarySpecimens(
	canaryEnvNames: readonly string[]
): { name: string; value: string }[] {
	const specimens = canaryEnvNames.map((name) => ({
		name,
		value: (process.env[name] ?? '').trim()
	}));
	const missingNames = specimens.filter(({ value }) => value.length === 0).map(({ name }) => name);
	if (missingNames.length > 0) {
		throw new Error(
			`source migration canary guard is missing required owner specimens: ${missingNames.join(', ')}`
		);
	}
	return specimens;
}

async function browserMigrationArtifacts(page: Page): Promise<ReadonlyMap<string, string>> {
	const pageUrl = page.url();
	const dataUrl = new URL(pageUrl);
	dataUrl.pathname = `${dataUrl.pathname.replace(/\/$/, '')}/__data.json`;
	const dataResponse = await page.request.get(dataUrl.toString());
	if (!dataResponse.ok()) {
		throw new Error(
			`source migration retained data probe failed with HTTP ${dataResponse.status()}`
		);
	}
	const browserStorage = await page.evaluate(() => {
		const entries = (storage: Storage): [string, string | null][] =>
			Array.from({ length: storage.length }, (_, index) => {
				const key = storage.key(index) ?? '';
				return [key, storage.getItem(key)];
			});
		return JSON.stringify({
			localStorage: entries(localStorage),
			sessionStorage: entries(sessionStorage)
		});
	});
	const cookies = await page.context().cookies();
	return new Map([
		['page URL', pageUrl],
		['rendered DOM', await page.content()],
		['browser storage', browserStorage],
		['browser cookies', JSON.stringify(cookies)],
		['retained __data.json', await dataResponse.text()]
	]);
}

// Require and scan every owner-backed specimen across retained browser-owned surfaces.
export async function assertValuesAbsentInBrowserArtifacts(
	page: Page,
	specimens: readonly { name: string; value: string }[],
	provider: string
): Promise<void> {
	const artifacts = await browserMigrationArtifacts(page);
	for (const specimen of specimens) {
		for (const [artifactName, artifact] of artifacts) {
			if (artifact.includes(specimen.value)) {
				throw new Error(`${provider} ${artifactName} leaked canary ${specimen.name}`);
			}
		}
	}
}

async function assertNoCanaryInBrowserArtifacts(
	page: Page,
	canaryEnvNames: readonly string[],
	provider: string
): Promise<void> {
	await assertValuesAbsentInBrowserArtifacts(page, seededCanarySpecimens(canaryEnvNames), provider);
}

function readCurlHeaderSecret(fileName: string, headerPrefix: string): string {
	const resolved = path.join(CREDENTIAL_ROOT, fileName);
	if (!existsSync(resolved)) {
		throw new Error(
			`source migration provider parity missing local source credential file ${resolved}`
		);
	}
	const source = readFileSync(resolved, 'utf8');
	const escapedPrefix = escapeRegex(headerPrefix);
	const match = source.match(new RegExp(`^header = "${escapedPrefix}(.+)"$`, 'm'));
	if (!match || match[1].trim().length === 0) {
		throw new Error(`source migration provider parity could not read ${headerPrefix} credential`);
	}
	return match[1].trim();
}

export function localProviderOriginForPort(envName: string, port: string): string {
	if (!/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65_535) {
		throw new Error(`${envName} must be a numeric TCP port between 1 and 65535`);
	}
	return `http://127.0.0.1:${port}`;
}

function localProviderHost(provider: 'meilisearch' | 'typesense'): string {
	const envName = provider === 'meilisearch' ? 'LOCAL_MEILISEARCH_PORT' : 'LOCAL_TYPESENSE_PORT';
	const configuredPort = process.env[envName]?.trim();
	const port = configuredPort || derivedManualStackPort(envName);
	return localProviderOriginForPort(envName, port);
}

function requireLoopbackUrl(name: string, value: string, protocols: readonly string[]): URL {
	const parsed = new URL(value);
	const loopbackHosts = new Set(['localhost', '127.0.0.1', '[::1]']);
	if (!protocols.includes(parsed.protocol) || !loopbackHosts.has(parsed.hostname))
		throw new Error(`source migration provider parity requires a loopback ${name}`);
	return parsed;
}

function localParityDatabaseUrl(): string {
	const databaseUrl = [
		process.env.DATABASE_URL?.trim(),
		parseDotenvFile(path.join(REPO_ROOT, 'web/.env.local')).DATABASE_URL?.trim(),
		parseDotenvFile(path.join(REPO_ROOT, '.env.local')).DATABASE_URL?.trim()
	].find((candidate): candidate is string => Boolean(candidate));
	if (!databaseUrl) throw new Error('source migration provider parity requires DATABASE_URL');
	requireLoopbackUrl('PostgreSQL database', databaseUrl, ['postgres:', 'postgresql:']);
	return databaseUrl;
}

function currentFlapjackUrl(): string {
	const flapjackUrl = process.env.FLAPJACK_URL?.trim();
	if (!flapjackUrl) throw new Error('source migration provider parity requires FLAPJACK_URL');
	return requireLoopbackUrl('HTTP FLAPJACK_URL', flapjackUrl, ['http:']).origin;
}

type SelectedMigrationBackend = { id: string; createdAt: string; pinnedAt: string };

export function pinCurrentFlapjackAsSelectedMigrationBackend(region: string): () => Promise<void> {
	const databaseUrl = localParityDatabaseUrl();
	const flapjackUrl = currentFlapjackUrl();
	const hostname = `local-dev-${region.trim()}`;
	if (hostname === 'local-dev-')
		throw new Error('source migration provider parity requires a nonempty backend region');
	const selectedOutput = runSqlWithPsqlFallback(
		databaseUrl,
		`
WITH selected AS MATERIALIZED (
    SELECT id, created_at
    FROM vm_inventory
    WHERE status = 'active'
      AND provider = 'local'
      AND hostname = ${quoteSqlLiteral(hostname)}
      AND flapjack_url = ${quoteSqlLiteral(flapjackUrl)}
    LIMIT 1
    FOR UPDATE
), pin_time AS (
    SELECT MIN(created_at) - INTERVAL '1 day' AS created_at
    FROM vm_inventory
    WHERE status = 'active'
), updated AS (
    UPDATE vm_inventory vm
    SET created_at = pin_time.created_at
    FROM selected, pin_time
    WHERE vm.id = selected.id
    RETURNING vm.id, vm.created_at
)
SELECT json_build_object('id', selected.id, 'createdAt', selected.created_at, 'pinnedAt', updated.created_at)::text
FROM selected
JOIN updated USING (id);
`,
		'pin the current Playwright Flapjack as source migration backend'
	).trim();
	if (!selectedOutput)
		throw new Error('source migration provider parity requires the current local backend row');
	const selected = JSON.parse(selectedOutput) as SelectedMigrationBackend;
	if (
		typeof selected.id !== 'string' ||
		typeof selected.createdAt !== 'string' ||
		typeof selected.pinnedAt !== 'string'
	) {
		throw new Error('source migration provider parity received an invalid backend selection');
	}

	return async () => {
		const restored = runSqlWithPsqlFallback(
			databaseUrl,
			`
WITH restored AS (
    UPDATE vm_inventory
    SET created_at = ${quoteSqlLiteral(selected.createdAt)}::timestamptz
    WHERE id = ${quoteSqlLiteral(selected.id)}::uuid
      AND created_at = ${quoteSqlLiteral(selected.pinnedAt)}::timestamptz
      AND flapjack_url = ${quoteSqlLiteral(flapjackUrl)}
    RETURNING 1
)
SELECT COUNT(*) FROM restored;
`,
			'restore source migration backend after provider parity'
		).trim();
		if (restored !== '1')
			throw new Error(`source migration backend cleanup restored ${restored || '0'} rows`);
	};
}

function derivedManualStackPort(envName: 'LOCAL_MEILISEARCH_PORT' | 'LOCAL_TYPESENSE_PORT') {
	const portPlanHelper = path.join(REPO_ROOT, 'scripts/lib/playwright_port_plan.sh');
	const plan = execFileSync(
		'bash',
		[
			'-c',
			'source "$1"; playwright_derive_manual_stack_port_defaults "$2" "$2"',
			'source-migration-provider-parity-port-plan',
			portPlanHelper,
			REPO_ROOT
		],
		{ encoding: 'utf8' }
	);
	const prefix = `${envName}=`;
	const port = plan
		.split('\n')
		.find((line) => line.startsWith(prefix))
		?.slice(prefix.length);
	if (!port) {
		throw new Error(`manual-stack port plan did not provide ${envName}`);
	}
	return port;
}

async function requireOk(response: Response, context: string): Promise<void> {
	if (response.ok) {
		return;
	}
	throw new Error(`${context} failed with HTTP ${response.status}`);
}

// Await asynchronous Meilisearch writes using the imported bundle's task contract.
async function waitForMeiliTask(
	connection: SourceMigrationProviderParityConnection,
	enqueueResponse: Response,
	terminalStatuses: readonly string[],
	pollLimit: number,
	context: string
): Promise<void> {
	const enqueued = (await enqueueResponse.json()) as { taskUid?: number };
	if (typeof enqueued.taskUid !== 'number') {
		throw new Error(`${context} did not return a taskUid`);
	}
	for (let attempt = 0; attempt < pollLimit; attempt += 1) {
		const response = await fetch(`${connection.hostUrl}/tasks/${enqueued.taskUid}`, {
			headers: { Authorization: `Bearer ${connection.apiKey}` }
		});
		await requireOk(response, `${context} task poll`);
		const task = (await response.json()) as { status?: string };
		const status = task.status ?? '';
		if (status === 'succeeded') {
			return;
		}
		if (status !== '' && terminalStatuses.includes(status)) {
			throw new Error(`${context} reached terminal task status ${status}, expected succeeded`);
		}
		await new Promise((resolve) => setTimeout(resolve, 250));
	}
	throw new Error(`${context} task did not reach succeeded within ${pollLimit} polls`);
}

// Remove the bundle mutation row so a correct importer starts from the certified before-state.
async function restoreMeilisearchSourceBeforeMutation(
	connection: SourceMigrationProviderParityConnection,
	mutationPrimaryKeyValue: string,
	terminalStatuses: readonly string[],
	pollLimit: number
): Promise<void> {
	const response = await fetch(
		`${connection.hostUrl}/indexes/${connection.sourceName}/documents/${encodeURIComponent(mutationPrimaryKeyValue)}`,
		{
			method: 'DELETE',
			headers: { Authorization: `Bearer ${connection.apiKey}` }
		}
	);
	if (response.status === 404) {
		return;
	}
	await requireOk(response, 'Meilisearch source restore');
	await waitForMeiliTask(
		connection,
		response,
		terminalStatuses,
		pollLimit,
		'Meilisearch source restore'
	);
}

// Deterministic source_changed trigger: re-apply the imported-bundle mutation document (single
// source of truth, not an invented sentinel), awaited to terminal succeeded so the change is
// committed before the import is submitted.
async function mutateMeilisearchSource(
	connection: SourceMigrationProviderParityConnection,
	mutationDocument: JsonObject,
	terminalStatuses: readonly string[],
	pollLimit: number
): Promise<void> {
	const response = await fetch(`${connection.hostUrl}/indexes/${connection.sourceName}/documents`, {
		method: 'POST',
		headers: {
			Authorization: `Bearer ${connection.apiKey}`,
			'Content-Type': 'application/json'
		},
		body: JSON.stringify([mutationDocument])
	});
	await requireOk(response, 'Meilisearch source_changed mutation');
	await waitForMeiliTask(
		connection,
		response,
		terminalStatuses,
		pollLimit,
		'Meilisearch source_changed mutation'
	);
}

// Typesense has no imported mutation document, so the deterministic source_changed trigger upserts
// an existing bundle product (its id and shape come from the imported contract) with a changed
// field. Typesense document upserts are synchronous, so no task poll is required.
async function mutateTypesenseSource(
	connection: SourceMigrationProviderParityConnection,
	upsertDocument: JsonObject,
	context: string
): Promise<void> {
	const response = await fetch(
		`${connection.hostUrl}/collections/${connection.sourceName}/documents?action=upsert`,
		{
			method: 'POST',
			headers: {
				'X-TYPESENSE-API-KEY': connection.apiKey,
				'Content-Type': 'application/json'
			},
			body: JSON.stringify(upsertDocument)
		}
	);
	await requireOk(response, context);
}

function localDestinationNames(sourceName: string): SourceMigrationLocalDestinationNames {
	return {
		completed: `${sourceName}_migrated`,
		cancelled: `${sourceName}_cancelled_migration`,
		sourceChanged: `${sourceName}_source_changed_migration`
	};
}

function meilisearchContract(): SourceMigrationLocalProviderParityContract {
	const bundle = readJsonObject('meilisearch', 'expected_bundle.json');
	assertEvidenceContainsBundleValues('meilisearch', bundle);
	const indexes = getObject(bundle, 'indexes');
	const configured = getObject(indexes, 'configured');
	const documents = getObject(bundle, 'documents');
	const stableIds = stringArray(documents, 'stableIds');
	const targetIndex = getString(configured, 'uid');
	const primaryKey = getString(configured, 'primaryKey');
	const countBefore = getNumber(documents, 'countBefore');
	const mutationDocument = getObject(documents, 'mutation');
	const mutationPrimaryKeyValue = getString(mutationDocument, primaryKey);
	const tasks = getObject(bundle, 'tasks');
	const terminalStatuses = stringArray(tasks, 'terminalStatuses');
	const taskPollLimit = getNumber(tasks, 'taskPollLimit');
	const canaryNames = ['MEILI_TEST_SECRET_CANARY'];
	const destinations = localDestinationNames(targetIndex);
	const connection = {
		hostUrl: localProviderHost('meilisearch'),
		apiKey: readCurlHeaderSecret('meilisearch.curl.conf', 'Authorization: Bearer '),
		sourceName: targetIndex,
		sourceLabel: sourceLabelWithRecordCount(targetIndex, meilisearchSourceRecordCount(bundle)),
		destinationName: destinations.completed
	};
	assertUniqueStrings(stableIds, 'Meilisearch stableIds');

	if (countBefore !== stableIds.length) {
		throw new Error(
			`Meilisearch countBefore ${countBefore} must match stableIds denominator ${stableIds.length}`
		);
	}
	// The bundle mutation must be the SKU-004 row the seeder applies (so restore removes exactly it,
	// and the source_changed trigger re-applies exactly it) — assert it is not already a before row.
	if (stableIds.includes(mutationPrimaryKeyValue)) {
		throw new Error(
			`Meilisearch mutation ${primaryKey}=${mutationPrimaryKeyValue} must be absent from the beforeMutation stableIds`
		);
	}

	return {
		provider: 'meilisearch',
		sourceProof: 'local-container',
		sourceOwner:
			'scripts/lib/local_source_providers.sh + scripts/lib/local_source_provider_evidence.py',
		connection,
		destinations,
		targetNames: Object.values(destinations),
		canaryNames,
		restoreSourceBeforeMutation: () =>
			restoreMeilisearchSourceBeforeMutation(
				connection,
				mutationPrimaryKeyValue,
				terminalStatuses,
				taskPollLimit
			),
		mutateSourceAfterEligibility: () =>
			mutateMeilisearchSource(connection, mutationDocument, terminalStatuses, taskPollLimit),
		assertNoCanaryInBrowserArtifacts: (page) =>
			assertNoCanaryInBrowserArtifacts(page, canaryNames, 'meilisearch'),
		// Exact imported-value proof reads discrete owner-backed job summary rows rendered by
		// ImportJobDetail.svelte (`migration-summary-<row>`) — never synthetic composite
		// sentences. With the source restored to beforeMutation, a correct create import
		// lands exactly `countBefore` rows.
		expectations: [
			{
				label: 'documents imported count',
				testId: 'migration-summary-documents',
				expectedText: `${countBefore} imported · ${countBefore} expected · 0 rejected`
			},
			{
				label: 'settings applied',
				testId: 'migration-summary-settings',
				expectedText: 'Applied'
			}
		],
		warningCodePattern: /^Meilisearch[A-Za-z]+$/
	};
}

function typesenseExpectations(
	documentCount: number
): readonly SourceMigrationProviderParityExpectation[] {
	// The shipped engine imports documents and the translated settings it can prove, while
	// synonym_sets and curation_sets are explicitly reported as not migrated. Assert that
	// honest compatibility result instead of deriving fictional imported counts from the source.
	return [
		{
			label: 'documents imported count',
			testId: 'migration-summary-documents',
			expectedText: `${documentCount} imported · ${documentCount} expected · 0 rejected`
		},
		{ label: 'settings applied', testId: 'migration-summary-settings', expectedText: 'Applied' },
		{
			label: 'synonyms imported count',
			testId: 'migration-summary-synonyms',
			expectedText: '0 imported'
		},
		{
			label: 'rules imported count',
			testId: 'migration-summary-rules',
			expectedText: '0 imported'
		}
	];
}

function typesenseContract(): SourceMigrationLocalProviderParityContract {
	const bundle = readJsonObject('typesense', 'expected_bundle.json');
	assertEvidenceContainsBundleValues('typesense', bundle);
	const source = getObject(bundle, 'source');
	const collections = objectArray(source, 'collections');
	const collectionNames = collections.map((collection) => getString(collection, 'name'));
	const canaryNames = ['TYPESENSE_STAGE2_BOOTSTRAP_CANARY'];
	assertUniqueStrings(collectionNames, 'Typesense collection names');

	const productCollection = collections.find(
		(collection) => getString(collection, 'name') === 'fj_ts_migration_products'
	);
	if (!productCollection) {
		throw new Error('Typesense fixture missing fj_ts_migration_products collection');
	}
	const productDocuments = objectArray(productCollection, 'documents');
	const productIds = productDocuments.map((document) => getString(document, 'id'));
	assertUniqueStrings(productIds, 'Typesense product document ids');

	const sourceName = getString(productCollection, 'name');
	const destinations = localDestinationNames(sourceName);
	const connection = {
		hostUrl: localProviderHost('typesense'),
		apiKey: readCurlHeaderSecret('typesense.curl.conf', 'X-TYPESENSE-API-KEY: '),
		sourceName,
		sourceLabel: sourceLabelWithRecordCount(
			sourceName,
			typesenseSourceRecordCount(productCollection)
		),
		destinationName: destinations.completed
	};

	// Deterministic source_changed trigger: upsert an existing bundle product with a changed field.
	const firstProduct = productDocuments[0];
	const upsertDocument: JsonObject = {
		...firstProduct,
		title: `${getString(firstProduct, 'title')} (source_changed audit)`
	};

	return {
		provider: 'typesense',
		sourceProof: 'local-container',
		sourceOwner:
			'scripts/lib/local_source_providers.sh + scripts/lib/local_source_provider_evidence.py',
		connection,
		destinations,
		targetNames: Object.values(destinations),
		canaryNames,
		restoreSourceBeforeMutation: () =>
			mutateTypesenseSource(connection, firstProduct, 'Typesense source restore'),
		mutateSourceAfterEligibility: () =>
			mutateTypesenseSource(connection, upsertDocument, 'Typesense source_changed mutation'),
		assertNoCanaryInBrowserArtifacts: (page) =>
			assertNoCanaryInBrowserArtifacts(page, canaryNames, 'typesense'),
		// Owner-backed exact values: documents, applied settings, and explicit zero imported
		// counts for unsupported synonym/curation translation — all rendered by ImportJobDetail
		// summary rows. Every warning this import renders is the engine's single Typesense
		// settings-translation gap code, observed live on the local container specimen.
		expectations: typesenseExpectations(productDocuments.length),
		warningCodePattern: /^TypesenseSettingNotMigrated$/
	};
}

export function sourceMigrationProviderParityFixture(
	provider: 'meilisearch'
): Promise<SourceMigrationLocalProviderParityContract>;
export function sourceMigrationProviderParityFixture(
	provider: 'typesense'
): Promise<SourceMigrationLocalProviderParityContract>;
export function sourceMigrationProviderParityFixture(
	provider: 'algolia'
): Promise<SourceMigrationAlgoliaParityContract>;
export async function sourceMigrationProviderParityFixture(
	provider: SourceMigrationProviderParityProvider
): Promise<SourceMigrationProviderParityContract> {
	switch (provider) {
		case 'meilisearch':
			return meilisearchContract();
		case 'typesense':
			return typesenseContract();
		case 'algolia':
			return algoliaContract();
	}
}
