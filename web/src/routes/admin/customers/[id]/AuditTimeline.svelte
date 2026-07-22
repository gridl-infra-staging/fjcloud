<script lang="ts">
	import type { AdminAuditRow } from '$lib/admin-client';
	import { auditActionLabel, auditMetadataDisplay } from '$lib/audit';
	import { formatRelativeTime } from '$lib/format';

	let { audit } = $props<{ audit: AdminAuditRow[] | null }>();
	const auditRows = $derived(
		(audit ?? []).map((row: AdminAuditRow) => ({
			...row,
			metadataText: auditMetadataDisplay(row.metadata)
		}))
	);
</script>

<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
	<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Audit Timeline</h3>

	{#if audit === null}
		<p class="mt-3 text-sm text-slate-400">Audit timeline unavailable.</p>
	{:else if audit.length === 0}
		<p class="mt-3 text-sm text-slate-400">No audit events recorded for this customer yet.</p>
	{:else}
		<ul class="mt-3 divide-y divide-slate-700/50 rounded-lg border border-slate-700">
			{#each auditRows as row (row.id)}
				<li class="flex flex-col gap-1 px-4 py-3 md:flex-row md:items-center md:justify-between">
					<div class="space-y-1">
						<p class="text-sm font-medium text-slate-100">{auditActionLabel(row.action)}</p>
						<p data-testid="audit-actor" class="font-mono text-xs text-slate-400">
							{row.actor_id}
						</p>
						{#if row.metadataText}
							<p data-testid="audit-metadata" class="font-mono text-xs text-slate-300">
								{row.metadataText}
							</p>
						{/if}
					</div>
					<p data-testid="audit-relative-time" class="text-xs text-slate-400">
						{formatRelativeTime(row.created_at)}
					</p>
				</li>
			{/each}
		</ul>
	{/if}
</div>
