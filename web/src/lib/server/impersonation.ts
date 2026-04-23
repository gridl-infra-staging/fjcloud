/**
 * Shared impersonation helpers — single source of truth for return-path validation.
 *
 * The impersonation cookie value is untrusted input (it's set by server code but
 * read back from the browser). Only allow redirects to local /admin paths to
 * prevent open-redirect attacks.
 */

/**
 * Validates and sanitizes the impersonation return path.
 * Returns the path if it is a local /admin URL that survives URL normalization unchanged.
 */
export function sanitizeImpersonationReturnPath(
	value: string | undefined
): string | null {
	if (!value) return null;

	let parsed: URL;
	try {
		parsed = new URL(value, 'http://impersonation.local');
	} catch {
		return null;
	}

	// Only allow same-origin relative URLs. This rejects absolute URLs,
	// protocol-relative inputs, and query/fragment-only values.
	if (parsed.origin !== 'http://impersonation.local') return null;

	// Only allow the /admin root plus descendants, queries, and fragments.
	// Reject broader prefixes like /administrator or /admin-api.
	if (!/^\/admin(?:\/|$)/.test(parsed.pathname)) return null;

	const normalized = `${parsed.pathname}${parsed.search}${parsed.hash}`;

	// Reject dot-segment traversal or other encoded forms that normalize to a
	// different path than what the browser received.
	if (normalized !== value) return null;

	return normalized;
}
