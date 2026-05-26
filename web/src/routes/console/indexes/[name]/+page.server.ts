import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { ApiRequestError } from '$lib/api/client';
import { buildTenantScopedIndexUid } from '$lib/flapjack-index';
import { executeIndexSearch } from '$lib/server/index-search';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';
import {
	browseDictionaryEntriesAction,
	deleteDictionaryEntryAction,
	loadDictionariesPayload,
	saveDictionaryEntryAction
} from './dictionary-management.server';
import {
	appendSecuritySourceAction,
	deleteSecuritySourceAction,
	emptySecuritySourcesPayload,
	loadSecuritySourcesPayload
} from './security-sources.server';
import { recommendAction } from './recommendations-management.server';
import { chatAction } from './chat-management.server';
import {
	addDocumentAction,
	browseDocumentsAction,
	DEFAULT_DOCUMENT_HITS_PER_PAGE,
	deleteDocumentAction,
	errorMessage,
	parseJsonObject,
	parsePositiveInt,
	normalizeDocumentsBrowseResponse,
	uploadDocumentsAction
} from './document-management.server';
import {
	fetchAnalyticsConversionRateAction,
	fetchAnalyticsCountriesAction,
	fetchAnalyticsDevicesAction,
	fetchAnalyticsFiltersAction,
	loadAnalyticsPayload
} from './analytics-management.server';
import type {
	Synonym,
	SynonymSearchResponse,
	PersonalizationStrategy,
	PersonalizationProfile,
	QsConfig,
	ConcludeExperimentRequest,
	CreateExperimentRequest,
	ExperimentResults,
	DebugEventsResponse
} from '$lib/api/types';

const MAX_EVENTS_REFRESH_LIMIT = 1000;

function failForDashboardAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	return sessionFailure ?? fail(400, payload);
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

function isTransientPreviewKeyFailure(error: unknown): boolean {
	if (!(error instanceof ApiRequestError)) {
		return false;
	}

	if (
		error.status === 404 ||
		error.status === 429 ||
		error.status === 500 ||
		error.status === 503
	) {
		return true;
	}

	return error.status === 400 && error.message.toLowerCase().includes('endpoint not ready yet');
}

export const load: PageServerLoad = async ({ locals, params, url }) => {
	const api = createApiClient(locals.user?.token);
	const { name } = params;
	const nowMs = Date.now();
	const defaultEventsUntil = nowMs;
	const defaultEventsFrom = nowMs - 24 * 60 * 60 * 1000;

	try {
		const [
			index,
			settings,
			replicas,
			regions,
			documents,
			rules,
			synonyms,
			personalizationStrategy,
			qsConfig,
			qsStatus,
			analyticsPayload,
			experiments,
			debugEventsResult
		] = await Promise.all([
			retryTransientDashboardApiRequest(() => api.getIndex(name)),
			api.getIndexSettings(name).catch(() => null),
			api.listReplicas(name).catch(() => []),
			api.getInternalRegions().catch(() => []),
			api
				.browseObjects(name, { hitsPerPage: DEFAULT_DOCUMENT_HITS_PER_PAGE, query: '' })
				.catch(() => null),
			loadRulesPayloadForQuery(api, name, url.searchParams.get('q') ?? ''),
			api.searchSynonyms(name).catch((): SynonymSearchResponse | null => null),
			api.getPersonalizationStrategy(name).catch((): PersonalizationStrategy | null => null),
			api.getQsConfig(name).catch(() => null),
			api.getQsStatus(name).catch(() => null),
			loadAnalyticsPayload(api, name, url.searchParams.get('period')),
			api.listExperiments(name).catch(() => null),
			api
				.getDebugEvents(name, {
					limit: 100,
					from: defaultEventsFrom,
					until: defaultEventsUntil
				})
				.then((debugEvents) => ({
					debugEvents,
					eventsLoadError: ''
				}))
				.catch((loadError) => ({
					debugEvents: null as DebugEventsResponse | null,
					eventsLoadError: errorMessage(loadError, 'Failed to load events')
				}))
		]);

		const experimentResults: Record<string, ExperimentResults> = {};
		if (experiments?.abtests?.length) {
			const resultEntries = await Promise.all(
				experiments.abtests.map(async (experiment) => {
					try {
						const result = await api.getExperimentResults(name, experiment.abTestID);
						return [String(experiment.abTestID), result] as const;
					} catch {
						return null;
					}
				})
			);

			for (const entry of resultEntries) {
				if (!entry) continue;
				experimentResults[entry[0]] = entry[1];
			}
		}

		const [dictionaries, securitySourcesResult] = await Promise.all([
			loadDictionariesPayload(
				api,
				name,
				url.searchParams.get('dictionary'),
				url.searchParams.get('dictionaryLang')
			),
			loadSecuritySourcesPayload(api, name, { allowFallbackOnError: false })
				.then((securitySources) => ({
					securitySources,
					securitySourcesLoadError: ''
				}))
				.catch((loadError) => ({
					securitySources: emptySecuritySourcesPayload(),
					securitySourcesLoadError: errorMessage(loadError, 'Failed to load security sources')
				}))
		]);

		return {
			index,
			settings,
			replicas,
			regions,
			documents: normalizeDocumentsBrowseResponse(documents, ''),
			rules,
			synonyms,
			personalizationStrategy,
			qsConfig,
			qsStatus,
			experiments,
			experimentResults,
			...analyticsPayload,
			debugEvents: debugEventsResult.debugEvents,
			eventsLoadError: debugEventsResult.eventsLoadError,
			dictionaries,
			securitySources: securitySourcesResult.securitySources,
			securitySourcesLoadError: securitySourcesResult.securitySourcesLoadError
		};
	} catch (e) {
		if (isDashboardSessionExpiredError(e)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (e instanceof ApiRequestError && e.status === 404) {
			error(404, 'Index not found');
		}
		error(500, 'Failed to load index');
	}
};

export const actions: Actions = {
	search: async ({ request, locals, params }) => {
		const data = await request.formData();
		const query = (data.get('query') as string)?.trim() ?? '';

		try {
			const result = await executeIndexSearch(locals.user?.token, params.name, { query });
			return { searchResult: result, query };
		} catch (e) {
			return failForDashboardAction(e, { searchError: errorMessage(e, 'Search failed'), query });
		}
	},
	createPreviewKey: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			let result: Awaited<ReturnType<typeof api.createIndexKey>> | null = null;
			for (let attempt = 0; attempt < 10; attempt++) {
				try {
					result = await api.createIndexKey(params.name, 'Search preview', ['search']);
					break;
				} catch (error) {
					if (!isTransientPreviewKeyFailure(error) || attempt === 9) {
						throw error;
					}
					await sleep(Math.min(2000 * (attempt + 1), 10_000));
				}
			}

			return {
				previewKey: result!.key,
				previewIndexName: buildTenantScopedIndexUid(locals.user?.customerId ?? '', params.name)
			};
		} catch (e) {
			const message = customerFacingErrorMessage(e, 'Failed to create preview key');
			return failForDashboardAction(e, { previewKeyError: message });
		}
	},
	createReplica: async ({ request, locals, params }) => {
		const data = await request.formData();
		const region = (data.get('region') as string)?.trim();
		if (!region) return fail(400, { replicaError: 'Region is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.createReplica(params.name, region);
			return { replicaCreated: true };
		} catch (e) {
			return failForDashboardAction(e, {
				replicaError: errorMessage(e, 'Failed to create replica')
			});
		}
	},
	saveSettings: async ({ request, locals, params }) => {
		const data = await request.formData();
		const rawSettings = (data.get('settings') as string)?.trim();
		if (!rawSettings) return fail(400, { settingsError: 'Settings JSON is required' });

		let settings: Record<string, unknown>;
		try {
			settings = parseJsonObject(rawSettings, 'settings');
		} catch (e) {
			return failForDashboardAction(e, { settingsError: errorMessage(e, 'Invalid settings JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.updateIndexSettings(params.name, settings);
			return { settingsSaved: true };
		} catch (e) {
			const message = normalizeTransientBackendFailure(errorMessage(e, 'Failed to save settings'));
			return failForDashboardAction(e, {
				settingsError: message
			});
		}
	},
	saveRule: async ({ request, locals, params }) =>
		saveRuleAction({ request, indexName: params.name, token: locals.user?.token }),
	deleteRule: async ({ request, locals, params }) =>
		deleteRuleAction({ request, indexName: params.name, token: locals.user?.token }),
	clearRules: async ({ locals, params }) =>
		clearRulesAction({ indexName: params.name, token: locals.user?.token }),
	saveSynonym: async ({ request, locals, params }) => {
		const data = await request.formData();
		const objectID = (data.get('objectID') as string)?.trim();
		const rawSynonym = (data.get('synonym') as string)?.trim();
		if (!objectID) return fail(400, { synonymError: 'objectID is required' });
		if (!rawSynonym) return fail(400, { synonymError: 'Synonym JSON is required' });

		let synonym: Synonym;
		try {
			synonym = parseJsonObject<Synonym>(rawSynonym, 'synonym');
		} catch (e) {
			return failForDashboardAction(e, { synonymError: errorMessage(e, 'Invalid synonym JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.saveSynonym(params.name, objectID, synonym);
			return { synonymSaved: true };
		} catch (e) {
			return failForDashboardAction(e, { synonymError: errorMessage(e, 'Failed to save synonym') });
		}
	},
	deleteSynonym: async ({ request, locals, params }) => {
		const data = await request.formData();
		const objectID = (data.get('objectID') as string)?.trim();
		if (!objectID) return fail(400, { synonymError: 'objectID is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteSynonym(params.name, objectID);
			return { synonymDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				synonymError: errorMessage(e, 'Failed to delete synonym')
			});
		}
	},
	uploadDocuments: async ({ request, locals, params }) => {
		return uploadDocumentsAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	addDocument: async ({ request, locals, params }) => {
		return addDocumentAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	browseDocuments: async ({ request, locals, params }) => {
		return browseDocumentsAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deleteDocument: async ({ request, locals, params }) => {
		return deleteDocumentAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	browseDictionaryEntries: async ({ request, locals, params }) => {
		return browseDictionaryEntriesAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	fetchAnalyticsDevices: ({ request, locals, params }) =>
		fetchAnalyticsDevicesAction({ request, indexName: params.name, token: locals.user?.token }),
	fetchAnalyticsCountries: ({ request, locals, params }) =>
		fetchAnalyticsCountriesAction({ request, indexName: params.name, token: locals.user?.token }),
	fetchAnalyticsFilters: ({ request, locals, params }) =>
		fetchAnalyticsFiltersAction({ request, indexName: params.name, token: locals.user?.token }),
	fetchAnalyticsConversionRate: ({ request, locals, params }) =>
		fetchAnalyticsConversionRateAction({ request, indexName: params.name, token: locals.user?.token }),
	saveDictionaryEntry: async ({ request, locals, params }) => {
		return saveDictionaryEntryAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deleteDictionaryEntry: async ({ request, locals, params }) => {
		return deleteDictionaryEntryAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	savePersonalizationStrategy: async ({ request, locals, params }) => {
		const data = await request.formData();
		const rawStrategy = (data.get('strategy') as string)?.trim();
		if (!rawStrategy) return fail(400, { personalizationError: 'Strategy JSON is required' });

		let strategy: PersonalizationStrategy;
		try {
			strategy = parseJsonObject<PersonalizationStrategy>(rawStrategy, 'strategy');
		} catch (e) {
			return failForDashboardAction(e, {
				personalizationError: errorMessage(e, 'Invalid strategy JSON')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.savePersonalizationStrategy(params.name, strategy);
			return { personalizationStrategySaved: true };
		} catch (e) {
			return failForDashboardAction(e, {
				personalizationError: errorMessage(e, 'Failed to save personalization strategy')
			});
		}
	},
	deletePersonalizationStrategy: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			await api.deletePersonalizationStrategy(params.name);
			return { personalizationStrategyDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				personalizationError: errorMessage(e, 'Failed to delete personalization strategy')
			});
		}
	},
	getPersonalizationProfile: async ({ request, locals, params }) => {
		const data = await request.formData();
		const userToken = (data.get('userToken') as string)?.trim();
		if (!userToken) return fail(400, { personalizationError: 'userToken is required' });

		const api = createApiClient(locals.user?.token);
		try {
			const profile: PersonalizationProfile = await api.getPersonalizationProfile(
				params.name,
				userToken
			);
			return { personalizationProfile: profile };
		} catch (e) {
			return failForDashboardAction(e, {
				personalizationError: errorMessage(e, 'Failed to load personalization profile')
			});
		}
	},
	deletePersonalizationProfile: async ({ request, locals, params }) => {
		const data = await request.formData();
		const userToken = (data.get('userToken') as string)?.trim();
		if (!userToken) return fail(400, { personalizationError: 'userToken is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deletePersonalizationProfile(params.name, userToken);
			return { personalizationProfileDeleted: true, personalizationProfile: null };
		} catch (e) {
			return failForDashboardAction(e, {
				personalizationError: errorMessage(e, 'Failed to delete personalization profile')
			});
		}
	},
	recommend: async ({ request, locals, params }) => {
		return recommendAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	chat: async ({ request, locals, params }) => {
		return chatAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	saveQsConfig: async ({ request, locals, params }) => {
		const data = await request.formData();
		const rawConfig = (data.get('config') as string)?.trim();
		if (!rawConfig) return fail(400, { qsConfigError: 'Suggestions config JSON is required' });

		let config: QsConfig;
		try {
			config = parseJsonObject<QsConfig>(rawConfig, 'config');
		} catch (e) {
			return failForDashboardAction(e, {
				qsConfigError: errorMessage(e, 'Invalid suggestions config JSON')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.saveQsConfig(params.name, config);
			return { qsConfigSaved: true };
		} catch (e) {
			return failForDashboardAction(e, {
				qsConfigError: errorMessage(e, 'Failed to save suggestions config')
			});
		}
	},
	deleteQsConfig: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteQsConfig(params.name);
			return { qsConfigDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				qsConfigError: errorMessage(e, 'Failed to delete suggestions config')
			});
		}
	},
	createExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		const rawExperiment = (data.get('experiment') as string)?.trim();
		if (!rawExperiment) return fail(400, { experimentError: 'Experiment JSON is required' });

		let experiment: CreateExperimentRequest;
		try {
			experiment = parseJsonObject<CreateExperimentRequest>(rawExperiment, 'experiment');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid experiment JSON')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await retryTransientDashboardApiRequest(() => api.createExperiment(params.name, experiment));
			return { experimentCreated: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to create experiment')
			});
		}
	},
	deleteExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid experiment ID')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteExperiment(params.name, experimentID);
			return { experimentDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to delete experiment')
			});
		}
	},
	startExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid experiment ID')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.startExperiment(params.name, experimentID);
			return { experimentStarted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to start experiment')
			});
		}
	},
	stopExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid experiment ID')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.stopExperiment(params.name, experimentID);
			return { experimentStopped: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to stop experiment')
			});
		}
	},
	concludeExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid experiment ID')
			});
		}

		const rawConclusion = (data.get('conclusion') as string)?.trim();
		if (!rawConclusion) return fail(400, { experimentError: 'Conclusion JSON is required' });

		let conclusion: ConcludeExperimentRequest;
		try {
			conclusion = parseJsonObject<ConcludeExperimentRequest>(rawConclusion, 'conclusion');
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Invalid conclusion JSON')
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.concludeExperiment(params.name, experimentID, conclusion);
			return { experimentConcluded: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to conclude experiment')
			});
		}
	},
	refreshEvents: async ({ request, locals, params }) => {
		const data = await request.formData();
		const eventType = (data.get('eventType') as string) || undefined;
		const status = (data.get('status') as string) || undefined;
		let limit = 100;
		let from: number | undefined;
		let until: number | undefined;
		try {
			const limitRaw = (data.get('limit') as string | null)?.trim() ?? '';
			if (limitRaw) {
				limit = Math.min(parsePositiveInt(limitRaw, 'limit'), MAX_EVENTS_REFRESH_LIMIT);
			}

			const fromRaw = (data.get('from') as string | null)?.trim() ?? '';
			if (fromRaw) {
				from = parsePositiveInt(fromRaw, 'from');
			}

			const untilRaw = (data.get('until') as string | null)?.trim() ?? '';
			if (untilRaw) {
				until = parsePositiveInt(untilRaw, 'until');
			}
		} catch (e) {
			return failForDashboardAction(e, { eventsError: errorMessage(e, 'Invalid event filters') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const result = await api.getDebugEvents(params.name, {
				eventType,
				status,
				limit,
				from,
				until
			});
			return { refreshedEvents: result };
		} catch (e) {
			return failForDashboardAction(e, { eventsError: errorMessage(e, 'Failed to fetch events') });
		}
	},
	deleteReplica: async ({ request, locals, params }) => {
		const data = await request.formData();
		const replicaId = data.get('replica_id') as string;
		if (!replicaId) return fail(400, { replicaError: 'Replica ID is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteReplica(params.name, replicaId);
			return { replicaDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				replicaError: errorMessage(e, 'Failed to remove replica')
			});
		}
	},
	delete: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteIndex(params.name);
			return { deleted: true };
		} catch (e) {
			return failForDashboardAction(e, { deleteError: errorMessage(e, 'Failed to delete index') });
		}
	},
	appendSecuritySource: async ({ request, locals, params }) => {
		return appendSecuritySourceAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deleteSecuritySource: async ({ request, locals, params }) => {
		return deleteSecuritySourceAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	}
};
