import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it } from 'vitest';
import OAuthButtons from './OAuthButtons.svelte';

afterEach(() => {
	cleanup();
});

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
});
