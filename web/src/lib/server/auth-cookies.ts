export function authCookieOptions(url: URL, maxAge: number, path = '/') {
	return {
		path,
		httpOnly: true,
		secure: url.protocol === 'https:',
		sameSite: 'lax' as const,
		maxAge
	};
}
