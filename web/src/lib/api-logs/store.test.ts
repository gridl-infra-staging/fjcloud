import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import type { SanitizedLogEntry } from './sanitization';

// ---------------------------------------------------------------------------
// Mock $app/environment so the store thinks it's in a browser
// ---------------------------------------------------------------------------

let mockBrowser = true;
vi.mock('$app/environment', () => ({
	get browser() {
		return mockBrowser;
	}
}));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const STORAGE_KEY = 'fjcloud:api-log-entries';

function makeSanitizedEntry(overrides: Partial<SanitizedLogEntry> = {}): SanitizedLogEntry {
	return {
		method: 'POST',
		url: '?/search',
		status: 200,
		duration: 12,
		body: { query: 'shoes' },
		response: { hits: [], nbHits: 0 },
		...overrides
	};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('api-logs store', () => {
	beforeEach(() => {
		mockBrowser = true;
		sessionStorage.clear();
		// Re-import the module fresh for each test to reset store state
		vi.resetModules();
	});

	afterEach(() => {
		vi.restoreAllMocks();
	});

	// -----------------------------------------------------------------------
	// Basic append and read
	// -----------------------------------------------------------------------

	describe('appendLogEntry and getLogEntries', () => {
		it('returns an empty array initially', async () => {
			const { getLogEntries } = await import('./store');
			expect(getLogEntries()).toEqual([]);
		});

		it('appends an entry with generated id and timestamp', async () => {
			const { appendLogEntry, getLogEntries } = await import('./store');
			const entry = makeSanitizedEntry();

			appendLogEntry(entry);

			const entries = getLogEntries();
			expect(entries).toHaveLength(1);
			expect(entries[0].method).toBe('POST');
			expect(entries[0].url).toBe('?/search');
			expect(entries[0].status).toBe(200);
			expect(entries[0].id).toMatch(/^\d+-[a-z0-9]+$/);
			expect(entries[0].timestamp).toBeGreaterThan(0);
		});

		it('prepends newer entries (newest first)', async () => {
			const { appendLogEntry, getLogEntries } = await import('./store');
			appendLogEntry(makeSanitizedEntry({ url: '?/search' }));
			appendLogEntry(makeSanitizedEntry({ url: '?/saveSettings' }));

			const entries = getLogEntries();
			expect(entries).toHaveLength(2);
			// Newest first
			expect(entries[0].url).toBe('?/saveSettings');
			expect(entries[1].url).toBe('?/search');
		});
	});

	// -----------------------------------------------------------------------
	// Session storage persistence
	// -----------------------------------------------------------------------

	describe('session storage persistence', () => {
		it('persists entries to sessionStorage on append', async () => {
			const { appendLogEntry } = await import('./store');
			appendLogEntry(makeSanitizedEntry());

			const stored = sessionStorage.getItem(STORAGE_KEY);
			expect(stored).not.toBeNull();

			const parsed = JSON.parse(stored!);
			expect(parsed).toHaveLength(1);
			expect(parsed[0].method).toBe('POST');
		});

		it('hydrates entries from sessionStorage on module load', async () => {
			// Pre-populate sessionStorage before importing the module
			const seedEntries = [
				{
					id: 'seed-1',
					timestamp: 1000,
					method: 'GET',
					url: '/api/v1/indexes',
					status: 200,
					duration: 50,
					body: undefined,
					response: { items: [] }
				}
			];
			sessionStorage.setItem(STORAGE_KEY, JSON.stringify(seedEntries));

			const { getLogEntries } = await import('./store');
			const entries = getLogEntries();
			expect(entries).toHaveLength(1);
			expect(entries[0].id).toBe('seed-1');
			expect(entries[0].url).toBe('/api/v1/indexes');
		});

		it('handles corrupted sessionStorage gracefully', async () => {
			sessionStorage.setItem(STORAGE_KEY, '{not valid json array');

			const { getLogEntries } = await import('./store');
			expect(getLogEntries()).toEqual([]);
		});

		it('handles non-array sessionStorage gracefully', async () => {
			sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ wrong: true }));

			const { getLogEntries } = await import('./store');
			expect(getLogEntries()).toEqual([]);
		});
	});

	// -----------------------------------------------------------------------
	// Clear
	// -----------------------------------------------------------------------

	describe('clearLog', () => {
		it('removes all entries', async () => {
			const { appendLogEntry, getLogEntries, clearLog } = await import('./store');
			appendLogEntry(makeSanitizedEntry());
			appendLogEntry(makeSanitizedEntry({ url: '?/deleteRule' }));
			expect(getLogEntries()).toHaveLength(2);

			clearLog();
			expect(getLogEntries()).toEqual([]);
		});

		it('removes the sessionStorage key', async () => {
			const { appendLogEntry, clearLog } = await import('./store');
			appendLogEntry(makeSanitizedEntry());
			expect(sessionStorage.getItem(STORAGE_KEY)).not.toBeNull();

			clearLog();
			expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();
		});
	});

	// -----------------------------------------------------------------------
	// SSR-safe behavior: in-memory ops work, session storage is skipped
	// -----------------------------------------------------------------------

	describe('SSR-safe behavior', () => {
		it('in-memory operations work when not in browser', async () => {
			mockBrowser = false;
			const { appendLogEntry, getLogEntries } = await import('./store');
			appendLogEntry(makeSanitizedEntry());
			expect(getLogEntries()).toHaveLength(1);
		});

		it('does not persist to sessionStorage when not in browser', async () => {
			mockBrowser = false;
			const { appendLogEntry } = await import('./store');
			appendLogEntry(makeSanitizedEntry());
			expect(sessionStorage.getItem(STORAGE_KEY)).toBeNull();
		});

		it('clear works without throwing when not in browser', async () => {
			mockBrowser = false;
			const { appendLogEntry, clearLog, getLogEntries } = await import('./store');
			appendLogEntry(makeSanitizedEntry());
			expect(() => clearLog()).not.toThrow();
			expect(getLogEntries()).toEqual([]);
		});

		it('does not hydrate from sessionStorage when not in browser', async () => {
			// Pre-populate sessionStorage, then import with browser=false
			sessionStorage.setItem(
				STORAGE_KEY,
				JSON.stringify([
					{ id: 'ssr-1', timestamp: 1, method: 'GET', url: '/test', status: 200, duration: 0 }
				])
			);
			mockBrowser = false;
			const { getLogEntries } = await import('./store');
			// Should start empty — sessionStorage is not read during SSR
			expect(getLogEntries()).toEqual([]);
		});
	});

	// -----------------------------------------------------------------------
	// Dedupe: same object reference should not double-log
	// -----------------------------------------------------------------------

	describe('dedupe', () => {
		it('does not double-log the same sanitized entry reference', async () => {
			const { appendLogEntry, getLogEntries } = await import('./store');
			const entry = makeSanitizedEntry();

			appendLogEntry(entry);
			appendLogEntry(entry);

			expect(getLogEntries()).toHaveLength(1);
		});

		it('logs a distinct entry with identical content as a fresh entry', async () => {
			const { appendLogEntry, getLogEntries } = await import('./store');

			appendLogEntry(makeSanitizedEntry({ url: '?/search' }));
			appendLogEntry(makeSanitizedEntry({ url: '?/search' }));

			// Two different objects with same content = two separate submissions
			expect(getLogEntries()).toHaveLength(2);
		});
	});

	// -----------------------------------------------------------------------
	// subscribe: reactive notification for multiple consumers
	// -----------------------------------------------------------------------

	describe('subscribe', () => {
		it('notifies subscriber when an entry is appended', async () => {
			const { appendLogEntry, subscribe } = await import('./store');
			const listener = vi.fn();

			subscribe(listener);
			appendLogEntry(makeSanitizedEntry());

			expect(listener).toHaveBeenCalledOnce();
			expect(listener.mock.calls[0][0]).toHaveLength(1);
			expect(listener.mock.calls[0][0][0].url).toBe('?/search');
		});

		it('notifies subscriber when the log is cleared', async () => {
			const { appendLogEntry, clearLog, subscribe } = await import('./store');

			appendLogEntry(makeSanitizedEntry());
			const listener = vi.fn();
			subscribe(listener);
			clearLog();

			expect(listener).toHaveBeenCalledOnce();
			expect(listener.mock.calls[0][0]).toEqual([]);
		});

		it('stops notifying after unsubscribe', async () => {
			const { appendLogEntry, subscribe } = await import('./store');
			const listener = vi.fn();

			const unsubscribe = subscribe(listener);
			appendLogEntry(makeSanitizedEntry({ url: '?/first' }));
			expect(listener).toHaveBeenCalledOnce();

			unsubscribe();
			appendLogEntry(makeSanitizedEntry({ url: '?/second' }));
			expect(listener).toHaveBeenCalledOnce(); // no additional call
		});

		it('supports multiple concurrent subscribers', async () => {
			const { appendLogEntry, subscribe } = await import('./store');
			const listenerA = vi.fn();
			const listenerB = vi.fn();

			subscribe(listenerA);
			subscribe(listenerB);
			appendLogEntry(makeSanitizedEntry());

			expect(listenerA).toHaveBeenCalledOnce();
			expect(listenerB).toHaveBeenCalledOnce();
		});

		it('passes the current entries snapshot to subscriber', async () => {
			const { appendLogEntry, subscribe } = await import('./store');

			appendLogEntry(makeSanitizedEntry({ url: '?/first' }));
			const listener = vi.fn();
			subscribe(listener);
			appendLogEntry(makeSanitizedEntry({ url: '?/second' }));

			// Should receive all entries (newest first)
			expect(listener.mock.calls[0][0]).toHaveLength(2);
			expect(listener.mock.calls[0][0][0].url).toBe('?/second');
		});
	});
});
