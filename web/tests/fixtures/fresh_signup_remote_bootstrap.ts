import { expect, type Page } from '@playwright/test';
import { AUTH_COOKIE } from '../../src/lib/server/auth-session-contracts';
import {
	DEFAULT_PLAYWRIGHT_BASE_URL,
	REMOTE_TARGET_OPT_IN_ENV
} from '../../playwright.config.contract';

type CreateUserWithTokenFn = (
	email: string,
	password: string,
	name?: string
) => Promise<{ token: string }>;

type AttemptRemoteSignupFallbackParams = {
	page: Page;
	email: string;
	password: string;
	name: string;
	createUser: CreateUserWithTokenFn;
	remoteTargetOptInEnv?: string;
};

export function isRemoteTargetMode(remoteTargetOptInEnv = REMOTE_TARGET_OPT_IN_ENV): boolean {
	return process.env[remoteTargetOptInEnv] === '1';
}

function getFixtureBaseUrl(): string {
	return process.env.BASE_URL?.trim() || DEFAULT_PLAYWRIGHT_BASE_URL;
}

export async function setAuthCookieForToken(page: Page, token: string): Promise<void> {
	const baseUrl = getFixtureBaseUrl();
	const baseUrlProtocol = new URL(baseUrl).protocol;
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: baseUrl,
			httpOnly: true,
			secure: baseUrlProtocol === 'https:',
			sameSite: 'Lax'
		}
	]);
}

export async function attemptRemoteSignupFallback({
	page,
	email,
	password,
	name,
	createUser,
	remoteTargetOptInEnv
}: AttemptRemoteSignupFallbackParams): Promise<boolean> {
	if (!isRemoteTargetMode(remoteTargetOptInEnv)) {
		return false;
	}

	const created = await createUser(email, password, name);
	await setAuthCookieForToken(page, created.token);
	await page.goto('/dashboard');
	await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
	return true;
}
