import { afterEach, describe, expect, it } from 'vitest';
import {
	DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS,
	DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS,
	DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS,
	adminKeysMatch,
	checkAdminLoginRateLimit,
	clearAdminLoginAttemptsForTest,
	clearAdminSessionsForTest,
	createAdminSession,
	getAdminSession,
	resolveAdminSessionMaxAgeSeconds,
	resetAdminLoginAttempts,
	revokeAdminSession
} from './admin-session';

afterEach(() => {
	clearAdminSessionsForTest();
	clearAdminLoginAttemptsForTest();
});

describe('resolveAdminSessionMaxAgeSeconds', () => {
	it('returns default for undefined', () => {
		expect(resolveAdminSessionMaxAgeSeconds(undefined)).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for empty string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for whitespace-only', () => {
		expect(resolveAdminSessionMaxAgeSeconds('   ')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('parses valid integer string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('3600')).toBe(3600);
	});

	it('trims whitespace before parsing', () => {
		expect(resolveAdminSessionMaxAgeSeconds('  7200  ')).toBe(7200);
	});

	it('returns default for zero', () => {
		expect(resolveAdminSessionMaxAgeSeconds('0')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for negative', () => {
		expect(resolveAdminSessionMaxAgeSeconds('-1')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for non-numeric string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('abc')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for float', () => {
		expect(resolveAdminSessionMaxAgeSeconds('3.14')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for leading zero', () => {
		expect(resolveAdminSessionMaxAgeSeconds('01')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});
});

describe('adminKeysMatch', () => {
	it('returns true for identical keys', () => {
		expect(adminKeysMatch('secret-key-123', 'secret-key-123')).toBe(true);
	});

	it('returns false for different keys', () => {
		expect(adminKeysMatch('secret-key-123', 'wrong-key')).toBe(false);
	});

	it('returns false for empty vs non-empty', () => {
		expect(adminKeysMatch('secret', '')).toBe(false);
	});

	it('is case-sensitive', () => {
		expect(adminKeysMatch('SecretKey', 'secretkey')).toBe(false);
	});
});

describe('session management', () => {
	it('creates and retrieves a session', () => {
		const session = createAdminSession(3600);
		expect(session.id).toBeTruthy();
		expect(session.expiresAt.getTime()).toBeGreaterThan(session.createdAt.getTime());

		const retrieved = getAdminSession(session.id);
		expect(retrieved).not.toBeNull();
		expect(retrieved!.id).toBe(session.id);
	});

	it('returns null for unknown session ID', () => {
		expect(getAdminSession('nonexistent-id')).toBeNull();
	});

	it('returns null for undefined session ID', () => {
		expect(getAdminSession(undefined)).toBeNull();
	});

	it('revokes a session', () => {
		const session = createAdminSession(3600);
		expect(getAdminSession(session.id)).not.toBeNull();
		revokeAdminSession(session.id);
		expect(getAdminSession(session.id)).toBeNull();
	});

	it('revokeAdminSession is safe for undefined', () => {
		expect(() => revokeAdminSession(undefined)).not.toThrow();
	});

	it('expired session returns null and is cleaned up', () => {
		// Create a session that expires immediately (0 seconds)
		const session = createAdminSession(0);
		// The session expires at createdAt + 0ms, so it should already be expired
		const retrieved = getAdminSession(session.id);
		expect(retrieved).toBeNull();
	});
});

describe('admin login rate limiting', () => {
	it('allows attempts within limit', () => {
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			const result = checkAdminLoginRateLimit('192.168.1.1');
			expect(result.blocked).toBe(false);
		}
	});

	it('blocks after exceeding attempt limit', () => {
		const ip = '10.0.0.1';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}
		// One more should trigger lockout
		const result = checkAdminLoginRateLimit(ip);
		expect(result.blocked).toBe(true);
		expect(result.retryAfterSeconds).toBe(DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS);
	});

	it('different IPs are independent', () => {
		// Exhaust IP 1
		for (let i = 0; i <= DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit('1.1.1.1');
		}
		// IP 2 should still be fine
		const result = checkAdminLoginRateLimit('2.2.2.2');
		expect(result.blocked).toBe(false);
	});

	it('resetAdminLoginAttempts clears the counter', () => {
		const ip = '10.0.0.2';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}
		resetAdminLoginAttempts(ip);
		// Should be allowed again
		const result = checkAdminLoginRateLimit(ip);
		expect(result.blocked).toBe(false);
	});
});
