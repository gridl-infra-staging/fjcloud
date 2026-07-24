import { error, redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import type { Experiment, ExperimentResults } from '$lib/api/types';
import { ApiRequestError } from '$lib/api/client';
import { normalizeExperimentList } from '$lib/experiment_helpers';
import { createApiClient } from '$lib/server/api';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	isDashboardSessionExpiredError
} from '$lib/server/auth-action-errors';
import { load as loadIndexDetailData } from '../../+page.server';

function parseExperimentId(rawId: string): number {
	if (!/^\d+$/.test(rawId)) {
		throw error(404, 'Experiment not found');
	}

	const parsed = Number(rawId);
	if (!Number.isSafeInteger(parsed)) {
		throw error(404, 'Experiment not found');
	}

	return parsed;
}

function experimentBackHref(indexName: string | undefined): string {
	if (!indexName || indexName.trim().length === 0) {
		return '../../?tab=experiments';
	}
	return `/console/indexes/${encodeURIComponent(indexName)}?tab=experiments`;
}

function rethrowExperimentFallbackFailure(loadError: unknown): never {
	if (isDashboardSessionExpiredError(loadError)) {
		throw redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
	}
	if (loadError instanceof ApiRequestError && loadError.status === 404) {
		throw error(404, 'Experiment not found');
	}
	throw error(500, 'Failed to load experiment');
}

export const load: PageServerLoad = async ({ parent, params, locals, url }) => {
	const parentDataCandidate = (await parent()) as Record<string, unknown>;
	const parentData = (
		parentDataCandidate.index
			? parentDataCandidate
			: ((await loadIndexDetailData({
					locals,
					params: { name: params.name },
					url
				} as never)) as Record<string, unknown>)
	) as Record<string, unknown>;
	const experiments = normalizeExperimentList(parentData.experiments);
	const experimentId = parseExperimentId(params.experimentId);
	let selectedExperiment =
		experiments.abtests.find((experiment) => experiment.abTestID === experimentId) ?? null;

	const experimentResultsMap = (parentData.experimentResults ?? {}) as Record<
		string,
		ExperimentResults
	>;
	let selectedExperimentResults: ExperimentResults | null =
		experimentResultsMap[String(experimentId)] ?? null;

	if (!selectedExperiment) {
		if (!params.name) {
			throw error(404, 'Experiment not found');
		}
		const api = createApiClient(locals.user?.token);
		try {
			selectedExperiment = await api.getExperiment(params.name, experimentId);
		} catch (loadError) {
			rethrowExperimentFallbackFailure(loadError);
		}
		if (!selectedExperimentResults) {
			try {
				selectedExperimentResults = await api.getExperimentResults(params.name, experimentId);
			} catch (loadError) {
				if (isDashboardSessionExpiredError(loadError)) {
					throw redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
				}
				selectedExperimentResults = null;
			}
		}
	}

	return {
		...parentData,
		selectedExperiment: selectedExperiment as Experiment,
		selectedExperimentResults,
		experimentDetailBackHref: experimentBackHref(params.name)
	};
};
