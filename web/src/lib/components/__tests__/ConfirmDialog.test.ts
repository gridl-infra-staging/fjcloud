import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { compile } from 'svelte/compiler';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { render as renderServerComponent } from 'svelte/server';
import ConfirmDialog from '../ConfirmDialog.svelte';

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (error: unknown) => void;
};

function createDeferred<T>(): Deferred<T> {
	let resolveFn: ((value: T) => void) | undefined;
	let rejectFn: ((error: unknown) => void) | undefined;
	const promise = new Promise<T>((resolve, reject) => {
		resolveFn = resolve;
		rejectFn = reject;
	});
	return {
		promise,
		resolve: (value: T) => resolveFn?.(value),
		reject: (error: unknown) => rejectFn?.(error)
	};
}

type DialogProps = {
	open: boolean;
	mode: 'standard' | 'typed';
	dangerLevel: 'warn' | 'severe';
	title: string;
	consequences: string;
	rationale: string;
	entityName: string;
	typedPhrase?: string;
	confirmLabel: string;
	cancelLabel: string;
	onConfirm: () => Promise<void> | void;
	onCancel: () => void;
	triggerRef?: HTMLElement | null;
};

function buildProps(overrides: Partial<DialogProps> = {}): DialogProps {
	return {
		open: true,
		mode: 'typed',
		dangerLevel: 'warn',
		title: 'Delete index "movies_demo"',
		consequences: 'All data in this index will be permanently deleted.',
		rationale: 'This action affects live search traffic.',
		entityName: 'movies_demo',
		confirmLabel: 'Permanently Delete',
		cancelLabel: 'Cancel',
		onConfirm: async () => {},
		onCancel: () => {},
		...overrides
	};
}

async function renderConfirmDialogSsrHtml(props: DialogProps): Promise<string> {
	const nodeRequire = createRequire(import.meta.url);
	const sourcePath = path.resolve(process.cwd(), 'src/lib/components/ConfirmDialog.svelte');
	const source = readFileSync(sourcePath, 'utf8');
	const compilation = compile(source, {
		filename: 'ConfirmDialog.svelte',
		generate: 'server'
	});
	const resolvedSsrRuntimeUrl = pathToFileURL(nodeRequire.resolve('svelte/internal/server')).href;
	const resolvedSvelteUrl = pathToFileURL(nodeRequire.resolve('svelte')).href;
	const runtimeResolvedCode = compilation.js.code
		.replaceAll("'svelte/internal/server'", `'${resolvedSsrRuntimeUrl}'`)
		.replaceAll("'svelte'", `'${resolvedSvelteUrl}'`);
	const moduleUrl = `data:text/javascript;base64,${Buffer.from(runtimeResolvedCode, 'utf8').toString('base64')}`;
	const serverModule = (await import(moduleUrl)) as { default: unknown };
	return (
		renderServerComponent as (
			component: unknown,
			options: { props: DialogProps }
		) => { body: string }
	)(serverModule.default, { props }).body;
}

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe('ConfirmDialog', () => {
	it('preserves open-state dialog markup in pre-hydration SSR output when open is true', async () => {
		const ssrBody = await renderConfirmDialogSsrHtml(
			buildProps({ open: true, mode: 'standard', dangerLevel: 'warn' })
		);

		expect(ssrBody).toMatch(
			/<dialog[^>]*\bdata-testid="confirm-dialog"[^>]*\bopen(?:=(?:""|''|open))?[^>]*>/
		);
	});

	it('uses a native dialog modal owner via showModal and close', async () => {
		const originalShowModal = HTMLDialogElement.prototype.showModal;
		const originalClose = HTMLDialogElement.prototype.close;
		const showModalSpy = vi.fn();
		const closeSpy = vi.fn();
		HTMLDialogElement.prototype.showModal = showModalSpy;
		HTMLDialogElement.prototype.close = closeSpy;

		try {
			const { rerender } = render(
				ConfirmDialog,
				buildProps({ mode: 'standard', dangerLevel: 'warn', open: false })
			);
			expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();

			rerender(buildProps({ mode: 'standard', dangerLevel: 'warn', open: true }));
			const dialog = screen.getByTestId('confirm-dialog');
			expect(dialog.tagName).toBe('DIALOG');
			await waitFor(() => {
				expect(showModalSpy).toHaveBeenCalledTimes(1);
			});

			rerender(buildProps({ mode: 'standard', dangerLevel: 'warn', open: false }));
			await waitFor(() => {
				expect(closeSpy).toHaveBeenCalledTimes(1);
			});
		} finally {
			HTMLDialogElement.prototype.showModal = originalShowModal;
			HTMLDialogElement.prototype.close = originalClose;
		}
	});

	it('keeps aria id wiring stable across repeated mount lifecycles', () => {
		render(ConfirmDialog, buildProps({ mode: 'standard' }));
		const firstDialog = screen.getByTestId('confirm-dialog');
		const firstAria = {
			labelledBy: firstDialog.getAttribute('aria-labelledby'),
			describedBy: firstDialog.getAttribute('aria-describedby')
		};
		cleanup();

		render(ConfirmDialog, buildProps({ mode: 'standard' }));
		const secondDialog = screen.getByTestId('confirm-dialog');
		const secondAria = {
			labelledBy: secondDialog.getAttribute('aria-labelledby'),
			describedBy: secondDialog.getAttribute('aria-describedby')
		};

		expect(firstAria.labelledBy).toBeTruthy();
		expect(firstAria.describedBy).toBeTruthy();
		expect(firstAria).toEqual(secondAria);
	});

	it('renders nothing when open is false', () => {
		render(ConfirmDialog, buildProps({ open: false }));

		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
	});

	it('renders standard mode without typed input and uses role dialog for warn', () => {
		render(ConfirmDialog, buildProps({ mode: 'standard', dangerLevel: 'warn' }));

		const dialog = screen.getByTestId('confirm-dialog');
		const dialogContainer = dialog.querySelector(':scope > div');

		expect(screen.getByRole('dialog')).toBeInTheDocument();
		expect(dialog).toBeInTheDocument();
		expect(dialog).toHaveClass('bg-flapjack-ink/55');
		expect(dialogContainer).not.toBeNull();
		expect(dialogContainer).toHaveClass('border-flapjack-ink/20');
		expect(screen.getByTestId('confirm-confirm-btn')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-confirm-btn')).toHaveClass('bg-flapjack-plum');
		expect(screen.getByTestId('confirm-cancel-btn')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-cancel-btn')).toHaveClass('border-flapjack-ink/30');
		expect(screen.queryByTestId('confirm-input')).not.toBeInTheDocument();
		expect(screen.queryByText('This cannot be undone.')).not.toBeInTheDocument();
	});

	it('renders typed mode, exposes required hooks, and uses alertdialog for severe', () => {
		render(ConfirmDialog, buildProps({ dangerLevel: 'severe' }));

		expect(screen.getByRole('alertdialog')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-input')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-confirm-btn')).toBeInTheDocument();
		expect(screen.getByTestId('confirm-cancel-btn')).toBeInTheDocument();
		expect(screen.getByText('This cannot be undone.')).toBeInTheDocument();
	});

	it('uses case-sensitive trimmed typed phrase matching to enable confirm', async () => {
		render(ConfirmDialog, buildProps({ typedPhrase: 'DELETE movies_demo' }));

		const input = screen.getByTestId('confirm-input');
		const confirmButton = screen.getByTestId('confirm-confirm-btn');
		expect(confirmButton).toBeDisabled();

		await fireEvent.input(input, { target: { value: ' DELETE movies_demo ' } });
		expect(confirmButton).toBeEnabled();

		await fireEvent.input(input, { target: { value: 'delete movies_demo' } });
		expect(confirmButton).toBeDisabled();
	});

	it('owns aria-labelledby and aria-describedby wiring', () => {
		render(ConfirmDialog, buildProps());

		const dialog = screen.getByTestId('confirm-dialog');
		const labelledBy = dialog.getAttribute('aria-labelledby');
		const describedBy = dialog.getAttribute('aria-describedby');
		expect(labelledBy).toBeTruthy();
		expect(describedBy).toBeTruthy();
		expect(document.getElementById(labelledBy ?? '')).toBeInTheDocument();

		const describedIds = (describedBy ?? '').split(' ').filter(Boolean);
		expect(describedIds.length).toBeGreaterThanOrEqual(1);
		for (const id of describedIds) {
			expect(document.getElementById(id)).toBeInTheDocument();
		}
	});

	it('focuses cancel by default in standard mode and typed input in typed mode', async () => {
		const { rerender } = render(ConfirmDialog, buildProps({ mode: 'standard', open: false }));

		rerender(buildProps({ mode: 'standard', open: true }));
		await waitFor(() => {
			expect(screen.getByTestId('confirm-cancel-btn')).toHaveFocus();
		});

		rerender(buildProps({ mode: 'typed', open: true }));
		await waitFor(() => {
			expect(screen.getByTestId('confirm-input')).toHaveFocus();
		});
	});

	it('supports Enter to confirm in standard mode and blocks Enter in typed mode mismatch', async () => {
		const standardConfirm = vi.fn(async () => {});
		const { rerender } = render(
			ConfirmDialog,
			buildProps({ mode: 'standard', onConfirm: standardConfirm })
		);

		await waitFor(() => {
			expect(screen.getByTestId('confirm-cancel-btn')).toHaveFocus();
		});
		await fireEvent.keyDown(screen.getByTestId('confirm-cancel-btn'), { key: 'Enter' });
		expect(standardConfirm).toHaveBeenCalledTimes(0);

		await fireEvent.keyDown(screen.getByTestId('confirm-dialog'), { key: 'Enter' });
		expect(standardConfirm).toHaveBeenCalledTimes(1);

		const typedConfirm = vi.fn(async () => {});
		rerender(buildProps({ mode: 'typed', onConfirm: typedConfirm }));

		const input = screen.getByTestId('confirm-input');
		await fireEvent.input(input, { target: { value: 'wrong' } });
		await fireEvent.keyDown(input, { key: 'Enter' });
		expect(typedConfirm).not.toHaveBeenCalled();

		await fireEvent.input(input, { target: { value: 'movies_demo' } });
		await fireEvent.keyDown(input, { key: 'Enter' });
		expect(typedConfirm).toHaveBeenCalledTimes(1);
	});

	it('moves focus to a focusable fallback when triggerRef is removed before close', async () => {
		const triggerButton = document.createElement('button');
		triggerButton.type = 'button';
		document.body.appendChild(triggerButton);

		const fallbackMain = document.createElement('main');
		fallbackMain.setAttribute('role', 'main');
		document.body.appendChild(fallbackMain);

		const { rerender } = render(
			ConfirmDialog,
			buildProps({ mode: 'standard', open: true, triggerRef: triggerButton })
		);

		triggerButton.remove();
		rerender(buildProps({ mode: 'standard', open: false, triggerRef: triggerButton }));

		await waitFor(() => {
			expect(document.activeElement).toBe(fallbackMain);
		});

		fallbackMain.remove();
	});

	it('falls back to the stable container when a still-mounted triggerRef cannot receive focus', async () => {
		// A disabled trigger stays in the DOM but is unfocusable: .focus() is a no-op,
		// so return-focus must continue into the stable-container fallback rather than
		// leaving focus stranded on <body>.
		const disabledTrigger = document.createElement('button');
		disabledTrigger.type = 'button';
		disabledTrigger.disabled = true;
		document.body.appendChild(disabledTrigger);

		const fallbackMain = document.createElement('main');
		fallbackMain.setAttribute('role', 'main');
		document.body.appendChild(fallbackMain);

		const { rerender } = render(
			ConfirmDialog,
			buildProps({ mode: 'standard', open: true, triggerRef: disabledTrigger })
		);

		rerender(buildProps({ mode: 'standard', open: false, triggerRef: disabledTrigger }));

		await waitFor(() => {
			expect(document.activeElement).toBe(fallbackMain);
		});
		expect(document.body.contains(disabledTrigger)).toBe(true);

		disabledTrigger.remove();
		fallbackMain.remove();
	});

	it('returns focus to the last active trigger when parent clears triggerRef on close', async () => {
		const triggerButton = document.createElement('button');
		triggerButton.type = 'button';
		document.body.appendChild(triggerButton);

		const fallbackMain = document.createElement('main');
		fallbackMain.setAttribute('role', 'main');
		document.body.appendChild(fallbackMain);

		const { rerender } = render(
			ConfirmDialog,
			buildProps({ mode: 'standard', open: true, triggerRef: triggerButton })
		);

		rerender(buildProps({ mode: 'standard', open: false, triggerRef: null }));

		await waitFor(() => {
			expect(document.activeElement).toBe(triggerButton);
		});

		triggerButton.remove();
		fallbackMain.remove();
	});

	it('disables controls while confirming, then shows alert on rejection and allows retry', async () => {
		const firstAttempt = createDeferred<void>();
		const secondAttempt = createDeferred<void>();
		const onConfirm = vi
			.fn<() => Promise<void>>()
			.mockImplementationOnce(() => firstAttempt.promise)
			.mockImplementationOnce(() => secondAttempt.promise);

		render(ConfirmDialog, buildProps({ onConfirm }));

		const input = screen.getByTestId('confirm-input');
		const cancelButton = screen.getByTestId('confirm-cancel-btn');
		const confirmButton = screen.getByTestId('confirm-confirm-btn');

		await fireEvent.input(input, { target: { value: 'movies_demo' } });
		await fireEvent.click(confirmButton);

		expect(onConfirm).toHaveBeenCalledTimes(1);
		expect(input).toBeDisabled();
		expect(cancelButton).toBeDisabled();
		expect(confirmButton).toBeDisabled();

		firstAttempt.reject(new Error('Server rejected delete'));
		const alert = await screen.findByRole('alert');
		expect(alert).toHaveTextContent('Server rejected delete');
		expect(alert).toHaveClass('border-flapjack-rose/45');
		expect(alert).toHaveClass('bg-flapjack-rose/10');
		expect(input).toHaveValue('movies_demo');
		expect(confirmButton).toBeEnabled();
		expect(cancelButton).toBeEnabled();

		await fireEvent.click(confirmButton);
		expect(onConfirm).toHaveBeenCalledTimes(2);
		secondAttempt.resolve();
		await waitFor(() => {
			expect(confirmButton).toBeEnabled();
		});
	});
});
