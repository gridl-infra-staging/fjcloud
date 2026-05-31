import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const STAGING_PUBLISHABLE_PARAM = "/fjcloud/staging/stripe_publishable_key";
const STAGING_SECRET_PARAM = "/fjcloud/staging/stripe_secret_key";
const LOCAL_STRIPE_ROLLBACK_PATH =
	".secret/local_only_stage1_stripe_rollback_20260502T013922Z.env";
const STAGE0_FRAMES_PATH = "chatting/20260531T173200Z_stage0_diagnostic/frames.json";

function hasPrefix(value, prefixes) {
	return typeof value === "string" && prefixes.some((prefix) => value.startsWith(prefix));
}

function maybeReadStagingKeyFromSsm(paramName) {
	try {
		const value = execFileSync(
			"aws",
			[
				"ssm",
				"get-parameter",
				"--name",
				paramName,
				"--with-decryption",
				"--query",
				"Parameter.Value",
				"--output",
				"text"
			],
			{ encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }
		).trim();
		return value;
	} catch {
		return "";
	}
}

function maybeReadStagingKeyFromRollbackFile(paramName) {
	try {
		const text = readFileSync(LOCAL_STRIPE_ROLLBACK_PATH, "utf8");
		for (const line of text.split("\n")) {
			if (!line.startsWith(`${paramName}=`)) {
				continue;
			}
			return line.slice(paramName.length + 1).trim();
		}
		return "";
	} catch {
		return "";
	}
}

function maybeReadStage0PublishableKey() {
	try {
		const frames = JSON.parse(readFileSync(STAGE0_FRAMES_PATH, "utf8"));
		for (const frame of frames) {
			const html = String(frame?.html_head || "");
			const windowPk = html.match(/window\\.PK_LIVE=\"(pk_test_[A-Za-z0-9]+)\"/);
			if (windowPk) {
				return windowPk[1];
			}
			const urlPk = String(frame?.url || "").match(/(?:apiKey|publishableKey)=?(pk_test_[A-Za-z0-9]+)/);
			if (urlPk) {
				return urlPk[1];
			}
		}
		return "";
	} catch {
		return "";
	}
}

function resolveStripeTestCredentials() {
	let publishableKey =
		process.env.STRIPE_TEST_PUBLISHABLE_KEY ||
		process.env.STRIPE_PUBLISHABLE_KEY ||
		"";
	let secretKey =
		process.env.STRIPE_TEST_SECRET_KEY ||
		process.env.STRIPE_SECRET_KEY ||
		"";

	if (!hasPrefix(publishableKey, ["pk_test_"])) {
		const stage0Publishable = maybeReadStage0PublishableKey();
		if (hasPrefix(stage0Publishable, ["pk_test_"])) {
			publishableKey = stage0Publishable;
		}
	}

	if (!hasPrefix(publishableKey, ["pk_test_"])) {
		const rollbackPublishable = maybeReadStagingKeyFromRollbackFile(STAGING_PUBLISHABLE_PARAM);
		if (hasPrefix(rollbackPublishable, ["pk_test_"])) {
			publishableKey = rollbackPublishable;
		}
	}

	if (!hasPrefix(secretKey, ["sk_test_", "rk_test_"])) {
		const rollbackSecret = maybeReadStagingKeyFromRollbackFile(STAGING_SECRET_PARAM);
		if (hasPrefix(rollbackSecret, ["sk_test_", "rk_test_"])) {
			secretKey = rollbackSecret;
		}
	}

	if (!hasPrefix(publishableKey, ["pk_test_"]) || !hasPrefix(secretKey, ["sk_test_", "rk_test_"])) {
		const stagedPublishable = maybeReadStagingKeyFromSsm(STAGING_PUBLISHABLE_PARAM);
		const stagedSecret = maybeReadStagingKeyFromSsm(STAGING_SECRET_PARAM);
		if (hasPrefix(stagedPublishable, ["pk_test_"])) {
			publishableKey = stagedPublishable;
		}
		if (hasPrefix(stagedSecret, ["sk_test_", "rk_test_"])) {
			secretKey = stagedSecret;
		}
	}

	assert.ok(
		hasPrefix(publishableKey, ["pk_test_"]),
		"attach_card_via_setup_intent_test requires a pk_test_ publishable key (set STRIPE_TEST_PUBLISHABLE_KEY or configure /fjcloud/staging/stripe_publishable_key)"
	);
	assert.ok(
		hasPrefix(secretKey, ["sk_test_", "rk_test_"]),
		"attach_card_via_setup_intent_test requires an sk_test_/rk_test_ secret key (set STRIPE_TEST_SECRET_KEY or configure /fjcloud/staging/stripe_secret_key)"
	);

	return { publishableKey, secretKey };
}

function stripeBasicAuth(secretKey) {
	return `Basic ${Buffer.from(`${secretKey}:`).toString("base64")}`;
}

async function stripePost(secretKey, path, formFields) {
	const response = await fetch(`https://api.stripe.com/v1/${path}`, {
		method: "POST",
		headers: {
			Authorization: stripeBasicAuth(secretKey),
			"Content-Type": "application/x-www-form-urlencoded"
		},
		body: new URLSearchParams(formFields)
	});
	const payload = await response.json();
	if (!response.ok) {
		throw new Error(`Stripe ${path} failed with HTTP ${response.status}: ${JSON.stringify(payload)}`);
	}
	return payload;
}

async function stripeDelete(secretKey, customerId) {
	await fetch(`https://api.stripe.com/v1/customers/${customerId}`, {
		method: "DELETE",
		headers: { Authorization: stripeBasicAuth(secretKey) }
	});
}

test("attach_card_via_setup_intent exits 0 and returns pm_id on Stripe test mode", async () => {
	const { publishableKey, secretKey } = resolveStripeTestCredentials();
	const nonce = `${Date.now()}-${process.pid}`;
	const customer = await stripePost(secretKey, "customers", {
		description: `stage2-attach-card-test-${nonce}`
	});
	assert.match(customer.id || "", /^cus_/, "customer creation should return a Stripe customer id");

	try {
		const setupIntent = await stripePost(secretKey, "setup_intents", {
			customer: customer.id,
			"payment_method_types[]": "card",
			usage: "off_session"
		});
		assert.match(setupIntent.client_secret || "", /^seti_/, "setup intent should include a client secret");

		const screenshotDir = mkdtempSync(join(tmpdir(), "attach-card-setup-intent-"));
		const run = spawnSync("node", ["scripts/stripe/attach_card_via_setup_intent.mjs"], {
			env: {
				...process.env,
				PK_LIVE: publishableKey,
				CLIENT_SECRET: setupIntent.client_secret,
				CARD_NUMBER: "4242424242424242",
				CARD_EXP: "1230",
				CARD_CVC: "123",
				CARD_ZIP: "10001",
				HEADLESS: "1",
				TIMEOUT_MS: "45000",
				PORT: String(9500 + (process.pid % 400)),
				SCREENSHOT_DIR: screenshotDir
			},
			encoding: "utf8",
			timeout: 120000
		});

		assert.equal(run.status, 0, `attach script should exit 0\nstdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
		let payload;
		try {
			payload = JSON.parse(run.stdout);
		} catch (error) {
			assert.fail(`attach script stdout must be valid JSON: ${error.message}\nstdout:\n${run.stdout}`);
		}
		assert.equal(payload.ok, true, `attach script payload should report ok=true: ${run.stdout}`);
		assert.match(payload.pm_id || "", /^pm_/, `attach script payload pm_id should be Stripe pm_*: ${run.stdout}`);
	} finally {
		await stripeDelete(secretKey, customer.id);
	}
});
