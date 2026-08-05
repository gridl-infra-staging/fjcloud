import type { Page, Response } from '@playwright/test';

export const CSP_AUDIT_ROUTE_LABELS = ['/signup', '/console', '/console/billing'] as const;

export type CspAuditRouteLabel = (typeof CSP_AUDIT_ROUTE_LABELS)[number];

export type CapturedCspViolation = {
	directive: string;
	blockedUrl: string;
	disposition: 'enforce' | 'report';
	routeLabel: CspAuditRouteLabel;
};

export type CspAuditResult = {
	violations: CapturedCspViolation[];
	routeDenominators: Record<CspAuditRouteLabel, number>;
};

export type CspAudit = {
	flushPendingViolations(): Promise<void>;
	navigate(routeLabel: CspAuditRouteLabel): Promise<Response>;
	result(): Promise<CspAuditResult>;
};

const CSP_VIOLATION_COLLECTOR = '__fjcloudCollectCspViolation';
const CSP_VIOLATION_DELIVERY_WAITER = '__fjcloudWaitForCspViolationDelivery';
const CSP_VIOLATION_LISTENER_READY = '__fjcloudCspViolationListenerReady';
const CSP_AUDIT_ROUTE_LABEL_SET = new Set<string>(CSP_AUDIT_ROUTE_LABELS);
const MISSING_CSP_INSTRUMENTATION_ERROR =
	'CSP audit browser instrumentation is missing after audited navigation';

function isCapturedCspViolation(value: unknown): value is CapturedCspViolation {
	if (!value || typeof value !== 'object') return false;
	const candidate = value as Record<string, unknown>;
	return (
		typeof candidate.directive === 'string' &&
		typeof candidate.blockedUrl === 'string' &&
		(candidate.disposition === 'enforce' || candidate.disposition === 'report') &&
		typeof candidate.routeLabel === 'string' &&
		CSP_AUDIT_ROUTE_LABEL_SET.has(candidate.routeLabel)
	);
}

function emptyRouteDenominators(): Record<CspAuditRouteLabel, number> {
	return {
		'/signup': 0,
		'/console': 0,
		'/console/billing': 0
	};
}

function auditedRouteCount(routeDenominators: Record<CspAuditRouteLabel, number>): number {
	return CSP_AUDIT_ROUTE_LABELS.reduce(
		(total, routeLabel) => total + routeDenominators[routeLabel],
		0
	);
}

async function waitForCspViolationDelivery(
	page: Page,
	requireInstrumentation: boolean
): Promise<void> {
	await page.evaluate(
		async ({ waiterName, listenerReadyName, requireInstrumentation, errorMessage }) => {
			const browserBindings = window as unknown as Record<string, unknown>;
			const waitForDelivery = browserBindings[waiterName] as (() => Promise<void>) | undefined;
			if (!waitForDelivery) {
				if (requireInstrumentation) {
					throw new Error(errorMessage);
				}
				return;
			}

			await waitForDelivery();
			if (requireInstrumentation && browserBindings[listenerReadyName] !== true) {
				throw new Error(errorMessage);
			}
		},
		{
			waiterName: CSP_VIOLATION_DELIVERY_WAITER,
			listenerReadyName: CSP_VIOLATION_LISTENER_READY,
			requireInstrumentation,
			errorMessage: MISSING_CSP_INSTRUMENTATION_ERROR
		}
	);
}

export async function installCspAudit(page: Page): Promise<CspAudit> {
	const violations: CapturedCspViolation[] = [];
	const routeDenominators = emptyRouteDenominators();

	await page.exposeFunction(CSP_VIOLATION_COLLECTOR, (violation: unknown) => {
		if (isCapturedCspViolation(violation)) {
			violations.push(violation);
		}
	});
	await page.addInitScript(
		({ collectorName, waiterName, listenerReadyName }) => {
			const browserBindings = window as unknown as Record<string, unknown>;
			const pendingDeliveries = new Set<Promise<unknown>>();
			browserBindings[listenerReadyName] = false;
			browserBindings[waiterName] = async () => {
				while (pendingDeliveries.size > 0) {
					await Promise.allSettled([...pendingDeliveries]);
				}
			};
			window.addEventListener('securitypolicyviolation', (event) => {
				const collect = browserBindings[collectorName] as (value: unknown) => Promise<unknown>;
				const delivery = collect({
					directive: event.effectiveDirective,
					blockedUrl: event.blockedURI,
					disposition: event.disposition,
					routeLabel: window.location.pathname
				});
				pendingDeliveries.add(delivery);
				void delivery.then(
					() => pendingDeliveries.delete(delivery),
					() => pendingDeliveries.delete(delivery)
				);
			});
			browserBindings[listenerReadyName] = true;
		},
		{
			collectorName: CSP_VIOLATION_COLLECTOR,
			waiterName: CSP_VIOLATION_DELIVERY_WAITER,
			listenerReadyName: CSP_VIOLATION_LISTENER_READY
		}
	);

	return {
		async flushPendingViolations() {
			await waitForCspViolationDelivery(page, auditedRouteCount(routeDenominators) > 0);
		},
		async navigate(routeLabel) {
			await waitForCspViolationDelivery(page, auditedRouteCount(routeDenominators) > 0);
			const response = await page.goto(routeLabel);
			if (!response) {
				throw new Error(`CSP audit navigation to ${routeLabel} returned no document response`);
			}
			const responsePathname = new URL(response.url()).pathname;
			if (responsePathname !== routeLabel) {
				throw new Error(`CSP audit navigation to ${routeLabel} resolved to ${responsePathname}`);
			}
			routeDenominators[routeLabel] += 1;
			return response;
		},
		async result() {
			await waitForCspViolationDelivery(page, auditedRouteCount(routeDenominators) > 0);
			return {
				violations: violations.map((violation) => ({ ...violation })),
				routeDenominators: { ...routeDenominators }
			};
		}
	};
}
