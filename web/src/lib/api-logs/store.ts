/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_2_feature_gaps/fjcloud_dev/web/src/lib/api-logs/store.ts.
 */
/**
 * Browser-only shared API log store backed by session storage.
 *
 * Single source of truth for persisted client-visible log entries.
 * All entries must pass through sanitizeLogEntry() before reaching this store.
 *
 * In-memory operations always work (including in tests and SSR).
 * Session storage persistence is guarded behind the `browser` flag.
 */

import { browser } from '$app/environment';
import type { SanitizedLogEntry } from './sanitization';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** A stored log entry with generated ID and timestamp. */
export type StoredLogEntry = SanitizedLogEntry & {
	id: string;
	timestamp: number;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const STORAGE_KEY = 'fjcloud:api-log-entries';

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

// Reference-based dedupe: track the last appended object to prevent
// double-logging when a reactive rerender passes the same form result.
let lastAppendedRef: WeakRef<SanitizedLogEntry> | null = null;

let entries: StoredLogEntry[] = [];
let hydrated = false;

// Reactive subscriber set — notified on every mutation (append, clear).
type LogChangeListener = (entries: StoredLogEntry[]) => void;
const listeners = new Set<LogChangeListener>();

function notifyListeners(): void {
	const snapshot = entries;
	for (const fn of listeners) fn(snapshot);
}

// ---------------------------------------------------------------------------
// Session storage helpers (browser-only)
// ---------------------------------------------------------------------------

function persistToStorage(): void {
	if (!browser) return;
	try {
		sessionStorage.setItem(STORAGE_KEY, JSON.stringify(entries));
	} catch {
		// Storage full or unavailable — degrade silently
	}
}

function hydrateFromStorage(): void {
	if (!browser || hydrated) return;
	hydrated = true;

	try {
		const raw = sessionStorage.getItem(STORAGE_KEY);
		if (!raw) return;

		const parsed: unknown = JSON.parse(raw);
		if (!Array.isArray(parsed)) return;

		entries = parsed as StoredLogEntry[];
	} catch {
		// Corrupted storage — start fresh
		entries = [];
	}
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

function generateId(): string {
	return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/** Get all stored log entries (newest first). */
export function getLogEntries(): StoredLogEntry[] {
	hydrateFromStorage();
	return entries;
}

/**
 * Append a sanitized entry to the store and persist to session storage.
 * Reference-based dedupe: passing the exact same object twice is a no-op
 * (prevents double-logging on reactive rerenders), but two distinct objects
 * with identical content are treated as separate submissions.
 */
export function appendLogEntry(entry: SanitizedLogEntry): void {
	hydrateFromStorage();

	// Reference-based dedupe: same object reference = same form result
	if (lastAppendedRef?.deref() === entry) return;
	lastAppendedRef = new WeakRef(entry);

	const stored: StoredLogEntry = {
		id: generateId(),
		timestamp: Date.now(),
		...entry
	};

	// Prepend for newest-first ordering
	entries = [stored, ...entries];
	persistToStorage();
	notifyListeners();
}

/** Clear all entries and remove from session storage. */
export function clearLog(): void {
	entries = [];
	lastAppendedRef = null;
	if (browser) {
		try {
			sessionStorage.removeItem(STORAGE_KEY);
		} catch {
			// Degrade silently
		}
	}
	notifyListeners();
}

/**
 * Subscribe to store mutations. The listener receives the current entries
 * snapshot after every append or clear. Returns an unsubscribe function.
 */
export function subscribe(listener: LogChangeListener): () => void {
	listeners.add(listener);
	return () => {
		listeners.delete(listener);
	};
}
