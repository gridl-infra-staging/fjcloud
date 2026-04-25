import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('$app/environment', () => ({ browser: true }));

// ---------------------------------------------------------------------------
// Types for form result records (mirrors +page.server.ts action returns)
// ---------------------------------------------------------------------------

type FormResult = Record<string, unknown>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function searchSuccess(query: string, hits: unknown[] = [], nbHits = 0): FormResult {
	return { query, searchResult: { hits, nbHits } };
}

function searchError(query: string, error: string): FormResult {
	return { query, searchError: error };
}

// ---------------------------------------------------------------------------
// Tests: deriveFormLogEntry — form submission to sanitized log entry
// ---------------------------------------------------------------------------

describe('deriveFormLogEntry', () => {
	beforeEach(() => {
		vi.resetModules();
	});

	// -- Search results --

	it('derives a search success entry with query body and search result', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const result = searchSuccess('shoes', [{ objectID: '1' }], 1);
		const entry = deriveFormLogEntry(result, null);

		expect(entry).not.toBeNull();
		expect(entry!.method).toBe('POST');
		expect(entry!.url).toBe('?/search');
		expect(entry!.status).toBe(200);
		expect(entry!.body).toEqual({ query: 'shoes' });
		// Response should be the search result, sanitized (no sensitive fields)
		expect(entry!.response).toEqual({ hits: [{ objectID: '1' }], nbHits: 1 });
	});

	it('derives a search error entry with 400 status', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const result = searchError('bad query', 'Invalid filter syntax');
		const entry = deriveFormLogEntry(result, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/search');
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'Invalid filter syntax' });
	});

	// -- Mutation routes --

	it('derives a settings saved entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ settingsSaved: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/saveSettings');
		expect(entry!.status).toBe(200);
	});

	it('derives a settings error entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ settingsError: 'Bad setting' }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/saveSettings');
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'Bad setting' });
	});

	it('derives a delete rule entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ ruleDeleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteRule');
	});

	it('derives a save rule entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ ruleSaved: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/saveRule');
	});

	it('derives a save synonym entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ synonymSaved: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/saveSynonym');
	});

	it('derives a delete synonym entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ synonymDeleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteSynonym');
	});

	it('derives an append security source entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry(
			{
				securitySourceAppended: true,
				securitySources: {
					sources: [{ source: '10.0.0.0/8', description: 'VPN range' }]
				}
			},
			null
		);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/appendSecuritySource');
		expect(entry!.status).toBe(200);
		expect(entry!.response).toEqual({
			securitySourceAppended: true,
			securitySources: {
				sources: [{ source: '10.0.0.0/8', description: 'VPN range' }]
			}
		});
	});

	it('derives an append security source error entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry(
			{
				securitySourceAppendError: 'source is required',
				securitySources: { sources: [] }
			},
			null
		);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/appendSecuritySource');
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'source is required' });
	});

	it('derives a delete security source entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry(
			{
				securitySourceDeleted: true,
				securitySources: { sources: [] }
			},
			null
		);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteSecuritySource');
		expect(entry!.status).toBe(200);
		expect(entry!.response).toEqual({
			securitySourceDeleted: true,
			securitySources: { sources: [] }
		});
	});

	it('derives a delete security source error entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry(
			{
				securitySourceDeleteError: 'Failed to delete security source',
				securitySources: { sources: [] }
			},
			null
		);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteSecuritySource');
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'Failed to delete security source' });
	});

	// -- Replica routes with ambiguous resolution --

	it('derives a create replica entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ replicaCreated: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/createReplica');
	});

	it('derives a delete replica entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ replicaDeleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteReplica');
	});

	it('derives a replica error entry with 400 status', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ replicaError: 'Replica limit reached' }, null);

		expect(entry).not.toBeNull();
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'Replica limit reached' });
	});

	// -- Experiment routes with ambiguous resolution using lastSubmittedAction --

	it('derives a stop experiment entry using lastSubmittedAction', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentStopped: true }, '?/stopExperiment');

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/stopExperiment');
	});

	it('derives a create experiment entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentCreated: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/createExperiment');
	});

	it('derives a delete experiment entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentDeleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteExperiment');
	});

	it('derives a start experiment entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentStarted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/startExperiment');
		expect(entry!.status).toBe(200);
	});

	it('derives a conclude experiment entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentConcluded: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/concludeExperiment');
		expect(entry!.status).toBe(200);
	});

	it('derives an experiment error entry with 400 status', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ experimentError: 'AB test overlap' }, null);

		expect(entry).not.toBeNull();
		expect(entry!.status).toBe(400);
		expect(entry!.response).toEqual({ error: 'AB test overlap' });
	});

	// -- Ambiguous route resolution edge cases --

	it('falls back to generic route when lastSubmittedAction is null for ambiguous experiment', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		// experimentStopped without a lastSubmittedAction: the matcher resolves
		// to ?/stopExperiment directly (not ambiguous — only the generic fallback is)
		const entry = deriveFormLogEntry({ experimentStopped: true }, null);
		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/stopExperiment');
	});

	it('ignores unrelated lastSubmittedAction for experiment routes', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		// Pass a lastSubmittedAction that doesn't match any allowed experiment route
		const entry = deriveFormLogEntry({ experimentCreated: true }, '?/saveSettings');
		expect(entry).not.toBeNull();
		// Should resolve from result fields, not from wrong lastSubmittedAction
		expect(entry!.url).toBe('?/createExperiment');
	});

	// -- Query suggestions config --

	it('derives a save QS config entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ qsConfigSaved: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/saveQsConfig');
	});

	it('derives a delete QS config entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ qsConfigDeleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/deleteQsConfig');
	});

	// -- Events --

	it('derives a refresh events entry with events response', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const events = { events: [{ type: 'click' }] };
		const entry = deriveFormLogEntry({ refreshedEvents: events }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/refreshEvents');
		expect(entry!.status).toBe(200);
		expect(entry!.response).toEqual(events);
	});

	// -- Null cases --

	it('returns null for null form result', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		expect(deriveFormLogEntry(null, null)).toBeNull();
	});

	it('returns null for unrecognized form result', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		expect(deriveFormLogEntry({ unknownField: true }, null)).toBeNull();
	});

	// -- Delete index --

	it('derives a delete index entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ deleted: true }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/delete');
		expect(entry!.status).toBe(200);
	});

	it('derives a delete index error entry', async () => {
		const { deriveFormLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFormLogEntry({ deleteError: 'Cannot delete' }, null);

		expect(entry).not.toBeNull();
		expect(entry!.url).toBe('?/delete');
		expect(entry!.status).toBe(400);
	});
});

// ---------------------------------------------------------------------------
// Tests: deriveFetchLogEntry — browser fetch to sanitized log entry
// ---------------------------------------------------------------------------

describe('deriveFetchLogEntry', () => {
	beforeEach(() => {
		vi.resetModules();
	});

	it('derives a log entry from a fetch request/response pair', async () => {
		const { deriveFetchLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFetchLogEntry({
			method: 'GET',
			url: '/api/v1/indexes',
			status: 200,
			duration: 45,
			headers: { 'Content-Type': 'application/json' },
			body: undefined,
			response: { items: [] }
		});

		expect(entry).not.toBeNull();
		expect(entry!.method).toBe('GET');
		expect(entry!.url).toBe('/api/v1/indexes');
		expect(entry!.status).toBe(200);
		expect(entry!.duration).toBe(45);
		expect(entry!.response).toEqual({ items: [] });
	});

	it('strips sensitive fields from fetch capture bodies and responses', async () => {
		const { deriveFetchLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFetchLogEntry({
			method: 'POST',
			url: '/api/v1/auth',
			status: 200,
			duration: 10,
			headers: { Authorization: 'Bearer secret', 'Content-Type': 'application/json' },
			body: { token: 'jwt-value', action: 'refresh' },
			response: { previewKey: 'fj_preview_secret', ok: true }
		});

		expect(entry).not.toBeNull();
		expect(entry!.body).toEqual({ action: 'refresh' });
		expect(entry!.response).toEqual({ ok: true });
	});

	it('returns null for /migration/algolia/list-indexes', async () => {
		const { deriveFetchLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFetchLogEntry({
			method: 'POST',
			url: '/migration/algolia/list-indexes',
			status: 200,
			duration: 100,
			headers: {},
			body: { algolia_api_key: 'secret' },
			response: { indexes: [] }
		});

		expect(entry).toBeNull();
	});

	it('returns null for /migration/algolia/migrate', async () => {
		const { deriveFetchLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFetchLogEntry({
			method: 'POST',
			url: '/migration/algolia/migrate',
			status: 200,
			duration: 250,
			headers: {},
			body: { algolia_api_key: 'secret', source_index: 'products' },
			response: { taskId: 'task-1', message: 'ok' }
		});

		expect(entry).toBeNull();
	});

	it('strips sensitive fields from fetch request body', async () => {
		const { deriveFetchLogEntry } = await import('./dashboard-instrumentation');
		const entry = deriveFetchLogEntry({
			method: 'POST',
			url: '/api/v1/auth',
			status: 200,
			duration: 10,
			headers: {},
			body: { token: 'jwt-value', action: 'refresh' },
			response: { ok: true }
		});

		expect(entry).not.toBeNull();
		expect(entry!.body).toEqual({ action: 'refresh' });
	});
});

// ---------------------------------------------------------------------------
// Tests: extractFormAction — extract action from SubmitEvent
// ---------------------------------------------------------------------------

describe('extractFormAction', () => {
	beforeEach(() => {
		vi.resetModules();
	});

	it('extracts action from a form submit event', async () => {
		const { extractFormAction } = await import('./dashboard-instrumentation');
		const form = document.createElement('form');
		form.setAttribute('action', '?/search');
		const event = new Event('submit') as SubmitEvent;
		Object.defineProperty(event, 'target', { value: form });

		expect(extractFormAction(event)).toBe('?/search');
	});

	it('returns null when target is not a form', async () => {
		const { extractFormAction } = await import('./dashboard-instrumentation');
		const event = new Event('submit') as SubmitEvent;
		Object.defineProperty(event, 'target', { value: document.createElement('div') });

		expect(extractFormAction(event)).toBeNull();
	});

	it('returns null when action does not start with ?/', async () => {
		const { extractFormAction } = await import('./dashboard-instrumentation');
		const form = document.createElement('form');
		form.setAttribute('action', '/some/path');
		const event = new Event('submit') as SubmitEvent;
		Object.defineProperty(event, 'target', { value: form });

		expect(extractFormAction(event)).toBeNull();
	});
});
