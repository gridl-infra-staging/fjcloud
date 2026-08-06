/**
 * Shared Playwright test fixtures.
 *
 * Spec files import { test, expect } from this module instead of directly
 * from @playwright/test.  Custom fixtures handle data seeding and automatic
 * cleanup so spec files never need to call request.* themselves.
 *
 * API calls here are ARRANGE-phase shortcuts, explicitly allowed by
 * BROWSER_TESTING_STANDARDS_2.md.  They must never appear in *.spec.ts files.
 */

import {
	test as base,
	expect,
	type BrowserContext,
	type Locator,
	type Page
} from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
	createMetricsReadySearchableIndexSeedOptions,
	createSeedSearchableIndexFactory,
	seedSearchableIndexForCustomer,
	type SeedMetricsSearchableIndexFn,
	type SeedSearchableIndexFn
} from './searchable-index';
import { createDashboardUsageSeedFactory, type SeedDashboardUsageFn } from './dashboard_usage';
import { buildTenantScopedIndexUid } from '../../src/lib/flapjack-index';
import {
	findCustomerStatusViaStagingSsm,
	findPaidInvoiceEvidenceViaStagingSsm,
	findVerificationTokenViaStagingSsm,
	type StagingCustomerStatusEvidence,
	type StagingPaidInvoiceEvidence
} from './staging_db_lookup';
import { readStripeDefaultPaymentMethod } from './staging_stripe_lookup';
import {
	DEFAULT_API_URL,
	PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV,
	REMOTE_TARGET_OPT_IN_ENV,
	parseDotenvFile,
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import { ADMIN_SESSION_COOKIE, AUTH_COOKIE } from '../../src/lib/auth-session-contracts';
import { requireAdminApiKey, requireNonEmptyString } from './contract-guards';
import {
	attemptRemoteSignupFallback,
	isRemoteTargetMode,
	setAuthCookieForToken
} from './fresh_signup_remote_bootstrap';
import { SharedAuthCallCounter, type SharedAuthCallTotals } from './shared_auth_call_counter';
import { SharedTrackedCustomerCache } from './shared_tracked_customer_cache';
import type {
	ApiKeyListItem,
	DebugEvent,
	EstimatedBillResponse,
	IndexInfrastructureResponse,
	Rule,
	RuleSearchResponse,
	Synonym,
	SynonymSearchResponse,
	QsBuildStatus,
	QsConfig,
	PublicAlgoliaImportJob,
	SourceProvider as MigrationSourceProvider
} from '../../src/lib/api/types';
import { formatBytes, formatDateTime, formatNumber, statusLabel } from '../../src/lib/format';
import type {
	AdminRateCard,
	VmHostMetricsResponse,
	VmInventoryItem
} from '../../src/lib/admin-client';
import {
	pricingContractSnapshotFromAdminRateCard,
	type MarketingPricingContractSnapshot
} from '../../src/lib/pricing';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';
import { formatFixtureSetupFailure, redactSensitiveDiagnostics } from './setup_failure_message';
import { installCspAudit, type CspAudit } from './csp_audit';
export { formatFixtureSetupFailure } from './setup_failure_message';

// ---------------------------------------------------------------------------
// Internal HTTP helpers — never imported by spec files
// ---------------------------------------------------------------------------

type ResolvedFixtureEnv = ReturnType<typeof resolveFixtureEnv>;

function currentFixtureEnv(): ResolvedFixtureEnv {
	return resolveFixtureEnv(process.env);
}

function fixtureEnvForFailureDiagnostics(): { apiUrl: string; adminKey: string | undefined } {
	try {
		const resolved = currentFixtureEnv();
		return {
			apiUrl: resolved.apiUrl,
			adminKey: resolved.adminKey
		};
	} catch {
		return {
			apiUrl: process.env.API_URL?.trim() || process.env.API_BASE_URL?.trim() || DEFAULT_API_URL,
			adminKey: process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY
		};
	}
}

async function verifyTrackedCustomerEmailForRemote(email: string): Promise<void> {
	if (!shouldVerifyTrackedCustomerEmailViaStaging(fixtureEnv.apiUrl, isRemoteTargetMode())) {
		return;
	}

	const verificationToken = await findVerificationTokenViaStagingSsm(email);
	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const response = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/auth/verify-email',
			{},
			{ token: verificationToken }
		);
		if (response.ok) {
			return;
		}
		if (response.status === 429) {
			await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
			continue;
		}
		const requestId =
			response.headers.get('x-request-id') ?? response.headers.get('x-amzn-requestid') ?? '';
		throw new Error(
			`arrangeTrackedCustomerSession email verification failed: status=${response.status}${
				requestId ? ` request_id=${requestId}` : ''
			}`
		);
	}
	throw new Error(
		'arrangeTrackedCustomerSession email verification failed: exhausted retries after 429 rate limiting'
	);
}

function shouldVerifyTrackedCustomerEmailViaStaging(
	apiUrl: string,
	remoteTargetMode = isRemoteTargetMode()
): boolean {
	if (!remoteTargetMode) {
		return false;
	}
	return !isLoopbackApiUrl(apiUrl);
}

function isLoopbackApiUrl(apiUrl: string): boolean {
	let hostname: string;
	try {
		hostname = new URL(apiUrl).hostname;
	} catch {
		return false;
	}
	return (
		hostname === 'localhost' ||
		hostname === '127.0.0.1' ||
		hostname === '::1' ||
		hostname === '[::1]'
	);
}

// Resolve fixture env lazily so unit tests can import this module without
// immediately enforcing loopback constraints on the ambient shell env.
const fixtureEnv = {
	get apiUrl() {
		return currentFixtureEnv().apiUrl;
	},
	get adminKey() {
		return currentFixtureEnv().adminKey;
	},
	get userEmail() {
		return currentFixtureEnv().userEmail;
	},
	get userPassword() {
		return currentFixtureEnv().userPassword;
	},
	get testRegion() {
		return currentFixtureEnv().testRegion;
	},
	get flapjackUrl() {
		return currentFixtureEnv().flapjackUrl;
	}
} as ResolvedFixtureEnv;

let _token: string | null = null;
let _customerId: string | null = null;
let _staleFixtureIndexesCleaned = false;
let _staleFixtureIndexesCleanupCooldownUntil = 0;

// Shared-tracked-customer state lives in the worker-scoped fixture below so the
// customer survives every serial lane and is cleaned up when the worker exits.
type CleanupStaleFixtureIndexesOnceOptions = {
	force?: boolean;
	apiCall?: FixtureApiCall;
	now?: () => number;
	sleep?: (ms: number) => Promise<void>;
};
type FixtureApiCall = (
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
) => Promise<Response>;
type IsolatedAdminSession = {
	page: Page;
	revokeCurrentSession: () => Promise<void>;
};
type ArrangeIsolatedAdminSessionFn = () => Promise<IsolatedAdminSession>;
type EnsureLocalSharedVmInventoryForRegionDeps = {
	env?: Record<string, string | undefined>;
	flapjackUrl?: string;
	databaseUrl?: string | null;
	runSql?: (databaseUrl: string, sql: string, context: string) => unknown;
};
type ReconcileIndexPrimaryVmTelemetryDeps = {
	databaseUrl?: string | null;
	runSql?: (databaseUrl: string, sql: string, context: string) => unknown;
};
type PublicInfrastructureCanaryVmDeps = {
	databaseUrl?: string | null;
	runSql?: (databaseUrl: string, sql: string, context: string) => unknown;
};
type StaleFixtureIndexCleanupState = {
	cleaned: boolean;
	cooldownUntil: number;
};
type RunTrackedIndexCleanupDeps = {
	apiCall?: FixtureApiCall;
};
type RunTrackedCustomerCleanupDeps = {
	deleteTrackedCustomerForCleanup?: (customerId: string) => Promise<void>;
};
type AdminDeploymentFixture = {
	id: string;
	region: string;
	provider: 'aws' | 'local';
	status: string;
};
type AdminDeploymentSeedOptions = {
	provider?: 'aws' | 'local';
	region?: string;
};
type AdminVmLifecycleTimelineEventType =
	| 'detected_dead'
	| 'replacement_refused'
	| 'replacement_provisioning'
	| 'replacement_booted'
	| 'tenants_replaced'
	| 'replacement_failed'
	| 'replacement_completed';
export type AdminVmLifecycleTimelineEventExpectation = {
	id: string;
	vmId: string;
	eventType: AdminVmLifecycleTimelineEventType;
	label: string;
	detail: Record<string, unknown>;
	createdAt: string;
	formattedCreatedAt: string;
	rowTestId: string;
	expectedDetailText: string[];
	replacementLink?: {
		testId: string;
		href: string;
		text: string;
	};
};
export type AdminVmLifecycleTimelineFixture = {
	deadVmId: string;
	replacementVmId: string;
	deadHostname: string;
	replacementHostname: string;
	events: AdminVmLifecycleTimelineEventExpectation[];
	expectedGuardrailLabel: 'Guardrail';
	expectedGuardrailText: 'kill_switch_disabled';
	expectedReplacementHref: string;
	expectedReplacementText: string;
	fixtureMarker: 'admin_vm_timeline';
	emptyStateCopy: 'No lifecycle events recorded for this VM.';
};

const FIXTURE_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');

function resolveFixtureContractPath(relativePath: string): string {
	const contractPath = path.resolve(FIXTURE_REPO_ROOT, relativePath);
	if (!contractPath) {
		throw new Error(`${relativePath} not found from fixture repo root`);
	}
	if (!existsSync(contractPath)) {
		throw new Error(`${relativePath} not found from fixture repo root`);
	}
	return contractPath;
}

function readShellStringAssignment(contractPath: string, variableName: string): string {
	const contractSource = readFileSync(contractPath, 'utf8');
	const assignmentMatch = contractSource.match(new RegExp(`^${variableName}=(['"])(.*?)\\1$`, 'm'));
	if (!assignmentMatch) {
		throw new Error(`${contractPath} missing ${variableName}`);
	}
	return assignmentMatch[2];
}

function readShellArrayAssignment(contractPath: string, variableName: string): readonly string[] {
	const contractSource = readFileSync(contractPath, 'utf8');
	const arrayMatch = contractSource.match(new RegExp(`${variableName}=\\(([\\s\\S]*?)\\)`, 'm'));
	if (!arrayMatch) {
		throw new Error(`${contractPath} missing ${variableName}`);
	}

	const values = [...arrayMatch[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
	if (values.length === 0) {
		throw new Error(`${contractPath} has no ${variableName} values`);
	}
	return values;
}

const LOCAL_SEED_CONTRACT_PATH = resolveFixtureContractPath('scripts/lib/local_seed_contract.sh');
const STALE_FIXTURE_CONTRACT_PATH = resolveFixtureContractPath(
	'scripts/lib/stale_fixture_contract.sh'
);
const LOCAL_VM_CAPACITY_JSON = readShellStringAssignment(
	LOCAL_SEED_CONTRACT_PATH,
	'LOCAL_SEED_VM_CAPACITY_JSON'
);
const LOCAL_VM_CURRENT_LOAD_JSON = readShellStringAssignment(
	LOCAL_SEED_CONTRACT_PATH,
	'LOCAL_SEED_VM_CURRENT_LOAD_JSON'
);
const REPLICA_CANARY_MEM_RSS_BYTES = 5_153_960_755;
const REPLICA_CANARY_DISK_BYTES = 64_424_509_440;
const PUBLIC_INFRASTRUCTURE_CANARY_REGION = 'us-west-1';
// Single source of truth for the canary VM's private telemetry: the SQL seed and the
// forbidden-text assertions both derive from these objects, so a value can never be
// asserted-absent without also having been seeded (which would make the canary vacuous).
const PUBLIC_INFRASTRUCTURE_CANARY_CAPACITY = {
	cpu_weight: 24,
	mem_rss_bytes: 103_079_215_104,
	disk_bytes: 1_099_511_627_776,
	query_rps: 200,
	indexing_rps: 50
};
const PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD = {
	cpu_weight: 3.75,
	mem_rss_bytes: 34_359_738_368,
	disk_bytes: 274_877_906_944,
	query_rps: 41.5,
	indexing_rps: 9.25
};

function fixtureLocalDatabaseUrl(): string | null {
	const directDatabaseUrl = process.env.DATABASE_URL?.trim();
	if (directDatabaseUrl) {
		return directDatabaseUrl;
	}

	const dotenvCandidates = [
		path.resolve(process.cwd(), '.env.local'),
		path.resolve(process.cwd(), '..', '.env.local')
	];
	for (const dotenvPath of dotenvCandidates) {
		const databaseUrl = parseDotenvFile(dotenvPath).DATABASE_URL?.trim();
		if (databaseUrl) {
			return databaseUrl;
		}
	}

	return null;
}

function requireFixtureDatabaseUrl(context: string): string {
	const databaseUrl = fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error(`${context} requires DATABASE_URL or web/.env.local DATABASE_URL`);
	}
	return databaseUrl;
}

function runFixtureSql(sql: string, context: string): string {
	return runSqlWithPsqlFallback(requireFixtureDatabaseUrl(context), sql, context).trim();
}

function requireLoopbackDatabaseUrl(databaseUrl: string, context: string): string {
	let parsed: URL;
	try {
		parsed = new URL(databaseUrl);
	} catch {
		throw new Error(`${context} requires a valid local PostgreSQL DATABASE_URL`);
	}

	const isPostgres = parsed.protocol === 'postgres:' || parsed.protocol === 'postgresql:';
	const isLoopback =
		parsed.hostname === 'localhost' ||
		parsed.hostname === '::1' ||
		parsed.hostname === '[::1]' ||
		/^127(?:\.\d{1,3}){3}$/.test(parsed.hostname);
	if (!isPostgres || !isLoopback) {
		throw new Error(`${context} requires a loopback PostgreSQL DATABASE_URL`);
	}
	return databaseUrl;
}

function reconcileIndexPrimaryVmTelemetry(
	customerId: string,
	indexName: string,
	deps?: ReconcileIndexPrimaryVmTelemetryDeps
): void {
	const databaseUrl = deps && 'databaseUrl' in deps ? deps.databaseUrl : fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error('DATABASE_URL must be set to reconcile Infrastructure primary telemetry');
	}
	const localDatabaseUrl = requireLoopbackDatabaseUrl(
		databaseUrl,
		'reconcile Infrastructure primary telemetry'
	);

	const output = String(
		(deps?.runSql ?? runSqlWithPsqlFallback)(
			localDatabaseUrl,
			`
WITH target AS (
    SELECT vm_id
    FROM customer_tenants
    WHERE customer_id = ${quoteSqlLiteral(customerId)}::uuid
      AND tenant_id = ${quoteSqlLiteral(indexName)}
), updated AS (
    UPDATE vm_inventory vm
    SET capacity = ${quoteSqlLiteral(LOCAL_VM_CAPACITY_JSON)}::jsonb,
        current_load = ${quoteSqlLiteral(LOCAL_VM_CURRENT_LOAD_JSON)}::jsonb,
        status = 'active',
        load_scraped_at = NOW(),
        updated_at = NOW()
    FROM target
    WHERE vm.id = target.vm_id
    RETURNING 1
)
SELECT COUNT(*) FROM updated;
`,
			`reconcile Infrastructure primary telemetry for ${indexName}`
		)
	).trim();
	assertSingleSqlUpdatedRow(output, `reconcile Infrastructure primary telemetry for ${indexName}`);
}

function assertSingleSqlUpdatedRow(output: string, context: string): void {
	const lines = output
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean);
	if (lines[lines.length - 1] === '1') {
		return;
	}
	throw new Error(`${context} did not update exactly one row. Output: ${output}`);
}

/** Reset a locally seeded tracked customer to the unverified-email state. */
async function forceTrackedCustomerEmailUnverifiedForLocal(email: string): Promise<void> {
	if (isRemoteTargetMode()) {
		return;
	}

	const quotedEmail = quoteSqlLiteral(email);
	const output = runFixtureSql(
		[
			'WITH updated AS (',
			'  UPDATE customers',
			'  SET email_verified_at = NULL,',
			"      email_verify_token = COALESCE(email_verify_token, 'e2e-unverified-' || replace(id::text, '-', '')),",
			"      email_verify_expires_at = COALESCE(email_verify_expires_at, NOW() + INTERVAL '24 hours'),",
			'      resend_verification_sent_at = NULL,',
			'      updated_at = NOW()',
			`  WHERE email = ${quotedEmail}`,
			"    AND status != 'deleted'",
			'  RETURNING 1',
			')',
			'SELECT COUNT(*) FROM updated;'
		].join('\n'),
		'arrangeTrackedCustomerSession local unverified setup'
	);
	assertSingleSqlUpdatedRow(output, 'arrangeTrackedCustomerSession local unverified setup');
}

export async function ensureLocalSharedVmInventoryForRegion(
	region: string,
	deps?: EnsureLocalSharedVmInventoryForRegionDeps
): Promise<void> {
	const env = deps?.env ?? process.env;
	const apiUrl = env.API_URL ?? env.API_BASE_URL;
	if (env[REMOTE_TARGET_OPT_IN_ENV] === '1' && !isLoopbackApiUrl(apiUrl ?? '')) {
		return;
	}

	const safeRegion = requireNonEmptyString(region, 'ensureLocalSharedVmInventory requires region');
	const safeFlapjackUrl = requireLoopbackHttpUrl(
		'FLAPJACK_URL',
		deps?.flapjackUrl ?? fixtureEnv.flapjackUrl
	);
	const databaseUrl = deps && 'databaseUrl' in deps ? deps.databaseUrl : fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for local first-five-minutes UI create-index proof so vm_inventory can target the current Flapjack process.'
		);
	}

	const quotedRegion = quoteSqlLiteral(safeRegion);
	const quotedHostname = quoteSqlLiteral(`local-dev-${safeRegion}`);
	const quotedFlapjackUrl = quoteSqlLiteral(safeFlapjackUrl);
	const quotedCapacity = quoteSqlLiteral(LOCAL_VM_CAPACITY_JSON);
	const quotedCurrentLoad = quoteSqlLiteral(LOCAL_VM_CURRENT_LOAD_JSON);

	// The Playwright local stack moves Flapjack ports by workspace. Keep the
	// chosen browser region pointed at this session's Flapjack and drain stale
	// synthetic VMs left by earlier admin-seeded runs for the same local region.
	const runSql = deps?.runSql ?? runSqlWithPsqlFallback;
	runSql(
		databaseUrl,
		`
INSERT INTO vm_inventory (
    provider,
    hostname,
    flapjack_url,
    region,
    capacity,
    current_load,
    load_scraped_at,
    created_at,
    updated_at
)
VALUES (
    'local',
    ${quotedHostname},
    ${quotedFlapjackUrl},
    ${quotedRegion},
    ${quotedCapacity}::jsonb,
    ${quotedCurrentLoad}::jsonb,
    NOW(),
    NOW(),
    NOW()
)
ON CONFLICT (hostname) DO UPDATE
SET provider = EXCLUDED.provider,
    region = EXCLUDED.region,
    flapjack_url = EXCLUDED.flapjack_url,
    capacity = EXCLUDED.capacity,
    current_load = EXCLUDED.current_load,
    status = 'active',
    load_scraped_at = NOW(),
    updated_at = NOW();

UPDATE vm_inventory
SET status = 'decommissioned',
    updated_at = NOW()
WHERE provider = 'local'
  AND region = ${quotedRegion}
  AND status = 'active'
  AND hostname LIKE 'e2e-seed-%';
`,
		`local vm_inventory refresh for ${safeRegion}`
	);
}

type SeedInfrastructureTopologyInput = {
	customerId: string;
	indexName: string;
	replicaRegion: string;
	flapjackUrl: string;
};

type SeedInfrastructureTopologyResult = {
	replicaVmId: string;
	replicaHostname: string;
};

function seedInfrastructureReplicaTopology({
	customerId,
	indexName,
	replicaRegion,
	flapjackUrl
}: SeedInfrastructureTopologyInput): SeedInfrastructureTopologyResult {
	const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const replicaHostname = `e2e-infrastructure-replica-${seed}`;
	const replicaCurrentLoad = JSON.stringify({
		cpu_weight: 2.4,
		mem_rss_bytes: REPLICA_CANARY_MEM_RSS_BYTES,
		disk_bytes: REPLICA_CANARY_DISK_BYTES,
		query_rps: 300.0,
		indexing_rps: 120.0
	});
	const output = runFixtureSql(
		`
	WITH primary_target AS (
    SELECT vm_id
    FROM customer_tenants
    WHERE customer_id = ${quoteSqlLiteral(customerId)}::uuid
      AND tenant_id = ${quoteSqlLiteral(indexName)}
), replica_vm AS (
    INSERT INTO vm_inventory (
        provider,
        hostname,
        flapjack_url,
        region,
        capacity,
        current_load,
        load_scraped_at,
        created_at,
        updated_at
    )
    VALUES (
        'local',
	        ${quoteSqlLiteral(replicaHostname)},
	        ${quoteSqlLiteral(flapjackUrl)},
	        ${quoteSqlLiteral(replicaRegion)},
	        ${quoteSqlLiteral(LOCAL_VM_CAPACITY_JSON)}::jsonb,
	        ${quoteSqlLiteral(replicaCurrentLoad)}::jsonb,
	        NOW(),
	        NOW(),
	        NOW()
    )
    RETURNING id
), created_replica AS (
    INSERT INTO index_replicas (
        customer_id,
        tenant_id,
        primary_vm_id,
        replica_vm_id,
        replica_region,
        status,
        lag_ops
    )
    SELECT
        ${quoteSqlLiteral(customerId)}::uuid,
        ${quoteSqlLiteral(indexName)},
        primary_target.vm_id,
        replica_vm.id,
        ${quoteSqlLiteral(replicaRegion)},
        'active',
        37
    FROM primary_target, replica_vm
    RETURNING replica_vm_id
)
SELECT replica_vm_id::text FROM created_replica;
`,
		`seed Infrastructure topology for ${indexName}`
	);
	if (!output) {
		throw new Error(`seed Infrastructure topology returned no replica VM for ${indexName}`);
	}
	return {
		replicaVmId: output,
		replicaHostname
	};
}

function infrastructureBrowserContract(
	indexName: string,
	payload: IndexInfrastructureResponse,
	replicaRegion: string,
	replicaVmId: string,
	replicaHostname: string
): IndexInfrastructureBrowserContract {
	const replica = payload.replicas.find((candidate) => candidate.region === replicaRegion);
	if (
		payload.primary.utilization !== 'green' ||
		!replica ||
		replica.status !== 'active' ||
		replica.lag_ops !== 37 ||
		replica.utilization !== 'yellow' ||
		payload.headroom !== 'comfortable'
	) {
		throw new Error(`seeded Infrastructure contract did not converge for ${indexName}`);
	}

	return {
		indexName,
		primary: {
			region: payload.primary.region,
			status: statusLabel(payload.primary.status),
			utilization: 'Green'
		},
		replica: {
			region: replica.region,
			status: 'Active',
			lagOperations: 37,
			utilization: 'Yellow'
		},
		headroom: 'Comfortable',
		failover: `Automatic cross-region failover is available in ${replica.region}.`,
		forbiddenText: [
			replicaVmId,
			replicaHostname,
			String(REPLICA_CANARY_MEM_RSS_BYTES),
			String(REPLICA_CANARY_DISK_BYTES),
			'hostname',
			'flapjack_url',
			'vm_id',
			'replica_vm_id',
			'capacity',
			'current_load',
			'query_rps',
			'indexing_rps',
			'load_scraped_at'
		],
		footprint: {
			documents: formatNumber(payload.footprint.documents_count),
			storage: formatBytes(payload.footprint.storage_bytes),
			searchRequests: formatNumber(payload.footprint.search_requests_total),
			writeOperations: formatNumber(payload.footprint.write_operations_total)
		}
	};
}

type PublicInfrastructureCanaryVm = {
	vmId: string;
	customerId: string;
	deploymentId: string;
	tenantId: string;
	displacedVmIds: string[];
	kAnonymityRegion: string;
	forbiddenText: string[];
};

function seedPublicInfrastructureCanaryVm(
	deps?: PublicInfrastructureCanaryVmDeps
): PublicInfrastructureCanaryVm {
	const databaseUrl = deps && 'databaseUrl' in deps ? deps.databaseUrl : fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error('DATABASE_URL must be set to seed the public Infrastructure canary VM');
	}
	const localDatabaseUrl = requireLoopbackDatabaseUrl(
		databaseUrl,
		'seed public Infrastructure canary VM'
	);

	const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const hostname = `e2e-public-infra-canary-${seed}`;
	const customerName = `E2E public infrastructure canary ${seed}`;
	const customerEmail = `e2e-public-infra-canary-${seed}@example.invalid`;
	const nodeId = `e2e-public-infra-canary-node-${seed}`;
	const tenantId = `e2e-public-infra-canary-tenant-${seed}`;
	const ipLiteral = `127.64.${Math.floor(Math.random() * 200) + 20}.${
		Math.floor(Math.random() * 200) + 20
	}`;
	const flapjackUrl = `http://${ipLiteral}:47700`;
	const output = String(
		(deps?.runSql ?? runSqlWithPsqlFallback)(
			localDatabaseUrl,
			`
	WITH prior_active AS (
	    SELECT id, id::text AS id_text
	    FROM vm_inventory
	    WHERE region = ${quoteSqlLiteral(PUBLIC_INFRASTRUCTURE_CANARY_REGION)}
	      AND status = 'active'
	), decommissioned AS (
	    UPDATE vm_inventory
	    SET status = 'decommissioned',
	        updated_at = NOW()
	    WHERE id IN (SELECT id FROM prior_active)
	    RETURNING 1
	), inserted_vm AS (
	    INSERT INTO vm_inventory (
	        provider,
	        hostname,
	        flapjack_url,
	        region,
	        capacity,
	        current_load,
	        load_scraped_at,
	        created_at,
	        updated_at,
	        status
	    )
	    VALUES (
	        'local',
	        ${quoteSqlLiteral(hostname)},
	        ${quoteSqlLiteral(flapjackUrl)},
	        ${quoteSqlLiteral(PUBLIC_INFRASTRUCTURE_CANARY_REGION)},
	        ${quoteSqlLiteral(JSON.stringify(PUBLIC_INFRASTRUCTURE_CANARY_CAPACITY))}::jsonb,
	        ${quoteSqlLiteral(JSON.stringify(PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD))}::jsonb,
	        NOW(),
	        NOW(),
	        NOW(),
	        'active'
	    )
	    RETURNING id, id::text AS id_text
	), inserted_customer AS (
	    INSERT INTO customers (name, email, status)
	    VALUES (
	        ${quoteSqlLiteral(customerName)},
	        ${quoteSqlLiteral(customerEmail)},
	        'active'
	    )
	    RETURNING id, id::text AS id_text
	), inserted_deployment AS (
	    INSERT INTO customer_deployments (
	        customer_id,
	        node_id,
	        region,
	        vm_type,
	        vm_provider,
	        status,
	        hostname,
	        flapjack_url
	    )
	    SELECT
	        inserted_customer.id,
	        ${quoteSqlLiteral(nodeId)},
	        ${quoteSqlLiteral(PUBLIC_INFRASTRUCTURE_CANARY_REGION)},
	        'local.e2e',
	        'local',
	        'running',
	        ${quoteSqlLiteral(hostname)},
	        ${quoteSqlLiteral(flapjackUrl)}
	    FROM inserted_customer
	    RETURNING id, id::text AS id_text
	), inserted_tenant AS (
	    INSERT INTO customer_tenants (
	        customer_id,
	        tenant_id,
	        deployment_id,
	        vm_id
	    )
	    SELECT
	        inserted_customer.id,
	        ${quoteSqlLiteral(tenantId)},
	        inserted_deployment.id,
	        inserted_vm.id
	    FROM inserted_customer, inserted_deployment, inserted_vm
	    RETURNING tenant_id
	)
	SELECT json_build_object(
	    'vm_id',
	    (SELECT id_text FROM inserted_vm),
	    'customer_id',
	    (SELECT id_text FROM inserted_customer),
	    'deployment_id',
	    (SELECT id_text FROM inserted_deployment),
	    'tenant_id',
	    (SELECT tenant_id FROM inserted_tenant),
	    'displaced_vm_ids',
	    COALESCE((SELECT json_agg(id_text ORDER BY id_text) FROM prior_active), '[]'::json)
	)::text;
	`,
			`seed public Infrastructure canary VM for ${PUBLIC_INFRASTRUCTURE_CANARY_REGION}`
		)
	).trim();

	if (!output) {
		throw new Error('seed public Infrastructure canary VM returned no seed metadata');
	}

	let seedMetadata: {
		vm_id?: unknown;
		customer_id?: unknown;
		deployment_id?: unknown;
		tenant_id?: unknown;
		displaced_vm_ids?: unknown;
	};
	try {
		seedMetadata = JSON.parse(output) as typeof seedMetadata;
	} catch (error) {
		throw new Error(
			`seed public Infrastructure canary VM returned invalid JSON metadata: ${setupFailureDetailsFromError(error)}`,
			{ cause: error }
		);
	}

	if (
		typeof seedMetadata.vm_id !== 'string' ||
		typeof seedMetadata.customer_id !== 'string' ||
		typeof seedMetadata.deployment_id !== 'string' ||
		typeof seedMetadata.tenant_id !== 'string' ||
		!Array.isArray(seedMetadata.displaced_vm_ids) ||
		!seedMetadata.displaced_vm_ids.every((value) => typeof value === 'string')
	) {
		throw new Error('seed public Infrastructure canary VM returned incomplete seed metadata');
	}

	return {
		vmId: seedMetadata.vm_id,
		customerId: seedMetadata.customer_id,
		deploymentId: seedMetadata.deployment_id,
		tenantId: seedMetadata.tenant_id,
		displacedVmIds: seedMetadata.displaced_vm_ids,
		kAnonymityRegion: PUBLIC_INFRASTRUCTURE_CANARY_REGION,
		forbiddenText: [
			seedMetadata.vm_id,
			seedMetadata.customer_id,
			seedMetadata.deployment_id,
			seedMetadata.tenant_id,
			hostname,
			customerName,
			customerEmail,
			nodeId,
			flapjackUrl,
			ipLiteral,
			String(PUBLIC_INFRASTRUCTURE_CANARY_CAPACITY.mem_rss_bytes),
			String(PUBLIC_INFRASTRUCTURE_CANARY_CAPACITY.disk_bytes),
			String(PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD.mem_rss_bytes),
			String(PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD.disk_bytes),
			String(PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD.query_rps),
			String(PUBLIC_INFRASTRUCTURE_CANARY_CURRENT_LOAD.indexing_rps)
		]
	};
}

function restorePublicInfrastructureCanaryVm(
	canary: PublicInfrastructureCanaryVm,
	deps?: PublicInfrastructureCanaryVmDeps
): void {
	const databaseUrl = deps && 'databaseUrl' in deps ? deps.databaseUrl : fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error('DATABASE_URL must be set to restore the public Infrastructure canary VM');
	}
	const localDatabaseUrl = requireLoopbackDatabaseUrl(
		databaseUrl,
		'restore public Infrastructure canary VM'
	);

	const restoreDisplacedSql =
		canary.displacedVmIds.length > 0
			? `
UPDATE vm_inventory
SET status = 'active',
    updated_at = NOW()
WHERE id IN (${canary.displacedVmIds.map((vmId) => `${quoteSqlLiteral(vmId)}::uuid`).join(', ')});`
			: '';

	(deps?.runSql ?? runSqlWithPsqlFallback)(
		localDatabaseUrl,
		`
BEGIN;
DELETE FROM customer_tenants
WHERE customer_id = ${quoteSqlLiteral(canary.customerId)}::uuid
  AND tenant_id = ${quoteSqlLiteral(canary.tenantId)}
  AND deployment_id = ${quoteSqlLiteral(canary.deploymentId)}::uuid
  AND vm_id = ${quoteSqlLiteral(canary.vmId)}::uuid;

DELETE FROM customer_deployments
WHERE id = ${quoteSqlLiteral(canary.deploymentId)}::uuid
  AND customer_id = ${quoteSqlLiteral(canary.customerId)}::uuid;

DELETE FROM customers
WHERE id = ${quoteSqlLiteral(canary.customerId)}::uuid;

UPDATE vm_inventory
SET status = 'decommissioned',
    updated_at = NOW()
WHERE id = ${quoteSqlLiteral(canary.vmId)}::uuid;
${restoreDisplacedSql}
COMMIT;
	`,
		`restore public Infrastructure canary VM ${canary.vmId}`
	);
}

const STALE_FIXTURE_INDEX_PREFIXES = readStaleFixtureIndexPrefixes();
const PASSIVE_STALE_INDEX_CLEANUP_DEADLINE_MS = 8_000;
const FORCE_STALE_INDEX_CLEANUP_DEADLINE_MS = 300_000;
const STAGE5_SYNONYMS_PROOF_MANIFEST_PATH = 'test-results/stage5-synonyms-proof.json';

function readStaleFixtureIndexPrefixes(): readonly string[] {
	return readShellArrayAssignment(STALE_FIXTURE_CONTRACT_PATH, 'STALE_FIXTURE_INDEX_PREFIXES');
}

export class FixtureAuthTokenInvalidError extends Error {
	status: number;

	constructor(status: number, details: string) {
		super(details);
		this.status = status;
		this.name = 'FixtureAuthTokenInvalidError';
	}
}

type BearerTokenRefreshDeps<T> = {
	getToken: () => Promise<string>;
	invalidateToken: () => void;
	invoke: (token: string) => Promise<T>;
};

// Shared bearer-token refresh seam: every authenticated fixture call routes
// through one of these helpers so a stale cached token (e.g. left behind by a
// local API restart) is invalidated and recovered the same way regardless of
// caller. Pure and DI-driven so tests can exercise the refresh logic without
// touching module-level state. Used by apiCall and getCustomerId.

/**
 * Run a bearer-authenticated operation that returns a Response, retrying once
 * with a refreshed token when the first response is 401 or 403.
 */
export async function callWithBearerTokenRefreshOnResponse({
	getToken,
	invalidateToken,
	invoke
}: BearerTokenRefreshDeps<Response>): Promise<Response> {
	const token = await getToken();
	const first = await invoke(token);
	if (first.status !== 401 && first.status !== 403) {
		return first;
	}
	invalidateToken();
	const refreshedToken = await getToken();
	return invoke(refreshedToken);
}

/**
 * Run a bearer-authenticated operation that throws FixtureAuthTokenInvalidError
 * on 401/403, retrying once with a refreshed token. Non-auth errors propagate.
 */
export async function callWithBearerTokenRefreshOnUnauthorizedThrow<T>({
	getToken,
	invalidateToken,
	invoke
}: BearerTokenRefreshDeps<T>): Promise<T> {
	try {
		const token = await getToken();
		return await invoke(token);
	} catch (error) {
		if (!(error instanceof FixtureAuthTokenInvalidError)) {
			throw error;
		}
		invalidateToken();
		const refreshedToken = await getToken();
		return invoke(refreshedToken);
	}
}

type AuthApiResponse = {
	token: string;
	customer_id: string;
};
type JsonHeaders = Record<string, string>;
type RegisterIndexCleanupOptions = {
	deferCleanup?: boolean;
};
type SeedIndexOptions = RegisterIndexCleanupOptions & {
	proofManifestPath?: string;
	settings?: Record<string, unknown>;
};
type WriteSynonymsProofManifestInput = {
	indexName: string;
	objectIDs: string[];
	manifestPath?: string;
};
type SynonymsProofManifest = {
	indexName: string;
	objectIDs: string[];
	cleanup: {
		method: 'DELETE';
		path: string;
		body: { confirm: true };
	};
	generatedAt: string;
	consumed: boolean;
};

export type CreatedFixtureUser = {
	customerId: string;
	token: string;
	email: string;
	password: string;
};

export type FreshSignupIdentity = {
	name: string;
	email: string;
	password: string;
};

type BatchBillingResult = {
	customer_id: string;
	status: string;
	invoice_id: string | null;
	reason: string | null;
};

type BatchBillingResponse = {
	month: string;
	invoices_created: number;
	invoices_skipped: number;
	results: BatchBillingResult[];
};

type ArrangePaidInvoiceForFreshSignupResult = {
	customerId: string;
	invoiceId: string;
	billingMonth: string;
	stagingCustomerId: string;
	stagingInvoiceId: string;
	stagingInvoiceStatus: string;
	stagingInvoicePeriodStart: string;
};

type ArrangeFreshSignupToDashboardResult = {
	prerequisiteFailureMessage: string | null;
};

type TrackCustomerForCleanupFn = (customerId: string) => void;
type BeforeDocumentReplacementFn = () => Promise<void>;
type ArrangeFreshSignupToDashboardDeps = {
	resolveCleanupCustomerId?: typeof resolveFreshSignupCleanupCustomerId;
	getSessionTokenFromPage?: (page: Page) => Promise<string | null>;
	attemptRemoteFallback?: typeof attemptRemoteSignupFallback;
};

const JSON_CONTENT_TYPE = { 'Content-Type': 'application/json' } as const;

const FRESH_SIGNUP_ARRANGE_SETUP_FAILURE_ALERT_PATTERN =
	/service is unavailable|verify API_URL|verification email temporarily unavailable/i;
const FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN = /invalid (email or password|credentials)/i;
const TRANSIENT_API_MAX_RETRIES = 10;
const IGNORE_TRACKED_FIXTURE_CUSTOMER_ID: TrackCustomerForCleanupFn = () => {};

type ThrowFreshSignupArrangeFailureParams = {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
};
type ResolveFreshSignupCleanupCustomerIdParams = {
	sessionToken: string | null;
	currentPath: string;
	responseStatus?: number;
	responseUrl?: string;
	resolveCustomerIdByToken?: (token: string) => Promise<string>;
};
type ThrowBillingPortalArrangeFailureParams = {
	currentPath: string;
	error: unknown;
	responseStatus?: number;
	responseUrl?: string;
};

export function isFreshSignupArrangePrerequisiteFailure(alertText: string): boolean {
	return FRESH_SIGNUP_ARRANGE_SETUP_FAILURE_ALERT_PATTERN.test(alertText.trim());
}

export function throwFreshSignupArrangeFailure({
	currentPath,
	alertText,
	responseStatus,
	responseUrl
}: ThrowFreshSignupArrangeFailureParams): never {
	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'fresh-signup arrange',
			expectedPath: '/console',
			currentPath,
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText,
			responseStatus,
			responseUrl
		})
	);
}

/** Resolve cleanup ownership from an authenticated signup session or throw fixture-owned setup errors. */
export async function resolveFreshSignupCleanupCustomerId({
	sessionToken,
	currentPath,
	responseStatus,
	responseUrl,
	resolveCustomerIdByToken = getCustomerIdForToken
}: ResolveFreshSignupCleanupCustomerIdParams): Promise<string> {
	if (!sessionToken) {
		throwFreshSignupArrangeFailure({
			currentPath,
			alertText: 'Sign up reached /console but auth cookie token was missing.',
			responseStatus,
			responseUrl
		});
	}

	try {
		return await resolveCustomerIdByToken(sessionToken);
	} catch (error) {
		throwFreshSignupArrangeFailure({
			currentPath,
			alertText: `Sign up reached /console but fixture could not resolve customer id from auth cookie token: ${setupFailureDetailsFromError(error)}`,
			responseStatus,
			responseUrl
		});
	}
}

/** Throws a fixture-owned fail-closed setup error for billing-portal prerequisites. */
function throwBillingPortalArrangeFailure({
	currentPath,
	error,
	responseStatus,
	responseUrl
}: ThrowBillingPortalArrangeFailureParams): never {
	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'billing-portal arrange',
			expectedPath: '/console/billing',
			currentPath,
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText: setupFailureDetailsFromError(error),
			responseStatus,
			responseUrl
		})
	);
}

/** Extract a privacy-safe setup failure detail string from arbitrary thrown errors. */
export function setupFailureDetailsFromError(error: unknown): string {
	if (error instanceof Error && error.message.trim()) {
		return redactSensitiveDiagnostics(error.message.trim());
	}
	return redactSensitiveDiagnostics(String(error));
}

function buildJsonRequestInit(method: string, headers: JsonHeaders, body?: unknown): RequestInit {
	return {
		method,
		headers: {
			...JSON_CONTENT_TYPE,
			...headers
		},
		body: body === undefined ? undefined : JSON.stringify(body)
	};
}

async function callJsonApi(
	fetchImpl: typeof fetch,
	apiUrl: string,
	method: string,
	path: string,
	headers: JsonHeaders,
	body?: unknown
): Promise<Response> {
	return fetchImpl(`${apiUrl}${path}`, buildJsonRequestInit(method, headers, body));
}

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function getTransientRetryDelayMs(attempt: number): number {
	return Math.min(2000 * (attempt + 1), 10_000);
}

const REMOTE_SEEDED_INDEX_WRITE_RPS = 100;

function cappedTransientRetryBudgetMs(maxAttempts: number): number {
	return Array.from({ length: maxAttempts }, (_, attempt) =>
		getTransientRetryDelayMs(attempt)
	).reduce((total, delayMs) => total + delayMs, 0);
}

function getRetryDelayMs(attempt: number, retryAfterHeader: string | null): number {
	const retryAfterSeconds = Number(retryAfterHeader ?? '');
	const retryAfterMs =
		Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
	return Math.max(retryAfterMs, getTransientRetryDelayMs(attempt));
}

function isTransientAccountLookupFailure(status: number): boolean {
	return status === 429 || status >= 500;
}

function isTransientTransportFailure(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}
	const message = error.message.toLowerCase();
	return (
		message.includes('fetch failed') ||
		message.includes('econnrefused') ||
		message.includes('ecconnrefused') ||
		message.includes('socket hang up')
	);
}

function isUnauthorizedExpiredTokenAccountFailure(status: number, failureDetails: string): boolean {
	return status === 401 && /invalid or expired token/i.test(failureDetails);
}

function isTransientSeedIndexTransportFailure(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}
	const message = error.message.toLowerCase();
	return (
		message.includes('fetch failed') ||
		message.includes('econnrefused') ||
		message.includes('ecconnrefused') ||
		message.includes('socket hang up') ||
		message.includes('network error')
	);
}

// Keep the setup:user timeout aligned with the helper retry contract so
// Playwright does not abort before fixture bootstrap finishes its own retries.
export const FIXTURE_AUTH_API_RETRY_BUDGET_MS =
	cappedTransientRetryBudgetMs(TRANSIENT_API_MAX_RETRIES);

const STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS = 20;
const INVOICE_STATUS_WAIT_MAX_ATTEMPTS = 90;
const INVOICE_OPEN_WITHOUT_STRIPE_ID_MAX_ATTEMPTS = 12;
const INVOICE_OPEN_WITH_STRIPE_ID_MAX_ATTEMPTS = 46;
const PAID_INVOICE_PROOF_TIMEOUT_BUFFER_MS = 60_000;
const STAGING_LANE_WATCHDOG_TIMEOUT_MS = 480_000;
const PAID_INVOICE_PROOF_WATCHDOG_SAFETY_MARGIN_MS = 30_000;

// Keep the signup-to-paid-invoice spec timeout aligned with its fixture-owned
// Stripe + invoice polling budgets so remote staging failures surface the
// underlying fixture error instead of a generic Playwright timeout.
export const PAID_INVOICE_PROOF_TIMEOUT_MS = Math.min(
	FIXTURE_AUTH_API_RETRY_BUDGET_MS +
		cappedTransientRetryBudgetMs(STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS) +
		cappedTransientRetryBudgetMs(INVOICE_STATUS_WAIT_MAX_ATTEMPTS) +
		PAID_INVOICE_PROOF_TIMEOUT_BUFFER_MS,
	STAGING_LANE_WATCHDOG_TIMEOUT_MS - PAID_INVOICE_PROOF_WATCHDOG_SAFETY_MARGIN_MS
);

type CreateRegisteredUserParams = {
	apiUrl: string;
	email: string;
	password: string;
	name?: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
};

type FetchDisposableTenantRateCardSnapshotParams = {
	apiUrl: string;
	adminKey?: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
	seed?: string;
};

export async function createRegisteredUser({
	apiUrl,
	email,
	password,
	name,
	trackCustomerForCleanup,
	fetchImpl = fetch
}: CreateRegisteredUserParams): Promise<CreatedFixtureUser> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedEmail = requireNonEmptyString(
		email,
		'createRegisteredUser requires non-empty email and password'
	);
	if (!password.trim()) {
		throw new Error('createRegisteredUser requires non-empty email and password');
	}
	const customerName = name?.trim() || `E2E Fixture ${normalizedEmail}`;

	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetchImpl,
			localApiUrl,
			'POST',
			'/auth/register',
			{},
			{
				name: customerName,
				email: normalizedEmail,
				password
			}
		);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`createUser failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as AuthApiResponse;
		trackCustomerForCleanup(data.customer_id);
		return {
			customerId: data.customer_id,
			token: data.token,
			email: normalizedEmail,
			password
		};
	}

	throw new Error('createUser failed: exhausted retries after 429 rate limiting');
}

export async function fetchDisposableTenantRateCardSnapshot({
	apiUrl,
	adminKey,
	trackCustomerForCleanup,
	fetchImpl = fetch,
	seed
}: FetchDisposableTenantRateCardSnapshotParams): Promise<MarketingPricingContractSnapshot> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const snapshotSeed = seed ?? `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	const disposableUser = await createRegisteredUser({
		apiUrl: localApiUrl,
		email: `pricing-rate-card-${snapshotSeed}@e2e.griddle.test`,
		password: 'TestPassword123!',
		name: `Pricing Rate Card ${snapshotSeed}`,
		trackCustomerForCleanup,
		fetchImpl
	});
	const rateCardResponse = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'GET',
		`/admin/tenants/${encodeURIComponent(disposableUser.customerId)}/rate-card`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!rateCardResponse.ok) {
		throw new Error(
			`fetchDisposableTenantRateCardSnapshot failed: ${rateCardResponse.status} ${await rateCardResponse.text()}`
		);
	}
	const rateCard = (await rateCardResponse.json()) as AdminRateCard;
	return pricingContractSnapshotFromAdminRateCard(rateCard);
}

type LoginAsUserParams = {
	apiUrl: string;
	email: string;
	password: string;
	fetchImpl?: typeof fetch;
};

type LoginAsUserWithKnownMissingUserBootstrapParams = {
	apiUrl: string;
	email: string;
	password: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	contextLabel: string;
	fetchImpl?: typeof fetch;
	loginAsUserFn?: (params: LoginAsUserParams) => Promise<string>;
	bootstrapFn?: (
		params: BootstrapFixtureUserForKnownLoginFailureParams
	) => Promise<BootstrapFixtureUserForKnownLoginFailureResult>;
};

type BootstrapFixtureUserForKnownLoginFailureParams = {
	apiUrl: string;
	email: string;
	password: string;
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
	trackCustomerForCleanup?: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
};

type BootstrapFixtureUserForKnownLoginFailureResult = {
	bootstrapped: boolean;
	loginToken: string | null;
};

type FetchEstimatedBillForTokenParams = {
	apiUrl: string;
	token: string;
	month?: string;
	fetchImpl?: typeof fetch;
};

export async function loginAsUser({
	apiUrl,
	email,
	password,
	fetchImpl = fetch
}: LoginAsUserParams): Promise<string> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetchImpl,
			localApiUrl,
			'POST',
			'/auth/login',
			{},
			{
				email,
				password
			}
		);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`loginAs failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as AuthApiResponse;
		return data.token;
	}

	throw new Error('loginAs failed: exhausted retries after 429 rate limiting');
}

type ArrangeTrackedCustomerSessionForPageParams = {
	page: Page;
	options: ArrangeTrackedCustomerSessionOptions;
	createUser: CreateUserFn;
	loginAs: LoginAsFn;
	verifyCustomerEmail?: (email: string) => Promise<void>;
	forceCustomerEmailUnverified?: (email: string) => Promise<void>;
	setAuthCookie?: (page: Page, token: string) => Promise<void>;
	seed?: string;
};

/** Create a disposable customer, authenticate the page, and return its tracked identity. */
export async function arrangeTrackedCustomerSessionForPage({
	page,
	options,
	createUser,
	loginAs,
	verifyCustomerEmail = verifyTrackedCustomerEmailForRemote,
	forceCustomerEmailUnverified = forceTrackedCustomerEmailUnverifiedForLocal,
	setAuthCookie = setAuthCookieForToken,
	seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
}: ArrangeTrackedCustomerSessionForPageParams): Promise<CreatedFixtureUser> {
	const emailPrefix = requireNonEmptyString(
		options.emailPrefix,
		'arrangeTrackedCustomerSession requires a non-empty emailPrefix'
	);
	const password = options.password ?? 'TestPassword123!';
	const email = `${emailPrefix}-${seed}@e2e.griddle.test`;
	const name = options.name?.trim() || `E2E ${emailPrefix} ${seed}`;
	const createdUser = await createUser(email, password, name);
	if (options.verifyEmail !== false) {
		await verifyCustomerEmail(createdUser.email);
	} else {
		await forceCustomerEmailUnverified(createdUser.email);
	}
	const authToken = await loginAs(createdUser.email, password);
	await page.context().clearCookies();
	await setAuthCookie(page, authToken);
	return {
		...createdUser,
		token: authToken,
		password
	};
}

/**
 * Login for fixture flows and recover only the known missing-user seam by
 * bootstrapping the account through the existing helper contract.
 */
export async function loginAsUserWithKnownMissingUserBootstrap({
	apiUrl,
	email,
	password,
	trackCustomerForCleanup,
	contextLabel,
	fetchImpl = fetch,
	loginAsUserFn = loginAsUser,
	bootstrapFn = bootstrapFixtureUserForKnownLoginFailure
}: LoginAsUserWithKnownMissingUserBootstrapParams): Promise<string> {
	try {
		return await loginAsUserFn({ apiUrl, email, password, fetchImpl });
	} catch (error) {
		const loginFailureDetails = setupFailureDetailsFromError(error);
		const loginStatusMatch = loginFailureDetails.match(/\bloginAs failed:\s*(\d{3})\b/i);
		const loginStatus = loginStatusMatch ? Number(loginStatusMatch[1]) : 0;
		if (
			(loginStatus !== 400 && loginStatus !== 401) ||
			!FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN.test(loginFailureDetails)
		) {
			throw error;
		}

		const bootstrap = await bootstrapFn({
			apiUrl,
			email,
			password,
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			responseStatus: loginStatus,
			responseUrl: `${apiUrl}/auth/login`,
			trackCustomerForCleanup,
			fetchImpl
		});
		if (bootstrap.loginToken) {
			return bootstrap.loginToken;
		}

		throw new Error(
			`${contextLabel} failed to re-authenticate after known missing-user bootstrap`,
			{ cause: error }
		);
	}
}

function isKnownFixtureCustomerMissingLoginFailure({
	currentPath,
	alertText,
	responseStatus,
	responseUrl
}: {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
}): boolean {
	const onLoginPage = currentPath.includes('/login');
	const invalidCredentialsMessage = FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN.test(
		alertText?.trim() ?? ''
	);
	// Browser form posts surface `/login` while direct API fixtures surface
	// `/auth/login`; both represent the same invalid-credentials path.
	const knownApiFailureSurface =
		(responseStatus === 400 || responseStatus === 401) &&
		Boolean(responseUrl?.includes('/auth/login') || responseUrl?.includes('/login'));
	const browserOnlyFailureSurface = responseStatus === undefined && responseUrl === undefined;
	return (
		onLoginPage &&
		invalidCredentialsMessage &&
		(knownApiFailureSurface || browserOnlyFailureSurface)
	);
}

/** Bootstrap fixture credentials only when the known missing-user login failure occurs. */
export async function bootstrapFixtureUserForKnownLoginFailure({
	apiUrl,
	email,
	password,
	currentPath,
	alertText,
	responseStatus,
	responseUrl,
	trackCustomerForCleanup = IGNORE_TRACKED_FIXTURE_CUSTOMER_ID,
	fetchImpl = fetch
}: BootstrapFixtureUserForKnownLoginFailureParams): Promise<BootstrapFixtureUserForKnownLoginFailureResult> {
	if (
		!isKnownFixtureCustomerMissingLoginFailure({
			currentPath,
			alertText,
			responseStatus,
			responseUrl
		})
	) {
		return {
			bootstrapped: false,
			loginToken: null
		};
	}

	try {
		await createRegisteredUser({
			apiUrl,
			email,
			password,
			trackCustomerForCleanup,
			fetchImpl
		});
	} catch (error) {
		const details = setupFailureDetailsFromError(error);
		// Idempotency boundary: if another process already created this fixture
		// account, proceed to login instead of failing setup on 409.
		if (!details.includes('createUser failed: 409')) {
			throw error;
		}
	}

	const loginToken = await loginAsUser({
		apiUrl,
		email,
		password,
		fetchImpl
	});

	return {
		bootstrapped: true,
		loginToken
	};
}

/** Fetch the authenticated customer's estimated bill, returning null on 404. */
export async function fetchEstimatedBillForToken({
	apiUrl,
	token,
	month,
	fetchImpl = fetch
}: FetchEstimatedBillForTokenParams): Promise<EstimatedBillResponse | null> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const query = month ? `?month=${encodeURIComponent(month)}` : '';
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt += 1) {
		const res = await fetchImpl(`${localApiUrl}/billing/estimate${query}`, {
			method: 'GET',
			headers: {
				Authorization: `Bearer ${token}`
			}
		});
		if (res.ok) {
			return (await res.json()) as EstimatedBillResponse;
		}
		// 404 means no estimate data exists yet — genuine absence
		if (res.status === 404) {
			return null;
		}
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		// Auth failures (401/403) and server errors (5xx) must surface immediately.
		throw new Error(`/billing/estimate failed: ${res.status} ${await res.text()}`);
	}

	throw new Error('/billing/estimate failed: exhausted retries after 429 rate limiting');
}

type CreateUserFactory = (
	email: string,
	password: string,
	name?: string
) => Promise<CreatedFixtureUser>;

type SeedMultiUserScenarioWithCreateUserParams = {
	createUser: CreateUserFactory;
	password?: string;
	uniqueId?: string;
};

/** Create two uniquely-named users for cross-customer workflows. */
export async function seedMultiUserScenarioWithCreateUser({
	createUser,
	password = 'TestPassword123!',
	uniqueId
}: SeedMultiUserScenarioWithCreateUserParams): Promise<{
	primaryUser: CreatedFixtureUser;
	secondaryUser: CreatedFixtureUser;
}> {
	const seed = uniqueId ?? `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	const primaryEmail = `multi-user-primary-${seed}@e2e.griddle.test`;
	const secondaryEmail = `multi-user-secondary-${seed}@e2e.griddle.test`;

	const [primaryUser, secondaryUser] = await Promise.all([
		createUser(primaryEmail, password, `Multi User Primary ${seed}`),
		createUser(secondaryEmail, password, `Multi User Secondary ${seed}`)
	]);

	return { primaryUser, secondaryUser };
}

type AdminReactivateCustomerByIdParams = {
	apiUrl: string;
	customerId: string;
	adminKey?: string;
	fetchImpl?: typeof fetch;
};

type AdminSuspendCustomerByIdParams = {
	apiUrl: string;
	customerId: string;
	adminKey?: string;
	fetchImpl?: typeof fetch;
};

export async function adminReactivateCustomerById({
	apiUrl,
	customerId,
	adminKey,
	fetchImpl = fetch
}: AdminReactivateCustomerByIdParams): Promise<void> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedCustomerId = requireNonEmptyString(
		customerId,
		'adminReactivateCustomerById requires a non-empty customerId'
	);
	const res = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'POST',
		`/admin/customers/${encodeURIComponent(normalizedCustomerId)}/reactivate`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!res.ok) {
		throw new Error(`adminReactivateCustomer failed: ${res.status} ${await res.text()}`);
	}
}

export async function adminSuspendCustomerById({
	apiUrl,
	customerId,
	adminKey,
	fetchImpl = fetch
}: AdminSuspendCustomerByIdParams): Promise<void> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedCustomerId = requireNonEmptyString(
		customerId,
		'adminSuspendCustomerById requires a non-empty customerId'
	);
	const res = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'POST',
		`/admin/customers/${encodeURIComponent(normalizedCustomerId)}/suspend`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!res.ok) {
		throw new Error(`adminSuspendCustomer failed: ${res.status} ${await res.text()}`);
	}
}

async function getAuthToken(): Promise<string> {
	if (_token) return _token;
	const { email, password } = resolveRequiredFixtureUserCredentials(process.env);
	const maxRetries = 10;
	let lastTransportFailure = '';
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		let res: Response;
		try {
			res = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'POST',
				'/auth/login',
				{},
				{
					email,
					password
				}
			);
		} catch (error) {
			if (!isTransientTransportFailure(error) || attempt === maxRetries - 1) {
				throw error;
			}
			lastTransportFailure = setupFailureDetailsFromError(error);
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status === 429) {
			const retryAfterSeconds = Number(res.headers.get('retry-after') ?? '');
			const retryAfterMs =
				Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
			await sleep(Math.max(retryAfterMs, getTransientRetryDelayMs(attempt)));
			continue;
		}
		if (!res.ok) {
			throw new Error(`Auth login failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as { token: string };
		_token = data.token;
		return _token;
	}

	if (lastTransportFailure) {
		throw new Error(`Auth login failed after transient transport retries: ${lastTransportFailure}`);
	}
	throw new Error('Auth login failed: exhausted retries after 429 rate limiting');
}

async function getAccountPayloadForTokenWithRetries(
	token: string,
	contextLabel: string
): Promise<{ id?: string; billing_plan?: 'free' | 'shared' }> {
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	let lastTransientFailure = 'none';
	const currentToken = token;

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const accountResponse = await callJsonApi(fetch, fixtureEnv.apiUrl, 'GET', '/account', {
			Authorization: `Bearer ${currentToken}`
		});
		if (accountResponse.ok) {
			return (await accountResponse.json()) as { id?: string; billing_plan?: 'free' | 'shared' };
		}

		const failureDetails = `${accountResponse.status} ${await accountResponse.text()}`;
		if (accountResponse.status === 401 || accountResponse.status === 403) {
			throw new FixtureAuthTokenInvalidError(accountResponse.status, failureDetails);
		}
		if (!isTransientAccountLookupFailure(accountResponse.status)) {
			throw new Error(`${contextLabel} failed: ${failureDetails}`);
		}

		lastTransientFailure = failureDetails;
		if (attempt < maxRetries - 1) {
			await sleep(getRetryDelayMs(attempt, accountResponse.headers.get('retry-after')));
		}
	}

	throw new Error(`${contextLabel} failed after transient retries: ${lastTransientFailure}`);
}

function invalidateCachedAuthToken(): void {
	_token = null;
}

/**
 * Resolve the shared fixture customer id, refreshing the cached bearer token
 * once if /account rejects it with 401/403 (e.g. after a local API restart).
 */
async function getCustomerId(): Promise<string> {
	if (_customerId) return _customerId;
	let token = await getAuthToken();
	let accountPayload: { id?: string; billing_plan?: 'free' | 'shared' };

	try {
		accountPayload = await getAccountPayloadForTokenWithRetries(token, 'GET /account');
	} catch (error) {
		if (!(error instanceof Error) || !error.message.includes('GET /account failed: 401')) {
			throw error;
		}

		_token = null;
		token = await getAuthToken();
		accountPayload = await getAccountPayloadForTokenWithRetries(
			token,
			'GET /account after token refresh'
		);
	}

	_customerId = requireNonEmptyString(
		accountPayload.id ?? '',
		'GET /account returned an empty customer id'
	);
	return _customerId;
}

/**
 * Make a bearer-authenticated fixture API call. When no explicit tokenOverride
 * is provided, a stale cached token surfacing as 401/403 is invalidated and the
 * call is retried once with a fresh login token — so every authenticated
 * fixture helper (cleanupStaleFixtureIndexesOnce, waitForSeededIndex, etc.)
 * recovers from in-process token expiry without per-helper logic.
 */
async function apiCall(
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
): Promise<Response> {
	const invokeWithToken = (token: string): Promise<Response> =>
		callJsonApi(fetch, fixtureEnv.apiUrl, method, path, { Authorization: `Bearer ${token}` }, body);

	if (tokenOverride !== undefined) {
		return invokeWithToken(tokenOverride);
	}

	return callWithBearerTokenRefreshOnResponse({
		getToken: getAuthToken,
		invalidateToken: invalidateCachedAuthToken,
		invoke: invokeWithToken
	});
}

async function saveSynonymWithFixtureApi(
	indexName: string,
	synonym: Synonym,
	tokenOverride?: string
): Promise<void> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'PUT',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/${encodeURIComponent(synonym.objectID)}`,
			synonym,
			tokenOverride
		);
		if (response.ok) {
			return;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`saveSynonym failed: ${response.status} ${responseText}`);
	}
	throw new Error('saveSynonym failed: retries exhausted');
}

async function getSynonymWithFixtureApi(
	indexName: string,
	objectID: string,
	tokenOverride?: string
): Promise<Synonym | null> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/${encodeURIComponent(objectID)}`,
			undefined,
			tokenOverride
		);
		if (response.status === 404) {
			return null;
		}
		if (response.ok) {
			return (await response.json()) as Synonym;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`getSynonym failed: ${response.status} ${responseText}`);
	}
	throw new Error('getSynonym failed: retries exhausted');
}

async function searchSynonymsWithFixtureApi(
	indexName: string,
	query = '',
	tokenOverride?: string
): Promise<SynonymSearchResponse> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'POST',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/search`,
			{
				query,
				page: 0,
				hitsPerPage: 50
			},
			tokenOverride
		);
		if (response.ok) {
			return (await response.json()) as SynonymSearchResponse;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`searchSynonyms failed: ${response.status} ${responseText}`);
	}
	throw new Error('searchSynonyms failed: retries exhausted');
}

async function clearSynonymsWithFixtureApi(
	indexName: string,
	tokenOverride?: string
): Promise<void> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'POST',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/clear`,
			undefined,
			tokenOverride
		);
		if (response.ok) {
			return;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`clearSynonyms failed: ${response.status} ${responseText}`);
	}
	throw new Error('clearSynonyms failed: retries exhausted');
}

async function saveQsConfigWithFixtureApi(
	indexName: string,
	config: QsConfig,
	tokenOverride?: string
): Promise<void> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'PUT',
			`/indexes/${encodeURIComponent(indexName)}/suggestions`,
			config,
			tokenOverride
		);
		if (response.ok) {
			return;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`saveQsConfig failed: ${response.status} ${responseText}`);
	}
	throw new Error('saveQsConfig failed: retries exhausted');
}

async function getQsConfigWithFixtureApi(
	indexName: string,
	tokenOverride?: string
): Promise<QsConfig | null> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(indexName)}/suggestions`,
			undefined,
			tokenOverride
		);
		if (response.status === 404) {
			return null;
		}
		if (response.ok) {
			return (await response.json()) as QsConfig;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`getQsConfig failed: ${response.status} ${responseText}`);
	}
	throw new Error('getQsConfig failed: retries exhausted');
}

async function getQsStatusWithFixtureApi(
	indexName: string,
	tokenOverride?: string
): Promise<QsBuildStatus | null> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(indexName)}/suggestions/status`,
			undefined,
			tokenOverride
		);
		if (response.status === 404) {
			return null;
		}
		if (response.ok) {
			return (await response.json()) as QsBuildStatus;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`getQsStatus failed: ${response.status} ${responseText}`);
	}
	throw new Error('getQsStatus failed: retries exhausted');
}

function normalizeProofObjectIDs(objectIDs: string[]): string[] {
	const normalized = objectIDs.map((value) => value.trim()).filter((value) => value.length > 0);
	return Array.from(new Set(normalized));
}

function resolveSynonymsProofManifestPath(manifestPath?: string): string {
	const selectedPath = manifestPath?.trim() || STAGE5_SYNONYMS_PROOF_MANIFEST_PATH;
	return path.resolve(process.cwd(), selectedPath);
}

async function writeSynonymsProofManifest({
	indexName,
	objectIDs,
	manifestPath
}: WriteSynonymsProofManifestInput): Promise<void> {
	const manifest = {
		indexName,
		objectIDs: normalizeProofObjectIDs(objectIDs),
		cleanup: {
			method: 'DELETE' as const,
			path: `/indexes/${encodeURIComponent(indexName)}`,
			body: { confirm: true as const }
		},
		generatedAt: new Date().toISOString(),
		consumed: false
	} satisfies SynonymsProofManifest;
	const absolutePath = resolveSynonymsProofManifestPath(manifestPath);
	await mkdir(path.dirname(absolutePath), { recursive: true });
	await writeFile(absolutePath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
}

async function adminApiCall(method: string, path: string, body?: unknown): Promise<Response> {
	let lastResponse: Response | null = null;
	let lastTransportFailure = '';

	for (let attempt = 0; attempt < 10; attempt += 1) {
		let response: Response;
		try {
			response = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				method,
				path,
				{ 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) },
				body
			);
		} catch (error) {
			if (!isTransientTransportFailure(error) || attempt === 9) {
				throw error;
			}
			lastTransportFailure = setupFailureDetailsFromError(error);
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}

		if (response.status !== 429) {
			return response;
		}

		lastResponse = response;
		if (attempt === 9) {
			break;
		}

		await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
	}

	if (lastTransportFailure) {
		throw new Error(
			`adminApiCall transport retries exhausted for ${method} ${path}: ${lastTransportFailure}`
		);
	}
	return lastResponse ?? new Response('adminApiCall exhausted without a response', { status: 500 });
}

async function readAdminSessionCookie(page: Page): Promise<string> {
	const adminSessionCookie = (await page.context().cookies()).find(
		(cookie) => cookie.name === ADMIN_SESSION_COOKIE
	);
	const sessionToken = adminSessionCookie?.value?.trim() ?? '';
	return requireNonEmptyString(
		sessionToken,
		`isolated admin browser session missing ${ADMIN_SESSION_COOKIE} cookie`
	);
}

async function revokeAdminSessionToken(sessionToken: string): Promise<void> {
	const response = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'DELETE',
		'/admin/sessions/current',
		{ 'x-admin-session': sessionToken }
	);
	if (!response.ok) {
		throw new Error(`admin session revocation failed: ${response.status} ${await response.text()}`);
	}
}

async function loginIsolatedAdminPage(page: Page): Promise<void> {
	await page.goto('/admin/login');
	await expect(page.getByRole('heading', { name: 'Admin Login' })).toBeVisible();
	await page.getByLabel('Admin Key').fill(requireAdminApiKey(fixtureEnv.adminKey));
	await Promise.all([
		page.waitForURL(/\/admin\/fleet$/),
		page.getByRole('button', { name: 'Log In' }).click()
	]);
	await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
}

async function raiseRemoteSeededIndexWriteQuota(customerId: string): Promise<void> {
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1') {
		return;
	}

	const res = await adminApiCall('PUT', `/admin/tenants/${encodeURIComponent(customerId)}/quotas`, {
		max_write_rps: REMOTE_SEEDED_INDEX_WRITE_RPS
	});
	if (res.ok) {
		return;
	}

	throw new Error(`remote seed quota uplift failed: ${res.status} ${await res.text()}`);
}

async function deleteTrackedCustomerForCleanup(customerId: string): Promise<void> {
	const response = await adminApiCall('DELETE', `/admin/tenants/${encodeURIComponent(customerId)}`);
	if (response.status === 404) {
		return;
	}
	if (response.status === 401) {
		// Remote staging runs can intentionally omit admin credentials for browser-only
		// seam proofs. Preserve test signal from the assertions and skip tenant teardown
		// instead of failing after spec execution on an admin-only prerequisite.
		return;
	}
	if (!response.ok) {
		throw new Error(
			`tracked fixture customer cleanup failed for ${customerId}: ${response.status} ${await response.text()}`
		);
	}
}

async function seedAdminDeploymentForCustomer(
	customer: CreatedFixtureUser,
	options?: AdminDeploymentSeedOptions
): Promise<AdminDeploymentFixture> {
	const region = options?.region ?? fixtureEnv.testRegion;
	const provider = options?.provider ?? 'local';
	const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const output = runFixtureSql(
		`
INSERT INTO customer_deployments (
    customer_id,
    node_id,
    region,
    vm_type,
    vm_provider,
    ip_address,
    status,
    provider_vm_id,
    hostname,
    flapjack_url,
    health_status
)
VALUES (
    ${quoteSqlLiteral(customer.customerId)}::uuid,
    ${quoteSqlLiteral(`e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(region)},
    'e2e.small',
    ${quoteSqlLiteral(provider)},
    '127.0.0.1',
    'running',
    ${quoteSqlLiteral(`${provider}:e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(`e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(fixtureEnv.flapjackUrl)},
    'healthy'
			)
RETURNING id::text || '|' || region || '|' || vm_provider || '|' || status;
	`,
		`seed admin deployment for ${customer.customerId}`
	);
	const [id, returnedRegion, returnedProvider, status] = output.split('|');
	if (
		!id ||
		!returnedRegion ||
		(returnedProvider !== 'aws' && returnedProvider !== 'local') ||
		!status
	) {
		throw new Error(`seed admin deployment returned an unexpected row: ${output}`);
	}
	return { id, region: returnedRegion, provider: returnedProvider, status };
}

const ADMIN_VM_TIMELINE_DEAD_VM_ID = '00000000-0000-4000-8000-00000000d001';
const ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID = '00000000-0000-4000-8000-00000000d002';
const ADMIN_VM_TIMELINE_DEAD_HOSTNAME = 'e2e-admin-vm-timeline-dead.local';
const ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME = 'e2e-admin-vm-timeline-replacement.local';
const ADMIN_VM_TIMELINE_REGION = 'e2e-admin-vm-timeline-local';
const ADMIN_VM_TIMELINE_MARKER = 'admin_vm_timeline';
const ADMIN_VM_TIMELINE_EVENTS: AdminVmLifecycleTimelineEventExpectation[] = [
	{
		id: '00000000-0000-4000-8000-00000000d101',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'detected_dead',
		label: 'Detected dead',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			dead_hostname: ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
			provider: 'local',
			provider_vm_id: 'local:e2e-admin-vm-timeline-dead',
			region: ADMIN_VM_TIMELINE_REGION
		},
		createdAt: '2026-02-22T10:00:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:00:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d101',
		expectedDetailText: [
			'Dead hostname',
			ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
			'Provider',
			'local',
			'Provider VM ID',
			'local:e2e-admin-vm-timeline-dead',
			'Region',
			ADMIN_VM_TIMELINE_REGION
		]
	},
	{
		id: '00000000-0000-4000-8000-00000000d102',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'replacement_refused',
		label: 'Replacement refused',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			guardrail: 'kill_switch_disabled',
			planned_replacement_hostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		},
		createdAt: '2026-02-22T10:01:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:01:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d102',
		expectedDetailText: [
			'Guardrail',
			'kill_switch_disabled',
			'Planned replacement hostname',
			ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		]
	},
	{
		id: '00000000-0000-4000-8000-00000000d103',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'replacement_provisioning',
		label: 'Replacement provisioning',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			dead_hostname: ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
			provider: 'local',
			provider_vm_id: 'local:e2e-admin-vm-timeline-replacement',
			region: ADMIN_VM_TIMELINE_REGION,
			planned_replacement_hostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		},
		createdAt: '2026-02-22T10:02:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:02:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d103',
		expectedDetailText: [
			'Dead hostname',
			ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
			'Provider',
			'local',
			'Provider VM ID',
			'local:e2e-admin-vm-timeline-replacement',
			'Region',
			ADMIN_VM_TIMELINE_REGION,
			'Planned replacement hostname',
			ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		]
	},
	{
		id: '00000000-0000-4000-8000-00000000d104',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'replacement_booted',
		label: 'Replacement booted',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			replacement_vm_id: ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID,
			replacement_hostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		},
		createdAt: '2026-02-22T10:03:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:03:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d104',
		expectedDetailText: [],
		replacementLink: {
			testId: 'vm-lifecycle-replacement-link-00000000-0000-4000-8000-00000000d104',
			href: `/admin/fleet/${ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID}`,
			text: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		}
	},
	{
		id: '00000000-0000-4000-8000-00000000d105',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'tenants_replaced',
		label: 'Tenants replaced',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			replacement_vm_id: ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID,
			replacement_hostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		},
		createdAt: '2026-02-22T10:04:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:04:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d105',
		expectedDetailText: [],
		replacementLink: {
			testId: 'vm-lifecycle-replacement-link-00000000-0000-4000-8000-00000000d105',
			href: `/admin/fleet/${ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID}`,
			text: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		}
	},
	{
		id: '00000000-0000-4000-8000-00000000d106',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'replacement_failed',
		label: 'Replacement failed',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			retryable: true,
			failure_phase: 'provisioning',
			failure_reason: 'provider returned retryable local quota error'
		},
		createdAt: '2026-02-22T10:05:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:05:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d106',
		expectedDetailText: [
			'Failure phase',
			'provisioning',
			'Failure reason',
			'provider returned retryable local quota error'
		]
	},
	{
		id: '00000000-0000-4000-8000-00000000d107',
		vmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		eventType: 'replacement_completed',
		label: 'Replacement completed',
		detail: {
			e2e_fixture: ADMIN_VM_TIMELINE_MARKER,
			replacement_vm_id: ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID,
			replacement_hostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		},
		createdAt: '2026-02-22T10:06:00Z',
		formattedCreatedAt: formatDateTime('2026-02-22T10:06:00Z'),
		rowTestId: 'vm-lifecycle-row-00000000-0000-4000-8000-00000000d107',
		expectedDetailText: [],
		replacementLink: {
			testId: 'vm-lifecycle-replacement-link-00000000-0000-4000-8000-00000000d107',
			href: `/admin/fleet/${ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID}`,
			text: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME
		}
	}
];

type ApiVmLifecycleEvent = {
	id: string;
	vm_id: string;
	event_type: AdminVmLifecycleTimelineEventType;
	detail: Record<string, unknown>;
	created_at: string;
};

function assertAdminVmLifecycleEvents(actual: ApiVmLifecycleEvent[], context: string): void {
	expect(
		actual.map((event) => ({
			id: event.id,
			vm_id: event.vm_id,
			event_type: event.event_type,
			detail: event.detail,
			created_at: event.created_at
		}))
	).toEqual(
		ADMIN_VM_TIMELINE_EVENTS.map((event) => ({
			id: event.id,
			vm_id: event.vmId,
			event_type: event.eventType,
			detail: event.detail,
			created_at: event.createdAt
		}))
	);
	if (actual.length !== ADMIN_VM_TIMELINE_EVENTS.length) {
		throw new Error(`${context} returned ${actual.length} lifecycle events`);
	}
}

function parseFixtureJsonRows<T>(output: string, context: string): T {
	try {
		return JSON.parse(output) as T;
	} catch (error) {
		throw new Error(`${context} returned invalid JSON: ${output}. Error: ${error}`, {
			cause: error
		});
	}
}

function seedAdminVmLifecycleTimelineSql(): void {
	const flapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', fixtureEnv.flapjackUrl);
	const quotedCapacity = quoteSqlLiteral(LOCAL_VM_CAPACITY_JSON);
	const quotedCurrentLoad = quoteSqlLiteral(LOCAL_VM_CURRENT_LOAD_JSON);
	const eventValues = ADMIN_VM_TIMELINE_EVENTS.map(
		(event) =>
			`(${quoteSqlLiteral(event.id)}::uuid, ${quoteSqlLiteral(event.vmId)}::uuid, ${quoteSqlLiteral(
				event.eventType
			)}, ${quoteSqlLiteral(JSON.stringify(event.detail))}::jsonb, ${quoteSqlLiteral(
				event.createdAt
			)}::timestamptz)`
	).join(',\n    ');

	runFixtureSql(
		`
	INSERT INTO vm_inventory (
	    id,
	    provider,
	    hostname,
    flapjack_url,
    region,
    capacity,
    current_load,
    status,
    load_scraped_at,
    created_at,
    updated_at
)
VALUES
    (
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_DEAD_VM_ID)}::uuid,
        'local',
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_DEAD_HOSTNAME)},
        ${quoteSqlLiteral(flapjackUrl)},
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_REGION)},
        ${quotedCapacity}::jsonb,
        ${quotedCurrentLoad}::jsonb,
        'decommissioned',
        NOW(),
        '2026-02-22T09:55:00Z'::timestamptz,
        NOW()
    ),
    (
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID)}::uuid,
        'local',
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME)},
        ${quoteSqlLiteral(flapjackUrl)},
        ${quoteSqlLiteral(ADMIN_VM_TIMELINE_REGION)},
        ${quotedCapacity}::jsonb,
        ${quotedCurrentLoad}::jsonb,
        'active',
        NOW(),
        '2026-02-22T10:03:00Z'::timestamptz,
        NOW()
    )
ON CONFLICT (id) DO UPDATE
SET provider = EXCLUDED.provider,
    hostname = EXCLUDED.hostname,
    flapjack_url = EXCLUDED.flapjack_url,
    region = EXCLUDED.region,
    capacity = EXCLUDED.capacity,
    current_load = EXCLUDED.current_load,
    status = EXCLUDED.status,
    load_scraped_at = EXCLUDED.load_scraped_at,
    updated_at = NOW();

INSERT INTO vm_lifecycle_events (id, vm_id, event_type, detail, created_at)
VALUES
    ${eventValues}
ON CONFLICT (id) DO NOTHING;
`,
		'seed admin VM lifecycle timeline'
	);

	const seededRows = parseFixtureJsonRows<ApiVmLifecycleEvent[]>(
		runFixtureSql(
			`
SELECT COALESCE(
    jsonb_agg(
        jsonb_build_object(
            'id', id::text,
            'vm_id', vm_id::text,
            'event_type', event_type,
            'detail', detail,
            'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
        ORDER BY created_at ASC, id ASC
    ),
    '[]'::jsonb
)::text
FROM vm_lifecycle_events
WHERE id IN (${ADMIN_VM_TIMELINE_EVENTS.map((event) => `${quoteSqlLiteral(event.id)}::uuid`).join(', ')});
`,
			'verify admin VM lifecycle timeline rows'
		),
		'verify admin VM lifecycle timeline rows'
	);
	assertAdminVmLifecycleEvents(seededRows, 'seeded admin VM lifecycle SQL verification');
}

async function seedAdminVmLifecycleTimelineForFixture(): Promise<AdminVmLifecycleTimelineFixture> {
	seedAdminVmLifecycleTimelineSql();

	const adminHeaders = { 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) };
	const deadVmResponse = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/admin/vms/${ADMIN_VM_TIMELINE_DEAD_VM_ID}`,
		adminHeaders
	);
	if (!deadVmResponse.ok) {
		throw new Error(
			`seedAdminVmLifecycleTimeline /admin/vms/${ADMIN_VM_TIMELINE_DEAD_VM_ID} failed: ${deadVmResponse.status} ${await deadVmResponse.text()}`
		);
	}
	const deadVmDetail = (await deadVmResponse.json()) as {
		vm: { id: string; hostname: string; status: string };
	};
	expect(deadVmDetail.vm).toMatchObject({
		id: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		hostname: ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
		status: 'decommissioned'
	});

	const deadEventsResponse = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/admin/vms/${ADMIN_VM_TIMELINE_DEAD_VM_ID}/lifecycle-events`,
		adminHeaders
	);
	if (!deadEventsResponse.ok) {
		throw new Error(
			`seedAdminVmLifecycleTimeline dead lifecycle API failed: ${deadEventsResponse.status} ${await deadEventsResponse.text()}`
		);
	}
	assertAdminVmLifecycleEvents(
		(await deadEventsResponse.json()) as ApiVmLifecycleEvent[],
		'seedAdminVmLifecycleTimeline dead lifecycle API'
	);

	const replacementEventsResponse = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/admin/vms/${ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID}/lifecycle-events`,
		adminHeaders
	);
	if (!replacementEventsResponse.ok) {
		throw new Error(
			`seedAdminVmLifecycleTimeline replacement lifecycle API failed: ${replacementEventsResponse.status} ${await replacementEventsResponse.text()}`
		);
	}
	expect(await replacementEventsResponse.json()).toEqual([]);

	return {
		deadVmId: ADMIN_VM_TIMELINE_DEAD_VM_ID,
		replacementVmId: ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID,
		deadHostname: ADMIN_VM_TIMELINE_DEAD_HOSTNAME,
		replacementHostname: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME,
		events: ADMIN_VM_TIMELINE_EVENTS,
		expectedGuardrailLabel: 'Guardrail',
		expectedGuardrailText: 'kill_switch_disabled',
		expectedReplacementHref: `/admin/fleet/${ADMIN_VM_TIMELINE_REPLACEMENT_VM_ID}`,
		expectedReplacementText: ADMIN_VM_TIMELINE_REPLACEMENT_HOSTNAME,
		fixtureMarker: ADMIN_VM_TIMELINE_MARKER,
		emptyStateCopy: 'No lifecycle events recorded for this VM.'
	};
}

async function readAdminVmHostMetricsEvidenceForFixture({
	region,
	vmId
}: ReadAdminVmHostMetricsEvidenceParams): Promise<AdminVmHostMetricsEvidence> {
	const vmsResponse = await callJsonApi(fetch, fixtureEnv.apiUrl, 'GET', '/admin/vms', {
		'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey)
	});
	if (!vmsResponse.ok) {
		throw new Error(
			`readAdminVmHostMetricsEvidence /admin/vms failed: ${vmsResponse.status} ${await vmsResponse.text()}`
		);
	}
	const vms = (await vmsResponse.json()) as VmInventoryItem[];
	const resolvedVmId = vmId ?? resolveAdminVmIdFromRegion(vms, region);
	if (!vms.some((vm) => vm.id === resolvedVmId)) {
		throw new Error(
			`readAdminVmHostMetricsEvidence could not find VM ${resolvedVmId} in /admin/vms`
		);
	}

	const metricsResponse = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/admin/vms/${encodeURIComponent(resolvedVmId)}/host-metrics`,
		{ 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) }
	);
	if (!metricsResponse.ok) {
		throw new Error(
			`readAdminVmHostMetricsEvidence /admin/vms/${resolvedVmId}/host-metrics failed: ${metricsResponse.status} ${await metricsResponse.text()}`
		);
	}
	const metrics = (await metricsResponse.json()) as VmHostMetricsResponse | null;
	if (metrics && metrics.vm_id !== resolvedVmId) {
		throw new Error(
			`readAdminVmHostMetricsEvidence expected vm_id ${resolvedVmId}, got ${metrics.vm_id}`
		);
	}
	return { vmId: resolvedVmId, metrics };
}

function resolveAdminVmIdFromRegion(vms: VmInventoryItem[], region: string | undefined): string {
	const safeRegion = requireNonEmptyString(
		region ?? '',
		'readAdminVmHostMetricsEvidence requires region when vmId is omitted'
	);
	const expectedHostname = `local-dev-${safeRegion}`;
	const matches = vms.filter((vm) => vm.hostname === expectedHostname);
	if (matches.length !== 1) {
		throw new Error(
			`readAdminVmHostMetricsEvidence expected exactly one ${expectedHostname} VM, found ${matches.length}`
		);
	}
	return matches[0].id;
}

async function runTrackedIndexCleanup(
	useTrackedIndexCleanup: (
		trackIndexForCleanup: (name: string, options?: RegisterIndexCleanupOptions) => void
	) => Promise<void>,
	deps?: RunTrackedIndexCleanupDeps
): Promise<void> {
	const apiCallForCleanup = deps?.apiCall ?? apiCall;
	const created = new Map<string, RegisterIndexCleanupOptions>();
	await useTrackedIndexCleanup((name: string, options?: RegisterIndexCleanupOptions) => {
		const trimmed = name.trim();
		if (!trimmed) return;
		const previous = created.get(trimmed);
		created.set(trimmed, {
			deferCleanup: Boolean(previous?.deferCleanup || options?.deferCleanup)
		});
	});

	for (const [name, options] of created) {
		if (options.deferCleanup) {
			continue;
		}
		await apiCallForCleanup('DELETE', `/indexes/${encodeURIComponent(name)}`, {
			confirm: true
		}).catch(() => {
			/* ignore — may already be gone */
		});
	}
}

async function runTrackedCustomerCleanup(
	useTrackedCustomerCleanup: (
		trackCustomerForCleanup: (customerId: string) => void
	) => Promise<void>,
	deps?: RunTrackedCustomerCleanupDeps
): Promise<void> {
	const deleteCustomerForCleanup =
		deps?.deleteTrackedCustomerForCleanup ?? deleteTrackedCustomerForCleanup;
	const created = new Set<string>();
	let bodyFailure: unknown;
	try {
		await useTrackedCustomerCleanup((customerId: string) => {
			const trimmed = customerId.trim();
			if (!trimmed) return;
			created.add(trimmed);
		});
	} catch (error) {
		bodyFailure = error;
	}

	const cleanupFailures: unknown[] = [];
	for (const customerId of created) {
		try {
			await deleteCustomerForCleanup(customerId);
		} catch (error) {
			cleanupFailures.push(error);
		}
	}

	if (bodyFailure && cleanupFailures.length > 0) {
		throw new AggregateError(
			[bodyFailure, ...cleanupFailures],
			'tracked fixture customer cleanup failed after fixture body failure'
		);
	}
	if (bodyFailure) {
		throw bodyFailure;
	}
	if (cleanupFailures.length === 1) {
		throw cleanupFailures[0];
	}
	if (cleanupFailures.length > 1) {
		throw new AggregateError(cleanupFailures, 'tracked fixture customer cleanup failed');
	}
}

function resetStaleFixtureIndexCleanupState(): void {
	_staleFixtureIndexesCleaned = false;
	_staleFixtureIndexesCleanupCooldownUntil = 0;
}

function getStaleFixtureIndexCleanupState(): StaleFixtureIndexCleanupState {
	return {
		cleaned: _staleFixtureIndexesCleaned,
		cooldownUntil: _staleFixtureIndexesCleanupCooldownUntil
	};
}

function extractVisibleSvgTextBoxes(svgs: SVGSVGElement[]): SvgTextBox[] {
	const textNodes = Array.from(
		new Set(svgs.flatMap((svg) => Array.from(svg.querySelectorAll('text'))))
	);
	return textNodes
		.map((node, index) => {
			const rect = node.getBoundingClientRect();
			return {
				index,
				text: (node.textContent ?? '').trim(),
				left: rect.left,
				top: rect.top,
				right: rect.right,
				bottom: rect.bottom,
				width: rect.width,
				height: rect.height
			};
		})
		.filter((box) => box.text.length > 0 && box.width > 0 && box.height > 0);
}

export const __fixtureTestSeams = {
	cleanupStaleFixtureIndexesOnce,
	createSeededIndexViaCustomerToken,
	ensureLocalSharedVmInventoryForRegion,
	extractVisibleSvgTextBoxes,
	getStaleFixtureIndexCleanupState,
	loginConfirmsFreshSignupAlreadyVerified,
	reconcileIndexPrimaryVmTelemetry,
	resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel,
	resolveFixtureContractPath,
	resetStaleFixtureIndexCleanupState,
	restorePublicInfrastructureCanaryVm,
	runTrackedCustomerCleanup,
	runTrackedIndexCleanup,
	seedPublicInfrastructureCanaryVm,
	shouldVerifyTrackedCustomerEmailViaStaging
};

function isStaleFixtureIndexName(name: string): boolean {
	return STALE_FIXTURE_INDEX_PREFIXES.some((prefix) => name.startsWith(prefix));
}

function assertDeferredProofIndexAvoidsStalePrefixes(name: string): void {
	const stalePrefix = STALE_FIXTURE_INDEX_PREFIXES.find((prefix) => name.startsWith(prefix));
	if (!stalePrefix) {
		return;
	}
	throw new Error(
		`seedIndex deferCleanup index name must avoid stale cleanup prefixes (matched "${stalePrefix}")`
	);
}

async function cleanupStaleFixtureIndexesOnce(
	options?: CleanupStaleFixtureIndexesOnceOptions
): Promise<void> {
	const forceCleanup = options?.force === true;
	const apiCallForCleanup = options?.apiCall ?? apiCall;
	const now = options?.now ?? Date.now;
	const sleepForCleanup = options?.sleep ?? sleep;
	if (!forceCleanup && _staleFixtureIndexesCleaned) {
		return;
	}
	if (!forceCleanup && now() < _staleFixtureIndexesCleanupCooldownUntil) {
		return;
	}

	let res: Response | null = null;
	for (let attempt = 0; attempt < 4; attempt += 1) {
		res = await apiCallForCleanup('GET', '/indexes');
		if (res.ok) {
			break;
		}
		if (res.status !== 429) {
			throw new Error(
				`cleanupFixtureIndexes failed to list indexes: ${res.status} ${await res.text()}`
			);
		}
		await sleepForCleanup(getRetryDelayMs(attempt, res.headers.get('retry-after')));
	}
	if (!res?.ok) {
		// This cleanup only removes stale local fixtures. If the shared test user is
		// currently throttled, failing the spec here is noisier than tolerating a
		// best-effort miss and letting the real test assertions speak for themselves.
		//
		// Do not mark cleanup as complete when list reads never succeeded: a later
		// fixture call in this worker should retry once throttling clears.
		_staleFixtureIndexesCleanupCooldownUntil = now() + 30_000;
		return;
	}

	const indexes = (await res.json()) as Array<{ name: string }>;
	const staleNames = indexes
		.map((index) => index.name.trim())
		.filter((name) => name && isStaleFixtureIndexName(name));

	// Bounded cleanup window so a single fixture call cannot stall the suite
	// when the shared test user has accumulated many stale indexes — names
	// past the deadline are pushed to unresolvedStaleDeletes and retried on
	// the next fixture call (cleanup stays uncached until convergence).
	const cleanupDeadline =
		now() +
		(forceCleanup
			? FORCE_STALE_INDEX_CLEANUP_DEADLINE_MS
			: PASSIVE_STALE_INDEX_CLEANUP_DEADLINE_MS);
	const unresolvedStaleDeletes: string[] = [];
	for (let staleNameIndex = 0; staleNameIndex < staleNames.length; staleNameIndex += 1) {
		const name = staleNames[staleNameIndex];
		if (now() > cleanupDeadline) {
			unresolvedStaleDeletes.push(...staleNames.slice(staleNameIndex));
			break;
		}
		let deleted = false;
		for (let attempt = 0; attempt < 10; attempt += 1) {
			if (now() > cleanupDeadline) {
				break;
			}
			const deleteRes = await apiCallForCleanup('DELETE', `/indexes/${encodeURIComponent(name)}`, {
				confirm: true
			}).catch(() => null);
			if (!deleteRes) {
				await sleepForCleanup(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (deleteRes.ok || deleteRes.status === 404) {
				deleted = true;
				break;
			}
			if (deleteRes.status !== 429 && deleteRes.status !== 500 && deleteRes.status !== 503) {
				break;
			}
			await sleepForCleanup(getRetryDelayMs(attempt, deleteRes.headers.get('retry-after')));
		}
		if (!deleted) {
			unresolvedStaleDeletes.push(name);
		}
	}

	// Cooldown when deletes don't converge — keeps the fixture retryable across
	// calls without thrashing the API on every call.
	if (unresolvedStaleDeletes.length > 0) {
		_staleFixtureIndexesCleanupCooldownUntil = now() + 30_000;
	}

	if (unresolvedStaleDeletes.length > 0) {
		return;
	}

	_staleFixtureIndexesCleaned = true;
	_staleFixtureIndexesCleanupCooldownUntil = 0;
}

async function waitForSeededIndex(name: string, tokenOverride?: string): Promise<void> {
	const maxAttempts = 60;
	const pollIntervalMs = 500;
	let lastStatus: number | null = null;

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const res = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(name)}`,
			undefined,
			tokenOverride
		);
		if (res.ok) {
			return;
		}
		lastStatus = res.status;
		if (res.status !== 404 && res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex readiness check failed: ${res.status} ${await res.text()}`);
		}
		// Back off longer on rate-limit responses to avoid exhausting the window
		const delay = res.status === 429 ? getTransientRetryDelayMs(attempt) : pollIntervalMs;
		await sleep(delay);
	}

	throw new Error(
		`seedIndex readiness check timed out for index "${name}" (last status: ${lastStatus ?? 'none'})`
	);
}

/** Apply deterministic settings to a seeded index before browser tests load it. */
async function updateSeededIndexSettings(
	name: string,
	settings: Record<string, unknown>,
	tokenOverride?: string
): Promise<void> {
	const maxAttempts = 8;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await apiCall(
			'PUT',
			`/indexes/${encodeURIComponent(name)}/settings`,
			settings,
			tokenOverride
		);
		if (response.ok) {
			return;
		}

		const body = await response.text();
		lastFailure = `${response.status} ${body}`;
		if (response.status !== 404 && response.status !== 429 && response.status !== 500) {
			throw new Error(`seedIndex settings failed: ${lastFailure}`);
		}
		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex settings failed after transient retries: ${lastFailure}`);
}

async function assertIndexNeverBecomesReadable(name: string): Promise<void> {
	const maxAttempts = 60;
	const pollIntervalMs = 500;

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await apiCall('GET', `/indexes/${encodeURIComponent(name)}`);
		if (response.ok) {
			throw new Error(
				`deferred proof absence check failed: index "${name}" became readable (${response.status})`
			);
		}
		if (response.status !== 404 && response.status !== 429 && response.status !== 500) {
			throw new Error(
				`deferred proof absence check failed: ${response.status} ${await response.text()}`
			);
		}
		const delay = response.status === 429 ? getTransientRetryDelayMs(attempt) : pollIntervalMs;
		await sleep(delay);
	}

	// Terminate with a concrete not-found read so transient throttling cannot
	// masquerade as proof that the index truly stayed absent.
	for (let attempt = 0; attempt < 10; attempt += 1) {
		const response = await apiCall('GET', `/indexes/${encodeURIComponent(name)}`);
		if (response.status === 404) {
			return;
		}
		if (response.status === 429 || response.status === 500) {
			await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
			continue;
		}
		if (response.ok) {
			throw new Error(
				`deferred proof absence check failed: index "${name}" became readable (${response.status})`
			);
		}
		throw new Error(
			`deferred proof absence check failed: ${response.status} ${await response.text()}`
		);
	}

	throw new Error(
		`deferred proof absence check failed: could not confirm 404 for index "${name}" after transient retries`
	);
}

function isIndexLimitReachedFailure(status: number, body: string): boolean {
	return status === 400 && body.toLowerCase().includes('index limit reached');
}

async function createSeededIndex(
	customerId: string,
	name: string,
	region: string,
	flapjackUrl: string,
	customerToken?: string
): Promise<void> {
	// In remote-target mode the deployed API allocates a VM from its own
	// vm_inventory via the customer-auth POST /indexes route. The admin
	// seed path (which body-passes flapjack_url) is the wrong tool here —
	// the local test host's flapjack URL is not routable inside staging's
	// VPC, and the staging shared flapjack is http-only so the loopback
	// validator rejects it. The customer-auth path goes through the real
	// allocator which links a real VM, so synonyms/documents/api-keys
	// proxy calls work. Email-verified state is already arranged by
	// auth.setup → verifyFreshSignupEmail.
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		if (customerToken) {
			await createSeededIndexViaCustomerToken(name, region, customerToken);
		} else {
			await createSeededIndexForCurrentCustomer(name, region);
		}
		return;
	}
	const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', flapjackUrl);
	const maxRetries = 6;
	let lastFailure = 'none';
	let fallbackToken = customerToken;

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await adminApiCall(
			'POST',
			`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
			{
				name,
				region,
				flapjack_url: safeFlapjackUrl
			}
		);
		if (res.ok) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;

		// A retry can race with a previous attempt that actually created the
		// index before the server surfaced a transient failure to the client.
		if (res.status === 409 && attempt > 0) {
			return;
		}

		// Shared-host Playwright runs can restart the API with a different
		// admin key mid-suite. Signal "invalid admin key" so the seedIndex
		// factory can fall back to customer-auth creation; only attempt the
		// in-function fallback when seedCustomerIndex explicitly passed its
		// own token (it owns a per-customer create flow and does not want
		// the factory-level fallback to a different customer's auth).
		if (res.status === 401 && !fallbackToken) {
			throw new Error(`createSeededIndex: invalid admin key (${lastFailure})`);
		}
		if (res.status === 401 && fallbackToken) {
			const fallbackResponse = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'POST',
				'/indexes',
				{ Authorization: `Bearer ${fallbackToken}` },
				{ name, region }
			);
			if (fallbackResponse.ok) {
				return;
			}
			const fallbackBody = await fallbackResponse.text();
			lastFailure = `admin 401; customer fallback ${fallbackResponse.status} ${fallbackBody}`;
			if (fallbackResponse.status === 409) {
				return;
			}
			if (fallbackResponse.status === 401 || fallbackResponse.status === 403) {
				_token = null;
				fallbackToken = await getAuthToken();
				await sleep(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (isIndexLimitReachedFailure(fallbackResponse.status, fallbackBody)) {
				await cleanupStaleFixtureIndexesOnce({ force: true });
				await sleep(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (
				fallbackResponse.status !== 429 &&
				fallbackResponse.status !== 500 &&
				fallbackResponse.status !== 503
			) {
				throw new Error(`seedIndex failed: ${lastFailure}`);
			}
		} else if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		} else if (res.status !== 401 && res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

async function createSeededIndexViaCustomerToken(
	name: string,
	region: string,
	customerToken: string
): Promise<void> {
	const maxRetries = 6;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/indexes',
			{ Authorization: `Bearer ${customerToken}` },
			{ name, region }
		);
		if (res.ok || res.status === 409) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status !== 429 && res.status !== 500 && res.status !== 503) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

type TrackedCustomerIndex = {
	token: string;
	name: string;
	deferCleanup: boolean;
};

type SeedCustomerIndexForFixtureParams = {
	customer: CreatedFixtureUser;
	name: string;
	region: string;
	flapjackUrl: string;
	options?: SeedIndexOptions;
	trackCreatedIndex: (entry: TrackedCustomerIndex) => void;
};

type SeedCustomerIndexForFixtureDeps = {
	createSeededIndexFn?: typeof createSeededIndex;
	waitForSeededIndexFn?: typeof waitForSeededIndex;
	updateSeededIndexSettingsFn?: typeof updateSeededIndexSettings;
	raiseRemoteSeededIndexWriteQuotaFn?: typeof raiseRemoteSeededIndexWriteQuota;
	writeSynonymsProofManifestFn?: typeof writeSynonymsProofManifest;
};

/** Seed an index owned by an explicit disposable customer and register fixture cleanup. */
export async function seedCustomerIndexForFixture(
	{
		customer,
		name,
		region,
		flapjackUrl,
		options,
		trackCreatedIndex
	}: SeedCustomerIndexForFixtureParams,
	{
		createSeededIndexFn = createSeededIndex,
		waitForSeededIndexFn = waitForSeededIndex,
		updateSeededIndexSettingsFn = updateSeededIndexSettings,
		raiseRemoteSeededIndexWriteQuotaFn = raiseRemoteSeededIndexWriteQuota,
		writeSynonymsProofManifestFn = writeSynonymsProofManifest
	}: SeedCustomerIndexForFixtureDeps = {}
): Promise<void> {
	const deferCleanup = Boolean(options?.deferCleanup);
	if (deferCleanup) {
		assertDeferredProofIndexAvoidsStalePrefixes(name);
	}

	await createSeededIndexFn(customer.customerId, name, region, flapjackUrl, customer.token);
	trackCreatedIndex({ token: customer.token, name, deferCleanup });
	await waitForSeededIndexFn(name, customer.token);
	if (options?.settings) {
		await updateSeededIndexSettingsFn(name, options.settings, customer.token);
	}
	await raiseRemoteSeededIndexWriteQuotaFn(customer.customerId);
	if (deferCleanup) {
		await writeSynonymsProofManifestFn({
			indexName: name,
			objectIDs: [],
			manifestPath: options?.proofManifestPath
		});
	}
}

async function createSeededIndexForCurrentCustomer(name: string, region: string): Promise<void> {
	const maxRetries = 6;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await apiCall('POST', '/indexes', {
			name,
			region
		});
		if (res.ok || res.status === 409) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		if (isUnauthorizedExpiredTokenAccountFailure(res.status, lastFailure)) {
			_token = null;
			continue;
		}
		if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

const RECOMMENDATION_FIXTURE_FACET_NAME = 'category';
const RECOMMENDATION_FIXTURE_FACET_VALUE = 'language';
const RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE = 'no-matches-category';

async function getCurrentBillingPlan(tokenOverride?: string): Promise<'free' | 'shared'> {
	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const res = await apiCall('GET', '/account', undefined, tokenOverride);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`GET /account failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as { billing_plan: 'free' | 'shared' };
		return data.billing_plan;
	}

	throw new Error('GET /account failed: exhausted retries after 429 rate limiting');
}

async function updateBillingPlan(
	plan: 'free' | 'shared',
	customerIdOverride?: string
): Promise<void> {
	const customerId = customerIdOverride ?? (await getCustomerId());
	const res = await adminApiCall('PUT', `/admin/tenants/${encodeURIComponent(customerId)}`, {
		billing_plan: plan
	});
	if (!res.ok) {
		throw new Error(`setBillingPlan failed: ${res.status} ${await res.text()}`);
	}
}

type ArrangeBillingPortalCustomerResult = CreatedFixtureUser & {
	stripeCustomerId: string;
	defaultPaymentMethodId: string;
	nonDefaultPaymentMethodId: string;
	expectedDefaultPaymentMethodId: string;
};

type ArrangeBillingPortalCustomerParams = {
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

type ArrangePaidInvoiceForFreshSignupParams = {
	email: string;
	password: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

type MailpitSearchResponse = {
	messages?: Array<{ ID?: string; id?: string }>;
	messages_count?: number;
	total?: number;
};

export const LOCAL_AUTO_VERIFIED_TOKEN_PREFIX = 'local-auto-verified-';

function buildFreshSignupIdentity(seed?: string): FreshSignupIdentity {
	const identitySeed = seed?.trim() || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	return {
		name: `Signup Lane ${identitySeed}`,
		email: `signup-paid-${identitySeed}@e2e.griddle.test`,
		password: 'TestPassword123!'
	};
}

export async function arrangeFreshSignupToDashboardWithFixtureFallback(
	{
		page,
		signup,
		createUser,
		trackCustomerForCleanup,
		beforeDocumentReplacement
	}: {
		page: Page;
		signup: FreshSignupIdentity;
		createUser: CreateUserFn;
		trackCustomerForCleanup: TrackCustomerForCleanupFn;
		beforeDocumentReplacement?: BeforeDocumentReplacementFn;
	},
	{
		resolveCleanupCustomerId = resolveFreshSignupCleanupCustomerId,
		getSessionTokenFromPage = getAuthCookieTokenFromPage,
		attemptRemoteFallback = attemptRemoteSignupFallback
	}: ArrangeFreshSignupToDashboardDeps = {}
): Promise<ArrangeFreshSignupToDashboardResult> {
	await beforeDocumentReplacement?.();
	await page.goto('/signup');
	await page.getByLabel('Name').fill(signup.name);
	await page.getByLabel('Email').fill(signup.email);
	await page.getByLabel('Password', { exact: true }).fill(signup.password);
	await page.getByLabel('Confirm Password').fill(signup.password);

	const signupResponsePromise = page
		.waitForResponse(
			(response) => response.request().method() === 'POST' && response.url().includes('/signup'),
			{ timeout: 20_000 }
		)
		.catch(() => null);
	await beforeDocumentReplacement?.();
	await page.getByRole('button', { name: 'Sign Up' }).click();

	const signupAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/console/, { timeout: 20_000 }),
		signupAlert.waitFor({ state: 'visible', timeout: 20_000 })
	]).catch(() => undefined);

	if (/\/console/.test(page.url())) {
		await page.waitForLoadState('load');
		const signupResponse = await signupResponsePromise;
		const customerId = await resolveCleanupCustomerId({
			sessionToken: await getSessionTokenFromPage(page),
			currentPath: page.url(),
			responseStatus: signupResponse?.status(),
			responseUrl: signupResponse?.url()
		});
		trackCustomerForCleanup(customerId);
		return { prerequisiteFailureMessage: null };
	}

	const signupResponse = await signupResponsePromise;
	const alertVisible = await signupAlert.isVisible().catch(() => false);
	const alertText = alertVisible ? ((await signupAlert.textContent())?.trim() ?? '') : '';
	let fallbackSucceeded = false;
	let fallbackErrorDetail: string | null = null;
	try {
		fallbackSucceeded = await attemptRemoteFallback({
			page,
			email: signup.email,
			password: signup.password,
			name: signup.name,
			createUser,
			beforeDocumentReplacement,
			remoteTargetOptInEnv: REMOTE_TARGET_OPT_IN_ENV
		});
	} catch (error) {
		fallbackErrorDetail = setupFailureDetailsFromError(error);
	}

	if (fallbackSucceeded) {
		return { prerequisiteFailureMessage: null };
	}
	if (fallbackErrorDetail) {
		throwFreshSignupArrangeFailure({
			currentPath: page.url(),
			alertText: [
				alertText || 'Sign up did not reach /console and no alert was visible within 20 seconds.',
				`Remote signup fallback failed: ${fallbackErrorDetail}`
			].join(' | '),
			responseStatus: signupResponse?.status(),
			responseUrl: signupResponse?.url()
		});
	}

	if (isFreshSignupArrangePrerequisiteFailure(alertText)) {
		return {
			prerequisiteFailureMessage: alertText || 'unknown alert'
		};
	}

	throwFreshSignupArrangeFailure({
		currentPath: page.url(),
		alertText:
			alertText || 'Sign up did not reach /console and no alert was visible within 20 seconds.',
		responseStatus: signupResponse?.status(),
		responseUrl: signupResponse?.url()
	});
}

async function getAuthCookieTokenFromPage(page: Page): Promise<string | null> {
	const sessionCookie = (await page.context().cookies()).find(
		(cookie) => cookie.name === AUTH_COOKIE && cookie.value.trim().length > 0
	);
	return sessionCookie?.value.trim() || null;
}

function currentUtcBillingMonth(now = new Date()): string {
	const month = String(now.getUTCMonth() + 1).padStart(2, '0');
	return `${now.getUTCFullYear()}-${month}`;
}

function getMailpitApiUrl(): string {
	const configuredMailpitApiUrl = process.env.MAILPIT_API_URL?.trim();
	if (!configuredMailpitApiUrl) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup mailpit setup',
				expectedPath: 'MAILPIT_API_URL',
				currentPath: '(env:MAILPIT_API_URL)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: 'MAILPIT_API_URL must be set for fresh-signup verification checks'
			})
		);
	}
	return requireLoopbackHttpUrl('MAILPIT_API_URL', configuredMailpitApiUrl);
}

function extractMailpitMessageId(rawMessage: unknown): string | null {
	if (!rawMessage || typeof rawMessage !== 'object') {
		return null;
	}

	const record = rawMessage as { ID?: unknown; id?: unknown };
	const id = record.ID ?? record.id;
	if (typeof id !== 'string' || !id.trim()) {
		return null;
	}

	return id;
}

function extractVerificationTokenFromMailpitPayload(payload: unknown): string | null {
	const payloadText = JSON.stringify(payload ?? {});
	const patterns = [/\/verify-email\/([A-Za-z0-9_-]+)/, /verify-email[?&]token=([A-Za-z0-9_-]+)/];

	for (const pattern of patterns) {
		const match = pattern.exec(payloadText);
		const token = match?.[1];
		if (token) {
			return token;
		}
	}

	return null;
}

async function fetchMailpitMessageIds(query: string): Promise<string[]> {
	const mailpitApiUrl = getMailpitApiUrl();
	const searchResponse = await fetch(
		`${mailpitApiUrl}/api/v1/search?query=${encodeURIComponent(query)}`
	);
	if (!searchResponse.ok) {
		throw new Error(
			`Mailpit search failed: ${searchResponse.status} ${await searchResponse.text()}`
		);
	}

	const payload = (await searchResponse.json()) as MailpitSearchResponse;
	const messages = Array.isArray(payload.messages) ? payload.messages : [];
	return messages.map(extractMailpitMessageId).filter((id): id is string => id !== null);
}

async function fetchMailpitMessagePayload(messageId: string): Promise<unknown> {
	const mailpitApiUrl = getMailpitApiUrl();
	const messageResponse = await fetch(
		`${mailpitApiUrl}/api/v1/message/${encodeURIComponent(messageId)}`
	);
	if (!messageResponse.ok) {
		throw new Error(
			`Mailpit message fetch failed for ${messageId}: ${messageResponse.status} ${await messageResponse.text()}`
		);
	}
	return messageResponse.json();
}

type FindMailpitTokenParams = {
	email: string;
	missingEmailMessage: string;
	extractToken: (payload: unknown) => string | null;
	setupName: string;
	expectedPath: string;
	missingTokenMessage: string;
};

async function findTokenViaMailpit({
	email,
	missingEmailMessage,
	extractToken,
	setupName,
	expectedPath,
	missingTokenMessage
}: FindMailpitTokenParams): Promise<string> {
	const normalizedEmail = requireNonEmptyString(email, missingEmailMessage);
	const maxAttempts = 30;
	const query = `to:${normalizedEmail}`;

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const messageIds = await fetchMailpitMessageIds(query).catch(() => []);
		for (const messageId of messageIds) {
			const payload = await fetchMailpitMessagePayload(messageId).catch(() => null);
			const token = extractToken(payload);
			if (token) {
				return token;
			}
		}

		await sleep(1000);
	}

	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName,
			expectedPath,
			currentPath: '(mailpit search)',
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText: `${missingTokenMessage} for ${normalizedEmail} after ${maxAttempts}s`
		})
	);
}

export async function findVerificationTokenViaMailpit(email: string): Promise<string> {
	return findTokenViaMailpit({
		email,
		missingEmailMessage: 'findVerificationTokenViaMailpit requires a non-empty email',
		extractToken: extractVerificationTokenFromMailpitPayload,
		setupName: 'fresh-signup email verification token lookup',
		expectedPath: '/verify-email/{token}',
		missingTokenMessage: 'No verification token found in Mailpit'
	});
}

export function extractResetTokenFromMailpitPayload(payload: unknown): string | null {
	const payloadText = JSON.stringify(payload ?? {});
	const patterns = [
		/\/reset-password\/([A-Za-z0-9_-]+)/,
		/reset-password[?&]token=([A-Za-z0-9_-]+)/
	];

	for (const pattern of patterns) {
		const match = pattern.exec(payloadText);
		const token = match?.[1];
		if (token) {
			return token;
		}
	}

	return null;
}

export async function findResetTokenViaMailpit(email: string): Promise<string> {
	return findTokenViaMailpit({
		email,
		missingEmailMessage: 'findResetTokenViaMailpit requires a non-empty email',
		extractToken: extractResetTokenFromMailpitPayload,
		setupName: 'forgot-password reset token lookup',
		expectedPath: '/reset-password/{token}',
		missingTokenMessage: 'No reset token found in Mailpit'
	});
}

/**
 * Look up the verification token for a freshly-signed-up customer.
 *
 * Local lane: token is read from Mailpit (the local SMTP catcher).
 *
 * LB-2/LB-3 remote lane: when PLAYWRIGHT_TARGET_REMOTE=1, Mailpit doesn't
 * exist (staging uses real SES). The token is instead read directly from
 * the staging customers table via SSM-exec'd psql on the EC2 host. See
 * web/tests/fixtures/staging_db_lookup.ts and LB-2/LB-3 in LAUNCH.md.
 */
async function findFreshSignupVerificationToken(email: string): Promise<string> {
	// Read the opt-in flag through the canonical constant exported by
	// playwright.config.contract.ts so the env var name has exactly one
	// definition site (SSoT). The harness, the loopback guard, and this
	// dispatcher all reference the same source of truth.
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		return findVerificationTokenViaStagingSsm(email);
	}
	return findVerificationTokenViaMailpit(email);
}

function isPlaywrightEmailVerificationRequired(): boolean {
	return process.env[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV] === '1';
}

async function loginConfirmsFreshSignupAlreadyVerified(
	email: string,
	password: string | undefined
): Promise<boolean> {
	if (!password?.trim()) {
		return false;
	}

	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const loginResponse = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/auth/login',
			{},
			{ email, password }
		);
		if (loginResponse.status === 429) {
			await sleep(getRetryDelayMs(attempt, loginResponse.headers.get('retry-after')));
			continue;
		}
		if (!loginResponse.ok) {
			return false;
		}

		const loginPayload = (await loginResponse.json().catch(() => null)) as {
			token?: unknown;
		} | null;
		const token = typeof loginPayload?.token === 'string' ? loginPayload.token.trim() : '';
		if (!token) {
			return false;
		}

		const accountResponse = await callJsonApi(fetch, fixtureEnv.apiUrl, 'GET', '/account', {
			Authorization: `Bearer ${token}`
		});
		if (accountResponse.status === 429) {
			await sleep(getRetryDelayMs(attempt, accountResponse.headers.get('retry-after')));
			continue;
		}
		if (!accountResponse.ok) {
			return false;
		}

		const accountPayload = (await accountResponse.json().catch(() => null)) as {
			email_verified?: unknown;
		} | null;
		return accountPayload?.email_verified === true;
	}
	return false;
}

async function resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
	email: string,
	password: string | undefined
): Promise<string> {
	if (
		!isPlaywrightEmailVerificationRequired() &&
		process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1' &&
		(await loginConfirmsFreshSignupAlreadyVerified(email, password))
	) {
		return `${LOCAL_AUTO_VERIFIED_TOKEN_PREFIX}${Date.now()}`;
	}

	try {
		return await findFreshSignupVerificationToken(email);
	} catch (error) {
		if (
			!isPlaywrightEmailVerificationRequired() &&
			process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1' &&
			(await loginConfirmsFreshSignupAlreadyVerified(email, password))
		) {
			return `${LOCAL_AUTO_VERIFIED_TOKEN_PREFIX}${Date.now()}`;
		}
		throw error;
	}
}

async function completeFreshSignupEmailVerificationViaRoute(
	page: Page,
	email: string,
	password?: string
): Promise<{ verificationToken: string }> {
	try {
		const verificationToken = await resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
			email,
			password
		);
		if (verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
			// The locally spawned Playwright API intentionally auto-verifies
			// signups. There is no email token to replay, so assert the browser
			// route's consumed/invalid-token result instead of polling Mailpit.
			await page.context().clearCookies();
			await page.goto(`/verify-email/${verificationToken}`);
			await expect(
				page.getByRole('heading', { name: 'We could not verify your email' })
			).toBeVisible({
				timeout: 10_000
			});
			return { verificationToken };
		}
		// Remote browser lanes can target a deployed frontend host whose
		// verify-email route is not guaranteed to consume staging tokens via the
		// same API origin as fixtureEnv.apiUrl. In remote mode, consume the
		// token through the staging API seam first, then let specs assert browser
		// replay behavior on /verify-email/{token}.
		if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const verifyResponse = await callJsonApi(
					fetch,
					fixtureEnv.apiUrl,
					'POST',
					'/auth/verify-email',
					{},
					{ token: verificationToken }
				);
				if (verifyResponse.status === 429) {
					await sleep(getRetryDelayMs(attempt, verifyResponse.headers.get('retry-after')));
					continue;
				}
				if (!verifyResponse.ok) {
					throw new Error(
						`staging API verify-email failed: ${verifyResponse.status} ${await verifyResponse.text()}`
					);
				}
				await page.context().clearCookies();
				// Cooldown before the spec navigates to /verify-email/{token} in the
				// browser — the SvelteKit server makes a second API call and upstream
				// rate limiters (Cloudflare) can reject it if it arrives too soon.
				await sleep(3000);
				return { verificationToken };
			}
			throw new Error('staging API verify-email failed: exhausted retries after 429 rate limiting');
		}

		// Public auth pages redirect authenticated users to /console, so clear
		// auth cookies before exercising the verify-email success contract.
		await page.context().clearCookies();
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(page.getByRole('heading', { name: 'Email verified' })).toBeVisible({
			timeout: 30_000
		});
		return { verificationToken };
	} catch (error) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup email verification replay setup',
				expectedPath: '/verify-email/{token}',
				currentPath: page.url() || '(no browser url)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: setupFailureDetailsFromError(error)
			}),
			{ cause: error }
		);
	}
}

async function getCustomerIdForToken(token: string): Promise<string> {
	const accountPayload = await getAccountPayloadForTokenWithRetries(token, 'getCustomerIdForToken');
	return requireNonEmptyString(
		accountPayload.id ?? '',
		'getCustomerIdForToken received an empty customer id'
	);
}

async function syncStripeCustomer(customerId: string, contextLabel: string): Promise<string> {
	const stripeSync = await adminApiCall(
		'POST',
		`/admin/customers/${encodeURIComponent(customerId)}/sync-stripe`
	);
	if (!stripeSync.ok) {
		throw new Error(
			`${contextLabel} failed to sync stripe customer: ${stripeSync.status} ${await stripeSync.text()}`
		);
	}

	const stripeSyncPayload = (await stripeSync.json()) as { stripe_customer_id?: string };
	if (!stripeSyncPayload.stripe_customer_id) {
		throw new Error(`${contextLabel} failed: stripe sync returned no stripe_customer_id`);
	}
	return stripeSyncPayload.stripe_customer_id;
}

/**
 * Attach Stripe's well-known `pm_card_visa` test payment method to the given
 * Stripe customer and set it as the customer's default `invoice_settings`
 * payment method. Returns the attached PaymentMethod id.
 *
 * Why this exists as a shared helper: both `arrangeBillingPortalCustomer`
 * (LB-3 lane) and `arrangePaidInvoiceForFreshSignup` (LB-2 lane) need a
 * disposable test customer with a default PM so Stripe can auto-charge
 * the invoice in `charge_automatically` mode. Previously only the LB-3
 * fixture attached a PM; the LB-2 fixture skipped this step and the
 * resulting invoice sat in `open` state forever, timing out
 * `waitForInvoicePaid`.
 *
 * Requires `STRIPE_SECRET_KEY` in env (the test-mode `rk_test_*` /
 * `sk_test_*` key matching the staging API). Source
 * `.secret/.env.secret` before invoking Playwright.
 */
async function attachDefaultStripeTestCard(
	stripeCustomerId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<string> {
	return attachStripeTestCard({
		stripeCustomerId,
		stripeSecretKey,
		contextLabel,
		stripePaymentMethodId: 'pm_card_visa',
		setAsDefault: true
	});
}

type AttachStripeTestCardParams = {
	stripeCustomerId: string;
	stripeSecretKey: string;
	contextLabel: string;
	stripePaymentMethodId: string;
	setAsDefault: boolean;
};

async function attachStripeTestCard({
	stripeCustomerId,
	stripeSecretKey,
	contextLabel,
	stripePaymentMethodId,
	setAsDefault
}: AttachStripeTestCardParams): Promise<string> {
	const stripeAuthHeaders = {
		Authorization: `Bearer ${stripeSecretKey}`,
		'Content-Type': 'application/x-www-form-urlencoded'
	};

	const attachResp = await fetch(
		`https://api.stripe.com/v1/payment_methods/${encodeURIComponent(stripePaymentMethodId)}/attach`,
		{
			method: 'POST',
			headers: stripeAuthHeaders,
			body: `customer=${encodeURIComponent(stripeCustomerId)}`
		}
	);
	if (!attachResp.ok) {
		throw new Error(
			`${contextLabel} Stripe PaymentMethod.attach failed: ${attachResp.status} ${await attachResp.text()}`
		);
	}
	const paymentMethod = (await attachResp.json()) as { id?: string };
	const defaultPaymentMethodId = requireNonEmptyString(
		paymentMethod.id ?? '',
		`${contextLabel} expected attached PaymentMethod.id from Stripe`
	);

	if (!setAsDefault) {
		return defaultPaymentMethodId;
	}

	const updateResp = await fetch(
		`https://api.stripe.com/v1/customers/${encodeURIComponent(stripeCustomerId)}`,
		{
			method: 'POST',
			headers: stripeAuthHeaders,
			body: `invoice_settings[default_payment_method]=${encodeURIComponent(defaultPaymentMethodId)}`
		}
	);
	if (!updateResp.ok) {
		throw new Error(
			`${contextLabel} Stripe customer default-PM update failed: ${updateResp.status} ${await updateResp.text()}`
		);
	}

	return defaultPaymentMethodId;
}

async function attachNonDefaultStripeTestCard(
	stripeCustomerId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<string> {
	return attachStripeTestCard({
		stripeCustomerId,
		stripeSecretKey,
		contextLabel,
		stripePaymentMethodId: 'pm_card_mastercard',
		setAsDefault: false
	});
}

type WaitForStripeDefaultPaymentMethodParams = {
	stripeCustomerId: string;
	stripeSecretKey: string;
	expectedPaymentMethodId: string;
	contextLabel: string;
	maxAttempts?: number;
};

async function waitForStripeDefaultPaymentMethod({
	stripeCustomerId,
	stripeSecretKey,
	expectedPaymentMethodId,
	contextLabel,
	maxAttempts = STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS
}: WaitForStripeDefaultPaymentMethodParams): Promise<string> {
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const currentDefaultPaymentMethod = await readStripeDefaultPaymentMethod({
			stripeCustomerId,
			stripeSecretKey,
			contextLabel
		});
		if (currentDefaultPaymentMethod === expectedPaymentMethodId) {
			return currentDefaultPaymentMethod;
		}
		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(
		`${contextLabel} timed out waiting for Stripe default payment method ` +
			`${expectedPaymentMethodId} on customer ${stripeCustomerId}`
	);
}

/**
 * Create a disposable customer fixture that can reach the billing portal.
 */
async function arrangeBillingPortalCustomer({
	trackCustomerForCleanup
}: ArrangeBillingPortalCustomerParams): Promise<ArrangeBillingPortalCustomerResult> {
	try {
		const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
		if (!stripeSecretKey) {
			throw new Error(
				'arrangeBillingPortalCustomer requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
			);
		}

		const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
		const email = `billing-portal-${seed}@e2e.griddle.test`;
		const password = 'TestPassword123!';

		const created = await createRegisteredUser({
			apiUrl: fixtureEnv.apiUrl,
			email,
			password,
			name: `Billing Portal ${seed}`,
			trackCustomerForCleanup
		});
		const verificationToken = await resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
			email,
			password
		);
		if (!verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const verifyResponse = await callJsonApi(
					fetch,
					fixtureEnv.apiUrl,
					'POST',
					'/auth/verify-email',
					{},
					{ token: verificationToken }
				);
				if (verifyResponse.status === 429) {
					await sleep(getRetryDelayMs(attempt, verifyResponse.headers.get('retry-after')));
					continue;
				}
				if (!verifyResponse.ok) {
					throw new Error(
						`arrangeBillingPortalCustomer verify-email failed: ${verifyResponse.status} ${await verifyResponse.text()}`
					);
				}
				break;
			}
		}
		const token = await loginAsUser({
			apiUrl: fixtureEnv.apiUrl,
			email,
			password
		});

		const currentPlan = await getCurrentBillingPlan(token);
		if (currentPlan !== 'shared') {
			await updateBillingPlan('shared', created.customerId);
		}

		const stripeCustomerId = await syncStripeCustomer(
			created.customerId,
			'arrangeBillingPortalCustomer'
		);

		if (stripeCustomerId.startsWith('cus_local_')) {
			return {
				...created,
				token,
				stripeCustomerId,
				defaultPaymentMethodId: 'pm_local_default',
				nonDefaultPaymentMethodId: 'pm_local_secondary',
				expectedDefaultPaymentMethodId: 'pm_local_secondary'
			};
		}

		const defaultPaymentMethodId = await attachDefaultStripeTestCard(
			stripeCustomerId,
			stripeSecretKey,
			'arrangeBillingPortalCustomer'
		);
		const nonDefaultPaymentMethodId = await attachNonDefaultStripeTestCard(
			stripeCustomerId,
			stripeSecretKey,
			'arrangeBillingPortalCustomer'
		);
		await waitForStripeDefaultPaymentMethod({
			stripeCustomerId,
			stripeSecretKey,
			expectedPaymentMethodId: defaultPaymentMethodId,
			contextLabel: 'arrangeBillingPortalCustomer'
		});

		return {
			...created,
			token,
			stripeCustomerId,
			defaultPaymentMethodId,
			nonDefaultPaymentMethodId,
			expectedDefaultPaymentMethodId: nonDefaultPaymentMethodId
		};
	} catch (error) {
		throwBillingPortalArrangeFailure({
			currentPath: '(arrangeBillingPortalCustomer)',
			error
		});
	}
}

async function resolveInvoiceIdFromBatch(
	batch: BatchBillingResponse,
	customerId: string,
	token: string,
	billingMonth: string,
	stripeSecretKey: string
): Promise<string> {
	const customerResult = batch.results.find((result) => result.customer_id === customerId);
	if (!customerResult) {
		throw new Error(
			`arrangePaidInvoiceForFreshSignup missing batch result for customer ${customerId}`
		);
	}

	if (customerResult.status === 'created' && customerResult.invoice_id) {
		return customerResult.invoice_id;
	}

	if (customerResult.status === 'skipped' && customerResult.reason === 'already_invoiced') {
		return recoverAlreadyInvoicedInvoiceForMonth({
			billingMonth,
			contextLabel: 'arrangePaidInvoiceForFreshSignup',
			listInvoices: () => listInvoicesBestEffort(token),
			getInvoiceDetail: (invoiceId: string) => getInvoiceDetailForToken(invoiceId, token),
			finalizeDraftInvoice: finalizeExistingInvoiceForFreshSignup,
			payStripeInvoice: (stripeInvoiceId: string) =>
				payStripeInvoiceWithTestKey(
					stripeInvoiceId,
					stripeSecretKey,
					'arrangePaidInvoiceForFreshSignup'
				)
		});
	}

	throw new Error(
		`arrangePaidInvoiceForFreshSignup unexpected batch status for customer ${customerId}: ${customerResult.status} (${customerResult.reason ?? 'no reason'})`
	);
}

type RecoverAlreadyInvoicedInvoiceForMonthParams = {
	billingMonth: string;
	contextLabel: string;
	listInvoices: () => Promise<InvoiceListApiItem[]>;
	getInvoiceDetail: (invoiceId: string) => Promise<InvoiceDetailApiItem | null>;
	finalizeDraftInvoice: (invoiceId: string) => Promise<void>;
	payStripeInvoice: (stripeInvoiceId: string) => Promise<void>;
};

type EnsureInvoicePaymentAttemptForBillingProofParams = {
	invoiceId: string;
	contextLabel: string;
	getInvoiceDetail: (invoiceId: string) => Promise<InvoiceDetailApiItem | null>;
	payStripeInvoice: (stripeInvoiceId: string) => Promise<void>;
};

/**
 * Recover an existing monthly invoice when batch billing reports already_invoiced.
 */
export async function recoverAlreadyInvoicedInvoiceForMonth({
	billingMonth,
	contextLabel,
	listInvoices,
	getInvoiceDetail,
	finalizeDraftInvoice,
	payStripeInvoice
}: RecoverAlreadyInvoicedInvoiceForMonthParams): Promise<string> {
	const monthStart = `${billingMonth}-01`;
	const invoices = await listInvoices();
	const existing = invoices.find((invoice) => invoice.period_start === monthStart);
	if (!existing) {
		throw new Error(
			`${contextLabel} reported already_invoiced for ${billingMonth} but no matching invoice was visible`
		);
	}

	const detail = await getInvoiceDetail(existing.id);
	if (!detail) {
		throw new Error(
			`${contextLabel} could not read existing already_invoiced invoice detail for ${existing.id}`
		);
	}

	if (detail.status === 'draft') {
		await finalizeDraftInvoice(detail.id);
		return detail.id;
	}

	if (
		(detail.status === 'finalized' || detail.status === 'failed') &&
		detail.stripe_invoice_id?.trim()
	) {
		await payStripeInvoice(detail.stripe_invoice_id);
		return detail.id;
	}

	return detail.id;
}

/**
 * Ensure finalized/failed Stripe-backed invoices get an explicit pay attempt
 * before waiting for paid status convergence in remote staging proofs.
 */
export async function ensureInvoicePaymentAttemptForBillingProof({
	invoiceId,
	contextLabel,
	getInvoiceDetail,
	payStripeInvoice
}: EnsureInvoicePaymentAttemptForBillingProofParams): Promise<void> {
	const detail = await getInvoiceDetail(invoiceId);
	if (!detail) {
		throw new Error(`${contextLabel} could not read invoice detail for ${invoiceId}`);
	}

	if (
		(detail.status === 'open' || detail.status === 'finalized' || detail.status === 'failed') &&
		detail.stripe_invoice_id?.trim()
	) {
		await payStripeInvoice(detail.stripe_invoice_id);
	}
}

async function finalizeExistingInvoiceForFreshSignup(invoiceId: string): Promise<void> {
	const finalizeResponse = await adminApiCall(
		'POST',
		`/admin/invoices/${encodeURIComponent(invoiceId)}/finalize`
	);
	if (!finalizeResponse.ok) {
		throw new Error(
			`arrangePaidInvoiceForFreshSignup failed to finalize existing invoice ${invoiceId}: ${finalizeResponse.status} ${await finalizeResponse.text()}`
		);
	}
}

async function payStripeInvoiceWithTestKey(
	stripeInvoiceId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<void> {
	// Local-stack proofs can emit synthetic invoice ids that look Stripe-like
	// (`in_local_*`) but do not exist on stripe.com. Skip remote pay attempts.
	if (stripeInvoiceId.startsWith('in_local_')) {
		return;
	}

	const paymentResponse = await fetch(
		`https://api.stripe.com/v1/invoices/${encodeURIComponent(stripeInvoiceId)}/pay`,
		{
			method: 'POST',
			headers: {
				Authorization: `Bearer ${stripeSecretKey}`,
				'Content-Type': 'application/x-www-form-urlencoded'
			}
		}
	);
	if (!paymentResponse.ok) {
		const responseBody = await paymentResponse.text();
		if (
			paymentResponse.status === 400 &&
			responseBody.toLowerCase().includes('invoice is already paid')
		) {
			// Stripe can return a 400 when an automatic payment has already
			// settled the invoice between our polling intervals. Treat that
			// idempotent state as converged success for the staging proof.
			return;
		}
		throw new Error(
			`${contextLabel} Stripe invoice pay failed for ${stripeInvoiceId}: ${paymentResponse.status} ${responseBody}`
		);
	}
}

async function waitForInvoicePaid(invoiceId: string, token: string): Promise<InvoiceDetailApiItem> {
	return waitForInvoiceStatus({
		invoiceId,
		token,
		expectedStatus: 'paid',
		contextLabel: 'arrangePaidInvoiceForFreshSignup'
	});
}

type WaitForInvoiceStatusParams = {
	invoiceId: string;
	token: string;
	expectedStatus: 'paid' | 'refunded';
	contextLabel: string;
};

type WaitForInvoiceStatusForTokenParams = {
	apiUrl: string;
	token: string;
	invoiceId: string;
	expectedStatus: 'paid' | 'refunded';
	contextLabel: string;
	fetchImpl?: typeof fetch;
	maxAttempts?: number;
};

export async function waitForInvoiceStatusForToken({
	apiUrl,
	token,
	invoiceId,
	expectedStatus,
	contextLabel,
	fetchImpl = fetch,
	maxAttempts = INVOICE_STATUS_WAIT_MAX_ATTEMPTS
}: WaitForInvoiceStatusForTokenParams): Promise<InvoiceDetailApiItem> {
	let openWithoutStripeInvoiceIdAttempts = 0;
	let openWithStripeInvoiceIdAttempts = 0;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await callJsonApi(
			fetchImpl,
			apiUrl,
			'GET',
			`/invoices/${encodeURIComponent(invoiceId)}`,
			{
				Authorization: `Bearer ${token}`
			}
		);
		if (response.ok) {
			const invoice = (await response.json()) as InvoiceDetailApiItem;
			if (invoice.status === expectedStatus && (expectedStatus !== 'paid' || invoice.paid_at)) {
				return invoice;
			}
			if (expectedStatus === 'paid') {
				const stripeInvoiceId = invoice.stripe_invoice_id?.trim() ?? '';
				if (invoice.status === 'open') {
					if (!stripeInvoiceId) {
						openWithoutStripeInvoiceIdAttempts += 1;
						openWithStripeInvoiceIdAttempts = 0;
						if (openWithoutStripeInvoiceIdAttempts >= INVOICE_OPEN_WITHOUT_STRIPE_ID_MAX_ATTEMPTS) {
							throw new Error(
								`${contextLabel} invoice ${invoiceId} remained open without stripe_invoice_id`
							);
						}
					} else {
						openWithStripeInvoiceIdAttempts += 1;
						openWithoutStripeInvoiceIdAttempts = 0;
						if (openWithStripeInvoiceIdAttempts >= INVOICE_OPEN_WITH_STRIPE_ID_MAX_ATTEMPTS) {
							throw new Error(
								`${contextLabel} invoice ${invoiceId} remained open with stripe_invoice_id present`
							);
						}
					}
				} else {
					openWithoutStripeInvoiceIdAttempts = 0;
					openWithStripeInvoiceIdAttempts = 0;
				}
			}
		} else if (
			response.status !== 404 &&
			response.status !== 429 &&
			response.status !== 503 &&
			response.status < 500
		) {
			throw new Error(
				`${contextLabel} failed to read invoice ${invoiceId}: ${response.status} ${await response.text()}`
			);
		}

		await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
	}

	throw new Error(
		`${contextLabel} timed out waiting for invoice ${invoiceId} to become ${expectedStatus}`
	);
}

async function waitForInvoiceStatus({
	invoiceId,
	token,
	expectedStatus,
	contextLabel
}: WaitForInvoiceStatusParams): Promise<InvoiceDetailApiItem> {
	return waitForInvoiceStatusForToken({
		apiUrl: fixtureEnv.apiUrl,
		token,
		invoiceId,
		expectedStatus,
		contextLabel
	});
}

async function arrangePaidInvoiceForFreshSignup({
	email,
	password,
	trackCustomerForCleanup
}: ArrangePaidInvoiceForFreshSignupParams): Promise<ArrangePaidInvoiceForFreshSignupResult> {
	try {
		const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
		if (!stripeSecretKey) {
			// Mirror arrangeBillingPortalCustomer's contract: the test-mode
			// Stripe key is what lets us attach pm_card_visa as the default PM
			// so the batch-billing-created invoice can be auto-charged. Without
			// it, the invoice sits in `open` state forever and the spec times
			// out at waitForInvoicePaid.
			throw new Error(
				'arrangePaidInvoiceForFreshSignup requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
			);
		}

		const normalizedEmail = requireNonEmptyString(
			email,
			'arrangePaidInvoiceForFreshSignup requires a non-empty email and password'
		);
		if (!password.trim()) {
			throw new Error('arrangePaidInvoiceForFreshSignup requires a non-empty email and password');
		}

		const token = await loginAsUserWithKnownMissingUserBootstrap({
			apiUrl: fixtureEnv.apiUrl,
			email: normalizedEmail,
			password,
			trackCustomerForCleanup,
			contextLabel: 'arrangePaidInvoiceForFreshSignup'
		});
		const customerId = await getCustomerIdForToken(token);
		trackCustomerForCleanup(customerId);

		const currentPlan = await getCurrentBillingPlan(token);
		if (currentPlan !== 'shared') {
			await updateBillingPlan('shared', customerId);
		}

		const stripeCustomerId = await syncStripeCustomer(
			customerId,
			'arrangePaidInvoiceForFreshSignup'
		);
		if (stripeCustomerId.startsWith('cus_local_')) {
			throw new Error(
				'arrangePaidInvoiceForFreshSignup local Stripe mode does not support paid-invoice proof fixtures'
			);
		}

		// Local-only Stripe placeholder IDs (`cus_local_*`) are not valid at
		// stripe.com and must skip external card attachment in local-stack proofs.
		if (!stripeCustomerId.startsWith('cus_local_')) {
			// Attach pm_card_visa as the default PM BEFORE batch billing runs,
			// so the invoice that batch billing creates gets auto-charged
			// (collection_method=charge_automatically with a default PM = paid in
			// seconds). Without this step, waitForInvoicePaid below times out.
			const defaultPaymentMethodId = await attachDefaultStripeTestCard(
				stripeCustomerId,
				stripeSecretKey,
				'arrangePaidInvoiceForFreshSignup'
			);
			// Stripe can acknowledge attachment before `invoice_settings.default_payment_method`
			// is query-consistent. Wait for that read seam to converge before batch billing.
			await waitForStripeDefaultPaymentMethod({
				stripeCustomerId,
				stripeSecretKey,
				expectedPaymentMethodId: defaultPaymentMethodId,
				contextLabel: 'arrangePaidInvoiceForFreshSignup'
			});
		}

		const billingMonth = currentUtcBillingMonth();
		const batchBillingResponse = await adminApiCall('POST', '/admin/billing/run', {
			month: billingMonth
		});
		if (!batchBillingResponse.ok) {
			throw new Error(
				`arrangePaidInvoiceForFreshSignup failed to run batch billing: ${batchBillingResponse.status} ${await batchBillingResponse.text()}`
			);
		}

		const batch = (await batchBillingResponse.json()) as BatchBillingResponse;
		const invoiceId = await resolveInvoiceIdFromBatch(
			batch,
			customerId,
			token,
			billingMonth,
			stripeSecretKey
		);
		await ensureInvoicePaymentAttemptForBillingProof({
			invoiceId,
			contextLabel: 'arrangePaidInvoiceForFreshSignup',
			getInvoiceDetail: (id) => getInvoiceDetailForToken(id, token),
			payStripeInvoice: (stripeInvoiceId) =>
				payStripeInvoiceWithTestKey(
					stripeInvoiceId,
					stripeSecretKey,
					'arrangePaidInvoiceForFreshSignup'
				)
		});
		await waitForInvoicePaid(invoiceId, token);
		const paidInvoiceEvidence =
			process.env[REMOTE_TARGET_OPT_IN_ENV] === '1'
				? await findPaidInvoiceEvidenceViaStagingSsm(normalizedEmail, invoiceId)
				: {
						stagingCustomerId: customerId,
						stagingInvoiceId: invoiceId,
						stagingInvoiceStatus: 'paid',
						stagingInvoicePeriodStart: `${billingMonth}-01`
					};

		return {
			customerId,
			invoiceId,
			billingMonth,
			stagingCustomerId: paidInvoiceEvidence.stagingCustomerId,
			stagingInvoiceId: paidInvoiceEvidence.stagingInvoiceId,
			stagingInvoiceStatus: paidInvoiceEvidence.stagingInvoiceStatus,
			stagingInvoicePeriodStart: paidInvoiceEvidence.stagingInvoicePeriodStart
		};
	} catch (error) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'arrangePaidInvoiceForFreshSignup',
				expectedPath: '/console/billing/invoices/{id}',
				currentPath: '(arrangePaidInvoiceForFreshSignup)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: setupFailureDetailsFromError(error)
			}),
			{ cause: error }
		);
	}
}

type InvoiceListApiItem = {
	id: string;
	status: string;
	period_start: string;
};

type InvoiceDetailApiItem = {
	id: string;
	status: string;
	paid_at: string | null;
	pdf_url: string | null;
	stripe_invoice_id?: string | null;
};

async function listInvoicesBestEffort(tokenOverride?: string): Promise<InvoiceListApiItem[]> {
	const res = await apiCall('GET', '/invoices', undefined, tokenOverride);
	if (!res.ok) {
		return [];
	}
	return (await res.json()) as InvoiceListApiItem[];
}

async function createDraftInvoiceForCustomer(
	customerId: string,
	month = '2025-01'
): Promise<{ id: string }> {
	const res = await adminApiCall(
		'POST',
		`/admin/tenants/${encodeURIComponent(customerId)}/invoices`,
		{
			month
		}
	);
	if (!res.ok) {
		throw new Error(`seedInvoice failed: ${res.status} ${await res.text()}`);
	}
	return (await res.json()) as { id: string };
}

async function createDraftInvoice(month = '2025-01'): Promise<{ id: string }> {
	return createDraftInvoiceForCustomer(await getCustomerId(), month);
}

async function getInvoiceDetailForFixture(invoiceId: string): Promise<InvoiceDetailApiItem | null> {
	const res = await apiCall('GET', `/invoices/${encodeURIComponent(invoiceId)}`);
	if (!res.ok) {
		return null;
	}
	return (await res.json()) as InvoiceDetailApiItem;
}

async function getInvoiceDetailForToken(
	invoiceId: string,
	token: string
): Promise<InvoiceDetailApiItem | null> {
	const res = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/invoices/${encodeURIComponent(invoiceId)}`,
		{ Authorization: `Bearer ${token}` }
	);
	if (!res.ok) {
		return null;
	}
	return (await res.json()) as InvoiceDetailApiItem;
}

// ---------------------------------------------------------------------------
// Custom fixture types
// ---------------------------------------------------------------------------

type SeedIndexFn = (name: string, region?: string, options?: SeedIndexOptions) => Promise<void>;
type SeedRecommendationsConfigResult = {
	indexName: string;
	primaryObjectID: string;
	secondaryObjectID: string;
	facetName: string;
	facetValue: string;
	missingFacetValue: string;
};
type SeedRecommendationsConfigFn = (
	name: string,
	region?: string
) => Promise<SeedRecommendationsConfigResult>;
type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string,
	flapjackUrl?: string,
	options?: SeedIndexOptions
) => Promise<void>;
type RegisterIndexForCleanupFn = (name: string, options?: RegisterIndexCleanupOptions) => void;
type CleanupFixtureIndexesFn = () => Promise<void>;
type SeedApiKeyFn = (name: string, scopes?: string[]) => Promise<{ id: string }>;
type SeedRulePayload = { objectID: string } & Record<string, unknown>;
type SeedRulesFn = (indexName: string, rules: SeedRulePayload[]) => Promise<void>;
type SeedPersonalizationStrategyFn = (
	indexName: string,
	strategy: Record<string, unknown>
) => Promise<void>;
type GetRuleFn = (indexName: string, objectID: string) => Promise<Rule>;
type SearchRulesFn = (
	indexName: string,
	query?: string,
	page?: number,
	hitsPerPage?: number
) => Promise<RuleSearchResponse>;
type ReadClipboardTextFn = (page: Page) => Promise<string>;
export type SvgTextBox = {
	index: number;
	text: string;
	left: number;
	top: number;
	right: number;
	bottom: number;
	width: number;
	height: number;
};
type ReadVisibleSvgTextBoxesFn = (locator: Locator) => Promise<SvgTextBox[]>;
type SeedSynonymFn = (indexName: string, synonym: Synonym) => Promise<void>;
type GetSynonymFn = (indexName: string, objectID: string) => Promise<Synonym | null>;
type SearchSynonymsFn = (indexName: string, query?: string) => Promise<SynonymSearchResponse>;
type ClearSynonymsFn = (indexName: string) => Promise<void>;
type SeedQsConfigFn = (indexName: string, config: QsConfig) => Promise<void>;
type GetQsConfigFn = (indexName: string) => Promise<QsConfig | null>;
type GetQsStatusFn = (indexName: string) => Promise<QsBuildStatus | null>;
type AssertIndexNeverReadableFn = (indexName: string) => Promise<void>;
type WriteSynonymsProofManifestFn = (input: WriteSynonymsProofManifestInput) => Promise<void>;
type ListApiKeysFn = () => Promise<ApiKeyListItem[]>;
type GetPublicInfrastructureRawFn = () => Promise<{
	status: number;
	body: unknown;
	text: string;
}>;
type ArrangePublicInfrastructureCanaryVmFn = () => Promise<PublicInfrastructureCanaryVm>;
type DiscoverWithApiKeyFn = (
	indexName: string,
	apiKey: string
) => Promise<{
	status: number;
	body: {
		vm?: string;
		flapjack_url?: string;
		ttl?: number;
		service_type?: string;
	} | null;
}>;
type SetBillingPlanFn = (plan: 'free' | 'shared') => Promise<void>;
type SetBillingPlanForCustomerFn = (customerId: string, plan: 'free' | 'shared') => Promise<void>;
type GetAccountPayloadForTokenFn = (
	token: string
) => Promise<{ id?: string; billing_plan?: 'free' | 'shared' }>;
type SeedEventPayload = {
	eventType: 'view' | 'click' | 'conversion';
	eventSubtype?: string;
	eventName: string;
	userToken: string;
	objectIDs: string[];
	timestampMs?: number;
};
type SeedEventsFn = (indexName: string, events: SeedEventPayload[]) => Promise<void>;
type GetDebugEventsFn = (
	indexName: string,
	query?: { eventType?: string; status?: string; limit?: number; from?: number; until?: number }
) => Promise<{ events: DebugEvent[]; count: number }>;
type SeedInvoiceFn = () => Promise<{ id: string }>;
type SeedInvoiceWithPdfUrlFn = () => Promise<{ id: string }>;
type SeedAdminDraftInvoiceFn = (
	customer: CreatedFixtureUser,
	month?: string
) => Promise<{ id: string }>;
type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
export type LoginAsFn = (email: string, password: string) => Promise<string>;
type ArrangeTrackedCustomerSessionOptions = {
	emailPrefix: string;
	password?: string;
	name?: string;
	verifyEmail?: boolean;
};
type ArrangeTrackedCustomerSessionFn = (
	page: Page,
	options: ArrangeTrackedCustomerSessionOptions
) => Promise<CreatedFixtureUser>;
type ArrangeSharedTrackedCustomerSessionFixture = {
	/** Provision (once per worker) or reuse the shared tracked customer, and apply its auth cookie to `page`. */
	arrange: ArrangeTrackedCustomerSessionFn;
	/** Read the count of POST /auth/login + POST /auth/register requests observed on shared-fixture pages. */
	getAuthCallCount: () => number;
	/** Read endpoint-level POST /auth/login and POST /auth/register totals for failure diagnostics. */
	getAuthCallTotals: () => SharedAuthCallTotals;
};
type WaitForStripeDefaultPaymentMethodFn = (
	stripeCustomerId: string,
	expectedPaymentMethodId: string
) => Promise<string>;
type GetEstimatedBillFn = (month?: string) => Promise<EstimatedBillResponse | null>;
type SeedMultiUserScenarioFn = () => Promise<{
	primaryUser: CreatedFixtureUser;
	secondaryUser: CreatedFixtureUser;
}>;
type AdminDeleteCustomerFn = (customerId: string) => Promise<void>;
type AdminReactivateCustomerFn = (customerId: string) => Promise<void>;
type AdminSuspendCustomerFn = (customerId: string) => Promise<void>;
type SeedAdminDeploymentFn = (
	customer: CreatedFixtureUser,
	options?: AdminDeploymentSeedOptions
) => Promise<AdminDeploymentFixture>;
type SeedAdminVmLifecycleTimelineFn = () => Promise<AdminVmLifecycleTimelineFixture>;
type ReadAdminVmHostMetricsEvidenceParams = {
	region?: string;
	vmId?: string;
};
type AdminVmHostMetricsEvidence = {
	vmId: string;
	metrics: VmHostMetricsResponse | null;
};
type ReadAdminVmHostMetricsEvidenceFn = (
	params: ReadAdminVmHostMetricsEvidenceParams
) => Promise<AdminVmHostMetricsEvidence>;
type ElementHasHorizontalOverflowFn = (locator: Locator) => Promise<boolean>;
type GetDisposableTenantRateCardSnapshotFn = () => Promise<MarketingPricingContractSnapshot>;
type ArrangeBillingPortalCustomerFn = () => Promise<ArrangeBillingPortalCustomerResult>;
type CreateFreshSignupIdentityFn = () => FreshSignupIdentity;
type FindCustomerStatusViaStagingSsmFn = (email: string) => Promise<StagingCustomerStatusEvidence>;
type FindPaidInvoiceEvidenceViaStagingSsmFn = (
	invoiceId: string
) => Promise<StagingPaidInvoiceEvidence>;
type CompleteFreshSignupEmailVerificationFn = (
	page: Page,
	email: string,
	password?: string
) => Promise<{ verificationToken: string }>;
type EnsureLocalSharedVmInventoryFn = (region: string) => Promise<void>;
type IndexInfrastructureBrowserContract = {
	indexName: string;
	primary: { region: string; status: string; utilization: 'Green' };
	replica: { region: string; status: 'Active'; lagOperations: 37; utilization: 'Yellow' };
	headroom: 'Comfortable';
	failover: string;
	forbiddenText: string[];
	footprint: {
		documents: string;
		storage: string;
		searchRequests: string;
		writeOperations: string;
	};
};
type ArrangeIndexInfrastructureFn = (
	customer: CreatedFixtureUser,
	indexName: string,
	primaryRegion: string,
	replicaRegion: string
) => Promise<IndexInfrastructureBrowserContract>;
type ArrangePaidInvoiceForFreshSignupFn = (
	email: string,
	password: string
) => Promise<ArrangePaidInvoiceForFreshSignupResult>;
type ArrangeFreshSignupToDashboardFn = (
	page: Page,
	signup: FreshSignupIdentity,
	beforeDocumentReplacement?: BeforeDocumentReplacementFn
) => Promise<ArrangeFreshSignupToDashboardResult>;
type IsFreshSignupArrangePrerequisiteFailureFn = (alertText: string) => boolean;
type ThrowFreshSignupArrangeFailureFn = (input: {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
}) => never;

type E2eFixtures = {
	/** Capture CSP violations across document replacements and count audited route responses. */
	cspAudit: CspAudit;
	/** Resolved API origin from resolveFixtureEnv (single env-contract owner). */
	apiUrl: string;
	/** Seed an index via the admin API and auto-delete after the test. */
	seedIndex: SeedIndexFn;
	/** Seed an index for a newly-created customer fixture without switching browser auth state. */
	seedCustomerIndex: SeedCustomerIndexFn;
	/** Register an index name for teardown when the index is created via UI flow. */
	registerIndexForCleanup: RegisterIndexForCleanupFn;
	/** Seed a synonym through fixture-owned bearer-token API access. */
	seedSynonym: SeedSynonymFn;
	/** Read a synonym object through fixture-owned bearer-token API access. */
	getSynonym: GetSynonymFn;
	/** Search synonyms through fixture-owned bearer-token API access. */
	searchSynonyms: SearchSynonymsFn;
	/** Clear all synonyms through fixture-owned bearer-token API access. */
	clearSynonyms: ClearSynonymsFn;
	/** Seed query suggestions config through fixture-owned bearer-token API access. */
	seedQsConfig: SeedQsConfigFn;
	/** Read query suggestions config through fixture-owned bearer-token API access. */
	getQsConfig: GetQsConfigFn;
	/** Read query suggestions build status through fixture-owned bearer-token API access. */
	getQsStatus: GetQsStatusFn;
	/** Prove an index stays unreadable across the seeded-index readiness window. */
	assertIndexNeverReadable: AssertIndexNeverReadableFn;
	/** Emit shell-readable Stage 5 synonyms proof metadata and cleanup contract. */
	writeSynonymsProofManifest: WriteSynonymsProofManifestFn;
	/** Remove leaked safe-to-delete test indexes from prior runs for the shared fixture user. */
	cleanupFixtureIndexes: CleanupFixtureIndexesFn;
	/** Seed an API key and auto-revoke after the test. */
	seedApiKey: SeedApiKeyFn;
	/** Seed one or more rules and auto-delete them after the test. */
	seedRules: SeedRulesFn;
	/** Seed a personalization strategy through fixture-owned bearer-token API access. */
	seedPersonalizationStrategy: SeedPersonalizationStrategyFn;
	/** Seed Insights events via POST to the flapjack engine for debug-event testing. */
	seedEvents: SeedEventsFn;
	/** Read debug events for an index through fixture-owned API access. */
	getDebugEvents: GetDebugEventsFn;
	/** Read a single rule by objectID through fixture-owned API access. */
	getRule: GetRuleFn;
	/** Search rules through fixture-owned API access. */
	searchRules: SearchRulesFn;
	/** Read clipboard text through fixture-owned browser permission seam. */
	readClipboardText: ReadClipboardTextFn;
	/** Read positive-area SVG text boxes through fixture-owned DOM inspection. */
	readVisibleSvgTextBoxes: ReadVisibleSvgTextBoxesFn;
	/** Read API-key rows for the authenticated customer through fixture-owned API access. */
	listApiKeys: ListApiKeysFn;
	/** Read the anonymous public infrastructure response without browser auth state. */
	getPublicInfrastructureRaw: GetPublicInfrastructureRawFn;
	/** Seed one local VM row that proves public infrastructure keeps private VM facts anonymous. */
	arrangePublicInfrastructureCanaryVm: ArrangePublicInfrastructureCanaryVmFn;
	/** Call /discover with a bearer API key through fixture-owned API access. */
	discoverWithApiKey: DiscoverWithApiKeyFn;
	/** Temporarily switch the authenticated customer between free and shared plans. */
	setBillingPlan: SetBillingPlanFn;
	/** Set a specific customer's plan through fixture-owned admin mutation flow. */
	setBillingPlanForCustomer: SetBillingPlanForCustomerFn;
	/** Read /account payload for a specific auth token through fixture-owned retry semantics. */
	getAccountPayloadForToken: GetAccountPayloadForTokenFn;
	/** Seed a recommendation-ready index with deterministic object/facet fixture data. */
	seedRecommendationsConfig: SeedRecommendationsConfigFn;
	/** Seed an index backed by Flapjack with searchable documents. */
	seedSearchableIndex: SeedSearchableIndexFn;
	/** Seed an index backed by Flapjack with deterministic Metrics-ready document counts. */
	seedMetricsSearchableIndex: SeedMetricsSearchableIndexFn;
	/** Seed isolated current-month rows consumed by the dashboard usage APIs. */
	seedDashboardUsage: SeedDashboardUsageFn;
	/** Ensure an invoice exists for the test user and return its ID. */
	seedInvoice: SeedInvoiceFn;
	/** Ensure a finalized invoice with `pdf_url` exists and return its ID. */
	seedInvoiceWithPdfUrl: SeedInvoiceWithPdfUrlFn;
	/** Create a login-capable user through POST /auth/register for cross-user scenarios. */
	createUser: CreateUserFn;
	/** Login as an explicit user and return a fresh token. */
	loginAs: LoginAsFn;
	/** Create a tracked disposable customer and authenticate the browser as that customer. */
	arrangeTrackedCustomerSession: ArrangeTrackedCustomerSessionFn;
	/** Poll Stripe customer state until the expected default payment method is active. */
	waitForStripeDefaultPaymentMethod: WaitForStripeDefaultPaymentMethodFn;
	/** Fetch the authenticated customer's current estimated bill. */
	getEstimatedBill: GetEstimatedBillFn;
	/** Seed two unique users for multi-user workflows. */
	seedMultiUserScenario: SeedMultiUserScenarioFn;
	/** Soft-delete an active customer through the existing admin route. */
	adminDeleteCustomer: AdminDeleteCustomerFn;
	/** Reactivate a suspended customer through the existing admin route. */
	adminReactivateCustomer: AdminReactivateCustomerFn;
	/** Suspend an active customer through the existing admin route. */
	adminSuspendCustomer: AdminSuspendCustomerFn;
	/** Seed a real admin-visible deployment row for a disposable customer. */
	seedAdminDeployment: SeedAdminDeploymentFn;
	/** Seed a draft invoice owned by a disposable customer for the admin billing table. */
	seedAdminDraftInvoice: SeedAdminDraftInvoiceFn;
	/** Seed the local admin VM autorepair lifecycle browser specimen. */
	seedAdminVmLifecycleTimeline: SeedAdminVmLifecycleTimelineFn;
	/** Read raw admin VM host-metrics evidence without formatting browser expectations. */
	readAdminVmHostMetricsEvidence: ReadAdminVmHostMetricsEvidenceFn;
	/** Create an isolated admin browser session and expose fixture-owned durable revocation. */
	arrangeIsolatedAdminSession: ArrangeIsolatedAdminSessionFn;
	/** Measure horizontal overflow through fixture-owned DOM inspection. */
	elementHasHorizontalOverflow: ElementHasHorizontalOverflowFn;
	/** Create a disposable tenant and return a normalized snapshot of /admin/tenants/{id}/rate-card. */
	getDisposableTenantRateCardSnapshot: GetDisposableTenantRateCardSnapshotFn;
	/** Provision a disposable customer fixture that can access Stripe portal with subscription state arranged. */
	arrangeBillingPortalCustomer: ArrangeBillingPortalCustomerFn;
	/** Create unique, deterministic signup credentials for fresh-user browser flows. */
	createFreshSignupIdentity: CreateFreshSignupIdentityFn;
	/** Read customer status evidence from staging DB through the shared lookup seam. */
	findCustomerStatusViaStagingSsm: FindCustomerStatusViaStagingSsmFn;
	/** Read paid-invoice evidence for the fixture user from staging DB through the shared lookup seam. */
	findPaidInvoiceEvidenceViaStagingSsm: FindPaidInvoiceEvidenceViaStagingSsmFn;
	/** Resolve a real Mailpit token and complete /verify-email/{token} in the browser. */
	completeFreshSignupEmailVerification: CompleteFreshSignupEmailVerificationFn;
	/** Keep local browser create-index placement pointed at the current Flapjack process. */
	ensureLocalSharedVmInventory: EnsureLocalSharedVmInventoryFn;
	/** Arrange the customer-safe Infrastructure payload and its exact browser expectations. */
	arrangeIndexInfrastructure: ArrangeIndexInfrastructureFn;
	/** Advance a fresh verified signup through paid billing and invoice-email evidence. */
	arrangePaidInvoiceForFreshSignup: ArrangePaidInvoiceForFreshSignupFn;
	/** Create a fresh signup through UI and land on /console with remote-target fallback. */
	arrangeFreshSignupToDashboard: ArrangeFreshSignupToDashboardFn;
	/** Detects known prerequisite/setup failures surfaced from fresh-signup UI alerts. */
	isFreshSignupArrangePrerequisiteFailure: IsFreshSignupArrangePrerequisiteFailureFn;
	/** Throws a fixture-owned fail-closed setup error for fresh-signup prerequisites. */
	throwFreshSignupArrangeFailure: ThrowFreshSignupArrangeFailureFn;
	/** Default region for index creation (via resolveFixtureEnv). */
	testRegion: string;
};

type E2eInternalFixtures = {
	/** Internal registry used by fixtures to clean up test-created indexes. */
	_trackIndexForCleanup: RegisterIndexForCleanupFn;
	/** Internal registry used by fixtures to clean up test-created customers. */
	_trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

type E2eWorkerFixtures = {
	/** Provision ONE tracked customer per worker and reuse its session across every describe-scoped lane. */
	arrangeSharedTrackedCustomerSession: ArrangeSharedTrackedCustomerSessionFixture;
};

// ---------------------------------------------------------------------------
// Extended test object
// ---------------------------------------------------------------------------

export const test = base.extend<E2eFixtures & E2eInternalFixtures, E2eWorkerFixtures>({
	// Override the built-in page fixture so that every page.goto() call waits
	// for the network to be idle before returning.  In Vite dev mode the client
	// JS is served as individual ES modules loaded via async import().  The
	// default waitUntil:'load' resolves as soon as the initial HTML document and
	// synchronous resources are ready — well before Svelte components hydrate
	// and register their onclick handlers.  Without networkidle the test can
	// click a button before the event listener is attached and the interaction
	// is silently dropped.
	page: async ({ page }, use) => {
		const originalGoto = page.goto.bind(page);
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		(page as any).goto = async (
			...args: Parameters<typeof originalGoto>
		): ReturnType<typeof originalGoto> => {
			const response = await originalGoto(...args);
			// Remote staging pages can keep long-lived requests open, so waiting
			// for networkidle can deadlock navigation in LB-2/LB-3 proofs.
			if (isRemoteTargetMode()) {
				return response;
			}
			await page.waitForLoadState('networkidle');
			return response;
		};

		// Auto-accept browser confirm/alert dialogs so that tests exercising
		// buttons that use window.confirm() for confirmation behave like a user
		// clicking OK.  Without this, headless Chromium dismisses the dialog
		// with false, which triggers e.preventDefault() and blocks the action.
		page.on('dialog', (dialog) => dialog.accept());

		await use(page);
	},

	cspAudit: async ({ page }, use) => {
		await use(await installCspAudit(page));
	},

	testRegion: async ({}, use) => {
		await use(fixtureEnv.testRegion);
	},

	apiUrl: async ({}, use) => {
		await use(fixtureEnv.apiUrl);
	},

	arrangeIsolatedAdminSession: async ({ browser, baseURL }, use) => {
		const contexts: BrowserContext[] = [];

		await use(async () => {
			const context = await browser.newContext({
				baseURL,
				storageState: { cookies: [], origins: [] }
			});
			contexts.push(context);
			const page = await context.newPage();
			await loginIsolatedAdminPage(page);
			return {
				page,
				revokeCurrentSession: async () => {
					await revokeAdminSessionToken(await readAdminSessionCookie(page));
				}
			};
		});

		for (const context of contexts.reverse()) {
			await context.close().catch(() => undefined);
		}
	},

	_trackIndexForCleanup: async ({}, use) => {
		await runTrackedIndexCleanup(async (trackIndexForCleanup) => {
			await use(trackIndexForCleanup);
		});
	},

	_trackCustomerForCleanup: async ({}, use) => {
		await runTrackedCustomerCleanup(async (trackCustomerForCleanup) => {
			await use(trackCustomerForCleanup);
		});
	},

	createUser: async ({ _trackCustomerForCleanup }, use) => {
		await use((email, password, name) =>
			createRegisteredUser({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password,
				name,
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	getDisposableTenantRateCardSnapshot: async ({ _trackCustomerForCleanup }, use) => {
		await use(async () => {
			return fetchDisposableTenantRateCardSnapshot({
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				trackCustomerForCleanup: _trackCustomerForCleanup
			});
		});
	},

	arrangeBillingPortalCustomer: async ({ _trackCustomerForCleanup }, use) => {
		await use(() =>
			arrangeBillingPortalCustomer({
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	createFreshSignupIdentity: async ({}, use) => {
		await use(() => buildFreshSignupIdentity());
	},

	findCustomerStatusViaStagingSsm: async ({}, use) => {
		await use((email) => findCustomerStatusViaStagingSsm(email));
	},

	findPaidInvoiceEvidenceViaStagingSsm: async ({}, use) => {
		await use((invoiceId: string) =>
			findPaidInvoiceEvidenceViaStagingSsm(
				requireNonEmptyString(
					fixtureEnv.userEmail ?? '',
					'findPaidInvoiceEvidenceViaStagingSsm requires fixture user email'
				),
				invoiceId
			)
		);
	},

	completeFreshSignupEmailVerification: async ({}, use) => {
		await use((page, email, password) =>
			completeFreshSignupEmailVerificationViaRoute(page, email, password)
		);
	},

	ensureLocalSharedVmInventory: async ({}, use) => {
		await use((region: string) => ensureLocalSharedVmInventoryForRegion(region));
	},

	arrangeIndexInfrastructure: async ({ ensureLocalSharedVmInventory }, use) => {
		const created: Array<{ token: string; indexName: string; replicaVmId?: string }> = [];
		const factory: ArrangeIndexInfrastructureFn = async (
			customer,
			indexName,
			primaryRegion,
			replicaRegion
		) => {
			const tracked: { token: string; indexName: string; replicaVmId?: string } = {
				token: customer.token,
				indexName
			};
			created.push(tracked);
			await ensureLocalSharedVmInventory(primaryRegion);
			await seedSearchableIndexForCustomer({
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				customerId: customer.customerId,
				token: customer.token,
				name: indexName,
				region: primaryRegion,
				flapjackUrl: fixtureEnv.flapjackUrl,
				...createMetricsReadySearchableIndexSeedOptions()
			});
			reconcileIndexPrimaryVmTelemetry(customer.customerId, indexName);

			const seededTopology = seedInfrastructureReplicaTopology({
				customerId: customer.customerId,
				indexName,
				replicaRegion,
				flapjackUrl: fixtureEnv.flapjackUrl
			});
			tracked.replicaVmId = seededTopology.replicaVmId;
			const response = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'GET',
				`/indexes/${encodeURIComponent(indexName)}/infrastructure`,
				{ Authorization: `Bearer ${customer.token}` }
			);
			if (!response.ok) {
				throw new Error(
					`seeded Infrastructure payload failed: ${response.status} ${await response.text()}`
				);
			}
			return infrastructureBrowserContract(
				indexName,
				(await response.json()) as IndexInfrastructureResponse,
				replicaRegion,
				seededTopology.replicaVmId,
				seededTopology.replicaHostname
			);
		};

		await use(factory);

		for (const entry of created.reverse()) {
			await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'DELETE',
				`/indexes/${encodeURIComponent(entry.indexName)}`,
				{ Authorization: `Bearer ${entry.token}` },
				{ confirm: true }
			).catch(() => undefined);
			if (entry.replicaVmId) {
				runFixtureSql(
					`DELETE FROM index_replicas WHERE replica_vm_id = ${quoteSqlLiteral(entry.replicaVmId)}::uuid;
DELETE FROM vm_inventory WHERE id = ${quoteSqlLiteral(entry.replicaVmId)}::uuid;`,
					`clean Infrastructure topology for ${entry.indexName}`
				);
			}
		}
	},

	arrangePaidInvoiceForFreshSignup: async ({ _trackCustomerForCleanup }, use) => {
		await use((email, password) =>
			arrangePaidInvoiceForFreshSignup({
				email,
				password,
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	arrangeFreshSignupToDashboard: async ({ createUser, _trackCustomerForCleanup }, use) => {
		await use((page, signup, beforeDocumentReplacement) =>
			arrangeFreshSignupToDashboardWithFixtureFallback({
				page,
				signup,
				createUser,
				trackCustomerForCleanup: _trackCustomerForCleanup,
				beforeDocumentReplacement
			})
		);
	},

	isFreshSignupArrangePrerequisiteFailure: async ({}, use) => {
		await use((alertText) => isFreshSignupArrangePrerequisiteFailure(alertText));
	},

	throwFreshSignupArrangeFailure: async ({}, use) => {
		await use((input) => throwFreshSignupArrangeFailure(input));
	},

	loginAs: async ({}, use) => {
		await use((email, password) =>
			loginAsUser({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password
			})
		);
	},

	arrangeTrackedCustomerSession: async ({ createUser, loginAs }, use) => {
		const previousToken = _token;
		const previousCustomerId = _customerId;
		await use(async (page, options) => {
			const customer = await arrangeTrackedCustomerSessionForPage({
				page,
				options,
				createUser,
				loginAs
			});
			_token = customer.token;
			_customerId = customer.customerId;
			return customer;
		});
		_token = previousToken;
		_customerId = previousCustomerId;
	},

	arrangeSharedTrackedCustomerSession: [
		async ({}, use) => {
			const cache = new SharedTrackedCustomerCache();
			const authCallCounter = new SharedAuthCallCounter();
			const previousToken = _token;
			const previousCustomerId = _customerId;
			await runTrackedCustomerCleanup(async (trackCustomerForCleanup) => {
				const arrange: ArrangeTrackedCustomerSessionFn = async (page, options) => {
					authCallCounter.observePageContext(page);
					const countedFetch = authCallCounter.countedFetch(fetch);
					const customer = await cache.getOrCreate(() =>
						arrangeTrackedCustomerSessionForPage({
							page,
							options,
							createUser: (email, password, name) =>
								createRegisteredUser({
									apiUrl: fixtureEnv.apiUrl,
									email,
									password,
									name,
									trackCustomerForCleanup,
									fetchImpl: countedFetch
								}),
							loginAs: (email, password) =>
								loginAsUser({
									apiUrl: fixtureEnv.apiUrl,
									email,
									password,
									fetchImpl: countedFetch
								})
						})
					);
					await cache.applyCookieFor(page);
					_token = customer.token;
					_customerId = customer.customerId;
					return customer;
				};
				await use({
					arrange,
					getAuthCallCount: () => authCallCounter.getTotals().total,
					getAuthCallTotals: () => authCallCounter.getTotals()
				});
			});
			_token = previousToken;
			_customerId = previousCustomerId;
		},
		{ scope: 'worker' }
	],

	waitForStripeDefaultPaymentMethod: async ({}, use) => {
		await use(async (stripeCustomerId, expectedPaymentMethodId) => {
			const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
			if (!stripeSecretKey) {
				throw new Error(
					'waitForStripeDefaultPaymentMethod requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
				);
			}

			return waitForStripeDefaultPaymentMethod({
				stripeCustomerId,
				stripeSecretKey,
				expectedPaymentMethodId,
				contextLabel: 'waitForStripeDefaultPaymentMethod'
			});
		});
	},

	getEstimatedBill: async ({}, use) => {
		await use(async (month) => {
			const token = await getAuthToken();
			return fetchEstimatedBillForToken({
				apiUrl: fixtureEnv.apiUrl,
				token,
				month
			});
		});
	},

	seedMultiUserScenario: async ({ createUser }, use) => {
		await use(() => seedMultiUserScenarioWithCreateUser({ createUser }));
	},

	adminDeleteCustomer: async ({}, use) => {
		await use(async (customerId) => {
			const response = await adminApiCall(
				'DELETE',
				`/admin/tenants/${encodeURIComponent(customerId)}`
			);
			if (!response.ok) {
				throw new Error(`adminDeleteCustomer failed: ${response.status} ${await response.text()}`);
			}
		});
	},

	adminReactivateCustomer: async ({}, use) => {
		await use((customerId) =>
			adminReactivateCustomerById({
				apiUrl: fixtureEnv.apiUrl,
				customerId,
				adminKey: fixtureEnv.adminKey
			})
		);
	},

	adminSuspendCustomer: async ({}, use) => {
		await use((customerId) =>
			adminSuspendCustomerById({
				apiUrl: fixtureEnv.apiUrl,
				customerId,
				adminKey: fixtureEnv.adminKey
			})
		);
	},

	seedAdminDeployment: async ({}, use) => {
		await use((customer, options) => seedAdminDeploymentForCustomer(customer, options));
	},

	seedAdminDraftInvoice: async ({}, use) => {
		await use((customer, month = '2025-01') =>
			createDraftInvoiceForCustomer(customer.customerId, month)
		);
	},

	seedAdminVmLifecycleTimeline: async ({}, use) => {
		await use(() => seedAdminVmLifecycleTimelineForFixture());
	},

	readAdminVmHostMetricsEvidence: async ({}, use) => {
		await use((params) => readAdminVmHostMetricsEvidenceForFixture(params));
	},

	elementHasHorizontalOverflow: async ({}, use) => {
		await use((locator) =>
			locator.evaluate((element) => element.scrollWidth > element.clientWidth)
		);
	},

	registerIndexForCleanup: async ({ _trackIndexForCleanup }, use) => {
		await use((name: string, options?: RegisterIndexCleanupOptions) =>
			_trackIndexForCleanup(name, options)
		);
	},

	seedSynonym: async ({}, use) => {
		await use((indexName: string, synonym: Synonym) =>
			saveSynonymWithFixtureApi(indexName, synonym)
		);
	},

	getSynonym: async ({}, use) => {
		await use((indexName: string, objectID: string) =>
			getSynonymWithFixtureApi(indexName, objectID)
		);
	},

	searchSynonyms: async ({}, use) => {
		await use((indexName: string, query = '') => searchSynonymsWithFixtureApi(indexName, query));
	},

	clearSynonyms: async ({}, use) => {
		await use((indexName: string) => clearSynonymsWithFixtureApi(indexName));
	},

	seedQsConfig: async ({}, use) => {
		await use((indexName: string, config: QsConfig) =>
			saveQsConfigWithFixtureApi(indexName, config)
		);
	},

	getQsConfig: async ({}, use) => {
		await use((indexName: string) => getQsConfigWithFixtureApi(indexName));
	},

	getQsStatus: async ({}, use) => {
		await use((indexName: string) => getQsStatusWithFixtureApi(indexName));
	},

	assertIndexNeverReadable: async ({}, use) => {
		await use((indexName: string) => assertIndexNeverBecomesReadable(indexName));
	},

	writeSynonymsProofManifest: async ({}, use) => {
		await use((input: WriteSynonymsProofManifestInput) => writeSynonymsProofManifest(input));
	},

	cleanupFixtureIndexes: async ({}, use) => {
		await use(() => cleanupStaleFixtureIndexesOnce({ force: true }));
	},

	seedIndex: async ({ _trackIndexForCleanup }, use) => {
		const factory: SeedIndexFn = async (name, region, options) => {
			await cleanupStaleFixtureIndexesOnce();
			const r = region ?? fixtureEnv.testRegion;
			const deferCleanup = Boolean(options?.deferCleanup);
			if (deferCleanup) {
				// Reject stale-prefix proof names before provisioning so deferred
				// proof failures never leak an index outside the tracked cleanup seam.
				assertDeferredProofIndexAvoidsStalePrefixes(name);
			}
			// Use the admin endpoint to seed a local Flapjack-backed index directly
			// so tab/detail browser proofs exercise the real local engine. When
			// admin auth is invalid mid-suite (shared-host API restart), fall back
			// to the authenticated customer route. Wrap the whole sequence in a
			// short transport-retry loop so a single fetch disconnect (worker
			// restart, port flap) does not fail the spec.
			const customerId = await getCustomerId();
			for (let attempt = 0; attempt < 3; attempt++) {
				try {
					try {
						await createSeededIndex(customerId, name, r, fixtureEnv.flapjackUrl);
					} catch (error) {
						if (
							error instanceof Error &&
							error.message.toLowerCase().includes('invalid admin key')
						) {
							await createSeededIndexForCurrentCustomer(name, r);
						} else {
							throw error;
						}
					}
					// The admin create endpoint can return before the customer
					// index-read path is consistent enough for the detail page
					// loader. Poll the same read path the UI uses so seeded detail
					// specs do not flake on a 500.
					await waitForSeededIndex(name);
					if (options?.settings) {
						await updateSeededIndexSettings(name, options.settings);
					}
					await raiseRemoteSeededIndexWriteQuota(customerId);
					_trackIndexForCleanup(name, { deferCleanup });
					if (deferCleanup) {
						await writeSynonymsProofManifest({
							indexName: name,
							objectIDs: [],
							manifestPath: options?.proofManifestPath
						});
					}
					return;
				} catch (error) {
					if (isTransientSeedIndexTransportFailure(error) && attempt < 2) {
						await sleep(getTransientRetryDelayMs(attempt));
						continue;
					}
					throw error;
				}
			}
		};

		await use(factory);
	},

	seedCustomerIndex: async ({}, use) => {
		const created: TrackedCustomerIndex[] = [];

		const factory: SeedCustomerIndexFn = async (customer, name, region, flapjackUrl, options) => {
			const r = region ?? fixtureEnv.testRegion;
			await seedCustomerIndexForFixture({
				customer,
				name,
				region: r,
				flapjackUrl: flapjackUrl ?? fixtureEnv.flapjackUrl,
				options,
				trackCreatedIndex: (entry) => created.push(entry)
			});
		};

		await use(factory);

		for (const index of created) {
			if (index.deferCleanup) {
				continue;
			}
			await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'DELETE',
				`/indexes/${encodeURIComponent(index.name)}`,
				{ Authorization: `Bearer ${index.token}` },
				{ confirm: true }
			).catch(() => {
				/* ignore — the owning customer cleanup may already have removed access */
			});
		}
	},

	seedApiKey: async ({}, use) => {
		const created: string[] = [];

		const factory: SeedApiKeyFn = async (name, scopes = ['search']) => {
			const res = await apiCall('POST', '/api-keys', { name, scopes });
			if (!res.ok) {
				throw new Error(`seedApiKey failed: ${res.status} ${await res.text()}`);
			}
			const data = (await res.json()) as { id: string };
			created.push(data.id);
			return { id: data.id };
		};

		await use(factory);

		// Teardown: revoke all seeded keys
		for (const id of created) {
			await apiCall('DELETE', `/api-keys/${id}`).catch(() => {
				/* ignore — may already be gone */
			});
		}
	},

	seedRules: async ({}, use) => {
		const createdRules: Array<{ indexName: string; objectID: string }> = [];

		const factory: SeedRulesFn = async (indexName, rules) => {
			for (const rule of rules) {
				const objectID = rule.objectID;
				if (!objectID) {
					throw new Error('seedRules requires each rule to include a non-empty objectID');
				}
				let saved = false;
				let lastFailure = 'none';
				for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
					const response = await apiCall(
						'PUT',
						`/indexes/${encodeURIComponent(indexName)}/rules/${encodeURIComponent(objectID)}`,
						rule
					);
					if (response.ok) {
						saved = true;
						break;
					}
					const body = await response.text();
					lastFailure = `${response.status} ${body}`;
					if (
						response.status === 404 ||
						response.status === 429 ||
						response.status === 500 ||
						response.status === 503
					) {
						await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
						continue;
					}
					throw new Error(`seedRules failed: ${lastFailure}`);
				}
				if (!saved) {
					throw new Error(`seedRules failed after transient retries: ${lastFailure}`);
				}
				createdRules.push({ indexName, objectID });
			}
		};

		await use(factory);

		for (const createdRule of createdRules) {
			await apiCall(
				'DELETE',
				`/indexes/${encodeURIComponent(createdRule.indexName)}/rules/${encodeURIComponent(createdRule.objectID)}`
			).catch(() => {
				/* ignore — may already be gone */
			});
		}
	},

	seedPersonalizationStrategy: async ({}, use) => {
		const fixture: SeedPersonalizationStrategyFn = async (indexName, strategy) => {
			let lastFailure = 'none';
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const response = await apiCall(
					'PUT',
					`/indexes/${encodeURIComponent(indexName)}/personalization/strategy`,
					strategy
				);
				if (response.ok) return;

				const body = await response.text();
				lastFailure = `${response.status} ${body}`;
				if (
					response.status === 404 ||
					response.status === 429 ||
					response.status === 500 ||
					response.status === 503
				) {
					await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
					continue;
				}
				break;
			}
			throw new Error(`seedPersonalizationStrategy failed: ${lastFailure}`);
		};
		await use(fixture);
	},

	seedEvents: async ({}, use) => {
		const factory: SeedEventsFn = async (indexName, events) => {
			const customerId = await getCustomerId();
			const flapjackIndexUid = buildTenantScopedIndexUid(customerId, indexName);
			const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', fixtureEnv.flapjackUrl);

			const keyRes = await apiCall('POST', `/indexes/${encodeURIComponent(indexName)}/keys`, {
				description: `seedEvents fixture key for ${indexName}`,
				acl: ['search', 'addObject']
			});
			if (!keyRes.ok) {
				throw new Error(`seedEvents: key creation failed: ${keyRes.status} ${await keyRes.text()}`);
			}
			const { key } = (await keyRes.json()) as { key: string };

			const insightsPayload = {
				events: events.map((e) => ({
					eventType: e.eventType,
					eventSubtype: e.eventSubtype ?? undefined,
					eventName: e.eventName,
					index: flapjackIndexUid,
					userToken: e.userToken,
					objectIDs: e.objectIDs,
					timestamp: e.timestampMs ?? Date.now()
				}))
			};

			let lastFailure: string;
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const res = await fetch(`${safeFlapjackUrl}/1/events`, {
					method: 'POST',
					headers: {
						'Content-Type': 'application/json',
						'X-Algolia-API-Key': key,
						'X-Algolia-Application-Id': 'flapjack'
					},
					body: JSON.stringify(insightsPayload)
				});
				if (res.ok || res.status === 202) break;
				lastFailure = `${res.status} ${await res.text()}`;
				if (res.status === 429 || res.status === 500 || res.status === 503) {
					await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
					continue;
				}
				throw new Error(`seedEvents failed: ${lastFailure}`);
			}
		};
		await use(factory);
	},

	getDebugEvents: async ({}, use) => {
		const fixture: GetDebugEventsFn = async (indexName, query) => {
			const params = new URLSearchParams();
			if (query?.eventType) params.set('eventType', query.eventType);
			if (query?.status) params.set('status', query.status);
			if (query?.limit !== undefined) params.set('limit', String(query.limit));
			if (query?.from !== undefined) params.set('from', String(query.from));
			if (query?.until !== undefined) params.set('until', String(query.until));
			const qs = params.toString();
			const path = `/indexes/${encodeURIComponent(indexName)}/events/debug${qs ? `?${qs}` : ''}`;
			const response = await apiCall('GET', path);
			if (!response.ok) {
				throw new Error(`getDebugEvents failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as { events: DebugEvent[]; count: number };
		};
		await use(fixture);
	},

	getRule: async ({}, use) => {
		const fixture: GetRuleFn = async (indexName, objectID) => {
			const response = await apiCall(
				'GET',
				`/indexes/${encodeURIComponent(indexName)}/rules/${encodeURIComponent(objectID)}`
			);
			if (!response.ok) {
				throw new Error(`getRule failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as Rule;
		};
		await use(fixture);
	},

	searchRules: async ({}, use) => {
		const fixture: SearchRulesFn = async (indexName, query = '', page = 0, hitsPerPage = 50) => {
			const response = await apiCall(
				'POST',
				`/indexes/${encodeURIComponent(indexName)}/rules/search`,
				{
					query,
					page,
					hitsPerPage
				}
			);
			if (!response.ok) {
				throw new Error(`searchRules failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as RuleSearchResponse;
		};
		await use(fixture);
	},

	readClipboardText: async ({}, use) => {
		const fixture: ReadClipboardTextFn = async (page) => {
			try {
				return await page.evaluate(async () => navigator.clipboard.readText());
			} catch (error) {
				throw new Error(
					`readClipboardText failed to access navigator.clipboard.readText(): ${setupFailureDetailsFromError(error)}`,
					{ cause: error }
				);
			}
		};
		await use(fixture);
	},

	readVisibleSvgTextBoxes: async ({}, use) => {
		const fixture: ReadVisibleSvgTextBoxesFn = async (locator) =>
			locator.evaluateAll(extractVisibleSvgTextBoxes as (svgs: SVGSVGElement[]) => SvgTextBox[]);
		await use(fixture);
	},

	listApiKeys: async ({}, use) => {
		await use(async () => {
			const res = await apiCall('GET', '/api-keys');
			if (!res.ok) {
				throw new Error(`listApiKeys failed: ${res.status} ${await res.text()}`);
			}
			const data = (await res.json()) as unknown;
			if (!Array.isArray(data)) {
				throw new Error('listApiKeys failed: expected array response from /api-keys');
			}
			return data as ApiKeyListItem[];
		});
	},

	getPublicInfrastructureRaw: async ({}, use) => {
		await use(async () => {
			const response = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'GET',
				'/public/infrastructure',
				{}
			);
			const text = await response.text();
			let body: unknown;
			try {
				body = JSON.parse(text) as unknown;
			} catch {
				body = null;
			}

			return { status: response.status, body, text };
		});
	},

	arrangePublicInfrastructureCanaryVm: async ({}, use) => {
		const created: PublicInfrastructureCanaryVm[] = [];
		await use(async () => {
			const canary = seedPublicInfrastructureCanaryVm();
			created.push(canary);
			return canary;
		});

		for (const canary of created.reverse()) {
			restorePublicInfrastructureCanaryVm(canary);
		}
	},

	discoverWithApiKey: async ({}, use) => {
		await use(async (indexName: string, apiKey: string) => {
			const response = await fetch(
				`${fixtureEnv.apiUrl}/discover?index=${encodeURIComponent(indexName)}`,
				{
					headers: {
						Authorization: `Bearer ${apiKey}`
					}
				}
			);

			let body: {
				vm?: string;
				flapjack_url?: string;
				ttl?: number;
				service_type?: string;
			} | null;
			try {
				body = (await response.json()) as {
					vm?: string;
					flapjack_url?: string;
					ttl?: number;
					service_type?: string;
				};
			} catch {
				body = null;
			}

			return {
				status: response.status,
				body
			};
		});
	},

	setBillingPlan: async ({}, use) => {
		let originalPlan: 'free' | 'shared' | null = null;

		const switchPlan: SetBillingPlanFn = async (plan) => {
			if (originalPlan === null) {
				originalPlan = await getCurrentBillingPlan();
			}
			if (originalPlan === plan) {
				return;
			}
			await updateBillingPlan(plan);
		};

		await use(switchPlan);

		if (originalPlan !== null) {
			await updateBillingPlan(originalPlan).catch(() => {
				/* ignore teardown failures */
			});
		}
	},

	setBillingPlanForCustomer: async ({}, use) => {
		await use(async (customerId, plan) => {
			await updateBillingPlan(plan, customerId);
		});
	},

	getAccountPayloadForToken: async ({}, use) => {
		await use(async (token) => {
			return getAccountPayloadForTokenWithRetries(token, 'GET /account');
		});
	},

	seedRecommendationsConfig: async ({ testRegion, _trackIndexForCleanup }, use) => {
		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion,
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: fixtureEnv.flapjackUrl
		});
		const factory: SeedRecommendationsConfigFn = async (name, region) => {
			await cleanupStaleFixtureIndexesOnce();
			const targetRegion = region ?? fixtureEnv.testRegion;
			if (targetRegion === testRegion) {
				try {
					await seedSearchableIndex(name);
				} catch (error) {
					const message = error instanceof Error ? error.message : String(error);
					if (!message.toLowerCase().includes('index limit reached')) {
						throw error;
					}
					await cleanupStaleFixtureIndexesOnce({ force: true });
					try {
						await seedSearchableIndex(name);
					} catch (retryError) {
						throw new Error(
							`seedRecommendationsConfig failed after forced stale-index cleanup retry: ${retryError instanceof Error ? retryError.message : String(retryError)}`,
							{ cause: retryError }
						);
					}
				}
			} else {
				const customerId = await getCustomerId();
				await createSeededIndex(customerId, name, targetRegion, fixtureEnv.flapjackUrl);
				await waitForSeededIndex(name);
			}
			_trackIndexForCleanup(name);
			return {
				indexName: name,
				primaryObjectID: 'doc-1',
				secondaryObjectID: 'doc-2',
				facetName: RECOMMENDATION_FIXTURE_FACET_NAME,
				facetValue: RECOMMENDATION_FIXTURE_FACET_VALUE,
				missingFacetValue: RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE
			};
		};

		await use(factory);
	},

	seedSearchableIndex: async ({ testRegion }, use) => {
		const cleanupIndexes: string[] = [];
		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion,
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: fixtureEnv.flapjackUrl
		});
		const factory: SeedSearchableIndexFn = async (name, options) => {
			await cleanupStaleFixtureIndexesOnce();
			let result;
			try {
				result = await seedSearchableIndex(name, options);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				if (!message.toLowerCase().includes('index limit reached')) {
					throw error;
				}
				await cleanupStaleFixtureIndexesOnce({ force: true });
				try {
					result = await seedSearchableIndex(name, options);
				} catch (retryError) {
					throw new Error(
						`seedSearchableIndex failed after forced stale-index cleanup retry: ${retryError instanceof Error ? retryError.message : String(retryError)}`,
						{ cause: retryError }
					);
				}
			}
			cleanupIndexes.push(name);
			return result;
		};

		await use(factory);

		// Teardown: delete seeded indexes. Flapjack index keys are VM-side and
		// do not expose key IDs for revocation through this API surface.
		for (const name of cleanupIndexes) {
			await apiCall('DELETE', `/indexes/${encodeURIComponent(name)}`, { confirm: true }).catch(
				() => {}
			);
		}
	},

	seedMetricsSearchableIndex: async ({ seedSearchableIndex }, use) => {
		const factory: SeedMetricsSearchableIndexFn = async (name) => {
			const result = await seedSearchableIndex(
				name,
				createMetricsReadySearchableIndexSeedOptions()
			);
			if (!result.metrics) {
				throw new Error(`seedMetricsSearchableIndex did not return Metrics readiness for ${name}`);
			}
			return { ...result, metrics: result.metrics };
		};

		await use(factory);
	},

	seedDashboardUsage: async ({ page, arrangeTrackedCustomerSession }, use) => {
		const cleanupTasks: Array<() => Promise<void>> = [];
		let bodyFailure: unknown;
		try {
			await use(
				createDashboardUsageSeedFactory({
					adminApiCall,
					apiCall,
					arrangeCustomerSession: (seedId) =>
						arrangeTrackedCustomerSession(page, {
							emailPrefix: 'dashboard-usage',
							name: `E2E Dashboard Usage ${seedId}`
						}),
					currentBillingMonth: currentUtcBillingMonth,
					registerCleanup: (cleanup) => {
						cleanupTasks.push(cleanup);
					}
				})
			);
		} catch (error) {
			bodyFailure = error;
		}

		const cleanupFailures: unknown[] = [];
		for (const cleanup of cleanupTasks.reverse()) {
			try {
				await cleanup();
			} catch (error) {
				cleanupFailures.push(error);
			}
		}
		if (bodyFailure && cleanupFailures.length > 0) {
			throw new AggregateError(
				[bodyFailure, ...cleanupFailures],
				'seedDashboardUsage cleanup failed after fixture body failure'
			);
		}
		if (bodyFailure) {
			throw bodyFailure;
		}
		if (cleanupFailures.length > 0) {
			throw new AggregateError(cleanupFailures, 'seedDashboardUsage cleanup failed');
		}
	},

	seedInvoice: async ({}, use) => {
		const factory: SeedInvoiceFn = async () => {
			// Prefer existing invoices to avoid generating unnecessary data.
			const invoices = await listInvoicesBestEffort();
			if (invoices.length > 0) {
				return { id: invoices[0].id };
			}
			// No invoices exist — generate a draft via admin API.
			return createDraftInvoice('2025-01');
		};
		await use(factory);
	},

	seedInvoiceWithPdfUrl: async ({}, use) => {
		const factory: SeedInvoiceWithPdfUrlFn = async () => {
			const invoices = await listInvoicesBestEffort();

			// Reuse an existing invoice that already has Stripe PDF metadata.
			for (const invoice of invoices) {
				const detail = await getInvoiceDetailForFixture(invoice.id);
				if (detail?.pdf_url) {
					return { id: detail.id };
				}
			}

			// Otherwise finalize a draft invoice to produce pdf_url.
			const draftInvoiceId =
				invoices.find((invoice) => invoice.status === 'draft')?.id ??
				(await createDraftInvoice('2025-01')).id;
			const finalizeRes = await adminApiCall(
				'POST',
				`/admin/invoices/${encodeURIComponent(draftInvoiceId)}/finalize`
			);
			if (!finalizeRes.ok) {
				throw new Error(
					`seedInvoiceWithPdfUrl failed: ${finalizeRes.status} ${await finalizeRes.text()}`
				);
			}
			const finalized = (await finalizeRes.json()) as InvoiceDetailApiItem;
			if (!finalized.pdf_url) {
				throw new Error('seedInvoiceWithPdfUrl failed: finalized invoice returned null pdf_url');
			}
			return { id: finalized.id };
		};
		await use(factory);
	}
});

// ---------------------------------------------------------------------------
// Retained migration job arrange helpers.
//
// A completed retained import job normally requires a live third-party source
// catalog, which no local proof can supply. These helpers seed the terminal row
// the retained-job detail route reads, then prove it is genuinely readable
// through the product API before any spec asserts on the rendered page — so a
// seeded row that the API would reject fails here rather than as a confusing
// page assertion.
// ---------------------------------------------------------------------------

/** Matches the `algolia_app_id ~ '^[A-Z0-9]+$'` column check for every provider. */
const RETAINED_MIGRATION_JOB_SOURCE_APP_ID = 'E2ECUTOVERPROOF';

export type SeedCompletedRetainedMigrationJobParams = {
	/** API base URL of the stack that must be able to read the job back. */
	apiUrl: string;
	/** Owning customer, addressed by the credentials the proof logs in with. */
	email: string;
	password: string;
	sourceProvider: MigrationSourceProvider;
	/** Source index name shown as the job's source. */
	sourceName: string;
	/** Destination index name; also the job's tenant id and logical target. */
	destinationTarget: string;
	region?: string;
};

export type SeededRetainedMigrationJob = {
	jobId: string;
	sourceProvider: MigrationSourceProvider;
	sourceName: string;
	destinationTarget: string;
};

export async function seedCompletedRetainedMigrationJob({
	apiUrl,
	email,
	password,
	sourceProvider,
	sourceName,
	destinationTarget,
	region = 'us-east-1'
}: SeedCompletedRetainedMigrationJobParams): Promise<SeededRetainedMigrationJob> {
	const context = `seedCompletedRetainedMigrationJob(${sourceProvider})`;
	const idempotencyKey = `${context}-${destinationTarget}`;
	const quotedTarget = quoteSqlLiteral(destinationTarget);
	const quotedKey = quoteSqlLiteral(idempotencyKey);
	// The terminal shape the table's public-row checks demand for a completed
	// create-destination import: a committed dispatch with an acknowledged engine
	// job, a promoted publication, and no resume state.
	const insertOutput = runFixtureSql(
		[
			'INSERT INTO algolia_import_jobs (',
			'  customer_id, tenant_id, source_provider, algolia_app_id, destination_kind,',
			'  logical_target, destination_region, source_name, engine_job_id,',
			'  dispatch_intent_state, lifecycle_generation, idempotency_key, canonical_fingerprint,',
			'  source_size_bytes, reserved_index_count, reserved_customer_storage_bytes,',
			'  reserved_node_transient_bytes, retryable, resume_intent_generation, resumable,',
			'  resume_count, documents_expected, documents_imported, documents_rejected,',
			'  settings_applied, settings_unsupported, synonyms_expected, synonyms_imported,',
			'  synonyms_rejected, rules_expected, rules_imported, rules_rejected,',
			'  warnings, status, publication_disposition, engine_ack_state,',
			'  terminal_at, terminal_outcome_observed',
			')',
			'SELECT',
			`  customers.id, ${quotedTarget}, ${quoteSqlLiteral(sourceProvider)},`,
			`  ${quoteSqlLiteral(RETAINED_MIGRATION_JOB_SOURCE_APP_ID)}, 'create',`,
			`  ${quotedTarget}, ${quoteSqlLiteral(region)}, ${quoteSqlLiteral(sourceName)},`,
			'  gen_random_uuid(),',
			`  'committed', customers.lifecycle_generation, ${quotedKey}, ${quotedKey},`,
			'  1024, 1, 0,',
			'  0, FALSE, 0, FALSE,',
			'  0, 17, 17, 0,',
			'  1, 0, 0, 0,',
			'  0, 0, 0, 0,',
			"  '[]'::jsonb, 'completed', 'promoted', 'acknowledged',",
			'  NOW(), TRUE',
			'FROM customers',
			`WHERE customers.email = ${quoteSqlLiteral(email)}`,
			"  AND customers.status <> 'deleted'",
			'ON CONFLICT (customer_id, idempotency_key) DO UPDATE',
			'  SET updated_at = NOW()',
			'RETURNING id;'
		].join('\n'),
		context
	);
	// `psql -tA` prints the `INSERT 0 1` command tag alongside the RETURNING row,
	// so take the returned id rather than the whole output. No matching customer
	// inserts nothing and leaves no id to find.
	const jobId = insertOutput.split('\n')[0]?.trim() ?? '';
	if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(jobId)) {
		throw new Error(
			`${context} seeded no job row — no active customer matched ${email} (psql output: ${insertOutput})`
		);
	}

	try {
		await assertRetainedMigrationJobReadable({ apiUrl, email, password, sourceProvider, jobId });
	} catch (readbackFailure) {
		try {
			deleteSeededRetainedMigrationJobs([jobId]);
		} catch (cleanupFailure) {
			// `errors` carries both failures; `cause` names the proximate one, so the
			// rollback failure that turned a recoverable readback error into a leaked
			// seeded row is not lost behind the aggregate summary message.
			throw new AggregateError(
				[readbackFailure, cleanupFailure],
				`${context} readback and rollback both failed`,
				{ cause: cleanupFailure }
			);
		}
		throw readbackFailure;
	}
	return { jobId, sourceProvider, sourceName, destinationTarget };
}

async function assertRetainedMigrationJobReadable({
	apiUrl,
	email,
	password,
	sourceProvider,
	jobId
}: {
	apiUrl: string;
	email: string;
	password: string;
	sourceProvider: MigrationSourceProvider;
	jobId: string;
}): Promise<void> {
	const context = `seedCompletedRetainedMigrationJob(${sourceProvider}) readback`;
	const token = await loginAsUser({ apiUrl, email, password });
	const response = await callJsonApi(
		fetch,
		requireLoopbackHttpUrl('API_URL', apiUrl),
		'GET',
		`/migration/${sourceProvider}/jobs/${encodeURIComponent(jobId)}`,
		{ Authorization: `Bearer ${token}` }
	);
	if (!response.ok) {
		throw new Error(`${context} failed: ${response.status} ${await response.text()}`);
	}
	const job = (await response.json()) as PublicAlgoliaImportJob;
	if (job.id !== jobId || job.sourceProvider !== sourceProvider || job.status !== 'completed') {
		throw new Error(
			`${context} returned an unexpected job: ${JSON.stringify({
				id: job.id,
				sourceProvider: job.sourceProvider,
				status: job.status
			})}`
		);
	}
}

/** Remove seeded retained jobs so the shared database does not accumulate them. */
export function deleteSeededRetainedMigrationJobs(jobIds: readonly string[]): void {
	if (jobIds.length === 0) return;
	const quotedIds = jobIds.map((jobId) => `${quoteSqlLiteral(jobId)}::uuid`).join(', ');
	runFixtureSql(
		`DELETE FROM algolia_import_jobs WHERE id IN (${quotedIds});`,
		'deleteSeededRetainedMigrationJobs'
	);
}

export { expect };
