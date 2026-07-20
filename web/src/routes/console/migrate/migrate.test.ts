import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/migrate') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

import MigratePage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

function renderMigratePage() {
	return render(MigratePage, {
		data: {
			...layoutTestDefaults,
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.',
				capabilities: { cancel: false, resume: false, replace: false }
			}
		}
	});
}

describe('Migrate page unavailable state', () => {
	it('renders the authenticated unavailable explanation page', () => {
		const { container } = renderMigratePage();

		expect(screen.getByRole('heading', { name: /migrate from algolia/i })).toBeInTheDocument();
		expect(screen.getByTestId('migration-unavailable')).toHaveTextContent(
			'Algolia migration is temporarily unavailable while we replace the importer.'
		);
		expect(
			screen.getByText(/We have temporarily turned off new Algolia imports/i)
		).toBeInTheDocument();
		expect(container.querySelector('form')).not.toBeInTheDocument();
	});

	it('does not render migration credentials, source controls, or import CTAs', () => {
		renderMigratePage();

		expect(screen.queryByLabelText(/app.*id/i)).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/api key/i)).not.toBeInTheDocument();
		expect(screen.queryByRole('textbox', { name: /source index/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('textbox', { name: /target index/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('textbox', { name: /destination index/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /browse indexes/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /migrate/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /resume/i })).not.toBeInTheDocument();
	});

	it('does not mount the dormant migration create flow component', () => {
		renderMigratePage();

		// The create-mode flow exists as an unmounted component cluster. The served
		// route must stay on the unavailable state until activation mounts it.
		expect(screen.queryByTestId('migration-create-flow')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/search source indexes/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
	});

	it('renders no dormant preview, job-history, or operation links', () => {
		const { container } = renderMigratePage();

		expect(screen.getByTestId('migration-unavailable')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-recent-imports')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-job-detail')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /open import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /preview/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /start a new import/i })).not.toBeInTheDocument();

		const renderedLinks = Array.from(container.querySelectorAll('a')).map((link) =>
			link.getAttribute('href')
		);
		expect(renderedLinks).toEqual(['mailto:support@flapjack.foo']);
		expect(container.innerHTML).not.toMatch(/\/migration\/|\/console\/migrate\/job_|preview/i);
	});
});
