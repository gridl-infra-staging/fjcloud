import '@testing-library/jest-dom/vitest';

// jsdom does not implement matchMedia; @layerstack/svelte-stores (a transitive
// dep of layerchart) calls window.matchMedia at module load even though the
// chart never renders without `browser` from $app/environment being true.
// Stub a minimal-but-spec-compliant API so importing components that use
// layerchart does not throw during component-test setup.
if (typeof window !== 'undefined' && typeof window.matchMedia !== 'function') {
	window.matchMedia = (query: string): MediaQueryList => ({
		matches: false,
		media: query,
		onchange: null,
		addListener: () => {},
		removeListener: () => {},
		addEventListener: () => {},
		removeEventListener: () => {},
		dispatchEvent: () => false
	});
}

// jsdom doesn't implement ResizeObserver; layerchart/layercake instantiates one
// to track container sizing. Stub a no-op constructor so chart mounts don't crash.
if (typeof globalThis.ResizeObserver === 'undefined') {
	globalThis.ResizeObserver = class {
		observe(): void {}
		unobserve(): void {}
		disconnect(): void {}
	} as unknown as typeof ResizeObserver;
}
