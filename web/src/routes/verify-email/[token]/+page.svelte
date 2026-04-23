<script lang="ts">

	import { resolve } from '$app/paths';

	let { data } = $props();
</script>

<svelte:head>
	<title>Verify Email — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-gray-50">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow text-center">
		{#if data.success}
			<div class="mb-4 text-green-600">
				<svg class="mx-auto h-12 w-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
					<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
				</svg>
			</div>
			<h1 class="mb-2 text-2xl font-bold text-gray-900">Email Verified</h1>
			<p class="mb-6 text-gray-600">{data.message}</p>
			<a
				href={resolve("/login")}
				class="inline-block rounded bg-blue-600 px-6 py-2 font-medium text-white hover:bg-blue-700"
			>
				Go to Login
			</a>
		{:else}
			<div class="mb-4 text-red-600">
				<svg class="mx-auto h-12 w-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
					<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
				</svg>
			</div>
			<h1 class="mb-2 text-2xl font-bold text-gray-900">Verification Failed</h1>
			<p class="mb-6 text-gray-600">{data.message}</p>
			<a
				href={resolve("/login")}
				class="inline-block rounded bg-blue-600 px-6 py-2 font-medium text-white hover:bg-blue-700"
			>
				Go to Login
			</a>
		{/if}
	</div>
</div>
