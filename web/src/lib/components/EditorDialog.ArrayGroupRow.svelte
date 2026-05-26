<script lang="ts">
	import type {
		EditorDialogArrayFieldSchema,
		EditorDialogSimpleFieldSchema
	} from './EditorDialog.types';
	import {
		editorDialogArrayItemTestId,
		editorDialogArrayGroupItemFieldTestId,
		editorDialogArrayGroupItemFieldOptionTestId
	} from './EditorDialog.types';
	import {
		canRemoveArrayRow,
		groupRowFieldValueAsBoolean,
		groupRowFieldValueAsString,
		groupRowFieldValueAsStringArray,
		inputMaxLength,
		inputMaximum,
		inputMinimum,
		inputPattern,
		inputStep,
		inputTypeForSimpleField
	} from './EditorDialog.fieldHelpers';
	import { isGroupArrayItem } from './EditorDialog.normalize';

	let {
		field,
		rowValue,
		index,
		testId,
		isSaving,
		rowsLength,
		onUpdateField,
		onUpdateChecked,
		onUpdateSelected,
		onMarkTouched,
		onRemove
	}: {
		field: EditorDialogArrayFieldSchema;
		rowValue: unknown;
		index: number;
		testId: string;
		isSaving: boolean;
		rowsLength: number;
		onUpdateField: (groupField: EditorDialogSimpleFieldSchema, rawValue: string) => void;
		onUpdateChecked: (groupField: EditorDialogSimpleFieldSchema, checked: boolean) => void;
		onUpdateSelected: (
			groupField: EditorDialogSimpleFieldSchema,
			selectedValues: string[]
		) => void;
		onMarkTouched: () => void;
		onRemove: () => void;
	} = $props();
</script>

{#if isGroupArrayItem(field.item)}
	<div data-testid={editorDialogArrayItemTestId(field.name, index)}>
		{#each field.item.fields as groupField (groupField.name)}
			{#if groupField.type !== 'radio'}
				<label for={`${testId}-field-${field.name}-${index}-${groupField.name}`}>
					{groupField.label}
				</label>
			{/if}
			{#if groupField.type === 'textarea'}
				<textarea
					id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
					rows={groupField.rows ?? 4}
					maxlength={inputMaxLength(groupField)}
					value={groupRowFieldValueAsString(field, rowValue, groupField)}
					oninput={(event) =>
						onUpdateField(groupField, (event.currentTarget as HTMLTextAreaElement).value)}
					onblur={onMarkTouched}
					disabled={isSaving}
				></textarea>
			{:else if groupField.type === 'select'}
				<select
					id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
					value={groupRowFieldValueAsString(field, rowValue, groupField)}
					onchange={(event) =>
						onUpdateField(groupField, (event.currentTarget as HTMLSelectElement).value)}
					onblur={onMarkTouched}
					disabled={isSaving}
				>
					{#each groupField.options as option (option.value)}
						<option value={option.value}>{option.label}</option>
					{/each}
				</select>
			{:else if groupField.type === 'multiselect'}
				<select
					id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
					multiple
					onchange={(event) =>
						onUpdateSelected(
							groupField,
							Array.from((event.currentTarget as HTMLSelectElement).selectedOptions).map(
								(option) => option.value
							)
						)}
					onblur={onMarkTouched}
					disabled={isSaving}
				>
					{#each groupField.options as option (option.value)}
						<option
							value={option.value}
							selected={groupRowFieldValueAsStringArray(field, rowValue, groupField).includes(
								option.value
							)}
						>
							{option.label}
						</option>
					{/each}
				</select>
			{:else if groupField.type === 'toggle'}
				<input
					id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
					type="checkbox"
					checked={groupRowFieldValueAsBoolean(field, rowValue, groupField)}
					onchange={(event) =>
						onUpdateChecked(groupField, (event.currentTarget as HTMLInputElement).checked)}
					onblur={onMarkTouched}
					disabled={isSaving}
				/>
			{:else if groupField.type === 'radio'}
				<fieldset>
					<legend>{groupField.label}</legend>
					{#each groupField.options as option (option.value)}
						<label>
							<input
								id={`${testId}-field-${field.name}-${index}-${groupField.name}-${option.value}`}
								type="radio"
								name={`${testId}-field-${field.name}-${index}-${groupField.name}`}
								data-testid={editorDialogArrayGroupItemFieldOptionTestId(
									field.name,
									index,
									groupField.name,
									option.value
								)}
								value={option.value}
								checked={groupRowFieldValueAsString(field, rowValue, groupField) === option.value}
								onchange={(event) =>
									onUpdateField(groupField, (event.currentTarget as HTMLInputElement).value)}
								onblur={onMarkTouched}
								disabled={isSaving}
							/>
							<span>{option.label}</span>
						</label>
					{/each}
				</fieldset>
			{:else}
				<input
					id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
					type={inputTypeForSimpleField(groupField)}
					maxlength={inputMaxLength(groupField)}
					pattern={inputPattern(groupField)}
					min={inputMinimum(groupField)}
					max={inputMaximum(groupField)}
					step={inputStep(groupField)}
					value={groupRowFieldValueAsString(field, rowValue, groupField)}
					oninput={(event) =>
						onUpdateField(groupField, (event.currentTarget as HTMLInputElement).value)}
					onblur={onMarkTouched}
					disabled={isSaving}
				/>
			{/if}
		{/each}
		<button
			type="button"
			data-testid={`editor-dialog-remove-${field.name}-${index}`}
			onclick={onRemove}
			disabled={isSaving || !canRemoveArrayRow(field, rowsLength)}
		>
			Remove
		</button>
	</div>
{/if}
