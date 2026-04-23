/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/lib/auth/jwt.ts.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';

export interface JwtPayload {
	sub: string;
	exp: number;
	iat: number;
}

function normalizeBase64Url(input: string): string | null {
	if (!input || !/^[A-Za-z0-9_-]+$/.test(input)) return null;
	const base64 = input.replace(/-/g, '+').replace(/_/g, '/');
	const padding = '='.repeat((4 - (base64.length % 4)) % 4);
	return `${base64}${padding}`;
}

function decodeBase64UrlJson(segment: string): unknown | null {
	const normalized = normalizeBase64Url(segment);
	if (!normalized) return null;
	try {
		const decoded = Buffer.from(normalized, 'base64').toString('utf8');
		return JSON.parse(decoded);
	} catch {
		return null;
	}
}

export function decodeJwt(token: string): JwtPayload | null {
	const parts = token.split('.');
	if (parts.length !== 3) return null;

	const payload = decodeBase64UrlJson(parts[1]);
	if (!payload || typeof payload !== 'object') return null;

	const maybeSub = (payload as Record<string, unknown>).sub;
	const maybeExp = (payload as Record<string, unknown>).exp;
	const maybeIat = (payload as Record<string, unknown>).iat;
	if (typeof maybeSub !== 'string') return null;
	if (typeof maybeExp !== 'number' || !Number.isFinite(maybeExp)) return null;
	if (typeof maybeIat !== 'number' || !Number.isFinite(maybeIat)) return null;

	return { sub: maybeSub, exp: maybeExp, iat: maybeIat };
}

export function isJwtHs256SignatureValid(token: string, secret: string): boolean {
	if (!secret) return false;

	const parts = token.split('.');
	if (parts.length !== 3) return false;

	const [headerSegment, payloadSegment, signatureSegment] = parts;
	const header = decodeBase64UrlJson(headerSegment);
	if (!header || typeof header !== 'object') return false;
	if ((header as Record<string, unknown>).alg !== 'HS256') return false;

	const normalizedSignature = normalizeBase64Url(signatureSegment);
	if (!normalizedSignature) return false;

	let providedSignature: Buffer;
	try {
		providedSignature = Buffer.from(normalizedSignature, 'base64');
	} catch {
		return false;
	}

	const signingInput = `${headerSegment}.${payloadSegment}`;
	const expectedSignature = createHmac('sha256', secret).update(signingInput).digest();
	if (providedSignature.length !== expectedSignature.length) return false;

	return timingSafeEqual(providedSignature, expectedSignature);
}

export function isJwtExpired(payload: JwtPayload): boolean {
	return Date.now() >= payload.exp * 1000;
}
