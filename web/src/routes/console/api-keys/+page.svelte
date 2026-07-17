<script lang="ts">
	import { applyAction, deserialize, enhance } from '$app/forms';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
	import { onMount } from 'svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogFieldSchema,
		EditorDialogSaveRejection,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';
	import { copyToClipboard } from '$lib/clipboard';
	import { DEFAULT_MANAGEMENT_SCOPE, formatDate, MANAGEMENT_SCOPES, scopeLabel } from '$lib/format';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import type { ApiKeyListItem, Index } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let apiKeys: ApiKeyListItem[] = $derived(data.apiKeys ?? []);
	let indexOptions: Index[] = $derived(data.indexOptions ?? []);
	let selectedIndexFilter = $derived((data.selectedIndexFilter as string) ?? '');
	let selectedIndexFilterValue = $derived(selectedIndexFilter);
	let formErrorMessage = $derived((formResult?.error as string) ?? '');
	let loadErrorMessage = $derived((data.loadError as string) ?? '');
	let errorMessage = $derived(formErrorMessage || loadErrorMessage);
	let createdKey = $derived((formResult?.createdKey as string) ?? '');
	let createdKeyId = $derived((formResult?.createdKeyId as string) ?? '');
	let filterOptions = $derived.by(() => {
		const distinctIndexes: string[] = [];
		for (const key of apiKeys) {
			for (const indexName of key.indexes) {
				if (indexName.trim().length > 0 && !distinctIndexes.includes(indexName)) {
					distinctIndexes.push(indexName);
				}
			}
		}
		return distinctIndexes.sort((left, right) => left.localeCompare(right));
	});
	let filteredApiKeys = $derived.by(() => {
		if (!selectedIndexFilterValue) {
			return apiKeys;
		}
		return apiKeys.filter(
			(key) => key.indexes.length === 0 || key.indexes.includes(selectedIndexFilterValue)
		);
	});

	let showCreateDialog = $state(false);
	let pendingDeleteKey = $state<ApiKeyListItem | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);
	let interactiveReady = $state(false);
	let requestedIndexFilter = $state('');

	onMount(() => {
		requestedIndexFilter = selectedIndexFilter;
		interactiveReady = true;
	});

	const createDialogSchema = $derived<EditorDialogFieldSchema[]>([
		{
			type: 'text',
			name: 'name',
			label: 'Name',
			required: true,
			maxLength: 120,
			placeholder: 'e.g. Production Key'
		},
		{
			type: 'textarea',
			name: 'description',
			label: 'Description',
			rows: 3,
			maxLength: 500
		},
		{
			type: 'multiselect',
			name: 'indexes',
			label: 'Indexes',
			options: indexOptions.map((indexOption) => ({
				value: indexOption.name,
				label: indexOption.name
			}))
		},
		{
			type: 'multiselect',
			name: 'scopes',
			label: 'ACL',
			required: true,
			minItems: 1,
			options: MANAGEMENT_SCOPES.map((scope) => ({
				value: scope.value,
				label: scope.label
			}))
		},
		{
			type: 'array',
			name: 'restrict_sources',
			label: 'Restrict sources',
			addLabel: 'Add source',
			item: {
				type: 'text',
				name: 'source',
				label: 'Source restriction',
				placeholder: 'e.g. 10.0.0.0/24'
			}
		},
		{
			type: 'datetime-local',
			name: 'expires_at',
			label: 'Expires at'
		},
		{
			type: 'number',
			name: 'max_hits_per_query',
			label: 'Max hits per query',
			min: 1,
			integer: true
		},
		{
			type: 'number',
			name: 'max_queries_per_ip_per_hour',
			label: 'Max queries per IP per hour',
			min: 1,
			integer: true
		}
	]);

	function createDialogInitialValue(): EditorDialogValues {
		return {
			name: '',
			description: '',
			indexes: [],
			scopes: DEFAULT_MANAGEMENT_SCOPE ? [DEFAULT_MANAGEMENT_SCOPE] : [],
			restrict_sources: [],
			expires_at: '',
			max_hits_per_query: null,
			max_queries_per_ip_per_hour: null
		};
	}

	function optionalStringValue(value: unknown): string {
		return typeof value === 'string' ? value.trim() : '';
	}

	function stringArrayValue(value: unknown): string[] {
		if (!Array.isArray(value)) {
			return [];
		}
		return value
			.filter((entry): entry is string => typeof entry === 'string')
			.map((entry) => entry.trim())
			.filter((entry) => entry.length > 0);
	}

	function optionalNumberValue(value: unknown): string {
		return typeof value === 'number' && Number.isFinite(value) ? String(value) : '';
	}

	function timezoneOffsetMinutesForDateTimeLocal(value: string): string {
		if (value.trim().length === 0) {
			return '0';
		}

		const datetimeLocalMatch = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
		if (!datetimeLocalMatch) {
			return '0';
		}

		const [, year, month, day, hour, minute, second = '00'] = datetimeLocalMatch;
		const localDate = new Date(
			Number(year),
			Number(month) - 1,
			Number(day),
			Number(hour),
			Number(minute),
			Number(second)
		);
		return String(localDate.getTimezoneOffset());
	}

	function buildCreateFormData(values: EditorDialogValues): FormData {
		const formData = new FormData();
		formData.set('name', optionalStringValue(values.name));
		formData.set('description', optionalStringValue(values.description));

		for (const scope of stringArrayValue(values.scopes)) {
			formData.append('scope', scope);
		}
		for (const indexName of stringArrayValue(values.indexes)) {
			formData.append('indexes', indexName);
		}
		for (const sourceRestriction of stringArrayValue(values.restrict_sources)) {
			formData.append('restrict_sources', sourceRestriction);
		}

		const expiresAt = optionalStringValue(values.expires_at);
		formData.set('expires_at', expiresAt);
		formData.set(
			'expires_at_timezone_offset_minutes',
			timezoneOffsetMinutesForDateTimeLocal(expiresAt)
		);
		formData.set('max_hits_per_query', optionalNumberValue(values.max_hits_per_query));
		formData.set(
			'max_queries_per_ip_per_hour',
			optionalNumberValue(values.max_queries_per_ip_per_hour)
		);
		return formData;
	}

	function createFailureMessage(result: ActionResult): string {
		if (result.type === 'failure') {
			const errorValue = (result.data as Record<string, unknown> | null)?.error;
			if (typeof errorValue === 'string' && errorValue.trim().length > 0) {
				return errorValue;
			}
		}
		return 'Failed to create API key';
	}

	function revokedKeyNameFromResult(result: ActionResult, fallbackKeyName = ''): string {
		if (result.type !== 'success') {
			return '';
		}
		const revokedKeyName = (result.data as Record<string, unknown> | null)?.revokedKeyName;
		const normalizedKeyName = typeof revokedKeyName === 'string' ? revokedKeyName.trim() : '';
		return normalizedKeyName.length > 0 ? normalizedKeyName : fallbackKeyName;
	}

	function emitRevokeSuccessToast(keyName: string): void {
		if (keyName.length === 0) {
			return;
		}
		toast.success(`API key '${keyName}' revoked.`, { duration: TOAST_DURATION_MS });
	}

	const handleRevokeSubmit: SubmitFunction = ({ formData }) => {
		const submittedKeyName = optionalStringValue(formData.get('keyName'));
		return async ({ result, update }) => {
			emitRevokeSuccessToast(revokedKeyNameFromResult(result, submittedKeyName));
			await update();
		};
	};

	async function saveCreateDialog(values: EditorDialogValues): Promise<void> {
		const response = await fetch('?/create', {
			method: 'POST',
			body: buildCreateFormData(values)
		});
		const result = deserialize(await response.text()) as ActionResult;

		if (result.type === 'failure') {
			throw { message: createFailureMessage(result) } satisfies EditorDialogSaveRejection;
		}

		await applyAction(result);

		if (result.type === 'success') {
			showCreateDialog = false;
			await invalidateAll();
			return;
		}

		if (result.type === 'redirect') {
			showCreateDialog = false;
			return;
		}

		if (result.type === 'error') {
			throw new Error('Failed to create API key');
		}
	}

	function openDeleteConfirmDialog(
		key: ApiKeyListItem,
		form: HTMLFormElement,
		trigger: HTMLElement
	): void {
		pendingDeleteKey = key;
		pendingDeleteForm = form;
		pendingDeleteTrigger = trigger;
	}

	function closeDeleteConfirmDialog(): void {
		pendingDeleteKey = null;
		pendingDeleteForm = null;
		pendingDeleteTrigger = null;
	}

	function confirmDeleteKey(): void {
		const form = pendingDeleteForm;
		if (!form) {
			return;
		}
		form.requestSubmit();
		closeDeleteConfirmDialog();
	}

	function isExpired(expiresAt: string | null): boolean {
		if (!expiresAt) {
			return false;
		}
		const expiresAtEpoch = new Date(expiresAt).getTime();
		return Number.isFinite(expiresAtEpoch) && expiresAtEpoch <= Date.now();
	}

	function limitsSummary(key: ApiKeyListItem): string[] {
		const summaries: string[] = [];
		if (key.max_hits_per_query !== null) {
			summaries.push(`${key.max_hits_per_query} hits/query`);
		}
		if (key.max_queries_per_ip_per_hour !== null) {
			summaries.push(`${key.max_queries_per_ip_per_hour} queries/IP/hr`);
		}
		return summaries;
	}

	function copyValueForKey(key: ApiKeyListItem): string {
		if (createdKey && createdKeyId === key.id) {
			return createdKey;
		}
		return key.key_prefix;
	}

	async function handleCopyKey(
		key: ApiKeyListItem,
		buttonElement: HTMLButtonElement | null
	): Promise<void> {
		await copyApiKeyValue(copyValueForKey(key), buttonElement);
	}

	async function copyApiKeyValue(
		value: string,
		buttonElement: HTMLButtonElement | null
	): Promise<void> {
		const copied = await copyToClipboard(value, buttonElement);
		if (copied) {
			toast.success('API key copied', { duration: TOAST_DURATION_MS });
		}
	}

	function updateIndexFilter(nextIndex: string): void {
		const normalizedNextIndex = nextIndex.trim();
		if (normalizedNextIndex === requestedIndexFilter) {
			return;
		}
		selectedIndexFilterValue = normalizedNextIndex;
		requestedIndexFilter = normalizedNextIndex;

		const currentEntries = Array.from(new URL(window.location.href).searchParams.entries()).filter(
			([key]) => key !== 'index'
		);
		if (normalizedNextIndex.length > 0) {
			currentEntries.push(['index', normalizedNextIndex]);
		}

		const query = currentEntries
			.map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
			.join('&');
		if (query.length > 0) {
			// eslint-disable-next-line svelte/no-navigation-without-resolve -- typed routes reject `${path}?${string}` query forms; resolve() is for path literals only.
			void goto(`${resolve('/console/api-keys')}?${query}`, { keepFocus: true, noScroll: true });
		} else {
			void goto(resolve('/console/api-keys'), { keepFocus: true, noScroll: true });
		}
	}

	function handleIndexFilterInput(event: Event): void {
		updateIndexFilter((event.currentTarget as HTMLSelectElement).value);
	}
</script>

<svelte:head>
	<title>API Keys — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6 flex flex-wrap items-center justify-between gap-3">
		<h1 class="text-2xl font-bold text-flapjack-ink">API Keys</h1>
		<button
			type="button"
			disabled={!interactiveReady}
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
			onclick={() => {
				showCreateDialog = true;
			}}
		>
			Create API Key
		</button>
	</div>

	{#if errorMessage}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if createdKey}
		<div
			data-testid="key-reveal"
			class="mb-6 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4"
		>
			<div class="flex flex-wrap items-start justify-between gap-3">
				<div>
					<p class="mb-2 font-medium text-flapjack-ink">API key created successfully</p>
					<p class="mb-2 text-sm text-flapjack-ink/80">
						This key won't be shown again. Copy it now.
					</p>
				</div>
				<button
					type="button"
					class="rounded border border-flapjack-ink/20 px-3 py-1.5 text-sm text-flapjack-ink/80 hover:bg-white/70"
					onclick={(event) =>
						void copyApiKeyValue(createdKey, event.currentTarget as HTMLButtonElement)}
				>
					Copy
				</button>
			</div>
			<code class="block break-all rounded bg-white p-3 font-mono text-sm text-flapjack-ink"
				>{createdKey}</code
			>
		</div>
	{/if}

	<div class="mb-4 flex flex-wrap items-center gap-3">
		<label class="text-sm font-medium text-flapjack-ink/80" for="api-key-index-filter"
			>Index filter</label
		>
		<select
			id="api-key-index-filter"
			class="rounded-md border border-flapjack-ink/30 bg-white px-3 py-2 text-sm text-flapjack-ink focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			data-testid="index-filter"
			disabled={!interactiveReady}
			oninput={handleIndexFilterInput}
			onchange={handleIndexFilterInput}
			bind:value={selectedIndexFilterValue}
		>
			<option value="">All indexes</option>
			{#each filterOptions as indexName (indexName)}
				<option value={indexName}>{indexName}</option>
			{/each}
		</select>
	</div>

	{#if apiKeys.length === 0}
		{#if !loadErrorMessage}
			<div class="rounded-lg bg-white p-6 text-center shadow">
				<p class="text-flapjack-ink/70">No API keys. Create one to get started.</p>
			</div>
		{/if}
	{:else if filteredApiKeys.length === 0}
		<div class="rounded-lg bg-white p-6 text-center shadow">
			<p class="text-flapjack-ink/70">No API keys match this filter.</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-4 py-3">Name</th>
						<th class="px-4 py-3">Prefix</th>
						<th class="px-4 py-3">Scopes</th>
						<th class="px-4 py-3">Indexes</th>
						<th class="px-4 py-3">Restrictions</th>
						<th class="px-4 py-3">Expires</th>
						<th class="px-4 py-3">Limits</th>
						<th class="px-4 py-3">Last used</th>
						<th class="px-4 py-3">Created</th>
						<th class="px-4 py-3"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each filteredApiKeys as key (key.id)}
						<tr class={isExpired(key.expires_at) ? 'bg-flapjack-cream/30' : ''}>
							<td class="px-4 py-3">
								<div class="flex flex-wrap items-center gap-2">
									<span class="font-medium text-flapjack-ink">{key.name}</span>
									{#if isExpired(key.expires_at)}
										<span
											class="rounded-full border border-flapjack-rose/35 bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
										>
											Expired
										</span>
									{/if}
								</div>
								{#if key.description}
									<p class="mt-1 text-xs text-flapjack-ink/70">{key.description}</p>
								{/if}
							</td>
							<td class="px-4 py-3 font-mono text-flapjack-ink/70">{key.key_prefix}...</td>
							<td class="px-4 py-3">
								<div class="flex flex-wrap gap-1">
									{#each key.scopes as scope (scope)}
										<span
											class="rounded bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
											>{scopeLabel(scope)}</span
										>
									{/each}
								</div>
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{#if key.indexes.length === 0}
									<span>All indexes</span>
								{:else}
									<div class="flex flex-wrap gap-1">
										{#each key.indexes as indexName (indexName)}
											<span
												class="rounded bg-flapjack-mint/20 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
												>{indexName}</span
											>
										{/each}
									</div>
								{/if}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{#if key.restrict_sources.length === 0}
									<span>No restrictions</span>
								{:else}
									<div class="space-y-1">
										{#each key.restrict_sources as sourceRestriction (sourceRestriction)}
											<div>{sourceRestriction}</div>
										{/each}
									</div>
								{/if}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{#if key.expires_at}
									{formatDate(key.expires_at)}
								{:else}
									No expiry
								{/if}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{#if limitsSummary(key).length === 0}
									<span>No caps</span>
								{:else}
									<div class="space-y-1">
										{#each limitsSummary(key) as limitEntry (limitEntry)}
											<div>{limitEntry}</div>
										{/each}
									</div>
								{/if}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{key.last_used_at ? formatDate(key.last_used_at) : 'Never'}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatDate(key.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<div class="flex justify-end gap-2">
									<button
										aria-label={`Copy key for ${key.name}`}
										disabled={!interactiveReady}
										class="rounded border border-flapjack-ink/25 px-3 py-1 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/70 disabled:cursor-not-allowed disabled:opacity-60"
										type="button"
										onclick={(event) =>
											void handleCopyKey(key, event.currentTarget as HTMLButtonElement)}
									>
										Copy
									</button>
									<form method="POST" action="?/revoke" use:enhance={handleRevokeSubmit}>
										<input type="hidden" name="keyId" value={key.id} />
										<input type="hidden" name="keyName" value={key.name} />
										<button
											aria-label={`Revoke key ${key.name}`}
											disabled={!interactiveReady}
											class="rounded border border-flapjack-rose/45 px-3 py-1 text-sm text-flapjack-plum hover:bg-flapjack-rose/10 disabled:cursor-not-allowed disabled:opacity-60"
											type="button"
											onclick={(event) =>
												openDeleteConfirmDialog(
													key,
													(event.currentTarget as HTMLButtonElement).closest(
														'form'
													) as HTMLFormElement,
													event.currentTarget as HTMLButtonElement
												)}
										>
											Revoke
										</button>
									</form>
								</div>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<EditorDialog
	title="Create API Key"
	mode="create"
	schema={createDialogSchema}
	initialValue={createDialogInitialValue()}
	open={showCreateDialog}
	onSave={saveCreateDialog}
	onCancel={() => {
		showCreateDialog = false;
	}}
	description="Create a scoped key for search or management access."
	submitLabel="Create key"
	testId="api-keys-create-dialog"
/>

<ConfirmDialog
	open={pendingDeleteKey !== null}
	mode="typed"
	dangerLevel="severe"
	title={`Revoke key "${pendingDeleteKey?.name ?? ''}"?`}
	consequences="Revoking this key permanently removes its access from customer-facing search and management flows."
	rationale="Type the key name to confirm this destructive action."
	entityName={pendingDeleteKey?.name ?? ''}
	typedPhrase={pendingDeleteKey?.name ?? ''}
	confirmLabel="Revoke key"
	cancelLabel="Cancel"
	onCancel={closeDeleteConfirmDialog}
	onConfirm={confirmDeleteKey}
	triggerRef={pendingDeleteTrigger}
/>
