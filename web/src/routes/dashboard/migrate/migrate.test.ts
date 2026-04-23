import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import type { AlgoliaIndexInfo } from '$lib/api/types';
import { layoutTestDefaults } from '../layout-test-context';

const enhanceMock = vi.hoisted(() =>
	vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	})
);

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/migrate') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

import MigratePage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

type MigrateForm = {
	indexes?: AlgoliaIndexInfo[];
	appId?: string;
	migrationStarted?: boolean;
	taskId?: string;
	message?: string;
	error?: string;
} | null;

function renderMigratePage(form: MigrateForm = null) {
	return render(MigratePage, {
		data: { ...layoutTestDefaults },
		form
	});
}

describe('Migrate page', () => {
	it('renders credentials form in initial state', () => {
		renderMigratePage();

		expect(screen.getByRole('heading', { name: /migrate/i })).toBeInTheDocument();
		// Credentials form with appId and apiKey inputs
		expect(screen.getByLabelText(/app.*id/i)).toBeInTheDocument();
		expect(screen.getByLabelText(/api.*key/i)).toBeInTheDocument();
		// No index list or migration result visible
		expect(screen.queryByTestId('index-list')).not.toBeInTheDocument();
		expect(screen.queryByText(/migration started/i)).not.toBeInTheDocument();
	});

	it('renders listed indexes after listIndexes action', () => {
		const indexes: AlgoliaIndexInfo[] = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
			{ name: 'users', entries: 200, lastBuildTimeS: 3 }
		];

		renderMigratePage({
			indexes,
			appId: 'ALGOLIA_APP'
		});

		const indexList = screen.getByTestId('index-list');
		expect(indexList).toBeInTheDocument();
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('users')).toBeInTheDocument();
		expect(screen.getByText('5,000')).toBeInTheDocument();
		expect(screen.getByText('200')).toBeInTheDocument();
	});

	it('renders migration result after migrate action', () => {
		renderMigratePage({
			migrationStarted: true,
			taskId: 'task-abc-123',
			message: 'Migration queued successfully'
		});

		// The success banner heading
		expect(screen.getByText('Migration started')).toBeInTheDocument();
		expect(screen.getByText('task-abc-123')).toBeInTheDocument();
		expect(screen.getByText('Migration queued successfully')).toBeInTheDocument();
	});

	it('renders deployment-unavailable banner on 503 error', () => {
		renderMigratePage({
			error: 'No active deployment available'
		});

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText(/no active deployment available/i)).toBeInTheDocument();
	});

	it('renders generic error banner', () => {
		renderMigratePage({
			error: 'Invalid credentials'
		});

		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText('Invalid credentials')).toBeInTheDocument();
	});

	it('credentials form posts to ?/listIndexes', () => {
		const { container } = renderMigratePage();

		const credForm = container.querySelector('form[action="?/listIndexes"]');
		expect(credForm).toBeInTheDocument();
	});

	it('index list shows migrate forms with hidden appId and sourceIndex from server, apiKey from client state', () => {
		const indexes: AlgoliaIndexInfo[] = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 }
		];

		const { container } = renderMigratePage({
			indexes,
			appId: 'ALGOLIA_APP'
		});

		const migrateForm = container.querySelector('form[action="?/migrate"]');
		expect(migrateForm).toBeInTheDocument();

		// appId comes from server form response, apiKey from client $state (empty by default in test)
		const appIdInput = migrateForm!.querySelector('input[name="appId"]') as HTMLInputElement;
		const apiKeyInput = migrateForm!.querySelector('input[name="apiKey"]') as HTMLInputElement;
		const sourceIndexInput = migrateForm!.querySelector(
			'input[name="sourceIndex"]'
		) as HTMLInputElement;

		expect(appIdInput.value).toBe('ALGOLIA_APP');
		// apiKey is client-side state, not from server — defaults to empty in test
		expect(apiKeyInput.value).toBe('');
		expect(sourceIndexInput.value).toBe('products');
	});

	it('enhances all forms with use:enhance', () => {
		const indexes: AlgoliaIndexInfo[] = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
			{ name: 'users', entries: 200, lastBuildTimeS: 3 }
		];

		renderMigratePage({
			indexes,
			appId: 'APP'
		});

		// 1 credentials form + 2 migrate forms = at least 3 enhance calls
		const enhancedActions = enhanceMock.mock.calls.map(
			(call: [HTMLFormElement]) => call[0].getAttribute('action')
		);
		expect(enhancedActions.filter((a: string | null) => a === '?/listIndexes')).toHaveLength(1);
		expect(enhancedActions.filter((a: string | null) => a === '?/migrate')).toHaveLength(2);
	});

	it('does not import or reference the api-logs store', async () => {
		// The migrate page must not append entries to the shared API log store.
		// Verify the component source has no log store imports — this is a static
		// guarantee that migration credentials never leak into browser session storage.
		const pageSource = await import('./+page.svelte?raw');
		expect(pageSource.default).not.toContain('api-logs/store');
		expect(pageSource.default).not.toContain('appendLogEntry');
		expect(pageSource.default).not.toContain('api-logs/dashboard-instrumentation');
	});

	it('successful migration workflow does not append entries to the api-logs store', async () => {
		// Runtime behavioral assertion: exercise all three workflow states
		// (initial, index listing, migration success) and verify the shared
		// log store stays empty throughout — complements the static source check.
		const { getLogEntries, clearLog } = await import('$lib/api-logs/store');
		clearLog();

		// Step 1: initial credentials form
		renderMigratePage();
		expect(getLogEntries()).toHaveLength(0);
		cleanup();

		// Step 2: after listing indexes (simulates ?/listIndexes response)
		const indexes: AlgoliaIndexInfo[] = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
			{ name: 'users', entries: 200, lastBuildTimeS: 3 }
		];
		renderMigratePage({ indexes, appId: 'ALGOLIA_APP' });
		expect(getLogEntries()).toHaveLength(0);
		cleanup();

		// Step 3: after successful migration (simulates ?/migrate response)
		renderMigratePage({
			migrationStarted: true,
			taskId: 'task-abc-123',
			message: 'Migration queued successfully'
		});
		expect(getLogEntries()).toHaveLength(0);

		clearLog();
	});
});
