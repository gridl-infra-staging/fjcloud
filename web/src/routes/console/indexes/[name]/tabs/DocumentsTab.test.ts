import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { documentsFormsMockState, toastSuccessMock } = vi.hoisted(() => ({
	documentsFormsMockState: {
		enhanceSubmitFunctions: [] as Array<{
			action: string;
			submitFunction: () => PromiseLike<unknown> | unknown;
		}>
	},
	toastSuccessMock: vi.fn()
}));

vi.mock('$app/forms', () => ({
	enhance: (element: HTMLFormElement, submitFunction?: () => PromiseLike<unknown> | unknown) => {
		if (submitFunction) {
			documentsFormsMockState.enhanceSubmitFunctions.push({
				action: element.getAttribute('action') ?? '',
				submitFunction
			});
		}
		return { destroy: () => {} };
	}
}));

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			success: toastSuccessMock
		}
	};
});

import DocumentsTab from './DocumentsTab.svelte';
import { sampleIndex, sampleDocuments } from '../detail.test.shared';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

type DocumentsProps = ComponentProps<typeof DocumentsTab>;

function defaultProps(overrides: Partial<DocumentsProps> = {}): DocumentsProps {
	return {
		index: sampleIndex,
		documents: sampleDocuments,
		documentsUploadSuccess: false,
		documentsAddSuccess: false,
		documentsBrowseSuccess: false,
		documentsUploadError: '',
		documentsAddError: '',
		documentsBrowseError: '',
		documentsDeleteError: '',
		...overrides
	};
}

afterEach(() => {
	cleanup();
	documentsFormsMockState.enhanceSubmitFunctions.length = 0;
	vi.clearAllMocks();
});

async function resolveLatestEnhanceSuccess(
	action: string,
	data: Record<string, unknown>
): Promise<void> {
	const entry = documentsFormsMockState.enhanceSubmitFunctions
		.filter((candidate) => candidate.action === action)
		.at(-1);
	expect(entry).toBeDefined();
	const resultHandler = entry!.submitFunction() as ({
		result,
		update
	}: {
		result: unknown;
		update: () => Promise<void>;
	}) => Promise<void>;
	await resultHandler({
		result: { type: 'success', data },
		update: async () => {}
	});
}

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

	it('does not render removed browse/delete controls or per-record JSON previews', () => {
		const { container } = render(DocumentsTab, defaultProps());

		expect(screen.queryByText('Browse & Delete')).not.toBeInTheDocument();
		expect(container.querySelector('form[action="?/browseDocuments"]')).toBeNull();
		expect(container.querySelector('form[action="?/deleteDocument"]')).toBeNull();
		expect(
			screen.queryByRole('button', { name: /delete document doc-1/i })
		).not.toBeInTheDocument();
		expect(screen.getByTestId('documents-section').querySelector('pre')).toBeNull();
	});

	it('renders upload file input and submit button', () => {
		const { container } = render(DocumentsTab, defaultProps());

		expect(screen.getByLabelText(/upload json or csv file/i)).toBeInTheDocument();
		expect(container.querySelector('form[action="?/uploadDocuments"]')).not.toBeNull();
		expect(screen.getByRole('button', { name: /upload records/i })).toBeInTheDocument();
	});
});

describe('DocumentsTab — success toasts', () => {
	it('emits one shared upload toast without the old inline banner', async () => {
		render(DocumentsTab, defaultProps({ documentsUploadSuccess: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Documents uploaded.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByText('Documents uploaded.')).not.toBeInTheDocument();
	});

	it('emits one shared add toast without the old inline banner', async () => {
		render(DocumentsTab, defaultProps({ documentsAddSuccess: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Document added.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByText('Document added.')).not.toBeInTheDocument();
	});

	it('emits one shared browse toast without the old inline banner', async () => {
		render(DocumentsTab, defaultProps({ documentsBrowseSuccess: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Documents refreshed.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByText('Documents refreshed.')).not.toBeInTheDocument();
	});

	it('re-emits upload and add toasts for consecutive successful completions', async () => {
		render(
			DocumentsTab,
			defaultProps({
				documentsUploadSuccess: true,
				documentsAddSuccess: true,
				documentsBrowseSuccess: true
			})
		);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(3);
		});

		await resolveLatestEnhanceSuccess('?/uploadDocuments', { documentsUploadSuccess: true });
		await resolveLatestEnhanceSuccess('?/addDocument', { documentsAddSuccess: true });

		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(5);
		});
		expect(toastSuccessMock).toHaveBeenNthCalledWith(4, 'Documents uploaded.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenNthCalledWith(5, 'Document added.', {
			duration: TOAST_DURATION_MS
		});
		expect(screen.queryByText('Documents uploaded.')).not.toBeInTheDocument();
		expect(screen.queryByText('Document added.')).not.toBeInTheDocument();
		expect(screen.queryByText('Documents refreshed.')).not.toBeInTheDocument();
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

describe('DocumentsTab — form action contracts', () => {
	it('has uploadDocuments form action', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/uploadDocuments"]')).not.toBeNull();
	});

	it('has addDocument form action', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/addDocument"]')).not.toBeNull();
	});

	it('does not own browseDocuments or deleteDocument form actions', () => {
		const { container } = render(DocumentsTab, defaultProps());
		expect(container.querySelector('form[action="?/browseDocuments"]')).toBeNull();
		expect(container.querySelector('form[action="?/deleteDocument"]')).toBeNull();
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

describe('DocumentsTab — hidden query/hitsPerPage propagation', () => {
	it('propagates canonical query and hitsPerPage across upload and add forms', () => {
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
			container.querySelector('form[action="?/addDocument"] input[name="query"]')
		] as HTMLInputElement[];
		const canonicalHitsInputs = [
			container.querySelector('form[action="?/uploadDocuments"] input[name="hitsPerPage"]'),
			container.querySelector('form[action="?/addDocument"] input[name="hitsPerPage"]')
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

	it('keeps canonical refresh values on upload and add forms', () => {
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

		const uploadQueryInput = container.querySelector(
			'form[action="?/uploadDocuments"] input[name="query"]'
		) as HTMLInputElement;
		const addQueryInput = container.querySelector(
			'form[action="?/addDocument"] input[name="query"]'
		) as HTMLInputElement;
		const uploadHitsInput = container.querySelector(
			'form[action="?/uploadDocuments"] input[name="hitsPerPage"]'
		) as HTMLInputElement;
		const addHitsInput = container.querySelector(
			'form[action="?/addDocument"] input[name="hitsPerPage"]'
		) as HTMLInputElement;

		expect(uploadQueryInput.value).toBe('category:guides');
		expect(addQueryInput.value).toBe('category:guides');
		expect(uploadHitsInput.value).toBe('40');
		expect(addHitsInput.value).toBe('40');
	});
});
