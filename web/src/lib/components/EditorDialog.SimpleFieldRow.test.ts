import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import type { EditorDialogSimpleFieldSchema } from './EditorDialog.types';
import EditorDialogSimpleFieldRow from './EditorDialog.SimpleFieldRow.svelte';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

function renderSimpleFieldRow(
	field: EditorDialogSimpleFieldSchema,
	values: Record<string, unknown>
) {
	const updateSimpleFieldValue = vi.fn();
	const updateSimpleFieldCheckedValue = vi.fn();
	const updateSimpleFieldSelectedValues = vi.fn();
	const markTouched = vi.fn();

	const result = render(EditorDialogSimpleFieldRow, {
		props: {
			field,
			testId: 'editor-dialog',
			simpleFieldClass: 'simple-field',
			compactToggleClass: 'compact-toggle',
			radioOptionClass: (selected: boolean) => (selected ? 'selected-radio' : 'radio'),
			effectivelySaving: false,
			valueAsString: (name: string) => String(values[name] ?? ''),
			valueAsStringArray: (name: string) => {
				const value = values[name];
				return Array.isArray(value)
					? value.filter((entry): entry is string => typeof entry === 'string')
					: [];
			},
			valueAsBoolean: (name: string) => values[name] === true,
			updateSimpleFieldValue,
			updateSimpleFieldCheckedValue,
			updateSimpleFieldSelectedValues,
			markTouched
		}
	});

	return {
		...result,
		updateSimpleFieldValue,
		updateSimpleFieldCheckedValue,
		updateSimpleFieldSelectedValues,
		markTouched
	};
}

describe('EditorDialogSimpleFieldRow', () => {
	it('keeps simple field markup and callbacks owned by the extracted row', async () => {
		const textareaField: EditorDialogSimpleFieldSchema = {
			type: 'textarea',
			name: 'notes',
			label: 'Notes',
			helpText: 'Shown to operators',
			rows: 6,
			maxLength: 24
		};
		const textarea = renderSimpleFieldRow(textareaField, { notes: 'draft' });

		const notesInput = screen.getByTestId('editor-dialog-field-notes');
		expect(screen.getByLabelText('Notes')).toBe(notesInput);
		expect(screen.getByText('Shown to operators')).toBeInTheDocument();
		expect(notesInput).toHaveAttribute('rows', '6');
		expect(notesInput).toHaveAttribute('maxlength', '24');
		expect(notesInput).toHaveValue('draft');

		await fireEvent.input(notesInput, { target: { value: 'published' } });
		await fireEvent.blur(notesInput);
		expect(textarea.updateSimpleFieldValue).toHaveBeenCalledWith(textareaField, 'published');
		expect(textarea.markTouched).toHaveBeenCalledWith('notes');
		textarea.unmount();

		const toggleField: EditorDialogSimpleFieldSchema = {
			type: 'toggle',
			name: 'enabled',
			label: 'Enabled'
		};
		const toggle = renderSimpleFieldRow(toggleField, { enabled: true });
		const checkbox = screen.getByTestId('editor-dialog-field-enabled');
		expect(checkbox).toHaveClass('compact-toggle');
		expect(checkbox).toBeChecked();

		await fireEvent.click(checkbox);
		expect(toggle.updateSimpleFieldCheckedValue).toHaveBeenCalledWith(toggleField, false);
		toggle.unmount();

		const multiselectField: EditorDialogSimpleFieldSchema = {
			type: 'multiselect',
			name: 'regions',
			label: 'Regions',
			options: [
				{ value: 'iad', label: 'IAD' },
				{ value: 'sfo', label: 'SFO' }
			]
		};
		const multiselect = renderSimpleFieldRow(multiselectField, { regions: ['sfo'] });
		const regionsInput = screen.getByTestId('editor-dialog-field-regions') as HTMLSelectElement;
		expect(regionsInput.options[0].selected).toBe(false);
		expect(regionsInput.options[1].selected).toBe(true);

		regionsInput.options[0].selected = true;
		await fireEvent.change(regionsInput);
		expect(multiselect.updateSimpleFieldSelectedValues).toHaveBeenCalledWith(multiselectField, [
			'iad',
			'sfo'
		]);
	});
});
