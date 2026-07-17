import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/svelte';
import { fireEvent, within } from '@testing-library/dom';
import type { ApiKeyListItem, Index } from '$lib/api/types';
import {
	DEFAULT_MANAGEMENT_SCOPE,
	SAFE_READ_MANAGEMENT_SCOPE,
	formatDate,
	scopeLabel
} from '$lib/format';
import { layoutTestDefaults } from '../layout-test-context';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

const { applyActionMock, deserializeMock, enhanceSubmitFunctions, gotoMock, invalidateAllMock } =
	vi.hoisted(() => ({
		applyActionMock: vi.fn(),
		deserializeMock: vi.fn(),
		enhanceSubmitFunctions: [] as Array<(input?: unknown) => unknown>,
		gotoMock: vi.fn(),
		invalidateAllMock: vi.fn()
	}));
const toastSuccessMock = vi.hoisted(() => vi.fn());

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	deserialize: deserializeMock,
	enhance: (_form: HTMLFormElement, submitFunction?: () => unknown) => {
		if (submitFunction) {
			enhanceSubmitFunctions.push(submitFunction);
		}
		return { destroy: () => {} };
	}
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock,
	invalidateAll: invalidateAllMock
}));

vi.mock('$lib/toast', () => ({
	TOAST_DURATION_MS,
	toast: {
		success: (...args: unknown[]) => toastSuccessMock(...args)
	}
}));

import ApiKeysPage from './+page.svelte';

const sampleKeys: ApiKeyListItem[] = [
	{
		id: 'key-1',
		name: 'Production Key',
		description: 'production read-write key',
		key_prefix: 'fjc_live_abc1234',
		scopes: ['indexes:read', 'indexes:write'],
		indexes: ['products'],
		restrict_sources: ['10.0.0.0/24'],
		expires_at: '2026-08-15T00:00:00Z',
		max_hits_per_query: 250,
		max_queries_per_ip_per_hour: 5000,
		last_used_at: '2026-02-20T10:00:00Z',
		created_at: '2026-01-15T08:00:00Z'
	},
	{
		id: 'key-2',
		name: 'Search-Only Key',
		description: null,
		key_prefix: 'gridl_live_def34',
		scopes: ['search'],
		indexes: [],
		restrict_sources: [],
		expires_at: null,
		max_hits_per_query: null,
		max_queries_per_ip_per_hour: null,
		last_used_at: null,
		created_at: '2026-02-10T12:00:00Z'
	}
];

const sampleIndexOptions: Index[] = [
	{
		name: 'products',
		region: 'us-east-1',
		endpoint: null,
		entries: 5000,
		data_size_bytes: 32000,
		status: 'ready',
		tier: 'hot',
		created_at: '2026-03-14T12:00:00Z'
	},
	{
		name: 'orders',
		region: 'us-east-1',
		endpoint: null,
		entries: 2000,
		data_size_bytes: 15000,
		status: 'ready',
		tier: 'hot',
		created_at: '2026-03-14T12:00:00Z'
	}
];

function renderPage(
	dataOverrides: Partial<{
		apiKeys: ApiKeyListItem[];
		indexOptions: Index[];
		loadError: string;
		selectedIndexFilter: string;
	}> = {},
	form: Record<string, unknown> | null = null
) {
	return render(ApiKeysPage, {
		data: {
			...layoutTestDefaults,
			user: null,
			apiKeys: sampleKeys,
			indexOptions: sampleIndexOptions,
			selectedIndexFilter: '',
			...dataOverrides
		} as never,
		form: form as never
	});
}

function getRowForKeyName(name: string): HTMLTableRowElement {
	const row = screen.getByText(name).closest('tr');
	expect(row).not.toBeNull();
	return row as HTMLTableRowElement;
}

async function openCreateDialog(): Promise<void> {
	await fireEvent.click(screen.getByRole('button', { name: 'Create API Key' }));
	expect(screen.getByRole('dialog')).toBeInTheDocument();
}

function setMultiselectValues(select: HTMLSelectElement, values: string[]): void {
	for (const option of Array.from(select.options)) {
		option.selected = values.includes(option.value);
	}
}

describe('API Keys page', () => {
	beforeEach(() => {
		applyActionMock.mockReset();
		applyActionMock.mockResolvedValue(undefined);
		deserializeMock.mockReset();
		gotoMock.mockReset();
		invalidateAllMock.mockReset();
		invalidateAllMock.mockResolvedValue(undefined);
		enhanceSubmitFunctions.length = 0;
		vi.unstubAllGlobals();
		window.history.replaceState({}, '', '/console/api-keys');
	});

	afterEach(() => {
		cleanup();
		vi.clearAllMocks();
		enhanceSubmitFunctions.length = 0;
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('renders seeded rows with lifecycle fields, scope labels, and row actions', () => {
		renderPage();

		expect(screen.getByRole('button', { name: 'Create API Key' })).toBeInTheDocument();
		expect(screen.getByLabelText('Index filter')).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Prefix' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Indexes' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Restrictions' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Expires' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Limits' })).toBeInTheDocument();

		const productionRow = getRowForKeyName('Production Key');
		expect(within(productionRow).getByText('fjc_live_abc1234...')).toBeInTheDocument();
		expect(within(productionRow).getByText(scopeLabel('indexes:read'))).toBeInTheDocument();
		expect(within(productionRow).getByText(scopeLabel('indexes:write'))).toBeInTheDocument();
		expect(within(productionRow).getByText('products')).toBeInTheDocument();
		expect(within(productionRow).getByText('10.0.0.0/24')).toBeInTheDocument();
		expect(
			within(productionRow).getByText(formatDate(sampleKeys[0].expires_at))
		).toBeInTheDocument();
		expect(within(productionRow).getByText('250 hits/query')).toBeInTheDocument();
		expect(within(productionRow).getByText('5000 queries/IP/hr')).toBeInTheDocument();
		expect(
			within(productionRow).getByText(formatDate(sampleKeys[0].last_used_at))
		).toBeInTheDocument();
		expect(
			within(productionRow).getByRole('button', { name: 'Copy key for Production Key' })
		).toBeInTheDocument();
		expect(
			within(productionRow).getByRole('button', { name: 'Revoke key Production Key' })
		).toBeInTheDocument();

		const searchOnlyRow = getRowForKeyName('Search-Only Key');
		expect(within(searchOnlyRow).getByText(scopeLabel('search'))).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('All indexes')).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('No restrictions')).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('Never')).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('No expiry')).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('No caps')).toBeInTheDocument();
	});

	it('shows empty state when no API keys', () => {
		renderPage({ apiKeys: [] });

		expect(screen.getByText(/no api keys/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Create API Key' })).toBeInTheDocument();
		expect(screen.queryByRole('table')).not.toBeInTheDocument();
	});

	it('shows the load error banner without claiming the account has no keys', () => {
		renderPage({ apiKeys: [], loadError: 'Backend temporarily unavailable' });

		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Backend temporarily unavailable');
		expect(screen.queryByText(/no api keys/i)).not.toBeInTheDocument();
		expect(screen.queryByRole('table')).not.toBeInTheDocument();
	});

	it('opens the create dialog with all managed-key parity inputs', async () => {
		renderPage({ apiKeys: [], indexOptions: sampleIndexOptions });

		await openCreateDialog();

		expect(screen.getByLabelText('Name')).toBeInTheDocument();
		expect(screen.getByLabelText('Description')).toBeInTheDocument();
		expect(screen.getByLabelText('Indexes')).toBeInTheDocument();
		expect(screen.getByLabelText('ACL')).toBeInTheDocument();
		expect(screen.getByLabelText('Expires at')).toBeInTheDocument();
		expect(screen.getByLabelText('Max hits per query')).toBeInTheDocument();
		expect(screen.getByLabelText('Max queries per IP per hour')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Add source' })).toBeInTheDocument();
	});

	it('submits create requests through the route action with backend field names', async () => {
		const fetchMock = vi.fn().mockResolvedValue(new Response('serialized-result', { status: 200 }));
		vi.stubGlobal('fetch', fetchMock);
		deserializeMock.mockReturnValue({
			type: 'success',
			status: 200,
			data: { createdKey: 'fjc_live_createdkey1234567890abcdef' }
		});

		renderPage({ apiKeys: [], indexOptions: sampleIndexOptions });
		await openCreateDialog();

		await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Production Key' } });
		await fireEvent.input(screen.getByLabelText('Description'), {
			target: { value: 'Production traffic key' }
		});

		const indexesSelect = screen.getByLabelText('Indexes') as HTMLSelectElement;
		setMultiselectValues(indexesSelect, ['products']);
		await fireEvent.change(indexesSelect);

		const aclSelect = screen.getByLabelText('ACL') as HTMLSelectElement;
		setMultiselectValues(aclSelect, ['indexes:read', 'search']);
		await fireEvent.change(aclSelect);

		await fireEvent.click(screen.getByRole('button', { name: 'Add source' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Add source' }));
		await waitFor(() => {
			expect(screen.getByTestId('editor-dialog-field-restrict_sources-1')).toBeInTheDocument();
		});
		const firstSourceInput = screen.getByTestId(
			'editor-dialog-field-restrict_sources-0'
		) as HTMLInputElement;
		const secondSourceInput = screen.getByTestId(
			'editor-dialog-field-restrict_sources-1'
		) as HTMLInputElement;
		await fireEvent.input(firstSourceInput, { target: { value: '10.0.0.0/24' } });
		await fireEvent.input(secondSourceInput, { target: { value: '192.168.1.10' } });
		await fireEvent.input(screen.getByLabelText('Expires at'), {
			target: { value: '2026-07-01T00:00' }
		});
		await fireEvent.input(screen.getByLabelText('Max hits per query'), {
			target: { value: '250' }
		});
		await fireEvent.input(screen.getByLabelText('Max queries per IP per hour'), {
			target: { value: '5000' }
		});

		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(fetchMock).toHaveBeenCalledWith(
			'?/create',
			expect.objectContaining({
				method: 'POST',
				body: expect.any(FormData)
			})
		);
		const [, requestInit] = fetchMock.mock.calls[0] as [string, { body: FormData }];
		expect(requestInit.body.get('name')).toBe('Production Key');
		expect(requestInit.body.get('description')).toBe('Production traffic key');
		expect(requestInit.body.getAll('scope')).toEqual(['indexes:read', 'search']);
		expect(requestInit.body.getAll('indexes')).toEqual(['products']);
		expect(requestInit.body.getAll('restrict_sources')).toEqual(['10.0.0.0/24', '192.168.1.10']);
		expect(requestInit.body.get('expires_at')).toBe('2026-07-01T00:00');
		expect(requestInit.body.get('expires_at_timezone_offset_minutes')).toBe(
			String(new Date(2026, 6, 1, 0, 0, 0).getTimezoneOffset())
		);
		expect(requestInit.body.get('max_hits_per_query')).toBe('250');
		expect(requestInit.body.get('max_queries_per_ip_per_hour')).toBe('5000');

		await waitFor(() => {
			expect(applyActionMock).toHaveBeenCalledWith({
				type: 'success',
				status: 200,
				data: { createdKey: 'fjc_live_createdkey1234567890abcdef' }
			});
		});
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
	});

	it('keeps the create dialog open and surfaces route-action failures inline', async () => {
		const fetchMock = vi.fn().mockResolvedValue(new Response('serialized-result', { status: 400 }));
		vi.stubGlobal('fetch', fetchMock);
		deserializeMock.mockReturnValue({
			type: 'failure',
			status: 400,
			data: { error: 'Name already exists' }
		});

		renderPage({ apiKeys: [], indexOptions: sampleIndexOptions });
		await openCreateDialog();
		await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Duplicate Key' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(await screen.findByText('Name already exists')).toBeInTheDocument();
		expect(screen.getByRole('dialog')).toBeInTheDocument();
		expect(applyActionMock).not.toHaveBeenCalled();
		expect(invalidateAllMock).not.toHaveBeenCalled();
	});

	it('defaults the canonical safe-read management scope in the create dialog', async () => {
		renderPage({ apiKeys: [] });

		expect(SAFE_READ_MANAGEMENT_SCOPE).toBe('indexes:read');
		expect(DEFAULT_MANAGEMENT_SCOPE).toBe(SAFE_READ_MANAGEMENT_SCOPE);

		await openCreateDialog();
		const aclSelect = screen.getByLabelText('ACL') as HTMLSelectElement;
		expect(Array.from(aclSelect.selectedOptions).map((option) => option.value)).toEqual([
			DEFAULT_MANAGEMENT_SCOPE
		]);
	});

	it('filters keys by index, keeps all-index keys visible, and preserves unrelated query params when navigating', async () => {
		const keysWithOrders: ApiKeyListItem[] = [
			...sampleKeys,
			{
				id: 'key-3',
				name: 'Orders Key',
				description: null,
				key_prefix: 'fjc_live_orders',
				scopes: ['search'],
				indexes: ['orders'],
				restrict_sources: [],
				expires_at: null,
				max_hits_per_query: null,
				max_queries_per_ip_per_hour: null,
				last_used_at: null,
				created_at: '2026-02-11T12:00:00Z'
			}
		];
		window.history.replaceState({}, '', '/console/api-keys?view=detailed');
		renderPage({ apiKeys: keysWithOrders, selectedIndexFilter: 'products' });

		expect(screen.getByText('Production Key')).toBeInTheDocument();
		expect(screen.queryByText('Orders Key')).not.toBeInTheDocument();
		expect(screen.getByText('Search-Only Key')).toBeInTheDocument();

		await fireEvent.change(screen.getByLabelText('Index filter'), {
			target: { value: 'orders' }
		});

		expect(gotoMock).toHaveBeenCalledWith('/console/api-keys?view=detailed&index=orders', {
			keepFocus: true,
			noScroll: true
		});

		await fireEvent.change(screen.getByLabelText('Index filter'), {
			target: { value: '' }
		});

		expect(gotoMock).toHaveBeenLastCalledWith('/console/api-keys?view=detailed', {
			keepFocus: true,
			noScroll: true
		});
	});

	it('opens a typed revoke confirmation dialog and disables confirm until the key name matches', async () => {
		renderPage();

		const productionRow = getRowForKeyName('Production Key');
		await fireEvent.click(
			within(productionRow).getByRole('button', { name: 'Revoke key Production Key' })
		);

		expect(screen.getByRole('alertdialog')).toBeInTheDocument();
		const confirmButton = screen.getByTestId('confirm-confirm-btn') as HTMLButtonElement;
		expect(confirmButton.disabled).toBe(true);

		const confirmInput = screen.getByTestId('confirm-input') as HTMLInputElement;
		await fireEvent.input(confirmInput, { target: { value: 'Search-Only Key' } });
		expect(confirmButton.disabled).toBe(true);

		await fireEvent.input(confirmInput, { target: { value: 'Production Key' } });
		expect(confirmButton.disabled).toBe(false);
	});

	it('submits revoke only after typed confirm phrase matches the key name', async () => {
		renderPage();

		const productionRow = getRowForKeyName('Production Key');
		const revokeForm = productionRow.querySelector('form[action="?/revoke"]') as HTMLFormElement;
		const requestSubmitSpy = vi.spyOn(revokeForm, 'requestSubmit').mockImplementation(() => {});
		await fireEvent.click(
			within(productionRow).getByRole('button', { name: 'Revoke key Production Key' })
		);

		const confirmButton = screen.getByTestId('confirm-confirm-btn') as HTMLButtonElement;
		expect(confirmButton.disabled).toBe(true);
		await fireEvent.click(confirmButton);
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.input(screen.getByTestId('confirm-input'), {
			target: { value: 'Production Key' }
		});
		expect(confirmButton.disabled).toBe(false);
		await fireEvent.click(confirmButton);

		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
	});

	it('copies the key prefix with temporary feedback', async () => {
		vi.useFakeTimers();
		const writeTextMock = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: writeTextMock },
			configurable: true
		});

		renderPage();

		const productionRow = getRowForKeyName('Production Key');
		const copyButton = within(productionRow).getByRole('button', {
			name: 'Copy key for Production Key'
		}) as HTMLButtonElement;

		await fireEvent.click(copyButton);

		expect(writeTextMock).toHaveBeenCalledWith('fjc_live_abc1234');
		expect(copyButton).toHaveTextContent('Copied!');
		await Promise.resolve();
		await Promise.resolve();
		expect(toastSuccessMock).toHaveBeenCalledWith('API key copied', {
			duration: TOAST_DURATION_MS
		});

		vi.advanceTimersByTime(2000);
		expect(copyButton).toHaveTextContent('Copy');
	});

	it('does not toast API key copy failures', async () => {
		const writeTextMock = vi.fn().mockRejectedValue(new Error('clipboard unavailable'));
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: writeTextMock },
			configurable: true
		});

		renderPage();

		const productionRow = getRowForKeyName('Production Key');
		const copyButton = within(productionRow).getByRole('button', {
			name: 'Copy key for Production Key'
		}) as HTMLButtonElement;

		await fireEvent.click(copyButton);

		expect(writeTextMock).toHaveBeenCalledWith('fjc_live_abc1234');
		expect(toastSuccessMock).not.toHaveBeenCalled();
	});

	it('revoke forms still point at the existing route action owner', () => {
		const { container } = renderPage();
		const revokeForms = container.querySelectorAll('form[action="?/revoke"]');
		expect(revokeForms.length).toBe(2);
		const firstInput = revokeForms[0].querySelector('input[name="keyId"]') as HTMLInputElement;
		expect(firstInput.value).toBe('key-1');
	});

	it('shows create and revoke action errors in the alert banner', () => {
		renderPage({}, { error: 'Unable to create API key right now.' });

		const alert = screen.getByRole('alert');
		expect(alert).toBeInTheDocument();
		expect(alert).toHaveTextContent('Unable to create API key right now.');
	});

	it('shows full key-reveal success state with one-time warning and revealed value', () => {
		const createdKey = 'fjc_live_abc123def456abc123def456ab';
		renderPage({}, { createdKey });

		const reveal = screen.getByTestId('key-reveal');
		expect(reveal).toBeInTheDocument();
		expect(within(reveal).getByText('API key created successfully')).toBeInTheDocument();
		expect(within(reveal).getByText(/this key won't be shown again/i)).toBeInTheDocument();
		expect(within(reveal).getByText(createdKey)).toBeInTheDocument();
	});

	it('copies the revealed full key with shared toast success', async () => {
		const createdKey = 'fjc_live_abc123def456abc123def456ab';
		const writeTextMock = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: writeTextMock },
			configurable: true
		});

		renderPage({}, { createdKey });

		await fireEvent.click(
			within(screen.getByTestId('key-reveal')).getByRole('button', { name: 'Copy' })
		);

		expect(writeTextMock).toHaveBeenCalledWith(createdKey);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('API key copied', {
				duration: TOAST_DURATION_MS
			});
		});
	});

	it('copies the full key only for the newly created row when duplicate names exist', async () => {
		const writeTextMock = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: writeTextMock },
			configurable: true
		});

		const duplicateName = 'Production Key';
		renderPage(
			{
				apiKeys: [
					...sampleKeys,
					{
						...sampleKeys[0],
						id: 'key-3',
						key_prefix: 'fjc_live_new9876'
					}
				]
			},
			{
				createdKey: 'fjc_live_full_new_key_secret',
				createdKeyId: 'key-3'
			}
		);

		const duplicateRows = screen.getAllByText(duplicateName).map((node) => node.closest('tr'));
		expect(duplicateRows).toHaveLength(2);

		await fireEvent.click(
			within(duplicateRows[0] as HTMLTableRowElement).getByRole('button', {
				name: `Copy key for ${duplicateName}`
			})
		);
		expect(writeTextMock).toHaveBeenLastCalledWith('fjc_live_abc1234');

		await fireEvent.click(
			within(duplicateRows[1] as HTMLTableRowElement).getByRole('button', {
				name: `Copy key for ${duplicateName}`
			})
		);
		expect(writeTextMock).toHaveBeenLastCalledWith('fjc_live_full_new_key_secret');
	});

	it('emits the shared revoke toast from the enhanced revoke action result', async () => {
		renderPage();
		const submitFunction = enhanceSubmitFunctions.at(-1);
		expect(submitFunction).toBeDefined();
		const formData = new FormData();
		formData.set('keyName', 'Production Key');
		const resultHandler = submitFunction!({
			formData
		} as never) as ({
			result,
			update
		}: {
			result: unknown;
			update: () => Promise<void>;
		}) => Promise<void>;
		const update = vi.fn().mockResolvedValue(undefined);

		await resultHandler({
			result: {
				type: 'success',
				status: 200,
				data: { revokedKeyName: 'Production Key' }
			},
			update
		});

		expect(toastSuccessMock).toHaveBeenCalledWith("API key 'Production Key' revoked.", {
			duration: TOAST_DURATION_MS
		});
		expect(update).toHaveBeenCalledTimes(1);
	});

	it('falls back to submitted revoke key name when the action result omits it', async () => {
		renderPage();
		const submitFunction = enhanceSubmitFunctions.at(-1);
		expect(submitFunction).toBeDefined();
		const formData = new FormData();
		formData.set('keyName', 'Production Key');
		const resultHandler = submitFunction!({
			formData
		} as never) as ({
			result,
			update
		}: {
			result: unknown;
			update: () => Promise<void>;
		}) => Promise<void>;
		const update = vi.fn().mockResolvedValue(undefined);

		await resultHandler({
			result: {
				type: 'success',
				status: 200,
				data: {}
			},
			update
		});

		expect(toastSuccessMock).toHaveBeenCalledWith("API key 'Production Key' revoked.", {
			duration: TOAST_DURATION_MS
		});
		expect(update).toHaveBeenCalledTimes(1);
	});
});
