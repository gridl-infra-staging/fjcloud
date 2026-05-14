export function authCookieOptions(url: URL, maxAge: number, path = '/') {
	return {
		path,
		httpOnly: true,
		secure: url.protocol === 'https:',
		sameSite: 'lax' as const,
		maxAge
	};
}

function oauthCookieDomain(hostname: string): string | undefined {
	return hostname.endsWith('.flapjack.foo') || hostname === 'flapjack.foo'
		? '.flapjack.foo'
		: undefined;
}

export function oauthStateCookieOptions(url: URL) {
	const secure = url.protocol === 'https:';
	return {
		path: '/',
		httpOnly: true,
		secure,
		sameSite: secure ? ('none' as const) : ('lax' as const),
		domain: oauthCookieDomain(url.hostname)
	};
}
