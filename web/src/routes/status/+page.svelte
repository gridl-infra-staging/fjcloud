<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
	import { onMount } from 'svelte';
	import {
		parseRuntimeStatusPayload,
		resolveStatusRuntimeEnvironment,
		statusLabelForServiceStatus,
		type ServiceStatus,
		type StatusRouteData
	} from './status_contract';

	let { data }: { data: StatusRouteData } = $props();
	let status = $state<ServiceStatus>('operational');
	let statusLabel = $state('All Systems Operational');
	let lastUpdated = $state(new Date().toISOString());
	let message = $state<string | undefined>(undefined);

	const statusColors: Record<
		ServiceStatus,
		{ bg: string; border: string; text: string; dot: string }
	> = {
		operational: {
			bg: 'bg-green-50',
			border: 'border-green-200',
			text: 'text-green-800',
			dot: 'bg-green-500'
		},
		degraded: {
			bg: 'bg-amber-50',
			border: 'border-amber-200',
			text: 'text-amber-800',
			dot: 'bg-amber-500'
		},
		outage: {
			bg: 'bg-red-50',
			border: 'border-red-200',
			text: 'text-red-800',
			dot: 'bg-red-500'
		}
	};

	const colors = $derived(statusColors[status] ?? statusColors.operational);

	function formatTimestamp(iso: string): string {
		return new Date(iso).toLocaleString();
	}

	$effect(() => {
		status = data.status;
		statusLabel = data.statusLabel;
		lastUpdated = data.lastUpdated;
		message = data.message;
	});

	onMount(async () => {
		const runtimeEnvironment = resolveStatusRuntimeEnvironment(window.location.hostname);
		if (!runtimeEnvironment) {
			return;
		}

		try {
			const response = await fetch(
				`https://fjcloud-releases-${runtimeEnvironment}.s3.amazonaws.com/service_status.json`
			);
			if (!response.ok) {
				return;
			}

			const payload = parseRuntimeStatusPayload(await response.json());
			if (!payload) {
				return;
			}

			status = payload.status;
			statusLabel = statusLabelForServiceStatus(payload.status);
			lastUpdated = payload.lastUpdated;
			message = payload.message;
		} catch {
			// Keep prerendered fallback when runtime fetch/JSON parsing fails.
		}
	});
</script>

<svelte:head>
	<title>Service Status - Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-gray-200 bg-white">
	<div class="mx-auto flex h-16 max-w-3xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-gray-900">Flapjack Cloud</a>
		<nav class="flex items-center gap-4">
			<a href={resolve('/login')} class="text-sm font-medium text-gray-600 hover:text-gray-900"
				>Log In</a
			>
			<a
				href={resolve('/signup')}
				class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Sign Up
			</a>
		</nav>
	</div>
</header>

<main class="mx-auto max-w-3xl px-6 py-12">
	<h1 class="text-2xl font-bold text-gray-900">Service Status</h1>

	<div
		data-testid="status-badge"
		class={`mt-6 flex items-center gap-3 rounded-lg border p-5 ${colors.bg} ${colors.border}`}
	>
		<span class={`h-3 w-3 rounded-full ${colors.dot}`}></span>
		<span class={`text-lg font-semibold ${colors.text}`}>{statusLabel}</span>
	</div>

	<p data-testid="status-last-updated" class="mt-4 text-sm text-gray-500">
		Last updated: {formatTimestamp(lastUpdated)}
	</p>
	{#if message}
		<p data-testid="status-incident-message" class="mt-2 text-sm text-gray-700">{message}</p>
	{/if}

	<div class="mt-10 rounded-lg border border-gray-200 bg-white p-6">
		<h2 class="text-lg font-semibold text-gray-900">About this page</h2>
		<p class="mt-2 text-sm text-gray-600">
			This page reflects the current operational status of Flapjack Cloud services. During
			incidents, this page is updated with the latest information.
		</p>
		<p class="mt-3 text-sm text-gray-600">
			Flapjack Cloud operations owns incident updates for this page. Public beta support targets a
			response within 48 business hours.
		</p>
		<p class="mt-4">
			<!-- There is no incident-history route yet; link to beta scope so
					customers can see the currently promised support/status contract. -->
			<a href={resolve('/beta')} class="text-sm font-medium text-blue-600 hover:text-blue-800">
				View beta scope
			</a>
			<span class="mx-2 text-gray-300">|</span>
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto: scheme, not an internal path -->
			<a href={BETA_FEEDBACK_MAILTO} class="text-sm font-medium text-blue-600 hover:text-blue-800">
				Email support
			</a>
		</p>
	</div>
</main>
