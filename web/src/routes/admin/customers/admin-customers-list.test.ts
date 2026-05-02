import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { AdminCustomerListItem } from './+page.server';
import { load } from './+page.server';
import { adminBadgeColor } from '$lib/format';

const applyActionMock = vi.fn();
const invalidateMock = vi.fn();
const enhanceCalls: Array<{
	action: string | null;
	submit: ((input?: unknown) => unknown) | undefined;
}> = [];

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	enhance: (form: HTMLFormElement, submit?: (input?: unknown) => unknown) => {
		enhanceCalls.push({
			action: form.getAttribute('action'),
			submit
		});
		return { destroy: () => {} };
	}
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/customers') }
}));

vi.mock('$app/navigation', () => ({
	invalidate: invalidateMock
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

const ACTIVE_CUSTOMER_ID = 'aaaaaaaa-0001-0000-0000-000000000001';
const SUSPENDED_CUSTOMER_ID = 'aaaaaaaa-0002-0000-0000-000000000002';
const DELETED_CUSTOMER_ID = 'aaaaaaaa-0003-0000-0000-000000000003';
const YELLOW_OVERDUE_ID = 'aaaaaaaa-0004-0000-0000-000000000004';
const GREY_NO_SUB_ID = 'aaaaaaaa-0005-0000-0000-000000000005';
const YELLOW_INCOMPLETE_ID = 'aaaaaaaa-0006-0000-0000-000000000006';
const LEGACY_SUBSCRIPTION_FIELD = 'subscription' + '_status';

// Fixtures cover every rendered billing-health state, plus both distinct yellow paths.
const CUSTOMER_FIXTURES: AdminCustomerListItem[] = [
	{
		id: ACTIVE_CUSTOMER_ID,
		name: 'Acme Corp',
		email: 'ops@acme.dev',
		status: 'active',
		billing_plan: 'shared',
		last_accessed_at: '2026-04-20T12:00:00Z',
		overdue_invoice_count: 0,
		billing_health: 'green',
		created_at: '2026-04-25T12:00:00Z',
		updated_at: '2026-04-20T12:00:00Z',
		index_count: null
	},
	{
		id: YELLOW_INCOMPLETE_ID,
		name: 'Beta Labs',
		email: 'billing@beta.dev',
		status: 'active',
		billing_plan: 'shared',
		last_accessed_at: '2026-04-27T10:00:00Z',
		overdue_invoice_count: 0,
		billing_health: 'yellow',
		created_at: '2026-04-24T18:00:00Z',
		updated_at: '2026-04-27T10:00:00Z',
		index_count: null
	},
	{
		id: GREY_NO_SUB_ID,
		name: 'Epsilon Works',
		email: 'team@epsilon.dev',
		status: 'active',
		billing_plan: 'free',
		last_accessed_at: '2026-04-24T12:00:00Z',
		overdue_invoice_count: 0,
		billing_health: 'grey',
		created_at: '2026-04-24T12:00:00Z',
		updated_at: '2026-04-24T12:00:00Z',
		index_count: null
	},
	{
		id: DELETED_CUSTOMER_ID,
		name: 'Gamma Inc',
		email: 'team@gamma.dev',
		status: 'deleted',
		billing_plan: 'free',
		last_accessed_at: null,
		overdue_invoice_count: 3,
		billing_health: 'grey',
		created_at: '2026-04-23T12:00:00Z',
		updated_at: '2026-04-10T08:00:00Z',
		index_count: null
	},
	{
		id: YELLOW_OVERDUE_ID,
		name: 'Delta Systems',
		email: 'finance@delta.dev',
		status: 'active',
		billing_plan: 'shared',
		last_accessed_at: '2026-04-27T11:56:00Z',
		overdue_invoice_count: 2,
		billing_health: 'yellow',
		created_at: '2026-04-22T12:00:00Z',
		updated_at: '2026-04-27T11:56:00Z',
		index_count: null
	},
	{
		id: SUSPENDED_CUSTOMER_ID,
		name: 'Zeta Holdings',
		email: 'ops@zeta.dev',
		status: 'suspended',
		billing_plan: 'free',
		last_accessed_at: '2026-04-18T09:00:00Z',
		overdue_invoice_count: 0,
		billing_health: 'red',
		created_at: '2026-04-21T12:00:00Z',
		updated_at: '2026-04-18T09:00:00Z',
		index_count: null
	}
];

async function renderCustomersPage(
	customers: AdminCustomerListItem[] | null = CUSTOMER_FIXTURES
) {
	const CustomersPage = (await import('./+page.svelte')).default;

	render(CustomersPage, {
		data: {
			environment: 'test',
			isAuthenticated: true,
			customers
		}
	});
}

function customerRow(customerId: string) {
	return screen.getByTestId(`customer-row-${customerId}`);
}

async function getEnhanceResultHandler(actionName: 'suspend' | 'impersonate') {
	const enhanceCall = enhanceCalls.find((call) => call.action?.includes(`?/${actionName}`));
	expect(enhanceCall?.submit).toBeTypeOf('function');

	const handleResult = await enhanceCall?.submit?.({});
	expect(handleResult).toBeTypeOf('function');

	return handleResult as (result: { result: { type: string } }) => Promise<void>;
}

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
	enhanceCalls.length = 0;
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.useRealTimers();
	applyActionMock.mockReset();
	invalidateMock.mockReset();
	vi.clearAllMocks();
});

describe('Admin customers list', () => {
it('load omits legacy subscription field from list rows', async () => {
		const result = (await load({
			fetch: async () =>
				new Response(
					JSON.stringify([
						{
							id: ACTIVE_CUSTOMER_ID,
							name: 'Acme Corp',
							email: 'ops@acme.dev',
							status: 'active',
							billing_plan: 'shared',
							last_accessed_at: '2026-04-20T12:00:00Z',
							[LEGACY_SUBSCRIPTION_FIELD]: 'active',
							overdue_invoice_count: 0,
							billing_health: 'green',
							created_at: '2026-04-25T12:00:00Z',
							updated_at: '2026-04-20T12:00:00Z'
						}
					]),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				),
			depends: vi.fn()
		} as never)) as { customers: AdminCustomerListItem[] | null };

		expect(result.customers).not.toBeNull();
		expect(result.customers?.[0]).not.toHaveProperty(LEGACY_SUBSCRIPTION_FIELD);
		expect(result.customers?.[0]).toMatchObject({
			id: ACTIVE_CUSTOMER_ID,
			index_count: null,
			billing_health: 'green'
		});
	});

	// Stage 4 contract owner: verify customer-table columns and structure.
	it('renders customer table rows', async () => {
		await renderCustomersPage();

		expect(screen.getByRole('columnheader', { name: /name/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /email/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /status/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /last activity/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /billing health/i })).toBeInTheDocument();
		expect(screen.queryByRole('columnheader', { name: /last invoice/i })).not.toBeInTheDocument();

		const rows = within(screen.getByTestId('customers-table-body')).getAllByRole('row');
		expect(rows).toHaveLength(6);
		expect(screen.getByText('Acme Corp')).toBeInTheDocument();
		expect(screen.getByText('Beta Labs')).toBeInTheDocument();
	});

	it('filters customers by search query', async () => {
		await renderCustomersPage();

		await fireEvent.input(screen.getByTestId('customer-search'), {
			target: { value: 'beta' }
		});

		const rows = within(screen.getByTestId('customers-table-body')).getAllByRole('row');
		expect(rows).toHaveLength(1);
		expect(screen.getByText('Beta Labs')).toBeInTheDocument();
	});

	it('renders an unavailable state when the loader cannot fetch customers', async () => {
		await renderCustomersPage(null);

		expect(screen.getByText('Customer data unavailable.')).toBeInTheDocument();
		expect(screen.queryByTestId('customers-table-body')).not.toBeInTheDocument();
	});

	it('renders "—" in Indexes column when index_count is null', async () => {
		await renderCustomersPage();

		// All fixtures have index_count: null, so every row should show "—"
		const rows = within(screen.getByTestId('customers-table-body')).getAllByRole('row');
		for (const row of rows) {
			expect(within(row).getByTestId('index-count')).toHaveTextContent('—');
		}
	});

	// Stage 4 contract owner: verify last-activity rendering semantics.
	it('renders relative last-activity values and em dash for missing activity', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-04-27T12:00:00Z'));

		await renderCustomersPage();

		expect(screen.getByTestId(`last-activity-cell-${ACTIVE_CUSTOMER_ID}`)).toHaveTextContent(
			'7 days ago'
		);
		expect(screen.getByTestId(`last-activity-cell-${YELLOW_INCOMPLETE_ID}`)).toHaveTextContent(
			'2h ago'
		);
		expect(screen.getByTestId(`last-activity-cell-${YELLOW_OVERDUE_ID}`)).toHaveTextContent(
			'4m ago'
		);
		expect(screen.getByTestId(`last-activity-cell-${DELETED_CUSTOMER_ID}`)).toHaveTextContent(
			'—'
		);
	});

	// Stage 4 contract owner: verify billing-health badge rendering semantics.
	it('renders billing-health badges with the expected label and color class', async () => {
		await renderCustomersPage();

		for (const customer of CUSTOMER_FIXTURES) {
			const badge = screen.getByTestId(`billing-health-badge-${customer.id}`);
			expect(badge).toHaveTextContent(
				customer.billing_health.charAt(0).toUpperCase() + customer.billing_health.slice(1)
			);
			expect(badge.className).toContain(adminBadgeColor(customer.billing_health));
		}
	});

	// Stage 4 contract owner: verify billing-health sort and tie-break behavior.
	it('sorts billing health red to yellow to grey to green with created_at tie-breaks', async () => {
		await renderCustomersPage();
		const sortToggle = screen.getByTestId('sort-billing-health');
		expect(sortToggle).toHaveTextContent(/default/i);

		const initialRows = within(screen.getByTestId('customers-table-body'))
			.getAllByRole('row')
			.map((row) => row.getAttribute('data-testid'));
		expect(initialRows).toEqual([
			`customer-row-${ACTIVE_CUSTOMER_ID}`,
			`customer-row-${YELLOW_INCOMPLETE_ID}`,
			`customer-row-${GREY_NO_SUB_ID}`,
			`customer-row-${DELETED_CUSTOMER_ID}`,
			`customer-row-${YELLOW_OVERDUE_ID}`,
			`customer-row-${SUSPENDED_CUSTOMER_ID}`
		]);

		await fireEvent.click(sortToggle);
		expect(sortToggle).toHaveTextContent(/sorted/i);

		const sortedRows = within(screen.getByTestId('customers-table-body'))
			.getAllByRole('row')
			.map((row) => row.getAttribute('data-testid'));
		expect(sortedRows).toEqual([
			`customer-row-${SUSPENDED_CUSTOMER_ID}`,
			`customer-row-${YELLOW_INCOMPLETE_ID}`,
			`customer-row-${YELLOW_OVERDUE_ID}`,
			`customer-row-${GREY_NO_SUB_ID}`,
			`customer-row-${DELETED_CUSTOMER_ID}`,
			`customer-row-${ACTIVE_CUSTOMER_ID}`
		]);

		await fireEvent.click(sortToggle);
		expect(sortToggle).toHaveTextContent(/default/i);

		const resetRows = within(screen.getByTestId('customers-table-body'))
			.getAllByRole('row')
			.map((row) => row.getAttribute('data-testid'));
		expect(resetRows).toEqual(initialRows);
	});
});

describe('Admin customers list quick actions', () => {
	it('renders an Actions column header', async () => {
		await renderCustomersPage();

		expect(screen.getByRole('columnheader', { name: /actions/i })).toBeInTheDocument();
	});

	it('active customer row shows suspend and impersonate quick actions', async () => {
		await renderCustomersPage();

		const row = customerRow(ACTIVE_CUSTOMER_ID);
		const suspendBtn = within(row).getByTestId('quick-suspend');
		const impersonateBtn = within(row).getByTestId('quick-impersonate');
		expect(suspendBtn).toBeInTheDocument();
		expect(impersonateBtn).toBeInTheDocument();

		// Verify forms post to the detail route action surface
		const suspendForm = suspendBtn.closest('form');
		expect(suspendForm?.getAttribute('action')).toContain(
			'/admin/customers/aaaaaaaa-0001-0000-0000-000000000001?/suspend'
		);

		const impersonateForm = impersonateBtn.closest('form');
		expect(impersonateForm?.getAttribute('action')).toContain(
			'/admin/customers/aaaaaaaa-0001-0000-0000-000000000001?/impersonate'
		);
	});

	it('quick suspend invalidates the customer list after a successful action result', async () => {
		await renderCustomersPage();
		const handleResult = await getEnhanceResultHandler('suspend');

		await handleResult({
			result: { type: 'success' }
		});

		expect(invalidateMock).toHaveBeenCalledWith('admin:customers:list');
		expect(applyActionMock).not.toHaveBeenCalled();
	});

	it('quick impersonate applies redirect results instead of swallowing them', async () => {
		await renderCustomersPage();
		const handleResult = await getEnhanceResultHandler('impersonate');

		const redirectResult = { type: 'redirect', status: 303, location: '/dashboard' };
		await handleResult({
			result: redirectResult
		});

		expect(applyActionMock).toHaveBeenCalledWith(redirectResult);
		expect(invalidateMock).not.toHaveBeenCalled();
	});

	it('suspended customer row shows impersonate but not suspend', async () => {
		await renderCustomersPage();

		const row = customerRow(SUSPENDED_CUSTOMER_ID);
		expect(within(row).getByTestId('quick-impersonate')).toBeInTheDocument();
		expect(within(row).queryByTestId('quick-suspend')).not.toBeInTheDocument();
	});

	it('deleted customer row shows no quick actions', async () => {
		await renderCustomersPage();

		const row = customerRow(DELETED_CUSTOMER_ID);
		expect(within(row).queryByTestId('quick-suspend')).not.toBeInTheDocument();
		expect(within(row).queryByTestId('quick-impersonate')).not.toBeInTheDocument();
	});
});
