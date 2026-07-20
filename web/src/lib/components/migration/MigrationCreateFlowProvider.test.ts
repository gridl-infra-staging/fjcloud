import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

import type { AlgoliaSourceListResponse } from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	vi.useRealTimers();
});

const APP_ID_CANARY = 'CANARYAPPID0001';
const API_KEY_CANARY = 'canary-secret-key-0002';
const ELIGIBLE_AWS_PROVIDER = {
	phase: 'provider',
	mode: 'create',
	provider: 'aws',
	target: {
		kind: 'create',
		region: 'us-east-1',
		name: 'products_migration'
	},
	eligibilityToken: 'provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;
const EXPIRING_AWS_PROVIDER = {
	...ELIGIBLE_AWS_PROVIDER,
	expiresAt: '2026-07-18T10:15:00Z'
} as const;
const ELIGIBLE_AWS_REPLACE_PROVIDER = {
	phase: 'provider',
	mode: 'replace',
	provider: 'aws',
	target: {
		kind: 'replace',
		region: 'us-west-2',
		name: 'existing_products'
	},
	eligibilityToken: 'replace-provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;

type ProviderEligibilityFixture = ComponentProps<typeof MigrationCreateFlow>['providerEligibility'];
type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];

function migrationClient(listAlgoliaSourceIndexes = vi.fn()): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes,
		checkAlgoliaDestinationEligibility: vi.fn(),
		createAlgoliaImportJob: vi.fn()
	};
}

function renderFlow(
	providerEligibility: ProviderEligibilityFixture = ELIGIBLE_AWS_PROVIDER,
	listAlgoliaSourceIndexes = vi.fn(),
	capabilities: ComponentProps<typeof MigrationCreateFlow>['capabilities'] = undefined
) {
	const result = render(MigrationCreateFlow, {
		client: migrationClient(listAlgoliaSourceIndexes),
		providerEligibility,
		capabilities
	});
	return { ...result, listAlgoliaSourceIndexes };
}

function sourceList(name = 'old_provider_catalog'): AlgoliaSourceListResponse {
	return {
		items: [
			{
				name,
				entries: 1,
				dataSize: 10,
				fileSize: 10,
				updatedAt: '2026-07-18T10:00:00Z',
				lastBuildTimeS: 0,
				pendingTask: false,
				primary: null,
				replicas: []
			}
		],
		nextCursor: 'old-provider-cursor'
	};
}

describe('MigrationCreateFlow - provider gate', () => {
	it('hides Algolia credentials until provider eligibility succeeds', () => {
		renderFlow({
			status: 'checking',
			message: 'Checking destination eligibility'
		});

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'Checking destination eligibility'
		);
		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
	});

	it.each([
		['unsupported', 'migration_provider_unsupported: configured AWS-backed regions only'],
		['stale', 'Refresh provider eligibility before entering Algolia credentials'],
		['tampered', 'Provider eligibility could not be verified'],
		['cross_customer', 'Provider eligibility belongs to a different customer'],
		['provider_changed', 'Provider changed after eligibility was checked'],
		['region_changed', 'Region changed after eligibility was checked']
	] as const)(
		'hides Algolia credentials for %s provider eligibility fixtures',
		(status, message) => {
			renderFlow({ status, message });

			expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(message);
			expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: /connect to algolia/i })).not.toBeInTheDocument();
		}
	);

	it('shows Algolia credentials only for AWS provider eligibility success', () => {
		renderFlow();

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'AWS us-east-1 destination eligible'
		);
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /connect to algolia/i })).toBeDisabled();
	});

	it.each([
		[
			'target phase',
			{
				...ELIGIBLE_AWS_PROVIDER,
				phase: 'target'
			}
		],
		[
			'replace mode',
			{
				...ELIGIBLE_AWS_PROVIDER,
				mode: 'replace',
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					kind: 'replace'
				}
			}
		],
		[
			'replace target on create mode',
			{
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					kind: 'replace'
				}
			}
		]
	] as const)(
		'hides Algolia credentials for canonical %s eligibility',
		(_name, providerEligibility) => {
			renderFlow(providerEligibility);

			expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
				'Refresh provider eligibility before entering Algolia credentials'
			);
			expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		}
	);

	it('shows Algolia credentials for AWS replace eligibility only when replace is capable', () => {
		renderFlow(ELIGIBLE_AWS_REPLACE_PROVIDER, vi.fn(), {
			cancel: false,
			resume: false,
			replace: true
		});

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'AWS us-west-2 replacement destination eligible'
		);
		expect(screen.getByTestId('migration-replace-destination')).toHaveTextContent(
			'existing_products'
		);
		expect(screen.getByTestId('migration-replace-destination')).toHaveTextContent('us-west-2');
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
	});

	it.each([
		['absent', undefined],
		['all false', { cancel: false, resume: false, replace: false }],
		['malformed replace by cast', { cancel: false, resume: false, replace: 'true' }]
	] as const)(
		'hides Algolia credentials for replace eligibility with %s capability input',
		(_name, capabilities) => {
			renderFlow(
				ELIGIBLE_AWS_REPLACE_PROVIDER,
				vi.fn(),
				capabilities as ComponentProps<typeof MigrationCreateFlow>['capabilities']
			);

			expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
				'Refresh provider eligibility before entering Algolia credentials'
			);
			expect(screen.queryByTestId('migration-replace-destination')).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
		}
	);

	it('hides Algolia credentials for an initially expired provider eligibility envelope', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:16:00Z'));

		renderFlow(EXPIRING_AWS_PROVIDER);

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'Refresh provider eligibility before entering Algolia credentials'
		);
		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
	});

	it('hides and clears credentials when rerendered with an already expired provider eligibility envelope', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:00:00Z'));
		const { rerender } = renderFlow(
			{
				...ELIGIBLE_AWS_PROVIDER,
				expiresAt: '2026-07-18T10:30:00Z'
			},
			vi.fn()
		);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});

		vi.setSystemTime(new Date('2026-07-18T10:16:00Z'));
		await rerender({
			client: migrationClient(),
			providerEligibility: EXPIRING_AWS_PROVIDER
		});

		expect(screen.getByTestId('migration-provider-eligibility')).toHaveTextContent(
			'Refresh provider eligibility before entering Algolia credentials'
		);
		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();

		await rerender({
			client: migrationClient(),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				expiresAt: '2026-07-18T10:45:00Z',
				eligibilityToken: 'refreshed-provider-eligibility-token'
			}
		});
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
	});

	it('clears credentials and catalog when provider eligibility expires while mounted', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-18T10:14:59Z'));
		const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue(sourceList());
		renderFlow(EXPIRING_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		await screen.findByTestId('migration-source-row-old_provider_catalog');

		await vi.advanceTimersByTimeAsync(1001);

		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();
		expect(
			screen.queryByTestId('migration-source-row-old_provider_catalog')
		).not.toBeInTheDocument();
	});

	it('clears volatile credentials when provider eligibility becomes stale', async () => {
		const { rerender } = renderFlow();

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});

		await rerender({
			client: migrationClient(),
			providerEligibility: {
				status: 'stale',
				message: 'Refresh provider eligibility before entering Algolia credentials'
			}
		});
		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();

		await rerender({
			client: migrationClient(),
			providerEligibility: ELIGIBLE_AWS_PROVIDER
		});
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
	});

	it('rejects an in-flight catalog response issued under previous provider eligibility', async () => {
		let resolveList!: (response: AlgoliaSourceListResponse) => void;
		const listAlgoliaSourceIndexes = vi.fn(
			() =>
				new Promise<AlgoliaSourceListResponse>((resolve) => {
					resolveList = resolve;
				})
		);
		const { rerender } = renderFlow(ELIGIBLE_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				status: 'region_changed',
				message: 'Region changed after eligibility was checked'
			}
		});
		expect(screen.queryByLabelText(/algolia application id/i)).not.toBeInTheDocument();

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					region: 'us-west-2'
				}
			}
		});
		resolveList({
			...sourceList()
		});
		await vi.waitFor(() => {
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument();
		});

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});

		expect(
			screen.queryByTestId('migration-source-row-old_provider_catalog')
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
	});

	it('does not clear replacement credentials when an old catalog response resolves', async () => {
		let resolveList!: (response: AlgoliaSourceListResponse) => void;
		const listAlgoliaSourceIndexes = vi.fn(
			() =>
				new Promise<AlgoliaSourceListResponse>((resolve) => {
					resolveList = resolve;
				})
		);
		const { rerender } = renderFlow(ELIGIBLE_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					region: 'us-west-2'
				},
				eligibilityToken: 'replacement-provider-eligibility-token'
			}
		});
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'REPLACEMENTAPPID' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'replacement-secret-key' }
		});

		resolveList(sourceList());
		await vi.waitFor(() => {
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument();
		});

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('REPLACEMENTAPPID');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('replacement-secret-key');
		expect(
			screen.queryByTestId('migration-source-row-old_provider_catalog')
		).not.toBeInTheDocument();
	});

	it('allows replacement discovery before an old provider request settles', async () => {
		let resolveOldList!: (response: AlgoliaSourceListResponse) => void;
		const listAlgoliaSourceIndexes = vi
			.fn()
			.mockImplementationOnce(
				() =>
					new Promise<AlgoliaSourceListResponse>((resolve) => {
						resolveOldList = resolve;
					})
			)
			.mockResolvedValueOnce(sourceList('replacement_provider_catalog'));
		const { rerender } = renderFlow(ELIGIBLE_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		expect(listAlgoliaSourceIndexes).toHaveBeenCalledTimes(1);

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					region: 'us-west-2'
				},
				eligibilityToken: 'replacement-provider-eligibility-token'
			}
		});
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'REPLACEMENTAPPID' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'replacement-secret-key' }
		});

		const replacementConnect = screen.getByRole('button', { name: /connect to algolia/i });
		expect(replacementConnect).toBeEnabled();
		await fireEvent.click(replacementConnect);

		await vi.waitFor(() => {
			expect(listAlgoliaSourceIndexes).toHaveBeenCalledTimes(2);
		});
		expect(listAlgoliaSourceIndexes).toHaveBeenLastCalledWith({
			appId: 'REPLACEMENTAPPID',
			apiKey: 'replacement-secret-key'
		});
		await screen.findByTestId('migration-source-row-replacement_provider_catalog');

		resolveOldList(sourceList('old_provider_catalog'));
		await vi.waitFor(() => {
			expect(
				screen.queryByTestId('migration-source-row-old_provider_catalog')
			).not.toBeInTheDocument();
		});
	});

	it('does not publish an old catalog error under replacement credentials', async () => {
		let rejectList!: (error: Error) => void;
		const listAlgoliaSourceIndexes = vi.fn(
			() =>
				new Promise<AlgoliaSourceListResponse>((_resolve, reject) => {
					rejectList = reject;
				})
		);
		const { rerender } = renderFlow(ELIGIBLE_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					region: 'us-west-2'
				},
				eligibilityToken: 'replacement-provider-eligibility-token'
			}
		});
		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: 'REPLACEMENTAPPID' }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'replacement-secret-key' }
		});

		rejectList(new Error('old_provider_credentials_rejected'));
		await vi.waitFor(() => {
			expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument();
		});

		expect(screen.queryByTestId('migration-source-error')).not.toBeInTheDocument();
		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('REPLACEMENTAPPID');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('replacement-secret-key');
	});

	it('clears a completed catalog and credentials when the eligible provider binding changes', async () => {
		const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue({
			items: [
				{
					name: 'old_provider_catalog',
					entries: 1,
					dataSize: 10,
					fileSize: 10,
					updatedAt: '2026-07-18T10:00:00Z',
					lastBuildTimeS: 0,
					pendingTask: false,
					primary: null,
					replicas: []
				}
			],
			nextCursor: 'old-provider-cursor'
		});
		const { rerender } = renderFlow(ELIGIBLE_AWS_PROVIDER, listAlgoliaSourceIndexes);

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		await screen.findByTestId('migration-source-row-old_provider_catalog');

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_PROVIDER,
				target: {
					...ELIGIBLE_AWS_PROVIDER.target,
					region: 'us-west-2'
				},
				eligibilityToken: 'refreshed-provider-eligibility-token'
			}
		});

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(
			screen.queryByTestId('migration-source-row-old_provider_catalog')
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole('button', { name: /load more source indexes/i })
		).not.toBeInTheDocument();
	});

	it('clears replace credentials and catalog when the existing destination binding changes', async () => {
		const listAlgoliaSourceIndexes = vi.fn().mockResolvedValue(sourceList());
		const { rerender } = renderFlow(ELIGIBLE_AWS_REPLACE_PROVIDER, listAlgoliaSourceIndexes, {
			cancel: false,
			resume: false,
			replace: true
		});

		await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
			target: { value: APP_ID_CANARY }
		});
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: API_KEY_CANARY }
		});
		await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
		await screen.findByTestId('migration-source-row-old_provider_catalog');

		await rerender({
			client: migrationClient(listAlgoliaSourceIndexes),
			providerEligibility: {
				...ELIGIBLE_AWS_REPLACE_PROVIDER,
				target: {
					...ELIGIBLE_AWS_REPLACE_PROVIDER.target,
					name: 'replacement_target_changed'
				}
			},
			capabilities: { cancel: false, resume: false, replace: true }
		});

		expect(screen.getByLabelText(/algolia application id/i)).toHaveValue('');
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(
			screen.queryByTestId('migration-source-row-old_provider_catalog')
		).not.toBeInTheDocument();
		expect(screen.getByTestId('migration-replace-destination')).toHaveTextContent(
			'replacement_target_changed'
		);
	});
});
