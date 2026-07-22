import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import AuditTimeline from './AuditTimeline.svelte';
import type { AdminAuditRow } from '$lib/admin-client';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

afterEach(() => {
	cleanup();
	vi.useRealTimers();
	vi.clearAllMocks();
});

describe('AuditTimeline', () => {
	it('renders actor ids and compact metadata while suppressing empty metadata', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-04-01T12:00:00Z'));

		const audit: AdminAuditRow[] = [
			{
				id: 'eeeeeeee-0001-0000-0000-000000000001',
				actor_id: '00000000-0000-0000-0000-000000000000',
				action: 'quotas_updated',
				target_tenant_id: 'aaaaaaaa-0002-0000-0000-000000000002',
				metadata: { duration_secs: 42 },
				created_at: '2026-04-01T11:30:00Z'
			},
			{
				id: 'eeeeeeee-0002-0000-0000-000000000002',
				actor_id: '11111111-1111-1111-1111-111111111111',
				action: 'customer_suspended',
				target_tenant_id: 'aaaaaaaa-0002-0000-0000-000000000002',
				metadata: {},
				created_at: '2026-04-01T11:45:00Z'
			}
		];

		render(AuditTimeline, { audit });

		const rows = screen.getAllByRole('listitem');
		expect(rows).toHaveLength(2);

		expect(within(rows[0]).getByText('Quotas updated')).toBeInTheDocument();
		expect(within(rows[0]).getByTestId('audit-actor')).toHaveTextContent(
			'00000000-0000-0000-0000-000000000000'
		);
		expect(within(rows[0]).getByTestId('audit-metadata')).toHaveTextContent('duration_secs: 42');
		expect(within(rows[0]).getByTestId('audit-relative-time')).toHaveTextContent('30m ago');
		expect(within(rows[1]).getByText('Customer suspended')).toBeInTheDocument();
		expect(within(rows[1]).getByTestId('audit-actor')).toHaveTextContent(
			'11111111-1111-1111-1111-111111111111'
		);
		expect(within(rows[1]).getByTestId('audit-relative-time')).toHaveTextContent('15m ago');
		expect(within(rows[1]).queryByTestId('audit-metadata')).not.toBeInTheDocument();
	});
});
