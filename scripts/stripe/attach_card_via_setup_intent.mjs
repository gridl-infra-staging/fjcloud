#!/usr/bin/env node
// Attach a card to a Stripe customer via a SetupIntent + Stripe.js Elements
// driven through Playwright. This is the same flow our /dashboard/billing/setup
// page uses for real customers, run against a local HTML page so we don't
// depend on having an authenticated fjcloud session.
//
// Bypasses Stripe's hosted billing portal (which gates fraud-flagged sessions
// behind hCaptcha image puzzles that we can't auto-solve). The SetupIntent
// flow uses pure Stripe.js Elements and does not trigger hCaptcha.
//
// Originally built 2026-05-03 for the Phase G live invoice probe — attaching
// a Privacy.com test card to cus_URij8h4pXDprIK on the live Stripe account.
// Kept as a reusable ops-layer helper for future card-attach scenarios:
//   - Replacement card for an existing customer
//   - Synthetic test customer setup against live mode for ops probes
//   - Disaster recovery rehearsals where we need a known-good PM on file
//
// Usage:
//   set -a; source .secret/.env.secret; set +a
//   PK_LIVE="$STRIPE_PUBLISHABLE_KEY" \
//   CLIENT_SECRET=seti_...secret_... \
//   CARD_NUMBER=5439300620174338 \
//   CARD_EXP=05/31 \
//   CARD_CVC=460 \
//   CARD_ZIP=10001 \
//   node scripts/stripe/attach_card_via_setup_intent.mjs
//
// To create the SetupIntent first:
//   curl -u "$STRIPE_SECRET_KEY_flapjack_cloud:" \
//     -X POST https://api.stripe.com/v1/setup_intents \
//     -d customer=<cus_xxx> -d "payment_method_types[]=card" -d usage=off_session
//
// Required env: PK_LIVE, CLIENT_SECRET, CARD_NUMBER, CARD_EXP, CARD_CVC.
// Optional: CARD_ZIP (default 10001), HEADLESS (default 1), TIMEOUT_MS (default 60000),
//           SCREENSHOT_DIR (default /tmp/setup_intent_drive), PORT (default 8765).
//
// Output (stdout, JSON): {"ok": true, "status": "OK succeeded", "pm_id": "pm_..."}
// or {"ok": false, "error": "..."} with non-zero exit.

import playwrightPkg from '../../web/node_modules/@playwright/test/index.js';
import fs from 'node:fs/promises';
import http from 'node:http';

const { chromium } = playwrightPkg;

const required = (name) => {
	const v = process.env[name];
	if (!v) {
		console.error(JSON.stringify({ ok: false, error: `missing env: ${name}` }));
		process.exit(2);
	}
	return v;
};

const PK_LIVE = required('PK_LIVE');
const CLIENT_SECRET = required('CLIENT_SECRET');
const CARD_NUMBER = required('CARD_NUMBER');
const CARD_EXP = required('CARD_EXP');
const CARD_CVC = required('CARD_CVC');
const CARD_ZIP = process.env.CARD_ZIP || '10001';
const HEADLESS = process.env.HEADLESS !== '0';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || '60000');
const SCREENSHOT_DIR = process.env.SCREENSHOT_DIR || '/tmp/setup_intent_drive';
const PORT = Number(process.env.PORT || '8765');

await fs.mkdir(SCREENSHOT_DIR, { recursive: true });

// Inline the minimal HTML page to avoid an extra file. Stripe.js loads from
// the CDN, mounts Elements, and confirms the SetupIntent on form submit.
// All result data is exposed on the parent page via data-testid attributes
// so the Playwright driver can read them without needing to await navigation.
const HTML_TEMPLATE = `<!DOCTYPE html>
<html><head><title>SetupIntent Card Attach</title>
<script src="https://js.stripe.com/v3/"></script></head>
<body>
<form id="payment-form">
  <div id="payment-element"></div>
  <button type="submit" id="submit-btn">Save</button>
  <div id="error-msg" data-testid="error" style="color:red"></div>
  <div id="success-msg" data-testid="success" style="color:green"></div>
  <div id="pm-id" data-testid="pm-id"></div>
</form>
<script>
const stripe = Stripe(window.PK_LIVE);
const elements = stripe.elements({ clientSecret: window.CLIENT_SECRET });
elements.create('payment').mount('#payment-element');
document.getElementById('payment-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  document.getElementById('submit-btn').disabled = true;
  const result = await stripe.confirmSetup({
    elements,
    confirmParams: { return_url: 'http://localhost:${PORT}/done.html' },
    redirect: 'if_required'
  });
  if (result.error) {
    document.getElementById('error-msg').innerText = result.error.message || JSON.stringify(result.error);
  } else {
    const pmId = result.setupIntent && result.setupIntent.payment_method;
    document.getElementById('success-msg').innerText = 'OK ' + (result.setupIntent && result.setupIntent.status);
    document.getElementById('pm-id').innerText = pmId || '';
  }
  document.getElementById('submit-btn').disabled = false;
});
</script>
</body></html>`;

// Local HTTP server so Stripe.js loads on a real origin (it warns but works
// over plain HTTP for non-production keys; for live keys it works on localhost).
const server = http.createServer((req, res) => {
	if (req.url.startsWith('/done')) {
		res.writeHead(200, { 'Content-Type': 'text/html' });
		res.end('<html><body data-testid="done">DONE</body></html>');
	} else {
		res.writeHead(200, { 'Content-Type': 'text/html' });
		const injected = HTML_TEMPLATE.replace(
			'<script src="https://js.stripe.com/v3/"></script>',
			`<script src="https://js.stripe.com/v3/"></script>\n<script>window.PK_LIVE=${JSON.stringify(PK_LIVE)};window.CLIENT_SECRET=${JSON.stringify(CLIENT_SECRET)};</script>`
		);
		res.end(injected);
	}
});
await new Promise((r) => server.listen(PORT, '127.0.0.1', r));

async function shot(p, name) {
	await p.screenshot({ path: `${SCREENSHOT_DIR}/${Date.now()}_${name}.png`, fullPage: true });
}

const browser = await chromium.launch({ headless: HEADLESS });
const ctx = await browser.newContext();
const page = await ctx.newPage();
page.setDefaultTimeout(TIMEOUT_MS);

let result = { ok: false };
try {
	await page.goto(`http://127.0.0.1:${PORT}/`);
	await page.waitForTimeout(3000);
	await shot(page, '01_loaded');

	// Wait for Stripe Elements iframe to mount.
	await page.waitForFunction(() => document.querySelectorAll('iframe').length > 0, null, {
		timeout: 15000
	});
	const elementsFrame = page.frames().find((f) =>
		f.url().includes('elements-inner-payment')
	);
	if (!elementsFrame) {
		const urls = page.frames().map((f) => f.url().substring(0, 80));
		throw new Error(`no elements-inner-payment iframe; frames: ${urls.join(' | ')}`);
	}
	await page.waitForTimeout(1500);

	// Stripe Elements bind validation to keystroke events, so fill() (which
	// sets .value directly) leaves the submit button disabled. pressSequentially
	// simulates real keypresses.
	const numberInput = elementsFrame
		.locator('#Field-numberInput, input[name="number"]')
		.first();
	await numberInput.click();
	await numberInput.pressSequentially(CARD_NUMBER, { delay: 20 });

	const expInput = elementsFrame
		.locator('#Field-expiryInput, input[name="expiry"]')
		.first();
	await expInput.click();
	await expInput.pressSequentially(CARD_EXP.replace('/', ''), { delay: 20 });

	const cvcInput = elementsFrame
		.locator('#Field-cvcInput, input[name="cvc"]')
		.first();
	await cvcInput.click();
	await cvcInput.pressSequentially(CARD_CVC, { delay: 20 });

	const zipInput = elementsFrame
		.locator('#Field-postalCodeInput, input[name="postalCode"]')
		.first();
	if (await zipInput.count()) {
		await zipInput.click();
		await zipInput.pressSequentially(CARD_ZIP, { delay: 20 });
		await zipInput.press('Tab');
	}

	// Disable Stripe Link if its opt-in checkbox appeared (it auto-checks
	// after card validation; submitting with it checked requires an SMS-deliverable
	// phone number which we don't have for headless ops use).
	const linkOptIn = elementsFrame
		.locator('#payment-linkOptInInput, input[name="linkOptIn"]')
		.first();
	if ((await linkOptIn.count()) && (await linkOptIn.isChecked())) {
		await linkOptIn.uncheck();
		await page.waitForTimeout(300);
	}

	await page.waitForTimeout(800);
	await shot(page, '02_form_filled');

	await page.click('#submit-btn');
	await page.waitForTimeout(8000);
	await shot(page, '03_after_submit');

	const errMsg = await page.locator('[data-testid="error"]').innerText().catch(() => '');
	const successMsg = await page.locator('[data-testid="success"]').innerText().catch(() => '');
	const pmId = await page.locator('[data-testid="pm-id"]').innerText().catch(() => '');
	if (successMsg) {
		result = { ok: true, status: successMsg, pm_id: pmId };
	} else if (errMsg) {
		result = { ok: false, error: errMsg };
	} else {
		result = { ok: false, error: 'no success or error message detected' };
	}
} catch (err) {
	result = { ok: false, error: err.message };
	await shot(page, 'ERROR');
} finally {
	await browser.close();
	server.close();
}

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
