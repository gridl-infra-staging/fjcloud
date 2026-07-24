import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

export const ADMIN_SESSION_COOKIE = 'admin_session_id';
export const DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS = 60 * 60 * 8;

export interface AdminSession {
	id: string;
	createdAt: Date;
	expiresAt: Date;
}

export function resolveAdminSessionMaxAgeSeconds(rawValue: string | undefined): number {
	if (!rawValue) return DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS;
	const normalized = rawValue.trim();
	if (!/^[1-9]\d*$/.test(normalized)) {
		return DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS;
	}
	const parsed = Number(normalized);
	if (!Number.isSafeInteger(parsed) || parsed <= 0) {
		return DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS;
	}
	return parsed;
}

// HMAC token format: <expiry_epoch_seconds_hex>.<hmac_hex>
// Self-validating — no server-side state needed across CF Workers isolates.
function signToken(expiryEpochSeconds: number, signingKey: string): string {
	const payload = expiryEpochSeconds.toString(16);
	const mac = createHmac('sha256', signingKey).update(payload).digest('hex');
	return `${payload}.${mac}`;
}

function verifyToken(
	token: string,
	signingKey: string
): { valid: true; expiresAt: Date } | { valid: false } {
	const dotIndex = token.indexOf('.');
	if (dotIndex === -1) return { valid: false };

	const payload = token.substring(0, dotIndex);
	const providedMac = token.substring(dotIndex + 1);

	if (!payload || !providedMac) return { valid: false };

	const expectedMac = createHmac('sha256', signingKey).update(payload).digest('hex');

	if (providedMac.length !== expectedMac.length) return { valid: false };

	const providedBuf = Buffer.from(providedMac, 'hex');
	const expectedBuf = Buffer.from(expectedMac, 'hex');
	if (providedBuf.length !== expectedBuf.length) return { valid: false };

	if (!timingSafeEqual(providedBuf, expectedBuf)) return { valid: false };

	const expiryEpoch = parseInt(payload, 16);
	if (!Number.isFinite(expiryEpoch)) return { valid: false };

	const expiresAt = new Date(expiryEpoch * 1000);
	if (expiresAt.getTime() <= Date.now()) return { valid: false };

	return { valid: true, expiresAt };
}

export function createAdminSession(maxAgeSeconds: number, signingKey?: string): AdminSession {
	const now = new Date();
	const expiresAt = new Date(now.getTime() + maxAgeSeconds * 1000);
	const expiryEpochSeconds = Math.floor(expiresAt.getTime() / 1000);

	let id: string;
	if (signingKey) {
		id = signToken(expiryEpochSeconds, signingKey);
	} else {
		id = crypto.randomUUID();
	}

	const session: AdminSession = { id, createdAt: now, expiresAt };
	sessions.set(session.id, session);
	return session;
}

const sessions = new Map<string, AdminSession>();

export function getAdminSession(
	sessionId: string | undefined,
	signingKey?: string
): AdminSession | null {
	if (!sessionId) return null;

	// Try stateless HMAC verification first (works across CF Workers isolates)
	if (signingKey && sessionId.includes('.')) {
		const result = verifyToken(sessionId, signingKey);
		if (result.valid) {
			return { id: sessionId, createdAt: new Date(0), expiresAt: result.expiresAt };
		}
		return null;
	}

	// Fallback to in-memory map for local dev with UUID tokens
	const session = sessions.get(sessionId);
	if (!session) return null;
	if (session.expiresAt.getTime() <= Date.now()) {
		sessions.delete(sessionId);
		return null;
	}
	return session;
}

export function revokeAdminSession(sessionId: string | undefined): void {
	if (!sessionId) return;
	sessions.delete(sessionId);
}

export function purgeExpiredAdminSessions(): void {
	const now = Date.now();
	for (const [id, session] of sessions.entries()) {
		if (session.expiresAt.getTime() <= now) {
			sessions.delete(id);
		}
	}
}

// --- Admin login rate limiting ---

export const DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS = 5;
export const DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS = 15 * 60; // 15 minutes

interface LoginAttemptRecord {
	attempts: number;
	firstAttemptAt: number; // Date.now()
	lockedUntil: number | null; // Date.now() timestamp
}

const loginAttempts = new Map<string, LoginAttemptRecord>();

export interface RateLimitResult {
	blocked: boolean;
	retryAfterSeconds?: number;
}

export function checkAdminLoginRateLimit(ip: string): RateLimitResult {
	const now = Date.now();
	const record = loginAttempts.get(ip);

	if (record?.lockedUntil) {
		if (now < record.lockedUntil) {
			return {
				blocked: true,
				retryAfterSeconds: Math.ceil((record.lockedUntil - now) / 1000)
			};
		}
		// Lockout expired — reset
		loginAttempts.delete(ip);
	}

	const current = loginAttempts.get(ip) ?? {
		attempts: 0,
		firstAttemptAt: now,
		lockedUntil: null
	};

	current.attempts += 1;

	if (current.attempts > DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS) {
		current.lockedUntil = now + DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS * 1000;
		loginAttempts.set(ip, current);
		return {
			blocked: true,
			retryAfterSeconds: DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS
		};
	}

	loginAttempts.set(ip, current);
	return { blocked: false };
}

export function resetAdminLoginAttempts(ip: string): void {
	loginAttempts.delete(ip);
}

export function clearAdminLoginAttemptsForTest(): void {
	loginAttempts.clear();
}

export function adminKeysMatch(expected: string, provided: string): boolean {
	const expectedHash = createHash('sha256').update(expected).digest();
	const providedHash = createHash('sha256').update(provided).digest();
	return timingSafeEqual(expectedHash, providedHash);
}

export function clearAdminSessionsForTest(): void {
	sessions.clear();
}
