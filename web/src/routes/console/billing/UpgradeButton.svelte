<script lang="ts">
	import { resolve } from '$app/paths';
	import { formatCents, planLabel } from '$lib/format';

	type UpgradeFixtureState = {
		billing_plan: 'free' | 'shared';
		has_payment_method: boolean;
		upgrade_outcome?: UpgradeOutcome;
	};

	type UpgradeOutcome =
		| {
				status: 'success';
				activationAmountCents: number;
		  }
		| {
				status: 'declined';
				message: string;
		  }
		| {
				status: 'requires_action';
		  }
		| {
				status: 'missing_payment_method';
		  }
		| {
				status: 'already_shared';
		  }
		| {
				status: 'error';
				message: string;
		  };

	const addCardPath = resolve('/console/billing/setup');
	const canReadUpgradeFixture = import.meta.env.DEV || import.meta.env.MODE === 'test';

	let {
		billingPlan,
		hasDefaultPaymentMethod,
		upgradeReady,
		upgradeOutcome
	}: {
		billingPlan: 'free' | 'shared';
		hasDefaultPaymentMethod: boolean;
		upgradeReady: boolean;
		upgradeOutcome: UpgradeOutcome | undefined;
	} = $props();

	function readUpgradeFixture(): UpgradeFixtureState | null {
		if (!canReadUpgradeFixture || typeof window === 'undefined') {
			return null;
		}

		const fixture = (
			window as Window & {
				__FJCLOUD_UPGRADE_TEST_FIXTURE__?: UpgradeFixtureState;
			}
		).__FJCLOUD_UPGRADE_TEST_FIXTURE__;
		if (!fixture) {
			return null;
		}

		return fixture;
	}

	let fixture = $derived(readUpgradeFixture());
	let effectiveUpgradeOutcome = $derived(fixture?.upgrade_outcome ?? upgradeOutcome);
	let effectivePlan = $derived.by<'free' | 'shared'>(() => {
		const planFromData = fixture?.billing_plan ?? billingPlan;
		if (
			effectiveUpgradeOutcome?.status === 'success' ||
			effectiveUpgradeOutcome?.status === 'already_shared'
		) {
			return 'shared';
		}
		return planFromData;
	});
	let effectiveHasDefaultPaymentMethod = $derived(
		fixture?.has_payment_method ?? hasDefaultPaymentMethod
	);
	let showingUpgradePath = $derived(effectivePlan === 'free');
	let effectiveUpgradeReady = $derived(
		fixture ? fixture.billing_plan === 'free' && fixture.has_payment_method : upgradeReady
	);
	let showNeedsCardState = $derived(
		effectiveUpgradeOutcome?.status === 'missing_payment_method' ||
			(effectivePlan === 'free' && !effectiveHasDefaultPaymentMethod)
	);
	let showUpgradeCta = $derived(
		effectivePlan === 'free' &&
			effectiveHasDefaultPaymentMethod &&
			effectiveUpgradeReady &&
			effectiveUpgradeOutcome?.status !== 'requires_action'
	);
	let activationAmountCents = $derived(
		effectiveUpgradeOutcome?.status === 'success'
			? effectiveUpgradeOutcome.activationAmountCents
			: 500
	);
</script>

<section class="rounded-lg border border-flapjack-ink/10 bg-flapjack-cream p-6 shadow-sm">
	<div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
		<div class="space-y-2">
			<p class="text-xs font-semibold uppercase tracking-[0.2em] text-flapjack-rose">
				Upgrade plan
			</p>
			<h2 class="text-xl font-semibold text-flapjack-ink">
				{showingUpgradePath ? 'Move from Free to Paid' : 'Paid plan active'}
			</h2>
			<p class="max-w-2xl text-sm text-flapjack-ink/80">
				{#if showingUpgradePath}
					Paid lifts the Free-tier caps and charges the paid-plan minimum right away so the account
					is trusted before higher quotas unlock.
				{:else}
					This account already has the Paid plan, so the higher limits stay unlocked while billing
					runs against the paid-plan minimum.
				{/if}
			</p>
		</div>
		<p
			class="inline-flex items-center rounded-full bg-flapjack-ink/10 px-3 py-1 text-sm font-medium text-flapjack-ink"
			data-testid="current-plan-label"
		>
			Current plan: {planLabel(effectivePlan)}
		</p>
	</div>

	<div class="mt-5 space-y-4">
		{#if effectiveUpgradeOutcome?.status === 'success'}
			<div
				class="rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink/90"
				data-testid="upgrade-success-banner"
			>
				<p class="font-semibold">You're on Paid.</p>
				<p>
					First charge cleared: {formatCents(activationAmountCents)}. Your next bill is due in 30
					days.
				</p>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'declined'}
			<div
				class="rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
				data-testid="upgrade-decline-banner"
			>
				<p class="font-semibold">Your card was declined.</p>
				<p>{effectiveUpgradeOutcome.message}</p>
				<a
					href={addCardPath}
					class="mt-3 inline-flex rounded-md border border-flapjack-rose/45 px-3 py-2 font-medium text-flapjack-plum hover:bg-flapjack-rose/20"
					data-testid="try-different-card-button"
				>
					Try a different card
				</a>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'requires_action'}
			<div
				class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-4 text-sm text-flapjack-ink/90"
				data-testid="upgrade-3ds-banner"
			>
				<p class="font-semibold">Your card needs extra authentication.</p>
				<p>Contact support to complete the upgrade with an authenticated payment method.</p>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'already_shared'}
			<div
				class="rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink/90"
				data-testid="already-shared-banner"
			>
				<p class="font-semibold">This account is already on Paid.</p>
				<p>Your plan status was refreshed from the backend.</p>
			</div>
		{:else if showNeedsCardState}
			<div
				class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-4 text-sm text-flapjack-ink/90"
				data-testid="upgrade-needs-card-banner"
			>
				<p class="font-semibold">Add a default card before upgrading.</p>
				<p>The upgrade charge only runs once a default payment method is on file.</p>
				<a
					href={addCardPath}
					class="mt-3 inline-flex rounded-md bg-flapjack-ink px-3 py-2 font-medium text-flapjack-cream hover:bg-flapjack-ink/85"
					data-testid="upgrade-add-card-cta"
				>
					Add a card
				</a>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'error'}
			<div
				class="rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
			>
				<p class="font-semibold">Upgrade unavailable.</p>
				<p>{effectiveUpgradeOutcome.message}</p>
			</div>
		{/if}

		{#if showUpgradeCta}
			<form method="POST" action="?/upgradeToShared">
				<button
					type="submit"
					class="inline-flex items-center rounded-md bg-flapjack-rose px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
					data-testid="upgrade-to-shared-button"
				>
					Upgrade to Paid ($5/mo minimum)
				</button>
			</form>
		{/if}
	</div>
</section>
