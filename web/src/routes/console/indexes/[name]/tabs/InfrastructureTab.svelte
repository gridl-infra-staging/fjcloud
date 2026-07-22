<script lang="ts">
	import { invalidate } from '$app/navigation';
	import type {
		HeadroomStatus,
		IndexInfrastructureResponse,
		UtilizationBucket
	} from '$lib/api/types';
	import { formatBytes, formatNumber, statusLabel } from '$lib/format';
	import { infrastructureDependencyKey } from '../infrastructure-keys';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';

	type InfrastructureError = {
		code: number;
		message: string;
	};

	type Props = {
		infrastructure: IndexInfrastructureResponse | null;
		error: InfrastructureError | null;
		indexName: string;
	};

	let { infrastructure, error, indexName }: Props = $props();
	let refreshInFlight = $state(false);
	let refreshPending = $state(false);
	let cooldownUntil = $state<number | null>(null);
	let currentTime = $state(Date.now());
	let lastObservedInfrastructure: IndexInfrastructureResponse | null = null;
	let lastObservedError: InfrastructureError | null = null;

	const headroomLabels: Record<HeadroomStatus, string> = {
		comfortable: 'Comfortable',
		busy: 'Busy',
		approaching_limits: 'Approaching limits'
	};

	const activeReplicaRegions = $derived(
		infrastructure?.replicas
			.filter((replica) => replica.status === 'active')
			.map((replica) => replica.region) ?? []
	);
	const cooldownActive = $derived(cooldownUntil !== null && currentTime < cooldownUntil);
	const refreshDisabled = $derived(
		refreshInFlight || refreshPending || cooldownActive || (infrastructure === null && error === null)
	);

	$effect(() => {
		const observedInfrastructure = infrastructure;
		const observedError = error;
		const infrastructureChanged = observedInfrastructure !== lastObservedInfrastructure;
		const errorChanged = observedError !== lastObservedError;
		if (!infrastructureChanged && !errorChanged) return;

		lastObservedInfrastructure = observedInfrastructure;
		lastObservedError = observedError;
		if (observedInfrastructure !== null) {
			currentTime = Date.now();
			cooldownUntil = currentTime + observedInfrastructure.minimum_refresh_interval_seconds * 1_000;
		}
		refreshPending = false;
	});

	$effect(() => {
		const boundary = cooldownUntil;
		if (boundary === null) return;

		const remainingMilliseconds = Math.max(0, boundary - Date.now());
		if (remainingMilliseconds === 0) {
			currentTime = Date.now();
			return;
		}

		const timer = setTimeout(() => {
			currentTime = Date.now();
		}, remainingMilliseconds);
		return () => clearTimeout(timer);
	});

	function utilizationLabel(utilization: UtilizationBucket | null): string {
		return utilization === null ? 'Updating...' : statusLabel(utilization);
	}

	function utilizationBadgeClasses(utilization: UtilizationBucket | null): string {
		switch (utilization) {
			case 'green':
				return 'bg-green-100 text-green-800';
			case 'yellow':
				return 'bg-yellow-100 text-yellow-800';
			case 'red':
				return 'bg-red-100 text-red-800';
			default:
				return 'bg-gray-100 text-gray-700';
		}
	}

	async function refreshInfrastructure(): Promise<void> {
		if (refreshDisabled) return;

		refreshInFlight = true;
		refreshPending = true;
		try {
			await invalidate(infrastructureDependencyKey(indexName));
		} catch {
			refreshPending = false;
		} finally {
			refreshInFlight = false;
		}
	}
</script>

<section class="space-y-4" data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.infrastructure}>
	<div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
		<div class="space-y-2">
			<h2 class="text-lg font-medium text-flapjack-ink">Infrastructure</h2>
			<p class="max-w-3xl text-sm text-flapjack-ink/70">
				This read-only and informational view shows customer-safe hosting details. Placement is
				automatically managed.
			</p>
		</div>
		<div class="flex flex-col items-start gap-1 sm:items-end">
			<button
				type="button"
				class="rounded-md border border-flapjack-ink/25 px-3 py-1.5 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream/70 disabled:cursor-not-allowed disabled:opacity-50"
				data-testid="infrastructure-refresh-btn"
				disabled={refreshDisabled}
				onclick={() => {
					void refreshInfrastructure();
				}}
			>
				{refreshInFlight ? 'Refreshing...' : 'Refresh'}
			</button>
			{#if cooldownActive}
				<p class="text-xs text-flapjack-ink/60">Refresh available after the safety interval.</p>
			{/if}
		</div>
	</div>

	{#if error}
		<div class="rounded-md border border-flapjack-rose/30 bg-flapjack-rose/10 p-4" role="alert">
			<p class="font-medium text-flapjack-ink">Infrastructure unavailable</p>
			<p class="mt-1 text-sm text-flapjack-ink/80">
				{error.message} (HTTP {error.code}). Retry to fetch a fresh infrastructure snapshot.
			</p>
		</div>
	{:else if infrastructure}
		<div class="rounded-lg border border-flapjack-ink/10 bg-white/90 p-4 shadow-sm">
			<h3 class="font-medium text-flapjack-ink">Where your index lives</h3>
			<div class="mt-3 space-y-2">
				<div
					class="grid min-w-0 grid-cols-1 gap-2 rounded-md bg-flapjack-cream/50 p-3 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-center"
					data-testid="infrastructure-primary-row"
				>
					<p class="min-w-0 break-words font-medium text-flapjack-ink">
						Primary · {infrastructure.primary.region}
					</p>
					<p class="text-sm text-flapjack-ink/75">{statusLabel(infrastructure.primary.status)}</p>
					<span
						class="w-fit rounded-full px-2.5 py-1 text-xs font-medium {utilizationBadgeClasses(
							infrastructure.primary.utilization
						)}"
					>
						{utilizationLabel(infrastructure.primary.utilization)}
					</span>
				</div>

				{#each infrastructure.replicas as replica (replica.region)}
					<div
						class="grid min-w-0 grid-cols-1 gap-2 rounded-md border border-flapjack-ink/10 p-3 sm:grid-cols-[minmax(0,1fr)_auto_auto_auto] sm:items-center"
						data-testid="infrastructure-replica-row"
					>
						<p class="min-w-0 break-words font-medium text-flapjack-ink">
							Replica · {replica.region}
						</p>
						<p class="text-sm text-flapjack-ink/75">{statusLabel(replica.status)}</p>
						<p class="text-sm text-flapjack-ink/75">
							{formatNumber(replica.lag_ops)} operations behind
						</p>
						<span
							class="w-fit rounded-full px-2.5 py-1 text-xs font-medium {utilizationBadgeClasses(
								replica.utilization
							)}"
						>
							{utilizationLabel(replica.utilization)}
						</span>
					</div>
				{/each}

				{#if infrastructure.replicas.length === 0}
					<p
						class="rounded-md border border-dashed border-flapjack-ink/20 p-3 text-sm text-flapjack-ink/70"
					>
						No replicas are configured.
					</p>
				{/if}
			</div>
		</div>

		<div class="rounded-lg border border-flapjack-ink/10 bg-white/90 p-4 shadow-sm">
			<h3 class="font-medium text-flapjack-ink">Capacity and headroom</h3>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				Utilization is intentionally shown only as broad customer-safe buckets.
			</p>
			<p class="mt-3 text-sm font-medium text-flapjack-ink" data-testid="infrastructure-headroom">
				Headroom: {headroomLabels[infrastructure.headroom]}
			</p>
			<p class="mt-2 text-sm text-flapjack-ink/75" data-testid="infrastructure-failover">
				{#if activeReplicaRegions.length > 0}
					Automatic cross-region failover is available in {activeReplicaRegions.join(', ')}.
				{:else}
					Automatic cross-region failover is not currently available.
				{/if}
			</p>
		</div>

		<div class="rounded-lg border border-flapjack-ink/10 bg-white/90 p-4 shadow-sm">
			<h3 class="font-medium text-flapjack-ink">Your index's resource footprint</h3>
			<div class="mt-3 grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
				<div
					class="min-w-0 rounded-md bg-flapjack-cream/50 p-3"
					data-testid="infrastructure-footprint-documents"
				>
					<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Documents</p>
					<p class="mt-1 break-words text-xl font-semibold text-flapjack-ink">
						{formatNumber(infrastructure.footprint.documents_count)}
					</p>
				</div>
				<div
					class="min-w-0 rounded-md bg-flapjack-cream/50 p-3"
					data-testid="infrastructure-footprint-storage"
				>
					<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Storage</p>
					<p class="mt-1 break-words text-xl font-semibold text-flapjack-ink">
						{formatBytes(infrastructure.footprint.storage_bytes)}
					</p>
				</div>
				<div
					class="min-w-0 rounded-md bg-flapjack-cream/50 p-3"
					data-testid="infrastructure-footprint-search-requests"
				>
					<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Search requests</p>
					<p class="mt-1 break-words text-xl font-semibold text-flapjack-ink">
						{formatNumber(infrastructure.footprint.search_requests_total)}
					</p>
				</div>
				<div
					class="min-w-0 rounded-md bg-flapjack-cream/50 p-3"
					data-testid="infrastructure-footprint-write-operations"
				>
					<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Write operations</p>
					<p class="mt-1 break-words text-xl font-semibold text-flapjack-ink">
						{formatNumber(infrastructure.footprint.write_operations_total)}
					</p>
				</div>
			</div>
		</div>
	{:else}
		<div
			class="rounded-md border border-dashed border-flapjack-ink/20 bg-flapjack-cream/40 p-4 text-sm text-flapjack-ink/75"
		>
			Infrastructure data is loading.
		</div>
	{/if}
</section>
