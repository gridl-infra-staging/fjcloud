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

describe('EditorDialog array fields', () => {
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
});
