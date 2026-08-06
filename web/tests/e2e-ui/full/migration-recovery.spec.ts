/**
 * Full - Migration unavailable state, and retained-job cutover verification honesty
 *
 * Coverage:
 *   - Authenticated customers can still open /console/migrate directly.
 *   - The page explains the temporary shutdown.
 *   - No working list/import controls or CTAs remain exposed.
 *   - Against a migration-enabled stack, a completed retained job states the
 *     cutover-verification boundary its server-published capability implies.
 */

import {
	test,
	expect,
	deleteSeededRetainedMigrationJobs,
	seedCompletedRetainedMigrationJob
} from '../../fixtures/fixtures';
import { describeUnsupportedCutoverVerification } from '../../../src/lib/components/migration/job_presentation';
import {
	cleanupMigrationEnabledStack,
	startMigrationEnabledStack
} from '../../fixtures/migration_enabled_stack';
import {
	logIntoNestedLocalStack,
	nestedLocalStackReadinessTiming,
	nestedStackOutput,
	resolvedFixtureUserCredentials
} from '../../fixtures/nested_local_stack';

test.describe('Migration unavailable page', () => {
	test.describe.configure({ retries: 0 });

	test('authenticated direct visits show the unavailable explanation without migration actions', async ({
		page,
		arrangeTrackedCustomerSession
	}) => {
		await arrangeTrackedCustomerSession(page, { emailPrefix: 'migration-unavailable' });
		await page.goto('/console/migrate');

		await expect(page).toHaveURL(/\/console\/migrate$/);
		// Heading and paused-imports copy dropped "Algolia" when the console gained
		// Meilisearch and Typesense sources. The unavailable message stays Algolia-worded
		// because it is server-owned (infra/api/src/routes/migration.rs:32) and rendered
		// verbatim, so it is asserted exactly as the API publishes it.
		await expect(page.getByRole('heading', { name: 'Migrate search data' })).toBeVisible();
		await expect(page.getByTestId('migration-unavailable')).toContainText(
			'Algolia migration is temporarily unavailable while we replace the importer.'
		);
		await expect(page.getByText(/temporarily turned off new search data imports/i)).toBeVisible();

		await expect(page.getByTestId('migration-available')).toHaveCount(0);
		await expect(page.getByTestId('migration-create-flow')).toHaveCount(0);
		await expect(page.getByTestId('migration-recent-imports')).toHaveCount(0);
		await expect(page.getByLabel('Algolia Application ID')).toHaveCount(0);
		await expect(page.getByLabel('Algolia API key')).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Connect to Algolia' })).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Check destination eligibility' })).toHaveCount(
			0
		);
		await expect(page.getByRole('button', { name: 'Start import' })).toHaveCount(0);
	});
});

test.describe('Retained cutover verification boundary', () => {
	test.describe.configure({ retries: 0 });

	// The shared stack runs with migration disabled (the state the suite above
	// proves), so `capabilities.verify` is fail-closed there for every provider
	// and could not tell provider support apart from a disabled platform. This
	// proof therefore runs against its own migration-enabled stack, where the
	// Algolia arm is a real negative control.
	test('completed retained jobs follow server-published verify capability', async ({ page }) => {
		// Must exceed the full cold-start budget plus seeding, login, and both page
		// assertions, so a genuine startup failure expires at the harness waiter
		// (which attaches the child diagnostics) rather than at this test timeout.
		test.setTimeout(nestedLocalStackReadinessTiming().derivedOuterReadinessTimeoutMs + 180_000);
		const { email, password } = resolvedFixtureUserCredentials();
		const stack = await startMigrationEnabledStack();
		const seededJobIds: string[] = [];
		try {
			const unsupportedJob = await seedCompletedRetainedMigrationJob({
				apiUrl: stack.apiUrl,
				email,
				password,
				sourceProvider: 'meilisearch',
				sourceName: 'cutover_proof_meili_source',
				destinationTarget: 'cutover_proof_meili_destination'
			});
			seededJobIds.push(unsupportedJob.jobId);
			const supportedJob = await seedCompletedRetainedMigrationJob({
				apiUrl: stack.apiUrl,
				email,
				password,
				sourceProvider: 'algolia',
				sourceName: 'cutover_proof_algolia_source',
				destinationTarget: 'cutover_proof_algolia_destination'
			});
			seededJobIds.push(supportedJob.jobId);

			await logIntoNestedLocalStack(page, stack.webBaseUrl);

			try {
				await page.goto(
					`${stack.webBaseUrl}/console/migrate/${unsupportedJob.jobId}?source_provider=meilisearch`
				);
				await expect(page.getByRole('region', { name: 'Cutover verification' })).toBeVisible();
				await expect(page.getByTestId('cutover-verification-unsupported')).toHaveText(
					describeUnsupportedCutoverVerification('meilisearch')
				);
				await expect(page.getByRole('button', { name: 'Run verification' })).toHaveCount(0);
				await expect(page.getByLabel('Algolia Application ID')).toHaveCount(0);
				await expect(page.getByLabel('Algolia API key')).toHaveCount(0);
				await expect(page.getByLabel('Queries')).toHaveCount(0);
				await expect(page.getByLabel('Result limit')).toHaveCount(0);

				// Negative control: same console, same panel, a provider the server
				// does publish `verify` for. Without this arm the assertion above
				// would also pass if the panel simply never offered verification.
				await page.goto(
					`${stack.webBaseUrl}/console/migrate/${supportedJob.jobId}?source_provider=algolia`
				);
				await expect(page.getByRole('button', { name: 'Run verification' })).toBeVisible();
				await expect(page.getByTestId('cutover-verification-unsupported')).toHaveCount(0);
				await expect(page.getByText(describeUnsupportedCutoverVerification('algolia'))).toHaveCount(
					0
				);
			} catch (error) {
				throw new Error(`${String(error)}\n\n${nestedStackOutput(stack.processes)}`);
			}
		} finally {
			await cleanupMigrationEnabledStack(stack, () =>
				deleteSeededRetainedMigrationJobs(seededJobIds)
			);
		}
	});
});
