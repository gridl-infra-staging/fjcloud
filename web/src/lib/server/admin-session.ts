/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/lib/server/admin-session.ts.
 */
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';

export const ADMIN_SESSION_COOKIE = 'admin_session_id';
export const DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS = 60 * 60 * 8;

export interface AdminSession {
	id: string;
	createdAt: Date;
	expiresAt: Date;
}

const sessions = new Map<string, AdminSession>();

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

export function createAdminSession(maxAgeSeconds: number): AdminSession {
	purgeExpiredAdminSessions();

	const now = new Date();
	const session: AdminSession = {
		id: randomUUID(),
		createdAt: now,
		expiresAt: new Date(now.getTime() + maxAgeSeconds * 1000)
	};
	sessions.set(session.id, session);
	return session;
}

export function getAdminSession(sessionId: string | undefined): AdminSession | null {
	if (!sessionId) return null;
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
