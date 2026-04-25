import type { Handle, HandleServerError } from '@sveltejs/kit';
import { redirect } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { resolveAuth } from '$lib/auth/guard';
import { AUTH_COOKIE } from '$lib/auth-session-contracts';
import {
	buildBoundaryCopy,
	resolveBoundaryScope,
	type BoundaryScope
} from '$lib/error-boundary/recovery-copy';
import { env } from '$env/dynamic/private';

const PUBLIC_PATHS = ['/login', '/signup', '/verify-email', '/forgot-password', '/reset-password'];
const SESSION_EXPIRED_REASON = 'session_expired';
const ROBOTS_HEADER_VALUE = 'noindex, nofollow, noarchive, nosnippet, noimageindex';

function isPublicPath(pathname: string): boolean {
	if (pathname === '/') return true;
	return PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + '/'));
}

function isForcedReauthRequest(url: URL): boolean {
	return url.pathname === '/login' && url.searchParams.get('reason') === SESSION_EXPIRED_REASON;
}

function backendRequestId(error: unknown): string | undefined {
	if (error instanceof ApiRequestError) {
		return error.requestId;
	}
	return undefined;
}

function routeErrorReport(input: {
	pathname: string;
	status: number;
	scope: BoundaryScope;
	supportReference: string;
	backendRequestId?: string;
}): Record<string, string | number> {
	const report: Record<string, string | number> = {
		path: input.pathname,
		status: input.status,
		scope: input.scope,
		support_reference: input.supportReference
	};

	if (input.backendRequestId) {
		report.backend_request_id = input.backendRequestId;
	}

	return report;
}

export const handle: Handle = async ({ event, resolve }) => {
	const token = event.cookies.get(AUTH_COOKIE);
	event.locals.user = resolveAuth(token, env.JWT_SECRET);

	// When the API has already declared the server-side session dead, force the
	// browser back to a clean unauthenticated state before rendering /login.
	if (isForcedReauthRequest(event.url)) {
		if (token) {
			event.cookies.delete(AUTH_COOKIE, { path: '/' });
		}
		event.locals.user = null;
	}

	if (!event.locals.user && event.url.pathname.startsWith('/dashboard')) {
		if (token) {
			event.cookies.delete(AUTH_COOKIE, { path: '/' });
		}
		redirect(303, '/login');
	}

	if (event.locals.user && isPublicPath(event.url.pathname)) {
		redirect(303, '/dashboard');
	}

	const response = await resolve(event);
	// The public beta should be fetchable for humans and link-preview bots, but
	// not indexed while product copy, pricing, and signup flows are still changing.
	response.headers.set('X-Robots-Tag', ROBOTS_HEADER_VALUE);
	return response;
};

export const handleError: HandleServerError = ({ error, event, status, message }) => {
	const scope = resolveBoundaryScope(event.url.pathname);
	const boundaryCopy = buildBoundaryCopy({
		status,
		errorMessage: message,
		scope
	});
	const requestId = backendRequestId(error);

	// Log only sanitized metadata. The thrown error may contain database hosts,
	// stack traces, or IPs, so raw error messages stay out of customer copy and
	// out of this correlation event.
	console.error(
		'route error reported',
		routeErrorReport({
			pathname: event.url.pathname,
			status,
			scope,
			supportReference: boundaryCopy.supportReference,
			backendRequestId: requestId
		})
	);
	// Local dev/diagnostic seam: when WEB_DEV_LOG_RAW_ERRORS=1, print the
	// thrown error itself so an operator can see SvelteKit/runtime stacks
	// during local triage. The default sanitized log above stays in place
	// for staging/prod so customer support_reference/backend_request_id
	// remain the correlation surface; raw errors stay opt-in.
	if (process.env.WEB_DEV_LOG_RAW_ERRORS === '1') {
		console.error('route raw error', error);
	}

	return {
		message,
		supportReference: boundaryCopy.supportReference,
		backendRequestId: requestId
	};
};
