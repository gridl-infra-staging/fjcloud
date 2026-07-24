import { SUPPORT_EMAIL } from '$lib/format';

// BoundaryScope is an internal-taxonomy literal for error-boundary copy
// selection, NOT a URL segment. The 'dashboard' value is intentionally kept
// after the /dashboard -> /console route-owner move because it labels the
// authenticated console surface for SupportReference hashing and copy
// selection. URL/copy sweeps that rename customer-facing /dashboard strings
// must NOT rename this literal — doing so would change every persisted
// support reference and break boundary-copy regression fixtures.
export type BoundaryScope = 'public' | 'dashboard';
type BoundaryCtaHref = '/' | '/console' | '/status';

export interface BoundaryCta {
	href: BoundaryCtaHref;
	label: string;
}

export interface BoundaryCopy {
	heading: string;
	description: string;
	primaryCta: BoundaryCta;
	showSecondaryStatusLink: boolean;
	supportReference: string;
	supportEmail: string;
	supportMailtoHref: string;
}

interface BuildBoundaryCopyInput {
	status: number;
	errorMessage: string;
	scope: BoundaryScope;
}

interface DeterministicSupportReferenceSeed {
	status: number;
	scope: BoundaryScope;
	description: string;
}

const SERVER_ERROR_DESCRIPTION =
	"We're experiencing a temporary issue. Please try again shortly or check our status page for updates.";
const REQUEST_FALLBACK_DESCRIPTION =
	'The request could not be completed. Please review the request and try again.';
const NOT_FOUND_FALLBACK_DESCRIPTION = 'The page you requested is not available.';
const CUSTOMER_SAFE_MESSAGE_PATTERN = /^[A-Za-z0-9 ,.'!?()-]{1,160}$/;
const UNSAFE_DETAIL_PATTERNS = [
	/\b(?:ECONNREFUSED|ECONNRESET|ENOTFOUND|ETIMEDOUT)\b/i,
	/\b(?:SQLSTATE|PG::|Traceback|Exception|Stack trace)\b/i,
	/\b(?:localhost|postgres|internal server)\b/i,
	/\b\d{1,3}(?:\.\d{1,3}){3}\b/,
	/:\d{2,5}\b/,
	/::/,
	/https?:\/\//i
];

const SUPPORT_REFERENCE_PREFIX = 'web-';
const SUPPORT_REFERENCE_HEX_LENGTH = 12;
const FNV64_OFFSET_BASIS = 0xcbf29ce484222325n;
const FNV64_PRIME = 0x100000001b3n;
const FNV64_MASK = 0xffffffffffffffffn;

function createHexSupportReferenceSegment(): string {
	if (globalThis.crypto?.getRandomValues) {
		const bytes = new Uint8Array(SUPPORT_REFERENCE_HEX_LENGTH / 2);
		globalThis.crypto.getRandomValues(bytes);
		return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
	}

	// This is a customer-facing conversation reference, not a backend request ID.
	return Math.random()
		.toString(16)
		.slice(2, 2 + SUPPORT_REFERENCE_HEX_LENGTH)
		.padEnd(SUPPORT_REFERENCE_HEX_LENGTH, '0');
}

export function createSupportReference(): string {
	return `${SUPPORT_REFERENCE_PREFIX}${createHexSupportReferenceSegment()}`;
}

export function resolveBoundaryScope(pathname: string): BoundaryScope {
	return pathname === '/dashboard' ||
		pathname.startsWith('/dashboard/') ||
		pathname === '/console' ||
		pathname.startsWith('/console/')
		? 'dashboard'
		: 'public';
}

function hashSupportReferenceInput(input: string): string {
	let hash = FNV64_OFFSET_BASIS;

	for (const character of input) {
		hash ^= BigInt(character.codePointAt(0) ?? 0);
		hash = (hash * FNV64_PRIME) & FNV64_MASK;
	}

	return hash.toString(16).padStart(16, '0');
}

function createDeterministicSupportReference({
	status,
	description,
	scope
}: DeterministicSupportReferenceSeed): string {
	const normalizedInput = `${scope}|${status}|${description.trim()}`;
	const hashedSegment = hashSupportReferenceInput(normalizedInput).slice(
		0,
		SUPPORT_REFERENCE_HEX_LENGTH
	);
	return `${SUPPORT_REFERENCE_PREFIX}${hashedSegment}`;
}

function is4xx(status: number): boolean {
	return status >= 400 && status <= 499;
}

function is5xx(status: number): boolean {
	return status >= 500 && status <= 599;
}

function isCustomerSafe4xxMessage(rawMessage: string): boolean {
	const trimmedMessage = rawMessage.trim();
	if (!trimmedMessage) return false;
	if (!CUSTOMER_SAFE_MESSAGE_PATTERN.test(trimmedMessage)) return false;
	return !UNSAFE_DETAIL_PATTERNS.some((pattern) => pattern.test(trimmedMessage));
}

function resolvePrimaryCta(scope: BoundaryScope, status: number): BoundaryCta {
	if (is5xx(status)) {
		return { href: '/status', label: 'Check service status' };
	}

	if (scope === 'dashboard') {
		return { href: '/console', label: 'Go to console' };
	}

	return { href: '/', label: 'Go home' };
}

function resolveHeading(status: number): string {
	if (status === 404) return 'Page not found';
	if (is5xx(status)) return 'Something went wrong';
	return 'Request could not be completed';
}

function resolveFallbackDescription(status: number): string {
	if (is5xx(status)) return SERVER_ERROR_DESCRIPTION;
	if (status === 404) return NOT_FOUND_FALLBACK_DESCRIPTION;
	return REQUEST_FALLBACK_DESCRIPTION;
}

export function buildBoundaryCopy(
	{ status, errorMessage, scope }: BuildBoundaryCopyInput,
	supportReference?: string
): BoundaryCopy {
	const showSafe4xxMessage = is4xx(status) && isCustomerSafe4xxMessage(errorMessage);
	const description = showSafe4xxMessage ? errorMessage.trim() : resolveFallbackDescription(status);
	const resolvedSupportReference =
		supportReference ?? createDeterministicSupportReference({ status, scope, description });

	return {
		heading: resolveHeading(status),
		description,
		primaryCta: resolvePrimaryCta(scope, status),
		showSecondaryStatusLink: !is5xx(status),
		supportReference: resolvedSupportReference,
		supportEmail: SUPPORT_EMAIL,
		supportMailtoHref: `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(
			`Flapjack Cloud support reference ${resolvedSupportReference}`
		)}`
	};
}
