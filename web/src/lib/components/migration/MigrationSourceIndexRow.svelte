<script lang="ts">
	import { formatBytes, formatDate, formatNumber } from '$lib/format';
	import type { AlgoliaIndexMetadata } from '$lib/api/types';

	let {
		source,
		selected,
		onSelect
	}: {
		source: AlgoliaIndexMetadata;
		selected: boolean;
		onSelect: (name: string) => void;
	} = $props();

	const replica = $derived(source.primary !== null);
	const role = $derived(source.primary === null ? 'Primary' : `Replica of ${source.primary}`);
</script>

<li
	data-testid={`migration-source-row-${source.name}`}
	class="rounded border border-flapjack-ink/20 p-3"
>
	<label class="flex items-start gap-3">
		<input
			type="radio"
			name="migration-source"
			value={source.name}
			disabled={replica}
			checked={selected}
			onchange={() => {
				if (!replica) onSelect(source.name);
			}}
			class="mt-1"
		/>
		<span class="space-y-1">
			<span class="block text-sm font-medium text-flapjack-ink">{source.name}</span>
			<span class="block text-xs text-flapjack-ink/70">
				{formatNumber(source.entries)} records · {formatBytes(source.dataSize)} · Updated {formatDate(
					source.updatedAt
				)}
				{#if source.lastBuildTimeS > 0}
					· Last build {source.lastBuildTimeS}s
				{/if}
				· {role}
			</span>
			{#if replica}
				<span class="block text-xs text-flapjack-ink/70">
					The primary index is imported, replica indices are not copied, and alternate sort orders
					built on replicas do not carry over.
				</span>
			{/if}
		</span>
	</label>
</li>
