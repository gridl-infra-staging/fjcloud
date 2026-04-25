<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatDate, indexStatusBadgeColor, statusLabel } from '$lib/format';
	import { AYB_PLAN_OPTIONS, type AybInstance } from '$lib/api/types';

	const DELETE_CONFIRMATION_MESSAGE = 'Are you sure you want to delete this database instance?';
	type SubmissionUpdate = { update: () => Promise<void> };
	type PendingSetter = (value: boolean) => void;
	type LoadErrorCode = 'duplicate_instances' | 'request_failed' | null;

	let { data, form } = $props();

	let instance: AybInstance | null = $derived(data.instance ?? null);
	let provisioningUnavailable: boolean = $derived(data.provisioningUnavailable ?? false);
	let loadError: string | null = $derived(data.loadError ?? null);
	let loadErrorCode: LoadErrorCode = $derived(data.loadErrorCode ?? null);
	let deletePending = $state(false);
	let deleting = $derived(deletePending || instance?.status?.toLowerCase() === 'deleting');
	let creating = $state(false);

	function handleDeleteClick(event: MouseEvent) {
		if (deleting) {
			event.preventDefault();
			return;
		}

		if (!confirm(DELETE_CONFIRMATION_MESSAGE)) {
			event.preventDefault();
		}
	}

	function trackPendingSubmission(setPending: PendingSetter) {
		setPending(true);
		return async ({ update }: SubmissionUpdate) => {
			try {
				await update();
			} finally {
				setPending(false);
			}
		};
	}

	function trackDeleteSubmission() {
		return trackPendingSubmission((value) => {
			deletePending = value;
		});
	}

	function trackCreateSubmission() {
		return trackPendingSubmission((value) => {
			creating = value;
		});
	}
</script>

<svelte:head>
	<title>Database — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-gray-900">Database</h1>
	</div>

	{#if loadError}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700"
		>
			<p>{loadError}</p>
		</div>
	{/if}

	{#if form?.error}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700"
		>
			<p>{form.error}</p>
		</div>
	{/if}

	{#if !instance}
		<div class="rounded-lg bg-white p-8 shadow">
			<h2 class="text-lg font-medium text-gray-900">AllYourBase Database</h2>
			{#if loadErrorCode === 'duplicate_instances'}
				<p class="mt-2 text-sm text-gray-600">
					Resolve the duplicate active database instances for this account before continuing.
				</p>
			{:else if loadError}
				<p class="mt-2 text-sm text-gray-600">
					We couldn't load the persisted database instance state for this account.
				</p>
			{:else if provisioningUnavailable}
				<p class="mt-2 text-sm text-gray-600">Create a new database instance to get started.</p>
				<form
					method="POST"
					action="?/create"
					use:enhance={trackCreateSubmission}
					data-testid="create-instance-form"
					class="mt-4 space-y-4"
				>
					<div>
						<label for="create-name" class="block text-sm font-medium text-gray-700">Name</label>
						<input
							id="create-name"
							type="text"
							name="name"
							required
							data-testid="create-name"
							class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>
					<div>
						<label for="create-slug" class="block text-sm font-medium text-gray-700">Slug</label>
						<input
							id="create-slug"
							type="text"
							name="slug"
							required
							data-testid="create-slug"
							class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>
					<div>
						<label for="create-plan" class="block text-sm font-medium text-gray-700">Plan</label>
						<select
							id="create-plan"
							name="plan"
							required
							data-testid="create-plan"
							class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						>
							{#each AYB_PLAN_OPTIONS as option (option.value)}
								<option value={option.value}>{option.label}</option>
							{/each}
						</select>
					</div>
					<button
						type="submit"
						disabled={creating}
						data-testid="create-submit"
						class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-70"
					>
						{creating ? 'Creating...' : 'Create Database'}
					</button>
				</form>
			{:else}
				<p class="mt-2 text-sm text-gray-600">
					No persisted database instance found for this account.
				</p>
			{/if}
		</div>
	{:else}
		<div class="rounded-lg bg-white p-6 shadow">
			<div class="mb-4 flex items-center justify-between gap-3">
				<div>
					<h2 class="text-lg font-medium text-gray-900">AllYourBase Instance</h2>
					<p class="mt-1 text-sm text-gray-500">{instance.id}</p>
				</div>
				<span
					class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium {indexStatusBadgeColor(
						instance.status
					)}"
				>
					{statusLabel(instance.status)}
				</span>
			</div>

			<div class="grid grid-cols-1 gap-4 text-sm sm:grid-cols-2">
				<div>
					<p class="font-medium text-gray-600">Database URL</p>
					<p class="mt-1 break-all text-gray-900">{instance.ayb_url}</p>
				</div>
				<div>
					<p class="font-medium text-gray-600">Slug</p>
					<p class="mt-1 text-gray-900">{instance.ayb_slug}</p>
				</div>
				<div>
					<p class="font-medium text-gray-600">Cluster ID</p>
					<p class="mt-1 text-gray-900">{instance.ayb_cluster_id}</p>
				</div>
				<div>
					<p class="font-medium text-gray-600">Plan</p>
					<p class="mt-1 text-gray-900">{instance.plan}</p>
				</div>
				<div>
					<p class="font-medium text-gray-600">Created</p>
					<p class="mt-1 text-gray-900">{formatDate(instance.created_at)}</p>
				</div>
				<div>
					<p class="font-medium text-gray-600">Updated</p>
					<p class="mt-1 text-gray-900">{formatDate(instance.updated_at)}</p>
				</div>
			</div>

			<div class="mt-6 border-t border-gray-200 pt-4">
				<form method="POST" action="?/delete" use:enhance={trackDeleteSubmission}>
					<input type="hidden" name="id" value={instance.id} />
					<button
						type="submit"
						disabled={deleting}
						class="rounded border border-red-300 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-70"
						onclick={handleDeleteClick}
					>
						{deleting ? 'Deleting...' : 'Delete Database'}
					</button>
				</form>
			</div>
		</div>
	{/if}
</div>
