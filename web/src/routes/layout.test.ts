import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

const {
	installBrowserRuntimeFailureListenersMock,
	reportBrowserRuntimeFailureMock,
	teardownMock,
	pageState
} = vi.hoisted(() => ({
	installBrowserRuntimeFailureListenersMock: vi.fn(),
	reportBrowserRuntimeFailureMock: vi.fn(),
	teardownMock: vi.fn(),
	pageState: { url: new URL('http://localhost/') }
}));

vi.mock('$lib/error-boundary/client-runtime', () => ({
	installBrowserRuntimeFailureListeners: installBrowserRuntimeFailureListenersMock,
	reportBrowserRuntimeFailure: reportBrowserRuntimeFailureMock
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

import Layout from './+layout.svelte';

const childSnippet = createRawSnippet(() => ({
	render: () => '<div data-testid="child-content">child</div>',
	setup: () => {}
}));

function renderAtPath(pathname: string) {
	pageState.url = new URL(`http://localhost${pathname}`);
	return render(Layout, { children: childSnippet });
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	pageState.url = new URL('http://localhost/');
});

describe('root layout browser runtime wiring', () => {
	it('installs browser runtime listeners exactly once with the reporting callback and tears down on unmount', () => {
		installBrowserRuntimeFailureListenersMock.mockReturnValue(teardownMock);

		const { unmount } = render(Layout, { children: childSnippet });

		expect(installBrowserRuntimeFailureListenersMock).toHaveBeenCalledTimes(1);
		expect(installBrowserRuntimeFailureListenersMock).toHaveBeenCalledWith(
			reportBrowserRuntimeFailureMock
		);

		unmount();

		expect(teardownMock).toHaveBeenCalledTimes(1);
	});
});

describe('root layout shared toast seam', () => {
	it.each(['/', '/console'])('mounts the shared toaster and child content on %s', (pathname) => {
		renderAtPath(pathname);

		expect(screen.getByTestId('shared-toast-mount')).toBeInTheDocument();
		expect(screen.getByTestId('child-content')).toBeInTheDocument();
	});
});

describe('root layout public trust chrome ownership', () => {
	it.each(['/', '/pricing', '/terms', '/privacy', '/dpa'])(
		'renders shared public trust chrome on %s',
		(pathname) => {
			renderAtPath(pathname);

			const publicBrandLink = screen.getByRole('link', { name: 'Flapjack Cloud' });
			expect(publicBrandLink).toHaveAttribute('href', '/');
			expect(publicBrandLink).toHaveClass("font-['Cabinet']");
			expect(screen.getByTestId('public-beta-banner')).toBeInTheDocument();
			expect(screen.getByTestId('public-beta-banner')).toHaveClass('bg-flapjack-cream');
			expect(screen.getByRole('link', { name: /learn about the beta/i })).toHaveAttribute(
				'href',
				'/beta'
			);
			const publicNav = screen.getByRole('navigation', { name: '' });
			expect(within(publicNav).getByRole('link', { name: 'Log In' })).toHaveAttribute(
				'href',
				'/login'
			);
			expect(within(publicNav).queryByRole('link', { name: 'Sign Up' })).not.toBeInTheDocument();
			expect(screen.getByText(/Contact:\s*support@flapjack\.foo/i)).toBeInTheDocument();
			const legalFooterNav = within(screen.getByRole('contentinfo')).getByRole('navigation', {
				name: 'Legal'
			});
			expect(within(legalFooterNav).getByRole('link', { name: 'Terms' })).toHaveAttribute(
				'href',
				'/terms'
			);
			expect(within(legalFooterNav).getByRole('link', { name: 'Terms' })).toHaveClass(
				'text-flapjack-rose'
			);
			expect(within(legalFooterNav).getByRole('link', { name: 'Privacy' })).toHaveAttribute(
				'href',
				'/privacy'
			);
			expect(within(legalFooterNav).getByRole('link', { name: 'DPA' })).toHaveAttribute(
				'href',
				'/dpa'
			);
			expect(within(legalFooterNav).getByRole('link', { name: 'Status' })).toHaveAttribute(
				'href',
				'/status'
			);
		}
	);

	it.each(['/terms', '/privacy', '/dpa'])(
		'renders shared legal back-link wrapper only for legal route %s',
		(pathname) => {
			renderAtPath(pathname);

			expect(screen.getByRole('link', { name: 'Back to Flapjack Cloud' })).toHaveAttribute(
				'href',
				'/'
			);
		}
	);

	it.each([
		'/login',
		'/signup',
		'/forgot-password',
		'/reset-password/token-123',
		'/verify-email/token-123',
		'/beta',
		'/status',
		'/console',
		'/console/account',
		'/console/settings',
		'/admin',
		'/admin/fleet'
	])('keeps public-shell beta and legal wrapper absent on %s', (pathname) => {
		renderAtPath(pathname);

		expect(screen.queryByTestId('public-beta-banner')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: 'Back to Flapjack Cloud' })).not.toBeInTheDocument();
		expect(screen.getByTestId('child-content')).toBeInTheDocument();
	});
});
