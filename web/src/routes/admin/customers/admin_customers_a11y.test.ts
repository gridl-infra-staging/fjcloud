import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { getAccessibilityViolations } from '../../../tests/a11y';
import type { AdminCustomerListItem } from './+page.server';
import CustomersPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

const customers: AdminCustomerListItem[] = [
	{
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		name: 'Acme Corp',
		email: 'ops@acme.dev',
		status: 'active',
		billing_plan: 'shared',
		index_count: 3,
		last_accessed_at: '2026-04-20T12:00:00Z',
		overdue_invoice_count: 0,
		billing_health: 'green',
		created_at: '2026-04-25T12:00:00Z',
		updated_at: '2026-04-20T12:00:00Z'
	},
	{
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		name: 'Beta Labs',
		email: 'billing@beta.dev',
		status: 'suspended',
		billing_plan: 'shared',
		index_count: 2,
		last_accessed_at: null,
		overdue_invoice_count: 2,
		billing_health: 'red',
		created_at: '2026-04-21T12:00:00Z',
		updated_at: '2026-04-22T12:00:00Z'
	}
];

describe('Admin customers list accessibility', () => {
	it('has no structural accessibility violations for populated, filtered, empty, and unavailable states', async () => {
		const { container } = render(CustomersPage, {
			data: { environment: 'test', isAuthenticated: true, customers }
		});
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		await fireEvent.input(document.querySelector('[data-testid="customer-search"]')!, {
			target: { value: 'missing' }
		});
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		cleanup();
		const { container: emptyContainer } = render(CustomersPage, {
			data: { environment: 'test', isAuthenticated: true, customers: [] }
		});
		await expect(getAccessibilityViolations(emptyContainer)).resolves.toEqual([]);

		cleanup();
		const { container: unavailableContainer } = render(CustomersPage, {
			data: { environment: 'test', isAuthenticated: true, customers: null }
		});
		await expect(getAccessibilityViolations(unavailableContainer)).resolves.toEqual([]);
	});
});
