export const ROBOTS_HEADER_VALUE =
	'noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai';

export const DOCUMENT_SECURITY_HEADER_NAMES = [
	'Strict-Transport-Security',
	'X-Content-Type-Options',
	'X-Frame-Options',
	'Referrer-Policy',
	'X-Robots-Tag'
] as const;

const DOCUMENT_SECURITY_HEADER_VALUES = {
	'Strict-Transport-Security': 'max-age=63072000; includeSubDomains',
	'X-Content-Type-Options': 'nosniff',
	'X-Frame-Options': 'DENY',
	'Referrer-Policy': 'strict-origin-when-cross-origin',
	'X-Robots-Tag': ROBOTS_HEADER_VALUE
} as const satisfies Record<(typeof DOCUMENT_SECURITY_HEADER_NAMES)[number], string>;

export function applyDocumentSecurityHeaders(headers: Headers): void {
	for (const name of DOCUMENT_SECURITY_HEADER_NAMES) {
		headers.set(name, DOCUMENT_SECURITY_HEADER_VALUES[name]);
	}
}
