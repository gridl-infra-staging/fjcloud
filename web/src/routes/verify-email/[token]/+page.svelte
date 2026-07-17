<script lang="ts">
	import { resolve } from '$app/paths';
	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';

	let { data } = $props();
</script>

<svelte:head>
	<title>Verify Email — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-flapjack-cream/80">
	<div
		class="w-full max-w-md rounded-lg bg-white p-8 text-center shadow"
		data-testid="verify-result"
		data-success={data.success ? 'true' : 'false'}
	>
		{#if data.success}
			<div class="mb-4 text-flapjack-fern">
				<svg class="mx-auto h-12 w-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
					<path
						stroke-linecap="round"
						stroke-linejoin="round"
						stroke-width="2"
						d="M5 13l4 4L19 7"
					/>
				</svg>
			</div>
			<h1 class="mb-2 text-2xl font-bold text-flapjack-ink">Email verified</h1>
			<p class="text-flapjack-ink/70">{data.message}</p>
			<p class="mb-6 mt-2 text-flapjack-ink/70">You can now log in to Flapjack Cloud.</p>
			<a
				href={resolve('/login')}
				class="inline-block rounded bg-flapjack-rose px-6 py-2 font-medium text-white hover:bg-flapjack-plum focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-flapjack-cream"
			>
				Log in to continue
			</a>
		{:else}
			<div class="mb-4 text-flapjack-plum">
				<svg class="mx-auto h-12 w-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
					<path
						stroke-linecap="round"
						stroke-linejoin="round"
						stroke-width="2"
						d="M6 18L18 6M6 6l12 12"
					/>
				</svg>
			</div>
			<h1 class="mb-2 text-2xl font-bold text-flapjack-ink">We could not verify your email</h1>
			<p class="text-flapjack-ink/70">{data.message}</p>
			<p class="mb-6 mt-2 text-flapjack-ink/70">
				The link may be expired or already used. Log in to request a fresh verification email.
			</p>
			<a
				href={resolve('/login')}
				class="inline-block rounded bg-flapjack-rose px-6 py-2 font-medium text-white hover:bg-flapjack-plum focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-flapjack-cream"
			>
				Log in to continue
			</a>
			<p class="mt-4 text-sm text-flapjack-ink/70">
				If the problem persists, contact
				<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
				<a
					href={LEGAL_SUPPORT_MAILTO}
					class="font-medium text-flapjack-rose hover:text-flapjack-plum"
				>
					{SUPPORT_EMAIL}
				</a>.
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			</p>
		{/if}
	</div>
</div>
