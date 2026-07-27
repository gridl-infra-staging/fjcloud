import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, waitFor, within } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';
import type {
	AlgoliaMigrationAvailabilityResponse,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage
} from '$lib/api/types';
import { migrationJobHref } from '$lib/components/migration/create_success_intent';
import {
	availableAvailability,
	unavailableAvailability
} from '$lib/components/migration/migration_test_fixtures';

const { applyActionMock, deserializeMock, fetchMock, gotoMock, invalidateAllMock } = vi.hoisted(
	() => ({
		applyActionMock: vi.fn(),
		deserializeMock: vi.fn(),
		fetchMock: vi.fn(),
		gotoMock: vi.fn(),
		invalidateAllMock: vi.fn()
	})
);

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	deserialize: deserializeMock
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock,
	invalidateAll: invalidateAllMock
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/migrate') }
}));

vi.mock('$app/environment', () => ({
	browser: true
}));

import MigratePage from './+page.svelte';

beforeEach(() => {
	fetchMock.mockResolvedValue(new Response('serialized-action-result'));
	deserializeMock.mockReturnValue({
		type: 'success',
		status: 200,
		data: {
			providerEligibility: {
				phase: 'provider',
				mode: 'create',
				provider: 'aws',
				target: {
					kind: 'create',
					region: 'us-east-1'
				},
				eligibilityToken: 'provider-token',
				expiresAt: '2099-07-18T10:15:00Z'
			}
		}
	});
	vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
});

type RecentImportsData = { page: PublicAlgoliaImportJobPage | null; error: string | null };

function renderMigratePage(
	availability: AlgoliaMigrationAvailabilityResponse = unavailableAvailability,
	recentImports: RecentImportsData = { page: null, error: null }
) {
	return render(MigratePage, {
		data: {
			...layoutTestDefaults,
			availability,
			recentImports
		}
	});
}

function recentImportJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'copying_documents',
		mode: 'create',
		destination: { kind: 'create', target: 'products_migrated', region: 'us-east-1' },
		source: { name: 'products' },
		summary: {
			documentsExpected: 17,
			documentsImported: 13,
			documentsRejected: 4,
			settingsApplied: 2,
			settingsUnsupported: 1,
			synonymsExpected: 5,
			synonymsImported: 3,
			synonymsRejected: 2,
			rulesExpected: 7,
			rulesImported: 6,
			rulesRejected: 1
		},
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'not_started',
		terminalOutcomeObserved: false,
		warnings: [],
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

function expectNoDormantMigrationControls(container: HTMLElement) {
	expect(container.querySelector('form')).not.toBeInTheDocument();
	expect(screen.queryByLabelText(/app.*id/i)).not.toBeInTheDocument();
	expect(screen.queryByLabelText(/api key/i)).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /source index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /target index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('textbox', { name: /destination index/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /browse indexes/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /migrate/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
	expect(screen.queryByRole('button', { name: /resume/i })).not.toBeInTheDocument();
}

describe('Migrate page unavailable state', () => {
	it('renders the connected create flow when availability.available is true', async () => {
		const { container } = renderMigratePage(availableAvailability);
		const available = screen.getByTestId('migration-available');

		expect(available).toHaveTextContent('Algolia migration is available.');
		expect(screen.queryByTestId('migration-unavailable')).not.toBeInTheDocument();
		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(await screen.findByLabelText(/algolia application id/i)).toHaveValue('');
		expect(await screen.findByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
		expect(container.innerHTML).not.toContain('provider-token');
		await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
		expect(fetchMock).toHaveBeenCalledWith(
			'?/providerEligibility',
			expect.objectContaining({
				method: 'POST',
				headers: { 'x-sveltekit-action': 'true' }
			})
		);
	});

	it('renders the authenticated unavailable explanation page', () => {
		const { container } = renderMigratePage();

		expect(screen.getByRole('heading', { name: /migrate from algolia/i })).toBeInTheDocument();
		expect(screen.getByTestId('migration-unavailable')).toHaveTextContent(
			'Algolia migration is temporarily unavailable while we replace the importer.'
		);
		expect(
			screen.getByText(/We have temporarily turned off new Algolia imports/i)
		).toBeInTheDocument();
		expect(container.querySelector('form')).not.toBeInTheDocument();
	});

	it('does not render migration credentials, source controls, or import CTAs', () => {
		const { container } = renderMigratePage();

		expectNoDormantMigrationControls(container);
	});

	it('does not mount the dormant migration create flow component', () => {
		renderMigratePage();

		// The create-mode flow exists as an unmounted component cluster. The served
		// route must stay on the unavailable state until activation mounts it.
		expect(screen.queryByTestId('migration-create-flow')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/search source indexes/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
	});

	it('renders no dormant preview, job-history, or operation links', () => {
		const { container } = renderMigratePage();

		expect(screen.getByTestId('migration-unavailable')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-recent-imports')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-detail')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /open import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /preview/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /start a new import/i })).not.toBeInTheDocument();

		const renderedLinks = Array.from(container.querySelectorAll('a')).map((link) =>
			link.getAttribute('href')
		);
		expect(renderedLinks).toEqual(['mailto:support@flapjack.foo']);
		expect(container.innerHTML).not.toMatch(/\/migration\/|\/console\/migrate\/job_|preview/i);
	});
});

describe('Migrate page recent imports on the available surface', () => {
	it('renders recent import rows with exact status, destination, date, and reopen link', () => {
		const job = recentImportJob();
		renderMigratePage(availableAvailability, {
			page: { jobs: [job], nextCursor: null },
			error: null
		});

		const recent = screen.getByTestId('migration-recent-imports');
		const row = within(recent).getByTestId(`migration-recent-import-${job.id}`);
		expect(row).toHaveTextContent('products to products_migrated');
		expect(row).toHaveTextContent('Copying documents');
		expect(row).toHaveTextContent('us-east-1');
		expect(row).toHaveTextContent('Updated Jul 18, 2026');

		const reopenLink = within(row).getByRole('link', { name: /open import job_123/i });
		expect(reopenLink).toHaveAttribute('href', migrationJobHref(job.id));
		expect(reopenLink).toHaveAttribute('href', '/console/migrate/job_123');
	});

	it('keeps the create flow visible when the recent-import list is empty', async () => {
		renderMigratePage(availableAvailability, { page: { jobs: [], nextCursor: null }, error: null });

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-imports-empty')).toHaveTextContent(
			'No Algolia imports yet'
		);
	});

	it('keeps the create flow visible when the recent-import list failed to load', async () => {
		renderMigratePage(availableAvailability, {
			page: null,
			error: 'Recent imports could not be loaded'
		});

		expect(await screen.findByTestId('migration-create-flow')).toBeInTheDocument();
		expect(screen.getByTestId('migration-recent-imports-error')).toHaveTextContent(
			'Recent imports could not be loaded'
		);
		expect(screen.getByRole('button', { name: /retry recent imports/i })).toBeInTheDocument();
	});

	it('resyncs recent imports from refreshed route data', async () => {
		const firstJob = recentImportJob();
		const rerenderedJob = recentImportJob({
			id: 'job_456',
			source: { name: 'products_archive' },
			destination: { kind: 'create', target: 'products_archive_migrated', region: 'us-west-2' }
		});
		const { rerender } = renderMigratePage(availableAvailability, {
			page: { jobs: [firstJob], nextCursor: null },
			error: null
		});

		expect(screen.getByTestId(`migration-recent-import-${firstJob.id}`)).toHaveTextContent(
			'products to products_migrated'
		);

		await rerender({
			data: {
				...layoutTestDefaults,
				availability: availableAvailability,
				recentImports: {
					page: { jobs: [rerenderedJob], nextCursor: null },
					error: null
				}
			}
		});

		expect(screen.queryByTestId(`migration-recent-import-${firstJob.id}`)).not.toBeInTheDocument();
		expect(screen.getByTestId(`migration-recent-import-${rerenderedJob.id}`)).toHaveTextContent(
			'products_archive to products_archive_migrated'
		);
	});
});
