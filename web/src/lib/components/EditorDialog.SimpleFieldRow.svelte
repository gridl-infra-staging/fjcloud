<script lang="ts">
	import type { EditorDialogSimpleFieldSchema } from './EditorDialog.types';
	import {
		inputMaxLength,
		inputMaximum,
		inputMinimum,
		inputPattern,
		inputStep,
		inputTypeForSimpleField
	} from './EditorDialog.fieldHelpers';

	let {
		field,
		testId,
		simpleFieldClass,
		compactToggleClass,
		radioOptionClass,
		effectivelySaving,
		valueAsString,
		valueAsStringArray,
		valueAsBoolean,
		updateSimpleFieldValue,
		updateSimpleFieldCheckedValue,
		updateSimpleFieldSelectedValues,
		markTouched
	}: {
		field: EditorDialogSimpleFieldSchema;
		testId: string;
		simpleFieldClass: string;
		compactToggleClass: string;
		radioOptionClass: (selected: boolean) => string;
		effectivelySaving: boolean;
		valueAsString: (name: string) => string;
		valueAsStringArray: (name: string) => string[];
		valueAsBoolean: (name: string) => boolean;
		updateSimpleFieldValue: (field: EditorDialogSimpleFieldSchema, rawValue: string) => void;
		updateSimpleFieldCheckedValue: (field: EditorDialogSimpleFieldSchema, checked: boolean) => void;
		updateSimpleFieldSelectedValues: (
			field: EditorDialogSimpleFieldSchema,
			selectedValues: string[]
		) => void;
		markTouched: (name: string) => void;
	} = $props();
</script>

{#if field.type !== 'radio' && field.type !== 'toggle'}
	<label
		class="block text-sm font-medium text-flapjack-ink/80"
		for={`${testId}-field-${field.name}`}>{field.label}</label
	>
{/if}
{#if field.helpText}
	<p class="text-xs text-flapjack-ink/60">{field.helpText}</p>
{/if}
{#if field.type === 'textarea'}
	<textarea
		id={`${testId}-field-${field.name}`}
		data-testid={`editor-dialog-field-${field.name}`}
		class={simpleFieldClass}
		rows={field.rows ?? 4}
		maxlength={inputMaxLength(field)}
		value={valueAsString(field.name)}
		oninput={(event) =>
			updateSimpleFieldValue(field, (event.currentTarget as HTMLTextAreaElement).value)}
		onblur={() => markTouched(field.name)}
		disabled={effectivelySaving}
	></textarea>
{:else if field.type === 'select'}
	<select
		id={`${testId}-field-${field.name}`}
		data-testid={`editor-dialog-field-${field.name}`}
		class={simpleFieldClass}
		value={valueAsString(field.name)}
		onchange={(event) =>
			updateSimpleFieldValue(field, (event.currentTarget as HTMLSelectElement).value)}
		onblur={() => markTouched(field.name)}
		disabled={effectivelySaving}
	>
		{#each field.options as option (option.value)}
			<option title={option.label} value={option.value}>{option.label}</option>
		{/each}
	</select>
{:else if field.type === 'multiselect'}
	<select
		id={`${testId}-field-${field.name}`}
		data-testid={`editor-dialog-field-${field.name}`}
		class={`${simpleFieldClass} min-h-32`}
		multiple
		onchange={(event) =>
			updateSimpleFieldSelectedValues(
				field,
				Array.from((event.currentTarget as HTMLSelectElement).selectedOptions).map(
					(option) => option.value
				)
			)}
		onblur={() => markTouched(field.name)}
		disabled={effectivelySaving}
	>
		{#each field.options as option (option.value)}
			<option
				title={option.label}
				value={option.value}
				selected={valueAsStringArray(field.name).includes(option.value)}
			>
				{option.label}
			</option>
		{/each}
	</select>
{:else if field.type === 'toggle'}
	<label
		class="flex items-center gap-3 rounded-md border border-flapjack-ink/15 bg-white/70 px-3 py-2 text-sm font-medium text-flapjack-ink/80"
		for={`${testId}-field-${field.name}`}
	>
		<input
			id={`${testId}-field-${field.name}`}
			data-testid={`editor-dialog-field-${field.name}`}
			type="checkbox"
			class={compactToggleClass}
			checked={valueAsBoolean(field.name)}
			onchange={(event) =>
				updateSimpleFieldCheckedValue(field, (event.currentTarget as HTMLInputElement).checked)}
			onblur={() => markTouched(field.name)}
			disabled={effectivelySaving}
		/>
		<span>{field.label}</span>
	</label>
{:else if field.type === 'radio'}
	<fieldset class="space-y-3 rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/20 p-3">
		<legend class="px-1 text-sm font-medium text-flapjack-ink/80">{field.label}</legend>
		<div class="grid gap-3 sm:grid-cols-2">
			{#each field.options as option (option.value)}
				{@const selected = valueAsString(field.name) === option.value}
				<label class={radioOptionClass(selected)}>
					<input
						id={`${testId}-field-${field.name}-${option.value}`}
						data-testid={`editor-dialog-field-${field.name}-${option.value}`}
						type="radio"
						class="sr-only"
						name={`${testId}-field-${field.name}`}
						value={option.value}
						checked={selected}
						onchange={(event) =>
							updateSimpleFieldValue(field, (event.currentTarget as HTMLInputElement).value)}
						onblur={() => markTouched(field.name)}
						disabled={effectivelySaving}
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
		id={`${testId}-field-${field.name}`}
		data-testid={`editor-dialog-field-${field.name}`}
		type={inputTypeForSimpleField(field)}
		class={simpleFieldClass}
		maxlength={inputMaxLength(field)}
		pattern={inputPattern(field)}
		min={inputMinimum(field)}
		max={inputMaximum(field)}
		step={inputStep(field)}
		value={valueAsString(field.name)}
		oninput={(event) =>
			updateSimpleFieldValue(field, (event.currentTarget as HTMLInputElement).value)}
		onblur={() => markTouched(field.name)}
		disabled={effectivelySaving}
	/>
{/if}
