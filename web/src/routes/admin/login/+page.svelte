<script lang="ts">
	import PasswordInput from '$lib/components/PasswordInput.svelte';

	let { form } = $props();
</script>

<svelte:head>
	<title>Admin Login - Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-slate-950 px-4">
	<div
		class="w-full max-w-md rounded-xl border border-violet-900/50 bg-slate-900/90 p-8 shadow-2xl shadow-violet-950/40"
	>
		<h1 class="mb-2 text-2xl font-bold text-white">Admin Login</h1>
		<p class="mb-6 text-sm text-slate-300">Enter the admin key to continue.</p>

		{#if form?.errors?.form}
			<div
				class="mb-4 rounded-md border border-red-700/60 bg-red-950/60 p-3 text-sm text-red-200"
				role="alert"
			>
				{form.errors.form}
			</div>
		{/if}

		<form method="POST" class="space-y-4">
			<PasswordInput
				id="admin_key"
				name="admin_key"
				label="Admin Key"
				required
				autocomplete="current-password"
				revealLabel="admin key"
				error={form?.errors?.admin_key}
				surface="dark"
				inputClass="rounded-md"
			/>

			<button
				type="submit"
				class="w-full rounded-md bg-violet-600 px-4 py-2 text-sm font-semibold text-white hover:bg-violet-500 focus:outline-none"
			>
				Log In
			</button>
		</form>
	</div>
</div>
