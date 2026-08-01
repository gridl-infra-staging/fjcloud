import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/svelte';
import type { AlgoliaMigrationCapabilities, AlgoliaSourceListResponse } from '$lib/api/types';

import {
	API_KEY_CANARY,
	APP_ID_CANARY,
	ELIGIBLE_AWS_REPLACE_PROVIDER,
	NO_CAPABILITIES,
	connect,
	listResponse,
	migrationClient,
	renderFlow,
	sourceIndex,
	waitForDiscoveryToSettle
} from './migration_test_fixtures';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

const API_KEY_CANARY_SHA256 = 'f38e91ffdce3adc96f812a25e847e7fda20b912d7722c4b4cc5ab5363d3be46f';

function hexDigestBuffer(hex: string): ArrayBuffer {
	const bytes = new Uint8Array(hex.length / 2);
	for (let index = 0; index < bytes.length; index += 1) {
		bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
	}
	return bytes.buffer;
}

function deferredDigest() {
	let resolve: (value: ArrayBuffer) => void = () => {};
	const promise = new Promise<ArrayBuffer>((nextResolve) => {
		resolve = nextResolve;
	});
	return { promise, resolve };
}

describe('MigrationCreateFlow - connect step', () => {
	it('renders the credential entry step with no source list before connecting', () => {
		renderFlow();

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'AWS us-east-1 destination eligible'
		);
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
	});

	it('announces provider eligibility through status and alert roles', async () => {
		const { rerender } = renderFlow();

		expect(screen.getByRole('status')).toHaveTextContent('AWS us-east-1 destination eligible');

		await rerender({
			client: migrationClient(),
			providerEligibility: {
				status: 'unsupported',
				message: 'migration_provider_unsupported: configured AWS-backed regions only'
			}
		});

		expect(screen.getByRole('alert')).toHaveTextContent(
			'migration_provider_unsupported: configured AWS-backed regions only'
		);
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
	});

	it('keeps responsive structure deterministic without relying on jsdom geometry', () => {
		renderFlow();

		const flow = screen.getByTestId('migration-create-flow');
		expect(flow).toHaveClass('space-y-6');
		expect(screen.getByLabelText(/algolia application id/i)).toHaveClass('w-full');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveClass('w-full');
		expect(screen.getByTestId('migration-algolia-key-instructions')).toHaveClass('leading-6');
	});

	it('enables connect only once both credential fields are non-empty', async () => {
		renderFlow();
		const connectButton = screen.getByRole('button', { name: /connect to algolia/i });

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		expect(connectButton).toBeDisabled();

		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		expect(connectButton).toBeEnabled();
	});

	it('renders scoped temporary key instructions from the migrate screen contract', () => {
		renderFlow();

		const instructions = screen.getByTestId('migration-algolia-key-instructions');
		expect(instructions).toHaveTextContent('API Keys');
		expect(instructions).toHaveTextContent('All API Keys');
		expect(instructions).toHaveTextContent('New API Key');
		expect(instructions).toHaveTextContent('temporary Algolia API key');
		expect(instructions).toHaveTextContent('listIndexes');
		expect(instructions).toHaveTextContent('browse');
		expect(instructions).toHaveTextContent('settings');
		expect(instructions).toHaveTextContent('seeUnretrievableAttributes');
		expect(instructions).toHaveTextContent('Restrict the key to the source index');
		expect(instructions).toHaveTextContent('Set validity long enough for the projected import');
		expect(instructions).toHaveTextContent(
			'Delete the key in Algolia after the import completes or fails'
		);
		expect(instructions).toHaveTextContent('fjcloud zeroizes its in-memory copy');
		expect(instructions).toHaveTextContent('cannot revoke the vendor key');
	});

	it('sends the entered volatile credentials to listAlgoliaSourceIndexes', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);

		await waitFor(() => expect(list).toHaveBeenCalledTimes(1));
		expect(list).toHaveBeenCalledWith({ appId: APP_ID_CANARY, apiKey: API_KEY_CANARY });
	});

	it('moves focus to the source step heading after a successful connection', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);

		const sourceHeading = await screen.findByRole('heading', {
			name: 'Choose a source index',
			level: 3
		});
		await waitFor(() => expect(sourceHeading).toHaveFocus());
	});

	it('starts an explicit reconnect with blank volatile credentials and no stale catalog', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));

		await fireEvent.click(screen.getByRole('button', { name: /^reconnect to algolia$/i }));

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /^connect to algolia$/i })).toBeDisabled();
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-selected-source')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
		expect(list).toHaveBeenCalledTimes(1);
	});

	it('shows a bounded loading state that clears when discovery resolves', async () => {
		let resolveList: (value: AlgoliaSourceListResponse) => void = () => {};
		const list = vi.fn().mockReturnValue(
			new Promise<AlgoliaSourceListResponse>((resolve) => {
				resolveList = resolve;
			})
		);
		renderFlow(list);

		await connect(list, APP_ID_CANARY, API_KEY_CANARY, false);

		const loading = await screen.findByTestId('migration-source-loading');
		expect(loading).toHaveAttribute('role', 'status');
		expect(loading).toHaveTextContent('Loading source indexes');
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();

		resolveList(listResponse([sourceIndex()]));

		await waitFor(() =>
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument()
		);
	});

	it('does not start a second discovery request while one is already in flight', async () => {
		let resolveList: (value: AlgoliaSourceListResponse) => void = () => {};
		const list = vi.fn().mockReturnValue(
			new Promise<AlgoliaSourceListResponse>((resolve) => {
				resolveList = resolve;
			})
		);
		renderFlow(list);
		const connectButton = screen.getByRole('button', { name: /connect to algolia/i });

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(connectButton);
		await fireEvent.click(connectButton);

		expect(list).toHaveBeenCalledTimes(1);

		resolveList(listResponse([sourceIndex()]));
		await screen.findByTestId('migration-source-row-source_products');
	});

	it.each([
		['absent', undefined],
		['all false', NO_CAPABILITIES],
		['partial replace omitted', { cancel: true, resume: true } as AlgoliaMigrationCapabilities],
		[
			'malformed replace by cast',
			{ cancel: true, resume: true, replace: 'true' } as unknown as AlgoliaMigrationCapabilities
		]
	])(
		'renders no replace affordance, placeholder, tooltip, hint, or inert control for %s capability inputs',
		(_name, capabilities) => {
			renderFlow(vi.fn(), capabilities, ELIGIBLE_AWS_REPLACE_PROVIDER);

			expect(
				screen.queryByRole('button', { name: /replace existing destination/i })
			).not.toBeInTheDocument();
			expect(screen.queryByTestId('migration-replace-destination')).not.toBeInTheDocument();
			expect(screen.queryByText(/replace unavailable/i)).not.toBeInTheDocument();
			expect(screen.queryByTitle(/replace/i)).not.toBeInTheDocument();
		}
	);

	it('renders only the producer-selected replace arm when the replace capability is true', () => {
		renderFlow(
			vi.fn(),
			{ cancel: false, resume: false, replace: true },
			ELIGIBLE_AWS_REPLACE_PROVIDER
		);

		expect(screen.getByTestId('migration-replace-destination')).toHaveTextContent(
			'existing_products'
		);
		expect(
			screen.queryByRole('button', { name: /replace existing destination/i })
		).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
	});

	it('does not let cancel, resume, or an availability-like flag cross-enable replace', () => {
		renderFlow(
			vi.fn(),
			{
				cancel: true,
				resume: true,
				replace: false,
				available: true
			} as AlgoliaMigrationCapabilities,
			ELIGIBLE_AWS_REPLACE_PROVIDER
		);

		expect(
			screen.queryByRole('button', { name: /replace existing destination/i })
		).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-replace-destination')).not.toBeInTheDocument();
	});

	it('renders replace target identity and region read-only after source selection', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(
			list,
			{ cancel: false, resume: false, replace: true },
			ELIGIBLE_AWS_REPLACE_PROVIDER
		);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));

		const replaceDestination = screen.getByTestId('migration-replace-destination');
		expect(replaceDestination).toHaveTextContent('existing_products');
		expect(replaceDestination).toHaveTextContent('us-west-2');
		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-selected-source')).toHaveTextContent('source_products');
	});
});

describe('MigrationCreateFlow - source metadata', () => {
	it('renders the exact source metadata contract for a primary index', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		renderFlow(list);

		await connect(list);

		const row = await screen.findByTestId('migration-source-row-source_products');
		expect(row).toHaveTextContent('source_products');
		// Hand-calculated against the shared formatters: 1234 -> "1,234",
		// 2048 bytes -> "2.0 KB", 2026-07-18T10:00:00Z -> "Jul 18, 2026".
		expect(row).toHaveTextContent('1,234 records');
		expect(row).toHaveTextContent('2.0 KB');
		expect(row).toHaveTextContent('Jul 18, 2026');
		expect(row).toHaveTextContent('Last build 17s');
		expect(row).toHaveTextContent('Primary');
	});

	it('labels a replica index with the primary it belongs to', async () => {
		const list = vi
			.fn()
			.mockResolvedValue(
				listResponse([sourceIndex({ name: 'products_price_asc', primary: 'source_products' })])
			);
		renderFlow(list);

		await connect(list);

		const row = await screen.findByTestId('migration-source-row-products_price_asc');
		expect(row).toHaveTextContent('Replica of source_products');
		expect(row).not.toHaveTextContent('Primary');
	});

	it('omits the build-time metadata row when the producer reports no build time', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex({ lastBuildTimeS: 0 })]));
		renderFlow(list);

		await connect(list);

		const row = await screen.findByTestId('migration-source-row-source_products');
		expect(row).not.toHaveTextContent('Last build');
	});

	it('renders an explicit empty state when the account has no source indexes', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([]));
		renderFlow(list);

		await connect(list);

		expect(await screen.findByTestId('migration-source-empty')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-source-row-source_products')).not.toBeInTheDocument();
	});
});

describe('MigrationCreateFlow - selection, search, and pagination', () => {
	it('records the selected source index without mutating the displayed name', async () => {
		const list = vi
			.fn()
			.mockResolvedValue(listResponse([sourceIndex(), sourceIndex({ name: 'Ünïcode Index' })]));
		renderFlow(list);

		await connect(list);

		const option = await screen.findByRole('radio', { name: /Ünïcode Index/ });
		await fireEvent.click(option);

		expect(option).toBeChecked();
		expect(screen.getByTestId('migration-selected-source')).toHaveTextContent('Ünïcode Index');
	});

	it('filters listed source indexes by the search term without refetching', async () => {
		const list = vi
			.fn()
			.mockResolvedValue(listResponse([sourceIndex(), sourceIndex({ name: 'orders_live' })]));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		await fireEvent.input(screen.getByLabelText(/search source indexes/i), {
			target: { value: 'orders' }
		});

		expect(screen.getByTestId('migration-source-row-orders_live')).toBeInTheDocument();
		expect(screen.queryByTestId('migration-source-row-source_products')).not.toBeInTheDocument();
		expect(list).toHaveBeenCalledTimes(1);
	});

	it('appends the next cursor page and hides load-more when the cursor is exhausted', async () => {
		const list = vi
			.fn()
			.mockResolvedValueOnce(listResponse([sourceIndex()], 'opaque-cursor-1'))
			.mockResolvedValueOnce(listResponse([sourceIndex({ name: 'orders_live' })], null));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		await fireEvent.click(screen.getByRole('button', { name: /load more source indexes/i }));

		await screen.findByTestId('migration-source-row-orders_live');
		expect(screen.getByTestId('migration-source-row-source_products')).toBeInTheDocument();
		expect(list).toHaveBeenLastCalledWith({
			appId: APP_ID_CANARY,
			apiKey: API_KEY_CANARY,
			cursor: 'opaque-cursor-1'
		});
		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
	});

	it('does not offer load-more when the first page exhausts the cursor', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()], null));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');

		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
	});

	it('clears the previous source selection and destination proposal when reconnecting', async () => {
		const list = vi
			.fn()
			.mockResolvedValueOnce(listResponse([sourceIndex({ name: 'first_source' })]))
			.mockResolvedValueOnce(listResponse([sourceIndex({ name: 'second_source' })]));
		renderFlow(list);

		await connect(list, 'FIRSTAPPID0001', 'first-secret-key');
		await screen.findByTestId('migration-source-row-first_source');
		await fireEvent.change(screen.getByRole('radio', { name: /first_source/i }));
		expect(screen.getByTestId('migration-selected-source')).toHaveTextContent('first_source');
		expect(screen.getByLabelText(/destination index name/i)).toHaveValue('first_source');

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'SECONDAPPID0002' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'second-secret-key' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		await screen.findByTestId('migration-source-row-second_source');
		expect(screen.queryByTestId('migration-source-row-first_source')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-selected-source')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
		expect(list).toHaveBeenLastCalledWith({
			appId: 'SECONDAPPID0002',
			apiKey: 'second-secret-key'
		});
	});

	it('clears a stale search filter when reconnecting so the new catalog is not hidden', async () => {
		// A filter typed against the previous application would silently hide every
		// row of the new one, which reads as an empty account rather than a filter.
		const list = vi
			.fn()
			.mockResolvedValueOnce(listResponse([sourceIndex({ name: 'first_source' })]))
			.mockResolvedValueOnce(listResponse([sourceIndex({ name: 'second_source' })]));
		renderFlow(list);

		await connect(list, 'FIRSTAPPID0001', 'first-secret-key');
		await screen.findByTestId('migration-source-row-first_source');
		await fireEvent.input(screen.getByLabelText(/search source indexes/i), {
			target: { value: 'first' }
		});

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'SECONDAPPID0002' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'second-secret-key' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		await screen.findByTestId('migration-source-row-second_source');
		expect(screen.getByLabelText(/search source indexes/i)).toHaveValue('');
	});
});

describe('MigrationCreateFlow - credential change invalidates the catalog', () => {
	async function connectWithPendingCursor() {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()], 'opaque-cursor-1'));
		renderFlow(list);

		await connect(list);
		await screen.findByTestId('migration-source-row-source_products');
		expect(screen.getByRole('button', { name: /load more source indexes/i })).toBeInTheDocument();

		return list;
	}

	it('keeps unchanged canary credentials connected after first discovery settles', async () => {
		const list = vi.fn().mockResolvedValue(listResponse([sourceIndex()]));
		const requestDigestDeferred = deferredDigest();
		const requestDigest = hexDigestBuffer(API_KEY_CANARY_SHA256);
		const digest = vi
			.spyOn(globalThis.crypto.subtle, 'digest')
			.mockReturnValue(requestDigestDeferred.promise);
		renderFlow(list);

		await connect(list, APP_ID_CANARY, API_KEY_CANARY, false);
		await waitFor(() => expect(list).toHaveBeenCalledTimes(1));
		expect(digest).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('migration-source-loading')).toBeInTheDocument();
		requestDigestDeferred.resolve(requestDigest);
		await waitForDiscoveryToSettle();

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue(APP_ID_CANARY);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue(API_KEY_CANARY);
		expect(list).toHaveBeenCalledTimes(1);
		expect(list).toHaveBeenCalledWith({ appId: APP_ID_CANARY, apiKey: API_KEY_CANARY });
		try {
			expect(screen.getByTestId('migration-source-row-source_products')).toBeInTheDocument();
			expect(screen.queryByTestId('migration-credentials-changed')).not.toBeInTheDocument();
		} finally {
			requestDigestDeferred.resolve(requestDigest);
		}
	});

	it('hides the loaded catalog when the app id is edited after connecting', async () => {
		await connectWithPendingCursor();

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'OTHERAPPID0003' }
		});

		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-credentials-changed')).toBeInTheDocument();
		// The empty state would falsely claim the other application has no indexes.
		expect(screen.queryByTestId('migration-source-empty')).not.toBeInTheDocument();
	});

	it('hides the loaded catalog when the api key is edited after connecting', async () => {
		await connectWithPendingCursor();

		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'other-secret-key-0004' }
		});

		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-credentials-changed')).toBeInTheDocument();
	});

	it('withdraws load-more so a cursor is never replayed with different credentials', async () => {
		const list = await connectWithPendingCursor();

		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'other-secret-key-0004' }
		});

		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
		expect(list).toHaveBeenCalledTimes(1);
	});

	it('drops the source selection and destination proposal while credentials are changed', async () => {
		await connectWithPendingCursor();
		await fireEvent.change(screen.getByRole('radio', { name: /source_products/i }));
		expect(screen.getByTestId('migration-selected-source')).toBeInTheDocument();

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'OTHERAPPID0003' }
		});

		expect(screen.queryByTestId('migration-selected-source')).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/destination index name/i)).not.toBeInTheDocument();
	});

	it('binds the arriving catalog to the credentials that fetched it, not the live inputs', async () => {
		// The customer edits the app id while the first page is still in flight. The
		// page that lands describes the ORIGINAL application, so it must not be
		// stamped as belonging to the credentials now sitting in the inputs.
		let resolveList: (value: AlgoliaSourceListResponse) => void = () => {};
		const list = vi.fn().mockReturnValue(
			new Promise<AlgoliaSourceListResponse>((resolve) => {
				resolveList = resolve;
			})
		);
		renderFlow(list);

		await connect(list, APP_ID_CANARY, API_KEY_CANARY, false);
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'OTHERAPPID0003' }
		});

		resolveList(listResponse([sourceIndex()], 'opaque-cursor-1'));
		await waitFor(() =>
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument()
		);

		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-credentials-changed')).toBeInTheDocument();
	});

	it('withdraws load-more for a page that landed after the credentials were edited', async () => {
		let resolveList: (value: AlgoliaSourceListResponse) => void = () => {};
		const list = vi.fn().mockReturnValue(
			new Promise<AlgoliaSourceListResponse>((resolve) => {
				resolveList = resolve;
			})
		);
		renderFlow(list);

		await connect(list, APP_ID_CANARY, API_KEY_CANARY, false);
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'other-secret-key-0004' }
		});

		resolveList(listResponse([sourceIndex()], 'opaque-cursor-1'));
		await waitFor(() =>
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument()
		);

		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
		expect(list).toHaveBeenCalledTimes(1);
	});

	it('does not publish an in-flight discovery error after credentials are edited', async () => {
		let rejectList: (error: Error) => void = () => {};
		const list = vi.fn().mockReturnValue(
			new Promise<AlgoliaSourceListResponse>((_resolve, reject) => {
				rejectList = reject;
			})
		);
		renderFlow(list);

		await connect(list, APP_ID_CANARY, API_KEY_CANARY, false);
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'replacement-secret-key-0005' }
		});

		rejectList(new Error('old_credentials_rejected'));
		await waitFor(() =>
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument()
		);

		expect(screen.queryByTestId('migration-source-error')).not.toBeInTheDocument();
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue(APP_ID_CANARY);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('replacement-secret-key-0005');
	});

	it('requires fresh discovery when credentials are edited back to a previous pair', async () => {
		const list = await connectWithPendingCursor();

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'OTHERAPPID0003' }
		});
		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});

		expect(screen.queryByTestId('migration-source-list')).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-credentials-changed')).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		await screen.findByTestId('migration-source-list');

		expect(screen.queryByTestId('migration-credentials-changed')).not.toBeInTheDocument();
		expect(list).toHaveBeenCalledTimes(2);
	});
});
