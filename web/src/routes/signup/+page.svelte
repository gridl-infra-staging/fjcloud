<script lang="ts">
	import { resolve } from '$app/paths';
	import OAuthButtons from '$lib/components/OAuthButtons.svelte';
	import { MARKETING_PRICING } from '$lib/pricing';
	import { SIGNUP_PASSWORD_MIN_LENGTH, clientSignupPasswordLengthError } from './signup-validation';

	type SignupFieldError = 'form' | 'name' | 'email' | 'password' | 'confirm_password';
	type SignupFormState = {
		errors?: Partial<Record<SignupFieldError, string>>;
		name?: string;
		email?: string;
	};

	let { form, data }: { form?: SignupFormState; data: { apiBaseUrl: string } } = $props();

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

<div class="flex min-h-screen items-center justify-center bg-flapjack-cream/80">
	<div class="w-full max-w-md rounded-lg bg-white p-8 shadow">
		<h1 class="mb-6 text-2xl font-bold text-flapjack-ink">Create your account</h1>
		<p class="mb-6 text-sm text-flapjack-ink/70">{MARKETING_PRICING.free_tier_promise}</p>

		{#if form?.errors?.form}
			<div class="mb-4 rounded bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum" role="alert">
				{form.errors.form}
			</div>
		{/if}

		<form method="POST" class="space-y-4">
			<div>
				<label for="name" class="mb-1 block text-sm font-medium text-flapjack-ink/80">Name</label>
				<input
					id="name"
					name="name"
					type="text"
					bind:value={name}
					required
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
				{#if form?.errors?.name}
					<p class="mt-1 text-sm text-flapjack-plum">{form.errors.name}</p>
				{/if}
			</div>

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

			<div>
				<label for="password" class="mb-1 block text-sm font-medium text-flapjack-ink/80">
					Password
				</label>
				<input
					id="password"
					name="password"
					type="password"
					bind:value={password}
					required
					minlength={SIGNUP_PASSWORD_MIN_LENGTH}
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
				{#if passwordErrorMessage}
					<p class="mt-1 text-sm text-flapjack-plum">{passwordErrorMessage}</p>
				{/if}
			</div>

			<div>
				<label for="confirm_password" class="mb-1 block text-sm font-medium text-flapjack-ink/80">
					Confirm Password
				</label>
				<input
					id="confirm_password"
					name="confirm_password"
					type="password"
					required
					minlength={SIGNUP_PASSWORD_MIN_LENGTH}
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
				{#if form?.errors?.confirm_password}
					<p class="mt-1 text-sm text-flapjack-plum" role="alert">{form.errors.confirm_password}</p>
				{/if}
			</div>

			<button
				type="submit"
				class="w-full rounded bg-flapjack-rose px-4 py-2 font-medium text-white hover:bg-flapjack-plum focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-flapjack-cream"
			>
				Sign Up
			</button>
		</form>

		<div class="my-6 flex items-center">
			<div class="h-px flex-1 bg-flapjack-cream/60"></div>
			<span class="px-3 text-xs font-medium uppercase tracking-wide text-flapjack-ink/60">Or</span>
			<div class="h-px flex-1 bg-flapjack-cream/60"></div>
		</div>

		<OAuthButtons apiBaseUrl={data.apiBaseUrl} />

		<p class="mt-4 text-center text-sm text-flapjack-ink/70">
			Already have an account?
			<a href={resolve('/login')} class="font-medium text-flapjack-rose hover:text-flapjack-plum"
				>Log in</a
			>
		</p>
	</div>
</div>
