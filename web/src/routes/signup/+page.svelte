<script lang="ts">
	import { resolve } from '$app/paths';
	import { MARKETING_PRICING } from '$lib/pricing';
	import { SIGNUP_PASSWORD_MIN_LENGTH, clientSignupPasswordLengthError } from './signup-validation';

	type SignupFieldError =
		| 'form'
		| 'name'
		| 'email'
		| 'password'
		| 'confirm_password'
		| 'beta_acknowledgement';
	type SignupFormState = {
		errors?: Partial<Record<SignupFieldError, string>>;
		name?: string;
		email?: string;
	};

	let { form }: { form?: SignupFormState } = $props();

	// Local state so Playwright's fill() isn't clobbered by Svelte's controlled-input
	// reconciliation on blur.  $effect re-syncs if the server action returns a value.
	let name = $state('');
	let email = $state('');
	let password = $state('');
	$effect(() => {
		if (form?.name !== undefined) name = form.name ?? '';
		if (form?.email !== undefined) email = form.email ?? '';
	});

	const passwordErrorMessage = $derived.by(() => {
		if (password.length > 0) {
			return clientSignupPasswordLengthError(password);
		}

		return form?.errors?.password ?? null;
	});
</script>

<svelte:head>
	<title>Sign Up — Flapjack Cloud</title>
</svelte:head>

<div class="flex min-h-screen items-center justify-center bg-gray-50">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-6 text-2xl font-bold text-gray-900">Create your account</h1>
		<p class="mb-6 text-sm text-gray-600">{MARKETING_PRICING.free_tier_promise}</p>

		{#if form?.errors?.form}
			<div class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700" role="alert">
				{form.errors.form}
			</div>
		{/if}

		<form method="POST" class="space-y-4">
			<div>
				<label for="name" class="mb-1 block text-sm font-medium text-gray-700">Name</label>
				<input
					id="name"
					name="name"
					type="text"
					bind:value={name}
					required
					class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				{#if form?.errors?.name}
					<p class="mt-1 text-sm text-red-600">{form.errors.name}</p>
				{/if}
			</div>

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
					bind:value={password}
					required
					minlength={SIGNUP_PASSWORD_MIN_LENGTH}
					class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				{#if passwordErrorMessage}
					<p class="mt-1 text-sm text-red-600">{passwordErrorMessage}</p>
				{/if}
			</div>

			<div>
				<label for="confirm_password" class="mb-1 block text-sm font-medium text-gray-700">
					Confirm Password
				</label>
				<input
					id="confirm_password"
					name="confirm_password"
					type="password"
					required
					minlength={SIGNUP_PASSWORD_MIN_LENGTH}
					class="w-full rounded border border-gray-300 px-3 py-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				{#if form?.errors?.confirm_password}
					<p class="mt-1 text-sm text-red-600" role="alert">{form.errors.confirm_password}</p>
				{/if}
			</div>

			<div class="rounded-lg border border-blue-100 bg-blue-50 p-3">
				<div class="flex items-start gap-3">
					<input
						id="beta_acknowledged"
						name="beta_acknowledged"
						type="checkbox"
						required
						class="mt-1 rounded border-blue-300 text-blue-600 focus:ring-blue-500"
					/>
					<label for="beta_acknowledged" class="text-sm text-blue-950">
						I acknowledge the Flapjack Cloud public beta terms, including the
						<a href={resolve('/beta')} class="font-medium underline">public beta scope</a>,
						<a href={resolve('/terms')} class="font-medium underline">Terms</a>, and
						<a href={resolve('/privacy')} class="font-medium underline">Privacy Policy</a>.
					</label>
				</div>
				{#if form?.errors?.beta_acknowledgement}
					<p class="mt-2 text-sm text-red-600">{form.errors.beta_acknowledgement}</p>
				{/if}
			</div>

			<button
				type="submit"
				class="w-full rounded bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
			>
				Sign Up
			</button>
		</form>

		<p class="mt-4 text-center text-sm text-gray-600">
			Already have an account?
			<a href={resolve('/login')} class="font-medium text-blue-600 hover:text-blue-500">Log in</a>
		</p>
	</div>
</div>
