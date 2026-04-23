import { createHmac } from 'node:crypto';
import { describe, it, expect, vi, afterEach } from 'vitest';
import { resolveAuth, type AuthUser } from './guard';

const TEST_JWT_SECRET = 'jwt-secret-for-tests-1234567890';

function b64UrlEncodeJson(value: Record<string, unknown>): string {
	return Buffer.from(JSON.stringify(value))
		.toString('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '');
}

function makeJwt(payload: Record<string, unknown>, secret = TEST_JWT_SECRET): string {
	const header = b64UrlEncodeJson({ alg: 'HS256', typ: 'JWT' });
	const body = b64UrlEncodeJson(payload);
	const signature = createHmac('sha256', secret)
		.update(`${header}.${body}`)
		.digest('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '');
	return `${header}.${body}.${signature}`;
}

describe('resolveAuth', () => {
	afterEach(() => {
		vi.useRealTimers();
	});

	it('returns null when no token cookie exists', () => {
		expect(resolveAuth(undefined, TEST_JWT_SECRET)).toBeNull();
	});

	it('returns null for empty token', () => {
		expect(resolveAuth('', TEST_JWT_SECRET)).toBeNull();
	});

	it('returns null for malformed token', () => {
		expect(resolveAuth('not-a-jwt', TEST_JWT_SECRET)).toBeNull();
	});

	it('returns null when jwt secret is missing', () => {
		const token = makeJwt({ sub: 'user-1', exp: 1893456000, iat: 1000 });
		expect(resolveAuth(token, undefined)).toBeNull();
	});

	it('returns null for expired token', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2030-06-01T00:00:00Z'));
		const token = makeJwt({ sub: 'user-1', exp: 1893456000, iat: 1000 }); // exp = 2030-01-01
		expect(resolveAuth(token, TEST_JWT_SECRET)).toBeNull();
	});

	it('returns null for token with invalid signature', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-01-01T00:00:00Z'));
		const token = makeJwt({ sub: 'user-abc', exp: 1893456000, iat: 1000 });
		const forged = `${token.split('.').slice(0, 2).join('.')}.forged`;
		expect(resolveAuth(forged, TEST_JWT_SECRET)).toBeNull();
	});

	it('returns AuthUser for valid non-expired token', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-01-01T00:00:00Z'));
		const token = makeJwt({ sub: 'user-abc', exp: 1893456000, iat: 1000 }); // exp = 2030-01-01
		const result = resolveAuth(token, TEST_JWT_SECRET);
		expect(result).toEqual({ customerId: 'user-abc', token });
	});
});

describe('AuthUser type', () => {
	it('has customerId and token fields', () => {
		const user: AuthUser = { customerId: 'c-1', token: 'jwt-tok' };
		expect(user.customerId).toBe('c-1');
		expect(user.token).toBe('jwt-tok');
	});
});
