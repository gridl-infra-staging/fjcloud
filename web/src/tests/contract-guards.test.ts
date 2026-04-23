import { describe, expect, it } from 'vitest';
import {
	requireNonBlankString,
	requireNonEmptyString,
	requireAdminApiKey
} from '../../tests/fixtures/contract-guards';

describe('contract-guards', () => {
	describe('requireNonEmptyString', () => {
		it('returns trimmed value for non-empty string', () => {
			expect(requireNonEmptyString('  hello  ', 'should not throw')).toBe('hello');
		});

		it('returns the value unchanged when no whitespace padding exists', () => {
			expect(requireNonEmptyString('exact', 'should not throw')).toBe('exact');
		});

		it('throws with the provided message for empty string', () => {
			expect(() => requireNonEmptyString('', 'field is required')).toThrow(
				'field is required'
			);
		});

		it('throws with the provided message for whitespace-only string', () => {
			expect(() => requireNonEmptyString('   ', 'field is required')).toThrow(
				'field is required'
			);
		});

		it('throws with the provided message for tab/newline-only string', () => {
			expect(() => requireNonEmptyString('\t\n', 'field is required')).toThrow(
				'field is required'
			);
		});
	});

	describe('requireNonBlankString', () => {
		it('returns the original value when it contains non-whitespace content', () => {
			expect(requireNonBlankString('  secret  ', 'should not throw')).toBe('  secret  ');
		});

		it('throws with the provided message for whitespace-only string', () => {
			expect(() => requireNonBlankString(' \t\n ', 'field is required')).toThrow(
				'field is required'
			);
		});
	});

	describe('requireAdminApiKey', () => {
		it('returns the admin key when provided', () => {
			expect(requireAdminApiKey('admin-key-123')).toBe('admin-key-123');
		});

		it('preserves an admin key exactly when surrounding whitespace exists', () => {
			expect(requireAdminApiKey('  admin-key-123  ')).toBe('  admin-key-123  ');
		});

		it('throws when admin key is undefined', () => {
			expect(() => requireAdminApiKey(undefined)).toThrow(
				'E2E_ADMIN_KEY must be set for admin API calls'
			);
		});

		it('throws when admin key is empty string', () => {
			expect(() => requireAdminApiKey('')).toThrow(
				'E2E_ADMIN_KEY must be set for admin API calls'
			);
		});

		it('throws when admin key is whitespace only', () => {
			expect(() => requireAdminApiKey(' \t\n ')).toThrow(
				'E2E_ADMIN_KEY must be set for admin API calls'
			);
		});
	});
});
