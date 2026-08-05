import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { applyDocumentSecurityHeaders } from './security_headers';

const OWNED_DOCUMENT_SECURITY_HEADERS = [
	'Strict-Transport-Security',
	'X-Content-Type-Options',
	'X-Frame-Options',
	'Referrer-Policy',
	'X-Robots-Tag'
] as const;

const EXPECTED_DOCUMENT_SECURITY_HEADERS = {
	'Strict-Transport-Security': 'max-age=63072000; includeSubDomains',
	'X-Content-Type-Options': 'nosniff',
	'X-Frame-Options': 'DENY',
	'Referrer-Policy': 'strict-origin-when-cross-origin',
	'X-Robots-Tag': 'noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai'
} as const satisfies Record<(typeof OWNED_DOCUMENT_SECURITY_HEADERS)[number], string>;

const SHARED_API_EMITTED_HEADER_PATTERNS = {
	'Strict-Transport-Security':
		/headers\.insert\(\s*header::STRICT_TRANSPORT_SECURITY,\s*HeaderValue::from_static\("([^"]+)"\),\s*\);/,
	'X-Content-Type-Options':
		/headers\.insert\(\s*header::X_CONTENT_TYPE_OPTIONS,\s*HeaderValue::from_static\("([^"]+)"\),\s*\);/,
	'X-Frame-Options':
		/headers\.insert\(\s*header::X_FRAME_OPTIONS,\s*HeaderValue::from_static\("([^"]+)"\)\s*\);/
} as const;

const RUST_ROBOTS_HEADER_VALUE_PATTERN = /const ROBOTS_HEADER_VALUE: &str =\s*"([^"]+)";/;
const RUST_ROBOTS_HEADER_INSERTION_PATTERN =
	/headers\.insert\(\s*HeaderName::from_static\("x-robots-tag"\),\s*HeaderValue::from_static\(ROBOTS_HEADER_VALUE\),\s*\);/;
const SECURITY_HEADERS_MIDDLEWARE_SIGNATURE_PATTERN =
	/pub\(super\)\s+async\s+fn\s+security_headers_middleware\s*\([^)]*\)\s*->\s*Response\s*\{/;

function ownedHeaderSubset(
	headers: Headers
): Record<(typeof OWNED_DOCUMENT_SECURITY_HEADERS)[number], string> {
	return Object.fromEntries(
		OWNED_DOCUMENT_SECURITY_HEADERS.map((name) => [name, headers.get(name)])
	) as Record<(typeof OWNED_DOCUMENT_SECURITY_HEADERS)[number], string>;
}

function readApiMiddlewareSource(): string {
	const testDir = dirname(fileURLToPath(import.meta.url));
	const repoRoot = resolve(testDir, '..', '..', '..', '..');
	return readFileSync(resolve(repoRoot, 'infra/api/src/router/middleware.rs'), 'utf8');
}

function requireSingleSourceValue(source: string, pattern: RegExp, label: string): string {
	const matches = [...source.matchAll(new RegExp(pattern, 'g'))];
	expect(matches, `${label} must have exactly one Rust owner match`).toHaveLength(1);
	const value = matches[0]?.[1];
	if (!value) {
		throw new Error(`${label} Rust owner match did not capture a value`);
	}
	return value;
}

function requireSingleSourceMatch(source: string, pattern: RegExp, label: string): void {
	const matches = [...source.matchAll(new RegExp(pattern, 'g'))];
	expect(matches, `${label} must have exactly one Rust owner match`).toHaveLength(1);
}

function extractSecurityHeadersMiddlewareBody(source: string): string {
	const matches = [
		...source.matchAll(new RegExp(SECURITY_HEADERS_MIDDLEWARE_SIGNATURE_PATTERN, 'g'))
	];
	expect(
		matches,
		'security_headers_middleware must have exactly one Rust owner match'
	).toHaveLength(1);

	const match = matches[0];
	if (match.index === undefined) {
		throw new Error('security_headers_middleware Rust owner match did not expose a source index');
	}

	const bodyStart = match.index + match[0].length;
	let braceDepth = 1;

	for (let index = bodyStart; index < source.length; index += 1) {
		const character = source[index];
		if (character === '{') {
			braceDepth += 1;
		} else if (character === '}') {
			braceDepth -= 1;
			if (braceDepth === 0) {
				return source.slice(bodyStart, index);
			}
		}
	}

	throw new Error('security_headers_middleware Rust owner match did not close its body');
}

function readSharedApiHeaderValues(
	source = readApiMiddlewareSource()
): Record<keyof typeof SHARED_API_EMITTED_HEADER_PATTERNS | 'X-Robots-Tag', string> {
	const middlewareBody = extractSecurityHeadersMiddlewareBody(source);
	const emittedValues = Object.fromEntries(
		Object.entries(SHARED_API_EMITTED_HEADER_PATTERNS).map(([name, pattern]) => [
			name,
			requireSingleSourceValue(middlewareBody, pattern, name)
		])
	) as Record<keyof typeof SHARED_API_EMITTED_HEADER_PATTERNS, string>;

	requireSingleSourceMatch(
		middlewareBody,
		RUST_ROBOTS_HEADER_INSERTION_PATTERN,
		'X-Robots-Tag insertion'
	);
	return {
		...emittedValues,
		'X-Robots-Tag': requireSingleSourceValue(
			source,
			RUST_ROBOTS_HEADER_VALUE_PATTERN,
			'X-Robots-Tag value'
		)
	};
}

describe('document security headers', () => {
	it('sets the exact owned document security headers without owning unrelated headers', () => {
		const headers = new Headers({ 'Content-Type': 'text/html' });

		applyDocumentSecurityHeaders(headers);

		expect(ownedHeaderSubset(headers)).toEqual(EXPECTED_DOCUMENT_SECURITY_HEADERS);
		expect(headers.get('Content-Security-Policy')).toBeNull();
		expect(headers.get('Content-Security-Policy-Report-Only')).toBeNull();
		expect(headers.get('Content-Type')).toBe('text/html');
	});

	it('stays aligned with the API security middleware for shared emitted values', () => {
		const headers = new Headers();
		applyDocumentSecurityHeaders(headers);

		// Reading the Rust owner avoids restating its values in the drift guard.
		expect(ownedHeaderSubset(headers)).toMatchObject(readSharedApiHeaderValues());
	});

	it('requires the API middleware to emit X-Robots-Tag through ROBOTS_HEADER_VALUE', () => {
		const sourceWithoutRobotsEmission = `
			const ROBOTS_HEADER_VALUE: &str = "noindex, nofollow";
			pub(super) async fn security_headers_middleware(request: Request, next: Next) -> Response {
				let mut response = next.run(request).await;
				let headers = response.headers_mut();
				headers.insert(
					header::STRICT_TRANSPORT_SECURITY,
					HeaderValue::from_static("max-age=63072000; includeSubDomains"),
				);
				headers.insert(
					header::X_CONTENT_TYPE_OPTIONS,
					HeaderValue::from_static("nosniff"),
				);
				headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
				response
			}
		`;

		expect(() => readSharedApiHeaderValues(sourceWithoutRobotsEmission)).toThrow(
			'X-Robots-Tag insertion must have exactly one Rust owner match'
		);
	});

	it('rejects shared header fragments outside the API security middleware', () => {
		const sourceWithExternalFragmentsOnly = `
			const ROBOTS_HEADER_VALUE: &str = "noindex, nofollow";
			fn unrelated_security_header_example() {
				let headers = HeaderMap::new();
				headers.insert(
					header::STRICT_TRANSPORT_SECURITY,
					HeaderValue::from_static("max-age=63072000; includeSubDomains"),
				);
				headers.insert(
					header::X_CONTENT_TYPE_OPTIONS,
					HeaderValue::from_static("nosniff"),
				);
				headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
				headers.insert(
					HeaderName::from_static("x-robots-tag"),
					HeaderValue::from_static(ROBOTS_HEADER_VALUE),
				);
			}

			pub(super) async fn security_headers_middleware(request: Request, next: Next) -> Response {
				let response = next.run(request).await;
				response
			}
		`;

		expect(() => readSharedApiHeaderValues(sourceWithExternalFragmentsOnly)).toThrow(
			'Strict-Transport-Security must have exactly one Rust owner match'
		);
	});
});
