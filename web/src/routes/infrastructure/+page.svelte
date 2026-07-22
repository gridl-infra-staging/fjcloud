<script lang="ts">
	import { resolve } from '$app/paths';
	import { formatNumber } from '$lib/format';
	import {
		healthBadgeFor,
		parseInfrastructureHealth,
		parseInfrastructureUtilization,
		utilizationBadgeFor,
		type InfrastructureRouteData
	} from './infrastructure_contract';

	let { data }: { data: InfrastructureRouteData } = $props();
</script>

<svelte:head>
	<title>Infrastructure - Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-flapjack-ink/20 bg-white">
	<div class="mx-auto flex h-16 max-w-6xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-flapjack-ink">Flapjack Cloud</a>
		<nav class="flex items-center gap-4" aria-label="Public navigation">
			<a
				href={resolve('/login')}
				class="text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink">Log In</a
			>
		</nav>
	</div>
</header>

<main class="mx-auto max-w-6xl px-6 py-12" data-testid="public-infrastructure-main">
	<h1 class="text-3xl font-bold text-flapjack-ink">Infrastructure</h1>
	<p class="mt-3 max-w-3xl text-sm text-flapjack-ink/70">
		Current regional health and coarse utilization across Flapjack Cloud.
	</p>

	{#if data.status === 'error'}
		<div
			role="alert"
			class="mt-8 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-5 text-flapjack-plum"
		>
			{data.message}
		</div>
	{:else}
		<section class="mt-8 grid gap-4 sm:grid-cols-3" aria-label="Infrastructure summary">
			<div class="rounded-lg border border-flapjack-ink/20 bg-white p-5">
				{#if data.infrastructure.overall.total_vms === 0 || data.infrastructure.overall.availability_pct === null}
					<p data-testid="infrastructure-availability" class="text-xl font-semibold text-flapjack-ink">
						Availability unavailable
					</p>
				{:else}
					<p data-testid="infrastructure-availability" class="text-3xl font-bold text-flapjack-ink">
						Availability {formatNumber(data.infrastructure.overall.availability_pct)}%
					</p>
				{/if}
			</div>
			<div class="rounded-lg border border-flapjack-ink/20 bg-white p-5">
				<p class="text-sm text-flapjack-ink/60">Regions</p>
				<p class="mt-1 text-3xl font-bold text-flapjack-ink">
					{formatNumber(data.infrastructure.overall.total_regions)}
				</p>
			</div>
			<div class="rounded-lg border border-flapjack-ink/20 bg-white p-5">
				<p class="text-sm text-flapjack-ink/60">VMs</p>
				<p class="mt-1 text-3xl font-bold text-flapjack-ink">
					{formatNumber(data.infrastructure.overall.total_vms)}
				</p>
			</div>
		</section>

		<section class="mt-10" aria-labelledby="infrastructure-regions-heading">
			<h2 id="infrastructure-regions-heading" class="text-xl font-semibold text-flapjack-ink">
				Regions
			</h2>

			{#if data.infrastructure.regions.length === 0}
				<p class="mt-4 rounded-lg border border-flapjack-ink/20 bg-white p-5 text-flapjack-ink/70">
					No region data is currently available.
				</p>
			{:else}
				<div class="mt-4 overflow-x-auto rounded-lg border border-flapjack-ink/20 bg-white">
					<table class="w-full border-collapse text-left text-sm" aria-label="Infrastructure regions">
						<thead class="bg-flapjack-ink/5 text-flapjack-ink/70">
							<tr>
								<th scope="col" class="px-4 py-3 font-medium">Region ID</th>
								<th scope="col" class="px-4 py-3 font-medium">Provider</th>
								<th scope="col" class="px-4 py-3 font-medium">Display name</th>
								<th scope="col" class="px-4 py-3 font-medium">Provider location</th>
								<th scope="col" class="px-4 py-3 font-medium">Health</th>
								<th scope="col" class="px-4 py-3 font-medium">Utilization</th>
								<th scope="col" class="px-4 py-3 text-right font-medium">VMs</th>
							</tr>
						</thead>
						<tbody class="divide-y divide-flapjack-ink/10">
							{#each data.infrastructure.regions as region (region.region)}
								{@const health = healthBadgeFor(parseInfrastructureHealth(region.health))}
								{@const utilization = utilizationBadgeFor(
									parseInfrastructureUtilization(region.utilization)
								)}
								<tr data-testid={`infrastructure-region-row-${region.region}`}>
									<th scope="row" class="whitespace-nowrap px-4 py-4 font-medium text-flapjack-ink">
										{region.region}
									</th>
									<td class="whitespace-nowrap px-4 py-4 text-flapjack-ink/80">{region.provider}</td>
									<td class="whitespace-nowrap px-4 py-4 text-flapjack-ink/80">{region.display_name}</td>
									<td class="whitespace-nowrap px-4 py-4 text-flapjack-ink/80">
										{region.provider_location}
									</td>
									<td class="px-4 py-4">
										<span
											data-testid={`infrastructure-health-${region.region}`}
											class={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ${health.badgeClass}`}
										>
											{health.label}
										</span>
									</td>
									<td class="px-4 py-4">
										<span
											data-testid={`infrastructure-utilization-${region.region}`}
											class={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ${utilization.badgeClass}`}
										>
											{utilization.label}
										</span>
									</td>
									<td class="px-4 py-4 text-right text-flapjack-ink/80">
										{formatNumber(region.vm_count)}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</section>
	{/if}
</main>
