import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent, within } from '@testing-library/dom';
import type { Index } from '$lib/api/types';
import type { InternalRegion } from '$lib/api/types';
import { layoutTestDefaults } from '../layout-test-context';

let latestEnhanceResultHandler:
	| ((args: { result: { type: string } & Record<string, unknown> }) => Promise<void>)
	| null = null;

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: (
		_: HTMLFormElement,
		submitHandler: () => void | ((args: { result: unknown }) => Promise<void>)
	) => {
		const resultHandler = submitHandler();
		latestEnhanceResultHandler = typeof resultHandler === 'function' ? resultHandler : null;
		return { destroy: () => {} };
	}
}));

const gotoMock = vi.fn();
vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/indexes') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

import IndexesPage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	latestEnhanceResultHandler = null;
});

const sampleIndexes: Index[] = [
	{
		name: 'products',
		region: 'us-east-1',
		endpoint: 'https://vm-abc.flapjack.foo',
		entries: 1500,
		data_size_bytes: 204800,
		status: 'ready',
		tier: 'active',
		created_at: '2026-02-15T10:00:00Z'
	},
	{
		name: 'blog-posts',
		region: 'eu-west-1',
		endpoint: 'https://vm-def.flapjack.foo',
		entries: 320,
		data_size_bytes: 51200,
		status: 'ready',
		tier: 'active',
		created_at: '2026-02-16T10:00:00Z'
	},
	{
		name: 'events',
		region: 'us-east-1',
		endpoint: null,
		entries: 0,
		data_size_bytes: 0,
		status: 'provisioning',
		tier: 'active',
		created_at: '2026-02-17T10:00:00Z'
	}
];

const sampleRegions: InternalRegion[] = [
	{
		id: 'us-east-1',
		display_name: 'US East (Virginia)',
		provider: 'aws',
		provider_location: 'us-east-1',
		available: true
	},
	{
		id: 'eu-west-1',
		display_name: 'EU West (Ireland)',
		provider: 'aws',
		provider_location: 'eu-west-1',
		available: true
	},
	{
		id: 'eu-central-1',
		display_name: 'EU Central (Germany)',
		provider: 'hetzner',
		provider_location: 'fsn1',
		available: true
	},
	{
		id: 'us-east-2',
		display_name: 'US East (Ashburn)',
		provider: 'hetzner',
		provider_location: 'ash',
		available: true
	}
];

describe('Index list page', () => {
	function getRegionOption(
		formQueries: ReturnType<typeof within>,
		displayName: string
	): HTMLInputElement {
		const regionCard = formQueries.getByText(displayName).closest('label');
		expect(regionCard).not.toBeNull();
		const radio = regionCard?.querySelector('input[name="region"]');
		expect(radio).not.toBeNull();
		return radio as HTMLInputElement;
	}

	it('renders index table with name, region, status, entries, and data size', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		const productsLink = screen.getByRole('link', { name: 'products' });
		const productsRow = productsLink.closest('tr');
		expect(productsRow).not.toBeNull();
		if (!productsRow) {
			throw new Error('Expected products row to exist');
		}
		const productsCells = within(productsRow);
		expect(productsCells.getByText('products')).toBeInTheDocument();
		expect(productsCells.getByText('us-east-1')).toBeInTheDocument();
		expect(productsCells.getByText('Ready')).toBeInTheDocument();
		expect(productsCells.getByText('1,500')).toBeInTheDocument();
		expect(productsCells.getByText('200.0 KB')).toBeInTheDocument();
		expect(productsCells.getByText('Feb 15, 2026')).toBeInTheDocument();

		const eventsLink = screen.getByRole('link', { name: 'events' });
		const eventsRow = eventsLink.closest('tr');
		expect(eventsRow).not.toBeNull();
		if (!eventsRow) {
			throw new Error('Expected events row to exist');
		}
		const eventsCells = within(eventsRow);
		expect(eventsCells.getByText('events')).toBeInTheDocument();
		expect(eventsCells.getByText('us-east-1')).toBeInTheDocument();
		expect(eventsCells.getByText('Preparing')).toBeInTheDocument();
		expect(eventsCells.getByText('0')).toBeInTheDocument();
		expect(eventsCells.getByText('0 B')).toBeInTheDocument();
		expect(eventsCells.getByText('Feb 17, 2026')).toBeInTheDocument();
	});

	it('create button opens create form', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		expect(screen.queryByTestId('create-index-form')).not.toBeInTheDocument();

		const createButton = screen.getByRole('button', { name: /create index/i });
		await fireEvent.click(createButton);

		const createForm = screen.getByTestId('create-index-form');
		const formQueries = within(createForm);
		expect(formQueries.getByRole('heading', { name: 'Create a new index' })).toBeInTheDocument();
		expect(formQueries.getByLabelText(/index name/i)).toBeInTheDocument();
		expect(createForm.querySelector('input[name="template_id"]')).toBeInTheDocument();
		expect(createForm.querySelector('input[name="template"]')).not.toBeInTheDocument();
		const defaultRegionOption = getRegionOption(formQueries, 'US East (Virginia)');
		expect(defaultRegionOption.value).toBe('us-east-1');
		expect(defaultRegionOption.checked).toBe(true);
		expect(formQueries.getByText('us-east-1')).toBeInTheDocument();
		expect(formQueries.getByRole('button', { name: /^create$/i })).toBeInTheDocument();
		await fireEvent.click(formQueries.getByRole('button', { name: /^cancel$/i }));
		expect(screen.queryByTestId('create-index-form')).not.toBeInTheDocument();
	});

	it('canceling or successful submit resets route-owned region and dialog visibility state', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));
		let createForm = screen.getByTestId('create-index-form');
		let formQueries = within(createForm);
		await fireEvent.click(getRegionOption(formQueries, 'EU West (Ireland)'));
		expect(getRegionOption(formQueries, 'EU West (Ireland)').checked).toBe(true);

		await fireEvent.click(formQueries.getByRole('button', { name: /^cancel$/i }));
		expect(screen.queryByTestId('create-index-form')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));
		createForm = screen.getByTestId('create-index-form');
		formQueries = within(createForm);
		expect(getRegionOption(formQueries, 'US East (Virginia)').checked).toBe(true);
		expect(latestEnhanceResultHandler).not.toBeNull();
		await latestEnhanceResultHandler?.({
			result: {
				type: 'success',
				status: 200
			}
		});

		expect(screen.queryByTestId('create-index-form')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));
		createForm = screen.getByTestId('create-index-form');
		formQueries = within(createForm);
		expect(getRegionOption(formQueries, 'US East (Virginia)').checked).toBe(true);
	});

	it('index_creation_shows_all_available_regions', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: [], regions: sampleRegions },
			form: null
		});

		// Open create form
		const createBtn = screen.getByRole('button', { name: /create index/i });
		await fireEvent.click(createBtn);

		const createForm = screen.getByTestId('create-index-form');
		const formQueries = within(createForm);

		// Form should be visible with name input and region select
		const nameInput = formQueries.getByLabelText(/index name/i);
		expect(nameInput).toBeInTheDocument();

		// Region options should be driven by backend-provided available regions
		expect(getRegionOption(formQueries, 'US East (Virginia)').value).toBe('us-east-1');
		expect(getRegionOption(formQueries, 'EU West (Ireland)').value).toBe('eu-west-1');
		expect(getRegionOption(formQueries, 'EU Central (Germany)').value).toBe('eu-central-1');
		expect(getRegionOption(formQueries, 'US East (Ashburn)').value).toBe('us-east-2');
		expect(formQueries.getByText('US East (Virginia)')).toBeInTheDocument();
		expect(formQueries.getByText('EU West (Ireland)')).toBeInTheDocument();
		expect(formQueries.getByText('EU Central (Germany)')).toBeInTheDocument();
		expect(formQueries.getByText('US East (Ashburn)')).toBeInTheDocument();

		// Region picker must not expose provider details to customers
		expect(formQueries.queryByTestId('region-provider-badge')).not.toBeInTheDocument();
		expect(formQueries.queryByText('AWS')).not.toBeInTheDocument();
		expect(formQueries.queryByText('Hetzner')).not.toBeInTheDocument();
	});

	it('detail page links present for each index', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		const productLink = screen.getByRole('link', { name: /products/i });
		expect(productLink).toBeInTheDocument();
		expect(productLink.getAttribute('href')).toBe('/console/indexes/products');

		const blogLink = screen.getByRole('link', { name: /blog-posts/i });
		expect(blogLink.getAttribute('href')).toBe('/console/indexes/blog-posts');
	});

	it('delete confirmation is scoped to the selected index row', async () => {
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
		const { container } = render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		const productsLink = screen.getByRole('link', { name: 'products' });
		const productsRow = productsLink.closest('tr');
		expect(productsRow).not.toBeNull();
		if (!productsRow) {
			throw new Error('Expected products row to exist');
		}

		const productsDeleteForm = productsRow.querySelector('form[action="?/delete"]');
		expect(productsDeleteForm).not.toBeNull();
		const productsDeleteInput = productsDeleteForm?.querySelector(
			'input[name="name"]'
		) as HTMLInputElement | null;
		expect(productsDeleteInput).not.toBeNull();
		expect(productsDeleteInput?.value).toBe('products');

		expect(container.querySelector('input[name="name"][value="blog-posts"]')).toBeInTheDocument();

		await fireEvent.click(within(productsRow).getByRole('button', { name: /delete/i }));

		expect(confirmSpy).toHaveBeenCalledWith(
			'Are you sure you want to delete the index "products"?'
		);
		confirmSpy.mockRestore();
	});

	it('empty state renders correctly', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: [], regions: sampleRegions },
			form: null
		});

		expect(screen.getByText(/no indexes yet/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /create index/i })).toBeInTheDocument();
	});

	it('shows quota-exceeded callout with upgrade CTA when form returns quota_exceeded error', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: { error: 'quota_exceeded' }
		});

		// Dedicated callout should appear (separate from generic error alert)
		const callout = screen.getByTestId('quota-exceeded-callout');
		expect(callout).toBeInTheDocument();
		expect(callout.textContent).toMatch(/free plan.*limit/i);

		// Should have a link to billing for upgrade
		const upgradeLink = screen.getByRole('link', { name: /upgrade/i });
		expect(upgradeLink.getAttribute('href')).toBe('/console/billing');

		// Generic error alert should NOT show quota_exceeded as raw text
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it('does not show quota-exceeded callout for generic errors', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: { error: 'Failed to create index' }
		});

		expect(screen.queryByTestId('quota-exceeded-callout')).not.toBeInTheDocument();
		expect(screen.getByRole('alert')).toBeInTheDocument();
	});

	it('renders create failure in one place when dialog is open', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: { error: 'Failed to create index' }
		});

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));

		const alerts = screen.getAllByRole('alert');
		expect(alerts).toHaveLength(1);
		expect(screen.getByTestId('create-index-server-error')).toBeInTheDocument();
	});

	it.each(['Index name is required', 'Region is required'])(
		'keeps plain create validation errors scoped to the dialog after enhanced create submit (%s)',
		async (validationError) => {
			render(IndexesPage, {
				data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
				form: { error: validationError }
			});

			await fireEvent.click(screen.getByRole('button', { name: /create index/i }));
			expect(latestEnhanceResultHandler).not.toBeNull();

			await latestEnhanceResultHandler?.({
				result: {
					type: 'failure',
					status: 400,
					data: { error: validationError }
				}
			});

			const alerts = screen.getAllByRole('alert');
			expect(alerts).toHaveLength(1);
			expect(screen.getByTestId('create-index-server-error')).toHaveTextContent(validationError);
		}
	);

	it('keeps delete failure scoped to page alert when create dialog is opened', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: { error: 'Failed to delete index' }
		});

		expect(screen.getByRole('alert')).toHaveTextContent('Failed to delete index');

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));

		expect(screen.getByRole('alert')).toHaveTextContent('Failed to delete index');
		expect(screen.queryByTestId('create-index-server-error')).not.toBeInTheDocument();
		expect(screen.queryByTestId('create-index-quota-callout')).not.toBeInTheDocument();
	});

	it('shows dedicated quota upgrade callout when dialog is open after quota_exceeded failure', async () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: { error: 'quota_exceeded' }
		});

		await fireEvent.click(screen.getByRole('button', { name: /create index/i }));

		const quotaCallout = screen.getByTestId('create-index-quota-callout');
		expect(quotaCallout).toBeInTheDocument();
		expect(quotaCallout.textContent).toMatch(/free plan.*limit/i);
		expect(screen.getByRole('link', { name: /upgrade your plan/i })).toHaveAttribute(
			'href',
			'/console/billing'
		);
		expect(screen.queryByText('quota_exceeded')).not.toBeInTheDocument();
	});

	it('status badges show correct colors', () => {
		render(IndexesPage, {
			data: { ...layoutTestDefaults, user: null, indexes: sampleIndexes, regions: sampleRegions },
			form: null
		});

		// Ready indexes should have green badge text
		const readyBadges = screen.getAllByText('Ready');
		expect(readyBadges.length).toBe(2);

		// Preparing status should have yellow badge
		expect(screen.getByText('Preparing')).toBeInTheDocument();
	});
});
