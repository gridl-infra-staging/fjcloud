import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import DocumentsTab from './DocumentsTab.svelte';
import { sampleIndex, sampleDocuments } from '../detail.test.shared';
import type { BrowseObjectsResponse } from '$lib/api/types';

type DocumentsProps = ComponentProps<typeof DocumentsTab>;

function defaultProps(overrides: Partial<DocumentsProps> = {}): DocumentsProps {
	return {
		index: sampleIndex,
		documents: sampleDocuments,
		documentsUploadSuccess: false,
		documentsAddSuccess: false,
		documentsBrowseSuccess: false,
		documentsDeleteSuccess: false,
		documentsUploadError: '',
		documentsAddError: '',
		documentsBrowseError: '',
		documentsDeleteError: '',
		...overrides
	};
}

function emptyDocuments(): BrowseObjectsResponse {
	return {
		hits: [],
		cursor: null,
		nbHits: 0,
		page: 0,
		nbPages: 0,
		hitsPerPage: 20,
		query: '',
		params: ''
	};
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('DocumentsTab — default render', () => {
	it('renders the documents section with data-testid and index name', () => {
		render(DocumentsTab, defaultProps());

		const section = screen.getByTestId('documents-section');
		expect(section).toBeInTheDocument();
		expect(section.getAttribute('data-index')).toBe('products');
	});

	it('renders section heading and description', () => {
		render(DocumentsTab, defaultProps());

		expect(screen.getByRole('heading', { name: /documents/i })).toBeInTheDocument();
		expect(screen.getByText(/upload json or csv records/i)).toBeInTheDocument();
	});

	it('renders manual single-record JSON add form with default text', () => {
		const { container } = render(DocumentsTab, defaultProps());

		const textarea = screen.getByRole('textbox', { name: /record json/i });
		expect(textarea).toBeInTheDocument();
		expect((textarea as HTMLTextAreaElement).value).toContain('"objectID"');
		expect((textarea as HTMLTextAreaElement).value).toContain('"title"');
		expect(container.querySelector('form[action="?/addDocument"]')).not.toBeNull();
		expect(screen.getByRole('button', { name: /add record/i })).toBeInTheDocument();
	});

	it('renders query-driven browse controls and browse form action', () => {
		const { container } = render(DocumentsTab, defaultProps());

		expect(screen.getByRole('textbox', { name: /browse query/i })).toBeInTheDocument();
		expect(container.querySelector('form[action="?/browseDocuments"]')).not.toBeNull();
		expect(screen.getByRole('button', { name: /browse documents/i })).toBeInTheDocument();
	});

	it('renders upload file input and submit button', () => {
		const { container } = render(DocumentsTab, defaultProps());

		expect(screen.getByLabelText(/upload json or csv file/i)).toBeInTheDocument();
		expect(container.querySelector('form[action="?/uploadDocuments"]')).not.toBeNull();
		expect(screen.getByRole('button', { name: /upload records/i })).toBeInTheDocument();
	});
});

describe('DocumentsTab — success banners', () => {
	it('shows upload success banner', () => {
		render(DocumentsTab, defaultProps({ documentsUploadSuccess: true }));
		expect(screen.getByText(/documents uploaded/i)).toBeInTheDocument();
	});

	it('shows add success banner', () => {
		render(DocumentsTab, defaultProps({ documentsAddSuccess: true }));
		expect(screen.getByText(/document added/i)).toBeInTheDocument();
	});

	it('shows browse success banner', () => {
		render(DocumentsTab, defaultProps({ documentsBrowseSuccess: true }));
		expect(screen.getByText(/documents refreshed/i)).toBeInTheDocument();
	});

	it('shows delete success banner', () => {
		render(DocumentsTab, defaultProps({ documentsDeleteSuccess: true }));
		expect(screen.getByText(/document deleted/i)).toBeInTheDocument();
	});
});

describe('DocumentsTab — error banners', () => {
	it('shows upload error banner', () => {
		render(DocumentsTab, defaultProps({ documentsUploadError: 'batch must be valid JSON' }));
		expect(screen.getByText(/batch must be valid json/i)).toBeInTheDocument();
	});

	it('shows add error banner', () => {
		render(DocumentsTab, defaultProps({ documentsAddError: 'invalid document JSON' }));
		expect(screen.getByText(/invalid document json/i)).toBeInTheDocument();
	});

	it('shows browse error banner', () => {
		render(DocumentsTab, defaultProps({ documentsBrowseError: 'browse upstream failed' }));
		expect(screen.getByText(/browse upstream failed/i)).toBeInTheDocument();
	});

	it('shows delete error banner', () => {
		render(DocumentsTab, defaultProps({ documentsDeleteError: 'delete upstream failed' }));
		expect(screen.getByText(/delete upstream failed/i)).toBeInTheDocument();
	});
});

describe('DocumentsTab — empty vs populated browse state', () => {
	it('shows empty state when browse payload has no records', () => {
		render(DocumentsTab, defaultProps({ documents: emptyDocuments() }));
		expect(screen.getByText(/no documents found/i)).toBeInTheDocument();
	});

	it('renders document hits with objectID and JSON preview', () => {
		render(DocumentsTab, defaultProps());

		expect(screen.getByText('doc-1')).toBeInTheDocument();
		// The pre element should contain the JSON of the hit
		const preElements = screen.getByTestId('documents-section').querySelectorAll('pre');
		expect(preElements.length).toBeGreaterThan(0);
	});

	it('renders per-record delete control wired to deleteDocument action', () => {
		const { container } = render(DocumentsTab, defaultProps());

		expect(screen.getByRole('button', { name: /delete document doc-1/i })).toBeInTheDocument();
		expect(container.querySelector('form[action="?/deleteDocument"]')).not.toBeNull();
	});
});

describe('DocumentsTab — form action contracts', () => {
	it('has uploadDocuments form action', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/uploadDocuments"]')).not.toBeNull();
	});

	it('has addDocument form action', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/addDocument"]')).not.toBeNull();
	});

	it('has browseDocuments form action', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/browseDocuments"]')).not.toBeNull();
	});

	it('has deleteDocument form action with objectID hidden input', () => {
		const { container } = render(DocumentsTab, defaultProps());
		const deleteForm = container.querySelector('form[action="?/deleteDocument"]');
		expect(deleteForm).not.toBeNull();
		const objectIDInput = deleteForm!.querySelector('input[name="objectID"]') as HTMLInputElement;
		expect(objectIDInput).not.toBeNull();
		expect(objectIDInput.value).toBe('doc-1');
	});
});

describe('DocumentsTab — file-selection preview', () => {
	it('shows JSON upload preview record count from selected file', async () => {
		render(DocumentsTab, defaultProps());

		const input = screen.getByLabelText(/upload json or csv file/i) as HTMLInputElement;
		const file = new File(
			[JSON.stringify([{ objectID: 'obj-1' }, { objectID: 'obj-2' }])],
			'records.json',
			{ type: 'application/json' }
		);

		await fireEvent.change(input, { target: { files: [file] } });
		expect(await screen.findByText('Parsed records: 2')).toBeInTheDocument();
	});

	it('shows CSV upload preview record count from selected file', async () => {
		render(DocumentsTab, defaultProps());

		const input = screen.getByLabelText(/upload json or csv file/i) as HTMLInputElement;
		const file = new File(['objectID,title\nobj-1,First\nobj-2,Second'], 'records.csv', {
			type: 'text/csv'
		});

		await fireEvent.change(input, { target: { files: [file] } });
		expect(await screen.findByText('Parsed records: 2')).toBeInTheDocument();
	});

	it('shows detected format label after file selection', async () => {
		render(DocumentsTab, defaultProps());

		const input = screen.getByLabelText(/upload json or csv file/i) as HTMLInputElement;
		const file = new File([JSON.stringify([{ objectID: 'obj-1' }])], 'data.json', {
			type: 'application/json'
		});

		await fireEvent.change(input, { target: { files: [file] } });
		expect(await screen.findByText(/detected format: json/i)).toBeInTheDocument();
	});

	it('shows selected file name after file selection', async () => {
		render(DocumentsTab, defaultProps());

		const input = screen.getByLabelText(/upload json or csv file/i) as HTMLInputElement;
		const file = new File([JSON.stringify([{ objectID: 'obj-1' }])], 'my-data.json', {
			type: 'application/json'
		});

		await fireEvent.change(input, { target: { files: [file] } });
		expect(await screen.findByText(/selected file: my-data\.json/i)).toBeInTheDocument();
	});
});

describe('DocumentsTab — cursor navigation', () => {
	it('renders cursor navigation control when next cursor exists', () => {
		render(DocumentsTab, defaultProps());

		expect(screen.getByRole('button', { name: /load next page/i })).toBeInTheDocument();
		expect(screen.getByText(/next cursor: next-cursor/i)).toBeInTheDocument();
	});

	it('hides cursor navigation when no cursor exists', () => {
		render(
			DocumentsTab,
			defaultProps({
				documents: { ...sampleDocuments, cursor: null }
			})
		);

		expect(screen.queryByRole('button', { name: /load next page/i })).not.toBeInTheDocument();
		expect(screen.queryByText(/next cursor/i)).not.toBeInTheDocument();
	});

	it('wires cursor value into the load-next-page form hidden input', () => {
		const { container } = render(DocumentsTab, defaultProps());

		// The cursor browse form has the cursor as a hidden input
		const cursorForms = container.querySelectorAll('form[action="?/browseDocuments"]');
		// There should be at least 2 browse forms: the manual query form and the next-page form
		const cursorInputs = Array.from(cursorForms)
			.map((form) => form.querySelector('input[name="cursor"][type="hidden"]') as HTMLInputElement)
			.filter(Boolean);
		expect(cursorInputs.some((input) => input.value === 'next-cursor')).toBe(true);
	});
});

describe('DocumentsTab — hidden query/hitsPerPage propagation', () => {
	it('propagates canonical query and hitsPerPage across upload, add, browse, and delete forms', () => {
		const { container } = render(
			DocumentsTab,
			defaultProps({
				documents: {
					...sampleDocuments,
					query: 'category:guides',
					hitsPerPage: 40
				}
			})
		);

		const canonicalQueryInputs = [
			container.querySelector('form[action="?/uploadDocuments"] input[name="query"]'),
			container.querySelector('form[action="?/addDocument"] input[name="query"]'),
			container.querySelector(
				'form[action="?/browseDocuments"] input[type="hidden"][name="query"]'
			),
			container.querySelector('form[action="?/deleteDocument"] input[name="query"]')
		] as HTMLInputElement[];
		const canonicalHitsInputs = [
			container.querySelector('form[action="?/uploadDocuments"] input[name="hitsPerPage"]'),
			container.querySelector('form[action="?/addDocument"] input[name="hitsPerPage"]'),
			container.querySelector(
				'form[action="?/browseDocuments"] input[type="hidden"][name="hitsPerPage"]'
			),
			container.querySelector('form[action="?/deleteDocument"] input[name="hitsPerPage"]')
		] as HTMLInputElement[];

		for (const input of canonicalQueryInputs) {
			expect(input).not.toBeNull();
			expect(input.value).toBe('category:guides');
		}
		for (const input of canonicalHitsInputs) {
			expect(input).not.toBeNull();
			expect(input.value).toBe('40');
		}
	});

	it('keeps canonical values pinned while browse drafts change', async () => {
		const { container } = render(
			DocumentsTab,
			defaultProps({
				documents: {
					...sampleDocuments,
					query: 'category:guides',
					hitsPerPage: 40
				}
			})
		);

		// Edit the draft inputs
		await fireEvent.input(screen.getByRole('textbox', { name: /browse query/i }), {
			target: { value: 'title:Draft' }
		});
		await fireEvent.input(screen.getByLabelText(/hits per page/i), {
			target: { value: '5' }
		});

		// Hidden canonical values should still reflect the original
		const uploadQueryInput = container.querySelector(
			'form[action="?/uploadDocuments"] input[name="query"]'
		) as HTMLInputElement;
		const addQueryInput = container.querySelector(
			'form[action="?/addDocument"] input[name="query"]'
		) as HTMLInputElement;
		const browseQueryInput = container.querySelector(
			'form[action="?/browseDocuments"] input[type="hidden"][name="query"]'
		) as HTMLInputElement;
		const deleteQueryInput = container.querySelector(
			'form[action="?/deleteDocument"] input[name="query"]'
		) as HTMLInputElement;
		const uploadHitsInput = container.querySelector(
			'form[action="?/uploadDocuments"] input[name="hitsPerPage"]'
		) as HTMLInputElement;
		const addHitsInput = container.querySelector(
			'form[action="?/addDocument"] input[name="hitsPerPage"]'
		) as HTMLInputElement;
		const browseHitsInput = container.querySelector(
			'form[action="?/browseDocuments"] input[type="hidden"][name="hitsPerPage"]'
		) as HTMLInputElement;
		const deleteHitsInput = container.querySelector(
			'form[action="?/deleteDocument"] input[name="hitsPerPage"]'
		) as HTMLInputElement;

		expect(uploadQueryInput.value).toBe('category:guides');
		expect(addQueryInput.value).toBe('category:guides');
		expect(browseQueryInput.value).toBe('category:guides');
		expect(deleteQueryInput.value).toBe('category:guides');
		expect(uploadHitsInput.value).toBe('40');
		expect(addHitsInput.value).toBe('40');
		expect(browseHitsInput.value).toBe('40');
		expect(deleteHitsInput.value).toBe('40');
	});
});
