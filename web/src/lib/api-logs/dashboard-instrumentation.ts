/**
 * @module Maps SvelteKit form results and fetch requests to sanitized API log entries for dashboard instrumentation.
 */
/**
 * Dashboard instrumentation helpers for the browser-only API log store.
 *
 * Provides two adapters:
 *  1. deriveFormLogEntry() — maps SvelteKit enhanced form results to sanitized log entries
 *  2. deriveFetchLogEntry() — maps browser fetch request/response pairs to sanitized log entries
 *
 * Also exports extractFormAction() to replace the inline trackSubmittedPostAction logic.
 *
 * All output passes through the sanitization layer before reaching the store.
 */

import { sanitizeLogEntry, type RawLogCapture, type SanitizedLogEntry } from './sanitization';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type FormResult = Record<string, unknown>;

/** Input shape for the browser-fetch adapter. */
export type FetchCaptureInput = {
	method: string;
	url: string;
	status: number;
	duration: number;
	headers: Record<string, string>;
	body: unknown;
	response: unknown;
};

// ---------------------------------------------------------------------------
// Internal helpers — form result introspection
// ---------------------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

function stringField(result: FormResult, fieldName?: string): string | undefined {
	if (!fieldName) return undefined;
	const value = result[fieldName];
	return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function hasSearchResult(
	result: FormResult
): result is FormResult & { searchResult: Record<string, unknown> } {
	return (
		isRecord(result.searchResult) &&
		Array.isArray(result.searchResult.hits) &&
		typeof result.searchResult.nbHits === 'number'
	);
}

// ---------------------------------------------------------------------------
// Mutation route matching — moved from SearchLogPanel.svelte
// ---------------------------------------------------------------------------

type MutationRouteMatcher = {
	matches: (result: FormResult) => boolean;
	resolveUrl: string | ((result: FormResult) => string);
	errorField?: string;
	resolveErrorMessage?: (result: FormResult) => string | undefined;
	buildResponse: (result: FormResult) => unknown;
};

function hasAnyTruthyField(result: FormResult, fieldNames: string[]): boolean {
	return fieldNames.some((fieldName) => Boolean(result[fieldName]));
}

function passthroughResponse(result: FormResult): FormResult {
	return result;
}

function createMutationRouteMatcher(config: {
	fieldNames: string[];
	resolveUrl: MutationRouteMatcher['resolveUrl'];
	errorField?: string;
	resolveErrorMessage?: MutationRouteMatcher['resolveErrorMessage'];
	buildResponse?: MutationRouteMatcher['buildResponse'];
}): MutationRouteMatcher {
	return {
		matches: (result) => hasAnyTruthyField(result, config.fieldNames),
		resolveUrl: config.resolveUrl,
		errorField: config.errorField,
		resolveErrorMessage: config.resolveErrorMessage,
		buildResponse: config.buildResponse ?? passthroughResponse
	};
}

const MUTATION_ROUTE_MATCHERS: MutationRouteMatcher[] = [
	createMutationRouteMatcher({
		fieldNames: ['replicaCreated', 'replicaDeleted', 'replicaError'],
		resolveUrl: (r) =>
			r.replicaDeleted
				? '?/deleteReplica'
				: r.replicaCreated
					? '?/createReplica'
					: '?/replicaAction',
		errorField: 'replicaError'
	}),
	createMutationRouteMatcher({
		fieldNames: ['deleted', 'deleteError'],
		resolveUrl: '?/delete',
		errorField: 'deleteError'
	}),
	createMutationRouteMatcher({
		fieldNames: ['settingsSaved', 'settingsError'],
		resolveUrl: '?/saveSettings',
		errorField: 'settingsError'
	}),
	createMutationRouteMatcher({
		fieldNames: ['ruleSaved', 'ruleDeleted', 'ruleError'],
		resolveUrl: (r) => (r.ruleDeleted ? '?/deleteRule' : '?/saveRule'),
		errorField: 'ruleError'
	}),
	createMutationRouteMatcher({
		fieldNames: ['synonymSaved', 'synonymDeleted', 'synonymError'],
		resolveUrl: (r) => (r.synonymDeleted ? '?/deleteSynonym' : '?/saveSynonym'),
		errorField: 'synonymError'
	}),
	createMutationRouteMatcher({
		fieldNames: [
			'securitySourceAppended',
			'securitySourceDeleted',
			'securitySourceAppendError',
			'securitySourceDeleteError'
		],
		resolveUrl: (r) =>
			r.securitySourceDeleted || r.securitySourceDeleteError
				? '?/deleteSecuritySource'
				: '?/appendSecuritySource',
		resolveErrorMessage: (r) =>
			stringField(r, 'securitySourceAppendError') ?? stringField(r, 'securitySourceDeleteError'),
		buildResponse: (r) =>
			r.securitySourceAppendError
				? { error: r.securitySourceAppendError }
				: r.securitySourceDeleteError
					? { error: r.securitySourceDeleteError }
					: r
	}),
	createMutationRouteMatcher({
		fieldNames: ['qsConfigSaved', 'qsConfigDeleted', 'qsConfigError'],
		resolveUrl: (r) => (r.qsConfigDeleted ? '?/deleteQsConfig' : '?/saveQsConfig'),
		errorField: 'qsConfigError'
	}),
	createMutationRouteMatcher({
		fieldNames: [
			'experimentCreated',
			'experimentDeleted',
			'experimentStarted',
			'experimentStopped',
			'experimentConcluded',
			'experimentError'
		],
		resolveUrl: (r) =>
			r.experimentDeleted
				? '?/deleteExperiment'
				: r.experimentStarted
					? '?/startExperiment'
					: r.experimentStopped
						? '?/stopExperiment'
						: r.experimentConcluded
							? '?/concludeExperiment'
							: r.experimentCreated
								? '?/createExperiment'
								: '?/experimentAction',
		errorField: 'experimentError'
	}),
	createMutationRouteMatcher({
		fieldNames: ['refreshedEvents', 'eventsError'],
		resolveUrl: '?/refreshEvents',
		errorField: 'eventsError',
		buildResponse: (r) => r.refreshedEvents ?? r
	})
];

type AmbiguousMutationRoute = '?/replicaAction' | '?/experimentAction';

const AMBIGUOUS_MUTATION_ROUTES: Record<AmbiguousMutationRoute, string[]> = {
	'?/replicaAction': ['?/createReplica', '?/deleteReplica'],
	'?/experimentAction': [
		'?/createExperiment',
		'?/deleteExperiment',
		'?/startExperiment',
		'?/stopExperiment',
		'?/concludeExperiment'
	]
};

function resolvedMutationRoute(matchedRoute: string, submittedAction: string | null): string {
	const allowed = AMBIGUOUS_MUTATION_ROUTES[matchedRoute as AmbiguousMutationRoute];
	if (!allowed || !submittedAction) return matchedRoute;
	return allowed.includes(submittedAction) ? submittedAction : matchedRoute;
}

// ---------------------------------------------------------------------------
// Internal: build form-derived log payload
// ---------------------------------------------------------------------------

function buildMutationLogPayload(
	url: string,
	errorMessage: string | undefined,
	successResponse: unknown
): { method: string; url: string; status: number; duration: number; response: unknown } {
	return {
		method: 'POST',
		url,
		status: errorMessage ? 400 : 200,
		duration: 0,
		response: errorMessage ? { error: errorMessage } : successResponse
	};
}

function sanitizeFormLogPayload(
	payload: Omit<RawLogCapture, 'source' | 'headers'>
): SanitizedLogEntry | null {
	return sanitizeLogEntry({ source: 'form', headers: {}, ...payload });
}

/**
 * Match a form result against registered mutation route patterns and resolve a sanitized log entry.
 *
 * @param result - The form result to match against mutation patterns
 * @param lastSubmittedAction - The submitted action URL, used to disambiguate ambiguous mutations
 * @returns A sanitized log entry if a matching pattern is found, null otherwise
 */
function resolveMutationLogEntry(
	result: FormResult,
	lastSubmittedAction: string | null
): SanitizedLogEntry | null {
	const matcher = MUTATION_ROUTE_MATCHERS.find(({ matches }) => matches(result));
	if (!matcher) return null;

	const matchedRoute =
		typeof matcher.resolveUrl === 'function' ? matcher.resolveUrl(result) : matcher.resolveUrl;
	const url = resolvedMutationRoute(matchedRoute, lastSubmittedAction);
	const errorMessage =
		matcher.resolveErrorMessage?.(result) ?? stringField(result, matcher.errorField);

	return sanitizeFormLogPayload(
		buildMutationLogPayload(url, errorMessage, matcher.buildResponse(result))
	);
}

// ---------------------------------------------------------------------------
// Public API: form adapter
// ---------------------------------------------------------------------------

/**
 * Derive a sanitized log entry from a SvelteKit enhanced form result.
 * Returns null if the result is null or does not match any known form action.
 *
 * @param result - The form result from +page.server.ts actions
 * @param lastSubmittedAction - The action URL from the last form submit event
 */
export function deriveFormLogEntry(
	result: FormResult | null,
	lastSubmittedAction: string | null
): SanitizedLogEntry | null {
	if (!result) return null;

	const query = typeof result.query === 'string' ? result.query : '';

	// Search success
	if (hasSearchResult(result)) {
		const payload = {
			...buildMutationLogPayload('?/search', undefined, result.searchResult),
			body: { query }
		};
		return sanitizeFormLogPayload(payload);
	}

	// Search error
	const searchError = stringField(result, 'searchError');
	if (searchError) {
		const payload = {
			...buildMutationLogPayload('?/search', searchError, undefined),
			body: { query }
		};
		return sanitizeFormLogPayload(payload);
	}

	return resolveMutationLogEntry(result, lastSubmittedAction);
}

// ---------------------------------------------------------------------------
// Public API: fetch adapter
// ---------------------------------------------------------------------------

/**
 * Derive a sanitized log entry from a browser fetch request/response pair.
 * Returns null if the route is excluded (e.g. migration routes).
 */
export function deriveFetchLogEntry(input: FetchCaptureInput): SanitizedLogEntry | null {
	const raw: RawLogCapture = {
		source: 'fetch',
		method: input.method,
		url: input.url,
		status: input.status,
		duration: input.duration,
		headers: input.headers,
		body: input.body,
		response: input.response
	};
	return sanitizeLogEntry(raw);
}

// ---------------------------------------------------------------------------
// Public API: form action extraction
// ---------------------------------------------------------------------------

/**
 * Extract the enhanced form action URL from a submit event.
 * Replaces the inline trackSubmittedPostAction() in +page.svelte.
 * Returns null if the target is not a form or action doesn't start with "?/".
 */
export function extractFormAction(event: SubmitEvent): string | null {
	const form = event.target;
	if (!(form instanceof HTMLFormElement)) return null;

	const action = form.getAttribute('action');
	if (!action || !action.startsWith('?/')) return null;

	return action;
}
