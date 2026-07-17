import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildBoundaryCopy } from './recovery-copy';
import type { NormalizedBrowserFailure } from './client_runtime_test_fixtures';

const SUPPORT_REFERENCE_PATTERN = /^web-[a-f0-9]{12}$/;
const SERVER_ERROR_DESCRIPTION =
	"We're experiencing a temporary issue. Please try again shortly or check our status page for updates.";
const RAW_INTERNAL_DETAIL_PATTERN =
	/(?:ECONNREFUSED|localhost|127\.0\.0\.1|postgres\.internal|5432|stack trace|req-backend)/i;
const BACKEND_CORRELATION_PATTERN = /(?:backend[_-]?request[_-]?id|req-backend)/i;

interface BrowserRuntimeContract {
	normalizeBrowserRuntimeFailure(input: unknown): NormalizedBrowserFailure;
	installBrowserRuntimeFailureListeners(
		onFailure: (failure: NormalizedBrowserFailure) => void
	): () => void;
	reportBrowserRuntimeFailure(failure: NormalizedBrowserFailure): void;
}

async function loadBrowserRuntimeContract(): Promise<BrowserRuntimeContract> {
	return (await import('./client-runtime')) as BrowserRuntimeContract;
}

function expectCustomerSafeBoundary(failure: NormalizedBrowserFailure): void {
	const boundaryCopy = buildBoundaryCopy(
		{
			status: failure.status,
			errorMessage: failure.error.message,
			scope: 'public'
		},
		failure.error.supportReference
	);
	const serializedFailure = JSON.stringify(failure);
	const supportReferences = serializedFailure.match(/web-[a-f0-9]{12}/g) ?? [];

	expect(boundaryCopy.description).toBe(SERVER_ERROR_DESCRIPTION);
	expect(boundaryCopy.supportReference).toMatch(SUPPORT_REFERENCE_PATTERN);
	expect(boundaryCopy.supportMailtoHref).toContain(boundaryCopy.supportReference);
	expect(boundaryCopy.description).not.toMatch(RAW_INTERNAL_DETAIL_PATTERN);
	expect(boundaryCopy.supportReference).not.toMatch(BACKEND_CORRELATION_PATTERN);
	expect(serializedFailure).not.toMatch(BACKEND_CORRELATION_PATTERN);
	expect(supportReferences).toHaveLength(1);
}

describe('client runtime browser-failure contract', () => {
	const originalPathname = globalThis.location.pathname;
	const originalSearch = globalThis.location.search;

	afterEach(() => {
		window.history.replaceState({}, '', `${originalPathname}${originalSearch}`);
		vi.unstubAllGlobals();
	});

	it('normalizes uncaught error events into customer-safe boundary data without backend correlation claims', async () => {
		const { normalizeBrowserRuntimeFailure } = await loadBrowserRuntimeContract();
		const normalizedFailure = normalizeBrowserRuntimeFailure({
			type: 'error',
			message: 'ECONNREFUSED 127.0.0.1:5432 while loading http://localhost:5173/dashboard',
			filename: 'http://localhost:5173/src/routes/+layout.svelte',
			lineno: 18,
			colno: 7,
			error: new Error(
				'PG::ConnectionBad: stack trace... request=req-backend-123 postgres.internal:5432'
			)
		});

		expect(normalizedFailure.status).toBe(500);
		expect(normalizedFailure.error.supportReference).toMatch(SUPPORT_REFERENCE_PATTERN);
		expect(normalizedFailure.error).not.toHaveProperty('backendRequestId');
		expectCustomerSafeBoundary(normalizedFailure);
	});

	it.each([
		[
			'Error reason',
			new Error('Unhandled rejection from http://localhost:5173 with ECONNREFUSED 10.0.0.9:5432')
		],
		['string reason', 'ECONNREFUSED while connecting to postgres.internal:5432 from localhost'],
		[
			'plain-object reason',
			{
				message: 'request req-backend-555 failed',
				details: 'stack trace from http://localhost:5173',
				host: '127.0.0.1',
				port: 5432
			}
		]
	])(
		'normalizes unhandledrejection with %s into one support reference and sanitized copy',
		async (_caseName, reason) => {
			const { normalizeBrowserRuntimeFailure } = await loadBrowserRuntimeContract();
			const normalizedFailure = normalizeBrowserRuntimeFailure({
				type: 'unhandledrejection',
				reason
			});

			expect(normalizedFailure.status).toBe(500);
			expect(normalizedFailure.error.supportReference).toMatch(SUPPORT_REFERENCE_PATTERN);
			expect(normalizedFailure.error).not.toHaveProperty('backendRequestId');
			expectCustomerSafeBoundary(normalizedFailure);
		}
	);

	it('registers and removes exactly one error and one unhandledrejection listener for the browser seam', async () => {
		const { installBrowserRuntimeFailureListeners } = await loadBrowserRuntimeContract();
		const onFailure = vi.fn();
		const addSpy = vi.spyOn(globalThis, 'addEventListener');
		const removeSpy = vi.spyOn(globalThis, 'removeEventListener');

		const cleanup = installBrowserRuntimeFailureListeners(onFailure);

		expect(addSpy.mock.calls.some(([eventName]) => eventName === 'error')).toBe(true);
		expect(addSpy.mock.calls.some(([eventName]) => eventName === 'unhandledrejection')).toBe(true);
		expect(addSpy.mock.calls.filter(([eventName]) => eventName === 'error')).toHaveLength(1);
		expect(
			addSpy.mock.calls.filter(([eventName]) => eventName === 'unhandledrejection')
		).toHaveLength(1);

		cleanup();

		expect(removeSpy.mock.calls.some(([eventName]) => eventName === 'error')).toBe(true);
		expect(removeSpy.mock.calls.some(([eventName]) => eventName === 'unhandledrejection')).toBe(
			true
		);

		addSpy.mockRestore();
		removeSpy.mockRestore();
	});

	it('attempts one best-effort POST with sanitized browser-runtime metadata only', async () => {
		const { normalizeBrowserRuntimeFailure, reportBrowserRuntimeFailure } =
			await loadBrowserRuntimeContract();
		const fetchMock = vi.fn().mockResolvedValue({ ok: true } as Response);
		vi.stubGlobal('fetch', fetchMock);
		window.history.replaceState({}, '', '/status?token=secret&redirect=http://localhost:5432');

		const normalizedFailure = normalizeBrowserRuntimeFailure({
			type: 'error',
			message: 'ECONNREFUSED 127.0.0.1:5432 for redirect=localhost',
			filename: 'http://localhost:5173/src/routes/+layout.svelte?token=secret',
			lineno: 18,
			colno: 7,
			error: new Error('request=req-backend-123 postgres.internal:5432')
		});
		reportBrowserRuntimeFailure(normalizedFailure);

		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock).toHaveBeenCalledWith(
			'/browser-errors',
			expect.objectContaining({
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: expect.any(String),
				credentials: 'omit',
				keepalive: true
			})
		);

		const [, requestInit] = fetchMock.mock.calls[0] as [string, RequestInit];
		const payload = JSON.parse(String(requestInit.body)) as Record<string, unknown>;
		const payloadKeys = Object.keys(payload).sort();
		const expectedKeys = [
			'backend_correlation',
			'event_type',
			'path',
			'scope',
			'status',
			'support_reference'
		].sort();
		const forbiddenTopLevelKeys = [
			'message',
			'stack',
			'filename',
			'lineno',
			'colno',
			'error',
			'reason',
			'token',
			'secret',
			'redirect',
			'localhost',
			'5432',
			'backend_request_id',
			'backendRequestId'
		];
		const forbiddenPayloadContent = [
			'token',
			'secret',
			'redirect',
			'localhost',
			'5432',
			'req-backend'
		];
		const serializedPayload = JSON.stringify(payload).toLowerCase();

		expect(payloadKeys).toEqual(expectedKeys);
		expect(payload.path).toBe('/status');
		expect(payload.status).toBe(500);
		expect(payload.scope).toBe('public');
		expect(payload.event_type).toBe('browser_runtime');
		expect(payload.support_reference).toMatch(SUPPORT_REFERENCE_PATTERN);
		expect(payload.backend_correlation).toBe('absent');
		for (const key of forbiddenTopLevelKeys) {
			expect(payload).not.toHaveProperty(key);
		}
		for (const snippet of forbiddenPayloadContent) {
			expect(serializedPayload).not.toContain(snippet);
		}
	});

	it('submits dashboard scope derived from pathname without duplicating scope logic', async () => {
		const { normalizeBrowserRuntimeFailure, reportBrowserRuntimeFailure } =
			await loadBrowserRuntimeContract();
		const fetchMock = vi.fn().mockResolvedValue({ ok: true } as Response);
		vi.stubGlobal('fetch', fetchMock);
		window.history.replaceState({}, '', '/dashboard/billing');

		const normalizedFailure = normalizeBrowserRuntimeFailure({
			type: 'error',
			message: 'runtime failure in dashboard',
			error: new Error('dashboard rejection')
		});
		reportBrowserRuntimeFailure(normalizedFailure);

		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [, requestInit] = fetchMock.mock.calls[0] as [string, RequestInit];
		const payload = JSON.parse(String(requestInit.body)) as Record<string, unknown>;
		expect(payload.scope).toBe('dashboard');
	});

	it('preserves the sanitized console fallback while attempting centralized reporting', async () => {
		const { normalizeBrowserRuntimeFailure, reportBrowserRuntimeFailure } =
			await loadBrowserRuntimeContract();
		const fetchMock = vi.fn().mockResolvedValue({ ok: true } as Response);
		const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
		vi.stubGlobal('fetch', fetchMock);
		window.history.replaceState({}, '', '/status?token=secret');

		const normalizedFailure = normalizeBrowserRuntimeFailure({
			type: 'error',
			message: 'ECONNREFUSED localhost:5432',
			error: new Error('request=req-backend-123')
		});
		reportBrowserRuntimeFailure(normalizedFailure);

		expect(consoleErrorSpy).toHaveBeenCalledTimes(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			'browser runtime error reported',
			expect.objectContaining({
				path: '/status',
				scope: 'public',
				status: 500,
				event_type: 'browser_runtime',
				support_reference: expect.stringMatching(SUPPORT_REFERENCE_PATTERN),
				backend_correlation: 'absent'
			})
		);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it('treats failed report submission as best effort without mutating normalized failure data', async () => {
		const { normalizeBrowserRuntimeFailure, reportBrowserRuntimeFailure } =
			await loadBrowserRuntimeContract();
		const fetchMock = vi.fn().mockRejectedValue(new Error('submission failed'));
		vi.stubGlobal('fetch', fetchMock);
		window.history.replaceState({}, '', '/status?token=secret');

		const normalizedFailure = normalizeBrowserRuntimeFailure({
			type: 'unhandledrejection',
			reason: new Error('runtime crash')
		});
		const failureSnapshot = JSON.parse(
			JSON.stringify(normalizedFailure)
		) as NormalizedBrowserFailure;

		expect(() => reportBrowserRuntimeFailure(normalizedFailure)).not.toThrow();
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock).toHaveBeenCalledWith(
			'/browser-errors',
			expect.objectContaining({
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: expect.any(String),
				credentials: 'omit',
				keepalive: true
			})
		);
		expect(normalizedFailure).toEqual(failureSnapshot);

		const boundaryCopy = buildBoundaryCopy(
			{
				status: normalizedFailure.status,
				errorMessage: normalizedFailure.error.message,
				scope: 'public'
			},
			normalizedFailure.error.supportReference
		);
		expect(boundaryCopy.supportReference).toMatch(SUPPORT_REFERENCE_PATTERN);
		expect(boundaryCopy.supportReference).toBe(normalizedFailure.error.supportReference);
	});
});
