import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent, within } from '@testing-library/dom';
import type { ApiKeyListItem } from '$lib/api/types';
import { formatDate, scopeLabel } from '$lib/format';
import { layoutTestDefaults } from '../layout-test-context';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

import ApiKeysPage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

const sampleKeys: ApiKeyListItem[] = [
	{
		id: 'key-1',
		name: 'Production Key',
		key_prefix: 'gridl_live_abc12',
		scopes: ['indexes:read', 'indexes:write'],
		last_used_at: '2026-02-20T10:00:00Z',
		created_at: '2026-01-15T08:00:00Z'
	},
	{
		id: 'key-2',
		name: 'Search-Only Key',
		key_prefix: 'gridl_live_def34',
		scopes: ['search'],
		last_used_at: null,
		created_at: '2026-02-10T12:00:00Z'
	}
];

function getRowForKeyName(name: string): HTMLTableRowElement {
	const row = screen.getByText(name).closest('tr');
	expect(row).not.toBeNull();
	return row as HTMLTableRowElement;
}

describe('API Keys page', () => {
	it('renders seeded rows with row-scoped prefixes, scope labels, and date values', () => {
		render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: sampleKeys },
			form: null
		});

		expect(screen.getByRole('columnheader', { name: 'Prefix' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Scopes' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Last used' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Created' })).toBeInTheDocument();

		const productionRow = getRowForKeyName('Production Key');
		expect(within(productionRow).getByText('gridl_live_abc12...')).toBeInTheDocument();
		expect(within(productionRow).getByText(scopeLabel('indexes:read'))).toBeInTheDocument();
		expect(within(productionRow).getByText(scopeLabel('indexes:write'))).toBeInTheDocument();
		expect(
			within(productionRow).getByText(formatDate(sampleKeys[0].last_used_at))
		).toBeInTheDocument();
		expect(
			within(productionRow).getByText(formatDate(sampleKeys[0].created_at))
		).toBeInTheDocument();
		expect(within(productionRow).queryByText('Never')).not.toBeInTheDocument();
		expect(
			within(productionRow).queryByText(formatDate(sampleKeys[1].created_at))
		).not.toBeInTheDocument();
		expect(within(productionRow).queryByText('Search')).not.toBeInTheDocument();

		const searchOnlyRow = getRowForKeyName('Search-Only Key');
		expect(within(searchOnlyRow).getByText('gridl_live_def34...')).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText(scopeLabel('search'))).toBeInTheDocument();
		expect(within(searchOnlyRow).getByText('Never')).toBeInTheDocument();
		expect(
			within(searchOnlyRow).getByText(formatDate(sampleKeys[1].created_at))
		).toBeInTheDocument();
		expect(
			within(searchOnlyRow).queryByText(formatDate(sampleKeys[0].last_used_at))
		).not.toBeInTheDocument();
		expect(
			within(searchOnlyRow).queryByText(formatDate(sampleKeys[0].created_at))
		).not.toBeInTheDocument();
		expect(within(searchOnlyRow).queryByText('Indexes: Read')).not.toBeInTheDocument();
	});

	it('shows revoke confirmation dialog when revoke is clicked', async () => {
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
		render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: sampleKeys },
			form: null
		});
		const revokeButtons = screen.getAllByRole('button', { name: /revoke/i });
		await fireEvent.click(revokeButtons[0]);
		expect(confirmSpy).toHaveBeenCalledWith(expect.stringMatching(/revoke/i));
		confirmSpy.mockRestore();
	});

	it('shows empty state when no API keys', () => {
		render(ApiKeysPage, { data: { ...layoutTestDefaults, user: null, apiKeys: [] }, form: null });
		expect(screen.getByText(/no api keys/i)).toBeInTheDocument();
		expect(screen.getByRole('heading', { name: /create api key/i })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /create key/i })).toBeInTheDocument();
		expect(screen.queryByRole('table')).not.toBeInTheDocument();
	});

	it('has create key form with name input and all management scope checkboxes', () => {
		render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: [] },
			form: null
		});
		expect(screen.getByLabelText(/^name$/i)).toBeInTheDocument();
		const scopeCheckboxes = [
			screen.getByLabelText('Indexes: Read'),
			screen.getByLabelText('Indexes: Write'),
			screen.getByLabelText('Keys: Manage'),
			screen.getByLabelText('Billing: Read'),
			screen.getByLabelText('Search')
		] as HTMLInputElement[];
		expect(scopeCheckboxes).toHaveLength(5);
		expect(scopeCheckboxes.every((checkbox) => checkbox.name === 'scope')).toBe(true);
		expect(scopeCheckboxes.map((checkbox) => checkbox.value)).toEqual([
			'indexes:read',
			'indexes:write',
			'keys:manage',
			'billing:read',
			'search'
		]);
	});

	it('revoke form posts to correct action with key ID', () => {
		const { container } = render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: sampleKeys },
			form: null
		});
		const revokeForms = container.querySelectorAll('form[action="?/revoke"]');
		expect(revokeForms.length).toBe(2);
		const firstInput = revokeForms[0].querySelector('input[name="keyId"]') as HTMLInputElement;
		expect(firstInput.value).toBe('key-1');
	});

	it('shows create/revoke action errors in the alert banner', () => {
		render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: sampleKeys },
			form: { error: 'Unable to create API key right now.' }
		});

		const alert = screen.getByRole('alert');
		expect(alert).toBeInTheDocument();
		expect(alert).toHaveTextContent('Unable to create API key right now.');
	});

	it('shows full key-reveal success state with one-time warning and revealed value', () => {
		const createdKey = 'gridl_live_abc123def456abc123def456ab';
		render(ApiKeysPage, {
			data: { ...layoutTestDefaults, user: null, apiKeys: sampleKeys },
			form: { createdKey }
		});

		const reveal = screen.getByTestId('key-reveal');
		expect(reveal).toBeInTheDocument();
		expect(within(reveal).getByText('API key created successfully')).toBeInTheDocument();
		expect(within(reveal).getByText(/this key won't be shown again/i)).toBeInTheDocument();
		expect(within(reveal).getByText(createdKey)).toBeInTheDocument();
	});
});
