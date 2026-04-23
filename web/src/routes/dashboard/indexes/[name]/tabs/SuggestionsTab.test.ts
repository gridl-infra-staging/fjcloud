import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import SuggestionsTab from './SuggestionsTab.svelte';
import { sampleIndex, sampleQsConfig, sampleQsStatus } from '../detail.test.shared';

type SuggestionsProps = ComponentProps<typeof SuggestionsTab>;

function defaultProps(overrides: Partial<SuggestionsProps> = {}): SuggestionsProps {
	return {
		index: sampleIndex,
		qsConfig: sampleQsConfig,
		qsStatus: sampleQsStatus,
		qsConfigError: '',
		qsConfigSaved: false,
		qsConfigDeleted: false,
		...overrides
	};
}

afterEach(cleanup);

describe('SuggestionsTab', () => {
	describe('section shell', () => {
		it('renders the Suggestions heading and description', () => {
			render(SuggestionsTab, { props: defaultProps() });

			expect(screen.getByText('Suggestions')).toBeInTheDocument();
			expect(screen.getByText(/configure query suggestions/i)).toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(SuggestionsTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="suggestions-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});
	});

	describe('success and error banners', () => {
		it('shows saved banner when qsConfigSaved is true', () => {
			render(SuggestionsTab, { props: defaultProps({ qsConfigSaved: true }) });
			expect(screen.getByText('Suggestions config saved.')).toBeInTheDocument();
		});

		it('shows deleted banner when qsConfigDeleted is true', () => {
			render(SuggestionsTab, { props: defaultProps({ qsConfigDeleted: true }) });
			expect(screen.getByText('Suggestions config deleted.')).toBeInTheDocument();
		});

		it('shows error banner with error message', () => {
			render(SuggestionsTab, { props: defaultProps({ qsConfigError: 'Parse error' }) });
			expect(screen.getByText('Parse error')).toBeInTheDocument();
		});

		it('does not show banners by default', () => {
			render(SuggestionsTab, { props: defaultProps() });
			expect(screen.queryByText('Suggestions config saved.')).not.toBeInTheDocument();
			expect(screen.queryByText('Suggestions config deleted.')).not.toBeInTheDocument();
		});
	});

	describe('no-config prompt', () => {
		it('shows no-config message when qsConfig is null', () => {
			render(SuggestionsTab, {
				props: defaultProps({ qsConfig: null, qsStatus: null })
			});
			expect(screen.getByText('No configuration')).toBeInTheDocument();
			expect(
				screen.getByRole('button', { name: /configure query suggestions/i })
			).toBeInTheDocument();
		});

		it('does not show no-config prompt when config exists', () => {
			render(SuggestionsTab, { props: defaultProps() });
			expect(screen.queryByText('No configuration')).not.toBeInTheDocument();
		});
	});

	describe('config form', () => {
		it('has saveQsConfig form wired to ?/saveQsConfig action', () => {
			const { container } = render(SuggestionsTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/saveQsConfig"]');
			expect(form).not.toBeNull();
			expect(screen.getByRole('button', { name: /save suggestions/i })).toBeInTheDocument();
		});

		it('config textarea is seeded from existing qsConfig', () => {
			render(SuggestionsTab, { props: defaultProps() });

			const textarea = screen.getByLabelText(/query suggestions json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed.indexName).toBe('products');
			expect(parsed.sourceIndices).toBeDefined();
		});

		it('config textarea seeded with index.name when qsConfig is null', () => {
			render(SuggestionsTab, {
				props: defaultProps({ qsConfig: null, qsStatus: null })
			});

			const textarea = screen.getByLabelText(/query suggestions json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed.indexName).toBe('products');
			expect(parsed.languages).toEqual(['en']);
		});

		it('shows delete button when config exists', () => {
			render(SuggestionsTab, { props: defaultProps() });

			expect(
				screen.getByRole('button', { name: /delete suggestions config/i })
			).toBeInTheDocument();
		});

		it('hides delete button when qsConfig is null', () => {
			render(SuggestionsTab, {
				props: defaultProps({ qsConfig: null, qsStatus: null })
			});

			expect(
				screen.queryByRole('button', { name: /delete suggestions config/i })
			).not.toBeInTheDocument();
		});

		it('delete button uses formaction ?/deleteQsConfig', () => {
			const { container } = render(SuggestionsTab, { props: defaultProps() });

			const deleteBtn = container.querySelector('button[formaction="?/deleteQsConfig"]');
			expect(deleteBtn).not.toBeNull();
		});
	});

	describe('build status', () => {
		it('renders build status when qsStatus is provided', () => {
			render(SuggestionsTab, { props: defaultProps() });

			expect(screen.getByText('Build Status')).toBeInTheDocument();
			expect(screen.getByText(/running: no/i)).toBeInTheDocument();
			expect(screen.getByText(/last built:/i)).toBeInTheDocument();
			expect(screen.getByText(/last successful build:/i)).toBeInTheDocument();
		});

		it('shows running status as yes when isRunning is true', () => {
			render(SuggestionsTab, {
				props: defaultProps({
					qsStatus: { ...sampleQsStatus, isRunning: true }
				})
			});
			expect(screen.getByText(/running: yes/i)).toBeInTheDocument();
		});

		it('does not render build status when qsStatus is null', () => {
			render(SuggestionsTab, {
				props: defaultProps({ qsStatus: null })
			});
			expect(screen.queryByText('Build Status')).not.toBeInTheDocument();
		});

		it('shows never for missing build timestamps', () => {
			render(SuggestionsTab, {
				props: defaultProps({
					qsStatus: {
						indexName: 'products',
						isRunning: false,
						lastBuiltAt: null as unknown as string,
						lastSuccessfulBuiltAt: null as unknown as string
					}
				})
			});
			const texts = screen.getAllByText(/never/);
			expect(texts.length).toBeGreaterThanOrEqual(2);
		});
	});
});
