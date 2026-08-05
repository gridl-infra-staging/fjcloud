/**
 * Server-side boundary for durable admin sessions.
 *
 * `infra/api` is the single source of truth for admin credential validation,
 * session validation, revocation, operator identity, and timeout enforcement.
 * This module owns only the web side of that contract: the cookie name, the
 * requested cookie lifetime, per-IP login throttling, and fail-closed wrappers
 * around the durable session endpoints.
 */
import { redirect } from '@sveltejs/kit';
import {
	AdminClientError,
	createAdminClientWithCredential,
	type AdminClient
} from '$lib/admin-client';
import { ADMIN_SESSION_COOKIE } from '$lib/auth-session-contracts';
import { resolveRequestApiBaseUrl } from '$lib/config';

export { ADMIN_SESSION_COOKIE };
export const DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS = 60 * 60 * 8;
// Mirrors the API's own absolute-lifetime cap. A cookie that outlives the
// durable session would only buy a round trip that 401s and bounces back to
// the login page, so the requested lifetime is clamped to the same ceiling.
export const MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS = 24 * 60 * 60;

const ADMIN_LOGIN_ROUTE = '/admin/login';

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
	return Math.min(parsed, MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS);
}

/** The request-scoped pieces a durable session call needs from a SvelteKit event. */
export interface AdminSessionRequestEvent {
	fetch: typeof globalThis.fetch;
	cookies: { get(name: string): string | undefined };
	locals?: { apiBaseUrl?: string };
	url?: URL;
}

export interface DurableAdminSessionIdentity {
	operatorId: string;
}

/** An operator-authenticated request: identity plus a client bound to their session. */
export interface AuthenticatedAdminSession extends DurableAdminSessionIdentity {
	adminClient: AdminClient;
}

export type CreateDurableAdminSessionResult =
	| { ok: true; sessionToken: string }
	| { ok: false; reason: 'invalid_credential' | 'unavailable' };

function isAdminAuthenticationError(error: unknown): boolean {
	return error instanceof AdminClientError && (error.status === 401 || error.status === 403);
}

/** Ends the browser session when a session-authenticated API call loses authorization. */
export function redirectIfAdminSessionAuthError(error: unknown): void {
	if (isAdminAuthenticationError(error)) {
		redirect(303, ADMIN_LOGIN_ROUTE);
	}
}

function adminSessionClient(event: AdminSessionRequestEvent, sessionToken: string): AdminClient {
	return createAdminClientWithCredential(
		resolveRequestApiBaseUrl(event.locals, event.url),
		{ kind: 'session', value: sessionToken },
		event.fetch
	);
}

/**
 * Exchanges a submitted admin key for a durable session token. The key is
 * never compared locally — the API decides whether it identifies an operator.
 */
export async function createDurableAdminSession(
	event: AdminSessionRequestEvent,
	submittedAdminKey: string,
	maxAgeSeconds: number
): Promise<CreateDurableAdminSessionResult> {
	const client = createAdminClientWithCredential(
		resolveRequestApiBaseUrl(event.locals, event.url),
		{ kind: 'admin-key', value: submittedAdminKey },
		event.fetch
	);

	try {
		const { session_id } = await client.createSession(maxAgeSeconds);
		return session_id
			? { ok: true, sessionToken: session_id }
			: { ok: false, reason: 'unavailable' };
	} catch (error) {
		return {
			ok: false,
			reason: isAdminAuthenticationError(error) ? 'invalid_credential' : 'unavailable'
		};
	}
}

/**
 * Every non-2xx answer — malformed token, revoked session, idle timeout, API
 * outage — resolves to null, because the web side cannot safely tell them
 * apart and none of them mean "authenticated".
 */
async function readCurrentOperatorId(client: AdminClient): Promise<string | null> {
	try {
		const { operator_id } = await client.getCurrentSession();
		return operator_id || null;
	} catch {
		return null;
	}
}

/** Resolves a cookie value to the operator it belongs to, or null. */
export async function validateDurableAdminSession(
	event: AdminSessionRequestEvent,
	sessionToken: string | undefined
): Promise<DurableAdminSessionIdentity | null> {
	if (!sessionToken) return null;

	const operatorId = await readCurrentOperatorId(adminSessionClient(event, sessionToken));
	return operatorId ? { operatorId } : null;
}

/**
 * Revocation is best-effort by design: an already-invalid session still has to
 * end with the cookie cleared, so callers never have to branch on the outcome.
 */
export async function revokeCurrentDurableAdminSession(
	event: AdminSessionRequestEvent,
	sessionToken: string | undefined
): Promise<void> {
	if (!sessionToken) return;
	await adminSessionClient(event, sessionToken)
		.revokeCurrentSession()
		.catch(() => undefined);
}

/** Revokes every session belonging to the operator who owns `sessionToken`. */
export async function revokeAllDurableAdminSessions(
	event: AdminSessionRequestEvent,
	sessionToken: string | undefined
): Promise<void> {
	if (!sessionToken) return;
	await adminSessionClient(event, sessionToken)
		.revokeAllSessions()
		.catch(() => undefined);
}

/**
 * The guard every privileged admin load and action runs first. It redirects to
 * the login page unless the request carries a live durable session, and hands
 * back a client that authenticates as that operator — so admin API calls are
 * attributable and revocable instead of riding a static server key.
 */
export async function requireDurableAdminSession(
	event: AdminSessionRequestEvent
): Promise<AuthenticatedAdminSession> {
	const sessionToken = event.cookies.get(ADMIN_SESSION_COOKIE);
	if (!sessionToken) {
		redirect(303, ADMIN_LOGIN_ROUTE);
	}

	const adminClient = adminSessionClient(event, sessionToken);
	const operatorId = await readCurrentOperatorId(adminClient);
	if (!operatorId) {
		redirect(303, ADMIN_LOGIN_ROUTE);
	}

	return { operatorId, adminClient };
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
