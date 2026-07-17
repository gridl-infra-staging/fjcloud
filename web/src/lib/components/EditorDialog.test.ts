import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type {
	EditorDialogFieldSchema,
	EditorDialogProps,
	EditorDialogValues
} from './EditorDialog.types';
import EditorDialog from './EditorDialog.svelte';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

function renderDialog(overrides: Partial<EditorDialogProps> = {}) {
	const onSave = vi.fn<EditorDialogProps['onSave']>().mockResolvedValue(undefined);
	const onCancel = vi.fn<EditorDialogProps['onCancel']>();
	const baseSchema: EditorDialogFieldSchema[] = [
		{
			type: 'text',
			name: 'title',
			label: 'Title',
			required: true
		}
	];
	const baseProps: EditorDialogProps = {
		title: 'Create Item',
		mode: 'create',
		schema: baseSchema,
		initialValue: {},
		open: true,
		onSave,
		onCancel
	};
	const props: EditorDialogProps = { ...baseProps, ...overrides };
	return {
		...render(EditorDialog, { props }),
		onSave,
		onCancel
	};
}

function createDeferredPromise<T>() {
	let resolve!: (value: T | PromiseLike<T>) => void;
	let reject!: (reason?: unknown) => void;
	const promise = new Promise<T>((resolvePromise, rejectPromise) => {
		resolve = resolvePromise;
		reject = rejectPromise;
	});
	return { promise, resolve, reject };
}

function expectClassTokens(element: HTMLElement, tokens: string[]): void {
	expect(element).toHaveClass(...tokens);
}

function expectRadioOptionTokens(input: HTMLElement, selected: boolean): void {
	const label = input.closest('label');
	expect(label).not.toBeNull();
	expectClassTokens(label as HTMLElement, [
		'block',
		'cursor-pointer',
		'rounded-lg',
		'border-2',
		'p-3',
		'transition-colors'
	]);
	expect(label).toHaveClass(selected ? 'border-flapjack-mint' : 'border-flapjack-ink/20');
	expect(label).toHaveClass(selected ? 'bg-flapjack-mint/25' : 'bg-white');
	expectClassTokens(input, ['sr-only']);
}

describe('EditorDialog', () => {
	it('renders simple schema fields and create-mode submit label', () => {
		renderDialog();

		expect(screen.getByRole('dialog')).toBeInTheDocument();
		expect(screen.getByLabelText('Title')).toBeInTheDocument();
		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Create');
	});

	it('shows required errors only after interaction while gating save by visible required fields', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{ type: 'text', name: 'name', label: 'Name', required: true },
			{
				type: 'text',
				name: 'conditional',
				label: 'Conditional',
				required: true,
				visible: (values) => values.name === 'show'
			}
		];
		renderDialog({ schema });

		const save = screen.getByTestId('editor-dialog-save');
		expect(save).toBeDisabled();
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();

		const nameInput = screen.getByLabelText('Name');
		await fireEvent.blur(nameInput);
		expect(await screen.findByText('Name is required.')).toBeInTheDocument();

		await fireEvent.input(nameInput, { target: { value: 'show' } });
		expect(screen.getByLabelText('Conditional')).toBeInTheDocument();
		expect(save).toBeDisabled();
	});

	it('omits hidden fields from the DOM and save payload', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'select',
				name: 'model',
				label: 'Model',
				required: true,
				options: [
					{ value: 'trending-facets', label: 'Trending Facets' },
					{ value: 'trending-items', label: 'Trending Items' }
				]
			},
			{
				type: 'text',
				name: 'objectID',
				label: 'Object ID',
				required: true,
				visible: (values) => values.model !== 'trending-facets'
			},
			{
				type: 'text',
				name: 'facetName',
				label: 'Facet Name',
				required: true,
				visible: (values) => values.model === 'trending-facets'
			}
		];
		const { onSave } = renderDialog({
			schema,
			initialValue: { model: 'trending-facets', objectID: 'legacy-object' }
		});

		expect(screen.queryByLabelText('Object ID')).not.toBeInTheDocument();
		await fireEvent.input(screen.getByLabelText('Facet Name'), { target: { value: 'brand' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(onSave).toHaveBeenCalledTimes(1);
		const payload = onSave.mock.calls[0][0] as EditorDialogValues;
		expect(payload.model).toBe('trending-facets');
		expect(payload.facetName).toBe('brand');
		expect(payload.objectID).toBeUndefined();
	});

	it('preserves unknown initial edit keys in the saved payload', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{ type: 'text', name: 'name', label: 'Name', required: true },
			{
				type: 'text',
				name: 'ephemeral',
				label: 'Ephemeral',
				visible: () => false
			}
		];
		const { onSave } = renderDialog({
			mode: 'edit',
			title: 'Edit Item',
			schema,
			initialValue: { name: 'Original', legacyFlag: true, ephemeral: 'hidden' }
		});

		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Save');
		await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Updated' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(onSave).toHaveBeenCalledTimes(1);
		const payload = onSave.mock.calls[0][0] as EditorDialogValues;
		expect(payload.name).toBe('Updated');
		expect(payload.legacyFlag).toBe(true);
		expect(payload.ephemeral).toBeUndefined();
	});

	it('allows required number fields to become valid and saves numeric payloads', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{ type: 'number', name: 'weight', label: 'Weight', required: true }
		];
		const { onSave } = renderDialog({ schema });

		const save = screen.getByTestId('editor-dialog-save');
		expect(save).toBeDisabled();

		const numberInput = screen.getByLabelText('Weight');
		await fireEvent.input(numberInput, { target: { value: '42' } });
		expect(save).toBeEnabled();

		await fireEvent.click(save);
		expect(onSave).toHaveBeenCalledTimes(1);
		const payload = onSave.mock.calls[0][0] as EditorDialogValues;
		expect(payload.weight).toBe(42);
		expect(typeof payload.weight).toBe('number');
	});

	it('enforces declared text and number constraints before save', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{ type: 'text', name: 'title', label: 'Title', required: true, maxLength: 5 },
			{
				type: 'number',
				name: 'limit',
				label: 'Limit',
				required: true,
				min: 1,
				max: 10,
				integer: true
			}
		];
		const { onSave } = renderDialog({ schema });

		const titleInput = screen.getByLabelText('Title');
		const limitInput = screen.getByLabelText('Limit');
		const save = screen.getByTestId('editor-dialog-save');

		expect(titleInput).toHaveAttribute('maxlength', '5');
		expect(limitInput).toHaveAttribute('min', '1');
		expect(limitInput).toHaveAttribute('max', '10');
		expect(limitInput).toHaveAttribute('step', '1');

		await fireEvent.input(titleInput, { target: { value: 'abcdef' } });
		await fireEvent.blur(titleInput);
		expect(await screen.findByText('Title must be at most 5 characters.')).toBeInTheDocument();
		expect(save).toBeDisabled();

		await fireEvent.input(titleInput, { target: { value: 'short' } });
		await fireEvent.input(limitInput, { target: { value: '3.5' } });
		await fireEvent.blur(limitInput);
		expect(await screen.findByText('Limit must be a whole number.')).toBeInTheDocument();
		expect(save).toBeDisabled();

		await fireEvent.input(limitInput, { target: { value: '11' } });
		expect(await screen.findByText('Limit must be at most 10.')).toBeInTheDocument();
		expect(save).toBeDisabled();

		await fireEvent.input(limitInput, { target: { value: '7' } });
		expect(save).toBeEnabled();

		await fireEvent.click(save);
		expect(onSave).toHaveBeenCalledTimes(1);
		expect(onSave.mock.calls[0][0]).toEqual({ title: 'short', limit: 7 });
	});

	it('renders multiselect, toggle, and radio with native controls and saves normalized values', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'multiselect',
				name: 'facets',
				label: 'Facet Filters',
				options: [
					{ value: 'brand', label: 'Brand' },
					{ value: 'category', label: 'Category' }
				]
			},
			{ type: 'toggle', name: 'enabled', label: 'Enabled' },
			{
				type: 'radio',
				name: 'rankingMode',
				label: 'Ranking mode',
				options: [
					{ value: 'balanced', label: 'Balanced' },
					{ value: 'aggressive', label: 'Aggressive' }
				]
			}
		];
		const { onSave } = renderDialog({
			schema,
			initialValue: {
				facets: [],
				enabled: false,
				rankingMode: 'balanced'
			}
		});

		expect(screen.getByLabelText('Facet Filters')).toHaveAttribute('multiple');
		expect(screen.getByRole('checkbox', { name: 'Enabled' })).not.toBeChecked();
		expect(screen.getByRole('radio', { name: 'Balanced' })).toBeChecked();

		const facetSelect = screen.getByLabelText('Facet Filters') as HTMLSelectElement;
		for (const option of Array.from(facetSelect.options)) {
			option.selected = option.value === 'brand' || option.value === 'category';
		}
		await fireEvent.change(facetSelect);
		await fireEvent.click(screen.getByRole('checkbox', { name: 'Enabled' }));
		await fireEvent.click(screen.getByRole('radio', { name: 'Aggressive' }));
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(onSave).toHaveBeenCalledTimes(1);
		expect(onSave.mock.calls[0][0]).toEqual({
			facets: ['brand', 'category'],
			enabled: true,
			rankingMode: 'aggressive'
		});
	});

	it('applies shared shell, field, alert, and footer styling tokens', async () => {
		const onSave = vi.fn<EditorDialogProps['onSave']>().mockRejectedValue({
			message: 'Server unavailable'
		});
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'text',
				name: 'title',
				label: 'Title',
				required: true,
				helpText: 'Choose a concise title.'
			},
			{ type: 'textarea', name: 'description', label: 'Description' },
			{
				type: 'select',
				name: 'region',
				label: 'Region',
				options: [
					{ value: 'us-east', label: 'US East' },
					{ value: 'us-west', label: 'US West' }
				]
			},
			{ type: 'toggle', name: 'enabled', label: 'Enabled' },
			{
				type: 'radio',
				name: 'mode',
				label: 'Mode',
				options: [
					{ value: 'basic', label: 'Basic' },
					{ value: 'advanced', label: 'Advanced' }
				]
			}
		];
		renderDialog({
			schema,
			initialValue: {
				title: '',
				description: '',
				region: 'us-east',
				enabled: false,
				mode: 'basic'
			},
			onSave
		});

		expectClassTokens(screen.getByTestId('editor-dialog-backdrop'), [
			'fixed',
			'inset-0',
			'bg-flapjack-ink/55'
		]);
		expectClassTokens(screen.getByRole('dialog'), [
			'flex',
			'max-h-[90vh]',
			'max-w-2xl',
			'rounded-lg',
			'bg-white',
			'shadow-xl'
		]);
		expectClassTokens(screen.getByRole('heading', { name: 'Create Item' }), [
			'text-lg',
			'font-bold',
			'text-flapjack-ink'
		]);
		expectClassTokens(screen.getByText('Title'), [
			'block',
			'text-sm',
			'font-medium',
			'text-flapjack-ink/80'
		]);
		expectClassTokens(screen.getByText('Choose a concise title.'), [
			'text-xs',
			'text-flapjack-ink/60'
		]);
		expectClassTokens(screen.getByLabelText('Title'), [
			'w-full',
			'rounded-md',
			'border',
			'border-flapjack-ink/30',
			'bg-white',
			'focus:border-flapjack-rose'
		]);
		expectClassTokens(screen.getByLabelText('Description'), ['w-full', 'rounded-md', 'px-3']);
		expectClassTokens(screen.getByLabelText('Region'), ['w-full', 'rounded-md', 'bg-white']);
		expectClassTokens(screen.getByRole('checkbox', { name: 'Enabled' }), [
			'rounded',
			'border-flapjack-ink/30',
			'text-flapjack-rose'
		]);
		const radioFieldset = screen.getByRole('group', { name: 'Mode' });
		expectClassTokens(radioFieldset, [
			'rounded-lg',
			'border',
			'border-flapjack-ink/20',
			'bg-flapjack-cream/20',
			'p-3'
		]);
		expectRadioOptionTokens(screen.getByTestId('editor-dialog-field-mode-basic'), true);
		expectRadioOptionTokens(screen.getByTestId('editor-dialog-field-mode-advanced'), false);
		expectClassTokens(screen.getByTestId('editor-dialog-cancel'), [
			'w-full',
			'rounded-md',
			'border',
			'border-flapjack-ink/30',
			'sm:w-auto'
		]);
		expectClassTokens(screen.getByTestId('editor-dialog-save'), [
			'w-full',
			'rounded-md',
			'bg-flapjack-rose',
			'text-white',
			'sm:w-auto'
		]);
		expectClassTokens(screen.getByTestId('editor-dialog-footer-actions'), [
			'flex',
			'flex-col-reverse',
			'justify-end',
			'gap-3',
			'border-t',
			'pt-4',
			'sm:flex-row'
		]);

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Styled title' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));
		expectClassTokens(await screen.findByTestId('editor-dialog-server-error'), [
			'rounded-lg',
			'border',
			'border-flapjack-rose/35',
			'bg-flapjack-rose/10',
			'p-3'
		]);

		await fireEvent.click(screen.getByTestId('editor-dialog-close'));
		expect(screen.getByText('Discard unsaved changes?')).toBeInTheDocument();
		expectClassTokens(screen.getByTestId('editor-dialog-discard'), [
			'w-full',
			'rounded-md',
			'bg-flapjack-plum',
			'text-white',
			'sm:w-auto'
		]);
		expectClassTokens(screen.getByTestId('editor-dialog-keep-editing'), [
			'w-full',
			'rounded-md',
			'border',
			'border-flapjack-ink/30',
			'sm:w-auto'
		]);
	});

	it('renders submit pending state, disables controls while saving, and clears save errors only after edits', async () => {
		const saveDeferred = createDeferredPromise<void>();
		const onSave = vi
			.fn<EditorDialogProps['onSave']>()
			.mockImplementation(() => saveDeferred.promise);
		renderDialog({ onSave });

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Updated title' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Saving...');
		expect(screen.getByTestId('editor-dialog-save')).toBeDisabled();
		expect(screen.getByLabelText('Title')).toBeDisabled();
		expect(screen.getByTestId('editor-dialog-cancel')).toBeDisabled();
		expect(screen.getByTestId('editor-dialog-close')).toBeDisabled();

		saveDeferred.reject(new Error('Server unavailable'));
		await waitFor(() => {
			expect(screen.getByText('Server unavailable')).toBeInTheDocument();
		});

		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Create');
		await fireEvent.blur(screen.getByLabelText('Title'));
		expect(screen.getByText('Server unavailable')).toBeInTheDocument();

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'New value' } });
		expect(screen.queryByText('Server unavailable')).not.toBeInTheDocument();
	});

	it('renders normalized per-field save rejections and clears them after field edits', async () => {
		const onSave = vi.fn<EditorDialogProps['onSave']>().mockRejectedValue({
			message: 'Validation failed.',
			fieldErrors: {
				title: 'Title already exists.'
			}
		});
		renderDialog({ onSave });

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Duplicate' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(await screen.findByText('Validation failed.')).toBeInTheDocument();
		expect(screen.getByText('Title already exists.')).toBeInTheDocument();

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Unique' } });
		expect(screen.queryByText('Validation failed.')).not.toBeInTheDocument();
		expect(screen.queryByText('Title already exists.')).not.toBeInTheDocument();
	});

	it('focuses the first field on open and traps tab navigation through close and footer controls', async () => {
		const view = renderDialog({ open: false });

		await view.rerender({
			title: 'Create Item',
			mode: 'create',
			schema: [{ type: 'text', name: 'title', label: 'Title', required: true }],
			initialValue: {},
			open: true,
			onSave: view.onSave,
			onCancel: view.onCancel
		});

		await waitFor(() => {
			expect(screen.getByLabelText('Title')).toHaveFocus();
		});
		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Focusable value' } });
		expect(screen.getByTestId('editor-dialog-save')).toBeEnabled();
		screen.getByLabelText('Title').focus();

		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Tab' });
		expect(screen.getByTestId('editor-dialog-cancel')).toHaveFocus();

		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Tab' });
		expect(screen.getByTestId('editor-dialog-save')).toHaveFocus();

		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Tab' });
		expect(screen.getByTestId('editor-dialog-close')).toHaveFocus();

		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Tab', shiftKey: true });
		expect(screen.getByTestId('editor-dialog-save')).toHaveFocus();
	});

	it('routes dirty dismiss attempts through discard confirmation and returns focus to trigger on close', async () => {
		const trigger = document.createElement('button');
		trigger.textContent = 'Open editor';
		document.body.appendChild(trigger);
		trigger.focus();

		let isOpen = true;
		const onSave = vi.fn<EditorDialogProps['onSave']>().mockResolvedValue(undefined);
		const onCancel = vi.fn(() => {
			isOpen = false;
			view.rerender({
				title: 'Create Item',
				mode: 'create',
				schema: [{ type: 'text', name: 'title', label: 'Title', required: true }],
				initialValue: {},
				open: isOpen,
				onSave,
				onCancel
			});
		});

		const view = render(EditorDialog, {
			props: {
				title: 'Create Item',
				mode: 'create',
				schema: [{ type: 'text', name: 'title', label: 'Title', required: true }],
				initialValue: {},
				open: isOpen,
				onSave,
				onCancel
			}
		});

		await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
		expect(onCancel).toHaveBeenCalledTimes(1);

		await view.rerender({
			title: 'Create Item',
			mode: 'create',
			schema: [{ type: 'text', name: 'title', label: 'Title', required: true }],
			initialValue: {},
			open: true,
			onSave,
			onCancel
		});
		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Dirty change' } });

		await fireEvent.click(screen.getByTestId('editor-dialog-close'));
		expect(screen.getByText('Discard')).toBeInTheDocument();
		expect(screen.getByText('Keep editing')).toBeInTheDocument();
		expect(onCancel).toHaveBeenCalledTimes(1);

		await fireEvent.click(screen.getByText('Keep editing'));
		expect(screen.queryByText('Discard')).not.toBeInTheDocument();

		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
		expect(screen.getByText('Discard')).toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('editor-dialog-backdrop'));
		expect(screen.getByText('Discard')).toBeInTheDocument();

		await fireEvent.click(screen.getByText('Discard'));
		expect(onCancel).toHaveBeenCalledTimes(2);

		await waitFor(() => {
			expect(trigger).toHaveFocus();
		});

		trigger.remove();
	});

	it('ignores dismiss actions while save is in flight', async () => {
		const saveDeferred = createDeferredPromise<void>();
		const onSave = vi
			.fn<EditorDialogProps['onSave']>()
			.mockImplementation(() => saveDeferred.promise);
		const onCancel = vi.fn();
		renderDialog({ onSave, onCancel });

		await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Save me' } });
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
		await fireEvent.click(screen.getByTestId('editor-dialog-close'));
		await fireEvent.click(screen.getByTestId('editor-dialog-backdrop'));
		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });

		expect(onCancel).not.toHaveBeenCalled();
		saveDeferred.resolve();
		await waitFor(() => {
			expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Create');
		});
	});

	it('honors external pendingSave state even after onSave has already resolved', async () => {
		const onCancel = vi.fn();
		const view = renderDialog({
			initialValue: { title: 'Persisted title' },
			pendingSave: true,
			onCancel
		});

		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Saving...');
		expect(screen.getByTestId('editor-dialog-save')).toBeDisabled();
		expect(screen.getByLabelText('Title')).toBeDisabled();
		expect(screen.getByTestId('editor-dialog-cancel')).toBeDisabled();
		expect(screen.getByTestId('editor-dialog-close')).toBeDisabled();

		await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
		await fireEvent.click(screen.getByTestId('editor-dialog-close'));
		await fireEvent.click(screen.getByTestId('editor-dialog-backdrop'));
		await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
		expect(onCancel).not.toHaveBeenCalled();

		await view.rerender({
			title: 'Create Item',
			mode: 'create',
			schema: [{ type: 'text', name: 'title', label: 'Title', required: true }],
			initialValue: { title: 'Persisted title' },
			open: true,
			pendingSave: false,
			onSave: view.onSave,
			onCancel
		});

		expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Create');
		expect(screen.getByLabelText('Title')).not.toBeDisabled();
		expect(screen.getByTestId('editor-dialog-cancel')).not.toBeDisabled();
	});
});
