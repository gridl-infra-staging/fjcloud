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
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import net from 'node:net';
import { SUPPORT_EMAIL } from '../../../src/lib/format';
import {
	DEFAULT_E2E_USER_EMAIL,
	DEFAULT_E2E_USER_PASSWORD,
	parseDotenvFile
} from '../../../playwright.config.contract';

type StartedProcess = {
	child: ChildProcessWithoutNullStreams;
	label: string;
	output: string[];
};
type ProcessEnvOverrides = Record<string, string | undefined>;
type ProcessCommand = {
	command: string;
	args: string[];
};
type UnconfiguredBillingStackStartContext = {
	apiPort: number;
	s3Port: number;
	flapjackPort: number;
	webPort: number;
	apiUrl: string;
	flapjackUrl: string;
	webBaseUrl: string;
	stackStateDir: string;
};
type UnconfiguredBillingStackCommandFactory = (
	context: UnconfiguredBillingStackStartContext
) => ProcessCommand;
type UnconfiguredBillingStackStartOptions = {
	stackCommand?: UnconfiguredBillingStackCommandFactory;
	readinessTimeoutMs?: number;
};

const repoEnv = parseDotenvFile('../.env.local');
const webEnv = parseDotenvFile('.env.local');
const UNCONFIGURED_STACK_JWT_SECRET =
	'stage4_unconfigured_billing_route_owner_proof_jwt_secret_0001';
const UNCONFIGURED_STACK_ADMIN_KEY = 'stage4-unconfigured-admin-key';

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

async function reservePort(): Promise<number> {
	const server = net.createServer();
	server.listen(0, '127.0.0.1');
	await once(server, 'listening');
	const address = server.address();
	if (!address || typeof address === 'string') {
		server.close();
		throw new Error('Unable to reserve a loopback port for the billing proof stack');
	}
	const port = address.port;
	server.close();
	await once(server, 'close');
	return port;
}

function sanitizedProcessOutput(started: StartedProcess): string {
	return started.output.join('').slice(-3_000);
}

function unconfiguredStackOutput(processes: StartedProcess[]): string {
	return processes
		.map((started) => `--- ${started.label} ---\n${sanitizedProcessOutput(started)}`)
		.join('\n');
}

async function waitForHttpOk(
	url: string,
	started: StartedProcess,
	timeoutMs = 60_000
): Promise<void> {
	await expect(async () => {
		if (started.child.exitCode !== null || started.child.signalCode !== null) {
			throw new Error(
				`${started.label} exited before readiness: exit=${started.child.exitCode} signal=${started.child.signalCode}\n${sanitizedProcessOutput(started)}`
			);
		}
		const response = await fetch(url);
		expect(response.ok, `${started.label} did not return 2xx at ${url}`).toBe(true);
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 5_000],
		timeout: timeoutMs
	});
}

function processEnvWithOverrides(overrides: ProcessEnvOverrides): NodeJS.ProcessEnv {
	const env = { ...process.env };
	for (const [key, value] of Object.entries(overrides)) {
		if (value === undefined) {
			delete env[key];
		} else {
			env[key] = value;
		}
	}
	return env;
}

function requiredRuntimeEnv(key: string, ...candidates: Array<string | undefined>): string {
	const value = candidates.find((candidate) => candidate !== undefined && candidate.length > 0);
	if (!value) {
		throw new Error(`${key} is required for the unconfigured billing proof stack`);
	}
	return value;
}

function resolvedFixtureUserCredentials(): { email: string; password: string } {
	return {
		email:
			process.env.E2E_USER_EMAIL ??
			webEnv.E2E_USER_EMAIL ??
			repoEnv.E2E_USER_EMAIL ??
			process.env.SEED_USER_EMAIL ??
			webEnv.SEED_USER_EMAIL ??
			repoEnv.SEED_USER_EMAIL ??
			DEFAULT_E2E_USER_EMAIL,
		password:
			process.env.E2E_USER_PASSWORD ??
			webEnv.E2E_USER_PASSWORD ??
			repoEnv.E2E_USER_PASSWORD ??
			process.env.SEED_USER_PASSWORD ??
			webEnv.SEED_USER_PASSWORD ??
			repoEnv.SEED_USER_PASSWORD ??
			DEFAULT_E2E_USER_PASSWORD
	};
}

function startProcess(label: string, command: string, args: string[], env: ProcessEnvOverrides) {
	const child = spawn(command, args, {
		cwd: process.cwd(),
		env: processEnvWithOverrides(env),
		detached: true
	});
	const started: StartedProcess = {
		child,
		label,
		output: []
	};
	const rememberOutput = (chunk: Buffer) => {
		started.output.push(chunk.toString('utf8'));
		started.output = started.output.slice(-80);
	};
	child.stdout.on('data', rememberOutput);
	child.stderr.on('data', rememberOutput);
	return started;
}

async function expectHttpUnavailable(url: string): Promise<void> {
	await expect(async () => {
		const response = await fetch(url).catch(() => null);
		expect(response, `${url} should not keep serving after stack cleanup`).toBeNull();
	}).toPass({
		intervals: [100, 250, 500],
		timeout: 5_000
	});
}

function signalStartedProcessGroup(started: StartedProcess, signal: NodeJS.Signals): void {
	const childPid = started.child.pid;
	if (childPid === undefined) {
		started.child.kill(signal);
		return;
	}
	try {
		process.kill(-childPid, signal);
	} catch {
		started.child.kill(signal);
	}
}

function unconfiguredBillingStackStartCommand({
	webPort
}: UnconfiguredBillingStackStartContext): ProcessCommand {
	return {
		command: 'bash',
		args: [
			'../scripts/playwright_local_stack.sh',
			'--force-api-restart',
			'--host',
			'127.0.0.1',
			'--port',
			String(webPort),
			'--strictPort'
		]
	};
}

async function stopProcess(started: StartedProcess): Promise<void> {
	if (started.child.exitCode !== null || started.child.signalCode !== null) {
		signalStartedProcessGroup(started, 'SIGTERM');
		await new Promise((resolve) => setTimeout(resolve, 250));
		signalStartedProcessGroup(started, 'SIGKILL');
		return;
	}
	signalStartedProcessGroup(started, 'SIGTERM');
	await Promise.race([
		once(started.child, 'exit'),
		new Promise((resolve) => setTimeout(resolve, 10_000))
	]);
	if (started.child.exitCode === null && started.child.signalCode === null) {
		signalStartedProcessGroup(started, 'SIGKILL');
		await once(started.child, 'exit');
	}
}

async function startUnconfiguredBillingStack(
	options: UnconfiguredBillingStackStartOptions = {}
): Promise<{
	webBaseUrl: string;
	processes: StartedProcess[];
	cleanup: () => Promise<void>;
}> {
	const apiPort = await reservePort();
	const s3Port = await reservePort();
	const flapjackPort = await reservePort();
	const webPort = await reservePort();
	const stackStateDir = await mkdtemp(join(tmpdir(), 'fjcloud-billing-proof-'));
	const apiUrl = `http://127.0.0.1:${apiPort}`;
	const flapjackUrl = `http://127.0.0.1:${flapjackPort}`;
	const webBaseUrl = `http://localhost:${webPort}`;
	const startContext: UnconfiguredBillingStackStartContext = {
		apiPort,
		s3Port,
		flapjackPort,
		webPort,
		apiUrl,
		flapjackUrl,
		webBaseUrl,
		stackStateDir
	};
	const commonEnv = {
		API_BASE_URL: apiUrl,
		API_URL: apiUrl,
		DATABASE_URL: requiredRuntimeEnv(
			'DATABASE_URL',
			process.env.DATABASE_URL,
			webEnv.DATABASE_URL,
			repoEnv.DATABASE_URL
		),
		JWT_SECRET: requiredRuntimeEnv(
			'JWT_SECRET',
			UNCONFIGURED_STACK_JWT_SECRET,
			process.env.JWT_SECRET,
			webEnv.JWT_SECRET,
			repoEnv.JWT_SECRET
		),
		ADMIN_KEY: requiredRuntimeEnv(
			'ADMIN_KEY',
			UNCONFIGURED_STACK_ADMIN_KEY,
			process.env.ADMIN_KEY,
			process.env.E2E_ADMIN_KEY,
			webEnv.ADMIN_KEY,
			repoEnv.ADMIN_KEY
		),
		PLAYWRIGHT_API_PORT: String(apiPort),
		PLAYWRIGHT_FLAPJACK_PORT: String(flapjackPort),
		LISTEN_ADDR: `127.0.0.1:${apiPort}`,
		S3_LISTEN_ADDR: `127.0.0.1:${s3Port}`,
		FLAPJACK_URL: flapjackUrl,
		LOCAL_DEV_FLAPJACK_URL: flapjackUrl,
		PLAYWRIGHT_FLAPJACK_DATA_DIR: join(stackStateDir, 'flapjack-data'),
		ENVIRONMENT: 'local',
		SKIP_EMAIL_VERIFICATION: '1',
		API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION: '1',
		API_DEV_PID_FILE: join(stackStateDir, 'api.pid'),
		NODE_SECRET_BACKEND: 'memory',
		SES_FROM_ADDRESS: undefined,
		SES_REGION: undefined,
		SES_CONFIGURATION_SET: undefined,
		STRIPE_LOCAL_MODE: '0',
		STRIPE_SECRET_KEY: undefined,
		STRIPE_TEST_SECRET_KEY: undefined,
		STRIPE_PUBLISHABLE_KEY: undefined
	} satisfies ProcessEnvOverrides;
	const startedProcesses: StartedProcess[] = [];
	const cleanup = async () => {
		await Promise.all(startedProcesses.map(stopProcess));
		await rm(stackStateDir, { recursive: true, force: true });
	};
	const readinessTimeoutMs = options.readinessTimeoutMs ?? 60_000;

	try {
		const stackCommand = (options.stackCommand ?? unconfiguredBillingStackStartCommand)(
			startContext
		);
		const stack = startProcess(
			'unconfigured billing local stack',
			stackCommand.command,
			stackCommand.args,
			commonEnv
		);
		startedProcesses.push(stack);
		await waitForHttpOk(`${webBaseUrl}/login`, stack, readinessTimeoutMs);

		return {
			webBaseUrl,
			processes: [stack],
			cleanup
		};
	} catch (error) {
		await cleanup();
		throw error;
	}
}

async function logIntoUnconfiguredBillingStack(page: Page, webBaseUrl: string): Promise<void> {
	const { email, password } = resolvedFixtureUserCredentials();
	await page.goto(`${webBaseUrl}/login`);
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: /log in/i }).click();
	await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
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
			).rejects.toThrow(/unconfigured billing local stack/);

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
		test.setTimeout(240_000);
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
