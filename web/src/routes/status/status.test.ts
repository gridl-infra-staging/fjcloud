import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

afterEach(cleanup);

describe('Status page', () => {
	it('renders current status with "All Systems Operational" default', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: 'All Systems Operational',
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.getByRole('heading', { name: /service status/i })).toBeInTheDocument();
		expect(screen.getByText('All Systems Operational')).toBeInTheDocument();
	});

	it('shows last updated timestamp', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: 'All Systems Operational',
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
				statusLabel: 'Degraded Performance',
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
				statusLabel: 'Major Outage',
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
				statusLabel: 'All Systems Operational',
				lastUpdated: '2026-02-21T12:00:00Z'
			}
		});

		expect(screen.queryByRole('link', { name: /incident history/i })).not.toBeInTheDocument();
		const betaScopeLink = screen.getByRole('link', { name: /beta scope/i });
		expect(betaScopeLink).toHaveAttribute('href', '/beta');
	});

	it('states incident communications ownership and support response target', async () => {
		const StatusPage = (await import('./+page.svelte')).default;

		render(StatusPage, {
			data: {
				status: 'operational',
				statusLabel: 'All Systems Operational',
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
				statusLabel: 'All Systems Operational',
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
				statusLabel: 'Major Outage',
				lastUpdated: '2026-02-21T15:00:00Z'
			}
		});

		expect(screen.queryByText(/ec2/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/postgres/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/vm/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/deployment/i)).not.toBeInTheDocument();
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
		expect(result.statusLabel).toBe('All Systems Operational');
		expect(result.lastUpdated).toBeTruthy();
	});

	it('maps SERVICE_STATUS=degraded to correct label', async () => {
		process.env.SERVICE_STATUS = 'degraded';
		process.env.SERVICE_STATUS_UPDATED = '2026-02-21T14:00:00Z';

		const { load } = await import('./+page.server');

		const result = load();

		expect(result.status).toBe('degraded');
		expect(result.statusLabel).toBe('Degraded Performance');
		expect(result.lastUpdated).toBe('2026-02-21T14:00:00Z');
	});
});
