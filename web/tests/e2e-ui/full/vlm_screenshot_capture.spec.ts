/**
 * VLM capture — authenticated regular-user lane (dashboard).
 *
 * Mirrors the `setAuthCookie` flow from `dashboard.spec.ts:62-71`: the
 * default `setup:user` storage state is cleared so we deterministically
 * mint a fresh user via `createUser` + `loginAs`, then set
 * `AUTH_COOKIE` on the test browser context before navigating. This is
 * the canonical auth pattern for tests that require a known-good user
 * identity per spec — we do not introduce alternate login flows.
 *
 * Each tuple's `setup` discriminator (from `vlm_capture/tuples.ts`)
 * decides whether to additionally seed an index for the fresh user
 * before navigating, so Loading/Empty/Error captures land against an
 * un-seeded account and Success captures land against a seeded one.
 *
 * Output contract: this file owns only the `auth__*` filename prefix
 * under `tmp/screens/`. On first invocation per run it ensures the
 * directory exists and removes its own prior `auth__*` artifacts so
 * stale captures cannot bleed into Stage 6, while leaving public/admin
 * lane files alone.
 *
 * File matches the default `chromium` project (excludes the `public-`
 * and `admin/` paths). Project depends on `setup:user`, but we override
 * storageState below to use the freshly-minted user instead.
 */

import fs from 'node:fs';
import path from 'node:path';
import type { BrowserContext } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';
import { assertNoCaptureRedirect } from './vlm_capture/redirect_guard';
import {
	CAPTURE_OUTPUT_DIR,
	VIEWPORT_SIZES,
	captureArtifactPath,
	captureTupleTestTitle,
	isProducibleSetup,
	tuplesForLane,
	type CaptureSetup
} from './vlm_capture/tuples';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

// Clear the setup:user storage state so the createUser+loginAs flow is
// the sole source of identity for this spec — same pattern as the
// verification-banner suite in dashboard.spec.ts.
test.use({ storageState: { cookies: [], origins: [] } });

test.beforeAll(() => {
	fs.mkdirSync(CAPTURE_OUTPUT_DIR, { recursive: true });
	for (const entry of fs.readdirSync(CAPTURE_OUTPUT_DIR)) {
		if (entry.startsWith('auth__') && entry.endsWith('.png')) {
			fs.unlinkSync(path.join(CAPTURE_OUTPUT_DIR, entry));
		}
	}
});

async function setAuthCookie(context: BrowserContext, token: string): Promise<void> {
	await context.addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
}

function shouldSeedIndexForSetup(setup: CaptureSetup): boolean {
	return setup === 'auth_fresh_user_with_index';
}

for (const tuple of tuplesForLane('auth')) {
	test(`auth capture: ${captureTupleTestTitle(tuple)}`, async ({
		page,
		createUser,
		loginAs,
		seedCustomerIndex
	}) => {
		test.skip(
			!isProducibleSetup(tuple.setup),
			`tuple setup ${tuple.setup}: see vlm_capture/tuples.ts for the gap rationale.`
		);

		const password = 'TestPassword123!';
		const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
		const email = `vlm-capture-${seed}@e2e.griddle.test`;
		const created = await createUser(email, password, `VLM Capture ${seed}`);
		const token = await loginAs(created.email, password);
		await setAuthCookie(page.context(), token);

		if (shouldSeedIndexForSetup(tuple.setup)) {
			// seedCustomerIndex uses customer.customerId for the admin-API seed
			// and customer.token for the per-test DELETE-on-cleanup hook. The
			// loginAs token is the active session token for this run; passing
			// it keeps both the seed and cleanup paths consistent.
			await seedCustomerIndex({ ...created, token }, `vlm-capture-${seed}`);
		}

		await page.setViewportSize(VIEWPORT_SIZES[tuple.viewport]);
		await page.goto(tuple.path);
		await assertNoCaptureRedirect(page, tuple.path);

		const artifactPath = captureArtifactPath(tuple);
		await page.screenshot({ path: artifactPath, fullPage: true });
		expect(fs.existsSync(artifactPath)).toBe(true);
	});
}
