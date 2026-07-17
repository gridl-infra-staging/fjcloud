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
		onRemove,
		classes
	}: {
		field: EditorDialogArrayFieldSchema;
		rowValue: unknown;
		index: number;
		testId: string;
		isSaving: boolean;
		rowsLength: number;
		onUpdateField: (groupField: EditorDialogSimpleFieldSchema, rawValue: string) => void;
		onUpdateChecked: (groupField: EditorDialogSimpleFieldSchema, checked: boolean) => void;
		onUpdateSelected: (groupField: EditorDialogSimpleFieldSchema, selectedValues: string[]) => void;
		onMarkTouched: () => void;
		onRemove: () => void;
		classes: {
			simpleField: string;
			compactToggle: string;
			secondaryButton: string;
			radioOption: (selected: boolean) => string;
		};
	} = $props();
</script>

{#if isGroupArrayItem(field.item)}
	<div
		class="space-y-4 rounded-lg border border-flapjack-ink/20 bg-white p-4"
		data-testid={editorDialogArrayItemTestId(field.name, index)}
	>
		{#each field.item.fields as groupField (groupField.name)}
			<div class="space-y-1.5">
				{#if groupField.type !== 'radio' && groupField.type !== 'toggle'}
					<label
						class="block text-sm font-medium text-flapjack-ink/80"
						for={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					>
						{groupField.label}
					</label>
				{/if}
				{#if groupField.helpText}
					<p class="text-xs text-flapjack-ink/60">{groupField.helpText}</p>
				{/if}
				{#if groupField.type === 'textarea'}
					<textarea
						id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
						data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
						class={classes.simpleField}
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
						class={classes.simpleField}
						value={groupRowFieldValueAsString(field, rowValue, groupField)}
						onchange={(event) =>
							onUpdateField(groupField, (event.currentTarget as HTMLSelectElement).value)}
						onblur={onMarkTouched}
						disabled={isSaving}
					>
						{#each groupField.options as option (option.value)}
							<option title={option.label} value={option.value}>{option.label}</option>
						{/each}
					</select>
				{:else if groupField.type === 'multiselect'}
					<select
						id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
						data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
						class={`${classes.simpleField} min-h-32`}
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
								title={option.label}
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
					<label
						class="flex items-center gap-3 rounded-md border border-flapjack-ink/15 bg-white/70 px-3 py-2 text-sm font-medium text-flapjack-ink/80"
						for={`${testId}-field-${field.name}-${index}-${groupField.name}`}
					>
						<input
							id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
							data-testid={editorDialogArrayGroupItemFieldTestId(
								field.name,
								index,
								groupField.name
							)}
							type="checkbox"
							class={classes.compactToggle}
							checked={groupRowFieldValueAsBoolean(field, rowValue, groupField)}
							onchange={(event) =>
								onUpdateChecked(groupField, (event.currentTarget as HTMLInputElement).checked)}
							onblur={onMarkTouched}
							disabled={isSaving}
						/>
						<span>{groupField.label}</span>
					</label>
				{:else if groupField.type === 'radio'}
					<fieldset
						class="space-y-3 rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/20 p-3"
					>
						<legend class="px-1 text-sm font-medium text-flapjack-ink/80">{groupField.label}</legend
						>
						<div class="grid gap-3 sm:grid-cols-2">
							{#each groupField.options as option (option.value)}
								{@const selected =
									groupRowFieldValueAsString(field, rowValue, groupField) === option.value}
								<label class={classes.radioOption(selected)}>
									<input
										id={`${testId}-field-${field.name}-${index}-${groupField.name}-${option.value}`}
										type="radio"
										name={`${testId}-field-${field.name}-${index}-${groupField.name}`}
										class="sr-only"
										data-testid={editorDialogArrayGroupItemFieldOptionTestId(
											field.name,
											index,
											groupField.name,
											option.value
										)}
										value={option.value}
										checked={selected}
										onchange={(event) =>
											onUpdateField(groupField, (event.currentTarget as HTMLInputElement).value)}
										onblur={onMarkTouched}
										disabled={isSaving}
									/>
									<span class="block text-sm font-medium text-flapjack-ink">{option.label}</span>
									{#if option.description}
										<span class="mt-1 block text-xs text-flapjack-ink/60">
											{option.description}
										</span>
									{/if}
								</label>
							{/each}
						</div>
					</fieldset>
				{:else}
					<input
						id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
						data-testid={editorDialogArrayGroupItemFieldTestId(field.name, index, groupField.name)}
						type={inputTypeForSimpleField(groupField)}
						class={classes.simpleField}
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
			</div>
		{/each}
		<button
			type="button"
			data-testid={`editor-dialog-remove-${field.name}-${index}`}
			class={classes.secondaryButton}
			onclick={onRemove}
			disabled={isSaving || !canRemoveArrayRow(field, rowsLength)}
		>
			Remove
		</button>
	</div>
{/if}
