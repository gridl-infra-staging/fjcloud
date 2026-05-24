<script lang="ts">
	import {
		LEGAL_EFFECTIVE_DATE_TEXT,
		LEGAL_ENTITY_NAME,
		LEGAL_SUPPORT_MAILTO,
		SUPPORT_EMAIL
	} from '$lib/format';
</script>

<svelte:head>
	<title>Terms of Service — Flapjack Cloud</title>
</svelte:head>

<article class="mt-6 space-y-8 rounded-3xl border border-[#e3d7bf] bg-flapjack-cream p-8 shadow-sm">
	<header class="space-y-4">
		<p class="text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">
			{LEGAL_ENTITY_NAME}
		</p>
		<h1 class="text-3xl font-black text-flapjack-ink sm:text-4xl">Terms of Service</h1>
		<p class="text-sm font-semibold uppercase tracking-[0.12em] text-[#7f4d21]">
			{LEGAL_EFFECTIVE_DATE_TEXT}
		</p>
		<p class="max-w-3xl text-base leading-7 text-flapjack-ink">
			These terms govern access to the Flapjack Cloud hosted dashboard, API endpoints, and related
			customer support.
		</p>
	</header>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Definitions</h2>
		<p class="leading-7 text-flapjack-ink/80">
			“Service” means the hosted Flapjack Cloud platform and related support services. “Customer
			Content” means data and materials that a customer submits to the service.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Service</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Flapjack Cloud provides multi-tenant hosted search infrastructure with account, billing, and
			operational tooling. Features and operational limits may evolve as the service is improved.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Acceptable Use</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Customers must not use the service for unlawful activity, abuse, credential theft, or
			interference with other tenants or platform operations.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Subscription and Payment</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Paid usage is billed in USD according to the published pricing surface and in-product billing
			details at the time of usage. Customers are responsible for applicable taxes, excluding taxes
			based on our net income.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Term and Termination</h2>
		<p class="leading-7 text-flapjack-ink/80">
			These terms apply while a customer account remains active. Either party may terminate service
			access, and accrued payment obligations survive termination.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">IP and License</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Customers retain ownership of Customer Content. We grant customers a limited, non-exclusive
			right to use the service during the subscription term.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Disclaimers</h2>
		<p class="leading-7 text-flapjack-ink/80">
			The service is provided on an "as is" and "as available" basis to the maximum extent permitted
			by applicable law.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Limitation of Liability</h2>
		<p class="leading-7 text-flapjack-ink/80">
			To the maximum extent permitted by law, neither party is liable for indirect, incidental,
			special, consequential, or exemplary damages arising from use of the service.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Indemnification</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Customers agree to defend and indemnify Flapjack Cloud against third-party claims arising from
			Customer Content or misuse of the service.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Contact</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Questions about these terms can be sent to
			<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
			<a
				href={LEGAL_SUPPORT_MAILTO}
				class="font-semibold text-flapjack-rose underline hover:text-flapjack-plum"
			>
				{SUPPORT_EMAIL}
			</a>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
			.
		</p>
	</section>
</article>
