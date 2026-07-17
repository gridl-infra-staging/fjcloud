#!/usr/bin/env node
// Attach a card to a Stripe customer via a SetupIntent + Stripe.js Elements
// driven through Playwright. This is the same flow our /console/billing/setup
// page uses for real customers, run against a local HTML page so we don't
// depend on having an authenticated fjcloud session.
//
// Bypasses Stripe's hosted billing portal (which gates fraud-flagged sessions
// behind hCaptcha image puzzles that we can't auto-solve). The SetupIntent
// flow uses pure Stripe.js Elements and does not trigger hCaptcha.
//
// Originally built 2026-05-03 for the Phase G live invoice probe to attach
// a card via SetupIntent on the live Stripe account.
// Kept as a reusable ops-layer helper for future card-attach scenarios:
//   - Replacement card for an existing customer
//   - Synthetic test customer setup against live mode for ops probes
//   - Disaster recovery rehearsals where we need a known-good PM on file
//
// Usage:
//   set -a; source .secret/.env.secret; set +a
//   PK_LIVE="$STRIPE_PUBLISHABLE_KEY" \
//   CLIENT_SECRET=seti_...secret_... \
//   CARD_NUMBER=4242424242424242 \
//   CARD_EXP=12/30 \
//   CARD_CVC=123 \
//   CARD_ZIP=10001 \
//   node scripts/stripe/attach_card_via_setup_intent.mjs
//
// Do not commit live card numbers, CVCs, or customer identifiers here. Supply
// real values only via environment variables at runtime.
//
// To create the SetupIntent first:
//   curl -u "$STRIPE_SECRET_KEY_flapjack_cloud:" \
//     -X POST https://api.stripe.com/v1/setup_intents \
//     -d customer=<cus_xxx> -d "payment_method_types[]=card" -d usage=off_session
//
// Required env: PK_LIVE, CLIENT_SECRET, CARD_NUMBER, CARD_EXP, CARD_CVC.
// Optional: CARD_ZIP (default 10001), HEADLESS (default 1), TIMEOUT_MS (default 60000),
//           SCREENSHOT_DIR (unset by default; enables diagnostic screenshots when set),
//           PORT (default 8765).
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
const SCREENSHOT_DIR = process.env.SCREENSHOT_DIR || '';
const PORT = Number(process.env.PORT || '8765');

if (SCREENSHOT_DIR) {
	await fs.mkdir(SCREENSHOT_DIR, { recursive: true, mode: 0o700 });
	await fs.chmod(SCREENSHOT_DIR, 0o700).catch(() => {});
}

// Inline the minimal HTML page to avoid an extra file. Stripe.js loads from
// the CDN, mounts Elements, and confirms the SetupIntent on form submit.
// All result data is exposed on the parent page via data-testid attributes
// so the Playwright driver can read them without needing to await navigation.
//
// Uses the legacy CardElement (not PaymentElement) deliberately: PaymentElement
// mounts Stripe Link which triggers an hCaptcha image puzzle on submission in
// headless environments. CardElement has no Link, no wallet prompts, and no
// fraud-detection hCaptcha gate. Confirmed broken on 2026-05-05 when Phase G
// flow (May 3rd) stopped working due to Stripe adding Link hCaptcha.
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
// CardElement — no clientSecret needed at elements() level; confirmCardSetup takes it directly.
const elements = stripe.elements();
const card = elements.create('card');
card.mount('#payment-element');
document.getElementById('payment-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  document.getElementById('submit-btn').disabled = true;
  const result = await stripe.confirmCardSetup(window.CLIENT_SECRET, {
    payment_method: { card }
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
	if (!SCREENSHOT_DIR) {
		return;
	}
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
	// DIAGNOSTIC_INJECTED_2026_05_31
		const captureDiagnosticEvidence = async (label) => {
			if (!SCREENSHOT_DIR) {
				return;
			}
			const ts = new Date().toISOString().replace(/[:.]/g, '-');
			const dir = `${SCREENSHOT_DIR}/diagnostic_${ts}_${label}`;
			await fs.mkdir(dir, { recursive: true, mode: 0o700 });
			await fs.chmod(dir, 0o700).catch(() => {});
			await page.screenshot({ path: `${dir}/full.png`, fullPage: true });
		const frames = [];
		for (const frame of page.frames()) {
			let html = '';
			try {
				html = await frame.content();
			} catch {
				html = '<frame-error>';
			}
			frames.push({
				url: frame.url(),
				name: frame.name(),
				html_len: html.length,
				html_head: html.slice(0, 4000)
			});
		}
		await fs.writeFile(`${dir}/frames.json`, JSON.stringify(frames, null, 2));
		console.error(`DIAGNOSTIC: wrote ${dir} (${frames.length} frames)`);
	};
	const resolveCardElementsFrame = () => {
		const frames = page.frames();
		const frameMatchers = [
			(frame) => frame.url().includes('elements-inner-card'),
			(frame) =>
				frame.url().includes('componentName=card') &&
				frame.url().includes('js.stripe.com/v3/') &&
				!frame.url().includes('elements-inner-link-button'),
			(frame) =>
				frame.name().startsWith('__privateStripeFrame') &&
				frame.url().includes('js.stripe.com/v3/') &&
				!frame.url().includes('elements-inner-link-button')
		];
		for (const matcher of frameMatchers) {
			const match = frames.find((frame) => matcher(frame));
			if (match) {
				console.error(`[selector-match] frame: ${match.url().slice(0, 140)}`);
				return match;
			}
		}
		return null;
	};
	const resolveFieldLocator = async (frame, label, selectors, optional = false) => {
		for (const selector of selectors) {
			const locator = frame.locator(selector).first();
			if ((await locator.count()) > 0) {
				console.error(`[selector-match] ${label}: ${selector}`);
				return locator;
			}
		}
		if (optional) {
			console.error(`[selector-miss-optional] ${label}`);
			return null;
		}
		throw new Error(`no ${label} selector matched in card frame: ${selectors.join(' | ')}`);
	};
	const elementsFrame = resolveCardElementsFrame();
	if (!elementsFrame) {
		const urls = page.frames().map((f) => f.url().substring(0, 80));
		await captureDiagnosticEvidence('no_elements_inner_card_iframe');
		throw new Error(`no elements-inner-card iframe; frames: ${urls.join(' | ')}`);
	}
	await page.waitForTimeout(1500);

	// Stripe Elements bind validation to keystroke events, so fill() (which
	// sets .value directly) leaves the submit button disabled. pressSequentially
	// simulates real keypresses.
	const numberInput = await resolveFieldLocator(elementsFrame, 'number', [
		'#Field-numberInput',
		'input[name="number"]',
		'input[name="cardnumber"]',
		'input[autocomplete="cc-number"]',
		'input[aria-label*="card number" i]',
		'input[placeholder*="card number" i]',
		'input[id^="Field-"][id*="number"]'
	]);
	try {
		await numberInput.click();
	} catch (err) {
		await captureDiagnosticEvidence('numberinput_click_failed');
		throw err;
	}
	await numberInput.pressSequentially(CARD_NUMBER, { delay: 20 });

	const expInput = await resolveFieldLocator(elementsFrame, 'expiry', [
		'#Field-expiryInput',
		'input[name="expiry"]',
		'input[name="exp-date"]',
		'input[autocomplete="cc-exp"]',
		'input[aria-label*="expiration" i]',
		'input[aria-label*="expiry" i]',
		'input[placeholder*="MM / YY" i]',
		'input[id^="Field-"][id*="expiry"]'
	]);
	await expInput.click();
	await expInput.pressSequentially(CARD_EXP.replace('/', ''), { delay: 20 });

	const cvcInput = await resolveFieldLocator(elementsFrame, 'cvc', [
		'#Field-cvcInput',
		'input[name="cvc"]',
		'input[name="securityCode"]',
		'input[autocomplete="cc-csc"]',
		'input[aria-label*="cvc" i]',
		'input[aria-label*="security code" i]',
		'input[placeholder*="CVC" i]',
		'input[id^="Field-"][id*="cvc"]'
	]);
	await cvcInput.click();
	await cvcInput.pressSequentially(CARD_CVC, { delay: 20 });

	const zipInput = await resolveFieldLocator(
		elementsFrame,
		'postal',
		[
			'#Field-postalCodeInput',
			'input[name="postalCode"]',
			'input[name="postal-code"]',
			'input[autocomplete="postal-code"]',
			'input[aria-label*="postal" i]',
			'input[placeholder*="ZIP" i]',
			'input[id^="Field-"][id*="postal"]'
		],
		true
	);
	if (zipInput) {
		await zipInput.click();
		await zipInput.pressSequentially(CARD_ZIP, { delay: 20 });
		await zipInput.press('Tab');
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
