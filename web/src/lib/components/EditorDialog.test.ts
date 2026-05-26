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

	it('uses normalized test IDs for single-field array rows', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'words',
				label: 'Words',
				addLabel: 'Add Word',
				item: {
					type: 'text',
					name: 'word',
					label: 'Word',
					required: true
				}
			}
		];
		renderDialog({ schema, initialValue: { words: ['alpha'] } });

		expect(screen.getByTestId('editor-dialog-field-words-0')).toBeInTheDocument();
		await fireEvent.click(screen.getByTestId('editor-dialog-add-words'));
		expect(screen.getByTestId('editor-dialog-field-words-1')).toBeInTheDocument();
	});

	it('keeps required single-field arrays invalid until required row values are populated', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'keywords',
				label: 'Keywords',
				required: true,
				addLabel: 'Add Keyword',
				item: {
					type: 'text',
					name: 'keyword',
					label: 'Keyword',
					required: true
				}
			}
		];
		const { onSave } = renderDialog({ schema, initialValue: { keywords: [] } });

		const save = screen.getByTestId('editor-dialog-save');
		expect(save).toBeDisabled();

		await fireEvent.click(screen.getByTestId('editor-dialog-add-keywords'));
		expect(screen.getByTestId('editor-dialog-field-keywords-0')).toBeInTheDocument();
		expect(save).toBeDisabled();
		expect(screen.queryByText('Keyword is required.')).not.toBeInTheDocument();

		await fireEvent.blur(screen.getByTestId('editor-dialog-field-keywords-0'));
		expect(await screen.findByText('Keyword is required.')).toBeInTheDocument();

		await fireEvent.click(save);
		expect(onSave).not.toHaveBeenCalled();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-keywords-0'), {
			target: { value: 'refactor' }
		});
		expect(save).toBeEnabled();
	});

	it('defers required row errors for newly added rows even after earlier rows were blurred', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'keywords',
				label: 'Keywords',
				required: true,
				addLabel: 'Add Keyword',
				item: {
					type: 'text',
					name: 'keyword',
					label: 'Keyword',
					required: true
				}
			}
		];
		renderDialog({ schema, initialValue: { keywords: ['existing'] } });

		const existingRow = screen.getByTestId('editor-dialog-field-keywords-0');
		await fireEvent.blur(existingRow);
		expect(screen.queryByText('Keyword is required.')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('editor-dialog-add-keywords'));
		expect(screen.getByTestId('editor-dialog-field-keywords-1')).toBeInTheDocument();
		expect(screen.getByTestId('editor-dialog-save')).toBeDisabled();
		expect(screen.queryByText('Keyword is required.')).not.toBeInTheDocument();

		await fireEvent.blur(screen.getByTestId('editor-dialog-field-keywords-1'));
		expect(await screen.findByText('Keyword is required.')).toBeInTheDocument();
	});

	it('shows array required row errors when a later invalid row is blurred first', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'keywords',
				label: 'Keywords',
				required: true,
				addLabel: 'Add Keyword',
				item: {
					type: 'text',
					name: 'keyword',
					label: 'Keyword',
					required: true
				}
			}
		];
		renderDialog({ schema, initialValue: { keywords: ['', ''] } });

		expect(screen.getByTestId('editor-dialog-save')).toBeDisabled();
		expect(screen.queryByText('Keyword is required.')).not.toBeInTheDocument();

		await fireEvent.blur(screen.getByTestId('editor-dialog-field-keywords-1'));
		expect(await screen.findByText('Keyword is required.')).toBeInTheDocument();
	});

	it('round-trips single-field number arrays with numeric input state and numeric payload entries', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'thresholds',
				label: 'Thresholds',
				required: true,
				addLabel: 'Add Threshold',
				item: {
					type: 'number',
					name: 'threshold',
					label: 'Threshold',
					required: true
				}
			}
		];
		const { onSave } = renderDialog({ schema, initialValue: { thresholds: [10] } });

		const existingRow = screen.getByTestId('editor-dialog-field-thresholds-0');
		expect(existingRow).toHaveValue(10);

		await fireEvent.click(screen.getByTestId('editor-dialog-add-thresholds'));
		const newRow = screen.getByTestId('editor-dialog-field-thresholds-1');
		await fireEvent.input(newRow, { target: { value: '25' } });

		await fireEvent.click(screen.getByTestId('editor-dialog-save'));
		expect(onSave).toHaveBeenCalledTimes(1);
		const payload = onSave.mock.calls[0][0] as EditorDialogValues;
		expect(payload.thresholds).toEqual([10, 25]);
		expect(typeof (payload.thresholds as unknown[])[0]).toBe('number');
		expect(typeof (payload.thresholds as unknown[])[1]).toBe('number');
	});

	it('renders group array rows, enforces min/max limits, and round-trips grouped payloads', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'boosts',
				label: 'Boosts',
				addLabel: 'Add Boost',
				minItems: 1,
				maxItems: 2,
				item: {
					type: 'group',
					fields: [
						{ type: 'text', name: 'attribute', label: 'Attribute', required: true },
						{ type: 'number', name: 'weight', label: 'Weight', required: true }
					]
				}
			}
		];
		const { onSave } = renderDialog({
			schema,
			initialValue: { boosts: [{ attribute: 'brand', weight: 2 }] }
		});

		expect(screen.getByTestId('editor-dialog-field-boosts-0-attribute')).toHaveValue('brand');
		expect(screen.getByTestId('editor-dialog-field-boosts-0-weight')).toHaveValue(2);
		expect(screen.getByTestId('editor-dialog-remove-boosts-0')).toBeDisabled();

		await fireEvent.click(screen.getByTestId('editor-dialog-add-boosts'));
		expect(screen.getByTestId('editor-dialog-field-boosts-1-attribute')).toBeInTheDocument();
		expect(screen.getByTestId('editor-dialog-add-boosts')).toBeDisabled();
		expect(screen.getByTestId('editor-dialog-remove-boosts-0')).toBeEnabled();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-1-attribute'), {
			target: { value: 'category' }
		});
		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-1-weight'), {
			target: { value: '5' }
		});

		await fireEvent.click(screen.getByTestId('editor-dialog-save'));
		expect(onSave).toHaveBeenCalledTimes(1);
		expect(onSave.mock.calls[0][0]).toEqual({
			boosts: [
				{ attribute: 'brand', weight: 2 },
				{ attribute: 'category', weight: 5 }
			]
		});
	});

	it('enforces grouped child constraints through the shared schema validation path', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'boosts',
				label: 'Boosts',
				addLabel: 'Add Boost',
				item: {
					type: 'group',
					fields: [
						{ type: 'text', name: 'attribute', label: 'Attribute', required: true, maxLength: 4 },
						{
							type: 'number',
							name: 'weight',
							label: 'Weight',
							required: true,
							min: 1,
							integer: true
						}
					]
				}
			}
		];
		renderDialog({
			schema,
			initialValue: { boosts: [{ attribute: 'brand', weight: 2 }] }
		});

		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-0-attribute'), {
			target: { value: 'toolong' }
		});
		await fireEvent.blur(screen.getByTestId('editor-dialog-field-boosts-0-attribute'));
		expect(await screen.findByText('Attribute must be at most 4 characters.')).toBeInTheDocument();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-0-attribute'), {
			target: { value: 'size' }
		});
		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-0-weight'), {
			target: { value: '0.5' }
		});
		await fireEvent.blur(screen.getByTestId('editor-dialog-field-boosts-0-weight'));
		expect(await screen.findByText('Weight must be a whole number.')).toBeInTheDocument();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-0-weight'), {
			target: { value: '0' }
		});
		expect(await screen.findByText('Weight must be at least 1.')).toBeInTheDocument();

		await fireEvent.input(screen.getByTestId('editor-dialog-field-boosts-0-weight'), {
			target: { value: '3' }
		});
		expect(screen.queryByText('Weight must be at least 1.')).not.toBeInTheDocument();
		expect(screen.getByTestId('editor-dialog-save')).toBeEnabled();
	});

	it('delays grouped row validation until an invalid grouped row is touched', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'boosts',
				label: 'Boosts',
				addLabel: 'Add Boost',
				item: {
					type: 'group',
					fields: [
						{ type: 'text', name: 'attribute', label: 'Attribute', required: true },
						{ type: 'number', name: 'weight', label: 'Weight', required: true }
					]
				}
			}
		];
		renderDialog({
			schema,
			initialValue: {
				boosts: [
					{ attribute: 'brand', weight: 1 },
					{ attribute: '', weight: null }
				]
			}
		});

		expect(screen.queryByText('Attribute is required.')).not.toBeInTheDocument();
		await fireEvent.blur(screen.getByTestId('editor-dialog-field-boosts-0-attribute'));
		expect(screen.queryByText('Attribute is required.')).not.toBeInTheDocument();

		await fireEvent.blur(screen.getByTestId('editor-dialog-field-boosts-1-attribute'));
		expect(await screen.findByText('Attribute is required.')).toBeInTheDocument();
	});

	it('renders grouped multiselect, toggle, and radio controls with normalized grouped payload values', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'rules',
				label: 'Rules',
				addLabel: 'Add Rule',
				item: {
					type: 'group',
					fields: [
						{
							type: 'multiselect',
							name: 'facets',
							label: 'Facets',
							options: [
								{ value: 'brand', label: 'Brand' },
								{ value: 'category', label: 'Category' }
							]
						},
						{ type: 'toggle', name: 'enabled', label: 'Enabled' },
						{
							type: 'radio',
							name: 'mode',
							label: 'Mode',
							options: [
								{ value: 'strict', label: 'Strict' },
								{ value: 'lenient', label: 'Lenient' }
							]
						}
					]
				}
			}
		];
		const { onSave } = renderDialog({
			schema,
			initialValue: {
				rules: [{ facets: ['category'], enabled: false, mode: 'strict' }]
			}
		});

		const groupedMultiselect = screen.getByTestId(
			'editor-dialog-field-rules-0-facets'
		) as HTMLSelectElement;
		expect(groupedMultiselect).toHaveAttribute('multiple');
		expect(groupedMultiselect.options[0]?.value).toBe('brand');
		expect(groupedMultiselect.options[0]?.selected).toBe(false);
		expect(groupedMultiselect.options[1]?.value).toBe('category');
		expect(groupedMultiselect.options[1]?.selected).toBe(true);
		expect(screen.getByTestId('editor-dialog-field-rules-0-enabled')).not.toBeChecked();
		expect(screen.getByTestId('editor-dialog-field-rules-0-mode-strict')).toBeInTheDocument();
		expect(screen.getByTestId('editor-dialog-field-rules-0-mode-lenient')).toBeInTheDocument();
		expect(screen.queryByTestId('editor-dialog-field-rules-0-mode')).not.toBeInTheDocument();
		expect(screen.getByRole('radio', { name: 'Strict' })).toBeChecked();

		for (const option of Array.from(groupedMultiselect.options)) {
			option.selected = option.value === 'brand' || option.value === 'category';
		}
		await fireEvent.change(groupedMultiselect);
		await fireEvent.click(screen.getByTestId('editor-dialog-field-rules-0-enabled'));
		await fireEvent.click(screen.getByRole('radio', { name: 'Lenient' }));
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));

		expect(onSave).toHaveBeenCalledTimes(1);
		expect(onSave.mock.calls[0][0]).toEqual({
			rules: [{ facets: ['brand', 'category'], enabled: true, mode: 'lenient' }]
		});
	});

	it('hydrates grouped multiselect selections when edit mode reopens with a new initial value', async () => {
		const schema: EditorDialogFieldSchema[] = [
			{
				type: 'array',
				name: 'rules',
				label: 'Rules',
				addLabel: 'Add Rule',
				item: {
					type: 'group',
					fields: [
						{
							type: 'multiselect',
							name: 'facets',
							label: 'Facets',
							options: [
								{ value: 'brand', label: 'Brand' },
								{ value: 'category', label: 'Category' }
							]
						}
					]
				}
			}
		];
		const view = renderDialog({
			mode: 'edit',
			title: 'Edit Rule',
			schema,
			initialValue: { rules: [{ facets: ['category'] }] }
		});

		let groupedMultiselect = screen.getByTestId(
			'editor-dialog-field-rules-0-facets'
		) as HTMLSelectElement;
		expect(groupedMultiselect.options[0]?.selected).toBe(false);
		expect(groupedMultiselect.options[1]?.selected).toBe(true);

		await view.rerender({
			title: 'Edit Rule',
			mode: 'edit',
			schema,
			initialValue: { rules: [{ facets: ['brand'] }] },
			open: false,
			onSave: view.onSave,
			onCancel: view.onCancel
		});
		await view.rerender({
			title: 'Edit Rule',
			mode: 'edit',
			schema,
			initialValue: { rules: [{ facets: ['brand'] }] },
			open: true,
			onSave: view.onSave,
			onCancel: view.onCancel
		});

		groupedMultiselect = screen.getByTestId(
			'editor-dialog-field-rules-0-facets'
		) as HTMLSelectElement;
		expect(groupedMultiselect.options[0]?.selected).toBe(true);
		expect(groupedMultiselect.options[1]?.selected).toBe(false);
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
});
