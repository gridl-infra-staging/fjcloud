<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import OAuthButtons from '$lib/components/OAuthButtons.svelte';
	import PasswordInput from '$lib/components/PasswordInput.svelte';

	let {
		form,
		data
	}: { form?: { errors?: Record<string, string>; email?: string }; data: { apiBaseUrl: string } } =
		$props();
	const showSessionExpiredBanner = $derived(
		page.url.searchParams.get('reason') === 'session_expired'
	);

	// Local state so Playwright's fill() isn't clobbered by Svelte's controlled-input
	// reconciliation on blur.  $effect re-syncs if the server action returns a value.
	let email = $state('');
	$effect(() => {
		if (form?.email !== undefined) email = form.email ?? '';
	});
</script>

<svelte:head>
	<title>Log In — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-flapjack-mint text-flapjack-ink">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-6 text-2xl font-bold text-flapjack-ink">Log in to Flapjack Cloud</h1>

		{#if showSessionExpiredBanner}
			<div
				class="mb-4 rounded border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3 text-sm text-flapjack-ink/80"
				data-testid="session-expired-banner"
			>
				Your session expired. Please log in again.
			</div>
		{/if}

		{#if form?.errors?.form}
			<div class="mb-4 rounded bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum" role="alert">
				{form.errors.form}
			</div>
		{/if}

		<form method="POST" class="space-y-4">
			<div>
				<label for="email" class="mb-1 block text-sm font-medium text-flapjack-ink/80">Email</label>
				<input
					id="email"
					name="email"
					type="email"
					bind:value={email}
					required
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
				{#if form?.errors?.email}
					<p class="mt-1 text-sm text-flapjack-plum">{form.errors.email}</p>
				{/if}
			</div>

			<PasswordInput
				id="password"
				name="password"
				label="Password"
				required
				autocomplete="current-password"
				data-testid="login-password"
				error={form?.errors?.password}
			/>

			<button
				type="submit"
				class="w-full rounded bg-flapjack-rose px-4 py-2 font-medium text-white hover:bg-flapjack-plum focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-flapjack-cream"
			>
				Log In
			</button>
		</form>

		<div class="my-6 flex items-center">
			<div class="h-px flex-1 bg-flapjack-cream/60"></div>
			<span class="px-3 text-xs font-medium uppercase tracking-wide text-flapjack-ink/60">Or</span>
			<div class="h-px flex-1 bg-flapjack-cream/60"></div>
		</div>

		<OAuthButtons apiBaseUrl={data.apiBaseUrl} />

		<div class="mt-4 text-center text-sm text-flapjack-ink/70">
			<p>
				<a
					href={resolve('/forgot-password')}
					class="font-medium text-flapjack-rose hover:text-flapjack-plum"
				>
					Forgot your password?
				</a>
			</p>
			<!-- Signup discovery is withdrawn; see decisions/2026-05-23_beta_signup_gate.md. -->
		</div>
	</div>
</div>
