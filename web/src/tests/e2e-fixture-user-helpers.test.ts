import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
	FIXTURE_AUTH_API_RETRY_BUDGET_MS,
	PAID_INVOICE_PROOF_TIMEOUT_MS,
	adminReactivateCustomerById,
	arrangeFreshSignupToDashboardWithFixtureFallback,
	bootstrapFixtureUserForKnownLoginFailure,
	createRegisteredUser,
	fetchDisposableTenantRateCardSnapshot,
	fetchEstimatedBillForToken,
	formatFixtureSetupFailure,
	isFreshSignupArrangePrerequisiteFailure,
	ensureInvoicePaymentAttemptForBillingProof,
	loginAsUserWithKnownMissingUserBootstrap,
	recoverAlreadyInvoicedInvoiceForMonth,
	resolveFreshSignupCleanupCustomerId,
	waitForInvoiceStatusForToken,
	loginAsUser,
	setupFailureDetailsFromError,
	seedMultiUserScenarioWithCreateUser
} from '../../tests/fixtures/fixtures';
import {
	createSeedSearchableIndexFactory,
	seedIndexForCustomerViaAdmin,
	seedSearchableIndexForCustomer
} from '../../tests/fixtures/searchable-index';
import { DEFAULT_FLAPJACK_URL } from '../../playwright.config.contract';

type MockJsonBody = Record<string, unknown>;
const ORIGINAL_API_URL = process.env.API_URL;
const ORIGINAL_API_BASE_URL = process.env.API_BASE_URL;
const ORIGINAL_PLAYWRIGHT_TARGET_REMOTE = process.env.PLAYWRIGHT_TARGET_REMOTE;

function restoreEnvVar(name: string, value: string | undefined): void {
	if (value === undefined) {
		delete process.env[name];
		return;
	}
	process.env[name] = value;
}

function makeJsonResponse(status: number, body: MockJsonBody): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('e2e fixture user helpers', () => {
	it('does not expose deprecated subscription-checkout helpers in the fixture contract surface', () => {
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(fixtureSource).not.toMatch(/\bensureCheckoutSubscriptionReady\b/);
		expect(fixtureSource).not.toMatch(/\bwaitForSubscriptionStatus\b/);
		expect(fixtureSource).not.toMatch(/\barrangeBillingDunningForFreshSignup\b/);
		expect(fixtureSource).not.toMatch(/\barrangeRefundedInvoiceForFreshSignup\b/);
	});

	it('classifies verification-email delivery outages as fresh-signup prerequisites', () => {
		expect(
			isFreshSignupArrangePrerequisiteFailure('verification email temporarily unavailable')
		).toBe(true);
		expect(
			isFreshSignupArrangePrerequisiteFailure(
				'createUser failed: 503 {"error":"verification email temporarily unavailable"}'
			)
		).toBe(true);
	});

	it('fails closed when remote fallback setup throws during fresh-signup arrange', () => {
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(fixtureSource).not.toMatch(
			/fallbackSucceeded\s*=\s*await\s+attemptRemoteSignupFallback\([^)]*\)\.catch\(\(\)\s*=>\s*false\)/
		);
	});

	it('fails closed when tracked-customer teardown cannot delete tenants', () => {
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(fixtureSource).toMatch(
			/_trackCustomerForCleanup:\s*async\s*\(\{\},\s*use\)\s*=>\s*\{[\s\S]*deleteTrackedCustomerForCleanup\(/m
		);
		expect(fixtureSource).not.toMatch(
			/_trackCustomerForCleanup:\s*async\s*\(\{\},\s*use\)\s*=>\s*\{[\s\S]*bestEffortAdminApiCall\(/m
		);
	});

	it('arrangePaidInvoiceForFreshSignup reads invoice detail through the fresh-signup auth token', () => {
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(fixtureSource).toContain('getInvoiceDetailForToken(invoiceId, token)');
	});

	it('arrangePaidInvoiceForFreshSignup treats Stripe already-paid pay responses as converged success', () => {
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(fixtureSource.toLowerCase()).toContain('invoice is already paid');
	});

	it('resolves cleanup ownership from authenticated session token after successful browser signup', async () => {
		const resolveCustomerIdByToken = vi.fn().mockResolvedValue('cust-owned-by-session');

		await expect(
			resolveFreshSignupCleanupCustomerId({
				sessionToken: 'session-token-123',
				currentPath: 'http://127.0.0.1:5173/dashboard',
				responseStatus: 303,
				responseUrl: 'http://127.0.0.1:5173/signup',
				resolveCustomerIdByToken
			})
		).resolves.toBe('cust-owned-by-session');
		expect(resolveCustomerIdByToken).toHaveBeenCalledWith('session-token-123');
	});

	it('fails closed when successful browser signup has no auth cookie token', async () => {
		await expect(
			resolveFreshSignupCleanupCustomerId({
				sessionToken: null,
				currentPath: 'http://127.0.0.1:5173/dashboard',
				responseStatus: 303,
				responseUrl: 'http://127.0.0.1:5173/signup'
			})
		).rejects.toThrow('auth cookie token was missing');
	});

	it('fails closed when customer ownership lookup from session token fails', async () => {
		await expect(
			resolveFreshSignupCleanupCustomerId({
				sessionToken: 'session-token-123',
				currentPath: 'http://127.0.0.1:5173/dashboard',
				resolveCustomerIdByToken: async () => {
					throw new Error('503 upstream');
				}
			})
		).rejects.toThrow('could not resolve customer id from auth cookie token');
	});

	it('retries transient /account failures before resolving cleanup ownership from session token', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'temporary upstream failure' }), { status: 503 })
			)
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'rate limited' }), {
					status: 429,
					headers: { 'retry-after': '0' }
				})
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					id: 'cust-retry-cleanup'
				})
			);
		vi.stubGlobal('fetch', fetchMock as unknown as typeof fetch);

		const promise = resolveFreshSignupCleanupCustomerId({
			sessionToken: 'session-token-123',
			currentPath: 'http://127.0.0.1:5173/dashboard'
		});

		await vi.runAllTimersAsync();
		await expect(promise).resolves.toBe('cust-retry-cleanup');
		expect(fetchMock).toHaveBeenCalledTimes(3);
	});

	it('registers cleanup ownership on successful arrangeFreshSignupToDashboard fallback flow', async () => {
		const fill = vi.fn().mockResolvedValue(undefined);
		const click = vi.fn().mockResolvedValue(undefined);
		const waitForAlert = vi.fn().mockRejectedValue(new Error('alert not shown'));
		const pageUrl = 'http://127.0.0.1:5173/dashboard';
		const mockPage = {
			goto: vi.fn().mockResolvedValue(undefined),
			waitForURL: vi.fn().mockResolvedValue(undefined),
			waitForResponse: vi.fn().mockResolvedValue({
				status: () => 303,
				url: () => 'http://127.0.0.1:5173/signup'
			}),
			url: vi.fn().mockReturnValue(pageUrl),
			getByLabel: vi.fn().mockReturnValue({ fill }),
			getByRole: vi.fn((role: string) => {
				if (role === 'button') {
					return { click };
				}
				if (role === 'alert') {
					return {
						waitFor: waitForAlert,
						isVisible: vi.fn().mockResolvedValue(false),
						textContent: vi.fn().mockResolvedValue('')
					};
				}
				return {};
			})
		};
		const trackedCustomerIds: string[] = [];
		const resolveCleanupCustomerId = vi.fn().mockResolvedValue('cust-cleanup-123');
		const getSessionTokenFromPage = vi.fn().mockResolvedValue('session-token-123');

		const result = await arrangeFreshSignupToDashboardWithFixtureFallback(
			{
				page: mockPage as never,
				signup: {
					name: 'Signup Lane Fixed Seed',
					email: 'signup-fixed-seed@e2e.griddle.test',
					password: 'TestPassword123!'
				},
				createUser: vi.fn() as never,
				trackCustomerForCleanup: (customerId) => trackedCustomerIds.push(customerId)
			},
			{
				resolveCleanupCustomerId,
				getSessionTokenFromPage
			}
		);

		expect(result).toEqual({ prerequisiteFailureMessage: null });
		expect(resolveCleanupCustomerId).toHaveBeenCalledWith({
			sessionToken: 'session-token-123',
			currentPath: pageUrl,
			responseStatus: 303,
			responseUrl: 'http://127.0.0.1:5173/signup'
		});
		expect(trackedCustomerIds).toEqual(['cust-cleanup-123']);
	});

	it('registers cleanup ownership after transient /account failures in successful arrange flow', async () => {
		vi.useFakeTimers();
		const fill = vi.fn().mockResolvedValue(undefined);
		const click = vi.fn().mockResolvedValue(undefined);
		const waitForAlert = vi.fn().mockRejectedValue(new Error('alert not shown'));
		const pageUrl = 'http://127.0.0.1:5173/dashboard';
		const mockPage = {
			goto: vi.fn().mockResolvedValue(undefined),
			waitForURL: vi.fn().mockResolvedValue(undefined),
			waitForResponse: vi.fn().mockResolvedValue({
				status: () => 303,
				url: () => 'http://127.0.0.1:5173/signup',
				request: () => ({ method: () => 'POST' })
			}),
			url: vi.fn().mockReturnValue(pageUrl),
			getByLabel: vi.fn().mockReturnValue({ fill }),
			getByRole: vi.fn((role: string) => {
				if (role === 'button') {
					return { click };
				}
				if (role === 'alert') {
					return {
						waitFor: waitForAlert,
						isVisible: vi.fn().mockResolvedValue(false),
						textContent: vi.fn().mockResolvedValue('')
					};
				}
				return {};
			})
		};
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'temporary upstream failure' }), { status: 500 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					id: 'cust-cleanup-from-default-owner'
				})
			);
		vi.stubGlobal('fetch', fetchMock as unknown as typeof fetch);
		const trackedCustomerIds: string[] = [];
		const getSessionTokenFromPage = vi.fn().mockResolvedValue('session-token-123');

		const promise = arrangeFreshSignupToDashboardWithFixtureFallback(
			{
				page: mockPage as never,
				signup: {
					name: 'Signup Lane Retry Seed',
					email: 'signup-retry-seed@e2e.griddle.test',
					password: 'TestPassword123!'
				},
				createUser: vi.fn() as never,
				trackCustomerForCleanup: (customerId) => trackedCustomerIds.push(customerId)
			},
			{
				getSessionTokenFromPage
			}
		);

		await vi.runAllTimersAsync();
		await expect(promise).resolves.toEqual({ prerequisiteFailureMessage: null });
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(trackedCustomerIds).toEqual(['cust-cleanup-from-default-owner']);
	});

	beforeEach(() => {
		vi.restoreAllMocks();
		process.env.API_URL = 'http://127.0.0.1:3001';
		process.env.API_BASE_URL = 'http://127.0.0.1:3001';
		delete process.env.PLAYWRIGHT_TARGET_REMOTE;
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
		restoreEnvVar('API_URL', ORIGINAL_API_URL);
		restoreEnvVar('API_BASE_URL', ORIGINAL_API_BASE_URL);
		restoreEnvVar('PLAYWRIGHT_TARGET_REMOTE', ORIGINAL_PLAYWRIGHT_TARGET_REMOTE);
	});

	it('createRegisteredUser posts to /auth/register and tracks cleanup', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(201, {
				customer_id: 'cust-123',
				token: 'tok-abc'
			})
		);
		const trackedCustomerIds: string[] = [];

		const created = await createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			name: 'Fixture User',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: (customerId) => trackedCustomerIds.push(customerId)
		});

		expect(created).toEqual({
			customerId: 'cust-123',
			token: 'tok-abc',
			email: 'user@example.com',
			password: 'TestPassword123!'
		});
		expect(trackedCustomerIds).toEqual(['cust-123']);
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'Fixture User',
				email: 'user@example.com',
				password: 'TestPassword123!'
			})
		});
	});

	it('createRegisteredUser fails fast when required contract inputs are blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			createRegisteredUser({
				apiUrl: 'http://localhost:3001',
				email: '   ',
				password: '',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow('createRegisteredUser requires non-empty email and password');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser preserves non-blank passwords exactly as provided', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(201, {
				customer_id: 'cust-456',
				token: 'tok-def'
			})
		);
		const passwordWithWhitespace = '  Pass phrase  ';

		const created = await createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: passwordWithWhitespace,
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});

		expect(created.password).toBe(passwordWithWhitespace);
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'E2E Fixture user@example.com',
				email: 'user@example.com',
				password: passwordWithWhitespace
			})
		});
	});

	it('createRegisteredUser retries 429 responses before succeeding', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-789',
					token: 'tok-retry'
				})
			);

		const promise = createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'retry@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});

		await vi.runAllTimersAsync();

		await expect(promise).resolves.toEqual({
			customerId: 'cust-789',
			token: 'tok-retry',
			email: 'retry@example.com',
			password: 'TestPassword123!'
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('loginAsUser posts to /auth/login and returns a fresh token', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(200, {
				customer_id: 'cust-123',
				token: 'login-token'
			})
		);

		const token = await loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(token).toBe('login-token');
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/login', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				email: 'user@example.com',
				password: 'TestPassword123!'
			})
		});
	});

	it('loginAsUser retries 429 responses before succeeding', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-123',
					token: 'retry-login-token'
				})
			);

		const promise = loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		await vi.runAllTimersAsync();

		await expect(promise).resolves.toBe('retry-login-token');
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('bootstrapFixtureUserForKnownLoginFailure registers then retries login only for the known missing-user failure surface', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-bootstrap',
					token: 'register-token'
				})
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-bootstrap',
					token: 'login-token'
				})
			);

		const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
			apiUrl: 'http://localhost:3001',
			email: 'dev@example.com',
			password: 'localdev-password-1234',
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			responseStatus: 400,
			responseUrl: 'http://127.0.0.1:3001/auth/login',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(bootstrapResult).toEqual({
			bootstrapped: true,
			loginToken: 'login-token'
		});
		expect(fetchMock).toHaveBeenNthCalledWith(1, 'http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'E2E Fixture dev@example.com',
				email: 'dev@example.com',
				password: 'localdev-password-1234'
			})
		});
		expect(fetchMock).toHaveBeenNthCalledWith(2, 'http://localhost:3001/auth/login', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				email: 'dev@example.com',
				password: 'localdev-password-1234'
			})
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('bootstrapFixtureUserForKnownLoginFailure treats SvelteKit /login 400 responses as the same bootstrapable missing-user surface', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-bootstrap',
					token: 'register-token'
				})
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-bootstrap',
					token: 'login-token'
				})
			);

		const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
			apiUrl: 'http://localhost:3001',
			email: 'dev@example.com',
			password: 'localdev-password-1234',
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			responseStatus: 400,
			responseUrl: 'http://127.0.0.1:5173/login',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(bootstrapResult).toEqual({
			bootstrapped: true,
			loginToken: 'login-token'
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('bootstrapFixtureUserForKnownLoginFailure does not register outside the known missing-user failure surface', async () => {
		const fetchMock = vi.fn();

		const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
			apiUrl: 'http://localhost:3001',
			email: 'dev@example.com',
			password: 'localdev-password-1234',
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'service unavailable',
			responseStatus: 500,
			responseUrl: 'http://127.0.0.1:3001/auth/login',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(bootstrapResult).toEqual({
			bootstrapped: false,
			loginToken: null
		});
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('bootstrapFixtureUserForKnownLoginFailure still bootstraps when browser login surfaces invalid credentials without exposing upstream response details', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-bootstrap',
					token: 'register-token'
				})
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-bootstrap',
					token: 'login-token'
				})
			);

		const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
			apiUrl: 'http://localhost:3001',
			email: 'dev@example.com',
			password: 'localdev-password-1234',
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(bootstrapResult).toEqual({
			bootstrapped: true,
			loginToken: 'login-token'
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('bootstrapFixtureUserForKnownLoginFailure treats existing-user registration conflicts as idempotent and still retries login', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'email taken' }), { status: 409 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-existing',
					token: 'login-token-after-conflict'
				})
			);

		const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
			apiUrl: 'http://localhost:3001',
			email: 'dev@example.com',
			password: 'localdev-password-1234',
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			responseStatus: 400,
			responseUrl: 'http://127.0.0.1:3001/auth/login',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(bootstrapResult).toEqual({
			bootstrapped: true,
			loginToken: 'login-token-after-conflict'
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(fetchMock).toHaveBeenNthCalledWith(1, 'http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'E2E Fixture dev@example.com',
				email: 'dev@example.com',
				password: 'localdev-password-1234'
			})
		});
		expect(fetchMock).toHaveBeenNthCalledWith(2, 'http://localhost:3001/auth/login', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				email: 'dev@example.com',
				password: 'localdev-password-1234'
			})
		});
	});

	it('loginAsUserWithKnownMissingUserBootstrap retries through bootstrap on known invalid-credentials seams', async () => {
		const loginAsUserFn = vi
			.fn()
			.mockRejectedValueOnce(new Error('loginAs failed: 400 {"error":"invalid email or password"}'));
		const bootstrapFn = vi.fn().mockResolvedValue({
			bootstrapped: true,
			loginToken: 'tok-after-bootstrap'
		});

		await expect(
			loginAsUserWithKnownMissingUserBootstrap({
				apiUrl: 'http://localhost:3001',
				email: 'fresh-signup@example.com',
				password: 'TestPassword123!',
				trackCustomerForCleanup: () => {},
				loginAsUserFn,
				bootstrapFn,
				contextLabel: 'arrangePaidInvoiceForFreshSignup'
			})
		).resolves.toBe('tok-after-bootstrap');
		expect(bootstrapFn).toHaveBeenCalledOnce();
	});

	it('loginAsUserWithKnownMissingUserBootstrap retries through bootstrap when login returns 401 invalid credentials', async () => {
		const loginAsUserFn = vi
			.fn()
			.mockRejectedValueOnce(new Error('loginAs failed: 401 {"error":"invalid credentials"}'));
		const bootstrapFn = vi.fn().mockResolvedValue({
			bootstrapped: true,
			loginToken: 'tok-after-401-bootstrap'
		});

		await expect(
			loginAsUserWithKnownMissingUserBootstrap({
				apiUrl: 'http://localhost:3001',
				email: 'fresh-signup@example.com',
				password: 'TestPassword123!',
				trackCustomerForCleanup: () => {},
				loginAsUserFn,
				bootstrapFn,
				contextLabel: 'arrangePaidInvoiceForFreshSignup'
			})
		).resolves.toBe('tok-after-401-bootstrap');
		expect(bootstrapFn).toHaveBeenCalledOnce();
	});

	it('setupFailureDetailsFromError redacts secret-bearing bootstrap errors before fixture diagnostics surface them', () => {
		const details = setupFailureDetailsFromError(
			new Error(
				'createUser failed: Bearer sensitive.jwt.token at /verify-email/abc123?token=secret-token'
			)
		);

		expect(details).toContain('Bearer [REDACTED]');
		expect(details).toContain('/verify-email/[REDACTED]');
		expect(details).toContain('token=[REDACTED]');
		expect(details).not.toContain('sensitive.jwt.token');
		expect(details).not.toContain('abc123');
		expect(details).not.toContain('secret-token');
	});

	it('fixture diagnostics redact URL-embedded credentials before surfacing helper failures', () => {
		const details = setupFailureDetailsFromError(
			new Error(
				'createUser failed at http://fixture-user:fixture-pass@127.0.0.1:3001/verify-email/abc123?token=secret-token'
			)
		);
		const formatted = formatFixtureSetupFailure({
			setupName: 'Customer login setup',
			expectedPath: '/dashboard',
			currentPath: 'http://ui-user:ui-pass@127.0.0.1:5173/login',
			apiUrl: 'http://api-user:api-pass@127.0.0.1:3001',
			adminKey: 'admin-key',
			alertText: 'invalid email or password',
			responseStatus: 400,
			responseUrl: 'http://resp-user:resp-pass@127.0.0.1:3001/auth/login?token=secret-token'
		});

		expect(details).toContain(
			'http://[REDACTED]@127.0.0.1:3001/verify-email/[REDACTED]?token=[REDACTED]'
		);
		expect(details).not.toContain('fixture-user');
		expect(details).not.toContain('fixture-pass');
		expect(formatted).toContain('Current URL: http://[REDACTED]@127.0.0.1:5173/login');
		expect(formatted).toContain('API URL: http://[REDACTED]@127.0.0.1:3001');
		expect(formatted).toContain(
			'Login response: status 400 at http://[REDACTED]@127.0.0.1:3001/auth/login?token=[REDACTED]'
		);
		expect(formatted).not.toContain('ui-user');
		expect(formatted).not.toContain('ui-pass');
		expect(formatted).not.toContain('api-user');
		expect(formatted).not.toContain('api-pass');
		expect(formatted).not.toContain('resp-user');
		expect(formatted).not.toContain('resp-pass');
		expect(formatted).not.toContain('secret-token');
	});

	it('fixture diagnostics redact token-bearing URL fragments, Basic auth, and JSON secret fields', () => {
		const details = setupFailureDetailsFromError(
			new Error(
				'upstream {"access_token":"fragment-token","refresh_token":"refresh-token","password":"super-secret"} Basic dGVzdDpzZWNyZXQ= http://127.0.0.1:3001/callback#access_token=fragment-token&state=opaque-state'
			)
		);

		expect(details).toContain('"access_token":"[REDACTED]"');
		expect(details).toContain('"refresh_token":"[REDACTED]"');
		expect(details).toContain('"password":"[REDACTED]"');
		expect(details).toContain('Basic [REDACTED]');
		expect(details).toContain('#access_token=[REDACTED]&state=[REDACTED]');
		expect(details).not.toContain('fragment-token');
		expect(details).not.toContain('refresh-token');
		expect(details).not.toContain('super-secret');
		expect(details).not.toContain('dGVzdDpzZWNyZXQ=');
		expect(details).not.toContain('opaque-state');
	});

	it('seedMultiUserScenarioWithCreateUser creates two unique users', async () => {
		const createUser = vi
			.fn()
			.mockResolvedValueOnce({
				customerId: 'cust-1',
				token: 'tok-1',
				email: 'primary@example.com',
				password: 'TestPassword123!'
			})
			.mockResolvedValueOnce({
				customerId: 'cust-2',
				token: 'tok-2',
				email: 'secondary@example.com',
				password: 'TestPassword123!'
			});

		const seeded = await seedMultiUserScenarioWithCreateUser({
			createUser,
			password: 'TestPassword123!',
			uniqueId: 'fixed-seed'
		});

		expect(createUser).toHaveBeenCalledTimes(2);
		const firstEmail = createUser.mock.calls[0]?.[0];
		const secondEmail = createUser.mock.calls[1]?.[0];
		expect(firstEmail).not.toBe(secondEmail);
		expect(firstEmail).toContain('fixed-seed');
		expect(secondEmail).toContain('fixed-seed');
		expect(seeded.primaryUser.customerId).toBe('cust-1');
		expect(seeded.secondaryUser.customerId).toBe('cust-2');
	});

	it('adminReactivateCustomerById calls POST /admin/customers/:id/reactivate', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(makeJsonResponse(200, { message: 'customer reactivated' }));

		await adminReactivateCustomerById({
			apiUrl: 'http://localhost:3001',
			customerId: 'cust-123',
			adminKey: 'admin-key',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(fetchMock).toHaveBeenCalledWith(
			'http://localhost:3001/admin/customers/cust-123/reactivate',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: undefined
			}
		);
	});

	it('adminReactivateCustomerById fails fast when E2E_ADMIN_KEY is missing', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'http://localhost:3001',
				customerId: 'cust-123',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('E2E_ADMIN_KEY must be set for admin API calls');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('adminReactivateCustomerById fails fast when customerId is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'http://localhost:3001',
				customerId: '   ',
				adminKey: 'admin-key',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('adminReactivateCustomerById requires a non-empty customerId');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('fetchDisposableTenantRateCardSnapshot reads backend rate-card without tenant override writes', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-rate-card',
					token: 'fixture-token'
				})
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					id: 'default-rate-card',
					name: 'Default',
					storage_rate_per_mb_month: '0.0500',
					cold_storage_rate_per_gb_month: '0.0200',
					object_storage_rate_per_gb_month: '0.0300',
					object_storage_egress_rate_per_gb: '0.0900',
					region_multipliers: {
						'us-east-1': '1',
						'eu-west-1': '1',
						'eu-central-1': '0.70',
						'eu-north-1': '0.75',
						'us-east-2': '0.80',
						'us-west-1': '0.80'
					},
					minimum_spend_cents: 1000,
					shared_minimum_spend_cents: 500,
					has_override: false,
					override_fields: {}
				})
			);
		const trackedCustomerIds: string[] = [];

		const snapshot = await fetchDisposableTenantRateCardSnapshot({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			seed: 'fixed-seed',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: (customerId) => trackedCustomerIds.push(customerId)
		});

		expect(snapshot).toEqual({
			storage_rate_per_mb_month: '$0.05',
			cold_storage_rate_per_gb_month: '$0.02',
			minimum_spend_cents: 1000,
			shared_minimum_spend_cents: 500,
			region_pricing: [
				{ id: 'us-east-1', display_name: 'US East (Virginia)', multiplier: '1.00x' },
				{ id: 'eu-west-1', display_name: 'EU West (Ireland)', multiplier: '1.00x' },
				{ id: 'eu-central-1', display_name: 'EU Central (Germany)', multiplier: '0.70x' },
				{ id: 'eu-north-1', display_name: 'EU North (Helsinki)', multiplier: '0.75x' },
				{ id: 'us-east-2', display_name: 'US East (Ashburn)', multiplier: '0.80x' },
				{ id: 'us-west-1', display_name: 'US West (Oregon)', multiplier: '0.80x' }
			]
		});
		expect(trackedCustomerIds).toEqual(['cust-rate-card']);
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(fetchMock).toHaveBeenNthCalledWith(1, 'http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'Pricing Rate Card fixed-seed',
				email: 'pricing-rate-card-fixed-seed@e2e.griddle.test',
				password: 'TestPassword123!'
			})
		});
		expect(fetchMock).toHaveBeenNthCalledWith(
			2,
			'http://localhost:3001/admin/tenants/cust-rate-card/rate-card',
			{
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: undefined
			}
		);
		expect(fetchMock.mock.calls.some(([, init]) => (init as RequestInit).method === 'PUT')).toBe(
			false
		);
	});

	it('fetchEstimatedBillForToken includes month query when provided', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(200, {
				month: '2026-03',
				subtotal_cents: 1800,
				total_cents: 1800,
				minimum_applied: false,
				line_items: []
			})
		);

		const estimate = await fetchEstimatedBillForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			month: '2026-03',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(estimate?.month).toBe('2026-03');
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/billing/estimate?month=2026-03', {
			method: 'GET',
			headers: { Authorization: 'Bearer tok-abc' }
		});
	});

	it('fetchEstimatedBillForToken returns null for 404 (no estimate data)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'no active rate card' }), { status: 404 })
			);

		const estimate = await fetchEstimatedBillForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(estimate).toBeNull();
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/billing/estimate', {
			method: 'GET',
			headers: { Authorization: 'Bearer tok-abc' }
		});
	});

	it('fetchEstimatedBillForToken throws on auth errors (401/403)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 }));

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'http://localhost:3001',
				token: 'expired-tok',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('/billing/estimate failed: 401');
	});

	it('fetchEstimatedBillForToken throws on server errors (5xx)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'internal error' }), { status: 500 })
			);

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'http://localhost:3001',
				token: 'tok-abc',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('/billing/estimate failed: 500');
	});

	it('waitForInvoiceStatusForToken survives prolonged invoice settlement windows', async () => {
		vi.useFakeTimers();
		let attempts = 0;
		const fetchMock = vi.fn(async () => {
			attempts += 1;
			if (attempts <= 45) {
				return makeJsonResponse(200, {
					id: 'inv-long-warmup',
					status: 'open',
					paid_at: null,
					stripe_invoice_id: 'in_long_warmup'
				});
			}
			return makeJsonResponse(200, {
				id: 'inv-long-warmup',
				status: 'paid',
				paid_at: '2026-05-19T00:00:00Z',
				stripe_invoice_id: 'in_long_warmup'
			});
		});

		const waitPromise = waitForInvoiceStatusForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			invoiceId: 'inv-long-warmup',
			expectedStatus: 'paid',
			contextLabel: 'test-long-warmup',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		await vi.runAllTimersAsync();
		await expect(waitPromise).resolves.toMatchObject({
			id: 'inv-long-warmup',
			status: 'paid'
		});
		expect(attempts).toBe(46);
	});

	it('waitForInvoiceStatusForToken fails closed when invoice remains open without stripe linkage', async () => {
		vi.useFakeTimers();
		const fetchMock = vi.fn().mockImplementation(async () =>
			makeJsonResponse(200, {
				id: 'inv-open-no-stripe',
				status: 'open',
				paid_at: null,
				stripe_invoice_id: null
			})
		);

		const waitPromise = waitForInvoiceStatusForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			invoiceId: 'inv-open-no-stripe',
			expectedStatus: 'paid',
			contextLabel: 'test-open-without-stripe',
			fetchImpl: fetchMock as unknown as typeof fetch,
			maxAttempts: 90
		});
		const rejection = expect(waitPromise).rejects.toThrow(
			'test-open-without-stripe invoice inv-open-no-stripe remained open without stripe_invoice_id'
		);
		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(12);
	});

	it('waitForInvoiceStatusForToken fails closed when invoice remains open with stripe linkage', async () => {
		vi.useFakeTimers();
		const fetchMock = vi.fn().mockImplementation(async () =>
			makeJsonResponse(200, {
				id: 'inv-open-with-stripe',
				status: 'open',
				paid_at: null,
				stripe_invoice_id: 'in_open_stalled_123'
			})
		);

		const waitPromise = waitForInvoiceStatusForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			invoiceId: 'inv-open-with-stripe',
			expectedStatus: 'paid',
			contextLabel: 'test-open-with-stripe',
			fetchImpl: fetchMock as unknown as typeof fetch,
			maxAttempts: 90
		});
		const rejection = expect(waitPromise).rejects.toThrow(
			'test-open-with-stripe invoice inv-open-with-stripe remained open with stripe_invoice_id present'
		);
		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(46);
	});

	it('recoverAlreadyInvoicedInvoiceForMonth finalizes draft invoices before waiting for paid status', async () => {
		const listInvoices = vi.fn().mockResolvedValue([
			{ id: 'inv-draft', status: 'draft', period_start: '2026-05-01' }
		]);
		const getInvoiceDetail = vi.fn().mockResolvedValue({
			id: 'inv-draft',
			status: 'draft',
			paid_at: null,
			pdf_url: null,
			stripe_invoice_id: null
		});
		const finalizeDraftInvoice = vi.fn().mockResolvedValue(undefined);
		const payStripeInvoice = vi.fn().mockResolvedValue(undefined);

		await expect(
			recoverAlreadyInvoicedInvoiceForMonth({
				billingMonth: '2026-05',
				contextLabel: 'arrangePaidInvoiceForFreshSignup',
				listInvoices,
				getInvoiceDetail,
				finalizeDraftInvoice,
				payStripeInvoice
			})
		).resolves.toBe('inv-draft');
		expect(finalizeDraftInvoice).toHaveBeenCalledWith('inv-draft');
		expect(payStripeInvoice).not.toHaveBeenCalled();
	});

	it('recoverAlreadyInvoicedInvoiceForMonth retries payment for finalized invoices with Stripe ids', async () => {
		const listInvoices = vi.fn().mockResolvedValue([
			{ id: 'inv-finalized', status: 'finalized', period_start: '2026-05-01' }
		]);
		const getInvoiceDetail = vi.fn().mockResolvedValue({
			id: 'inv-finalized',
			status: 'finalized',
			paid_at: null,
			pdf_url: 'https://stripe.test/invoice.pdf',
			stripe_invoice_id: 'in_test_123'
		});
		const finalizeDraftInvoice = vi.fn().mockResolvedValue(undefined);
		const payStripeInvoice = vi.fn().mockResolvedValue(undefined);

		await expect(
			recoverAlreadyInvoicedInvoiceForMonth({
				billingMonth: '2026-05',
				contextLabel: 'arrangePaidInvoiceForFreshSignup',
				listInvoices,
				getInvoiceDetail,
				finalizeDraftInvoice,
				payStripeInvoice
			})
		).resolves.toBe('inv-finalized');
		expect(finalizeDraftInvoice).not.toHaveBeenCalled();
		expect(payStripeInvoice).toHaveBeenCalledWith('in_test_123');
	});

	it('ensureInvoicePaymentAttemptForBillingProof retries payment for finalized invoices returned from created path', async () => {
		const getInvoiceDetail = vi.fn().mockResolvedValue({
			id: 'inv-created-finalized',
			status: 'finalized',
			paid_at: null,
			pdf_url: 'https://stripe.test/invoice.pdf',
			stripe_invoice_id: 'in_created_123'
		});
		const payStripeInvoice = vi.fn().mockResolvedValue(undefined);

		await expect(
			ensureInvoicePaymentAttemptForBillingProof({
				invoiceId: 'inv-created-finalized',
				contextLabel: 'arrangePaidInvoiceForFreshSignup',
				getInvoiceDetail,
				payStripeInvoice
			})
		).resolves.toBeUndefined();
		expect(payStripeInvoice).toHaveBeenCalledWith('in_created_123');
	});

	it('ensureInvoicePaymentAttemptForBillingProof retries payment for open invoices with Stripe ids', async () => {
		const getInvoiceDetail = vi.fn().mockResolvedValue({
			id: 'inv-created-open',
			status: 'open',
			paid_at: null,
			pdf_url: null,
			stripe_invoice_id: 'in_created_open_123'
		});
		const payStripeInvoice = vi.fn().mockResolvedValue(undefined);

		await expect(
			ensureInvoicePaymentAttemptForBillingProof({
				invoiceId: 'inv-created-open',
				contextLabel: 'arrangePaidInvoiceForFreshSignup',
				getInvoiceDetail,
				payStripeInvoice
			})
		).resolves.toBeUndefined();
		expect(payStripeInvoice).toHaveBeenCalledWith('in_created_open_123');
	});

	it('seedIndexForCustomerViaAdmin retries transient create failures before polling readiness', async () => {
		vi.useFakeTimers();

		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(new Response('temporary failure', { status: 500 }))
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'shared-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'shared-index' }));

		const seedPromise = seedIndexForCustomerViaAdmin({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'shared-index',
			region: 'us-east-1',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		await vi.runAllTimersAsync();
		await seedPromise;

		expect(fetchMock).toHaveBeenNthCalledWith(
			1,
			'http://localhost:3001/admin/tenants/cust-123/indexes',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: JSON.stringify({
					name: 'shared-index',
					region: 'us-east-1'
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			2,
			'http://localhost:3001/admin/tenants/cust-123/indexes',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: JSON.stringify({
					name: 'shared-index',
					region: 'us-east-1'
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(3, 'http://localhost:3001/indexes/shared-index', {
			method: 'GET',
			headers: {
				'Content-Type': 'application/json',
				Authorization: 'Bearer tok-abc'
			},
			body: undefined
		});
	});

	it('seedIndexForCustomerViaAdmin fails fast when required auth contract is missing', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: '',
				name: 'shared-index',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty token');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin fails fast when customerId is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: '   ',
				token: 'tok-abc',
				name: 'shared-index',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty customerId');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin fails fast when index name is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: 'tok-abc',
				name: '   ',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty index name');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin accepts a duplicate-name conflict after a retried create', async () => {
		vi.useFakeTimers();

		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(new Response('temporary failure', { status: 500 }))
			.mockResolvedValueOnce(new Response('duplicate name', { status: 409 }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'shared-index' }));

		const seedPromise = seedIndexForCustomerViaAdmin({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'shared-index',
			region: 'us-east-1',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		await vi.runAllTimersAsync();
		await seedPromise;

		expect(fetchMock).toHaveBeenCalledTimes(3);
	});

	it('seedSearchableIndexForCustomer provisions searchable documents for an explicit customer', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Tenant A Document' }]
				})
			);

		const seeded = await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'search-index',
			region: 'us-east-1',
			flapjackUrl: 'http://localhost:7700',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document',
			documents: [{ objectID: 'doc-1', title: 'Tenant A Document' }],
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(seeded).toEqual({
			name: 'search-index',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document'
		});
		expect(fetchMock).toHaveBeenNthCalledWith(
			4,
			'http://localhost:7700/1/indexes/cust123_search-index/batch',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'X-Algolia-API-Key': 'search-key',
					'X-Algolia-Application-Id': 'flapjack'
				},
				body: JSON.stringify({
					requests: [
						{ action: 'addObject', body: { objectID: 'doc-1', title: 'Tenant A Document' } }
					]
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			5,
			'http://localhost:3001/indexes/search-index/search',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					query: 'Tenant'
				})
			}
		);
	});

	it('seedSearchableIndexForCustomer uses contract DEFAULT_FLAPJACK_URL when flapjackUrl is omitted', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Rust Programming Language' }]
				})
			);

		await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'search-index',
			region: 'us-east-1',
			// flapjackUrl intentionally omitted — should use DEFAULT_FLAPJACK_URL
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		// The ingest call (4th) should use the contract default flapjack URL
		expect(fetchMock).toHaveBeenNthCalledWith(
			4,
			`${DEFAULT_FLAPJACK_URL}/1/indexes/cust123_search-index/batch`,
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('createSeedSearchableIndexFactory uses injected flapjackUrl from deps', async () => {
		// Stub global fetch for ingest call inside the factory
		const globalFetchMock = vi.fn().mockResolvedValue(makeJsonResponse(200, { taskID: 1 }));
		vi.stubGlobal('fetch', globalFetchMock);

		const apiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, { hits: [{ title: 'Rust Programming Language' }] })
			);
		const adminApiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'factory-index' }));
		const getCustomerIdMock = vi.fn().mockResolvedValue('cust-factory');
		const waitForSeededIndexMock = vi.fn().mockResolvedValue(undefined);

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: getCustomerIdMock,
			waitForSeededIndex: waitForSeededIndexMock,
			flapjackUrl: 'http://127.0.0.1:9900'
		});

		await seedFn('factory-index');

		// The admin create call should pass the injected flapjackUrl
		expect(adminApiCallMock).toHaveBeenCalledWith('POST', '/admin/tenants/cust-factory/indexes', {
			name: 'factory-index',
			region: 'us-east-1',
			flapjack_url: 'http://127.0.0.1:9900'
		});
		// The ingest call (via global fetch) should use the injected flapjackUrl
		expect(globalFetchMock).toHaveBeenCalledWith(
			'http://127.0.0.1:9900/1/indexes/custfactory_factory-index/batch',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('seedSearchableIndexForCustomer rejects non-loopback flapjackUrl overrides', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: 'tok-abc',
				name: 'search-index',
				region: 'us-east-1',
				flapjackUrl: 'https://flapjack.example.com',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'FLAPJACK_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createSeedSearchableIndexFactory falls back to contract DEFAULT_FLAPJACK_URL when flapjackUrl omitted', async () => {
		// Stub global fetch for ingest call inside the factory
		const globalFetchMock = vi.fn().mockResolvedValue(makeJsonResponse(200, { taskID: 1 }));
		vi.stubGlobal('fetch', globalFetchMock);

		const apiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, { hits: [{ title: 'Rust Programming Language' }] })
			);
		const adminApiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'factory-index' }));
		const getCustomerIdMock = vi.fn().mockResolvedValue('cust-factory');
		const waitForSeededIndexMock = vi.fn().mockResolvedValue(undefined);

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: getCustomerIdMock,
			waitForSeededIndex: waitForSeededIndexMock
		});

		await seedFn('factory-index');

		// Should use DEFAULT_FLAPJACK_URL from contract
		expect(adminApiCallMock).toHaveBeenCalledWith('POST', '/admin/tenants/cust-factory/indexes', {
			name: 'factory-index',
			region: 'us-east-1',
			flapjack_url: DEFAULT_FLAPJACK_URL
		});
	});

	it('createSeedSearchableIndexFactory rejects non-loopback flapjackUrl overrides', async () => {
		const globalFetchMock = vi.fn();
		vi.stubGlobal('fetch', globalFetchMock);
		const apiCallMock = vi.fn();
		const adminApiCallMock = vi.fn();

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: vi.fn().mockResolvedValue('cust-factory'),
			waitForSeededIndex: vi.fn().mockResolvedValue(undefined),
			flapjackUrl: 'https://flapjack.example.com'
		});

		await expect(seedFn('factory-index')).rejects.toThrow(
			'FLAPJACK_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);
		expect(adminApiCallMock).not.toHaveBeenCalled();
		expect(globalFetchMock).not.toHaveBeenCalled();
	});

	it('loginAsUser throws on auth failure (401)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'invalid credentials' }), { status: 401 })
			);

		await expect(
			loginAsUser({
				apiUrl: 'http://localhost:3001',
				email: 'user@example.com',
				password: 'wrong',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('loginAs failed: 401');
	});

	it('loginAsUser fails after exhausting 429 retries', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			);

		const promise = loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		const rejection = expect(promise).rejects.toThrow(
			'loginAs failed: exhausted retries after 429 rate limiting'
		);

		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(10);
	});

	it('loginAsUser rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			loginAsUser({
				apiUrl: 'https://api.example.com',
				email: 'user@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			createRegisteredUser({
				apiUrl: 'https://api.example.com',
				email: 'user@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser throws on non-ok API response', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ error: 'email taken' }), { status: 409 }));

		await expect(
			createRegisteredUser({
				apiUrl: 'http://localhost:3001',
				email: 'taken@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow('createUser failed: 409');
	});

	it('createRegisteredUser fails after exhausting 429 retries', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			);

		const promise = createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'retry-limit@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});
		const rejection = expect(promise).rejects.toThrow(
			'createUser failed: exhausted retries after 429 rate limiting'
		);

		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(10);
	});

	it('exports the fixture auth retry budget used by setup:user timeout calculations', () => {
		expect(FIXTURE_AUTH_API_RETRY_BUDGET_MS).toBe(80_000);
	});

	it('exports the paid-invoice proof timeout aligned to fixture-owned Stripe and invoice polling budgets', () => {
		expect(PAID_INVOICE_PROOF_TIMEOUT_MS).toBe(450_000);
	});

	it('caps paid-invoice proof timeout below the staging lane watchdog budget', () => {
		expect(PAID_INVOICE_PROOF_TIMEOUT_MS).toBeLessThan(480_000);
	});

	it('fetchEstimatedBillForToken rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'https://billing.example.com',
				token: 'tok-abc',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('adminReactivateCustomerById rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'https://admin.example.com',
				customerId: 'cust-123',
				adminKey: 'admin-key',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedSearchableIndexForCustomer reuses normalized token and index name after the guard step', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Tenant A Document' }]
				})
			);

		const seeded = await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: ' cust-123 ',
			token: ' tok-abc ',
			name: ' search-index ',
			region: 'us-east-1',
			flapjackUrl: 'http://localhost:7700',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document',
			documents: [{ objectID: 'doc-1', title: 'Tenant A Document' }],
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(seeded.name).toBe('search-index');
		expect(fetchMock).toHaveBeenNthCalledWith(
			3,
			'http://localhost:3001/indexes/search-index/keys',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					description: 'e2e-search-search-index',
					acl: ['search', 'addObject']
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			5,
			'http://localhost:3001/indexes/search-index/search',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					query: 'Tenant'
				})
			}
		);
	});

	it('formatFixtureSetupFailure reports api URL and masked admin-key fingerprint only', () => {
		const fullAdminKey = 'abcd-secret-super-long-key';
		const failureMessage = formatFixtureSetupFailure({
			setupName: 'customer auth setup',
			expectedPath: '/dashboard',
			currentPath: '/login',
			apiUrl: 'http://localhost:3001',
			adminKey: fullAdminKey,
			bootstrapCommand: 'scripts/bootstrap-env-local.sh',
			alertText: 'Invalid credentials'
		});

		expect(failureMessage).toContain('API URL: http://localhost:3001');
		// Per the 25beb7d7 "matt: posthoc security" tightening, the fingerprint
		// no longer leaks any prefix chars of the admin key — only presence
		// and length.
		expect(failureMessage).toContain('Admin key fingerprint: (present, len=26)');
		expect(failureMessage).not.toContain(fullAdminKey);
		expect(failureMessage).not.toContain('secret-super-long-key');
		expect(failureMessage).not.toContain('abcd');
		expect(failureMessage).toContain('scripts/bootstrap-env-local.sh');
		expect(failureMessage).toContain('scripts/api-dev.sh');
	});

	it('formatFixtureSetupFailure includes response status and URL without exposing full admin key', () => {
		const failureMessage = formatFixtureSetupFailure({
			setupName: 'admin auth setup',
			expectedPath: '/admin/fleet',
			currentPath: '/admin/login',
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key-12345',
			bootstrapCommand: 'scripts/bootstrap-env-local.sh',
			responseStatus: 401,
			responseUrl: 'http://localhost:3001/admin/login'
		});

		expect(failureMessage).toContain(
			'Login response: status 401 at http://localhost:3001/admin/login'
		);
		// Privacy-safe fingerprint format (post 25beb7d7): no prefix chars.
		expect(failureMessage).toContain('Admin key fingerprint: (present, len=15)');
		expect(failureMessage).not.toContain('admin-key-12345');
		expect(failureMessage).not.toContain('Admin key fingerprint: admi');
		expect(failureMessage).toContain('scripts/bootstrap-env-local.sh');
		expect(failureMessage).toContain('scripts/api-dev.sh');
		expect(failureMessage).toContain('docs/runbooks/local-dev.md');
	});
});
