import { describe, expect, it } from 'vitest';

import {
	PASSWORD_MIN_LENGTH,
	PASSWORD_TOO_COMMON_ERROR,
	passwordApiValidationError,
	passwordMeetsMinimumLength,
	passwordMinimumLengthError
} from './password-policy';

describe('password policy affordances', () => {
	it('exposes the shared minimum used by password form affordances', () => {
		expect(PASSWORD_MIN_LENGTH).toBe(15);
	});

	it('rejects passwords below the shared minimum with route-owned label text', () => {
		expect(passwordMeetsMinimumLength('a'.repeat(14))).toBe(false);
		expect(passwordMinimumLengthError('a'.repeat(14), 'New password')).toBe(
			'New password must be at least 15 characters'
		);
	});

	it('accepts passwords at the shared minimum', () => {
		expect(passwordMeetsMinimumLength('abc café 123456')).toBe(true);
		expect(passwordMinimumLengthError('abc café 123456', 'Password')).toBeNull();
	});

	it('rejects supplementary-plane specimens that clear a byte or UTF-16 unit floor', () => {
		// Eight lock emoji: 8 code points but 16 UTF-16 code units and 32 UTF-8 bytes.
		const eightEmoji = '🔒'.repeat(8);
		expect(eightEmoji.length).toBe(16);
		expect(passwordMeetsMinimumLength(eightEmoji)).toBe(false);
	});

	it('short-circuits the minimum check without depending on the full length', () => {
		expect(passwordMeetsMinimumLength('🔒'.repeat(15))).toBe(true);
		expect(passwordMeetsMinimumLength('a'.repeat(10_000))).toBe(true);
	});

	it('maps backend password validation messages onto route-owned field labels', () => {
		expect(passwordApiValidationError('password must be at most 128 bytes')).toBe(
			'Password must be at most 128 bytes'
		);
		expect(passwordApiValidationError(PASSWORD_TOO_COMMON_ERROR, 'New password')).toBe(
			'New password is too common; choose another password'
		);
		expect(passwordApiValidationError('invalid email or password')).toBeNull();
	});
});
