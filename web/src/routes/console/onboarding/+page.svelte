<script lang="ts">
	import { enhance } from '$app/forms';
	import { browser } from '$app/environment';
	import { resolve } from '$app/paths';
	import type { SubmitFunction } from '@sveltejs/kit';
	import { copyToClipboard } from '$lib/clipboard';
	import { REGIONS, SUPPORT_EMAIL } from '$lib/format';
	import type { OnboardingStatus, FlapjackCredentials } from '$lib/api/types';
	import { writeTextToClipboard } from '$lib/clipboard';

	let { data, form: formResult } = $props();

	const onboardingStatus: OnboardingStatus | null = $derived(data.onboardingStatus ?? null);
	const planContext = $derived(data.planContext);

	// Wizard step derived from form result
	type WizardStep =
		| 'choose'
		| 'preparing'
		| 'generating'
		| 'credentials'
		| 'completed'
		| 'billing'
		| 'unavailable';

	const waitingForRegionOrIndex: boolean = $derived(
		onboardingStatus?.has_region === true && onboardingStatus.has_index === false
	);

	const waitingForCredentials: boolean = $derived(
		onboardingStatus?.has_index === true && onboardingStatus.has_api_key === false
	);
	const completedFromPlanContext: boolean = $derived(
		planContext?.onboarding_completed ?? onboardingStatus?.completed ?? false
	);
	const sharedPlanNeedsBillingSetup: boolean = $derived(
		planContext?.billing_plan === 'shared' && planContext?.has_payment_method === false
	);

	const wizardStep: WizardStep = $derived.by(() => {
		if (!onboardingStatus) return 'unavailable';
		if (completedFromPlanContext) return 'completed';
		if (sharedPlanNeedsBillingSetup) return 'billing';
		if (formResult?.credentials) return 'credentials';
		if (formResult?.created || waitingForCredentials) return 'generating';
		if (waitingForRegionOrIndex) return 'preparing';
		return 'choose';
	});

	// Form state for step 1
	let indexName = $state('my-first-index');
	let selectedRegion = $state('us-east-1');

	const RESERVED_INDEX_NAMES = new Set(['_internal', 'health', 'metrics']);

	function isAsciiAlphaNumeric(char: string | undefined): boolean {
		return Boolean(
			char &&
			((char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9'))
		);
	}

	function isAllowedIndexNameCharacter(char: string): boolean {
		return isAsciiAlphaNumeric(char) || char === '-' || char === '_';
	}

	function hasOnlyAllowedIndexNameCharacters(name: string): boolean {
		for (const char of name) {
			if (!isAllowedIndexNameCharacter(char)) {
				return false;
			}
		}

		return true;
	}

	// Index name validation
	function validateIndexName(name: string): string | null {
		if (!name) return 'Index name is required';
		if (name.length > 64) return 'Index name must be 64 characters or less';
		if (!isAsciiAlphaNumeric(name[0]) || !isAsciiAlphaNumeric(name[name.length - 1]))
			return 'Index name must start and end with a letter or number';
		if (!hasOnlyAllowedIndexNameCharacters(name))
			return 'Only letters, numbers, hyphens, and underscores allowed';
		if (RESERVED_INDEX_NAMES.has(name)) return 'This name is reserved';
		return null;
	}

	const validationError = $derived(validateIndexName(indexName));
	const hasValidationError = $derived(indexName !== 'my-first-index' && validationError !== null);

	// Credentials from form result
	const credentials: FlapjackCredentials | null = $derived(formResult?.credentials ?? null);

	// Preparing state
	const preparingMessage: string = $derived(
		onboardingStatus?.suggested_next_step || 'Preparing your index...'
	);
	const savedIndexName: string = $derived(formResult?.indexName ?? indexName);
	const savedRegion: string = $derived(formResult?.region ?? selectedRegion);

	// Auto-polling for step 2 (client-side only)
	const POLL_INTERVAL_MS = 3000;
	const POLL_MAX_TICKS = 40; // 40 × 3s = 2-minute ceiling

	let pollTimer: ReturnType<typeof setInterval> | null = null;
	let pollCount = $state(0);
	let pollTimedOut = $state(false);

	function getRetryIndexForm(): HTMLFormElement | null {
		if (!browser) return null;

		return document.querySelector('form[action="?/retryIndex"]');
	}

	function startPolling() {
		if (!browser || pollTimer) return;
		pollTimer = setInterval(() => {
			pollCount++;
			// Submit the retry form on every tick, including the final one
			getRetryIndexForm()?.requestSubmit();
			// After hitting the ceiling, stop and surface timeout UI
			if (pollCount >= POLL_MAX_TICKS) {
				stopPolling();
				pollTimedOut = true;
			}
		}, POLL_INTERVAL_MS);
	}

	function stopPolling() {
		if (pollTimer) {
			clearInterval(pollTimer);
			pollTimer = null;
		}
	}

	function resumePolling() {
		pollCount = 0;
		pollTimedOut = false;
		startPolling();
	}

	const preserveWizardStepOnSuccess: SubmitFunction = () => {
		return async ({ result, update }) => {
			// After successful mutations, keep the current page state so the
			// onboarding_completed redirect doesn't replace the wizard result.
			await update({ invalidateAll: result.type !== 'success' });
		};
	};

	const preserveWizardStepAlways: SubmitFunction = () => {
		return async ({ update }) => {
			await update({ invalidateAll: false });
		};
	};

	// Start polling when wizard enters preparing step (region not yet ready)
	$effect(() => {
		if (wizardStep === 'preparing' && onboardingStatus && !onboardingStatus.region_ready) {
			startPolling();
		}
		return () => stopPolling();
	});
</script>

<svelte:head>
	<title>Get Started — Flapjack Cloud</title>
</svelte:head>

<div class="mx-auto max-w-2xl">
	<h1 class="mb-2 text-2xl font-bold text-flapjack-ink">Get Started</h1>
	<p class="mb-8 text-sm text-flapjack-ink/60">
		Set up your first search index in a few simple steps.
	</p>

	<!-- Step indicators -->
	{#if wizardStep !== 'completed' && wizardStep !== 'billing'}
		<div class="mb-8 flex items-center justify-center gap-2" data-testid="step-indicators">
			{#each [1, 2, 3] as stepNum (stepNum)}
				{@const active =
					(stepNum === 1 && wizardStep === 'choose') ||
					(stepNum === 2 && wizardStep === 'preparing') ||
					(stepNum === 3 && (wizardStep === 'generating' || wizardStep === 'credentials'))}
				{@const done =
					(stepNum === 1 && wizardStep !== 'choose') ||
					(stepNum === 2 && (wizardStep === 'generating' || wizardStep === 'credentials'))}
				<div
					class="flex h-8 w-8 items-center justify-center rounded-full text-sm font-medium {active
						? 'bg-flapjack-rose text-white'
						: done
							? 'bg-flapjack-mint text-white'
							: 'bg-flapjack-cream/60 text-flapjack-ink/60'}"
				>
					{stepNum}
				</div>
				{#if stepNum < 3}
					<div class="h-0.5 w-12 {done ? 'bg-flapjack-mint' : 'bg-flapjack-cream/60'}"></div>
				{/if}
			{/each}
		</div>
	{/if}

	{#if wizardStep === 'billing'}
		<div
			class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-6 shadow-sm"
			data-testid="billing-setup-gate"
		>
			<h2 class="text-lg font-medium text-flapjack-ink/90">Billing setup required</h2>
			<p class="mt-2 text-sm text-flapjack-ink/80">
				Your shared plan needs a payment method before onboarding can continue.
			</p>
			<a
				href={resolve('/console/billing/setup')}
				class="mt-4 inline-block rounded-md bg-flapjack-yellow px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-yellow/80"
				>Set up billing</a
			>
		</div>
	{:else if wizardStep === 'unavailable'}
		<div
			class="rounded-lg border border-flapjack-ink/20 bg-white p-6 shadow-sm"
			data-testid="onboarding-status-unavailable"
		>
			<h2 class="text-lg font-medium text-flapjack-ink">Unable to load setup status</h2>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				Refresh this page to retry loading your onboarding progress.
			</p>
			<a
				href={resolve('/console')}
				class="mt-4 inline-block rounded-md bg-flapjack-ink px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-ink/85"
				>Back to dashboard</a
			>
		</div>
		<!-- Step 1: Choose region & name index -->
	{:else if wizardStep === 'choose'}
		<div data-testid="onboarding-step-1">
			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-4 text-lg font-medium text-flapjack-ink">
					Choose a region & name your index
				</h2>
				{#if planContext?.billing_plan === 'free'}
					<p class="mb-4 text-sm text-flapjack-plum">
						No credit card required while you are on the Free plan.
					</p>
				{/if}

				<form method="POST" action="?/createIndex" use:enhance={preserveWizardStepOnSuccess}>
					<!-- Region picker -->
					<fieldset class="mb-6">
						<legend class="mb-3 text-sm font-medium text-flapjack-ink/80">Region</legend>
						<div class="grid grid-cols-2 gap-3">
							{#each REGIONS as region (region.id)}
								<label
									class="cursor-pointer rounded-lg border-2 p-4 transition-colors {selectedRegion ===
									region.id
										? 'border-flapjack-rose bg-flapjack-rose/10'
										: 'border-flapjack-ink/20 hover:border-flapjack-ink/30'}"
								>
									<input
										type="radio"
										name="region"
										value={region.id}
										bind:group={selectedRegion}
										class="sr-only"
									/>
									<span class="block text-sm font-medium text-flapjack-ink">{region.name}</span>
									<span class="mt-1 block text-xs text-flapjack-ink/60">{region.id}</span>
								</label>
							{/each}
						</div>
					</fieldset>

					<!-- Index name input -->
					<div class="mb-6">
						<label for="index-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
							>Index name</label
						>
						<input
							id="index-name"
							type="text"
							name="name"
							bind:value={indexName}
							class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose {hasValidationError
								? 'border-flapjack-rose/45'
								: ''}"
							placeholder="my-first-index"
							maxlength={64}
						/>
						{#if hasValidationError && validationError}
							<p class="mt-1 text-sm text-flapjack-plum" data-testid="index-name-error">
								{validationError}
							</p>
						{/if}
					</div>

					{#if formResult?.error}
						<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
							{formResult.error}
						</div>
					{/if}

					<button
						type="submit"
						disabled={validationError !== null}
						class="w-full rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
					>
						Continue
					</button>
				</form>
			</div>
		</div>

		<!-- Step 2: Setting up -->
	{:else if wizardStep === 'preparing'}
		<div data-testid="onboarding-step-2">
			<div class="rounded-lg bg-white p-6 shadow">
				{#if onboardingStatus?.region_ready}
					<!-- Index ready, create now -->
					<div class="text-center">
						<div
							class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-flapjack-mint/35"
						>
							<svg
								class="h-6 w-6 text-flapjack-ink/80"
								fill="none"
								stroke="currentColor"
								viewBox="0 0 24 24"
							>
								<path
									stroke-linecap="round"
									stroke-linejoin="round"
									stroke-width="2"
									d="M5 13l4 4L19 7"
								/>
							</svg>
						</div>
						<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Your index is ready!</h2>
						<p class="mb-6 text-sm text-flapjack-ink/60">Creating your index now...</p>

						<form method="POST" action="?/retryIndex" use:enhance={preserveWizardStepOnSuccess}>
							<input type="hidden" name="name" value={savedIndexName} />
							<input type="hidden" name="region" value={savedRegion} />
							<button
								type="submit"
								class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
							>
								Create Index
							</button>
						</form>
					</div>
				{:else if pollTimedOut}
					<!-- Polling timed out — offer to keep waiting or contact support -->
					<div class="text-center" data-testid="preparing-timeout">
						<div
							class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-flapjack-yellow/30"
						>
							<svg
								class="h-6 w-6 text-flapjack-yellow"
								fill="none"
								stroke="currentColor"
								viewBox="0 0 24 24"
							>
								<path
									stroke-linecap="round"
									stroke-linejoin="round"
									stroke-width="2"
									d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4.5c-.77-.833-2.694-.833-3.464 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z"
								/>
							</svg>
						</div>
						<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Taking longer than expected</h2>
						<p class="text-sm text-flapjack-ink/60">
							Your index is still being prepared. This can occasionally take longer than usual.
						</p>
						<div class="mt-6 flex flex-col items-center gap-3">
							<button
								type="button"
								onclick={resumePolling}
								class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
							>
								Keep waiting
							</button>
							<a
								href="mailto:{SUPPORT_EMAIL}"
								class="text-sm text-flapjack-ink/60 hover:text-flapjack-ink/80"
							>
								Contact support
							</a>
						</div>
					</div>
				{:else}
					<!-- Still preparing -->
					<div class="text-center">
						<div
							class="mx-auto mb-4 flex h-12 w-12 items-center justify-center"
							data-testid="preparing-spinner"
						>
							<svg class="h-8 w-8 animate-spin text-flapjack-rose" fill="none" viewBox="0 0 24 24">
								<circle
									class="opacity-25"
									cx="12"
									cy="12"
									r="10"
									stroke="currentColor"
									stroke-width="4"
								/>
								<path
									class="opacity-75"
									fill="currentColor"
									d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
								/>
							</svg>
						</div>
						<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Preparing index</h2>
						<p class="text-sm text-flapjack-ink/60">{preparingMessage}</p>
						<p class="mt-4 text-xs text-flapjack-ink/50">This usually takes a minute or two.</p>
					</div>
				{/if}

				<!-- Hidden retry form for auto-polling -->
				{#if onboardingStatus && !onboardingStatus.region_ready}
					<form
						method="POST"
						action="?/retryIndex"
						use:enhance={preserveWizardStepOnSuccess}
						class="hidden"
					>
						<input type="hidden" name="name" value={savedIndexName} />
						<input type="hidden" name="region" value={savedRegion} />
					</form>
				{/if}
			</div>
		</div>

		<!-- Step 3: Your credentials -->
	{:else if wizardStep === 'credentials' && credentials}
		<div data-testid="onboarding-step-3">
			<div class="rounded-lg bg-white p-6 shadow">
				<div class="mb-4 text-center">
					<div
						class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-flapjack-mint/35"
					>
						<svg
							class="h-6 w-6 text-flapjack-ink/80"
							fill="none"
							stroke="currentColor"
							viewBox="0 0 24 24"
						>
							<path
								stroke-linecap="round"
								stroke-linejoin="round"
								stroke-width="2"
								d="M5 13l4 4L19 7"
							/>
						</svg>
					</div>
					<h2 class="text-lg font-medium text-flapjack-ink">You're all set!</h2>
					<p class="mt-1 text-sm text-flapjack-ink/60">
						Here are your credentials. Save them somewhere safe.
					</p>
				</div>

				<div
					class="mb-4 rounded-md border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3 text-sm text-flapjack-ink/80"
				>
					You won't see this key again. Save it now.
				</div>

				<!-- Endpoint -->
				<div class="mb-4">
					<span class="mb-1 block text-sm font-medium text-flapjack-ink/80">Endpoint</span>
					<div class="flex items-center gap-2">
						<code
							class="flex-1 rounded-md bg-flapjack-cream/70 px-3 py-2 text-sm text-flapjack-ink"
							data-testid="credential-endpoint">{credentials.endpoint}</code
						>
						<button
							type="button"
							onclick={(event) =>
								void copyToClipboard(
									credentials.endpoint,
									event.currentTarget as HTMLButtonElement
								)}
							class="rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/80"
						>
							Copy
						</button>
					</div>
				</div>

				<!-- API Key -->
				<div class="mb-4">
					<span class="mb-1 block text-sm font-medium text-flapjack-ink/80">API Key</span>
					<div class="flex items-center gap-2">
						<code
							class="flex-1 rounded-md bg-flapjack-cream/70 px-3 py-2 text-sm text-flapjack-ink"
							data-testid="credential-api-key">{credentials.api_key}</code
						>
						<button
							type="button"
							onclick={(event) =>
								void copyToClipboard(credentials.api_key, event.currentTarget as HTMLButtonElement)}
							class="rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/80"
						>
							Copy
						</button>
					</div>
				</div>

				<!-- Quickstart snippet -->
				<details class="mb-6">
					<summary
						class="cursor-pointer text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
						>Quickstart code</summary
					>
					<div class="mt-3 rounded-md bg-flapjack-ink p-4">
						<pre class="overflow-x-auto text-xs text-flapjack-cream"><code
								>{`# Search your index
curl -X POST '${credentials.endpoint}/1/indexes/${savedIndexName}/query' \\
  -H 'X-Algolia-API-Key: ${credentials.api_key}' \\
  -H 'X-Algolia-Application-Id: ${credentials.application_id}' \\
  -H 'Content-Type: application/json' \\
  -d '{"query": "hello"}'

# Add a document
curl -X POST '${credentials.endpoint}/1/indexes/${savedIndexName}/batch' \\
  -H 'X-Algolia-API-Key: ${credentials.api_key}' \\
  -H 'X-Algolia-Application-Id: ${credentials.application_id}' \\
  -H 'Content-Type: application/json' \\
  -d '{"requests": [{"action": "addObject", "body": {"title": "My first document", "body": "Hello, world!"}}]}'`}</code
							></pre>
					</div>
				</details>

				<a
					href={resolve('/console')}
					class="block w-full rounded-md bg-flapjack-rose px-4 py-2 text-center text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Go to Console
				</a>
			</div>
		</div>

		<!-- Completed: already onboarded -->
	{:else if wizardStep === 'completed'}
		<div class="rounded-lg bg-white p-6 text-center shadow">
			<p class="text-flapjack-ink/60">You've already completed onboarding.</p>
			<a
				href={resolve('/console')}
				class="mt-4 inline-block text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			>
				Go to Console
			</a>
		</div>

		<!-- Step 3 loading: index created but need credentials -->
	{:else if wizardStep === 'generating'}
		<div data-testid="onboarding-step-3">
			<div class="rounded-lg bg-white p-6 text-center shadow">
				<div
					class="mx-auto mb-4 flex h-12 w-12 items-center justify-center"
					data-testid="credentials-spinner"
				>
					<svg class="h-8 w-8 animate-spin text-flapjack-rose" fill="none" viewBox="0 0 24 24">
						<circle
							class="opacity-25"
							cx="12"
							cy="12"
							r="10"
							stroke="currentColor"
							stroke-width="4"
						/>
						<path
							class="opacity-75"
							fill="currentColor"
							d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
						/>
					</svg>
				</div>
				<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Generating your credentials...</h2>
				{#if formResult?.error}
					<div
						class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-left text-sm text-flapjack-plum"
						data-testid="onboarding-step-3-error"
						role="alert"
					>
						{formResult.error}
					</div>
				{/if}
				<form method="POST" action="?/getCredentials" use:enhance={preserveWizardStepAlways}>
					<button
						type="submit"
						class="mt-4 rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Get Credentials
					</button>
				</form>
			</div>
		</div>
	{/if}
</div>
