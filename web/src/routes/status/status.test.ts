import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { parseServiceStatus, statusLabelForServiceStatus } from './status_contract';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
});

describe('Status contract', () => {
	it.each([
		['operational', 'operational', 'All Systems Operational'],
		['degraded', 'degraded', 'Degraded Performance'],
		['outage', 'outage', 'Major Outage'],
		['unexpected', 'operational', 'All Systems Operational'],
		[undefined, 'operational', 'All Systems Operational']
	] as const)(
		'parses "%s" to "%s" and derives label "%s"',
		(rawStatus, expectedStatus, expectedLabel) => {
			const parsedStatus = parseServiceStatus(rawStatus);
			expect(parsedStatus).toBe(expectedStatus);
			expect(statusLabelForServiceStatus(parsedStatus)).toBe(expectedLabel);
		}
	);
});

describe('Status page', () => {
	const TEST_STATUS_URL = 'http://localhost/status';

	function setStatusPageLocation(url: string): void {
		const jsdomGlobal = globalThis as typeof globalThis & {
			jsdom?: { reconfigure: (settings: { url: string }) => void };
		};
		if (!jsdomGlobal.jsdom) {
			throw new Error('Missing jsdom global; cannot set status-page hostname in tests.');
		}
		jsdomGlobal.jsdom.reconfigure({ url });
	}

	beforeEach(() => {
		setStatusPageLocation(TEST_STATUS_URL);
	});

	it('renders current status with "All Systems Operational" default', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: statusLabelForServiceStatus('operational'),
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.getByRole('heading', { name: /service status/i })).toBeInTheDocument();
		expect(screen.getByText('All Systems Operational')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Flapjack Cloud' })).toHaveClass('text-flapjack-ink');
	});

	it('shows last updated timestamp', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: statusLabelForServiceStatus('operational'),
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.getByTestId('status-last-updated')).toBeInTheDocument();
		expect(screen.getByTestId('status-last-updated').textContent).toContain('2026');
	});

	it('renders degraded performance status with warning styling', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'degraded',
				statusLabel: statusLabelForServiceStatus('degraded'),
				lastUpdated: '2026-02-21T14:30:00Z'
			}
		});

		expect(screen.getByText('Degraded Performance')).toBeInTheDocument();
		const badge = screen.getByTestId('status-badge');
		expect(badge.textContent).toContain('Degraded Performance');
	});

	it('renders major outage status', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'outage',
				statusLabel: statusLabelForServiceStatus('outage'),
				lastUpdated: '2026-02-21T15:00:00Z'
			}
		});

		expect(screen.getByText('Major Outage')).toBeInTheDocument();
		const badge = screen.getByTestId('status-badge');
		expect(badge.textContent).toContain('Major Outage');
	});

	it('links to the beta scope instead of an unimplemented incident-history page', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: statusLabelForServiceStatus('operational'),
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.queryByRole('link', { name: /incident history/i })).not.toBeInTheDocument();
		const betaScopeLink = screen.getByRole('link', { name: /beta scope/i });
		expect(betaScopeLink).toHaveAttribute('href', '/beta');
		expect(betaScopeLink).toHaveClass('text-flapjack-rose');
	});

	it('states incident communications ownership and support response target', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: statusLabelForServiceStatus('operational'),
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(
			screen.getByText(/Flapjack Cloud operations owns incident updates/i)
		).toBeInTheDocument();
		expect(screen.getByText(/48 business hours/i)).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /email support/i })).toHaveAttribute(
			'href',
			expect.stringContaining('mailto:support@flapjack.foo')
		);
	});

	it('renders Flapjack Cloud status copy without legacy product branding', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: statusLabelForServiceStatus('operational'),
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.getByRole('link', { name: 'Flapjack Cloud' })).toBeInTheDocument();
		expect(screen.getByText(/Flapjack Cloud services/)).toBeInTheDocument();
		expect(screen.queryByText(/Griddle services/)).not.toBeInTheDocument();
	});

	it('does not expose infrastructure details', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'outage',
				statusLabel: statusLabelForServiceStatus('outage'),
				lastUpdated: '2026-02-21T15:00:00Z'
			}
		});

		expect(screen.queryByText(/ec2/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/postgres/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/vm/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/deployment/i)).not.toBeInTheDocument();
	});

	it('keeps server fallback values on cloud host without runtime S3 fetch', async () => {
		const fallbackMessage = 'Fallback incident message.';
		setStatusPageLocation('https://cloud.flapjack.foo/status');
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'degraded',
				statusLabel: statusLabelForServiceStatus('degraded'),
				lastUpdated: '2026-05-04T12:00:00.000Z',
				message: fallbackMessage
			}
		});

		expect(fetchMock).not.toHaveBeenCalled();
		expect(screen.getByText('Degraded Performance')).toBeInTheDocument();
		expect(screen.getByTestId('status-last-updated').textContent).toContain('2026');
		expect(screen.getByText(fallbackMessage)).toBeInTheDocument();
	});
});

describe('Status page server load', () => {
	const savedEnv: Record<string, string | undefined> = {};

	beforeEach(() => {
		savedEnv.SERVICE_STATUS = process.env.SERVICE_STATUS;
		savedEnv.SERVICE_STATUS_UPDATED = process.env.SERVICE_STATUS_UPDATED;
		delete process.env.SERVICE_STATUS;
		delete process.env.SERVICE_STATUS_UPDATED;
	});

	afterEach(() => {
		process.env.SERVICE_STATUS = savedEnv.SERVICE_STATUS;
		process.env.SERVICE_STATUS_UPDATED = savedEnv.SERVICE_STATUS_UPDATED;
	});

	it('returns operational status when SERVICE_STATUS env var is not set', async () => {
		const { load } = await import('./+page.server');

		const result = load();

		expect(result.status).toBe('operational');
		expect(result.statusLabel).toBe(statusLabelForServiceStatus('operational'));
		expect(result.lastUpdated).toBeTruthy();
		expect(new Date(result.lastUpdated).toString()).not.toBe('Invalid Date');
	});

	it('maps SERVICE_STATUS=degraded to correct label', async () => {
		process.env.SERVICE_STATUS = 'degraded';
		process.env.SERVICE_STATUS_UPDATED = '2026-02-21T14:00:00Z';

		const { load } = await import('./+page.server');

		const result = load();

		expect(result.status).toBe('degraded');
		expect(result.statusLabel).toBe(statusLabelForServiceStatus('degraded'));
		expect(result.lastUpdated).toBe('2026-02-21T14:00:00Z');
	});

	it('collapses invalid SERVICE_STATUS values to operational fallback', async () => {
		process.env.SERVICE_STATUS = 'paused';
		process.env.SERVICE_STATUS_UPDATED = '2026-02-21T16:00:00Z';

		const { load } = await import('./+page.server');

		const result = load();

		expect(result.status).toBe('operational');
		expect(result.statusLabel).toBe(statusLabelForServiceStatus('operational'));
		expect(result.lastUpdated).toBe('2026-02-21T16:00:00Z');
	});
});
