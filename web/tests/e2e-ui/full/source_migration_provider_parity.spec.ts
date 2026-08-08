/**
 * Full — Source migration provider parity
 *
 * RED browser-unmocked contract for the future shared migration UI. Local
 * Meilisearch and Typesense expectations are loaded from imported source bundles
 * and asserted through the discrete owner-backed job surfaces rendered by
 * ImportJobDetail.svelte and job_presentation.ts. Algolia source extraction
 * remains owned by the existing live probe; its lane only drives the
 * provider-neutral submit/status/cancel/acknowledge/erasure lifecycle.
 */

import { test, expect } from '../../fixtures/fixtures';
import type { APIResponse, Page } from '@playwright/test';
import { formatNumber } from '../../../src/lib/format';
import type {
	SourceMigrationProviderParityConnection,
	SourceMigrationProviderParityContract,
	SourceMigrationLocalProviderParityContract,
	SourceMigrationProviderParityProvider
} from '../../fixtures/source_migration_provider_parity';
import {
	algoliaOriginForApplicationId,
	escapeRegex,
	localProviderOriginForPort,
	pinCurrentFlapjackAsSelectedMigrationBackend,
	resolveAlgoliaCredentials,
	sourceMigrationProviderParityFixture
} from '../../fixtures/source_migration_provider_parity';

// Credentials are entered before discovery and submit assertions. A failure at either
// boundary must not persist the rendered form or network payload in Playwright artifacts.
test.use({
	storageState: { cookies: [], origins: [] },
	trace: 'off',
	screenshot: 'off'
});

const PROVIDER_LABELS: Record<SourceMigrationProviderParityProvider, string> = {
	meilisearch: 'Meilisearch',
	typesense: 'Typesense',
	algolia: 'Algolia'
};

// job_presentation.ts owns these rendered strings; the spec asserts against them, not prose.
const STATUS_COMPLETED = 'Completed';
const STATUS_CANCELLED = 'Cancelled';
const SOURCE_CHANGED_ERROR_COPY = 'The source changed while the import was running.';
const RETAINED_JOB_TRANSITION_TIMEOUT_MS = 120_000;
const LOCAL_PROVIDER_LIFECYCLE_TIMEOUT_MS = RETAINED_JOB_TRANSITION_TIMEOUT_MS * 3 + 60_000;

// MigrationCreatePreview.svelte owns this copy for providers that do not support preview.
const PREVIEW_UNAVAILABLE_COPY =
	'Preview is not available for the selected source. The migration can still run, and compatibility warnings appear once the job starts.';
// job_presentation.ts::previewSeverityLabel owns the preview-side severity vocabulary. The
// retained job carries no severity, so severity is asserted present on the preview and
// absent on the job — never compared field-for-field.
const PREVIEW_SEVERITY_LABELS = ['Hard rejection', 'Warning', 'Scope gap'];

// Only the fields the preview and the retained job render identically through the shared
// MigrationCompatibilityWarnings component. code and locator are equivalent by construction;
// severity (preview-only), message (constant fallback vs real engine text), and summary
// (different sentence builders) are not, so they are deliberately excluded here. Keep locator
// paired with its row's code because locator is conditional in the shared component.
type MigrationWarningShape = {
	warnings: MigrationWarningTuple[];
};

type MigrationWarningTuple = { code: string; locator: string | null };

// Meilisearch/Typesense expose a "<Provider> host URL" identity field; Algolia exposes
// "Algolia Application ID". Both carry their identity value in connection.hostUrl.
function identityFieldLabel(provider: SourceMigrationProviderParityProvider): string {
	return provider === 'algolia'
		? 'Algolia Application ID'
		: `${PROVIDER_LABELS[provider]} host URL`;
}

async function assertProviderChoiceVisible(
	page: Page,
	provider: SourceMigrationProviderParityProvider
) {
	const providerRadio = page.getByRole('radio', { name: PROVIDER_LABELS[provider] });
	await expect(
		providerRadio,
		`${provider} source-connection assertion 1/4: provider choice`
	).toBeVisible();
	return providerRadio;
}

async function connectSource(
	page: Page,
	contract: SourceMigrationProviderParityContract,
	destinationName = contract.connection.destinationName
): Promise<SourceMigrationProviderParityConnection> {
	const providerLabel = PROVIDER_LABELS[contract.provider];
	const connection = { ...contract.connection, destinationName };

	const providerRadio = await assertProviderChoiceVisible(page, contract.provider);
	const identityField = page.getByLabel(identityFieldLabel(contract.provider));
	const apiKeyField = page.getByLabel(`${providerLabel} API key`);
	const connectButton = page.getByRole('button', { name: `Connect to ${providerLabel}` });
	await providerRadio.check();
	await expect(
		identityField,
		`${contract.provider} source-connection assertion 2/4: identity field`
	).toBeVisible();
	await expect(
		apiKeyField,
		`${contract.provider} source-connection assertion 3/4: API-key field`
	).toBeVisible();
	await expect(
		connectButton,
		`${contract.provider} source-connection assertion 4/4: connect action`
	).toBeVisible();
	await identityField.fill(connection.hostUrl);
	await apiKeyField.fill(connection.apiKey);
	await connectButton.click();
	const sourceList = page.getByTestId('migration-source-list');
	await expect(sourceList).toBeVisible();
	await expect(sourceList).toContainText(connection.sourceLabel);
	if (contract.provider === 'meilisearch') {
		await expect(sourceList).toContainText(
			new RegExp(`${escapeRegex(connection.sourceName)}\\s+\\d+ records`)
		);
	}
	await page.getByRole('radio', { name: new RegExp(escapeRegex(connection.sourceName)) }).check();
	await expect(page.getByTestId('migration-selected-source')).toContainText(connection.sourceName);
	await page.getByLabel('Destination index name').fill(connection.destinationName);
	await page.getByRole('button', { name: 'Check destination eligibility' }).click();
	await expect(page.getByTestId('migration-create-review')).toContainText(
		connection.destinationName
	);

	return connection;
}

async function clickStartImport(page: Page): Promise<void> {
	await page.getByRole('button', { name: /^Start import(?: anyway)?$/ }).click();
}

async function submitImport(
	page: Page,
	contract: SourceMigrationProviderParityContract
): Promise<void> {
	const previewButton = page.getByRole('button', { name: 'Preview import', exact: true });
	if ('preview' in contract && !contract.preview.supported) {
		await expect(previewButton).toHaveCount(0);
	} else {
		await previewButton.click();
		const previewOutcome = page
			.getByTestId('migration-preview-counts')
			.or(page.getByTestId('migration-preview-clean'))
			.or(page.getByTestId('migration-preview-error'));
		await expect(previewOutcome.first()).toBeVisible();
	}
	await clickStartImport(page);
}

async function startImport(
	page: Page,
	contract: SourceMigrationProviderParityContract
): Promise<void> {
	await submitImport(page, contract);
	await expect(page.getByTestId('migration-job-detail')).toBeVisible({
		timeout: RETAINED_JOB_TRANSITION_TIMEOUT_MS
	});
}

// Start after an already-completed preview step (no second preview click). Used by the
// preview-before-start lane so the preview shape is captured exactly once.
async function startImportAfterPreview(page: Page): Promise<void> {
	await clickStartImport(page);
	await expect(page.getByTestId('migration-job-detail')).toBeVisible({
		timeout: RETAINED_JOB_TRANSITION_TIMEOUT_MS
	});
}

// Mirrors MigrationCreatePreview.svelte's rendered count line — the component is the
// single source of truth for the format; this pins the exact expected text. Counts are
// single-source-index scoped, so `indexes` is always 1 here.
function previewCountsText(counts: { indexes: number; records: number }): string {
	return `${formatNumber(counts.indexes)} source index · ${formatNumber(counts.records)} records`;
}

// Reads the rendered compatibility-warning rows through the shared component test ids.
// Only code and locator are captured — the two fields preview and job render identically.
async function captureWarningShape(page: Page): Promise<MigrationWarningShape> {
	const warnings = await page.getByTestId('migration-warning-message').evaluateAll((messages) =>
		messages.map((message) => {
			const row = message.parentElement;
			const textFor = (testId: string) =>
				row?.querySelector(`[data-testid="${testId}"]`)?.textContent?.trim() ?? null;
			return {
				code: textFor('migration-warning-code') ?? '',
				locator: textFor('migration-warning-locator')
			};
		})
	);
	return { warnings };
}

function renderedLocatorCount(tuples: MigrationWarningTuple[]): number {
	return tuples.filter((tuple) => tuple.locator !== null).length;
}

function comparableWarningTuples(
	shape: MigrationWarningShape,
	codePattern: RegExp
): MigrationWarningTuple[] {
	return shape.warnings.filter((warning) => codePattern.test(warning.code)).sort((left, right) =>
		`${left.code}\u0000${left.locator ?? ''}`.localeCompare(
			`${right.code}\u0000${right.locator ?? ''}`
		)
	);
}

// Preview-before-start: click Preview (or assert the unsupported affordance), assert the
// exact fixture-owned source counts, prove previewing retained no import job, and return the
// rendered preview warning shape for the post-import equivalence check.
async function previewBeforeStart(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract,
	countRetainedJobs: () => Promise<number>
): Promise<MigrationWarningShape | null> {
	const previewButton = page.getByRole('button', { name: 'Preview import', exact: true });
	if (!contract.preview.supported) {
		await expect(previewButton).toHaveCount(0);
		await expect(page.getByTestId('migration-create-preview')).toContainText(
			PREVIEW_UNAVAILABLE_COPY
		);
		await expect(page.getByTestId('migration-job-detail')).toHaveCount(0);
		return null;
	}

	const retainedJobsBeforePreview = await countRetainedJobs();
	await previewButton.click();
	// Exact text, not a substring: `migration-preview-counts` renders only the count line, so
	// a substring match would accept a rendered `11 source index` for an expected `1`.
	await expect(page.getByTestId('migration-preview-counts')).toHaveText(
		previewCountsText(contract.preview.sourceCounts)
	);
	// Previewing must never create or navigate to a job; the create surface stays mounted.
	await expect(page.getByTestId('migration-job-detail')).toHaveCount(0);
	await expect(page.getByTestId('migration-create-review')).toBeVisible();
	// Navigation absence alone would still pass if preview wrote a retained row while the UI
	// stayed put, and the in-page recent-imports list is loaded once per provider selection
	// (no poll), so it cannot change without a reload. Read the tenant-scoped retained list
	// back instead — that is the surface a stray preview-created job would appear on.
	expect(
		await countRetainedJobs(),
		`source migration provider parity ${contract.provider}: preview retained an import job`
	).toBe(retainedJobsBeforePreview);

	// Wait for the rendered warnings before reading them so the capture is not racing render.
	await expect(page.getByTestId('migration-warning-code').first()).toBeVisible();
	const shape = await captureWarningShape(page);
	expect(
		shape.warnings.length,
		`source migration provider parity ${contract.provider}: preview rendered no compatibility warning codes`
	).toBeGreaterThan(0);
	// Measured over the rows the preview/job equivalence compares, not the full capture: a
	// locator on a preview-only row cannot give the compared locator dimension any teeth.
	expect(
		renderedLocatorCount(comparableWarningTuples(shape, contract.warningCodePattern)),
		`source migration provider parity ${contract.provider}: preview rendered too few warning locators among the codes compared against the retained job`
	).toBeGreaterThanOrEqual(contract.preview.minimumWarningLocators);
	for (const [index, warning] of shape.warnings.entries()) {
		expect(
			warning.code,
			`source migration provider parity ${contract.provider} preview warning code ${index + 1}/${shape.warnings.length}`
		).toMatch(contract.preview.warningCodePattern);
	}
	const severities = await page.getByTestId('migration-warning-severity').allTextContents();
	expect(
		severities.length,
		`source migration provider parity ${contract.provider}: preview rendered no warning severities`
	).toBeGreaterThan(0);
	for (const severity of severities) {
		expect(PREVIEW_SEVERITY_LABELS).toContain(severity.trim());
	}
	return shape;
}

// Field-for-field equivalence between the pre-start preview and the retained job. code and
// locator must match exactly (not merely by count); severity is preview-only, so the job
// must render none — that asymmetry is asserted rather than compared.
async function assertPreviewJobWarningEquivalence(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract,
	preview: MigrationWarningShape
): Promise<void> {
	const job = await captureWarningShape(page);
	const previewTuples = comparableWarningTuples(preview, contract.warningCodePattern);
	// An empty-vs-empty comparison would pass for any defect, so hold the compared preview
	// set non-empty here rather than relying on another assertion to hold the job side.
	expect(
		previewTuples.length,
		`source migration provider parity ${contract.provider}: preview rendered no warning codes comparable with the retained job`
	).toBeGreaterThan(0);
	expect(
		comparableWarningTuples(job, contract.warningCodePattern),
		`source migration provider parity ${contract.provider}: preview/job warning code+locator equivalence`
	).toEqual(previewTuples);
	await expect(
		page.getByTestId('migration-warning-severity'),
		`source migration provider parity ${contract.provider}: retained job carries no warning severity`
	).toHaveCount(0);
}

async function assertJobIdentity(
	page: Page,
	contract: SourceMigrationProviderParityContract,
	connection: SourceMigrationProviderParityConnection
): Promise<void> {
	// ImportJobDetail renders the raw provider id; match case-insensitively so the assertion
	// holds whether the field shows "meilisearch" or a future humanized label.
	await expect(page.getByTestId('migration-job-source-provider')).toContainText(
		new RegExp(escapeRegex(PROVIDER_LABELS[contract.provider]), 'i')
	);
	await expect(page.getByTestId('migration-job-source')).toContainText(connection.sourceName);
	await expect(page.getByTestId('migration-job-destination')).toContainText(
		connection.destinationName
	);
}

// Credential erasure: after the job is submitted the credential form is gone, so the
// provider API-key input no longer exists anywhere on the page.
async function assertCredentialErasure(
	page: Page,
	provider: SourceMigrationProviderParityProvider
): Promise<void> {
	await expect(page.getByLabel(`${PROVIDER_LABELS[provider]} API key`)).toHaveCount(0);
}

// Provider-neutral cancel lifecycle: cancel drives the job to the owner-defined terminal
// "Cancelled" status label. Acknowledgement stays separate so callers can inspect the
// terminal job artifacts before navigation removes them.
async function cancelImport(page: Page): Promise<void> {
	await page.getByRole('button', { name: 'Cancel import' }).click();
	await expect(page.getByTestId('migration-job-status')).toContainText(STATUS_CANCELLED, {
		timeout: RETAINED_JOB_TRANSITION_TIMEOUT_MS
	});
}

async function acknowledgeCancelledImport(page: Page): Promise<void> {
	await page.getByRole('link', { name: 'Start a new import' }).click();
	await expect(page.getByRole('heading', { name: 'Migrate search data' })).toBeVisible();
}

function failureDetail(failure: unknown): string {
	return failure instanceof Error ? failure.message : String(failure);
}

async function runWithCleanup(
	run: () => Promise<void>,
	cleanup: () => Promise<void>
): Promise<void> {
	let runFailure: unknown;
	try {
		await run();
	} catch (error) {
		runFailure = error;
	}

	try {
		await cleanup();
	} catch (cleanupFailure) {
		if (runFailure) {
			// Playwright reporters print an AggregateError's own message but not its
			// `errors` array, so fold both causes into the message. Otherwise a
			// combined lifecycle+cleanup failure reports no actionable detail at all.
			throw new AggregateError(
				[runFailure, cleanupFailure],
				`Parity lifecycle and cleanup failed.\nLifecycle failure: ${failureDetail(runFailure)}\nCleanup failure: ${failureDetail(cleanupFailure)}`
			);
		}
		throw cleanupFailure;
	}

	if (runFailure) throw runFailure;
}

function annotateSourceMethod(contract: SourceMigrationProviderParityContract): void {
	test.info().annotations.push({
		type: 'source-method',
		description: `${contract.provider} source proved via ${contract.method}`
	});
}

function customerIndexUrl(apiUrl: string, name: string): string {
	return new URL(`/indexes/${encodeURIComponent(name)}`, apiUrl).toString();
}

// Tenant-scoped retained-import readback (GET /migration/<provider>/jobs). This is the
// surface `algolia_import_jobs` rows become observable on, so counting it before and after
// the preview click is what proves the report-only preview path retained nothing.
async function countRetainedImportJobs(
	page: Page,
	apiUrl: string,
	provider: SourceMigrationProviderParityProvider,
	customerToken: string
): Promise<number> {
	const jobsUrl = new URL(`/migration/${provider}/jobs`, apiUrl);
	jobsUrl.searchParams.set('limit', '200');
	const response = await page.request.get(jobsUrl.toString(), {
		headers: { Authorization: `Bearer ${customerToken}` }
	});
	expect(
		response.status(),
		`retained import listing failed for ${provider}: ${await response.text()}`
	).toBe(200);
	const body = (await response.json()) as { jobs: unknown[]; nextCursor: string | null };
	expect(
		body.nextCursor,
		`retained import listing for ${provider} returned another page, so the helper cannot report a total`
	).toBeNull();
	return body.jobs.length;
}

async function assertIndexAbsentForCustomer(
	page: Page,
	apiUrl: string,
	name: string,
	customerToken: string
): Promise<void> {
	await expect
		.poll(
			async () => {
				const response = await page.request.get(customerIndexUrl(apiUrl, name), {
					headers: { Authorization: `Bearer ${customerToken}` }
				});
				return response.status();
			},
			{ message: `source migration destination ${name} must remain absent`, timeout: 5_000 }
		)
		.toBe(404);
}

async function deleteAndAssertIndexAbsent(
	page: Page,
	apiUrl: string,
	name: string,
	customerToken: string
): Promise<void> {
	let deletion: APIResponse | undefined;
	await expect
		.poll(
			async () => {
				deletion = await page.request.delete(customerIndexUrl(apiUrl, name), {
					headers: { Authorization: `Bearer ${customerToken}` },
					data: { confirm: true }
				});
				return deletion.status();
			},
			{
				message: `source migration destination ${name} must become deletable after terminal ACK`,
				timeout: 45_000
			}
		)
		.not.toBe(409);
	if (!deletion) {
		throw new Error(`source migration destination cleanup did not run for ${name}`);
	}
	expect(
		deletion.ok() || deletion.status() === 404,
		`source migration destination cleanup failed for ${name}: ${deletion.status()}`
	).toBe(true);
	await assertIndexAbsentForCustomer(page, apiUrl, name, customerToken);
}

async function primeMigrationBackend(
	page: Page,
	apiUrl: string,
	region: string,
	customerToken: string
): Promise<void> {
	const name = `source_migration_backend_prime_${Date.now()}`;
	const response = await page.request.post(new URL('/indexes', apiUrl).toString(), {
		headers: { Authorization: `Bearer ${customerToken}` },
		data: { name, region }
	});
	expect(response.status(), `migration backend prime failed: ${await response.text()}`).toBe(201);
	await deleteAndAssertIndexAbsent(page, apiUrl, name, customerToken);
}

// Exact imported-value proof: each expectation targets a discrete owner-backed job field by
// its real testId (ImportJobDetail summary rows), never composite prose in <main>.
async function assertExactImportedValues(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract
): Promise<void> {
	for (const [index, expectation] of contract.expectations.entries()) {
		await expect(
			page.getByTestId(expectation.testId),
			`source migration provider parity ${contract.provider} ${index + 1}/${contract.expectations.length}: ${expectation.label}`
		).toContainText(expectation.expectedText);
	}
}

// ImportJobDetail renders each compatibility warning's engine `ReportCode` verbatim under
// `migration-warning-code`. The import must render at least one, and every one it renders
// must be attributed to the contract's provider — a warning attributed to another provider
// (or none at all) means the translation report was not provider-scoped.
async function assertProviderAttributedWarningCodes(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract
): Promise<void> {
	const codes = page.getByTestId('migration-warning-code');
	const rendered = await codes.allTextContents();
	expect(
		rendered.length,
		`source migration provider parity ${contract.provider}: import rendered no compatibility warning codes`
	).toBeGreaterThan(0);
	for (const [index, code] of rendered.entries()) {
		expect(
			code.trim(),
			`source migration provider parity ${contract.provider} warning code ${index + 1}/${rendered.length}`
		).toMatch(contract.warningCodePattern);
	}
}

async function resetToMigrateSurface(page: Page): Promise<void> {
	await page.goto('/console/migrate');
	await expect(page.getByRole('heading', { name: 'Migrate search data' })).toBeVisible();
}

async function assertSourceChangedRefusal(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract,
	destinationName: string,
	assertIndexAbsent: (name: string) => Promise<void>
): Promise<void> {
	const connection = await connectSource(page, contract, destinationName);
	await contract.mutateSourceAfterEligibility();
	await submitImport(page, contract);
	await expect(page.getByTestId('migration-start-error')).toContainText(SOURCE_CHANGED_ERROR_COPY);
	await expect(page.getByTestId('migration-create-review')).toContainText(connection.sourceName);
	await contract.assertNoCanaryInBrowserArtifacts(page);
	await assertIndexAbsent(destinationName);
}

// Meilisearch and Typesense share this local-container proof: complete an import and read
// exact imported values from owner fields, then prove the cancel terminal, the source-change
// refusal copy, and destination/canary absence through fixture-owned probes.
type LocalProviderParityDependencies = {
	assertIndexAbsentForCustomer: (name: string, customerToken: string) => Promise<void>;
	deleteAndAssertIndexAbsent: (name: string, customerToken: string) => Promise<void>;
	arrangeCustomer: () => Promise<{ token: string }>;
	primeMigrationBackend: (customerToken: string) => Promise<void>;
	// Seed one active local VM in vm_inventory pointed at this workspace's Flapjack.
	// Source discovery proxies through migration source.rs::backend_target, which picks
	// vm_inventory_repo.list_active(None).next(); with no active target every
	// POST /migration/<provider>/list-indexes fails closed with backend_unavailable.
	ensureLocalTarget: () => Promise<void>;
	// Retained-import readback for the preview-creates-no-job proof.
	countRetainedJobs: (customerToken: string) => Promise<number>;
};

async function assertLocalProviderParityLifecycle(
	page: Page,
	contract: SourceMigrationLocalProviderParityContract,
	dependencies: LocalProviderParityDependencies,
	testRegion: string
): Promise<void> {
	const {
		assertIndexAbsentForCustomer,
		deleteAndAssertIndexAbsent,
		arrangeCustomer,
		primeMigrationBackend,
		ensureLocalTarget,
		countRetainedJobs
	} = dependencies;
	// Keep the method qualifier in the test log context so no provider parity claim is
	// recorded without naming how that provider's source was proved.
	annotateSourceMethod(contract);
	// Arrange the discovery backend before any provider connection: source discovery
	// picks the first active vm_inventory row, so this local target must exist first.
	await ensureLocalTarget();
	const customer = await arrangeCustomer();
	await primeMigrationBackend(customer.token);
	const restoreMigrationBackend = pinCurrentFlapjackAsSelectedMigrationBackend(testRegion);

	await runWithCleanup(
		async () => {
			// Restore the live source to the imported beforeMutation state so a correct create import
			// lands exactly the imported-bundle count. Twice proves retry idempotence.
			await contract.restoreSourceBeforeMutation();
			await contract.restoreSourceBeforeMutation();
			await resetToMigrateSurface(page);

			// Run 1 — preview before start, then complete the import and observe exact imported
			// values plus preview/post-import warning equivalence on the owner-backed job surfaces.
			const connection = await connectSource(page, contract);
			const previewShape = await previewBeforeStart(page, contract, () =>
				countRetainedJobs(customer.token)
			);
			await startImportAfterPreview(page);
			await assertJobIdentity(page, contract, connection);
			await assertCredentialErasure(page, contract.provider);
			await expect(page.getByTestId('migration-job-status')).toContainText(STATUS_COMPLETED, {
				// The retained-job reconciler owns terminal status and runs every 30 seconds.
				// Cover one full production-cadence observation rather than relying on
				// Playwright's shorter default assertion timeout.
				timeout: RETAINED_JOB_TRANSITION_TIMEOUT_MS
			});
			await assertExactImportedValues(page, contract);
			await assertProviderAttributedWarningCodes(page, contract);
			// Preview is supported only for Meilisearch; when previewed, the retained-job warning
			// shape must equal the pre-start preview shape field-for-field.
			if (previewShape) {
				await assertPreviewJobWarningEquivalence(page, contract, previewShape);
			}
			await contract.assertNoCanaryInBrowserArtifacts(page);

			// Run 2 — provider-neutral cancel terminal + acknowledgement affordance.
			await resetToMigrateSurface(page);
			await connectSource(page, contract, contract.destinations.cancelled);
			await startImport(page, contract);
			await cancelImport(page);
			await contract.assertNoCanaryInBrowserArtifacts(page);
			await acknowledgeCancelledImport(page);
			await assertIndexAbsentForCustomer(contract.destinations.cancelled, customer.token);

			// Run 3 — source-change refusal renders job_presentation error copy in the console.
			await assertSourceChangedRefusal(
				page,
				contract,
				contract.destinations.sourceChanged,
				(name) => assertIndexAbsentForCustomer(name, customer.token)
			);
		},
		async () => {
			await runWithCleanup(async () => {
				for (const target of contract.targetNames) {
					await deleteAndAssertIndexAbsent(target, customer.token);
				}
			}, restoreMigrationBackend);
		}
	);
}

test.describe('source migration provider parity', () => {
	// Local-provider completion is observed through the production-cadence retained-job
	// reconciler (30 seconds), followed by cancel/source-change lifecycle and cleanup.
	test.describe.configure({ retries: 0, timeout: LOCAL_PROVIDER_LIFECYCLE_TIMEOUT_MS });

	test('source migration provider parity — meilisearch — local-container create cancel source-change lifecycle', async ({
		page,
		arrangeTrackedCustomerSession,
		apiUrl,
		ensureLocalSharedVmInventory,
		testRegion
	}) => {
		expect(() =>
			localProviderOriginForPort('LOCAL_MEILISEARCH_PORT', '7700@credential-capture.example')
		).toThrow('LOCAL_MEILISEARCH_PORT must be a numeric TCP port between 1 and 65535');
		const contract = await sourceMigrationProviderParityFixture('meilisearch');
		await assertLocalProviderParityLifecycle(
			page,
			contract,
			{
				assertIndexAbsentForCustomer: (name, token) =>
					assertIndexAbsentForCustomer(page, apiUrl, name, token),
				deleteAndAssertIndexAbsent: (name, token) =>
					deleteAndAssertIndexAbsent(page, apiUrl, name, token),
				primeMigrationBackend: (token) => primeMigrationBackend(page, apiUrl, testRegion, token),
				ensureLocalTarget: () => ensureLocalSharedVmInventory(testRegion),
				countRetainedJobs: (token) =>
					countRetainedImportJobs(page, apiUrl, contract.provider, token),
				arrangeCustomer: () =>
					arrangeTrackedCustomerSession(page, { emailPrefix: 'source-migration-meilisearch' })
			},
			testRegion
		);
	});

	test('source migration provider parity — typesense — local-container schema alias synonym curation lifecycle', async ({
		page,
		arrangeTrackedCustomerSession,
		apiUrl,
		ensureLocalSharedVmInventory,
		testRegion
	}) => {
		expect(() =>
			localProviderOriginForPort('LOCAL_TYPESENSE_PORT', '8108@credential-capture.example')
		).toThrow('LOCAL_TYPESENSE_PORT must be a numeric TCP port between 1 and 65535');
		const contract = await sourceMigrationProviderParityFixture('typesense');
		await assertLocalProviderParityLifecycle(
			page,
			contract,
			{
				assertIndexAbsentForCustomer: (name, token) =>
					assertIndexAbsentForCustomer(page, apiUrl, name, token),
				deleteAndAssertIndexAbsent: (name, token) =>
					deleteAndAssertIndexAbsent(page, apiUrl, name, token),
				primeMigrationBackend: (token) => primeMigrationBackend(page, apiUrl, testRegion, token),
				ensureLocalTarget: () => ensureLocalSharedVmInventory(testRegion),
				countRetainedJobs: (token) =>
					countRetainedImportJobs(page, apiUrl, contract.provider, token),
				arrangeCustomer: () =>
					arrangeTrackedCustomerSession(page, { emailPrefix: 'source-migration-typesense' })
			},
			testRegion
		);
	});

	test('source migration provider parity — algolia — live-source provider-neutral lifecycle', async ({
		page,
		arrangeTrackedCustomerSession,
		apiUrl,
		ensureLocalSharedVmInventory,
		testRegion
	}) => {
		expect(
			() => algoliaOriginForApplicationId('example.com/credential-capture'),
			'Algolia app IDs must not escape the credential-bearing Algolia origin'
		).toThrow('ALGOLIA_APP_ID must be a single DNS host label');
		// Algolia is a live-probe row: when its credentials are absent the honest disposition
		// is fixture-only, recorded as a skip reason. No refugee fixture is ever passed off as
		// a live Algolia source. This is the conditional runtime-skip API, not a hardcoded skip.
		// eslint-disable-next-line playwright/no-skipped-test -- conditional fixture-only disposition
		test.skip(
			resolveAlgoliaCredentials() === null,
			'Algolia source is fixture-only: live-probe credentials (ALGOLIA_APP_ID/ALGOLIA_ADMIN_KEY) are absent, so no live Algolia source is arranged'
		);
		const customer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'source-migration-algolia'
		});
		await resetToMigrateSurface(page);
		// Assert the repaired UI surface before invoking the live-probe-owned source Arrange.
		await assertProviderChoiceVisible(page, 'algolia');
		await ensureLocalSharedVmInventory(testRegion);
		await primeMigrationBackend(page, apiUrl, testRegion, customer.token);
		const contract = await sourceMigrationProviderParityFixture('algolia');
		annotateSourceMethod(contract);
		let restoreMigrationBackend: () => Promise<void>;
		try {
			restoreMigrationBackend = pinCurrentFlapjackAsSelectedMigrationBackend(testRegion);
		} catch (error) {
			await contract.cleanupSource?.();
			throw error;
		}
		await runWithCleanup(
			async () => {
				// Source Arrange reuses the live probe's fixture/credentials, while browser assertions stay
				// provider-neutral: visible submit, status, credential erasure, cancel, and active ACK.
				const connection = await connectSource(page, contract);
				await startImport(page, contract);
				await assertJobIdentity(page, contract, connection);
				await assertCredentialErasure(page, 'algolia');
				await contract.assertNoCredentialLeakInBrowserArtifacts(page);
				await expect(page.getByTestId('migration-job-status')).toBeVisible();
				await cancelImport(page);
				await acknowledgeCancelledImport(page);
				await assertIndexAbsentForCustomer(
					page,
					apiUrl,
					connection.destinationName,
					customer.token
				);
			},
			async () => {
				await Promise.all([
					deleteAndAssertIndexAbsent(
						page,
						apiUrl,
						contract.connection.destinationName,
						customer.token
					),
					contract.cleanupSource?.() ?? Promise.resolve(),
					restoreMigrationBackend()
				]);
			}
		);
	});
});
