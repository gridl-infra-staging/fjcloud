<script lang="ts">
	import { resolve } from '$app/paths';

	let { form } = $props();
</script>

<svelte:head>
	<title>Reset Password — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-gray-50">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-6 text-2xl font-bold text-gray-900">Reset your password</h1>

		{#if form?.success}
			<div class="rounded bg-green-50 p-4 text-sm text-green-700" role="alert">
				Your password has been reset successfully.
			</div>
			<p class="mt-4 text-center">
				<a
					href={resolve('/login')}
					class="inline-block rounded bg-blue-600 px-6 py-2 font-medium text-white hover:bg-blue-700"
				>
					Log in
				</a>
			</p>
		{:else}
			{#if form?.errors?.form}
				<div class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700" role="alert">
					{form.errors.form}
				</div>
			{/if}

			<form method="POST" class="space-y-4">
				<div>
					<label for="password" class="mb-1 block text-sm font-medium text-gray-700">
						New Password
					</label>
					<input
						id="password"
						name="password"
						type="password"
						required
						minlength="8"
						class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					/>
					{#if form?.errors?.password}
						<p class="mt-1 text-sm text-red-600">{form.errors.password}</p>
					{/if}
				</div>

				<div>
					<label for="confirm_password" class="mb-1 block text-sm font-medium text-gray-700">
						Confirm New Password
					</label>
					<input
						id="confirm_password"
						name="confirm_password"
						type="password"
						required
						minlength="8"
						class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					/>
					{#if form?.errors?.confirm_password}
						<p class="mt-1 text-sm text-red-600">{form.errors.confirm_password}</p>
					{/if}
				</div>

				<button
					type="submit"
					class="w-full rounded bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
				>
					Reset Password
				</button>
			</form>
		{/if}
	</div>
</div>
