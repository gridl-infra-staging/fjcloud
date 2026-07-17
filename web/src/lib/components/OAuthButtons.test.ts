import { cleanup, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import OAuthButtons from './OAuthButtons.svelte';

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

function stubOAuthStatusFetch(payload: unknown): ReturnType<typeof vi.fn> {
	const fetchMock = vi.fn().mockResolvedValue(
		new Response(JSON.stringify(payload), {
			status: 200,
			headers: { 'Content-Type': 'application/json' }
		})
	);
	vi.stubGlobal('fetch', fetchMock);
	return fetchMock;
}

function expectEnabledOAuthLinks(apiBaseUrl = 'http://127.0.0.1:3001'): void {
	expect(screen.getByTestId('oauth-button-google')).toHaveAttribute(
		'href',
		`${apiBaseUrl}/auth/oauth/google/start`
	);
	expect(screen.getByTestId('oauth-button-github')).toHaveAttribute(
		'href',
		`${apiBaseUrl}/auth/oauth/github/start`
	);
	expect(screen.queryByTestId('oauth-unavailable-google')).not.toBeInTheDocument();
	expect(screen.queryByTestId('oauth-unavailable-github')).not.toBeInTheDocument();
}

describe('OAuthButtons', () => {
	it('renders Google and GitHub OAuth links with expected hrefs and labels', () => {
		render(OAuthButtons, {
			apiBaseUrl: 'http://127.0.0.1:3001'
		});

		const googleButton = screen.getByTestId('oauth-button-google');
		expect(googleButton).toHaveAttribute('href', 'http://127.0.0.1:3001/auth/oauth/google/start');
		expect(googleButton).toHaveTextContent('Continue with Google');
		expect(googleButton).toHaveClass('text-flapjack-ink/80');
		expect(googleButton).toHaveClass('border-flapjack-ink/30');

		const githubButton = screen.getByTestId('oauth-button-github');
		expect(githubButton).toHaveAttribute('href', 'http://127.0.0.1:3001/auth/oauth/github/start');
		expect(githubButton).toHaveTextContent('Continue with GitHub');
		expect(githubButton).toHaveClass('text-flapjack-ink/80');
		expect(githubButton).toHaveClass('border-flapjack-ink/30');
	});

	it('falls back to a same-origin OAuth path when apiBaseUrl uses an unsafe scheme', () => {
		render(OAuthButtons, {
			apiBaseUrl: 'javascript:alert(1)'
		});

		expect(screen.getByTestId('oauth-button-google')).toHaveAttribute(
			'href',
			'/auth/oauth/google/start'
		);
		expect(screen.getByTestId('oauth-button-github')).toHaveAttribute(
			'href',
			'/auth/oauth/github/start'
		);
	});

	it('preserves safe relative API prefixes while rejecting protocol-relative bases', () => {
		const { rerender } = render(OAuthButtons, {
			apiBaseUrl: '/backend/'
		});

		expect(screen.getByTestId('oauth-button-google')).toHaveAttribute(
			'href',
			'/backend/auth/oauth/google/start'
		);

		rerender({
			apiBaseUrl: '//evil.example'
		});

		expect(screen.getByTestId('oauth-button-google')).toHaveAttribute(
			'href',
			'/auth/oauth/google/start'
		);
	});

	it('fetches OAuth provider status once while preserving enabled links during loading', async () => {
		const fetchMock = vi.fn(() => new Promise<Response>(() => {}));
		vi.stubGlobal('fetch', fetchMock);

		render(OAuthButtons, {
			apiBaseUrl: 'http://127.0.0.1:3001'
		});

		expectEnabledOAuthLinks();
		await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
		expect(fetchMock).toHaveBeenCalledWith('http://127.0.0.1:3001/auth/oauth/_status');
	});

	it('disables only Google when the OAuth status reports Google unavailable', async () => {
		stubOAuthStatusFetch({
			google: { enabled: false },
			github: { enabled: true }
		});

		render(OAuthButtons, {
			apiBaseUrl: 'http://127.0.0.1:3001'
		});

		await waitFor(() =>
			expect(screen.getByTestId('oauth-unavailable-google')).toHaveTextContent(
				'Google sign-in is unavailable in this environment.'
			)
		);
		const googleButton = screen.getByTestId('oauth-button-google');
		expect(googleButton).toBeDisabled();
		expect(googleButton).not.toHaveAttribute('href');
		expect(googleButton).not.toHaveAttribute(
			'href',
			'http://127.0.0.1:3001/auth/oauth/google/start'
		);

		expect(screen.getByTestId('oauth-button-github')).toHaveAttribute(
			'href',
			'http://127.0.0.1:3001/auth/oauth/github/start'
		);
		expect(screen.queryByTestId('oauth-unavailable-github')).not.toBeInTheDocument();
	});

	it('disables only GitHub when the OAuth status reports GitHub unavailable', async () => {
		stubOAuthStatusFetch({
			google: { enabled: true },
			github: { enabled: false }
		});

		render(OAuthButtons, {
			apiBaseUrl: 'http://127.0.0.1:3001'
		});

		await waitFor(() =>
			expect(screen.getByTestId('oauth-unavailable-github')).toHaveTextContent(
				'GitHub sign-in is unavailable in this environment.'
			)
		);
		const githubButton = screen.getByTestId('oauth-button-github');
		expect(githubButton).toBeDisabled();
		expect(githubButton).not.toHaveAttribute('href');
		expect(githubButton).not.toHaveAttribute(
			'href',
			'http://127.0.0.1:3001/auth/oauth/github/start'
		);

		expect(screen.getByTestId('oauth-button-google')).toHaveAttribute(
			'href',
			'http://127.0.0.1:3001/auth/oauth/google/start'
		);
		expect(screen.queryByTestId('oauth-unavailable-google')).not.toBeInTheDocument();
	});

	it.each([
		['non-OK responses', () => Promise.resolve(new Response('{}', { status: 500 }))],
		['thrown fetches', () => Promise.reject(new Error('network failed'))],
		[
			'malformed JSON',
			() =>
				Promise.resolve(
					new Response('{', {
						status: 200,
						headers: { 'Content-Type': 'application/json' }
					})
				)
		],
		[
			'missing provider keys',
			() =>
				Promise.resolve(
					new Response(JSON.stringify({ google: { enabled: false } }), {
						status: 200,
						headers: { 'Content-Type': 'application/json' }
					})
				)
		]
	])('preserves enabled links without helper copy for %s', async (_label, responseFactory) => {
		const fetchMock = vi.fn(responseFactory);
		vi.stubGlobal('fetch', fetchMock);

		render(OAuthButtons, {
			apiBaseUrl: 'http://127.0.0.1:3001'
		});

		await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
		expectEnabledOAuthLinks();
	});
});
