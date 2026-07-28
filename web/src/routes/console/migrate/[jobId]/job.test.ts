import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/svelte';
import type {
	AlgoliaImportJobStatus,
	AlgoliaMigrationCapabilities,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import { getAccessibilityViolations } from '../../../../tests/a11y';

const { applyActionMock, deserializeMock, fetchMock, invalidateAllMock } = vi.hoisted(() => ({
	applyActionMock: vi.fn(),
	deserializeMock: vi.fn(),
	fetchMock: vi.fn(),
	invalidateAllMock: vi.fn()
}));

vi.mock('$app/forms', () => ({
	applyAction: applyActionMock,
	deserialize: deserializeMock
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: invalidateAllMock
}));

import JobDetailPage from './+page.svelte';

const RUNNING_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: true,
	resume: false,
	replace: true
};
const NO_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false
};

function publicJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
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

function renderJobPage(
	job: PublicAlgoliaImportJob = publicJob(),
	capabilities: AlgoliaMigrationCapabilities = NO_CAPABILITIES
) {
	return render(JobDetailPage, { data: { job, capabilities } });
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
});

describe('[jobId] job detail page presentation', () => {
	it('renders running document progress without premature terminal outcome rows', () => {
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Copying documents');
		expect(screen.getByTestId('migration-job-phase')).toHaveTextContent('Copying records');

		const documents = screen.getByTestId('migration-summary-documents');
		expect(documents).toHaveTextContent('13 imported');
		expect(documents).toHaveTextContent('17 expected');
		expect(documents).toHaveTextContent('4 rejected');

		expect(screen.queryByTestId('migration-summary-settings')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-summary-synonyms')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-summary-rules')).not.toBeInTheDocument();
	});

	it('renders the typed failure message and no cancel control for a failed job', () => {
		renderJobPage(
			publicJob({ status: 'failed', error: { code: 'invalid_credentials' } }),
			RUNNING_CAPABILITIES
		);

		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'Algolia credentials were rejected. Reconnect with a valid key.'
		);
		expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-capability-actions')).not.toBeInTheDocument();
	});

	it('renders cancel inside capability actions and no resume affordances when only cancel is enabled', () => {
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		const actions = screen.getByTestId('migration-job-capability-actions');
		expect(actions).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeInTheDocument();

		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-resume-deadline')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-retry-panel')).not.toBeInTheDocument();
	});

	it('has no structural accessibility violations for running and failed job states', async () => {
		const { container } = renderJobPage(
			publicJob({ status: 'copying_documents' }),
			RUNNING_CAPABILITIES
		);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		cleanup();

		const { container: failedContainer } = renderJobPage(
			publicJob({ status: 'failed', error: { code: 'invalid_credentials' } }),
			RUNNING_CAPABILITIES
		);

		await expect(getAccessibilityViolations(failedContainer)).resolves.toEqual([]);
	});
});

describe('[jobId] job detail live refresh', () => {
	beforeEach(() => {
		invalidateAllMock.mockResolvedValue(undefined);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it('reloads the server load data on an interval while the job is running', async () => {
		vi.useFakeTimers();
		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(invalidateAllMock).not.toHaveBeenCalled();

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(2);
	});

	it('never schedules a reload for a terminal job', async () => {
		vi.useFakeTimers();
		renderJobPage(publicJob({ status: 'completed' }), NO_CAPABILITIES);

		await vi.advanceTimersByTimeAsync(20000);
		expect(invalidateAllMock).not.toHaveBeenCalled();
	});

	it('stops reloading once the page is destroyed', async () => {
		vi.useFakeTimers();
		const { unmount } = renderJobPage(
			publicJob({ status: 'copying_documents' }),
			RUNNING_CAPABILITIES
		);

		await vi.advanceTimersByTimeAsync(4000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);

		unmount();
		await vi.advanceTimersByTimeAsync(12000);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
	});
});

describe('[jobId] job detail actions', () => {
	beforeEach(() => {
		fetchMock.mockResolvedValue(new Response('serialized-action-result'));
		vi.stubGlobal('fetch', fetchMock);
	});

	it('submits the cancel action through the server-only action boundary and refreshes on success', async () => {
		deserializeMock.mockReturnValue({ type: 'success', status: 200, data: { job: publicJob() } });
		invalidateAllMock.mockResolvedValue(undefined);
		vi.spyOn(window, 'confirm').mockReturnValue(true);

		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));

		expect(fetchMock).toHaveBeenCalledWith(
			'?/cancel',
			expect.objectContaining({
				method: 'POST',
				headers: { 'x-sveltekit-action': 'true' }
			})
		);
		await vi.waitFor(() => expect(invalidateAllMock).toHaveBeenCalled());
	});

	it('surfaces the reloading marker during a post-action refresh, then clears it', async () => {
		deserializeMock.mockReturnValue({ type: 'success', status: 200, data: { job: publicJob() } });
		let resolveInvalidate: () => void = () => {};
		invalidateAllMock.mockReturnValue(
			new Promise<void>((resolve) => {
				resolveInvalidate = resolve;
			})
		);
		vi.spyOn(window, 'confirm').mockReturnValue(true);

		renderJobPage(publicJob({ status: 'copying_documents' }), RUNNING_CAPABILITIES);

		expect(screen.getByTestId('migration-job-safe-reload')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-reloading')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));
		await vi.waitFor(() => expect(invalidateAllMock).toHaveBeenCalled());
		await vi.waitFor(() =>
			expect(screen.getByTestId('migration-job-reloading')).toBeInTheDocument()
		);

		resolveInvalidate();
		await vi.waitFor(() =>
			expect(screen.queryByTestId('migration-job-reloading')).not.toBeInTheDocument()
		);
	});

	it('submits the resume action with the entered API key without leaking it into the page', async () => {
		const resumableJob = publicJob({
			status: 'interrupted',
			error: { code: 'interrupted' },
			resumable: true
		});
		deserializeMock.mockReturnValue({ type: 'success', status: 200, data: { job: resumableJob } });
		invalidateAllMock.mockResolvedValue(undefined);

		const { container } = renderJobPage(resumableJob, {
			cancel: false,
			resume: true,
			replace: false
		});

		const apiKeyInput = screen.getByLabelText(/algolia api key/i);
		await fireEvent.input(apiKeyInput, { target: { value: 'resume-secret-key-canary-0007' } });
		await fireEvent.click(screen.getByRole('button', { name: /resume import/i }));

		expect(fetchMock).toHaveBeenCalledWith('?/resume', expect.objectContaining({ method: 'POST' }));
		const submittedBody = fetchMock.mock.calls[0][1].body as FormData;
		expect(submittedBody.get('apiKey')).toBe('resume-secret-key-canary-0007');
		expect(container.innerHTML).not.toContain('resume-secret-key-canary-0007');
	});
});

const TERMINAL_STATUSES: AlgoliaImportJobStatus[] = [
	'completed',
	'completed_with_warnings',
	'failed',
	'cancelled'
];

describe('[jobId] job detail terminal statuses never poll', () => {
	it.each(TERMINAL_STATUSES)('does not reload load data for terminal status %s', async (status) => {
		vi.useFakeTimers();
		invalidateAllMock.mockResolvedValue(undefined);
		renderJobPage(publicJob({ status }), NO_CAPABILITIES);

		await vi.advanceTimersByTimeAsync(20000);
		expect(invalidateAllMock).not.toHaveBeenCalled();
		vi.useRealTimers();
	});
});
