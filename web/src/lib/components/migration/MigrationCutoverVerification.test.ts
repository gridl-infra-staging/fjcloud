import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
	AlgoliaImportJobStatus,
	PublicAlgoliaImportJob,
	SourceProvider,
	VerifySourceMigrationResponse
} from '$lib/api/types';
import { getAccessibilityViolations } from '../../../tests/a11y';
import MigrationCutoverVerification from './MigrationCutoverVerification.svelte';

function publicJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'completed',
		mode: 'create',
		sourceProvider: 'algolia',
		destination: { kind: 'create', target: 'fj_products', region: 'us-east-1' },
		source: { name: 'source_products' },
		summary: {
			documentsExpected: 17,
			documentsImported: 17,
			documentsRejected: 0,
			settingsApplied: 1,
			settingsUnsupported: 0,
			synonymsExpected: 0,
			synonymsImported: 0,
			synonymsRejected: 0,
			rulesExpected: 0,
			rulesImported: 0,
			rulesRejected: 0
		},
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'promoted',
		terminalOutcomeObserved: true,
		warnings: [],
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

const DIFFERENCE_REPORT: VerifySourceMigrationResponse = {
	sourceIndex: 'source_products',
	destinationIndex: 'fj_products',
	resultLimit: 4,
	queries: [
		{
			query: 'running shoes',
			overlapCount: 3,
			sourceOnly: ['p2'],
			destinationOnly: ['p5'],
			hits: [
				{ objectID: 'p1', sourceRank: 1, destinationRank: 3, rankDelta: 2 },
				{ objectID: 'p3', sourceRank: 3, destinationRank: 1, rankDelta: -2 },
				{ objectID: 'p4', sourceRank: 4, destinationRank: 4, rankDelta: 0 }
			]
		}
	]
};

const HIGH_AGREEMENT_REPORT: VerifySourceMigrationResponse = {
	sourceIndex: 'source_products',
	destinationIndex: 'fj_products',
	resultLimit: 3,
	queries: [
		{
			query: 'boots',
			overlapCount: 3,
			sourceOnly: [],
			destinationOnly: [],
			hits: [
				{ objectID: 'b1', sourceRank: 1, destinationRank: 1, rankDelta: 0 },
				{ objectID: 'b2', sourceRank: 2, destinationRank: 2, rankDelta: 0 },
				{ objectID: 'b3', sourceRank: 3, destinationRank: 3, rankDelta: 0 }
			]
		}
	]
};

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('MigrationCutoverVerification', () => {
	it('renders the idle retained-job verification form with the required disclaimer', async () => {
		const { container } = render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true
		});

		expect(screen.getByRole('region', { name: /cutover verification/i })).toBeInTheDocument();
		expect(container).toHaveTextContent(
			'Compare top result identifiers and rank positions before cutover.'
		);
		expect(container).toHaveTextContent(
			'This inspection report is not a migration verdict, score, threshold, pass badge, or deployment approval.'
		);
		expect(screen.getByTestId('cutover-verification-source-index')).toHaveTextContent(
			'source_products'
		);
		expect(screen.getByTestId('cutover-verification-destination-index')).toHaveTextContent(
			'fj_products'
		);
		expect(screen.getByLabelText(/algolia application id/i)).toHaveAttribute('type', 'text');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveAttribute('type', 'password');
		expect(screen.getByLabelText(/queries/i)).toBeInTheDocument();
		expect(screen.getByLabelText(/result limit/i)).toHaveAttribute('type', 'number');
		expect(screen.getByRole('button', { name: /run verification/i })).toBeEnabled();
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('submits fresh credentials and parsed controls without treating live input values as leaks', async () => {
		const onVerifyIntent = vi.fn();
		const { container } = render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			onVerifyIntent
		});

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'algolia_app_id_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'algolia_api_key_canary' }
		});
		await fireEvent.input(screen.getByLabelText(/queries/i), {
			target: { value: 'running shoes\n\nboots' }
		});
		await fireEvent.input(screen.getByLabelText(/result limit/i), {
			target: { value: '4' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		expect(onVerifyIntent).toHaveBeenCalledWith({
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			queries: ['running shoes', 'boots'],
			resultLimit: 4
		});
		expect(container.textContent).not.toContain('algolia_app_id_canary');
		expect(container.textContent).not.toContain('algolia_api_key_canary');
	});

	it('clears only credential inputs after a verification attempt settles', async () => {
		let settleVerification: () => void = () => {};
		const onVerifyIntent = vi.fn(
			() =>
				new Promise<void>((resolve) => {
					settleVerification = resolve;
				})
		);
		render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			onVerifyIntent
		});

		const appIdInput = screen.getByLabelText(/algolia application id/i);
		const apiKeyInput = screen.getByLabelText(/algolia api key/i);
		const queriesInput = screen.getByLabelText(/queries/i);
		const resultLimitInput = screen.getByLabelText(/result limit/i);
		await fireEvent.input(appIdInput, { target: { value: 'algolia_app_id_canary' } });
		await fireEvent.input(apiKeyInput, { target: { value: 'algolia_api_key_canary' } });
		await fireEvent.input(queriesInput, { target: { value: 'running shoes\nboots' } });
		await fireEvent.input(resultLimitInput, { target: { value: '4' } });
		await fireEvent.click(screen.getByRole('button', { name: /run verification/i }));

		expect(appIdInput).toHaveValue('algolia_app_id_canary');
		expect(apiKeyInput).toHaveValue('algolia_api_key_canary');
		settleVerification();

		await vi.waitFor(() => {
			expect(appIdInput).toHaveValue('');
			expect(apiKeyInput).toHaveValue('');
		});
		expect(queriesInput).toHaveValue('running shoes\nboots');
		expect(resultLimitInput).toHaveValue(4);
	});

	it('shows the running state and suppresses duplicate local submissions', async () => {
		const onVerifyIntent = vi.fn();
		render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			activeRequest: true,
			onVerifyIntent
		});

		expect(screen.getByRole('status')).toHaveTextContent('Running cutover verification');
		expect(screen.getByRole('button', { name: /running verification/i })).toBeDisabled();
		await fireEvent.click(screen.getByRole('button', { name: /running verification/i }));
		expect(onVerifyIntent).not.toHaveBeenCalled();
	});

	it.each(['completed', 'completed_with_warnings'] as AlgoliaImportJobStatus[])(
		'renders for retained %s jobs',
		(status) => {
			render(MigrationCutoverVerification, { job: publicJob({ status }) });

			expect(screen.getByRole('region', { name: /cutover verification/i })).toBeInTheDocument();
		}
	);

	it.each(['queued', 'copying_documents', 'failed', 'cancelled'] as AlgoliaImportJobStatus[])(
		'does not render verification controls for %s jobs',
		(status) => {
			render(MigrationCutoverVerification, { job: publicJob({ status }) });

			expect(
				screen.queryByRole('region', { name: /cutover verification/i })
			).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		}
	);

	it('renders exact difference report values with accessible list and table names', async () => {
		const { container } = render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			report: DIFFERENCE_REPORT
		});

		expect(screen.getByLabelText('Cutover verification report')).toHaveTextContent(
			'source_products'
		);
		const queryReport = screen.getByLabelText('Cutover verification query report: running shoes');
		expect(queryReport).toHaveTextContent('Overlap 3');

		const sourceOnly = screen.getByLabelText('Source-only object IDs: running shoes');
		expect(within(sourceOnly).getByText('p2')).toBeInTheDocument();
		const destinationOnly = screen.getByLabelText('Destination-only object IDs: running shoes');
		expect(within(destinationOnly).getByText('p5')).toBeInTheDocument();

		const table = screen.getByRole('table', { name: 'Hit rank comparison: running shoes' });
		const p3 = within(table).getByRole('row', { name: /p3 3 1 -2/i });
		expect(p3).toBeInTheDocument();
		expect(container.textContent).not.toMatch(/pass|passed|success|score|verdict|ready|green/i);
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('renders every report when repeated query text has distinct values', () => {
		const repeatedQueryReport: VerifySourceMigrationResponse = {
			...DIFFERENCE_REPORT,
			queries: [
				DIFFERENCE_REPORT.queries[0],
				{
					query: 'running shoes',
					overlapCount: 1,
					sourceOnly: ['p8'],
					destinationOnly: ['p9'],
					hits: [{ objectID: 'p10', sourceRank: 4, destinationRank: 2, rankDelta: -2 }]
				}
			]
		};

		render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			report: repeatedQueryReport
		});

		const queryReports = screen.getAllByLabelText(
			'Cutover verification query report: running shoes'
		);
		expect(queryReports).toHaveLength(2);
		expect(queryReports[0]).toHaveTextContent('Overlap 3');
		expect(queryReports[0]).toHaveTextContent('p2');
		expect(queryReports[1]).toHaveTextContent('Overlap 1');
		expect(queryReports[1]).toHaveTextContent('p8');
		expect(queryReports[1]).toHaveTextContent('p10');
	});

	it('renders high-agreement reports as neutral facts, not as a pass state', () => {
		const { container } = render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			report: HIGH_AGREEMENT_REPORT
		});

		expect(screen.getByLabelText('Cutover verification query report: boots')).toHaveTextContent(
			'Overlap 3'
		);
		expect(container.textContent).not.toMatch(/pass|passed|success|score|verdict|ready|green/i);
	});

	it.each([
		{
			code: 'invalid_credentials',
			expected: 'Algolia credentials were rejected. Enter a valid key and run verification again.'
		},
		{
			code: 'missing_source_permission',
			expected: 'The Algolia key does not have permission to search the source index.'
		},
		{
			code: 'source_not_found',
			expected: 'The source index could not be found.'
		},
		{
			code: 'backend_unavailable',
			expected: 'The comparison service is temporarily unavailable.'
		},
		{
			code: 'incompatible_data',
			expected: 'The verification request or destination response could not be compared.'
		}
	])('renders sanitized verification error state for $code', ({ code, expected }) => {
		const { container } = render(MigrationCutoverVerification, {
			job: publicJob(),
			verifySupported: true,
			error: {
				code,
				message: `${expected} algolia_api_key_canary`
			}
		});

		expect(screen.getByRole('alert')).toHaveTextContent(expected);
		expect(container.textContent).not.toContain('algolia_api_key_canary');
	});

	it('renders empty credentials and the default query controls when the server supports verify', () => {
		render(MigrationCutoverVerification, { job: publicJob(), verifySupported: true });

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByLabelText(/queries/i)).toHaveValue('running shoes');
		expect(screen.getByLabelText(/result limit/i)).toHaveValue(10);
		expect(screen.getByRole('button', { name: /run verification/i })).toBeEnabled();
	});

	// Capability is server-published, not provider-inferred: an omitted
	// `verifySupported` must fail closed for every provider, Algolia included.
	//
	// The expected sentence is spelled out here rather than imported from
	// `job_presentation.ts`, so this file is the one place the customer-visible
	// wording is pinned; every other owner asserts through the shared builder.
	it.each([
		['algolia', 'Algolia'],
		['meilisearch', 'Meilisearch'],
		['typesense', 'Typesense']
	] as [SourceProvider, string][])(
		'renders the %s unsupported state without credential fields when verify is not published',
		(sourceProvider, providerLabel) => {
			render(MigrationCutoverVerification, { job: publicJob({ sourceProvider }) });

			expect(
				screen.getByText(
					`Cutover verification is not available for this ${providerLabel} migration, ` +
						'so you cannot compare source and fjcloud search results here. The completed ' +
						'migration and any preview support published for it are unaffected.'
				)
			).toBeInTheDocument();
			expect(screen.queryByLabelText(/api key/i)).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/queries/i)).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/result limit/i)).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: /run verification/i })).not.toBeInTheDocument();
		}
	);
});
