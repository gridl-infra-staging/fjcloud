<script lang="ts">
	import { invalidateAll } from '$app/navigation';
	import { applyAction, deserialize, enhance } from '$app/forms';
	import type { Index, SecuritySource, SecuritySourcesResponse } from '$lib/api/types';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogFieldSchema,
		EditorDialogSaveRejection,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';

	type Props = {
		index: Index;
		securitySources: SecuritySourcesResponse;
		securitySourcesLoadError: string;
		securitySourceAppendError: string;
		securitySourceDeleteError: string;
		securitySourceAppended: boolean;
		securitySourceDeleted: boolean;
	};

	let {
		index,
		securitySources,
		securitySourcesLoadError,
		securitySourceAppendError,
		securitySourceDeleteError,
		securitySourceAppended,
		securitySourceDeleted
	}: Props = $props();

	const addSourceSchema: EditorDialogFieldSchema[] = [
		{
			type: 'text',
			name: 'source',
			label: 'Source',
			required: true,
			placeholder: 'e.g. 192.168.1.0/24',
			validate: (value) => {
				if (typeof value !== 'string' || value.trim().length === 0) {
					return 'Source is required.';
				}
				return null;
			}
		},
		{
			type: 'textarea',
			name: 'description',
			label: 'Description',
			rows: 3
		}
	];
	const addSourceInitialValue: EditorDialogValues = {
		source: '',
		description: ''
	};

	let addSourceDialogOpen = $state(false);

	const sources: SecuritySource[] = $derived(securitySources.sources ?? []);
	const sourceEntryCount = $derived(sources.length);
	const hasSources: boolean = $derived(sources.length > 0);
	const addSourceDisabled = $derived(Boolean(securitySourcesLoadError));

	async function retrySecuritySourcesLoad(): Promise<void> {
		await invalidateAll();
	}

	function openAddSourceDialog(): void {
		if (addSourceDisabled) {
			return;
		}
		addSourceDialogOpen = true;
	}

	function closeAddSourceDialog(): void {
		addSourceDialogOpen = false;
	}

	function isSaveRejection(error: unknown): error is EditorDialogSaveRejection {
		return (
			typeof error === 'object' &&
			error !== null &&
			'message' in error &&
			(typeof (error as { message?: unknown }).message === 'string' ||
				(error as { message?: unknown }).message === undefined)
		);
	}

	function appendFailureMessage(data: unknown): string {
		if (!data || typeof data !== 'object') {
			return 'Failed to add security source';
		}
		const securitySourceAppendError = (data as Record<string, unknown>).securitySourceAppendError;
		if (
			typeof securitySourceAppendError === 'string' &&
			securitySourceAppendError.trim().length > 0
		) {
			return securitySourceAppendError;
		}
		return 'Failed to add security source';
	}

	function formDataFromDialogPayload(payload: EditorDialogValues): FormData {
		const formData = new FormData();
		const source = typeof payload.source === 'string' ? payload.source : '';
		const description = typeof payload.description === 'string' ? payload.description : '';
		formData.set('source', source);
		formData.set('description', description);
		return formData;
	}

	async function submitAddSource(payload: EditorDialogValues): Promise<void> {
		try {
			const response = await fetch('?/appendSecuritySource', {
				method: 'POST',
				headers: {
					'x-sveltekit-action': 'true'
				},
				body: formDataFromDialogPayload(payload)
			});
			const result = deserialize(await response.text());
			await applyAction(result);
			if (result.type === 'failure') {
				throw { message: appendFailureMessage(result.data) } satisfies EditorDialogSaveRejection;
			}
			if (result.type === 'success') {
				closeAddSourceDialog();
			}
		} catch (error) {
			if (isSaveRejection(error)) {
				throw error;
			}
			throw { message: 'Network error — please retry.' } satisfies EditorDialogSaveRejection;
		}
	}
</script>

<div class="space-y-6" data-testid="security-sources-section" data-index={index.name}>
	<div class="rounded-lg bg-white p-6 shadow">
		<div class="mb-2 flex flex-wrap items-center justify-between gap-3">
			<div class="flex items-center gap-2">
				<h2 class="text-lg font-medium text-flapjack-ink">Security Sources</h2>
				<span
					class="inline-flex rounded-full bg-flapjack-cream px-2.5 py-1 text-xs font-medium text-flapjack-ink/80"
					data-testid="security-sources-entry-count"
				>
					{sourceEntryCount}
				</span>
			</div>
			<button
				type="button"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
				data-testid="add-security-source-btn"
				disabled={addSourceDisabled}
				onclick={openAddSourceDialog}
			>
				Add Source
			</button>
		</div>
		<p class="mb-4 text-sm text-flapjack-ink/70">
			Manage IP-based security sources (CIDR ranges) that control access to this index.
		</p>

		{#if securitySourceAppended}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
				role="status"
			>
				Security source added.
			</div>
		{/if}
		{#if securitySourceDeleted}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
				role="status"
			>
				Security source deleted.
			</div>
		{/if}
		{#if securitySourceAppendError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum" role="alert">
				{securitySourceAppendError}
			</div>
		{/if}
		{#if securitySourceDeleteError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum" role="alert">
				{securitySourceDeleteError}
			</div>
		{/if}
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Source Allowlist</h3>
		{#if securitySourcesLoadError}
			<div
				class="rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
				data-testid="security-sources-error-state"
			>
				<p class="font-medium">Unable to load security sources.</p>
				<p class="mt-1">{securitySourcesLoadError}</p>
				<button
					type="button"
					class="mt-3 rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
					data-testid="security-sources-retry-btn"
					onclick={() => {
						void retrySecuritySourcesLoad();
					}}
				>
					Retry
				</button>
			</div>
		{:else if hasSources}
			<div class="space-y-3">
				{#each sources as entry (entry.source)}
					<div
						class="flex items-center justify-between rounded-md border border-flapjack-ink/20 p-3"
						data-testid="security-source-row"
					>
						<div>
							<p class="font-mono text-sm text-flapjack-ink">{entry.source}</p>
							{#if entry.description}
								<p class="text-xs text-flapjack-ink/60">{entry.description}</p>
							{:else}
								<p class="text-xs text-flapjack-ink/60">No description</p>
							{/if}
						</div>
						<form method="POST" action="?/deleteSecuritySource" use:enhance>
							<input type="hidden" name="source" value={entry.source} />
							<button
								type="submit"
								data-testid="delete-security-source-btn"
								aria-label={`Delete security source ${entry.source}`}
								class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
							>
								Delete
							</button>
						</form>
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-flapjack-ink/60" data-testid="security-sources-empty-state">
				No security sources configured yet.
			</p>
		{/if}
	</div>

	<EditorDialog
		title="Add Security Source"
		mode="create"
		schema={addSourceSchema}
		initialValue={addSourceInitialValue}
		open={addSourceDialogOpen}
		onSave={submitAddSource}
		onCancel={closeAddSourceDialog}
		submitLabel="Add Source"
	/>
</div>
