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
	loadSecuritySourcesPayload
} from './security-sources.server';
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
import type {
	Rule,
	RuleSearchResponse,
	Synonym,
	SynonymSearchResponse,
	PersonalizationStrategy,
	PersonalizationProfile,
	RecommendationsBatchRequest,
	RecommendationsBatchResponse,
	IndexChatRequest,
	IndexChatResponse,
	QsConfig,
	AnalyticsDateRangeParams,
	ConcludeExperimentRequest,
	CreateExperimentRequest,
	ExperimentResults,
	DebugEventsResponse
} from '$lib/api/types';


const PERIOD_TO_DAYS: Record<string, number> = {
	'7d': 7,
	'30d': 30,
	'90d': 90
};

function failForDashboardAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

function toIsoDateUtc(date: Date): string {
	return date.toISOString().slice(0, 10);
}

function resolveAnalyticsPeriod(rawPeriod: string | null): '7d' | '30d' | '90d' {
	if (rawPeriod === '30d' || rawPeriod === '90d') return rawPeriod;
	return '7d';
}

function analyticsDateRange(period: '7d' | '30d' | '90d'): AnalyticsDateRangeParams {
	const days = PERIOD_TO_DAYS[period];
	const now = new Date();
	const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
	const start = new Date(end);
	start.setUTCDate(end.getUTCDate() - (days - 1));

	return {
		startDate: toIsoDateUtc(start),
		endDate: toIsoDateUtc(end)
	};
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function isTransientPreviewKeyFailure(error: unknown): boolean {
	if (!(error instanceof ApiRequestError)) {
		return false;
	}

	if (error.status === 404 || error.status === 429 || error.status === 500 || error.status === 503) {
		return true;
	}

	return error.status === 400 && error.message.toLowerCase().includes('endpoint not ready yet');
}

export const load: PageServerLoad = async ({ locals, params, url }) => {
	const api = createApiClient(locals.user?.token);
	const { name } = params;
	const analyticsPeriod = resolveAnalyticsPeriod(url.searchParams.get('period'));
	const analyticsParams = analyticsDateRange(analyticsPeriod);
	const analyticsTopParams: AnalyticsDateRangeParams = { ...analyticsParams, limit: 10 };
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
			searchCount,
			noResultRate,
			topSearches,
			noResults,
				analyticsStatus,
				experiments,
				debugEvents
			] = await Promise.all([
			retryTransientDashboardApiRequest(() => api.getIndex(name)),
			api.getIndexSettings(name).catch(() => null),
			api.listReplicas(name).catch(() => []),
			api.getInternalRegions().catch(() => []),
			api
				.browseObjects(name, { hitsPerPage: DEFAULT_DOCUMENT_HITS_PER_PAGE, query: '' })
				.catch(() => null),
			api.searchRules(name).catch((): RuleSearchResponse | null => null),
			api.searchSynonyms(name).catch((): SynonymSearchResponse | null => null),
			api.getPersonalizationStrategy(name).catch((): PersonalizationStrategy | null => null),
			api.getQsConfig(name).catch(() => null),
			api.getQsStatus(name).catch(() => null),
			api.getAnalyticsSearchCount(name, analyticsParams).catch(() => null),
			api.getAnalyticsNoResultRate(name, analyticsParams).catch(() => null),
			api.getAnalyticsTopSearches(name, analyticsTopParams).catch(() => null),
			api.getAnalyticsNoResults(name, analyticsTopParams).catch(() => null),
			api.getAnalyticsStatus(name).catch(() => null),
			api.listExperiments(name).catch(() => null),
				api
					.getDebugEvents(name, {
						limit: 100,
						from: defaultEventsFrom,
						until: defaultEventsUntil
					})
					.catch((): DebugEventsResponse | null => null)
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

			const [dictionaries, securitySources] = await Promise.all([
				loadDictionariesPayload(
					api,
					name,
					url.searchParams.get('dictionary'),
					url.searchParams.get('dictionaryLang')
				),
				loadSecuritySourcesPayload(api, name)
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
			searchCount,
			noResultRate,
			topSearches,
			noResults,
			analyticsStatus,
				experiments,
				experimentResults,
				analyticsPeriod,
				debugEvents,
				dictionaries,
				securitySources
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
			return failForDashboardAction(e, { replicaError: errorMessage(e, 'Failed to create replica') });
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
			return failForDashboardAction(e, { settingsError: errorMessage(e, 'Failed to save settings') });
		}
	},
	saveRule: async ({ request, locals, params }) => {
		const data = await request.formData();
		const objectID = (data.get('objectID') as string)?.trim();
		const rawRule = (data.get('rule') as string)?.trim();
		if (!objectID) return fail(400, { ruleError: 'objectID is required' });
		if (!rawRule) return fail(400, { ruleError: 'Rule JSON is required' });

		let rule: Rule;
		try {
			rule = parseJsonObject<Rule>(rawRule, 'rule');
		} catch (e) {
			return failForDashboardAction(e, { ruleError: errorMessage(e, 'Invalid rule JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.saveRule(params.name, objectID, rule);
			return { ruleSaved: true };
		} catch (e) {
			return failForDashboardAction(e, { ruleError: errorMessage(e, 'Failed to save rule') });
		}
	},
	deleteRule: async ({ request, locals, params }) => {
		const data = await request.formData();
		const objectID = (data.get('objectID') as string)?.trim();
		if (!objectID) return fail(400, { ruleError: 'objectID is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteRule(params.name, objectID);
			return { ruleDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, { ruleError: errorMessage(e, 'Failed to delete rule') });
		}
	},
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
			return failForDashboardAction(e, { synonymError: errorMessage(e, 'Failed to delete synonym') });
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
			return failForDashboardAction(e, { personalizationError: errorMessage(e, 'Invalid strategy JSON') });
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
			const profile: PersonalizationProfile = await api.getPersonalizationProfile(params.name, userToken);
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
		const data = await request.formData();
		const rawRequest = (data.get('request') as string)?.trim();
		if (!rawRequest) return fail(400, { recommendationsError: 'Recommendations JSON is required' });

		let requestBody: RecommendationsBatchRequest;
		try {
			requestBody = parseJsonObject<RecommendationsBatchRequest>(rawRequest, 'request');
			if (!Array.isArray(requestBody.requests)) {
				throw new Error('request.requests must be an array');
			}
		} catch (e) {
			return failForDashboardAction(e, { recommendationsError: errorMessage(e, 'Invalid recommendations JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const recommendationsResponse: RecommendationsBatchResponse = await api.recommend(
				params.name,
				requestBody
			);
			return { recommendationsResponse };
		} catch (e) {
			return failForDashboardAction(e, {
				recommendationsError: errorMessage(e, 'Failed to fetch recommendations')
			});
		}
	},
	chat: async ({ request, locals, params }) => {
		const data = await request.formData();
		const query = (data.get('query') as string)?.trim() ?? '';
		if (!query) return fail(400, { chatError: 'Query is required' });
		const conversationId = (data.get('conversationId') as string | null)?.trim() ?? '';

		const rawConversationHistory = (data.get('conversationHistory') as string | null)?.trim() ?? '';
		let conversationHistory: Record<string, unknown>[] = [];

		if (rawConversationHistory) {
			let parsedConversationHistory: unknown;
			try {
				parsedConversationHistory = JSON.parse(rawConversationHistory);
			} catch {
				return fail(400, {
					chatError: 'conversationHistory must be valid JSON',
					chatQuery: query
				});
			}

			if (
				!Array.isArray(parsedConversationHistory) ||
				parsedConversationHistory.some(
					(entry) => typeof entry !== 'object' || entry === null || Array.isArray(entry)
				)
			) {
				return fail(400, {
					chatError: 'conversationHistory must be a JSON array',
					chatQuery: query
				});
			}

			conversationHistory = parsedConversationHistory as Record<string, unknown>[];
		}

		const requestBody: IndexChatRequest = {
			query,
			conversationHistory
		};
		if (conversationId) {
			requestBody.conversationId = conversationId;
		}

		const api = createApiClient(locals.user?.token);
		try {
			const chatResponse: IndexChatResponse = await api.chat(params.name, requestBody);
			return { chatResponse, chatQuery: query };
		} catch (e) {
			return failForDashboardAction(e, {
				chatError: errorMessage(e, 'Failed to get chat response'),
				chatQuery: query
			});
		}
	},
	saveQsConfig: async ({ request, locals, params }) => {
		const data = await request.formData();
		const rawConfig = (data.get('config') as string)?.trim();
		if (!rawConfig) return fail(400, { qsConfigError: 'Suggestions config JSON is required' });

		let config: QsConfig;
		try {
			config = parseJsonObject<QsConfig>(rawConfig, 'config');
		} catch (e) {
			return failForDashboardAction(e, { qsConfigError: errorMessage(e, 'Invalid suggestions config JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.saveQsConfig(params.name, config);
			return { qsConfigSaved: true };
		} catch (e) {
			return failForDashboardAction(e, { qsConfigError: errorMessage(e, 'Failed to save suggestions config') });
		}
	},
	deleteQsConfig: async ({ locals, params }) => {
		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteQsConfig(params.name);
			return { qsConfigDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, { qsConfigError: errorMessage(e, 'Failed to delete suggestions config') });
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
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid experiment JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.createExperiment(params.name, experiment);
			return { experimentCreated: true };
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Failed to create experiment') });
		}
	},
	deleteExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid experiment ID') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteExperiment(params.name, experimentID);
			return { experimentDeleted: true };
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Failed to delete experiment') });
		}
	},
	startExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid experiment ID') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.startExperiment(params.name, experimentID);
			return { experimentStarted: true };
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Failed to start experiment') });
		}
	},
	stopExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid experiment ID') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.stopExperiment(params.name, experimentID);
			return { experimentStopped: true };
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Failed to stop experiment') });
		}
	},
	concludeExperiment: async ({ request, locals, params }) => {
		const data = await request.formData();
		let experimentID: number;
		try {
			experimentID = parsePositiveInt(data.get('experimentID'), 'experimentID');
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid experiment ID') });
		}

		const rawConclusion = (data.get('conclusion') as string)?.trim();
		if (!rawConclusion) return fail(400, { experimentError: 'Conclusion JSON is required' });

		let conclusion: ConcludeExperimentRequest;
		try {
			conclusion = parseJsonObject<ConcludeExperimentRequest>(rawConclusion, 'conclusion');
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Invalid conclusion JSON') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.concludeExperiment(params.name, experimentID, conclusion);
			return { experimentConcluded: true };
		} catch (e) {
			return failForDashboardAction(e, { experimentError: errorMessage(e, 'Failed to conclude experiment') });
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
				limit = parsePositiveInt(limitRaw, 'limit');
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
			return failForDashboardAction(e, { replicaError: errorMessage(e, 'Failed to remove replica') });
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
