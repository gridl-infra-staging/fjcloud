import { describe, expect, it } from 'vitest';
import { parseRetryAfterSeconds, retryAfterHeaderValue } from './retry_after';

describe('retry_after helpers', () => {
	it('parses only positive integer retry-after values', () => {
		expect(parseRetryAfterSeconds('45')).toBe(45);
		expect(parseRetryAfterSeconds('0')).toBeNull();
		expect(parseRetryAfterSeconds('-10')).toBeNull();
		expect(parseRetryAfterSeconds('1.5')).toBeNull();
		expect(parseRetryAfterSeconds('60seconds')).toBeNull();
		expect(parseRetryAfterSeconds('invalid')).toBeNull();
		expect(parseRetryAfterSeconds(null)).toBeNull();
	});

	it('serializes positive cooldown values for Retry-After headers', () => {
		expect(retryAfterHeaderValue(30)).toBe('30');
		expect(retryAfterHeaderValue(0)).toBeNull();
		expect(retryAfterHeaderValue(null)).toBeNull();
	});
});
