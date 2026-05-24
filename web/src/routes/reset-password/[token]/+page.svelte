<script lang="ts">
	import { resolve } from '$app/paths';
	import { enhance } from '$app/forms';

	let { form } = $props();
	const errors = $derived(
		(form?.errors ?? {}) as {
			form?: string;
			password?: string;
			confirm_password?: string;
		}
	);

	function recoveryAction(formData: unknown): string | null {
		if (!formData || typeof formData !== 'object') {
			return null;
		}

		const action = 'recoveryAction' in formData ? (formData.recoveryAction as unknown) : null;
		return typeof action === 'string' ? action : null;
	}

	const showRequestNewEmailCta = $derived(recoveryAction(form) === 'invalid_or_expired_token');
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
			{#if errors.form}
				<div
					class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700"
					role="alert"
					data-testid="reset-password-form-error"
				>
					{errors.form}
				</div>
				{#if showRequestNewEmailCta}
					<p class="mb-4 text-sm text-gray-700">
						<a
							href={resolve('/forgot-password')}
							class="font-medium text-blue-600 hover:text-blue-500"
							data-testid="reset-password-request-new-email"
						>
							Request another reset email
						</a>
					</p>
				{/if}
			{/if}

			<form method="POST" use:enhance class="space-y-4">
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
					{#if errors.password}
						<p class="mt-1 text-sm text-red-600">{errors.password}</p>
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
					{#if errors.confirm_password}
						<p class="mt-1 text-sm text-red-600">{errors.confirm_password}</p>
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
