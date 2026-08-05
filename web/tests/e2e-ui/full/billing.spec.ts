/**
 * Full — Billing
 *
 * Verifies the complete billing surface:
 *   - Load-and-verify: billing page renders the Billing heading
 *   - Billing page renders in-app payment-method UI or the unavailable card
 *   - Invoices page renders (empty or with rows)
 *   - Invoice detail page renders heading, dates, and line items
 *   - Invoice PDF download link renders when backend provides pdf_url
 */

import { test, expect } from '../../fixtures/fixtures';
import type { Page } from '@playwright/test';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SUPPORT_EMAIL } from '../../../src/lib/format';
import {
	type UnconfiguredBillingColdStartPhases,
	UNCONFIGURED_BILLING_COLD_START_PHASES,
	expectHttpUnavailable,
	logIntoUnconfiguredBillingStack,
	startUnconfiguredBillingStack,
	unconfiguredBillingReadinessTiming,
	unconfiguredBillingStackStartCommand,
	unconfiguredStackOutput,
	waitForHttpOk
} from '../../fixtures/unconfigured_billing_stack';

async function expectNoBillingPortalControls(page: Page) {
	await expect(page.getByRole('button', { name: 'Manage billing' })).toHaveCount(0);
	await expect(page.getByRole('link', { name: 'Manage billing' })).toHaveCount(0);
	await expect(page.getByText(/Stripe Customer Portal/i)).toHaveCount(0);
	await expect(
		// eslint-disable-next-line playwright/no-raw-locators -- route action attribute contract assertion
		page.locator(
			'form[action*="?/manageBilling"], button[formaction*="?/manageBilling"], input[formaction*="?/manageBilling"]'
		)
	).toHaveCount(0);
	await expect(
		// eslint-disable-next-line playwright/no-raw-locators -- portal endpoint target contract assertion
		page.locator(
			'a[href*="/billing/portal"], form[action*="/billing/portal"], button[formaction*="/billing/portal"], input[formaction*="/billing/portal"]'
		)
	).toHaveCount(0);
	await expect(
		// eslint-disable-next-line playwright/no-raw-locators -- SvelteKit action target contract assertion
		page.locator('a[href*="?/manageBilling"]')
	).toHaveCount(0);
}

async function expectBillingPortalControlRejected(page: Page, markup: string) {
	await page.setContent(markup);
	await expect(expectNoBillingPortalControls(page)).rejects.toThrow();
}

test.describe('Billing page', () => {
	test('no-portal helper rejects non-exact manageBilling action targets', async ({ page }) => {
		await expectBillingPortalControlRejected(
			page,
			'<form action="/console/billing?/manageBilling"><button type="submit">Open billing</button></form>'
		);
		await expectBillingPortalControlRejected(
			page,
			'<form action="?/setDefaultPaymentMethod"><button type="submit" formaction="/console/billing?/manageBilling">Open billing</button></form>'
		);
	});

	test('load-and-verify: billing page renders Billing heading', async ({ page }) => {
		// Act: navigate to billing
		await page.goto('/console/billing');

		// Assert: page-specific heading (not sidebar "Billing" nav link)
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
	});

	test('billing page renders configured route-owned billing state without portal controls', async ({
		page
	}) => {
		await page.goto('/console/billing');

		const paymentMethodsHeading = page.getByRole('heading', { name: 'Payment methods' });
		await expect(paymentMethodsHeading).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Add or update card' })).toBeVisible();
		await expect(
			page.getByText('No payment methods on file yet.').or(page.getByText(/ending in/i))
		).toBeVisible();
		await expect(
			page.getByRole('link', { name: `Contact ${SUPPORT_EMAIL} to cancel` })
		).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);

		await expectNoBillingPortalControls(page);
	});

	test('unconfigured billing proof uses the repo-owned API startup script', async () => {
		const stackScript = await readFile('../scripts/playwright_local_stack.sh', 'utf8');

		expect(stackScript).toContain('bash "$SCRIPT_DIR/api-dev.sh"');
	});

	test('unconfigured billing proof uses the repo-owned Playwright stack startup script', () => {
		const command = unconfiguredBillingStackStartCommand({
			apiPort: 3001,
			s3Port: 3002,
			flapjackPort: 9700,
			webPort: 5173,
			apiUrl: 'http://127.0.0.1:3001',
			flapjackUrl: 'http://127.0.0.1:9700',
			webBaseUrl: 'http://localhost:5173',
			stackStateDir: '/tmp/fjcloud-billing-proof-contract'
		});

		expect(command).toEqual({
			command: 'bash',
			args: [
				'../scripts/playwright_local_stack.sh',
				'--force-api-restart',
				'--host',
				'127.0.0.1',
				'--port',
				'5173',
				'--strictPort'
			]
		});
	});

	test('unconfigured billing cold-start deadlines keep the outer waiter beyond the child', () => {
		const phases = UNCONFIGURED_BILLING_COLD_START_PHASES;
		const timing = unconfiguredBillingReadinessTiming();

		// The outer budget is the sum of every child phase, not the child's API loop plus a margin.
		expect(timing.derivedOuterReadinessTimeoutMs).toBe(
			phases.preludeMs + phases.apiReadinessMs + phases.infrastructureSettleMs + phases.webBootMs
		);
		// The child's two env-owned budgets are pushed down from the same phase record.
		expect(timing.apiReadyTimeoutSeconds).toBe(String(phases.apiReadinessMs / 1_000));
		expect(timing.infrastructureSettleSeconds).toBe(String(phases.infrastructureSettleMs / 1_000));
		// Every phase the child can spend time in has to be paid for, in the order it runs.
		expect(timing.derivedOuterReadinessTimeoutMs).toBeGreaterThan(
			phases.preludeMs + phases.apiReadinessMs
		);
		expect(timing.derivedOuterReadinessTimeoutMs).toBeGreaterThan(
			phases.apiReadinessMs + phases.infrastructureSettleMs + phases.webBootMs
		);
		// The cleanup proofs below still inject a short deadline so they stay fast.
		expect(unconfiguredBillingReadinessTiming(3_000).outerReadinessTimeoutMs).toBe(3_000);
	});

	test('unconfigured billing cold-start phases match the child script phase order', async () => {
		const stackScript = await readFile('../scripts/playwright_local_stack.sh', 'utf8');
		const preludeIndex = stackScript.indexOf('bash "$SCRIPT_DIR/local-dev-migrate.sh"');
		const apiReadinessIndex = stackScript.indexOf('seq 1 "$API_START_TIMEOUT_SECONDS"');
		const settleIndex = stackScript.indexOf('sleep "$PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS"');
		const webBootIndex = stackScript.indexOf('bash "$SCRIPT_DIR/web-dev.sh"');

		// Each phase modelled in UNCONFIGURED_BILLING_COLD_START_PHASES must still exist in the
		// child, in this order. If the child grows or reorders a startup phase, the budget above
		// is stale and this fails rather than resurfacing as an opaque outer-waiter timeout.
		expect(preludeIndex).toBeGreaterThan(-1);
		expect(apiReadinessIndex).toBeGreaterThan(preludeIndex);
		expect(settleIndex).toBeGreaterThan(apiReadinessIndex);
		expect(webBootIndex).toBeGreaterThan(settleIndex);
	});

	test('unconfigured billing outer waiter survives a prelude longer than the web-boot phase', async () => {
		test.setTimeout(45_000);
		// Scaled-down mirror of the real phase record. The fake stack binds later than every
		// post-prelude phase combined, so the outer waiter only survives if `preludeMs` is
		// actually part of the budget — the exact term the previous formula omitted.
		const phases: UnconfiguredBillingColdStartPhases = {
			preludeMs: 6_000,
			apiReadinessMs: 1_000,
			infrastructureSettleMs: 1_000,
			webBootMs: 1_000
		};
		const bindDelayMs = 4_000;
		expect(bindDelayMs).toBeGreaterThan(
			phases.apiReadinessMs + phases.infrastructureSettleMs + phases.webBootMs
		);

		const stack = await startUnconfiguredBillingStack({
			coldStartPhases: phases,
			stackCommand: ({ webPort }) => ({
				command: process.execPath,
				args: [
					'-e',
					`
const http = require('node:http');
const port = Number(process.argv[1]);
const bindDelayMs = Number(process.argv[2]);
const server = http.createServer((request, response) => {
	response.statusCode = request.url === '/login' ? 200 : 404;
	response.end('ok');
});
setTimeout(() => server.listen(port, '127.0.0.1'), bindDelayMs);
setTimeout(() => process.exit(0), bindDelayMs + 30000).unref();
`,
					String(webPort),
					String(bindDelayMs)
				]
			})
		});

		await stack.cleanup();
	});

	test('unconfigured billing spawn failure rejects and removes temp state', async () => {
		test.setTimeout(15_000);
		let stackStateDir = '';

		await expect(
			startUnconfiguredBillingStack({
				stackCommand: (context) => {
					stackStateDir = context.stackStateDir;
					return {
						command: 'fjcloud-missing-billing-stack-command',
						args: []
					};
				},
				readinessTimeoutMs: 3_000
			})
		).rejects.toThrow(/spawn failed before readiness.*ENOENT/s);

		expect(stackStateDir).not.toBe('');
		await expect(access(stackStateDir)).rejects.toThrow();
	});

	test('unconfigured billing startup failure cleans up started processes and temp state', async () => {
		test.setTimeout(45_000);
		const proofDir = await mkdtemp(join(tmpdir(), 'fjcloud-billing-startup-cleanup-'));
		const terminatedMarker = join(proofDir, 'api-terminated.txt');
		const stackStateDirMarker = join(proofDir, 'stack-state-dir.txt');
		try {
			await expect(
				startUnconfiguredBillingStack({
					stackCommand: ({ webPort, stackStateDir }) => ({
						command: process.execPath,
						args: [
							'-e',
							`
const fs = require('node:fs');
const http = require('node:http');
const port = Number(process.argv[1]);
const terminatedMarker = process.argv[2];
const stackStateDirMarker = process.argv[3];
const stackStateDir = process.argv[4];
const server = http.createServer((request, response) => {
	response.statusCode = request.url === '/login' ? 503 : 404;
	response.end('ok');
});
process.stdout.write('billing-startup-diagnostic');
fs.writeFileSync(stackStateDirMarker, stackStateDir);
process.on('SIGTERM', () => {
	fs.writeFileSync(terminatedMarker, 'terminated');
	server.close(() => process.exit(0));
	setTimeout(() => process.exit(0), 50).unref();
});
server.listen(port, '127.0.0.1');
setTimeout(() => {
	server.close(() => process.exit(0));
}, 15000).unref();
`,
							String(webPort),
							terminatedMarker,
							stackStateDirMarker,
							stackStateDir
						]
					}),
					readinessTimeoutMs: 3_000
				})
			).rejects.toThrow(/billing-startup-diagnostic/);

			await expect(async () => {
				await expect(readFile(terminatedMarker, 'utf8')).resolves.toBe('terminated');
			}).toPass({ timeout: 5_000 });

			const stackStateDir = (await readFile(stackStateDirMarker, 'utf8')).trim();
			await expect(access(stackStateDir)).rejects.toThrow();
		} finally {
			await rm(proofDir, { recursive: true, force: true });
		}
	});

	test('unconfigured billing normal cleanup stops wrapper-owned children and temp state', async () => {
		test.setTimeout(45_000);
		const proofDir = await mkdtemp(join(tmpdir(), 'fjcloud-billing-normal-cleanup-'));
		const childPidFile = join(proofDir, 'child-pids.txt');
		const endpointsFile = join(proofDir, 'child-endpoints.txt');
		const stackStateDirFile = join(proofDir, 'stack-state-dir.txt');
		try {
			const stack = await startUnconfiguredBillingStack({
				stackCommand: ({ apiPort, apiUrl, flapjackPort, flapjackUrl, webPort, stackStateDir }) => ({
					command: process.execPath,
					args: [
						'-e',
						`
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const [
	apiPort,
	apiUrl,
	flapjackPort,
	flapjackUrl,
	webPort,
	stackStateDir,
	childPidFile,
	endpointsFile,
	stackStateDirFile
] = process.argv.slice(1);
const childScript = \`
const fs = require('node:fs');
const http = require('node:http');
const port = Number(process.argv[1]);
const stackStateDir = process.argv[2];
const server = http.createServer((_request, response) => {
	response.statusCode = 200;
	response.end('ok');
});
server.listen(port, '127.0.0.1');
setInterval(() => {
	fs.mkdirSync(stackStateDir, { recursive: true });
	fs.writeFileSync(stackStateDir + '/child-heartbeat-' + port, String(Date.now()));
}, 100);
\`;
const children = [apiPort, flapjackPort].map((port) =>
	spawn(process.execPath, ['-e', childScript, port, stackStateDir], {
		stdio: 'ignore'
	})
);
fs.writeFileSync(childPidFile, children.map((child) => child.pid).join('\\n'));
fs.writeFileSync(endpointsFile, [apiUrl, flapjackUrl].join('\\n'));
fs.writeFileSync(stackStateDirFile, stackStateDir);
const web = http.createServer((request, response) => {
	response.statusCode = request.url === '/login' ? 200 : 404;
	response.end('ok');
});
process.on('SIGTERM', () => {
	web.close(() => process.exit(0));
	setTimeout(() => process.exit(0), 50).unref();
});
web.listen(Number(webPort), '127.0.0.1');
setTimeout(() => {
	web.close(() => process.exit(0));
}, 30000).unref();
`,
						String(apiPort),
						apiUrl,
						String(flapjackPort),
						flapjackUrl,
						String(webPort),
						stackStateDir,
						childPidFile,
						endpointsFile,
						stackStateDirFile
					]
				})
			});
			let childEndpoints: string[] = [];

			try {
				const stackOutput = unconfiguredStackOutput(stack.processes);
				childEndpoints = (await readFile(endpointsFile, 'utf8')).split(/\s+/).filter(Boolean);
				expect(childEndpoints.length, stackOutput).toBe(2);
				for (const childEndpoint of childEndpoints) {
					await waitForHttpOk(childEndpoint, stack.processes[0], 5_000);
				}
				await expect(fetch(`${stack.webBaseUrl}/login`)).resolves.toHaveProperty('ok', true);
			} finally {
				await stack.cleanup();
			}

			const stackOutput = unconfiguredStackOutput(stack.processes);
			await expectHttpUnavailable(stack.webBaseUrl);
			for (const childEndpoint of childEndpoints) {
				await expectHttpUnavailable(childEndpoint);
			}
			const stackStateDir = (await readFile(stackStateDirFile, 'utf8')).trim();
			await expect(async () => {
				await expect(access(stackStateDir)).rejects.toThrow();
			}).toPass({ timeout: 5_000 });
		} finally {
			const childPids = await readFile(childPidFile, 'utf8').catch(() => '');
			for (const value of childPids.split(/\s+/).filter(Boolean)) {
				const pid = Number(value);
				if (Number.isInteger(pid) && pid > 0) {
					try {
						process.kill(pid, 'SIGKILL');
					} catch {
						// Child already exited.
					}
				}
			}
			await rm(proofDir, { recursive: true, force: true });
		}
	});

	test('billing page renders unconfigured route-owned billing state without portal controls', async ({
		page
	}) => {
		// Must exceed the full cold-start budget plus the login and page-assertion budget, so a
		// genuine startup failure expires at the outer waitForHttpOk (which attaches the child
		// diagnostics) rather than at this test timeout (which would not name the child cause).
		test.setTimeout(unconfiguredBillingReadinessTiming().derivedOuterReadinessTimeoutMs + 140_000);
		const stack = await startUnconfiguredBillingStack();
		try {
			await logIntoUnconfiguredBillingStack(page, stack.webBaseUrl);
			await page.goto(`${stack.webBaseUrl}/console/billing`);

			try {
				await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
				await expect(page.getByText('Payment method management unavailable')).toBeVisible();
				await expect(
					page.getByText(
						'Stripe is not available in this environment. Payment method management is disabled.'
					)
				).toBeVisible();
				await expectNoBillingPortalControls(page);
			} catch (error) {
				throw new Error(`${String(error)}\n\n${unconfiguredStackOutput(stack.processes)}`);
			}
		} finally {
			await stack.cleanup();
		}
	});
});

test.describe('Invoices page', () => {
	test('load-and-verify: invoices page renders correctly', async ({ page }) => {
		// Act: navigate to invoices
		await page.goto('/console/billing/invoices');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'Invoices' })).toBeVisible();

		// Assert: either the table headers or the empty-state message is shown
		const tableHeaders = page.getByRole('columnheader', { name: 'Period' });
		const emptyState = page.getByText('No invoices yet');

		await expect(tableHeaders.or(emptyState)).toBeVisible({ timeout: 5_000 });
	});
});

test.describe('Invoice detail page', () => {
	test('load-and-verify: invoice detail renders heading, dates, line items, and PDF action', async ({
		page,
		seedInvoiceWithPdfUrl
	}) => {
		// Arrange: ensure an invoice with backend-provided pdf_url exists.
		let id: string;
		try {
			({ id } = await seedInvoiceWithPdfUrl());
		} catch (error) {
			if (
				error instanceof Error &&
				error.message.includes('customer has no stripe account linked')
			) {
				// eslint-disable-next-line playwright/no-skipped-test -- PDF proof requires local Stripe account state
				test.skip(
					true,
					'Invoice PDF generation is unavailable without a local Stripe-backed billing account'
				);
			}
			throw error;
		}

		// Act: navigate to invoice detail
		await page.goto(`/console/billing/invoices/${id}`);

		// Assert: back navigation link
		await expect(page.getByRole('link', { name: /back to invoices/i })).toBeVisible();

		// Assert: date labels rendered
		await expect(page.getByText('Created')).toBeVisible();

		// Assert: line items table structure
		await expect(page.getByRole('heading', { name: 'Line Items' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Description' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Amount' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Region' })).toBeVisible();
		const downloadPdfLink = page.getByRole('link', { name: 'Download PDF' });
		await expect(downloadPdfLink).toBeVisible();
		await expect(downloadPdfLink).toHaveAttribute('href', /\/pdf(?:\?|$)/);
	});
});
