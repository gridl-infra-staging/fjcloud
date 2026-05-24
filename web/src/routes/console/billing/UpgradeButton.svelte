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

<section class="rounded-lg border border-[#1f1b18]/10 bg-[#fff8ea] p-6 shadow-sm">
	<div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
		<div class="space-y-2">
			<p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#b83f5f]">Upgrade plan</p>
			<h2 class="text-xl font-semibold text-[#1f1b18]">Move from Free to Shared</h2>
			<p class="max-w-2xl text-sm text-[#5c5149]">
				Shared lifts the Free-tier caps and charges the minimum monthly spend right away so the
				account is trusted before higher quotas unlock.
			</p>
		</div>
		<p
			class="inline-flex items-center rounded-full bg-[#1f1b18]/8 px-3 py-1 text-sm font-medium text-[#1f1b18]"
			data-testid="current-plan-label"
		>
			Current plan: {planLabel(effectivePlan)}
		</p>
	</div>

	<div class="mt-5 space-y-4">
		{#if effectiveUpgradeOutcome?.status === 'success'}
			<div
				class="rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"
				data-testid="upgrade-success-banner"
			>
				<p class="font-semibold">You're on Shared.</p>
				<p>
					First charge cleared: {formatCents(activationAmountCents)}. Your next bill is due in 30
					days.
				</p>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'declined'}
			<div
				class="rounded-lg border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900"
				data-testid="upgrade-decline-banner"
			>
				<p class="font-semibold">Your card was declined.</p>
				<p>{effectiveUpgradeOutcome.message}</p>
				<a
					href={addCardPath}
					class="mt-3 inline-flex rounded-md border border-rose-300 px-3 py-2 font-medium text-rose-900 hover:bg-rose-100"
					data-testid="try-different-card-button"
				>
					Try a different card
				</a>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'requires_action'}
			<div
				class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
				data-testid="upgrade-3ds-banner"
			>
				<p class="font-semibold">Your card needs extra authentication.</p>
				<p>Contact support to complete the upgrade with an authenticated payment method.</p>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'already_shared'}
			<div
				class="rounded-lg border border-sky-200 bg-sky-50 p-4 text-sm text-sky-900"
				data-testid="already-shared-banner"
			>
				<p class="font-semibold">This account is already on Shared.</p>
				<p>Your plan status was refreshed from the backend.</p>
			</div>
		{:else if showNeedsCardState}
			<div
				class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
				data-testid="upgrade-needs-card-banner"
			>
				<p class="font-semibold">Add a default card before upgrading.</p>
				<p>The upgrade charge only runs once a default payment method is on file.</p>
				<a
					href={addCardPath}
					class="mt-3 inline-flex rounded-md bg-[#1f1b18] px-3 py-2 font-medium text-[#fff8ea] hover:bg-[#342d28]"
					data-testid="upgrade-add-card-cta"
				>
					Add a card
				</a>
			</div>
		{:else if effectiveUpgradeOutcome?.status === 'error'}
			<div class="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
				<p class="font-semibold">Upgrade unavailable.</p>
				<p>{effectiveUpgradeOutcome.message}</p>
			</div>
		{/if}

		{#if showUpgradeCta}
			<form method="POST" action="?/upgradeToShared">
				<button
					type="submit"
					class="inline-flex items-center rounded-md bg-[#b83f5f] px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-[#9c304f] disabled:cursor-not-allowed disabled:opacity-60"
					data-testid="upgrade-to-shared-button"
				>
					Upgrade to Shared ($5/mo minimum)
				</button>
			</form>
		{/if}
	</div>
</section>
