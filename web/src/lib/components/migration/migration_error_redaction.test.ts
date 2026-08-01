import { describe, expect, it } from 'vitest';

import { toErrorMessage } from './migration_error_redaction';

describe('migration error redaction', () => {
	it('redacts every literal occurrence of sensitive values, including regexp characters', () => {
		expect(
			toErrorMessage(new Error('failed key.* key.* app[1] context'), ['key.*', 'app[1]'])
		).toBe('failed [redacted] [redacted] [redacted] context');
	});

	it('ignores blank sensitive values and normalizes non-Error failures', () => {
		expect(toErrorMessage('producer unavailable', ['', '   '])).toBe('producer unavailable');
	});
});
