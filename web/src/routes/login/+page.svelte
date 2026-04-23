<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';

	let { form } = $props();
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

<div class="flex min-h-screen items-center justify-center bg-gray-50">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-6 text-2xl font-bold text-gray-900">Log in to Flapjack Cloud</h1>

		{#if showSessionExpiredBanner}
			<div
				class="mb-4 rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"
				data-testid="session-expired-banner"
			>
				Your session expired. Please log in again.
			</div>
		{/if}

		{#if form?.errors?.form}
			<div class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700" role="alert">
				{form.errors.form}
			</div>
		{/if}

		<form method="POST" class="space-y-4">
			<div>
				<label for="email" class="mb-1 block text-sm font-medium text-gray-700">Email</label>
				<input
					id="email"
					name="email"
					type="email"
					bind:value={email}
					required
					class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				{#if form?.errors?.email}
					<p class="mt-1 text-sm text-red-600">{form.errors.email}</p>
				{/if}
			</div>

			<div>
				<label for="password" class="mb-1 block text-sm font-medium text-gray-700">
					Password
				</label>
				<input
					id="password"
					name="password"
					type="password"
					required
					class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				{#if form?.errors?.password}
					<p class="mt-1 text-sm text-red-600">{form.errors.password}</p>
				{/if}
			</div>

			<button
				type="submit"
				class="w-full rounded bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
			>
				Log In
			</button>
		</form>

		<div class="mt-4 space-y-2 text-center text-sm text-gray-600">
			<p>
				<a href={resolve('/forgot-password')} class="font-medium text-blue-600 hover:text-blue-500">
					Forgot your password?
				</a>
			</p>
			<p>
				Don't have an account?
				<a href={resolve('/signup')} class="font-medium text-blue-600 hover:text-blue-500"
					>Sign up</a
				>
			</p>
		</div>
	</div>
</div>
