import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import {
	_parseOptionalU32 as parseOptionalU32,
	_parseOptionalU64 as parseOptionalU64
} from './+page.server';
import {
	ADMIN_SESSION_COOKIE,
	clearAdminSessionsForTest,
	createAdminSession
} from '$lib/server/admin-session';
import { DETAIL_FIXTURE } from '../admin-customer-detail.test-fixtures';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
	clearAdminSessionsForTest();
});

afterEach(() => {
	clearAdminSessionsForTest();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

describe('parseOptionalU32', () => {
	it('parses a valid positive integer string', () => {
		expect(parseOptionalU32('42')).toBe(42);
	});

	it('returns undefined for null', () => {
		expect(parseOptionalU32(null)).toBeUndefined();
	});

	it('returns undefined for empty string', () => {
		expect(parseOptionalU32('')).toBeUndefined();
	});

	it('returns undefined for whitespace-only string', () => {
		expect(parseOptionalU32('   ')).toBeUndefined();
	});

	it('returns undefined for zero', () => {
		expect(parseOptionalU32('0')).toBeUndefined();
	});

	it('returns undefined for negative number', () => {
		expect(parseOptionalU32('-5')).toBeUndefined();
	});

	it('returns undefined for non-numeric string', () => {
		expect(parseOptionalU32('abc')).toBeUndefined();
	});

	it('trims whitespace before parsing', () => {
		expect(parseOptionalU32('  100  ')).toBe(100);
	});

	it('returns undefined for Infinity string', () => {
		expect(parseOptionalU32('Infinity')).toBeUndefined();
	});

	it('parses integer portion of decimal string', () => {
		// parseInt("3.14", 10) → 3
		expect(parseOptionalU32('3.14')).toBe(3);
	});

	it('returns undefined for File (non-string FormDataEntryValue)', () => {
		const file = new File(['content'], 'test.txt');
		expect(parseOptionalU32(file)).toBeUndefined();
	});
});

describe('parseOptionalU64', () => {
	it('delegates to parseOptionalU32', () => {
		expect(parseOptionalU64('999')).toBe(999);
		expect(parseOptionalU64(null)).toBeUndefined();
		expect(parseOptionalU64('0')).toBeUndefined();
		expect(parseOptionalU64('-1')).toBeUndefined();
	});
});

// Helper: create an authenticated action context with a mock fetch
function actionContext(
	formParams: Record<string, string>,
	fetchHandler: (url: string, init?: RequestInit) => Promise<Response>,
	overrides: Record<string, unknown> = {}
) {
	const adminSession = createAdminSession(3600);
	return {
		request: new Request('http://localhost/admin/customers/test-id/action', {
			method: 'POST',
			body: new URLSearchParams(formParams)
		}),
		fetch: async (input: string | URL | Request, init?: RequestInit) => {
			const url =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			return fetchHandler(url, init);
		},
		params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
		cookies: {
			get: (name: string) => (name === ADMIN_SESSION_COOKIE ? adminSession.id : undefined)
		},
		...overrides
	} as never;
}

function jsonResponse(body: unknown) {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { 'content-type': 'application/json' }
	});
}

function loadContext(
	fetchHandler: (url: string, init?: RequestInit) => Promise<Response>,
	tenantId = 'aaaaaaaa-0002-0000-0000-000000000002',
	withSession = true
) {
	const adminSession = withSession ? createAdminSession(3600) : null;
	return {
		fetch: async (input: string | URL | Request, init?: RequestInit) => {
			const url =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			return fetchHandler(url, init);
		},
		params: { id: tenantId },
		depends: vi.fn(),
		cookies: {
			get: (name: string) =>
				name === ADMIN_SESSION_COOKIE && adminSession ? adminSession.id : undefined
		}
	} as never;
}

describe('load', () => {
	it('redirects to admin login when the session is missing', async () => {
		const { load } = await import('./+page.server');

		await expect(load(loadContext(async () => jsonResponse({}), undefined, false))).rejects.toMatchObject(
			{
				status: 303,
				location: '/admin/login'
			}
		);
	});

	it('retries transient tenant-detail failures before succeeding', async () => {
		const { load } = await import('./+page.server');
		vi.useFakeTimers();

		let tenantAttempts = 0;
		const ctx = loadContext(async (url) => {
			if (url.endsWith('/admin/tenants/aaaaaaaa-0002-0000-0000-000000000002')) {
				tenantAttempts += 1;
				if (tenantAttempts === 1) {
					return new Response('temporary failure', { status: 503 });
				}

				return new Response(
					JSON.stringify({
						id: 'aaaaaaaa-0002-0000-0000-000000000002',
						name: 'Retry Target',
						email: 'retry-target@example.com',
						status: 'active',
						billing_plan: 'shared',
						index_count: 1,
						stripe_customer_id: null,
						created_at: '2026-03-27T00:00:00Z',
						updated_at: '2026-03-27T00:00:00Z',
						last_accessed_at: null
					}),
					{ status: 200 }
				);
			}

			if (url.endsWith('/indexes') || url.endsWith('/deployments') || url.endsWith('/invoices')) {
				return new Response(JSON.stringify([]), { status: 200 });
			}

			return new Response(JSON.stringify(null), { status: 200 });
		});

		const loadPromise = load(ctx);
		await vi.runAllTimersAsync();
		const result = (await loadPromise) as { tenant: { name: string } };

		expect(tenantAttempts).toBe(2);
		expect(result.tenant.name).toBe('Retry Target');
	});

	it('requests tenant indexes and maps exact table fields', async () => {
		const { load } = await import('./+page.server');
		const tenantId = DETAIL_FIXTURE.tenant.id;
		const indexesPath = `/admin/tenants/${tenantId}/indexes`;
		const requestedUrls: string[] = [];

		const ctx = loadContext(async (url) => {
			requestedUrls.push(url);

			if (url.endsWith(indexesPath)) {
				return jsonResponse([
					{
						name: 'alpha',
						region: 'us-east-1',
						endpoint: 'https://alpha.flapjack.test',
						entries: 0,
						data_size_bytes: 0,
						status: 'running',
						tier: 'active',
						last_accessed_at: null,
						cold_since: null,
						created_at: '2026-04-01T00:00:00Z'
					}
				]);
			}
			if (url.endsWith(`/admin/tenants/${tenantId}`)) {
				return jsonResponse(DETAIL_FIXTURE.tenant);
			}

			return jsonResponse([]);
		}, tenantId);

		const result = await load(ctx);

		expect(requestedUrls.some((url) => url.endsWith(indexesPath))).toBe(true);
		expect((result as { indexes: unknown }).indexes).toEqual([
			{ name: 'alpha', region: 'us-east-1', status: 'running', entries: 0, tier: 'active' }
		]);
	});

	it('preserves an empty index catalog', async () => {
		const { load } = await import('./+page.server');
		const tenantId = DETAIL_FIXTURE.tenant.id;

		const ctx = loadContext(async (url) => {
			if (url.endsWith(`/admin/tenants/${tenantId}/indexes`)) {
				return jsonResponse([]);
			}
			if (url.endsWith(`/admin/tenants/${tenantId}`)) {
				return jsonResponse(DETAIL_FIXTURE.tenant);
			}

			return jsonResponse([]);
		}, tenantId);

		const result = await load(ctx);

		expect((result as { indexes: unknown[] }).indexes).toEqual([]);
	});

	it('uses null only when the optional index fetch fails', async () => {
		const { load } = await import('./+page.server');
		const tenantId = DETAIL_FIXTURE.tenant.id;

		const ctx = loadContext(async (url) => {
			if (url.endsWith(`/admin/tenants/${tenantId}/indexes`)) {
				return new Response('index catalog unavailable', { status: 400 });
			}
			if (url.endsWith(`/admin/tenants/${tenantId}`)) {
				return jsonResponse(DETAIL_FIXTURE.tenant);
			}

			return jsonResponse([]);
		}, tenantId);

		const result = await load(ctx);

		expect((result as { indexes: null }).indexes).toBeNull();
	});
});

describe('actions.updateQuotas', () => {
	it('fails with 400 when all quota fields are empty', async () => {
		const { actions } = await import('./+page.server');

		const fetchSpy = vi.fn();
		const ctx = actionContext({}, fetchSpy);

		const result = await actions.updateQuotas(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBe('At least one quota value is required');
		// The admin API should never be called on empty submission
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('sends only parsed numeric fields to updateQuotas API', async () => {
		const { actions } = await import('./+page.server');

		let capturedBody = '';
		const ctx = actionContext(
			{
				max_query_rps: '250',
				max_write_rps: '',
				max_storage_bytes: '4294967296',
				max_indexes: '20'
			},
			async (_url, init) => {
				capturedBody = String(init?.body ?? '');
				return new Response(JSON.stringify({}), { status: 200 });
			}
		);

		const result = await actions.updateQuotas(ctx);

		expect(result).toEqual({ success: true, message: 'Quotas updated' });
		// max_write_rps was empty string — should be excluded (undefined)
		const parsed = JSON.parse(capturedBody);
		expect(parsed.max_query_rps).toBe(250);
		expect(parsed.max_write_rps).toBeUndefined();
		expect(parsed.max_storage_bytes).toBe(4294967296);
		expect(parsed.max_indexes).toBe(20);
	});

	it('returns error message when the API call fails', async () => {
		const { actions } = await import('./+page.server');

		const ctx = actionContext(
			{ max_query_rps: '100' },
			async () =>
				new Response(JSON.stringify({ error: 'invalid quota payload' }), {
					status: 400,
					headers: { 'content-type': 'application/json' }
				})
		);

		const result = await actions.updateQuotas(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBeTruthy();
	});
});

describe('actions.terminateDeployment', () => {
	it('fails with 400 when deployment_id is missing', async () => {
		const { actions } = await import('./+page.server');

		const fetchSpy = vi.fn();
		const ctx = actionContext({}, fetchSpy);

		const result = await actions.terminateDeployment(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBe('Deployment ID is required');
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('fails with 400 when deployment_id is empty string', async () => {
		const { actions } = await import('./+page.server');

		const fetchSpy = vi.fn();
		const ctx = actionContext({ deployment_id: '  ' }, fetchSpy);

		const result = await actions.terminateDeployment(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBe('Deployment ID is required');
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('calls terminateDeployment API with the submitted deployment id', async () => {
		const { actions } = await import('./+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		const deploymentId = 'bbbbbbbb-0001-0000-0000-000000000001';

		const ctx = actionContext({ deployment_id: deploymentId }, async (url, init) => {
			capturedUrl = url;
			capturedMethod = init?.method ?? 'GET';
			return new Response(JSON.stringify({}), { status: 200 });
		});

		const result = await actions.terminateDeployment(ctx);

		expect(result).toEqual({ success: true, message: 'Deployment terminated' });
		expect(capturedUrl).toContain(`/admin/deployments/${deploymentId}`);
		expect(capturedMethod).toBe('DELETE');
	});

	it('returns error message when the API call fails', async () => {
		const { actions } = await import('./+page.server');

		const ctx = actionContext(
			{ deployment_id: 'bbbbbbbb-0001-0000-0000-000000000001' },
			async () => new Response('Not Found', { status: 404 })
		);

		const result = await actions.terminateDeployment(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBeTruthy();
	});
});

describe('actions.viewInvoice', () => {
	it('fails with 400 when invoice_id is missing', async () => {
		const { actions } = await import('./+page.server');

		const fetchSpy = vi.fn();
		const ctx = actionContext({}, fetchSpy);

		const result = await actions.viewInvoice(ctx);

		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBe('Invoice ID is required');
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('loads exact invoice detail for the submitted invoice id', async () => {
		const { actions } = await import('./+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		const invoiceId = 'cccccccc-0001-0000-0000-000000000001';
		const invoiceDetail = {
			id: invoiceId,
			customer_id: 'aaaaaaaa-0002-0000-0000-000000000002',
			period_start: '2026-01-01',
			period_end: '2026-01-31',
			subtotal_cents: 12000,
			total_cents: 13000,
			tax_cents: 1000,
			currency: 'usd',
			status: 'paid',
			minimum_applied: false,
			stripe_invoice_id: 'in_test_123',
			hosted_invoice_url: 'https://invoice.stripe.com/i/acct_x/test_123',
			pdf_url: 'https://invoice.stripe.com/i/acct_x/test_123/pdf',
			line_items: [
				{
					id: 'dddddddd-0001-0000-0000-000000000001',
					description: 'Hot storage',
					quantity: '42.5',
					unit: 'mb_month',
					unit_price_cents: '5',
					amount_cents: 12000,
					region: 'us-east-1'
				}
			],
			created_at: '2026-02-01T00:00:00Z',
			finalized_at: '2026-02-01T01:00:00Z',
			paid_at: '2026-02-02T00:00:00Z'
		};

		const ctx = actionContext({ invoice_id: invoiceId }, async (url, init) => {
			capturedUrl = url;
			capturedMethod = init?.method ?? 'GET';
			return new Response(JSON.stringify(invoiceDetail), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});
		});

		const result = await actions.viewInvoice(ctx);

		expect(result).toEqual({ success: true, invoiceDetail });
		expect(capturedUrl).toContain(`/admin/invoices/${invoiceId}`);
		expect(capturedMethod).toBe('GET');
	});

	it('rejects invoice detail for a different customer', async () => {
		const { actions } = await import('./+page.server');

		const invoiceId = 'cccccccc-0002-0000-0000-000000000002';
		const ctx = actionContext(
			{ invoice_id: invoiceId },
			async () =>
				new Response(
					JSON.stringify({
						id: invoiceId,
						customer_id: 'aaaaaaaa-9999-0000-0000-000000000999',
						period_start: '2026-02-01',
						period_end: '2026-02-28',
						subtotal_cents: 18000,
						total_cents: 18000,
						tax_cents: 0,
						currency: 'usd',
						status: 'paid',
						minimum_applied: false,
						stripe_invoice_id: 'in_wrong_customer',
						hosted_invoice_url: null,
						pdf_url: null,
						line_items: [],
						created_at: '2026-03-01T00:00:00Z',
						finalized_at: null,
						paid_at: null
					}),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
		);

		const result = await actions.viewInvoice(ctx);

		const data = (result as { data: { success: boolean; error: string; invoiceDetail?: unknown } })
			.data;
		expect(data.success).toBe(false);
		expect(data.error).toBe('Invoice does not belong to this customer');
		expect(data.invoiceDetail).toBeUndefined();
	});
});

// ---------------------------------------------------------------------------
// T0.2 — actions.impersonate must pass purpose='impersonation' to the API.
//
// Why this test exists: the API handler at infra/api/src/routes/admin/tokens.rs
// only writes an audit_log row when the body field `purpose` equals the exact
// string "impersonation". If the SvelteKit form action forgets to pass it,
// every operator impersonation event is silently invisible in T1.4's
// per-customer audit view. This test asserts the body shape end-to-end:
// captures the actual JSON sent to /admin/tokens and checks the field.
// ---------------------------------------------------------------------------

describe('actions.impersonate', () => {
	it('POSTs purpose="impersonation" to /admin/tokens', async () => {
		const { actions } = await import('./+page.server');

		let capturedUrl = '';
		let capturedBody = '';
		const ctx = actionContext({}, async (url, init) => {
			capturedUrl = url;
			capturedBody = String(init?.body ?? '');
			// Return a minimal successful token response so the action
			// proceeds through cookie-set + redirect — but the redirect
			// throws SvelteKit's `Redirect` symbol; we catch it below.
			return new Response(
				JSON.stringify({ token: 'test-token', expires_at: '2099-01-01T00:00:00Z' }),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			);
		});

		// Augment the actionContext with the SvelteKit-specific bits the
		// impersonate action uses but updateQuotas doesn't: a `url` and a
		// cookies.set() spy. Cast through `unknown` so TS doesn't complain
		// about the partial cookies impl — the test only exercises the
		// branch up to the first cookies.set() and never reads them back.
		const cookieJar = new Map<string, string>();
		const ctxAny = ctx as unknown as {
			url: URL;
			cookies: {
				get: (n: string) => string | undefined;
				set: (n: string, v: string) => void;
			};
		};
		ctxAny.url = new URL('http://localhost/admin/customers/test-id');
		const originalGet = ctxAny.cookies.get;
		ctxAny.cookies = {
			get: originalGet,
			set: (name: string, value: string) => {
				cookieJar.set(name, value);
			}
		};

		// SvelteKit's `redirect()` throws — catch and ignore so the test
		// can inspect the captured fetch.
		try {
			await actions.impersonate(ctx);
		} catch {
			// ignore expected redirect throw
		}

		expect(capturedUrl).toContain('/admin/tokens');
		const parsed = JSON.parse(capturedBody) as Record<string, unknown>;
		// Discriminating: a regression that drops purpose would leave parsed.purpose
		// undefined and this assertion would fail.
		expect(parsed.purpose).toBe('impersonation');
		// Sanity: customer_id is the path param, expires_in_secs is set.
		expect(parsed.customer_id).toBe('aaaaaaaa-0002-0000-0000-000000000002');
		expect(parsed.expires_in_secs).toBeTypeOf('number');
	});
});
