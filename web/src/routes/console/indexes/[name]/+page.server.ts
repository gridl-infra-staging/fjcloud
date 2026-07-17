import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { ApiRequestError } from '$lib/api/client';
import { DEFAULT_INTERNAL_REGIONS } from '$lib/format';
import { executeIndexSearch } from '$lib/server/index-search';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';
import { declareWinnerSettingsDiff } from '$lib/experiment_helpers';
import {
	browseDictionaryEntriesAction,
	clearDictionaryEntriesAction,
	deleteDictionaryEntryAction,
	loadDictionariesPayloadResult,
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
	clearRulesAction,
	deleteRuleAction,
	loadRulesPayloadForQuery,
	saveRuleAction
} from './rules-management.server';
import { refreshEventsAction } from './events-management.server';
import {
	clearSynonymsAction,
	deleteSynonymAction,
	loadSynonymsPayload,
	saveSynonymAction
} from './synonyms-management.server';
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
import { loadMetricsPayload } from './metrics-management.server';
import { metricsDependencyKey } from './metrics-keys';
import {
	deleteQsConfigAction,
	rebuildQsConfigAction,
	saveQsConfigAction
} from './suggestions-management.server';
import {
	deletePersonalizationProfileAction,
	deletePersonalizationStrategyAction,
	getPersonalizationProfileAction,
	savePersonalizationStrategyAction
} from './personalization-management.server';
import type {
	PersonalizationStrategy,
	ConcludeExperimentRequest,
	CreateExperimentRequest,
	Experiment,
	ExperimentResults,
	DebugEventsResponse
} from '$lib/api/types';

function failForDashboardAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	return sessionFailure ?? fail(400, payload);
}

function normalizeTransientBackendFailure(message: string): string {
	if (/fetch failed/i.test(message)) {
		return 'backend temporarily unavailable';
	}
	return message;
}

type ExperimentLifecycleAction = 'start' | 'stop' | 'delete' | 'conclude';

function loadExperimentMutationFailure(message: string) {
	return fail(400, { experimentError: message });
}

async function loadExperimentForLifecycleAction(
	api: ReturnType<typeof createApiClient>,
	indexName: string,
	experimentID: number
): Promise<Experiment> {
	return await api.getExperiment(indexName, experimentID);
}

function ensureExperimentActionAllowed(
	action: ExperimentLifecycleAction,
	experiment: Experiment
): string | null {
	switch (action) {
		case 'start':
			return experiment.status === 'created' ? null : 'Only created experiments can be started.';
		case 'stop':
			return experiment.status === 'running' || experiment.status === 'active'
				? null
				: 'Only active experiments can be stopped.';
		case 'delete':
			return experiment.status === 'running' || experiment.status === 'active'
				? 'Active experiments must be stopped before they can be deleted.'
				: null;
		case 'conclude':
			return experiment.status === 'running' || experiment.status === 'active'
				? null
				: 'Only active experiments can be concluded.';
	}
}

export const load: PageServerLoad = async ({ locals, params, url, depends }) => {
	depends?.(metricsDependencyKey(params.name));

	const api = createApiClient(locals.user?.token);
	const { name } = params;
	const synonymQuery = url.searchParams.get('q') ?? '';
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
			metricsPayload,
			experiments,
			debugEventsResult,
			allIndexes
		] = await Promise.all([
			retryTransientDashboardApiRequest(() => api.getIndex(name)),
			api.getIndexSettings(name).catch(() => null),
			api.listReplicas(name).catch(() => []),
			api.getInternalRegions().catch(() => DEFAULT_INTERNAL_REGIONS),
			api
				.browseObjects(name, { hitsPerPage: DEFAULT_DOCUMENT_HITS_PER_PAGE, query: '' })
				.catch(() => null),
			loadRulesPayloadForQuery(api, name, url.searchParams.get('q') ?? ''),
			loadSynonymsPayload(api, name, synonymQuery),
			api.getPersonalizationStrategy(name).catch((): PersonalizationStrategy | null => null),
			api.getQsConfig(name).catch(() => null),
			api.getQsStatus(name).catch(() => null),
			loadAnalyticsPayload(api, name, url.searchParams.get('period')),
			loadMetricsPayload(api, name),
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
				})),
			api.getIndexes().catch(() => [])
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

		const [dictionariesResult, securitySourcesResult] = await Promise.all([
			loadDictionariesPayloadResult(
				api,
				name,
				url.searchParams.get('dict'),
				url.searchParams.get('lang'),
				url.searchParams.get('q')
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
			rawIndexName: params.name,
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
			metrics: metricsPayload.metrics,
			metricsError: metricsPayload.error,
			debugEvents: debugEventsResult.debugEvents,
			eventsLoadError: debugEventsResult.eventsLoadError,
			dictionaries: dictionariesResult.payload,
			dictionaryBrowseError: dictionariesResult.requestError ?? '',
			securitySources: securitySourcesResult.securitySources,
			securitySourcesLoadError: securitySourcesResult.securitySourcesLoadError,
			allIndexes
		};
	} catch (e) {
		if (isDashboardSessionExpiredError(e)) {
			throw redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (e instanceof ApiRequestError && e.status === 404) {
			throw error(404, 'Index not found');
		}
		throw error(500, 'Failed to load index');
	}
};

export const actions: Actions = {
	restoreIndex: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			await api.restoreIndex(params.name);
			return { restoreStarted: true };
		} catch (e) {
			return failForDashboardAction(e, {
				restoreError: errorMessage(e, 'Failed to restore index')
			});
		}
	},
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
		return saveSynonymAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deleteSynonym: async ({ request, locals, params }) => {
		return deleteSynonymAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	clearSynonyms: async ({ request, locals, params }) => {
		return clearSynonymsAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
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
	clearDictionaryEntries: async ({ request, locals, params }) => {
		return clearDictionaryEntriesAction({
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
		fetchAnalyticsConversionRateAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		}),
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
		return savePersonalizationStrategyAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deletePersonalizationStrategy: async ({ locals, params }) => {
		return deletePersonalizationStrategyAction({
			indexName: params.name,
			token: locals.user?.token
		});
	},
	getPersonalizationProfile: async ({ request, locals, params }) => {
		return getPersonalizationProfileAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deletePersonalizationProfile: async ({ request, locals, params }) => {
		return deletePersonalizationProfileAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
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
		return saveQsConfigAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
	},
	deleteQsConfig: async ({ locals, params }) => {
		return deleteQsConfigAction({
			indexName: params.name,
			token: locals.user?.token
		});
	},
	rebuildQsConfig: async ({ locals, params }) => {
		return rebuildQsConfigAction({
			indexName: params.name,
			token: locals.user?.token
		});
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
			const experiment = await loadExperimentForLifecycleAction(api, params.name, experimentID);
			const validationError = ensureExperimentActionAllowed('delete', experiment);
			if (validationError) {
				return loadExperimentMutationFailure(validationError);
			}
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
			const experiment = await loadExperimentForLifecycleAction(api, params.name, experimentID);
			const validationError = ensureExperimentActionAllowed('start', experiment);
			if (validationError) {
				return loadExperimentMutationFailure(validationError);
			}
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
			const experiment = await loadExperimentForLifecycleAction(api, params.name, experimentID);
			const validationError = ensureExperimentActionAllowed('stop', experiment);
			if (validationError) {
				return loadExperimentMutationFailure(validationError);
			}
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
			const experiment = await loadExperimentForLifecycleAction(api, params.name, experimentID);
			const validationError = ensureExperimentActionAllowed('conclude', experiment);
			if (validationError) {
				return loadExperimentMutationFailure(validationError);
			}
			if (conclusion.promoted && !declareWinnerSettingsDiff(experiment).canPromote) {
				return loadExperimentMutationFailure(
					'Winner promotion is only allowed when the experiment changes base-index settings.'
				);
			}
			await api.concludeExperiment(params.name, experimentID, conclusion);
			return { experimentConcluded: true };
		} catch (e) {
			return failForDashboardAction(e, {
				experimentError: errorMessage(e, 'Failed to conclude experiment')
			});
		}
	},
	refreshEvents: async ({ request, locals, params }) => {
		return refreshEventsAction({
			request,
			indexName: params.name,
			token: locals.user?.token
		});
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
