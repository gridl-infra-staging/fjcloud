import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { PublicAlgoliaImportJob } from '$lib/api/types';

const getAlgoliaImportJobMock = vi.fn();
const getAlgoliaMigrationAvailabilityMock = vi.fn();
const cancelAlgoliaImportJobMock = vi.fn();
const resumeAlgoliaImportJobMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAlgoliaImportJob: getAlgoliaImportJobMock,
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock,
		cancelAlgoliaImportJob: cancelAlgoliaImportJobMock,
		resumeAlgoliaImportJob: resumeAlgoliaImportJobMock
	}))
}));

import { actions, load } from './+page.server';

const JOB_FIXTURE: PublicAlgoliaImportJob = {
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
	createdAt: '2026-07-18T10:00:00Z',
	updatedAt: '2026-07-18T10:05:00Z'
};

const AVAILABLE_CAPABILITIES = { cancel: true, resume: false, replace: true };

function availableResponse() {
	return {
		available: true,
		message: 'Algolia migration is available.',
		capabilities: AVAILABLE_CAPABILITIES
	};
}

function localsWithToken(token = 'jwt-secret-canary') {
	return { user: { token } };
}

const SECRET_CANARIES = [
	'jwt-secret-canary',
	'algolia_app_id_canary',
	'algolia_api_key_canary',
	'source_products',
	'resume-secret-key-canary'
];

describe('[jobId] migration route server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		getAlgoliaImportJobMock.mockResolvedValue(JOB_FIXTURE);
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue(availableResponse());
	});

	it('loads the job and derives capabilities from the single availability source', async () => {
		const result = (await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never)) as Record<string, unknown>;

		expect(getAlgoliaImportJobMock).toHaveBeenCalledOnce();
		expect(getAlgoliaImportJobMock).toHaveBeenCalledWith('job_123');
		expect(getAlgoliaMigrationAvailabilityMock).toHaveBeenCalledOnce();
		expect(result).toEqual({
			job: JOB_FIXTURE,
			capabilities: AVAILABLE_CAPABILITIES
		});
	});

	it('serializes the job fixture without leaking tokens, credentials, or resume keys', async () => {
		const result = await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never);
		const serialized = JSON.stringify(result);

		for (const canary of SECRET_CANARIES) {
			expect(serialized).not.toContain(canary);
		}
	});

	it('fails capabilities closed when availability reports unavailable', async () => {
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'unavailable',
			capabilities: { cancel: false, resume: false, replace: false }
		});

		const result = (await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never)) as Record<string, unknown>;

		expect(result).toEqual({
			job: JOB_FIXTURE,
			capabilities: { cancel: false, resume: false, replace: false }
		});
	});

	it('fails capabilities closed on a non-auth availability failure while still serving the job', async () => {
		getAlgoliaMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(500, 'boom'));

		const result = (await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never)) as Record<string, unknown>;

		expect(result).toEqual({
			job: JOB_FIXTURE,
			capabilities: { cancel: false, resume: false, replace: false }
		});
	});

	it('maps a 401 on the job fetch through the dashboard auth contract', async () => {
		getAlgoliaImportJobMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({ _authSessionExpired: true, error: 'Unauthorized' })
			})
		);
		expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
	});

	it('maps a 403 on the availability fetch through the dashboard auth contract', async () => {
		getAlgoliaMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await load({
			params: { jobId: 'job_123' },
			locals: localsWithToken()
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({ _authSessionExpired: true })
			})
		);
	});

	it('throws a 404 for a missing job', async () => {
		getAlgoliaImportJobMock.mockRejectedValue(new ApiRequestError(404, 'not found'));

		await expect(
			load({ params: { jobId: 'ghost' }, locals: localsWithToken() } as never)
		).rejects.toMatchObject({ status: 404 });
	});

	it('rejects path-traversal job ids before calling the control plane', async () => {
		await expect(
			load({ params: { jobId: '../admin' }, locals: localsWithToken() } as never)
		).rejects.toMatchObject({ status: 404 });

		expect(getAlgoliaImportJobMock).not.toHaveBeenCalled();
		expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
	});
});

function actionRequest(fields: Record<string, string> = {}): Request {
	const formData = new FormData();
	for (const [key, value] of Object.entries(fields)) {
		formData.set(key, value);
	}
	return new Request('http://localhost/console/migrate/job_123', {
		method: 'POST',
		body: formData
	});
}

describe('[jobId] migration route server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		cancelAlgoliaImportJobMock.mockResolvedValue({ ...JOB_FIXTURE, status: 'cancelling' });
		resumeAlgoliaImportJobMock.mockResolvedValue({ ...JOB_FIXTURE, status: 'resuming' });
	});

	it('exports only the cancel and resume job actions', () => {
		expect(Object.keys(actions).sort()).toEqual(['cancel', 'resume']);
	});

	it('cancel calls cancelAlgoliaImportJob with the path job id and the server token only', async () => {
		const result = await actions.cancel({
			params: { jobId: 'job_123' },
			request: actionRequest(),
			locals: localsWithToken()
		} as never);

		expect(cancelAlgoliaImportJobMock).toHaveBeenCalledOnce();
		expect(cancelAlgoliaImportJobMock).toHaveBeenCalledWith('job_123');
		expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
	});

	it('resume parses the fresh API key and forwards it without echoing it back', async () => {
		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({ apiKey: 'resume-secret-key-canary-0007' }),
			locals: localsWithToken()
		} as never);

		expect(resumeAlgoliaImportJobMock).toHaveBeenCalledOnce();
		expect(resumeAlgoliaImportJobMock).toHaveBeenCalledWith('job_123', {
			apiKey: 'resume-secret-key-canary-0007'
		});
		const serialized = JSON.stringify(result);
		expect(serialized).not.toContain('resume-secret-key-canary-0007');
		expect(serialized).not.toContain('jwt-secret-canary');
	});

	it('rejects a blank resume API key before calling the control plane', async () => {
		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({ apiKey: '   ' }),
			locals: localsWithToken()
		} as never);

		expect(resumeAlgoliaImportJobMock).not.toHaveBeenCalled();
		expect(result).toMatchObject({ status: 400 });
	});

	it('maps a 401 cancel failure through the dashboard auth contract', async () => {
		cancelAlgoliaImportJobMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.cancel({
			params: { jobId: 'job_123' },
			request: actionRequest(),
			locals: localsWithToken()
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({ _authSessionExpired: true })
			})
		);
	});

	it('maps a 403 resume failure through the dashboard auth contract', async () => {
		resumeAlgoliaImportJobMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({ apiKey: 'resume-secret-key-canary-0007' }),
			locals: localsWithToken()
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({ _authSessionExpired: true })
			})
		);
	});

	it('rejects invalid action job ids before forwarding cancel or resume calls', async () => {
		await expect(
			actions.cancel({
				params: { jobId: 'job_123/../../other' },
				request: actionRequest(),
				locals: localsWithToken()
			} as never)
		).rejects.toMatchObject({ status: 404 });
		await expect(
			actions.resume({
				params: { jobId: 'job_123\\evil' },
				request: actionRequest({ apiKey: 'resume-secret-key-canary-0007' }),
				locals: localsWithToken()
			} as never)
		).rejects.toMatchObject({ status: 404 });

		expect(cancelAlgoliaImportJobMock).not.toHaveBeenCalled();
		expect(resumeAlgoliaImportJobMock).not.toHaveBeenCalled();
	});
});
