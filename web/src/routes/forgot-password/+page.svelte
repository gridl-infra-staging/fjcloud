<script lang="ts">
	import { resolve } from '$app/paths';
	import { enhance } from '$app/forms';

	let { form } = $props();

	function cooldownRetryAfterSeconds(formData: unknown): number | null {
		if (!formData || typeof formData !== 'object') {
			return null;
		}

		const retryAfterSeconds =
			'retryAfterSeconds' in formData ? (formData.retryAfterSeconds as unknown) : null;
		return typeof retryAfterSeconds === 'number' ? retryAfterSeconds : null;
	}

	const retryAfterSeconds = $derived(cooldownRetryAfterSeconds(form));
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
			<div
				class="rounded bg-green-50 p-4 text-sm text-green-700"
				role="alert"
				data-testid="forgot-password-success-message"
			>
				If an account exists with that email, you'll receive a password reset link shortly.
			</div>

			{#if form?.resendStatus === 'delivery_failure'}
				<div
					class="mt-4 rounded bg-red-50 p-4 text-sm text-red-700"
					role="alert"
					data-testid="forgot-password-resend-delivery-failure-message"
				>
					We could not send a new reset email right now. Please try again shortly.
				</div>
			{/if}

			{#if form?.resendStatus === 'cooldown'}
				<div
					class="mt-4 rounded bg-yellow-50 p-4 text-sm text-yellow-800"
					role="alert"
					data-testid="forgot-password-resend-cooldown-message"
				>
					{#if retryAfterSeconds !== null}
						Please wait {retryAfterSeconds} seconds before requesting another reset link.
					{:else}
						Please wait before requesting another reset link.
					{/if}
				</div>
			{/if}

			<form method="POST" use:enhance class="mt-4" data-testid="forgot-password-resend-form">
				<input type="hidden" name="intent" value="resend" />
				<input type="hidden" name="email" value={form?.email ?? ''} />
				<button
					type="submit"
					class="w-full rounded border border-blue-600 bg-white px-4 py-2 font-medium text-blue-700 hover:bg-blue-50 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
					data-testid="forgot-password-resend-button"
				>
					Resend Reset Link
				</button>
			</form>

			<p class="mt-4 text-center text-sm text-gray-600">
				<a href={resolve('/login')} class="font-medium text-blue-600 hover:text-blue-500">
					Back to login
				</a>
			</p>
		{:else}
			<form method="POST" use:enhance class="space-y-4">
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
				<a href={resolve('/login')} class="font-medium text-blue-600 hover:text-blue-500">
					Back to login
				</a>
			</p>
		{/if}
	</div>
</div>
