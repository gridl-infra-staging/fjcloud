import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import {
	ADMIN_SESSION_COOKIE,
	clearAdminSessionsForTest,
	createAdminSession
} from '$lib/server/admin-session';
import {
	ACTIVE_DETAIL_FIXTURE,
	DETAIL_FIXTURE,
	POPULATED_AUDIT_FIXTURE_ROWS
} from './admin-customer-detail.test-fixtures';

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/customers') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
	clearAdminSessionsForTest();
});

afterEach(() => {
	cleanup();
	clearAdminSessionsForTest();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

describe('Admin customer detail', () => {
	it('detail load returns 404 when the tenant is missing', async () => {
		const { load } = await import('./[id]/+page.server');

		await expect(
			load({
				fetch: async () =>
					new Response(JSON.stringify({ error: 'customer not found' }), {
						status: 404,
						headers: { 'content-type': 'application/json' }
					}),
				params: { id: 'missing-customer' },
				depends: vi.fn()
			} as never)
		).rejects.toMatchObject({
			status: 404
		});
	});

	it('detail load preserves upstream admin API failures', async () => {
		const { load } = await import('./[id]/+page.server');

		await expect(
			load({
				fetch: async () =>
					new Response(JSON.stringify({ error: 'tenant service unavailable' }), {
						status: 500,
						headers: { 'content-type': 'application/json' }
					}),
				params: { id: 'broken-customer' },
				depends: vi.fn()
			} as never)
		).rejects.toMatchObject({
			name: 'AdminClientError',
			status: 500,
			message: 'tenant service unavailable'
		});
	});

	it('detail load preserves unavailable sentinels for deployment and invoice fetch failures', async () => {
		const { load } = await import('./[id]/+page.server');
		const tenantId = DETAIL_FIXTURE.tenant.id;

		const json = (body: unknown) =>
			new Response(JSON.stringify(body), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});

		const result = await load({
			fetch: async (input: string | URL | Request) => {
				const url =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;

				if (url.includes(`/admin/tenants/${tenantId}/deployments`)) {
					return new Response('deployment service unavailable', { status: 503 });
				}

				if (url.includes(`/admin/tenants/${tenantId}/invoices`)) {
					return new Response('invoice service unavailable', { status: 503 });
				}

				if (url.includes(`/admin/tenants/${tenantId}/usage`)) {
					return json(DETAIL_FIXTURE.usage);
				}

				if (url.includes(`/admin/tenants/${tenantId}/rate-card`)) {
					return json(DETAIL_FIXTURE.rateCard);
				}

				if (url.includes(`/admin/tenants/${tenantId}/quotas`)) {
					return json(DETAIL_FIXTURE.quotas);
				}

				if (url.includes(`/admin/tenants/${tenantId}`)) {
					return json(DETAIL_FIXTURE.tenant);
				}

				return new Response('not found', { status: 404 });
			},
			params: { id: tenantId },
			depends: vi.fn()
		} as never);

		expect((result as { deployments: null }).deployments).toBeNull();
		expect((result as { invoices: null }).invoices).toBeNull();
		expect((result as { usage: typeof DETAIL_FIXTURE.usage }).usage).toEqual(DETAIL_FIXTURE.usage);
	});

	it('detail load requests customer audit rows and keeps an unavailable sentinel on optional failure', async () => {
		const { load } = await import('./[id]/+page.server');
		const tenantId = DETAIL_FIXTURE.tenant.id;
		const auditPath = `/admin/customers/${tenantId}/audit`;

		const json = (body: unknown) =>
			new Response(JSON.stringify(body), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});

		const requestedUrls: string[] = [];
		const successful = await load({
			fetch: async (input: string | URL | Request) => {
				const url =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				requestedUrls.push(url);

				if (url.includes(auditPath)) {
					return json(POPULATED_AUDIT_FIXTURE_ROWS);
				}
				if (url.includes(`/admin/tenants/${tenantId}/usage`)) {
					return json(DETAIL_FIXTURE.usage);
				}
				if (url.includes(`/admin/tenants/${tenantId}/rate-card`)) {
					return json(DETAIL_FIXTURE.rateCard);
				}
				if (url.includes(`/admin/tenants/${tenantId}/quotas`)) {
					return json(DETAIL_FIXTURE.quotas);
				}
				if (url.includes(`/admin/tenants/${tenantId}/deployments`)) {
					return json(DETAIL_FIXTURE.deployments);
				}
				if (url.includes(`/admin/tenants/${tenantId}/invoices`)) {
					return json(DETAIL_FIXTURE.invoices);
				}
				if (url.includes(`/admin/tenants/${tenantId}`)) {
					return json(DETAIL_FIXTURE.tenant);
				}
				return new Response('not found', { status: 404 });
			},
			params: { id: tenantId },
			depends: vi.fn()
		} as never);

		expect(requestedUrls.some((url) => url.includes(auditPath))).toBe(true);
		expect((successful as { audit: typeof POPULATED_AUDIT_FIXTURE_ROWS }).audit).toEqual(
			POPULATED_AUDIT_FIXTURE_ROWS
		);

		const withAuditFailure = await load({
			fetch: async (input: string | URL | Request) => {
				const url =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;

				if (url.includes(auditPath)) {
					return new Response('audit service unavailable', { status: 503 });
				}
				if (url.includes(`/admin/tenants/${tenantId}/usage`)) {
					return json(DETAIL_FIXTURE.usage);
				}
				if (url.includes(`/admin/tenants/${tenantId}/rate-card`)) {
					return json(DETAIL_FIXTURE.rateCard);
				}
				if (url.includes(`/admin/tenants/${tenantId}/quotas`)) {
					return json(DETAIL_FIXTURE.quotas);
				}
				if (url.includes(`/admin/tenants/${tenantId}/deployments`)) {
					return json(DETAIL_FIXTURE.deployments);
				}
				if (url.includes(`/admin/tenants/${tenantId}/invoices`)) {
					return json(DETAIL_FIXTURE.invoices);
				}
				if (url.includes(`/admin/tenants/${tenantId}`)) {
					return json(DETAIL_FIXTURE.tenant);
				}
				return new Response('not found', { status: 404 });
			},
			params: { id: tenantId },
			depends: vi.fn()
		} as never);

		expect((withAuditFailure as { audit: null }).audit).toBeNull();
		expect((withAuditFailure as { tenant: { id: string } }).tenant.id).toBe(tenantId);
	});

	it('shows customer detail tabs', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		expect(screen.getByRole('button', { name: 'Info' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Indexes' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Deployments' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Usage' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Invoices' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Rate Card' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Audit' })).toBeInTheDocument();
	});

	it('reactivate action calls the admin API endpoint', async () => {
		const { actions } = await import('./[id]/+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		const adminSession = createAdminSession(3600);

		const request = new Request('http://localhost/admin/customers/aaaaaaaa-0002/reactivate', {
			method: 'POST',
			body: new URLSearchParams()
		});

		const result = await actions.reactivate({
			request,
			fetch: async (input: string | URL | Request, init?: RequestInit) => {
				capturedUrl = typeof input === 'string' ? input : input.toString();
				capturedMethod = init?.method ?? 'GET';
				return new Response(JSON.stringify({ message: 'customer reactivated' }), { status: 200 });
			},
			params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
			cookies: {
				get: (name: string) => (name === ADMIN_SESSION_COOKIE ? adminSession.id : undefined)
			}
		} as never);

		expect(capturedUrl).toContain(
			'/admin/customers/aaaaaaaa-0002-0000-0000-000000000002/reactivate'
		);
		expect(capturedMethod).toBe('POST');
		expect(result).toEqual({ success: true, message: 'Customer reactivated' });
	});

	it('customer info hides billing mode controls', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		expect(screen.queryByText('Billing Mode')).not.toBeInTheDocument();
		expect(screen.queryByTestId('billing-mode-select')).not.toBeInTheDocument();
	});

	it('shows invoice status badges in invoices tab', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Invoices' }));

		expect(screen.getByText('paid')).toBeInTheDocument();
		expect(screen.getByText('failed')).toBeInTheDocument();
		expect(screen.getByText('draft')).toBeInTheDocument();
	});

	it('quota_tab_shows_current_quotas', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Quotas' }));

		expect(screen.getByText('Index Quotas')).toBeInTheDocument();
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('orders')).toBeInTheDocument();
		expect(screen.getByText('10.00 GB')).toBeInTheDocument();
		expect(screen.getByText('2.00 GB')).toBeInTheDocument();
		expect(screen.getByText('120')).toBeInTheDocument();
		expect(screen.getByText('60')).toBeInTheDocument();
	});

	// quota_edit_submits_update — contract now owned by admin-customer-detail.server.test.ts

	it.each([
		{
			name: 'reactivate',
			invoke: (
				actions: Awaited<typeof import('./[id]/+page.server')>['actions'],
				fetchSpy: ReturnType<typeof vi.fn>
			) =>
				actions.reactivate({
					request: new Request('http://localhost/admin/customers/aaaaaaaa-0002/reactivate', {
						method: 'POST',
						body: new URLSearchParams()
					}),
					fetch: fetchSpy,
					params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
					cookies: { get: () => undefined }
				} as never)
		},
		{
			name: 'updateQuotas',
			invoke: (
				actions: Awaited<typeof import('./[id]/+page.server')>['actions'],
				fetchSpy: ReturnType<typeof vi.fn>
			) =>
				actions.updateQuotas({
					request: new Request('http://localhost/admin/customers/aaaaaaaa-0002/quotas', {
						method: 'POST',
						body: new URLSearchParams({ max_query_rps: '250' })
					}),
					fetch: fetchSpy,
					params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
					cookies: { get: () => undefined }
				} as never)
		},
		{
			name: 'syncStripe',
			invoke: (
				actions: Awaited<typeof import('./[id]/+page.server')>['actions'],
				fetchSpy: ReturnType<typeof vi.fn>
			) =>
				actions.syncStripe({
					request: new Request('http://localhost/admin/customers/aaaaaaaa-0002/sync-stripe', {
						method: 'POST',
						body: new URLSearchParams()
					}),
					fetch: fetchSpy,
					params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
					cookies: { get: () => undefined }
				} as never)
		},
		{
			name: 'softDelete',
			invoke: (
				actions: Awaited<typeof import('./[id]/+page.server')>['actions'],
				fetchSpy: ReturnType<typeof vi.fn>
			) =>
				actions.softDelete({
					request: new Request('http://localhost/admin/customers/aaaaaaaa-0002', {
						method: 'POST',
						body: new URLSearchParams()
					}),
					fetch: fetchSpy,
					params: { id: 'aaaaaaaa-0002-0000-0000-000000000002' },
					cookies: { get: () => undefined }
				} as never)
		},
		{
			name: 'terminateDeployment',
			invoke: (
				actions: Awaited<typeof import('./[id]/+page.server')>['actions'],
				fetchSpy: ReturnType<typeof vi.fn>
			) =>
				actions.terminateDeployment({
					request: new Request('http://localhost/admin/customers/aaaaaaaa-0002/deployments', {
						method: 'POST',
						body: new URLSearchParams({ deployment_id: 'bbbbbbbb-0001-0000-0000-000000000001' })
					}),
					fetch: fetchSpy,
					cookies: { get: () => undefined }
				} as never)
		}
	])('%s action redirects to admin login when session is missing', async ({ invoke }) => {
		const { actions } = await import('./[id]/+page.server');
		const fetchSpy = vi.fn();

		try {
			await invoke(actions, fetchSpy);
			expect.unreachable('Expected redirect to be thrown');
		} catch (e: unknown) {
			const err = e as { status: number; location: string };
			expect(err.status).toBe(303);
			expect(err.location).toBe('/admin/login');
		}

		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('customer_detail_shows_tier_badges', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Indexes' }));

		// Verify tier badges are rendered
		const tierBadges = screen.getAllByTestId('tier-badge');
		expect(tierBadges).toHaveLength(2);

		// Verify the tier values are correct
		expect(tierBadges[0].textContent?.trim()).toBe('active');
		expect(tierBadges[1].textContent?.trim()).toBe('cold');
	});

	it('rate_card_tab_does_not_show_vm_rate_per_hour', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Rate Card' }));

		// VM-hour pricing is removed — we are usage-based only
		expect(screen.queryByText('VM per hour')).not.toBeInTheDocument();
		expect(screen.queryByText('vm_rate_per_hour')).not.toBeInTheDocument();

		// Search/write dimensions are removed in per-MB model
		expect(screen.queryByText('Search per 1k')).not.toBeInTheDocument();
		expect(screen.queryByText('Write per 1k')).not.toBeInTheDocument();
		expect(screen.queryByText('Storage per GB / month')).not.toBeInTheDocument();

		// Per-MB hot storage rate should be present
		expect(screen.getByText('Storage per MB / month')).toBeInTheDocument();
		expect(screen.getByText('0.05')).toBeInTheDocument();
	});

	it('rate_card_tab_shows_storage_rates_and_shared_minimum', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Rate Card' }));

		// Shared minimum displays distinctly from dedicated minimum
		expect(screen.getByText('Shared minimum')).toBeInTheDocument();
		expect(screen.getByText('$5.00')).toBeInTheDocument();

		// Storage rate fields
		expect(screen.getByText('Cold storage per GB / month')).toBeInTheDocument();
		expect(screen.getByText('0.10')).toBeInTheDocument();
		expect(screen.getByText('Object storage per GB / month')).toBeInTheDocument();
		expect(screen.getByText('0.02')).toBeInTheDocument();
		expect(screen.getByText('Object storage egress per GB')).toBeInTheDocument();
		expect(screen.getByText('0.01')).toBeInTheDocument();
	});

	it('customer_detail_cold_index_has_restore_button', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Indexes' }));

		// Only cold indexes should have a restore button
		const restoreButtons = screen.getAllByTestId('index-restore-button');
		expect(restoreButtons).toHaveLength(1);
	});

	it('impersonate action mints token, sets cookies, and redirects to dashboard', async () => {
		const { actions } = await import('./[id]/+page.server');
		const { AUTH_COOKIE, IMPERSONATION_COOKIE } = await import('$lib/config');
		const { authCookieOptions } = await import('$lib/server/auth-cookies');

		const CUSTOMER_ID = 'aaaaaaaa-0002-0000-0000-000000000002';
		const MINTED_TOKEN = 'jwt-impersonation-token-abc';

		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const url = new URL('http://localhost/admin/customers/' + CUSTOMER_ID);
		const cookieStore = new Map<string, { value: string; options: Record<string, unknown> }>();
		const adminSession = createAdminSession(3600);
		cookieStore.set(ADMIN_SESSION_COOKIE, { value: adminSession.id, options: { path: '/admin' } });

		const cookies = {
			get: (name: string) => cookieStore.get(name)?.value,
			set: (name: string, value: string, options: Record<string, unknown>) => {
				cookieStore.set(name, { value, options });
			},
			delete: () => {}
		};

		try {
			await actions.impersonate({
				request: new Request(url, { method: 'POST', body: new URLSearchParams() }),
				fetch: async (input: string | URL | Request, init?: RequestInit) => {
					capturedUrl = typeof input === 'string' ? input : input.toString();
					capturedMethod = init?.method ?? 'GET';
					capturedBody = String(init?.body ?? '');
					return new Response(
						JSON.stringify({ token: MINTED_TOKEN, expires_at: '2026-03-23T14:00:00Z' }),
						{ status: 200 }
					);
				},
				params: { id: CUSTOMER_ID },
				url,
				cookies
			} as never);
			// redirect throws — should not reach here
			expect.unreachable('Expected redirect to be thrown');
		} catch (e: unknown) {
			const err = e as { status: number; location: string };
			expect(err.status).toBe(303);
			expect(err.location).toBe('/dashboard');
		}

		// Verify createToken was called with correct params
		expect(capturedUrl).toContain('/admin/tokens');
		expect(capturedMethod).toBe('POST');
		expect(capturedBody).toContain('"customer_id":"' + CUSTOMER_ID + '"');
		expect(capturedBody).toContain('"expires_in_secs":3600');

		// Verify auth cookie was set with the minted token
		const authEntry = cookieStore.get(AUTH_COOKIE);
		expect(authEntry).toBeDefined();
		expect(authEntry!.value).toBe(MINTED_TOKEN);
		const expectedAuthOpts = authCookieOptions(url, 3600, '/');
		expect(authEntry!.options).toEqual(expectedAuthOpts);

		// Verify impersonation cookie was set with the return path
		const impEntry = cookieStore.get(IMPERSONATION_COOKIE);
		expect(impEntry).toBeDefined();
		expect(impEntry!.value).toBe(`/admin/customers/${CUSTOMER_ID}`);
		expect(impEntry!.options).toEqual(expectedAuthOpts);
	});

	it('impersonate action redirects to admin login when session is missing', async () => {
		const { actions } = await import('./[id]/+page.server');

		const CUSTOMER_ID = 'aaaaaaaa-0002-0000-0000-000000000002';
		const url = new URL('http://localhost/admin/customers/' + CUSTOMER_ID);
		const fetchSpy = vi.fn();

		const cookies = {
			get: () => undefined,
			set: () => {},
			delete: () => {}
		};

		try {
			await actions.impersonate({
				request: new Request(url, { method: 'POST', body: new URLSearchParams() }),
				fetch: fetchSpy,
				params: { id: CUSTOMER_ID },
				url,
				cookies
			} as never);
			expect.unreachable('Expected redirect to be thrown');
		} catch (e: unknown) {
			const err = e as { status: number; location: string };
			expect(err.status).toBe(303);
			expect(err.location).toBe('/admin/login');
		}

		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('impersonate action returns fail when createToken errors', async () => {
		const { actions } = await import('./[id]/+page.server');

		const CUSTOMER_ID = 'aaaaaaaa-0002-0000-0000-000000000002';
		const url = new URL('http://localhost/admin/customers/' + CUSTOMER_ID);
		const adminSession = createAdminSession(3600);

		const cookies = {
			get: (name: string) => (name === ADMIN_SESSION_COOKIE ? adminSession.id : undefined),
			set: () => {},
			delete: () => {}
		};

		const result = await actions.impersonate({
			request: new Request(url, { method: 'POST', body: new URLSearchParams() }),
			fetch: async () => new Response('Unauthorized', { status: 401 }),
			params: { id: CUSTOMER_ID },
			url,
			cookies
		} as never);

		expect(result).toBeDefined();
		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBeTruthy();
	});

	it('active customer shows suspend and impersonate buttons, not reactivate', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...ACTIVE_DETAIL_FIXTURE }
		});

		// Active customers get suspend and impersonate, not reactivate
		expect(screen.getByTestId('suspend-button')).toBeInTheDocument();
		expect(screen.getByTestId('impersonate-button')).toBeInTheDocument();
		expect(screen.queryByTestId('reactivate-button')).not.toBeInTheDocument();
	});

	it('suspended customer shows reactivate and impersonate buttons, not suspend', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});

		// Suspended customers get reactivate and impersonate, not suspend
		expect(screen.getByTestId('reactivate-button')).toBeInTheDocument();
		expect(screen.getByTestId('impersonate-button')).toBeInTheDocument();
		expect(screen.queryByTestId('suspend-button')).not.toBeInTheDocument();
	});

	it('suspend action calls the admin API endpoint', async () => {
		const { actions } = await import('./[id]/+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		const adminSession = createAdminSession(3600);

		const result = await actions.suspend({
			request: new Request('http://localhost/admin/customers/aaaaaaaa-0001/suspend', {
				method: 'POST',
				body: new URLSearchParams()
			}),
			fetch: async (input: string | URL | Request, init?: RequestInit) => {
				capturedUrl = typeof input === 'string' ? input : input.toString();
				capturedMethod = init?.method ?? 'GET';
				return new Response(JSON.stringify({ message: 'customer suspended' }), { status: 200 });
			},
			params: { id: 'aaaaaaaa-0001-0000-0000-000000000001' },
			cookies: {
				get: (name: string) => (name === ADMIN_SESSION_COOKIE ? adminSession.id : undefined)
			}
		} as never);

		expect(capturedUrl).toContain('/admin/customers/aaaaaaaa-0001-0000-0000-000000000001/suspend');
		expect(capturedMethod).toBe('POST');
		expect(result).toEqual({ success: true, message: 'Customer suspended' });
	});

	it('suspend action redirects to admin login when session is missing', async () => {
		const { actions } = await import('./[id]/+page.server');
		const fetchSpy = vi.fn();

		try {
			await actions.suspend({
				request: new Request('http://localhost/admin/customers/aaaaaaaa-0001/suspend', {
					method: 'POST',
					body: new URLSearchParams()
				}),
				fetch: fetchSpy,
				params: { id: 'aaaaaaaa-0001-0000-0000-000000000001' },
				cookies: {
					get: () => undefined
				}
			} as never);
			expect.unreachable('Expected redirect to be thrown');
		} catch (e: unknown) {
			const err = e as { status: number; location: string };
			expect(err.status).toBe(303);
			expect(err.location).toBe('/admin/login');
		}

		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it('suspend action returns fail on error', async () => {
		const { actions } = await import('./[id]/+page.server');
		const adminSession = createAdminSession(3600);

		const result = await actions.suspend({
			request: new Request('http://localhost/admin/customers/bad-id/suspend', {
				method: 'POST',
				body: new URLSearchParams()
			}),
			fetch: async () => new Response('Not Found', { status: 404 }),
			params: { id: 'nonexistent-id' },
			cookies: {
				get: (name: string) => (name === ADMIN_SESSION_COOKIE ? adminSession.id : undefined)
			}
		} as never);

		expect(result).toBeDefined();
		const data = (result as { data: { success: boolean; error: string } }).data;
		expect(data.success).toBe(false);
		expect(data.error).toBeTruthy();
	});
});
