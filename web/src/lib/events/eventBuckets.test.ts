import { describe, it, expect } from 'vitest';
import { bucketByTimeAndType, type EventBucketRange } from './eventBuckets';
import type { DebugEvent } from '$lib/api/types';

function makeEvent(overrides: Partial<DebugEvent>): DebugEvent {
	return {
		timestampMs: 0,
		index: 'products',
		eventType: 'view',
		eventSubtype: null,
		eventName: 'name',
		userToken: 'u',
		objectIds: [],
		httpCode: 200,
		validationErrors: [],
		...overrides
	} as DebugEvent;
}

describe('bucketByTimeAndType', () => {
	it('returns empty buckets for empty input', () => {
		const range: EventBucketRange = { from: 0, until: 60 * 60 * 1000 };
		const result = bucketByTimeAndType([], range);
		expect(result.buckets).toEqual([]);
	});

	it('buckets same-day same-type events into a single bucket with type-keyed counts', () => {
		// 1h window starting at t=0; bucket size for 1h = 1 minute (60 buckets)
		const range: EventBucketRange = { from: 0, until: 60 * 60 * 1000 };
		const events: DebugEvent[] = [
			makeEvent({ timestampMs: 30_000, eventType: 'view', httpCode: 200 }), // 30s -> bucket 0
			makeEvent({ timestampMs: 45_000, eventType: 'view', httpCode: 200 }), // 45s -> bucket 0
			makeEvent({ timestampMs: 30_000, eventType: 'view', httpCode: 500 }) // 30s -> bucket 0
		];
		const result = bucketByTimeAndType(events, range);
		// First bucket should have total=3, ok=2, error=1
		expect(result.buckets[0]).toMatchObject({ total: 3, ok: 2, error: 1 });
		// Remaining 59 buckets are all zero
		expect(result.buckets.length).toBe(60);
		expect(result.buckets.slice(1).every((b) => b.total === 0)).toBe(true);
	});

	it('buckets mixed-type events into distinct buckets across the window', () => {
		// 24h window -> bucket size = 1 hour (24 buckets)
		const dayMs = 24 * 60 * 60 * 1000;
		const range: EventBucketRange = { from: 0, until: dayMs };
		const events: DebugEvent[] = [
			// bucket 0: hour 0 — click ok
			makeEvent({ timestampMs: 15 * 60 * 1000, eventType: 'click', httpCode: 200 }),
			// bucket 5: hour 5 — view ok
			makeEvent({ timestampMs: 5 * 60 * 60 * 1000, eventType: 'view', httpCode: 200 }),
			// bucket 5: hour 5 — conversion error
			makeEvent({ timestampMs: 5 * 60 * 60 * 1000 + 30, eventType: 'conversion', httpCode: 500 })
		];
		const result = bucketByTimeAndType(events, range);
		expect(result.buckets.length).toBe(24);
		expect(result.buckets[0]).toMatchObject({ total: 1, ok: 1, error: 0 });
		expect(result.buckets[5]).toMatchObject({ total: 2, ok: 1, error: 1 });
		// Other buckets are empty
		expect(result.buckets[1].total).toBe(0);
		expect(result.buckets[10].total).toBe(0);
	});
});
