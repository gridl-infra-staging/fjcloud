<script lang="ts">
	import type { AdminMigration } from '$lib/admin-client';
	import { adminBadgeColor } from '$lib/format';

	let { data, form } = $props<{
		data: { activeMigrations: AdminMigration[]; recentMigrations: AdminMigration[] };
		form?: { error?: string; message?: string };
	}>();

	const activeMigrations = $derived(data.activeMigrations);
	const recentMigrations = $derived(data.recentMigrations);

	function formatTimestamp(value: string | null): string {
		if (!value) return '—';
		return new Date(value).toLocaleString();
	}
</script>

<svelte:head>
	<title>Migrations - Admin Panel</title>
</svelte:head>

<div class="space-y-8">
	<h2 class="text-xl font-semibold text-white">Migration Management</h2>

	{#if form?.error}
		<p class="rounded-md border border-red-500/40 bg-red-950/30 px-3 py-2 text-sm text-red-200">
			{form.error}
		</p>
	{:else if form?.message}
		<p
			class="rounded-md border border-green-500/40 bg-green-950/30 px-3 py-2 text-sm text-green-200"
		>
			{form.message}
		</p>
	{/if}

	<div class="rounded-lg border border-violet-900/40 bg-violet-950/20 p-4">
		<h3 class="text-lg font-medium text-violet-300">Trigger Migration</h3>
		<form method="POST" action="?/trigger" class="mt-4 grid gap-4 md:grid-cols-3">
			<label class="text-sm text-slate-300">
				Index Name
				<input
					type="text"
					name="index_name"
					required
					class="mt-1 w-full rounded-md border border-slate-600 bg-slate-900 px-3 py-2 text-sm text-slate-100"
					placeholder="products"
				/>
			</label>
			<label class="text-sm text-slate-300">
				Destination VM ID
				<input
					type="text"
					name="dest_vm_id"
					required
					class="mt-1 w-full rounded-md border border-slate-600 bg-slate-900 px-3 py-2 text-sm text-slate-100"
					placeholder="00000000-0000-0000-0000-000000000000"
				/>
			</label>
			<div class="flex items-end">
				<button
					type="submit"
					class="rounded-md border border-violet-500 bg-violet-600/30 px-4 py-2 text-sm font-medium text-violet-100 transition hover:bg-violet-600/45"
				>
					Start Migration
				</button>
			</div>
		</form>
	</div>

	<div class="space-y-3">
		<h3 class="text-lg font-medium text-slate-100">Active Migrations</h3>
		{#if activeMigrations.length === 0}
			<p
				class="rounded-md border border-slate-700 bg-slate-800/40 px-3 py-2 text-sm text-slate-400"
			>
				No active migrations.
			</p>
		{:else}
			<div
				class="overflow-x-auto rounded-lg border border-slate-700"
				data-testid="active-migrations-table"
			>
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Index</th>
							<th class="px-4 py-3">Status</th>
							<th class="px-4 py-3">Source VM</th>
							<th class="px-4 py-3">Destination VM</th>
							<th class="px-4 py-3">Requested By</th>
							<th class="px-4 py-3">Started</th>
						</tr>
					</thead>
					<tbody class="divide-y divide-slate-700/50">
						{#each activeMigrations as migration (migration.id)}
							<tr class="transition hover:bg-slate-800/40">
								<td class="px-4 py-3 font-medium text-slate-200">{migration.index_name}</td>
								<td class="px-4 py-3">
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											migration.status
										)}"
									>
										{migration.status}
									</span>
								</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">{migration.source_vm_id}</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">{migration.dest_vm_id}</td>
								<td class="px-4 py-3 text-slate-300">{migration.requested_by}</td>
								<td class="px-4 py-3 text-xs text-slate-400"
									>{formatTimestamp(migration.started_at)}</td
								>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>

	<div class="space-y-3">
		<h3 class="text-lg font-medium text-slate-100">Recent Migrations</h3>
		{#if recentMigrations.length === 0}
			<p
				class="rounded-md border border-slate-700 bg-slate-800/40 px-3 py-2 text-sm text-slate-400"
			>
				No recent migrations.
			</p>
		{:else}
			<div
				class="overflow-x-auto rounded-lg border border-slate-700"
				data-testid="recent-migrations-table"
			>
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Index</th>
							<th class="px-4 py-3">Status</th>
							<th class="px-4 py-3">Source VM</th>
							<th class="px-4 py-3">Destination VM</th>
							<th class="px-4 py-3">Completed</th>
							<th class="px-4 py-3">Error</th>
						</tr>
					</thead>
					<tbody class="divide-y divide-slate-700/50">
						{#each recentMigrations as migration (migration.id)}
							<tr class="transition hover:bg-slate-800/40">
								<td class="px-4 py-3 font-medium text-slate-200">{migration.index_name}</td>
								<td class="px-4 py-3">
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											migration.status
										)}"
									>
										{migration.status}
									</span>
								</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">{migration.source_vm_id}</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">{migration.dest_vm_id}</td>
								<td class="px-4 py-3 text-xs text-slate-400"
									>{formatTimestamp(migration.completed_at)}</td
								>
								<td class="px-4 py-3 text-xs text-red-300">{migration.error ?? '—'}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>
</div>
