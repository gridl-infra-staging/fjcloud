import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

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

type CustomerListItem = {
	id: string;
	name: string;
	email: string;
	status: string;
	created_at: string;
	index_count: number | null;
	last_invoice_status: string | null;
};

const ACTIVE_CUSTOMER_ID = 'aaaaaaaa-0001-0000-0000-000000000001';
const SUSPENDED_CUSTOMER_ID = 'aaaaaaaa-0002-0000-0000-000000000002';
const DELETED_CUSTOMER_ID = 'aaaaaaaa-0003-0000-0000-000000000003';

// Fixtures cover the three truthful states the loader can produce:
//   Acme  -> real invoice status ("paid"), index_count null (unavailable)
//   Beta  -> "none" invoice status (no invoices), index_count null
//   Gamma -> null invoice status (API error), index_count null
const CUSTOMER_FIXTURES: CustomerListItem[] = [
	{
		id: ACTIVE_CUSTOMER_ID,
		name: 'Acme Corp',
		email: 'ops@acme.dev',
		status: 'active',
		created_at: '2026-02-10T12:00:00Z',
		index_count: null,
		last_invoice_status: 'paid'
	},
	{
		id: SUSPENDED_CUSTOMER_ID,
		name: 'Beta Labs',
		email: 'billing@beta.dev',
		status: 'suspended',
		created_at: '2026-02-11T12:00:00Z',
		index_count: null,
		last_invoice_status: 'none'
	},
	{
		id: DELETED_CUSTOMER_ID,
		name: 'Gamma Inc',
		email: 'team@gamma.dev',
		status: 'deleted',
		created_at: '2026-02-12T12:00:00Z',
		index_count: null,
		last_invoice_status: null
	}
];

async function renderCustomersPage(customers: CustomerListItem[] | null = CUSTOMER_FIXTURES) {
	const CustomersPage = (await import('./+page.svelte')).default;

	render(CustomersPage, {
		data: { environment: 'test', isAuthenticated: true, customers }
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
	applyActionMock.mockReset();
	invalidateMock.mockReset();
	vi.clearAllMocks();
});

describe('Admin customers list', () => {
	it('renders customer table rows', async () => {
		await renderCustomersPage();

		expect(screen.getByRole('columnheader', { name: /name/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /email/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /status/i })).toBeInTheDocument();

		const rows = within(screen.getByTestId('customers-table-body')).getAllByRole('row');
		expect(rows).toHaveLength(3);
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

		// All three fixtures have index_count: null, so every row should show "—"
		const rows = within(screen.getByTestId('customers-table-body')).getAllByRole('row');
		for (const row of rows) {
			expect(within(row).getByTestId('index-count')).toHaveTextContent('—');
		}
	});

	it('renders "—" for null invoice status and "none" for the "none" sentinel', async () => {
		await renderCustomersPage();

		// Acme has last_invoice_status: 'paid' -> renders "paid"
		const acmeRow = customerRow(ACTIVE_CUSTOMER_ID);
		expect(within(acmeRow).getByTestId('invoice-status')).toHaveTextContent('paid');

		// Beta has last_invoice_status: 'none' -> renders "none"
		const betaRow = customerRow(SUSPENDED_CUSTOMER_ID);
		expect(within(betaRow).getByTestId('invoice-status')).toHaveTextContent('none');

		// Gamma has last_invoice_status: null -> renders "—" (unavailable)
		const gammaRow = customerRow(DELETED_CUSTOMER_ID);
		expect(within(gammaRow).getByTestId('invoice-status')).toHaveTextContent('—');
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
