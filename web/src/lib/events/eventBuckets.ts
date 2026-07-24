import type { DebugEvent } from '$lib/api/types';

export type EventBucketRange = { from: number; until: number };

export type EventBucket = {
	bucketStartMs: number;
	total: number;
	ok: number;
	error: number;
};

export type EventBucketSeries = {
	bucketSizeMs: number;
	buckets: EventBucket[];
};

const FIFTEEN_MINUTES_MS = 15 * 60 * 1000;
const ONE_HOUR_MS = 60 * 60 * 1000;
const ONE_DAY_MS = 24 * ONE_HOUR_MS;
const SEVEN_DAYS_MS = 7 * ONE_DAY_MS;

function pickBucketSizeMs(windowMs: number): number {
	// Adaptive bucket sizing — keeps the bucket count roughly bounded across
	// the standard presets (15m, 1h, 24h, 7d). Anything beyond 7d (e.g. the
	// "All available" preset, which does not bucket since the chart isn't
	// rendered while polling is off) is clamped to a 1h bucket.
	if (windowMs <= FIFTEEN_MINUTES_MS) return 15 * 1000; // 15s buckets → 60 buckets
	if (windowMs <= ONE_HOUR_MS) return 60 * 1000; // 1m buckets → 60 buckets
	if (windowMs <= ONE_DAY_MS) return ONE_HOUR_MS; // 1h buckets → 24 buckets
	if (windowMs <= SEVEN_DAYS_MS) return 6 * ONE_HOUR_MS; // 6h buckets → 28 buckets
	return ONE_HOUR_MS;
}

export function bucketByTimeAndType(
	events: DebugEvent[],
	range: EventBucketRange
): EventBucketSeries {
	if (events.length === 0) return { bucketSizeMs: 0, buckets: [] };

	const windowMs = range.until - range.from;
	if (windowMs <= 0) return { bucketSizeMs: 0, buckets: [] };

	const bucketSizeMs = pickBucketSizeMs(windowMs);
	const bucketCount = Math.ceil(windowMs / bucketSizeMs);
	const buckets: EventBucket[] = Array.from({ length: bucketCount }, (_, i) => ({
		bucketStartMs: range.from + i * bucketSizeMs,
		total: 0,
		ok: 0,
		error: 0
	}));

	for (const event of events) {
		if (event.timestampMs < range.from || event.timestampMs >= range.until) continue;
		const bucketIndex = Math.floor((event.timestampMs - range.from) / bucketSizeMs);
		const bucket = buckets[bucketIndex];
		if (!bucket) continue;
		bucket.total += 1;
		if (event.httpCode === 200) bucket.ok += 1;
		else bucket.error += 1;
	}

	return { bucketSizeMs, buckets };
}
