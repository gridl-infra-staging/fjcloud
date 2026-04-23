<script lang="ts">
	import { resolve } from '$app/paths';

	let { form } = $props();
</script>

<svelte:head>
	<title>Forgot Password — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-gray-50">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-2 text-2xl font-bold text-gray-900">Forgot your password?</h1>
		<p class="mb-6 text-sm text-gray-600">
			Enter your email and we'll send you a link to reset it.
		</p>

		{#if form?.sent}
			<div class="rounded bg-green-50 p-4 text-sm text-green-700" role="alert">
				If an account exists with that email, you'll receive a password reset link shortly.
			</div>
			<p class="mt-4 text-center text-sm text-gray-600">
				<a href={resolve("/login")} class="font-medium text-blue-600 hover:text-blue-500">
					Back to login
				</a>
			</p>
		{:else}
			<form method="POST" class="space-y-4">
				<div>
					<label for="email" class="mb-1 block text-sm font-medium text-gray-700">Email</label>
					<input
						id="email"
						name="email"
						type="email"
						value={form?.email ?? ''}
						required
						class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					/>
					{#if form?.errors?.email}
						<p class="mt-1 text-sm text-red-600">{form.errors.email}</p>
					{/if}
				</div>

				<button
					type="submit"
					class="w-full rounded bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
				>
					Send Reset Link
				</button>
			</form>

			<p class="mt-4 text-center text-sm text-gray-600">
				<a href={resolve("/login")} class="font-medium text-blue-600 hover:text-blue-500">
					Back to login
				</a>
			</p>
		{/if}
	</div>
</div>
