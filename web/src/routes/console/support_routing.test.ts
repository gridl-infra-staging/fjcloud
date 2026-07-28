import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as formatModule from '$lib/format';
import { CANONICAL_PUBLIC_API_DOCS_URL } from '$lib/public_api';
import { layoutTestDefaults } from './layout-test-context';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const { gotoMock, pageState } = vi.hoisted(() => ({
	gotoMock: vi.fn(),
	pageState: {
		url: new URL('http://localhost/console'),
		form: null as Record<string, unknown> | null
	}
}));

vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args)
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

const fetchMock = vi.fn();
vi.stubGlobal('fetch', fetchMock);

import LayoutComponent from './+layout.svelte';

const {
	COMMUNITY_IDEAS_URL,
	COMMUNITY_QA_URL,
	DOCUMENTATION_SOURCE_URL,
	ENGINE_ISSUES_URL,
	SECURITY_POLICY_URL,
	SUPPORT_EMAIL,
	buildCloudSupportMailto
} = formatModule;
const SUPPORT_TEST_ROUTE = '/console/indexes/products';
const SUPPORT_TEST_TIMESTAMP = '2026-07-27T12:34:56.000Z';

const childSnippet = createRawSnippet(() => ({
	render: () => '<div data-testid="child-content">child</div>',
	setup: () => {}
}));

function renderLayout() {
	return render(LayoutComponent, {
		data: { ...layoutTestDefaults, user: { customerId: 'cust-1' } },
		children: childSnippet
	});
}

async function assertSupportRoutingContract(container: HTMLElement) {
	const supportAffordances = within(container).getAllByRole('button', {
		name: 'Report a problem or request a feature'
	});
	expect(supportAffordances).toHaveLength(1);

	const supportAffordance = supportAffordances[0];
	if (supportAffordance.getAttribute('aria-expanded') === 'false') {
		await fireEvent.click(supportAffordance);
	}

	expect(within(container).queryByRole('link', { name: 'Support' })).not.toBeInTheDocument();
	const bareSupportMailtoLinks = within(container)
		.queryAllByRole('link')
		.filter((link) => link.getAttribute('href') === `mailto:${SUPPORT_EMAIL}`);
	expect(bareSupportMailtoLinks).toHaveLength(0);

	const cloudSupport = within(container).getByRole('link', {
		name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
	});
	expect(cloudSupport).toHaveAttribute(
		'href',
		buildCloudSupportMailto(SUPPORT_TEST_ROUTE, SUPPORT_TEST_TIMESTAMP)
	);

	expect(within(container).getByRole('link', { name: 'Share an idea' })).toHaveAttribute(
		'href',
		COMMUNITY_IDEAS_URL
	);
	expect(within(container).getByRole('link', { name: 'Ask a question' })).toHaveAttribute(
		'href',
		COMMUNITY_QA_URL
	);
	expect(within(container).getByRole('link', { name: 'Report an engine bug' })).toHaveAttribute(
		'href',
		ENGINE_ISSUES_URL
	);
	expect(
		within(container).getByRole('link', { name: 'Propose a documentation correction' })
	).toHaveAttribute('href', DOCUMENTATION_SOURCE_URL);
	expect(
		within(container).getByRole('link', { name: 'Read private security reporting instructions' })
	).toHaveAttribute('href', SECURITY_POLICY_URL);
	expect(container).toHaveTextContent(
		'Do not include account, invoice, index, or customer-data details in public GitHub posts.'
	);
	expect(container).toHaveTextContent(
		'Security vulnerabilities use the private reporting policy, not public trackers.'
	);
	expect(within(container).getByRole('link', { name: 'API Docs' })).toHaveAttribute(
		'href',
		CANONICAL_PUBLIC_API_DOCS_URL
	);
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.useRealTimers();
	pageState.url = new URL('http://localhost/console');
	pageState.form = null;
});

describe('Dashboard support routing', () => {
	it('uses a real disclosure state for the desktop support-routing affordance', async () => {
		renderLayout();

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		const supportAffordance = within(desktopWrapper).getByRole('button', {
			name: 'Report a problem or request a feature'
		});
		expect(supportAffordance).toHaveAttribute('aria-expanded', 'false');
		expect(
			within(desktopWrapper).queryByRole('link', {
				name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
			})
		).not.toBeInTheDocument();

		await fireEvent.click(supportAffordance);

		expect(supportAffordance).toHaveAttribute('aria-expanded', 'true');
		expect(
			within(desktopWrapper).getByRole('link', {
				name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
			})
		).toBeInTheDocument();
	});

	it('exposes one complete support-routing affordance in the desktop Help section', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(SUPPORT_TEST_TIMESTAMP);
		pageState.url = new URL(`http://localhost${SUPPORT_TEST_ROUTE}`);
		renderLayout();

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		await assertSupportRoutingContract(desktopWrapper);
	});

	it('exposes one complete support-routing affordance after opening the mobile Help drawer', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(SUPPORT_TEST_TIMESTAMP);
		pageState.url = new URL(`http://localhost${SUPPORT_TEST_ROUTE}`);
		renderLayout();

		const mobileWrapper = screen.getByTestId('dashboard-nav-mobile-drawer');
		expect(mobileWrapper).toHaveAttribute('data-nav-open', 'false');
		expect(
			within(mobileWrapper).queryByRole('button', {
				name: 'Report a problem or request a feature'
			})
		).not.toBeInTheDocument();
		await fireEvent.click(screen.getByTestId('dashboard-mobile-nav-trigger'));
		expect(mobileWrapper).toHaveAttribute('data-nav-open', 'true');

		const supportAffordance = within(mobileWrapper).getByRole('button', {
			name: 'Report a problem or request a feature'
		});
		expect(supportAffordance).toHaveAttribute('aria-expanded', 'false');
		expect(
			within(mobileWrapper).queryByRole('link', {
				name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
			})
		).not.toBeInTheDocument();

		await fireEvent.click(supportAffordance);

		expect(supportAffordance).toHaveAttribute('aria-expanded', 'true');
		expect(
			within(mobileWrapper).getByRole('link', {
				name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
			})
		).toBeInTheDocument();
		await assertSupportRoutingContract(mobileWrapper);
	});

	it('keeps desktop and mobile support disclosure state independent in one shell instance', async () => {
		renderLayout();

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		const desktopSupportAffordance = within(desktopWrapper).getByRole('button', {
			name: 'Report a problem or request a feature'
		});
		await fireEvent.click(desktopSupportAffordance);
		expect(desktopSupportAffordance).toHaveAttribute('aria-expanded', 'true');

		await fireEvent.click(screen.getByTestId('dashboard-mobile-nav-trigger'));
		const mobileWrapper = screen.getByTestId('dashboard-nav-mobile-drawer');
		const mobileSupportAffordance = within(mobileWrapper).getByRole('button', {
			name: 'Report a problem or request a feature'
		});
		expect(mobileSupportAffordance).toHaveAttribute('aria-expanded', 'false');
		expect(
			within(mobileWrapper).queryByRole('link', {
				name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
			})
		).not.toBeInTheDocument();
	});
});
