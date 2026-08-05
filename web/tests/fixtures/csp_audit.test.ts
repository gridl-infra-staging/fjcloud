import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Page, Response } from '@playwright/test';
import { installCspAudit } from './csp_audit';

function createDelayedCollectorPage(responses: Response[]): {
	page: Page;
	dispatchViolation: () => void;
	releaseCollectorDelivery: () => void;
} {
	let releaseCollectorDelivery: (() => void) | undefined;
	let currentListeners = new Map<string, (event: Event) => void>();
	let currentWindow: Window & Record<string, unknown>;
	let initScript: ((arg: unknown) => void) | undefined;
	let initScriptArg: unknown;
	let responseIndex = 0;
	let exposedCollector: ((violation: unknown) => Promise<void>) | undefined;
	const replaceDocument = (pathname: string) => {
		currentListeners = new Map<string, (event: Event) => void>();
		currentWindow = {
			location: { pathname },
			addEventListener: (eventName: string, listener: (event: Event) => void) => {
				currentListeners.set(eventName, listener);
			}
		} as unknown as Window & Record<string, unknown>;
		if (exposedCollector) {
			currentWindow.__fjcloudCollectCspViolation = exposedCollector;
		}
		vi.stubGlobal('window', currentWindow);
		initScript?.(initScriptArg);
	};
	replaceDocument('/');
	const page = {
		exposeFunction: vi.fn(async (_name: string, callback: (violation: unknown) => void) => {
			exposedCollector = (violation: unknown) =>
				new Promise<void>((resolve) => {
					releaseCollectorDelivery = () => {
						callback(violation);
						resolve();
					};
				});
		}),
		addInitScript: vi.fn(async (script: (arg: unknown) => void, arg: unknown) => {
			initScript = script;
			initScriptArg = arg;
		}),
		goto: vi.fn(async (routeLabel: string) => {
			replaceDocument(routeLabel);
			const response = responses[responseIndex];
			responseIndex += 1;
			return response;
		}),
		evaluate: vi.fn(async (script: (arg: unknown) => Promise<void>, arg: unknown) => script(arg))
	} as unknown as Page;

	return {
		page,
		dispatchViolation() {
			const violationEvent = Object.assign(new Event('securitypolicyviolation'), {
				effectiveDirective: 'img-src',
				blockedURI: 'https://late.example/image.png',
				disposition: 'enforce'
			});
			currentListeners.get('securitypolicyviolation')?.(violationEvent);
		},
		releaseCollectorDelivery() {
			if (!releaseCollectorDelivery) {
				throw new Error('No pending CSP collector delivery');
			}
			releaseCollectorDelivery();
		}
	};
}

describe('CSP audit fixture', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it('keeps exact violations across documents and counts required route responses', async () => {
		let collectViolation: ((violation: unknown) => void) | undefined;
		const signupResponse = { url: () => 'http://localhost/signup' } as Response;
		const page = {
			exposeFunction: vi.fn(async (_name: string, callback: (violation: unknown) => void) => {
				collectViolation = callback;
			}),
			addInitScript: vi.fn(async () => undefined),
			goto: vi.fn(async () => signupResponse),
			evaluate: vi.fn(async () => undefined)
		} as unknown as Page;
		const audit = await installCspAudit(page);

		expect(await audit.navigate('/signup')).toBe(signupResponse);
		collectViolation?.({
			directive: 'script-src-elem',
			blockedUrl: 'https://unexpected.example/script.js',
			disposition: 'report',
			routeLabel: '/signup'
		});

		expect(await audit.result()).toEqual({
			violations: [
				{
					directive: 'script-src-elem',
					blockedUrl: 'https://unexpected.example/script.js',
					disposition: 'report',
					routeLabel: '/signup'
				}
			],
			routeDenominators: {
				'/signup': 1,
				'/console': 0,
				'/console/billing': 0
			}
		});
		expect(page.exposeFunction).toHaveBeenCalledOnce();
		expect(page.addInitScript).toHaveBeenCalledOnce();
	});

	it('rejects a required-route denominator when navigation resolves to another document', async () => {
		const loginResponse = { url: () => 'http://localhost/login' } as Response;
		const page = {
			exposeFunction: vi.fn(async () => undefined),
			addInitScript: vi.fn(async () => undefined),
			goto: vi.fn(async () => loginResponse),
			evaluate: vi.fn(async () => undefined)
		} as unknown as Page;
		const audit = await installCspAudit(page);

		await expect(audit.navigate('/console')).rejects.toThrow(
			'CSP audit navigation to /console resolved to /login'
		);
	});

	it('drains delayed collector delivery before replacing the audited document', async () => {
		const signupResponse = { url: () => 'http://localhost/signup' } as Response;
		const consoleResponse = { url: () => 'http://localhost/console' } as Response;
		const { page, dispatchViolation, releaseCollectorDelivery } = createDelayedCollectorPage([
			signupResponse,
			consoleResponse
		]);
		const audit = await installCspAudit(page);

		await audit.navigate('/signup');
		dispatchViolation();
		const consoleNavigation = audit.navigate('/console');
		let navigationSettled = false;
		void consoleNavigation.then(() => {
			navigationSettled = true;
		});
		await Promise.resolve();
		expect(navigationSettled).toBe(false);
		expect(page.goto).toHaveBeenCalledOnce();
		releaseCollectorDelivery();
		await expect(consoleNavigation).resolves.toBe(consoleResponse);

		await expect(audit.result()).resolves.toEqual({
			violations: [
				{
					directive: 'img-src',
					blockedUrl: 'https://late.example/image.png',
					disposition: 'enforce',
					routeLabel: '/signup'
				}
			],
			routeDenominators: {
				'/signup': 1,
				'/console': 1,
				'/console/billing': 0
			}
		});
		expect(page.evaluate).toHaveBeenCalledTimes(3);
	});

	it('rejects zero-violation results after audited navigation when browser instrumentation is absent', async () => {
		const signupResponse = { url: () => 'http://localhost/signup' } as Response;
		const page = {
			exposeFunction: vi.fn(async () => undefined),
			addInitScript: vi.fn(async () => undefined),
			goto: vi.fn(async () => signupResponse),
			evaluate: vi.fn(async (script: (arg: unknown) => Promise<void>, arg: unknown) => {
				vi.stubGlobal('window', {
					location: { pathname: '/signup' }
				});
				await script(arg);
			})
		} as unknown as Page;
		const audit = await installCspAudit(page);

		await expect(audit.flushPendingViolations()).resolves.toBeUndefined();
		await expect(audit.navigate('/signup')).resolves.toBe(signupResponse);
		await expect(audit.result()).rejects.toThrow(
			'CSP audit browser instrumentation is missing after audited navigation'
		);
	});
});
