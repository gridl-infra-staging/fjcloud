import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { PublicAlgoliaImportJob } from '$lib/api/types';

const getAlgoliaImportJobMock = vi.fn();
const getMigrationImportJobMock = vi.fn();
const getAlgoliaMigrationAvailabilityMock = vi.fn();
const getMigrationAvailabilityMock = vi.fn();
const cancelAlgoliaImportJobMock = vi.fn();
const resumeAlgoliaImportJobMock = vi.fn();
const cancelMigrationImportJobMock = vi.fn();
const resumeMigrationImportJobMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAlgoliaImportJob: getAlgoliaImportJobMock,
		getMigrationImportJob: getMigrationImportJobMock,
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock,
		getMigrationAvailability: getMigrationAvailabilityMock,
		cancelAlgoliaImportJob: cancelAlgoliaImportJobMock,
		resumeAlgoliaImportJob: resumeAlgoliaImportJobMock,
		cancelMigrationImportJob: cancelMigrationImportJobMock,
		resumeMigrationImportJob: resumeMigrationImportJobMock
	}))
}));

import { actions, load } from './+page.server';

const CLOSED_SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
const INVALID_SOURCE_PROVIDERS = ['elastic', '../typesense'] as const;
type SourceProvider = (typeof CLOSED_SOURCE_PROVIDERS)[number];
type PublicJobWithSourceProvider = PublicAlgoliaImportJob & { sourceProvider: SourceProvider };

const JOB_FIXTURE: PublicJobWithSourceProvider = {
	id: 'job_123',
	sourceProvider: 'algolia',
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

function loadEvent(
	sourceProvider: SourceProvider = 'algolia',
	jobId = 'job_123',
	token = 'jwt-secret-canary'
) {
	return loadEventWithSourceProviderQuery(sourceProvider, jobId, token);
}

function loadEventWithSourceProviderQuery(
	sourceProvider: string | null,
	jobId = 'job_123',
	token = 'jwt-secret-canary'
) {
	const url = new URL(`http://localhost/console/migrate/${encodeURIComponent(jobId)}`);
	if (sourceProvider !== null) {
		url.searchParams.set('source_provider', sourceProvider);
	}
	return {
		params: { jobId },
		url,
		locals: localsWithToken(token)
	} as never;
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
		getMigrationImportJobMock.mockImplementation(async (sourceProvider: SourceProvider) => ({
			...JOB_FIXTURE,
			sourceProvider
		}));
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue(availableResponse());
		getMigrationAvailabilityMock.mockResolvedValue(availableResponse());
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'loads the %s job through the provider-scoped detail client and derives capabilities from the single availability source',
		async (sourceProvider) => {
			const expectedJob = { ...JOB_FIXTURE, sourceProvider };
			const result = (await load(loadEvent(sourceProvider))) as Record<string, unknown>;

			expect(getMigrationImportJobMock).toHaveBeenCalledOnce();
			expect(getMigrationImportJobMock).toHaveBeenCalledWith(sourceProvider, 'job_123');
			expect(getAlgoliaImportJobMock).not.toHaveBeenCalled();
			expect(getMigrationAvailabilityMock).toHaveBeenCalledWith(sourceProvider);
			expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
			expect(result).toEqual({
				job: expectedJob,
				capabilities: AVAILABLE_CAPABILITIES
			});
		}
	);

	it.each([
		['unknown', 'elastic'],
		['path-shaped', '../typesense'],
		['missing', null]
	] as const)(
		'rejects %s source_provider query values before invoking a detail API client',
		async (_label, sourceProvider) => {
			await expect(load(loadEventWithSourceProviderQuery(sourceProvider))).rejects.toEqual(
				expect.objectContaining({
					status: 400,
					body: {
						message: 'source_provider_unsupported'
					}
				})
			);
			expect(getMigrationImportJobMock).not.toHaveBeenCalled();
			expect(getAlgoliaImportJobMock).not.toHaveBeenCalled();
			expect(getMigrationAvailabilityMock).not.toHaveBeenCalled();
			expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
		}
	);

	it('serializes the job fixture without leaking tokens, credentials, or resume keys', async () => {
		const result = await load(loadEvent());
		const serialized = JSON.stringify(result);

		for (const canary of SECRET_CANARIES) {
			expect(serialized).not.toContain(canary);
		}
	});

	it('fails capabilities closed when availability reports unavailable', async () => {
		getMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'unavailable',
			capabilities: { cancel: false, resume: false, replace: false }
		});

		const result = (await load(loadEvent())) as Record<string, unknown>;

		expect(result).toEqual({
			job: JOB_FIXTURE,
			capabilities: { cancel: false, resume: false, replace: false }
		});
	});

	it('fails capabilities closed on a non-auth availability failure while still serving the job', async () => {
		getMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(500, 'boom'));

		const result = (await load(loadEvent())) as Record<string, unknown>;

		expect(result).toEqual({
			job: JOB_FIXTURE,
			capabilities: { cancel: false, resume: false, replace: false }
		});
	});

	it('maps a 401 on the job fetch through the dashboard auth contract', async () => {
		getMigrationImportJobMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load(loadEvent());

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({ _authSessionExpired: true, error: 'Unauthorized' })
			})
		);
		expect(getMigrationAvailabilityMock).not.toHaveBeenCalled();
		expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
	});

	it('maps a 403 on the availability fetch through the dashboard auth contract', async () => {
		getMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await load(loadEvent());

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({ _authSessionExpired: true })
			})
		);
	});

	it('throws a 404 for a missing job', async () => {
		getMigrationImportJobMock.mockRejectedValue(new ApiRequestError(404, 'not found'));

		await expect(load(loadEvent('algolia', 'ghost'))).rejects.toMatchObject({ status: 404 });
	});

	it('rejects path-traversal job ids before calling the control plane', async () => {
		await expect(load(loadEvent('algolia', '../admin'))).rejects.toMatchObject({ status: 404 });

		expect(getMigrationImportJobMock).not.toHaveBeenCalled();
		expect(getAlgoliaImportJobMock).not.toHaveBeenCalled();
		expect(getMigrationAvailabilityMock).not.toHaveBeenCalled();
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
		cancelMigrationImportJobMock.mockResolvedValue({ ...JOB_FIXTURE, status: 'cancelling' });
		resumeMigrationImportJobMock.mockResolvedValue({ ...JOB_FIXTURE, status: 'resuming' });
	});

	it('exports only the cancel and resume job actions', () => {
		expect(Object.keys(actions).sort()).toEqual(['cancel', 'resume']);
	});

	it('cancel calls the neutral Algolia cancellation wrapper with the path job id and server token only', async () => {
		const result = await actions.cancel({
			params: { jobId: 'job_123' },
			request: actionRequest({ source_provider: 'algolia' }),
			locals: localsWithToken()
		} as never);

		expect(cancelMigrationImportJobMock).toHaveBeenCalledOnce();
		expect(cancelMigrationImportJobMock).toHaveBeenCalledWith('algolia', 'job_123');
		expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
	});

	it('resume parses the fresh API key and forwards it through the neutral Algolia wrapper without echoing it back', async () => {
		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({
				source_provider: 'algolia',
				apiKey: 'resume-secret-key-canary-0007'
			}),
			locals: localsWithToken()
		} as never);

		expect(resumeMigrationImportJobMock).toHaveBeenCalledOnce();
		expect(resumeMigrationImportJobMock).toHaveBeenCalledWith('algolia', 'job_123', {
			apiKey: 'resume-secret-key-canary-0007'
		});
		const serialized = JSON.stringify(result);
		expect(serialized).not.toContain('resume-secret-key-canary-0007');
		expect(serialized).not.toContain('jwt-secret-canary');
	});

	it('rejects a blank resume API key before calling the control plane', async () => {
		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({ source_provider: 'algolia', apiKey: '   ' }),
			locals: localsWithToken()
		} as never);

		expect(resumeMigrationImportJobMock).not.toHaveBeenCalled();
		expect(result).toMatchObject({ status: 400 });
	});

	it('maps a 401 cancel failure through the dashboard auth contract', async () => {
		cancelMigrationImportJobMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.cancel({
			params: { jobId: 'job_123' },
			request: actionRequest({ source_provider: 'algolia' }),
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
		resumeMigrationImportJobMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({
				source_provider: 'algolia',
				apiKey: 'resume-secret-key-canary-0007'
			}),
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

	it.each(['algolia', 'meilisearch', 'typesense'] as const)(
		'cancel forwards selected source_provider %s to the neutral job API client method',
		async (sourceProvider) => {
			await actions.cancel({
				params: { jobId: 'job_123' },
				request: actionRequest({ source_provider: sourceProvider }),
				locals: localsWithToken()
			} as never);

			expect(cancelMigrationImportJobMock).toHaveBeenCalledOnce();
			expect(cancelMigrationImportJobMock).toHaveBeenCalledWith(sourceProvider, 'job_123');
			expect(cancelAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'cancel rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const result = await actions.cancel({
				params: { jobId: 'job_123' },
				request: actionRequest({ source_provider: sourceProvider }),
				locals: localsWithToken()
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			expect(cancelMigrationImportJobMock).not.toHaveBeenCalled();
			expect(cancelAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each(['algolia', 'meilisearch', 'typesense'] as const)(
		'resume forwards selected source_provider %s and fresh key to the neutral job API client method',
		async (sourceProvider) => {
			await actions.resume({
				params: { jobId: 'job_123' },
				request: actionRequest({
					source_provider: sourceProvider,
					apiKey: `${sourceProvider}-resume-secret-key-canary`
				}),
				locals: localsWithToken()
			} as never);

			expect(resumeMigrationImportJobMock).toHaveBeenCalledOnce();
			expect(resumeMigrationImportJobMock).toHaveBeenCalledWith(sourceProvider, 'job_123', {
				apiKey: `${sourceProvider}-resume-secret-key-canary`
			});
			expect(resumeAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'resume rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const result = await actions.resume({
				params: { jobId: 'job_123' },
				request: actionRequest({
					source_provider: sourceProvider,
					apiKey: 'invalid-provider-resume-secret-key-canary'
				}),
				locals: localsWithToken()
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			expect(resumeMigrationImportJobMock).not.toHaveBeenCalled();
			expect(resumeAlgoliaImportJobMock).not.toHaveBeenCalled();
			expect(JSON.stringify(result)).not.toContain('invalid-provider-resume-secret-key-canary');
		}
	);

	it.each([
		{
			actionName: 'cancel',
			invoke: () =>
				actions.cancel({
					params: { jobId: 'job_123' },
					request: actionRequest(),
					locals: localsWithToken()
				} as never),
			clientMocks: [cancelMigrationImportJobMock, cancelAlgoliaImportJobMock]
		},
		{
			actionName: 'resume',
			invoke: () =>
				actions.resume({
					params: { jobId: 'job_123' },
					request: actionRequest({ apiKey: 'missing-provider-resume-key-canary' }),
					locals: localsWithToken()
				} as never),
			clientMocks: [resumeMigrationImportJobMock, resumeAlgoliaImportJobMock]
		}
	])(
		'$actionName rejects a missing source_provider before invoking a migration client method',
		async ({ invoke, clientMocks }) => {
			const result = await invoke();

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			for (const clientMock of clientMocks) {
				expect(clientMock).not.toHaveBeenCalled();
			}
			expect(JSON.stringify(result)).not.toContain('missing-provider-resume-key-canary');
		}
	);

	it('returns source_provider_unsupported as a neutral typed action failure', async () => {
		resumeMigrationImportJobMock.mockRejectedValue(
			new ApiRequestError(400, 'source_provider_unsupported', {
				body: {
					error: 'source_provider_unsupported',
					code: 'source_provider_unsupported'
				}
			})
		);

		const result = await actions.resume({
			params: { jobId: 'job_123' },
			request: actionRequest({
				source_provider: 'typesense',
				apiKey: 'typesense-resume-secret-key-canary'
			}),
			locals: localsWithToken()
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					error: 'source_provider_unsupported',
					code: 'source_provider_unsupported'
				}
			})
		);
		expect(JSON.stringify(result)).not.toContain('migration_provider_unsupported');
		expect(JSON.stringify(result)).not.toContain('typesense-resume-secret-key-canary');
	});
});
