import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { SUPPORT_EMAIL } from '$lib/format';
import {
	NORMALIZED_BROWSER_ERROR_FAILURE,
	NORMALIZED_BROWSER_REJECTION_FAILURE
} from '$lib/error-boundary/client_runtime_test_fixtures';

/**
 * Mock $app/state so we can inject page.status and page.error
 * into the error boundary component under test.
 */
let mockPage: Record<string, unknown> = {
	status: 404,
	error: { message: 'Not found' },
	url: new URL('http://localhost/missing')
};

vi.mock('$app/state', () => ({
	page: new Proxy({} as Record<string, unknown>, {
		get: (_target, prop: string) => (mockPage as Record<string, unknown>)[prop]
	})
}));

afterEach(() => {
	cleanup();
	mockPage = {
		status: 404,
		error: { message: 'Not found' },
		url: new URL('http://localhost/missing')
	};
});

describe('Public error boundary (+error.svelte)', () => {
	// --- 404 ---

	it('renders "Page not found" heading for 404 status', async () => {
		mockPage = {
			status: 404,
			error: { message: 'Not found' },
			url: new URL('http://localhost/missing')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByRole('heading', { name: /page not found/i })).toBeInTheDocument();
	});

	it('shows a link back to home for 404', async () => {
		mockPage = {
			status: 404,
			error: { message: 'Not found' },
			url: new URL('http://localhost/missing')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		const homeLink = screen.getByRole('link', { name: /go.*home|back.*home|home/i });
		expect(homeLink).toHaveAttribute('href', '/');
	});

	it('displays the error message for 404 (4xx messages are customer-safe)', async () => {
		mockPage = {
			status: 404,
			error: { message: 'The requested page does not exist' },
			url: new URL('http://localhost/missing')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByText('The requested page does not exist')).toBeInTheDocument();
	});

	// --- 5xx ---

	it('renders canned recovery heading for 500 status', async () => {
		mockPage = {
			status: 500,
			error: { message: 'Internal server error' },
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByRole('heading', { name: /something went wrong/i })).toBeInTheDocument();
	});

	it('shows a link to /status for 5xx recovery', async () => {
		mockPage = {
			status: 500,
			error: { message: 'Internal server error' },
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		const statusLink = screen.getByRole('link', { name: /status/i });
		expect(statusLink).toHaveAttribute('href', '/status');
	});

	it('does NOT render raw error.message for 5xx', async () => {
		mockPage = {
			status: 500,
			error: { message: 'PG::ConnectionBad: could not connect to server' },
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.queryByText(/PG::ConnectionBad/)).not.toBeInTheDocument();
		expect(screen.queryByText(/could not connect/)).not.toBeInTheDocument();
	});

	it('renders canned copy for 503 (server error range)', async () => {
		mockPage = {
			status: 503,
			error: { message: 'Service unavailable' },
			url: new URL('http://localhost/down')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByRole('heading', { name: /something went wrong/i })).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /status/i })).toHaveAttribute('href', '/status');
	});

	// --- Other 4xx ---

	it('renders generic 4xx heading for 403', async () => {
		mockPage = {
			status: 403,
			error: { message: 'Forbidden' },
			url: new URL('http://localhost/secret')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(
			screen.getByRole('heading', { name: /could not be completed|request error/i })
		).toBeInTheDocument();
	});

	it('shows a link back to home for generic 4xx', async () => {
		mockPage = {
			status: 403,
			error: { message: 'Forbidden' },
			url: new URL('http://localhost/secret')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		const homeLink = screen.getByRole('link', { name: /go.*home|back.*home|home/i });
		expect(homeLink).toHaveAttribute('href', '/');
	});

	it('does not render unsafe infrastructure details for generic 4xx messages', async () => {
		mockPage = {
			status: 403,
			error: { message: 'ECONNREFUSED 127.0.0.1:5432 while connecting to db' },
			url: new URL('http://localhost/secret')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.queryByText(/ECONNREFUSED/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/127\.0\.0\.1/)).not.toBeInTheDocument();
		expect(
			screen.getByText(
				'The request could not be completed. Please review the request and try again.'
			)
		).toBeInTheDocument();
	});

	it('renders the shared support reference block for safe 4xx copy without weakening privacy behavior', async () => {
		mockPage = {
			status: 403,
			error: { message: 'Your request cannot be completed right now' },
			url: new URL('http://localhost/secret')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByText('Your request cannot be completed right now')).toBeInTheDocument();
		expect(screen.getAllByText('Support reference')).toHaveLength(1);
		expect(screen.getAllByText(/^web-[a-f0-9]{12}$/)).toHaveLength(1);
		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
			'href',
			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
		);
	});

	it('renders the shared support reference block for 5xx while keeping raw internals suppressed', async () => {
		mockPage = {
			status: 500,
			error: { message: 'PG::ConnectionBad: could not connect to server' },
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.queryByText(/PG::ConnectionBad/)).not.toBeInTheDocument();
		expect(screen.queryByText(/could not connect/)).not.toBeInTheDocument();
		expect(screen.getAllByText('Support reference')).toHaveLength(1);
		expect(screen.getAllByText(/^web-[a-f0-9]{12}$/)).toHaveLength(1);
		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
			'href',
			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
		);
	});

	it('uses a hook-supplied web support reference without exposing backend request ids', async () => {
		mockPage = {
			status: 500,
			error: {
				message: 'Internal server error',
				supportReference: 'web-abc123def456',
				backendRequestId: 'req-backend-123'
			},
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getAllByText('Support reference')).toHaveLength(1);
		const supportReferences = screen.getAllByText(/^web-[a-f0-9]{12}$/);
		expect(supportReferences).toHaveLength(1);
		expect(supportReferences[0]).toHaveTextContent('web-abc123def456');
		expect(screen.queryByText(/req-backend-123/i)).not.toBeInTheDocument();
	});

	it.each([
		['normalized browser error failure', NORMALIZED_BROWSER_ERROR_FAILURE],
		['normalized browser rejection failure', NORMALIZED_BROWSER_REJECTION_FAILURE]
	])(
		'renders %s shape with sanitized public copy, one support reference, and no internal correlation details',
		async (_caseName, browserFailure) => {
			mockPage = {
				status: browserFailure.status,
				error: browserFailure.error,
				url: new URL('http://localhost/broken')
			};
			const ErrorPage = (await import('./+error.svelte')).default;
			render(ErrorPage);

			expect(
				screen.getByText(
					"We're experiencing a temporary issue. Please try again shortly or check our status page for updates."
				)
			).toBeInTheDocument();
			expect(screen.getAllByText('Support reference')).toHaveLength(1);
			const supportReferences = screen.getAllByText(/^web-[a-f0-9]{12}$/);
			expect(supportReferences).toHaveLength(1);
			expect(supportReferences[0]).toHaveTextContent(browserFailure.error.supportReference);
			expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
				'href',
				expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
			);
			expect(
				screen.queryByText(/ECONNREFUSED|localhost|127\.0\.0\.1|postgres\.internal|5432/i)
			).not.toBeInTheDocument();
			expect(screen.queryByText(/backend[_-]?request[_-]?id|req-backend/i)).not.toBeInTheDocument();
		}
	);

	// --- Branding ---

	it('displays the Flapjack Cloud brand name', async () => {
		mockPage = {
			status: 404,
			error: { message: 'Not found' },
			url: new URL('http://localhost/missing')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByText('Flapjack Cloud')).toBeInTheDocument();
		expect(screen.queryByText('Griddle')).not.toBeInTheDocument();
	});

	it('displays the HTTP status code', async () => {
		mockPage = {
			status: 404,
			error: { message: 'Not found' },
			url: new URL('http://localhost/missing')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.getByText('404')).toBeInTheDocument();
	});

	it('does not expose infrastructure details for any status', async () => {
		mockPage = {
			status: 500,
			error: { message: 'ECONNREFUSED 127.0.0.1:5432' },
			url: new URL('http://localhost/broken')
		};
		const ErrorPage = (await import('./+error.svelte')).default;
		render(ErrorPage);

		expect(screen.queryByText(/ECONNREFUSED/)).not.toBeInTheDocument();
		expect(screen.queryByText(/127\.0\.0\.1/)).not.toBeInTheDocument();
		expect(screen.queryByText(/5432/)).not.toBeInTheDocument();
	});
});
