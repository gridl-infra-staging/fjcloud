/**
 * @module Nested local-stack harness.
 *
 * Some route-owned states only exist under server configuration the shared Playwright
 * stack does not run: Stripe fully unset, or `FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true`.
 * Those flags are read once at API startup, so proving such a state needs a second,
 * separately-spawned local stack rather than a per-test toggle.
 *
 * This module owns everything that is not an assertion about the state under proof —
 * port reservation, process spawning, cold-start budgeting, readiness polling, and
 * process-group cleanup. Each caller supplies only the env overrides that define its
 * configuration profile (see `unconfigured_billing_stack.ts` and
 * `migration_enabled_stack.ts`), so there is exactly one owner of the mechanics and one
 * owner per profile.
 */
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import net from 'node:net';
import {
	DEFAULT_E2E_USER_EMAIL,
	DEFAULT_E2E_USER_PASSWORD,
	parseDotenvFile
} from '../../playwright.config.contract';

export type StartedProcess = {
	child: ChildProcessWithoutNullStreams;
	label: string;
	output: string[];
	spawnError: Error | null;
};
export type ProcessEnvOverrides = Record<string, string | undefined>;
export type ProcessCommand = {
	command: string;
	args: string[];
};
export type NestedLocalStackStartContext = {
	apiPort: number;
	s3Port: number;
	flapjackPort: number;
	webPort: number;
	apiUrl: string;
	flapjackUrl: string;
	webBaseUrl: string;
	stackStateDir: string;
};
export type NestedLocalStackCommandFactory = (
	context: NestedLocalStackStartContext
) => ProcessCommand;
/**
 * Every wall-clock phase the child `scripts/playwright_local_stack.sh` walks through
 * before `${webBaseUrl}/login` can answer. The outer `waitForHttpOk` starts counting
 * the instant the wrapper is spawned, so its budget has to span all four — the child's
 * own `PLAYWRIGHT_API_READY_TIMEOUT_SECONDS` countdown covers only the second one.
 */
export type NestedLocalStackColdStartPhases = {
	/** Flapjack identity/boot plus `local-dev-migrate.sh`, run before the child arms any timer. */
	preludeMs: number;
	/** The child's own API health-poll loop (`playwright_local_stack.sh:16`). */
	apiReadinessMs: number;
	/** The child's post-API public-infrastructure cache settle sleep (`playwright_local_stack.sh:19`). */
	infrastructureSettleMs: number;
	/** `web-dev.sh` boot plus the first SvelteKit SSR compile of `/login`. */
	webBootMs: number;
};
export type NestedLocalStackStartOptions = {
	/** Diagnostic label carried on every captured line of child output. */
	label: string;
	/** Temp-directory prefix for this profile's stack state. */
	stateDirPrefix: string;
	/** The profile's env overrides, layered over `nestedLocalStackBaseEnvironment`. */
	environment: (
		context: NestedLocalStackStartContext,
		readinessTiming: NestedLocalStackReadinessTiming
	) => ProcessEnvOverrides;
	stackCommand?: NestedLocalStackCommandFactory;
	readinessTimeoutMs?: number;
	coldStartPhases?: NestedLocalStackColdStartPhases;
};

const repoEnv = parseDotenvFile('../.env.local');
const webEnv = parseDotenvFile('.env.local');

/**
 * Single owner of the nested cold-start budget. Each field is one phase of the child
 * script, so the outer deadline is a stated sum rather than a guessed margin. An earlier
 * formula budgeted only `apiReadinessMs` plus a flat 30s margin, which expired while the
 * child was still legitimately inside its untimed prelude or its dev-server boot; the
 * outer waiter must never be the first thing to give up, or the failure message blames a
 * timeout instead of naming the real child cause.
 */
export const NESTED_LOCAL_STACK_COLD_START_PHASES: NestedLocalStackColdStartPhases = {
	preludeMs: 120_000,
	apiReadinessMs: 180_000,
	infrastructureSettleMs: 11_000,
	webBootMs: 90_000
};

export type NestedLocalStackReadinessTiming = {
	apiReadyTimeoutSeconds: string;
	infrastructureSettleSeconds: string;
	derivedOuterReadinessTimeoutMs: number;
	outerReadinessTimeoutMs: number;
};

export function nestedLocalStackReadinessTiming(
	readinessTimeoutMs?: number,
	phases: NestedLocalStackColdStartPhases = NESTED_LOCAL_STACK_COLD_START_PHASES
): NestedLocalStackReadinessTiming {
	const derivedOuterReadinessTimeoutMs =
		phases.preludeMs + phases.apiReadinessMs + phases.infrastructureSettleMs + phases.webBootMs;
	return {
		// Both child-side budgets are pushed down as env overrides so the shell script's
		// own defaults stay inert for this path and each value has exactly one live owner.
		apiReadyTimeoutSeconds: String(phases.apiReadinessMs / 1_000),
		infrastructureSettleSeconds: String(phases.infrastructureSettleMs / 1_000),
		derivedOuterReadinessTimeoutMs,
		outerReadinessTimeoutMs: readinessTimeoutMs ?? derivedOuterReadinessTimeoutMs
	};
}

async function reservePort(): Promise<number> {
	const server = net.createServer();
	server.listen(0, '127.0.0.1');
	await once(server, 'listening');
	const address = server.address();
	if (!address || typeof address === 'string') {
		server.close();
		throw new Error('Unable to reserve a loopback port for a nested local stack');
	}
	const port = address.port;
	server.close();
	await once(server, 'close');
	return port;
}

function sanitizedProcessOutput(started: StartedProcess): string {
	return started.output.join('').slice(-3_000);
}

export function nestedStackOutput(processes: StartedProcess[]): string {
	return processes
		.map((started) => `--- ${started.label} ---\n${sanitizedProcessOutput(started)}`)
		.join('\n');
}

export async function waitForHttpOk(
	url: string,
	started: StartedProcess,
	timeoutMs: number
): Promise<void> {
	try {
		await expect(async () => {
			if (started.spawnError !== null) {
				throw new Error(
					`${started.label} spawn failed before readiness: ${started.spawnError.message}`
				);
			}
			if (started.child.exitCode !== null || started.child.signalCode !== null) {
				throw new Error(
					`${started.label} exited before readiness: exit=${started.child.exitCode} signal=${started.child.signalCode}`
				);
			}
			const response = await fetch(url);
			expect(response.ok, `${started.label} did not return 2xx at ${url}`).toBe(true);
		}).toPass({
			intervals: [1_000, 2_000, 3_000, 5_000],
			timeout: timeoutMs
		});
	} catch (error) {
		throw new Error(`${String(error)}\n\n${nestedStackOutput([started])}`, { cause: error });
	}
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

function requiredRuntimeEnv(
	key: string,
	purpose: string,
	...candidates: Array<string | undefined>
): string {
	const value = candidates.find((candidate) => candidate !== undefined && candidate.length > 0);
	if (!value) {
		throw new Error(`${key} is required for the ${purpose}`);
	}
	return value;
}

export function resolvedFixtureUserCredentials(): { email: string; password: string } {
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

export type NestedLocalStackCredentialFallbacks = {
	purpose: string;
	fallbackJwtSecret: string;
	fallbackAdminKey: string;
};

export function nestedLocalStackRuntimeCredentials({
	purpose,
	fallbackJwtSecret,
	fallbackAdminKey
}: NestedLocalStackCredentialFallbacks) {
	return {
		DATABASE_URL: requiredRuntimeEnv(
			'DATABASE_URL',
			purpose,
			process.env.DATABASE_URL,
			webEnv.DATABASE_URL,
			repoEnv.DATABASE_URL
		),
		JWT_SECRET: requiredRuntimeEnv(
			'JWT_SECRET',
			purpose,
			fallbackJwtSecret,
			process.env.JWT_SECRET,
			webEnv.JWT_SECRET,
			repoEnv.JWT_SECRET
		),
		// The ambient key must win, and the stack-owned constant is only a last resort.
		// A nested stack shares the main stack's DATABASE_URL, and
		// `playwright_local_stack.sh:reconcile_playwright_bootstrap_admin_user` repoints
		// the single `admin_users` row at whatever ADMIN_KEY it is handed. A stack-owned
		// key therefore outlives this fixture — nothing restores the row on cleanup — and
		// 401s every later admin-authenticated test in the run.
		ADMIN_KEY: requiredRuntimeEnv(
			'ADMIN_KEY',
			purpose,
			process.env.ADMIN_KEY,
			process.env.E2E_ADMIN_KEY,
			webEnv.ADMIN_KEY,
			repoEnv.ADMIN_KEY,
			fallbackAdminKey
		)
	};
}

function startProcess(label: string, command: ProcessCommand, env: ProcessEnvOverrides) {
	const child = spawn(command.command, command.args, {
		cwd: process.cwd(),
		env: processEnvWithOverrides(env),
		detached: true
	});
	const started: StartedProcess = {
		child,
		label,
		output: [],
		spawnError: null
	};
	const rememberOutput = (chunk: Buffer | string) => {
		started.output.push(chunk.toString());
		started.output = started.output.slice(-80);
	};
	child.stdout.on('data', rememberOutput);
	child.stderr.on('data', rememberOutput);
	child.on('error', (error) => {
		started.spawnError = error;
		rememberOutput(`spawn error: ${error.message}\n`);
	});
	return started;
}

export async function expectHttpUnavailable(url: string): Promise<void> {
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

export function nestedLocalStackStartCommand({
	webPort
}: NestedLocalStackStartContext): ProcessCommand {
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
	if (started.spawnError !== null) return;
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

async function createNestedLocalStackStartContext(
	stateDirPrefix: string
): Promise<NestedLocalStackStartContext> {
	const apiPort = await reservePort();
	const s3Port = await reservePort();
	const flapjackPort = await reservePort();
	const webPort = await reservePort();
	const stackStateDir = await mkdtemp(join(tmpdir(), stateDirPrefix));
	const apiUrl = `http://127.0.0.1:${apiPort}`;
	const flapjackUrl = `http://127.0.0.1:${flapjackPort}`;

	return {
		apiPort,
		s3Port,
		flapjackPort,
		webPort,
		apiUrl,
		flapjackUrl,
		webBaseUrl: `http://localhost:${webPort}`,
		stackStateDir
	};
}

/**
 * The wiring every nested stack needs to run beside the shared stack without
 * colliding with it: its own ports, its own flapjack data, its own API pid file, and
 * local-environment defaults. Profiles layer their configuration-under-proof on top.
 */
export function nestedLocalStackBaseEnvironment(
	context: NestedLocalStackStartContext,
	readinessTiming: NestedLocalStackReadinessTiming
): ProcessEnvOverrides {
	return {
		API_BASE_URL: context.apiUrl,
		API_URL: context.apiUrl,
		PLAYWRIGHT_API_PORT: String(context.apiPort),
		PLAYWRIGHT_API_READY_TIMEOUT_SECONDS: readinessTiming.apiReadyTimeoutSeconds,
		PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS:
			readinessTiming.infrastructureSettleSeconds,
		PLAYWRIGHT_FLAPJACK_PORT: String(context.flapjackPort),
		LISTEN_ADDR: `127.0.0.1:${context.apiPort}`,
		S3_LISTEN_ADDR: `127.0.0.1:${context.s3Port}`,
		FLAPJACK_URL: context.flapjackUrl,
		LOCAL_DEV_FLAPJACK_URL: context.flapjackUrl,
		PLAYWRIGHT_FLAPJACK_DATA_DIR: join(context.stackStateDir, 'flapjack-data'),
		ENVIRONMENT: 'local',
		SKIP_EMAIL_VERIFICATION: '1',
		API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION: '1',
		API_DEV_PID_FILE: join(context.stackStateDir, 'api.pid'),
		NODE_SECRET_BACKEND: 'memory'
	};
}

export type StartedNestedLocalStack = {
	webBaseUrl: string;
	apiUrl: string;
	processes: StartedProcess[];
	cleanup: () => Promise<void>;
};

export async function startNestedLocalStack(
	options: NestedLocalStackStartOptions
): Promise<StartedNestedLocalStack> {
	const startContext = await createNestedLocalStackStartContext(options.stateDirPrefix);
	const startedProcesses: StartedProcess[] = [];
	const cleanup = async () => {
		await Promise.all(startedProcesses.map(stopProcess));
		await rm(startContext.stackStateDir, { recursive: true, force: true });
	};
	try {
		const readinessTiming = nestedLocalStackReadinessTiming(
			options.readinessTimeoutMs,
			options.coldStartPhases
		);
		const commonEnv = options.environment(startContext, readinessTiming);
		const stackCommand = (options.stackCommand ?? nestedLocalStackStartCommand)(startContext);
		const stack = startProcess(options.label, stackCommand, commonEnv);
		startedProcesses.push(stack);
		await waitForHttpOk(
			`${startContext.webBaseUrl}/login`,
			stack,
			readinessTiming.outerReadinessTimeoutMs
		);

		return {
			webBaseUrl: startContext.webBaseUrl,
			apiUrl: startContext.apiUrl,
			processes: [stack],
			cleanup
		};
	} catch (error) {
		await cleanup();
		throw error;
	}
}

export async function logIntoNestedLocalStack(page: Page, webBaseUrl: string): Promise<void> {
	const { email, password } = resolvedFixtureUserCredentials();
	await page.goto(`${webBaseUrl}/login`);
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: /log in/i }).click();
	await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
}
