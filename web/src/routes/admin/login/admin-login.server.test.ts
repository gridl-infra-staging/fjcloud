import { describe, it, expect } from 'vitest';
import { _extractClientIp as extractClientIp } from './+page.server';

describe('extractClientIp', () => {
	it('returns the framework-provided client address', () => {
		expect(extractClientIp(() => '10.0.0.1')).toBe('10.0.0.1');
	});

	it('trims whitespace from the client address', () => {
		expect(extractClientIp(() => '  203.0.113.50  ')).toBe('203.0.113.50');
	});

	it('returns unknown when getClientAddress is unavailable', () => {
		expect(extractClientIp(undefined)).toBe('unknown');
	});

	it('returns unknown when getClientAddress throws', () => {
		expect(
			extractClientIp(() => {
				throw new Error('adapter does not expose client IP');
			})
		).toBe('unknown');
	});

	it('returns unknown for an empty client address', () => {
		expect(extractClientIp(() => '   ')).toBe('unknown');
	});
});
