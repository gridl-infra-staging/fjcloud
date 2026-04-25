<script lang="ts">
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
			<div>
				<label for="admin_key" class="mb-1 block text-sm font-medium text-slate-200"
					>Admin Key</label
				>
				<input
					id="admin_key"
					name="admin_key"
					type="password"
					required
					autocomplete="current-password"
					class="w-full rounded-md border border-slate-700 bg-slate-950 px-3 py-2 text-slate-100 focus:border-violet-400 focus:outline-none"
				/>
				{#if form?.errors?.admin_key}
					<p class="mt-1 text-sm text-red-300">{form.errors.admin_key}</p>
				{/if}
			</div>

			<button
				type="submit"
				class="w-full rounded-md bg-violet-600 px-4 py-2 text-sm font-semibold text-white hover:bg-violet-500 focus:outline-none"
			>
				Log In
			</button>
		</form>
	</div>
</div>
