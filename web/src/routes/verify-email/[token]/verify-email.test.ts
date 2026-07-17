import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import VerifyEmailPage from './+page.svelte';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';

afterEach(cleanup);

function renderVerifyEmailPage(success: boolean, message: string) {
	return render(VerifyEmailPage, {
		data: { success, message }
	});
}

describe('Verify email page', () => {
	it('renders polished success outcome copy with login CTA', () => {
		renderVerifyEmailPage(true, 'Email verified successfully');

		expect(screen.getByRole('heading', { level: 1, name: 'Email verified' })).toBeInTheDocument();
		expect(screen.getByText('Email verified successfully')).toBeInTheDocument();
		expect(screen.getByText('You can now log in to Flapjack Cloud.')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
			'href',
			'/login'
		);
	});

	it('renders polished failure outcome copy with login CTA', () => {
		renderVerifyEmailPage(false, 'verification token expired');

		expect(
			screen.getByRole('heading', { level: 1, name: 'We could not verify your email' })
		).toBeInTheDocument();
		expect(screen.getByText('verification token expired')).toBeInTheDocument();
		expect(
			screen.getByText(
				'The link may be expired or already used. Log in to request a fresh verification email.'
			)
		).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
			'href',
			'/login'
		);
	});

	it('renders a support mailto link on verification failures', () => {
		renderVerifyEmailPage(false, 'verification token expired');

		const supportLink = screen.getByRole('link', { name: SUPPORT_EMAIL });
		expect(supportLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
		expect(supportLink.closest('p')).toHaveTextContent(
			`If the problem persists, contact ${SUPPORT_EMAIL}.`
		);
	});
});
