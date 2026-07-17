import { createHmac } from 'node:crypto';
import { describe, it, expect, vi, afterEach } from 'vitest';
import { decodeJwt, isJwtExpired, isJwtHs256SignatureValid } from './jwt';

function b64UrlEncodeJson(value: Record<string, unknown>): string {
	return Buffer.from(JSON.stringify(value))
		.toString('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '');
}

function makeJwt(
	payload: Record<string, unknown>,
	secret = 'jwt-secret-for-tests-1234567890'
): string {
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

describe('decodeJwt', () => {
	it('decodes a valid JWT payload', () => {
		const token = makeJwt({ sub: 'user-123', exp: 9999999999, iat: 1000000000 });
		const result = decodeJwt(token);
		expect(result).toEqual({ sub: 'user-123', exp: 9999999999, iat: 1000000000 });
	});

	it('returns null for malformed token (not 3 parts)', () => {
		expect(decodeJwt('not-a-jwt')).toBeNull();
		expect(decodeJwt('two.parts')).toBeNull();
	});

	it('returns null for invalid base64', () => {
		expect(decodeJwt('a.!!!.c')).toBeNull();
	});

	it('returns null when sub is missing', () => {
		const token = makeJwt({ exp: 9999999999, iat: 1000 });
		expect(decodeJwt(token)).toBeNull();
	});

	it('returns null when exp is missing', () => {
		const token = makeJwt({ sub: 'user-1', iat: 1000 });
		expect(decodeJwt(token)).toBeNull();
	});

	it('returns null when iat is missing', () => {
		const token = makeJwt({ sub: 'user-1', exp: 9999999999 });
		expect(decodeJwt(token)).toBeNull();
	});
});

describe('isJwtHs256SignatureValid', () => {
	it('returns true for a correctly signed HS256 token', () => {
		const secret = 'jwt-secret-for-tests-1234567890';
		const token = makeJwt({ sub: 'user-123', exp: 9999999999, iat: 1000 }, secret);
		expect(isJwtHs256SignatureValid(token, secret)).toBe(true);
	});

	it('returns false for forged signature', () => {
		const secret = 'jwt-secret-for-tests-1234567890';
		const token = makeJwt({ sub: 'user-123', exp: 9999999999, iat: 1000 }, secret);
		const forged = `${token.split('.').slice(0, 2).join('.')}.forged`;
		expect(isJwtHs256SignatureValid(forged, secret)).toBe(false);
	});

	it('returns false when secret is missing', () => {
		const token = makeJwt({ sub: 'user-123', exp: 9999999999, iat: 1000 });
		expect(isJwtHs256SignatureValid(token, '')).toBe(false);
	});

	it('returns false for non-HS256 alg header', () => {
		const header = b64UrlEncodeJson({ alg: 'none', typ: 'JWT' });
		const payload = b64UrlEncodeJson({ sub: 'user-123', exp: 9999999999, iat: 1000 });
		const token = `${header}.${payload}.abc`;
		expect(isJwtHs256SignatureValid(token, 'jwt-secret-for-tests-1234567890')).toBe(false);
	});
});

describe('isJwtExpired', () => {
	afterEach(() => {
		vi.useRealTimers();
	});

	it('returns false when token is not expired', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-01-01T00:00:00Z'));
		expect(isJwtExpired({ sub: 'u', exp: 1893456000, iat: 0 })).toBe(false); // exp = 2030-01-01
	});

	it('returns true when token is expired', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2030-01-02T00:00:00Z'));
		expect(isJwtExpired({ sub: 'u', exp: 1893456000, iat: 0 })).toBe(true); // exp = 2030-01-01
	});

	it('returns true when token expires exactly now', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date(1893456000 * 1000)); // exactly at exp
		expect(isJwtExpired({ sub: 'u', exp: 1893456000, iat: 0 })).toBe(true);
	});
});
