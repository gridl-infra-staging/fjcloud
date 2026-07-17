<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';

	type PasswordInputSurface = 'default' | 'neutral' | 'dark';

	type PasswordInputProps = {
		id: string;
		name: string;
		label: string;
		value?: string;
		required?: boolean;
		error?: string | null;
		errorRole?: 'alert';
		autocomplete?: HTMLInputAttributes['autocomplete'];
		minlength?: string | number;
		placeholder?: string;
		'data-testid'?: string;
		revealLabel?: string;
		inputClass?: string;
		surface?: PasswordInputSurface;
	};

	const surfaceStyles: Record<
		PasswordInputSurface,
		{ label: string; input: string; toggle: string; error: string }
	> = {
		default: {
			label: 'text-flapjack-ink/80',
			input:
				'border-flapjack-ink/30 focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose',
			toggle:
				'text-flapjack-ink/70 hover:bg-flapjack-cream/80 hover:text-flapjack-ink focus:ring-flapjack-rose focus:ring-offset-flapjack-cream',
			error: 'text-flapjack-plum'
		},
		neutral: {
			label: 'text-gray-700',
			input: 'border-gray-300 focus:border-blue-500 focus:ring-1 focus:ring-blue-500',
			toggle:
				'text-gray-600 hover:bg-gray-100 hover:text-gray-900 focus:ring-blue-500 focus:ring-offset-white',
			error: 'text-red-600'
		},
		dark: {
			label: 'text-slate-200',
			input:
				'border-slate-700 bg-slate-950 text-slate-100 focus:border-violet-400 focus:outline-none',
			toggle:
				'text-slate-300 hover:bg-slate-800 hover:text-white focus:ring-violet-400 focus:ring-offset-slate-900',
			error: 'text-red-300'
		}
	};

	let {
		id,
		name,
		label,
		value = $bindable(''),
		required = false,
		error,
		errorRole,
		autocomplete,
		minlength,
		placeholder,
		'data-testid': dataTestId,
		revealLabel = 'password',
		inputClass = '',
		surface = 'default'
	}: PasswordInputProps = $props();

	let showPassword = $state(false);
	const inputType = $derived(showPassword ? 'text' : 'password');
	const inputMinLength = $derived(typeof minlength === 'string' ? Number(minlength) : minlength);
	const toggleLabel = $derived(`${showPassword ? 'Hide' : 'Show'} ${revealLabel}`);
	const styles = $derived(surfaceStyles[surface]);
</script>

<div>
	<label for={id} class={`mb-1 block text-sm font-medium ${styles.label}`}>
		{label}
	</label>
	<span class="relative block">
		<input
			{id}
			{name}
			type={inputType}
			bind:value
			{required}
			{autocomplete}
			minlength={inputMinLength}
			{placeholder}
			data-testid={dataTestId}
			class={`w-full rounded border px-3 py-2 pr-32 ${styles.input} ${inputClass}`}
		/>
		<button
			type="button"
			aria-pressed={showPassword}
			class={`absolute inset-y-1 right-1 flex items-center gap-1 rounded px-2 text-xs font-medium focus:ring-2 ${styles.toggle}`}
			onclick={() => {
				showPassword = !showPassword;
			}}
		>
			{#if showPassword}
				<svg aria-hidden="true" class="h-4 w-4" fill="none" viewBox="0 0 24 24">
					<path d="M3 3l18 18" stroke="currentColor" stroke-linecap="round" stroke-width="2" />
					<path
						d="M10.6 10.7a2 2 0 0 0 2.7 2.7"
						stroke="currentColor"
						stroke-linecap="round"
						stroke-width="2"
					/>
					<path
						d="M9.2 5.4A9.5 9.5 0 0 1 12 5c4.5 0 8.1 3 10 7a12.2 12.2 0 0 1-3.2 4.2M6.2 6.2A12.2 12.2 0 0 0 2 12c1.9 4 5.5 7 10 7 1.3 0 2.5-.2 3.6-.7"
						stroke="currentColor"
						stroke-linecap="round"
						stroke-linejoin="round"
						stroke-width="2"
					/>
				</svg>
			{:else}
				<svg aria-hidden="true" class="h-4 w-4" fill="none" viewBox="0 0 24 24">
					<path
						d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"
						stroke="currentColor"
						stroke-linejoin="round"
						stroke-width="2"
					/>
					<circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="2" />
				</svg>
			{/if}
			<span>{toggleLabel}</span>
		</button>
	</span>
	{#if error}
		<p class={`mt-1 text-sm ${styles.error}`} role={errorRole}>{error}</p>
	{/if}
</div>
