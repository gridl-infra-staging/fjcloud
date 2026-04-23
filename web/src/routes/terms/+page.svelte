<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
</script>

<svelte:head>
	<title>Terms of Service — Flapjack Cloud</title>
</svelte:head>

<main class="mx-auto max-w-3xl px-6 py-12">
	<a href={resolve('/')} class="text-sm font-medium text-blue-600 hover:text-blue-800"
		>Back to Flapjack Cloud</a
	>
	<h1 class="mt-6 text-3xl font-bold text-gray-900">Terms of Service</h1>
	<p class="mt-4 text-gray-600">
		These terms describe access to Flapjack Cloud during public beta. By creating an account, you
		agree to use the service responsibly, keep credentials secure, and avoid workloads that abuse,
		disrupt, or attempt unauthorized access to the platform or other tenants.
	</p>

	<section class="mt-8 space-y-4 text-sm text-gray-700">
		<h2 class="text-lg font-semibold text-gray-900">Beta availability</h2>
		<p>
			Public beta features, limits, and pricing may change before general availability. Beta support
			is email-based with a target response within 48 business hours.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Billing and accounts</h2>
		<p>
			Prices are shown in USD. If paid billing is enabled for your account, invoices follow the
			prices shown on the Flapjack Cloud website and in the product at the time of use.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Delivery</h2>
		<p>
			Flapjack Cloud is a digital service. Nothing is shipped. Account access is provided through
			the web dashboard and API after signup.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Cancellation</h2>
		<p>
			You can cancel by closing your account or contacting support. Usage already incurred may still
			be billed.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Refunds</h2>
		<p>
			Refund requests are reviewed for duplicate charges, billing errors, or service unavailability.
			Approved refunds are returned to the original payment method when possible.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Payment security</h2>
		<p>
			Payment details are handled by Stripe over HTTPS. Flapjack Cloud does not store full card
			numbers.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Contact</h2>
		<p>
			Questions about these terms should be sent through the shared support channel.
			<a href={BETA_FEEDBACK_MAILTO} class="font-medium text-blue-600 hover:text-blue-800"
				>Email support</a
			>.
		</p>
	</section>
</main>
