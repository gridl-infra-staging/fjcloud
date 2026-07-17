<script lang="ts">
	import {
		LEGAL_EFFECTIVE_DATE_TEXT,
		LEGAL_ENTITY_NAME,
		LEGAL_SUPPORT_MAILTO,
		SUPPORT_EMAIL
	} from '$lib/format';
</script>

<svelte:head>
	<title>Privacy Policy — Flapjack Cloud</title>
</svelte:head>

<article class="mt-6 space-y-8 rounded-3xl border border-[#e3d7bf] bg-flapjack-cream p-8 shadow-sm">
	<header class="space-y-4">
		<p class="text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">
			{LEGAL_ENTITY_NAME}
		</p>
		<h1 class="text-3xl font-black text-flapjack-ink sm:text-4xl">Privacy Policy</h1>
		<p class="text-sm font-semibold uppercase tracking-[0.12em] text-[#7f4d21]">
			{LEGAL_EFFECTIVE_DATE_TEXT}
		</p>
		<p class="max-w-3xl text-base leading-7 text-flapjack-ink/80">
			This policy describes how Flapjack Cloud collects, uses, and protects customer information
			when operating the hosted service.
		</p>
	</header>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Data We Collect</h2>
		<p class="leading-7 text-flapjack-ink/80">
			We collect account identifiers, authentication records, index metadata, usage metering
			records, billing events, and support communications needed to operate the platform.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Purposes</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Information is used to provide the dashboard and API, secure accounts, calculate usage-based
			charges, investigate incidents, and respond to support requests.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Third Parties and Sharing</h2>
		<p class="leading-7 text-flapjack-ink/80">
			We share data with the following service providers that support hosting, billing, and support
			operations:
		</p>
		<ul class="list-disc pl-6 leading-7 text-flapjack-ink/80">
			<li>Amazon Web Services, Inc.</li>
			<li>Stripe, Inc.</li>
			<li>Cloudflare, Inc.</li>
			<li>Slack Technologies, LLC</li>
			<li>Discord, Inc.</li>
		</ul>
		<p class="leading-7 text-flapjack-ink/80">
			Slack Technologies, LLC and Discord, Inc. process only support and social identity
			interactions and are excluded from payment-processing flows.
		</p>
		<p class="leading-7 text-flapjack-ink/80">
			We may also share information when required by law.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Retention</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Operational, billing, and audit records are retained for security, fraud prevention, service
			reliability, and legal compliance, then deleted or anonymized when no longer needed.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Your Rights</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Customers may request access, correction, export, or deletion review of account data by
			contacting support. Requests are handled subject to legal and operational limits.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Children&apos;s Data</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Flapjack Cloud is not directed to children under 13, and we do not knowingly collect personal
			information from children under 13.
		</p>
	</section>

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Contact</h2>
		<p class="leading-7 text-flapjack-ink/80">
			Privacy, export, deletion, and retention questions can be sent to
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

	<section class="space-y-3">
		<h2 class="text-xl font-bold text-flapjack-ink">Changes to This Policy</h2>
		<p class="leading-7 text-flapjack-ink/80">
			We may update this policy as the service evolves. Material changes will be reflected by
			updating the effective date published on this page.
		</p>
	</section>
</article>
