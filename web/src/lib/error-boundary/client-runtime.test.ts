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

	afterEach(() => {
		window.history.replaceState({}, '', originalPathname);
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

	it('reports browser runtime failures with sanitized metadata and explicit absent backend correlation', async () => {
		const { reportBrowserRuntimeFailure } = await loadBrowserRuntimeContract();
		const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
		window.history.replaceState({}, '', '/status');

		reportBrowserRuntimeFailure({
			status: 500,
			error: {
				message:
					"We're experiencing a temporary issue. Please try again shortly or check our status page for updates.",
				supportReference: 'web-abc123def456'
			}
		});

		expect(consoleErrorSpy).toHaveBeenCalledTimes(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			'browser runtime error reported',
			expect.objectContaining({
				status: 500,
				path: '/status',
				scope: 'public',
				support_reference: 'web-abc123def456',
				backend_correlation: 'absent'
			})
		);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			expect.any(String),
			expect.not.objectContaining({ backend_request_id: expect.anything() })
		);

		consoleErrorSpy.mockRestore();
	});

	it('reports dashboard runtime failures with dashboard scope derived from pathname', async () => {
		const { reportBrowserRuntimeFailure } = await loadBrowserRuntimeContract();
		const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
		window.history.replaceState({}, '', '/dashboard/billing');

		reportBrowserRuntimeFailure({
			status: 500,
			error: {
				message:
					"We're experiencing a temporary issue. Please try again shortly or check our status page for updates.",
				supportReference: 'web-abc123def456'
			}
		});

		expect(consoleErrorSpy).toHaveBeenCalledTimes(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			'browser runtime error reported',
			expect.objectContaining({
				path: '/dashboard/billing',
				scope: 'dashboard'
			})
		);

		consoleErrorSpy.mockRestore();
	});
});
