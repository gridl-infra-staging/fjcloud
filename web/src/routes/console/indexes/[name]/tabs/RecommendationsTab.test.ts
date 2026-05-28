import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent, within } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const formsMockState = vi.hoisted(() => ({
	enhanceSubmitFunctions: [] as Array<() => PromiseLike<unknown> | unknown>,
	applyAction: vi.fn(async () => {})
}));

vi.mock('$app/forms', () => ({
	enhance: (_element: HTMLFormElement, submitFunction: () => PromiseLike<unknown> | unknown) => {
		formsMockState.enhanceSubmitFunctions.push(submitFunction);
		return { destroy: () => {} };
	},
	applyAction: formsMockState.applyAction
}));

import RecommendationsTab from './RecommendationsTab.svelte';
import { sampleIndex } from '../detail.test.shared';
import type { RecommendationsBatchResponse } from '$lib/api/types';
import {
	recommendationsBatchRequestFromConfig,
	type RecommendationConfig
} from '$lib/recommendations/config';

type RecommendationsProps = ComponentProps<typeof RecommendationsTab>;

function defaultProps(overrides: Partial<RecommendationsProps> = {}): RecommendationsProps {
	return {
		index: sampleIndex,
		recommendationsResponse: null,
		recommendationsError: '',
		...overrides
	};
}

function responseWithHits(hits: Record<string, unknown>[]): RecommendationsBatchResponse {
	return {
		results: [{ hits, processingTimeMS: 4 }]
	};
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	formsMockState.enhanceSubmitFunctions.length = 0;
});

describe('RecommendationsTab', () => {
	it('renders exactly five supported model options', () => {
		render(RecommendationsTab, defaultProps());

		const modelSelect = screen.getByTestId('recommendations-model-select');
		const options = modelSelect.querySelectorAll('option');
		expect(options).toHaveLength(5);
		expect(Array.from(options).map((option) => option.getAttribute('value'))).toEqual([
			'related-products',
			'bought-together',
			'trending-items',
			'trending-facets',
			'looking-similar'
		]);
	});

	it('defaults selected model to related-products', () => {
		render(RecommendationsTab, defaultProps());

		const modelSelect = screen.getByTestId('recommendations-model-select') as HTMLSelectElement;
		expect(modelSelect.value).toBe('related-products');
	});

	it('switching model toggles required field visibility', async () => {
		render(RecommendationsTab, defaultProps());

		const modelSelect = screen.getByTestId('recommendations-model-select') as HTMLSelectElement;
		expect(screen.getByLabelText('Object ID')).toBeInTheDocument();
		expect(screen.queryByLabelText('Facet Name')).not.toBeInTheDocument();
		expect(screen.queryByLabelText('Facet Value')).not.toBeInTheDocument();

		await fireEvent.change(modelSelect, { target: { value: 'trending-facets' } });
		expect(screen.queryByLabelText('Object ID')).not.toBeInTheDocument();
		expect(screen.getByLabelText('Facet Name')).toBeInTheDocument();
		expect(screen.getByLabelText('Facet Value')).toBeInTheDocument();
	});

	it('disables submit when model requirements are missing and enables when present', async () => {
		render(RecommendationsTab, defaultProps());

		const submitButton = screen.getByRole('button', { name: /get recommendations/i });
		expect(submitButton).toBeDisabled();

		await fireEvent.input(screen.getByLabelText('Object ID'), {
			target: { value: 'sku-1' }
		});
		expect(submitButton).toBeEnabled();

		const modelSelect = screen.getByTestId('recommendations-model-select') as HTMLSelectElement;
		await fireEvent.change(modelSelect, { target: { value: 'trending-facets' } });
		expect(submitButton).toBeDisabled();

		await fireEvent.input(screen.getByLabelText('Facet Name'), {
			target: { value: 'brand' }
		});
		expect(submitButton).toBeDisabled();

		await fireEvent.input(screen.getByLabelText('Facet Value'), {
			target: { value: 'Nike' }
		});
		expect(submitButton).toBeEnabled();
	});

	it('submits request payload in hidden request input using the shared serializer', async () => {
		const { container } = render(RecommendationsTab, defaultProps());

		const modelSelect = screen.getByTestId('recommendations-model-select') as HTMLSelectElement;
		await fireEvent.change(modelSelect, { target: { value: 'trending-facets' } });
		await fireEvent.input(screen.getByLabelText('Facet Name'), { target: { value: 'brand' } });
		await fireEvent.input(screen.getByLabelText('Facet Value'), { target: { value: 'Apple' } });
		await fireEvent.input(screen.getByLabelText('Threshold'), { target: { value: '10' } });
		await fireEvent.input(screen.getByLabelText('Max Recommendations'), {
			target: { value: '8' }
		});

		const requestInput = container.querySelector('input[name="request"]') as HTMLInputElement;
		expect(requestInput).not.toBeNull();
		const expectedConfig: RecommendationConfig = {
			model: 'trending-facets',
			objectID: '',
			facetName: 'brand',
			facetValue: 'Apple',
			threshold: 10,
			maxRecommendations: 8
		};
		expect(JSON.parse(requestInput.value)).toEqual(
			recommendationsBatchRequestFromConfig('products', expectedConfig)
		);
	});

	it('edit dialog saves into the same inline configuration state without submitting', async () => {
		render(RecommendationsTab, defaultProps());

		await fireEvent.click(screen.getByRole('button', { name: 'Edit Configuration' }));
		const dialog = screen.getByTestId('recommendations-edit-dialog');
		const dialogQueries = within(dialog);
		await fireEvent.change(dialogQueries.getByLabelText('Model'), {
			target: { value: 'trending-facets' }
		});
		await fireEvent.input(dialogQueries.getByLabelText('Facet Name'), {
			target: { value: 'brand' }
		});
		await fireEvent.input(dialogQueries.getByLabelText('Facet Value'), {
			target: { value: 'Apple' }
		});
		await fireEvent.input(dialogQueries.getByLabelText('Threshold'), {
			target: { value: '12' }
		});
		await fireEvent.input(dialogQueries.getByLabelText('Max Recommendations'), {
			target: { value: '9' }
		});
		await fireEvent.click(dialogQueries.getByTestId('editor-dialog-save'));

		expect(screen.queryByTestId('recommendations-edit-dialog')).not.toBeInTheDocument();
		expect(screen.getByTestId('recommendations-model-select')).toHaveValue('trending-facets');
		expect(screen.getByLabelText('Facet Name')).toHaveValue('brand');
		expect(screen.getByLabelText('Facet Value')).toHaveValue('Apple');
		expect(screen.getByLabelText('Threshold')).toHaveValue(12);
		expect(screen.getByLabelText('Max Recommendations')).toHaveValue(9);
		expect(screen.queryByLabelText('Object ID')).not.toBeInTheDocument();
		expect(formsMockState.applyAction).not.toHaveBeenCalled();
	});

	it('renders recommendation hits from action result', () => {
		render(
			RecommendationsTab,
			defaultProps({
				recommendationsResponse: responseWithHits([{ objectID: 'shoe-1' }, { objectID: 'shoe-2' }])
			})
		);

		expect(screen.getByText('shoe-1')).toBeInTheDocument();
		expect(screen.getByText('shoe-2')).toBeInTheDocument();
	});

	it('renders human-readable facet labels for facet recommendations', () => {
		render(
			RecommendationsTab,
			defaultProps({
				recommendationsResponse: responseWithHits([{ facet_name: 'brand', facet_value: 'Apple' }])
			})
		);

		expect(screen.getByText('brand: Apple')).toBeInTheDocument();
	});

	it('renders recommendation errors through one alert region', () => {
		render(
			RecommendationsTab,
			defaultProps({
				recommendationsError: 'Recommendations failed upstream'
			})
		);

		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Recommendations failed upstream');
		expect(screen.getAllByRole('alert')).toHaveLength(1);
	});

	it('renders one aggregate empty-state copy when every result has zero hits', () => {
		render(
			RecommendationsTab,
			defaultProps({
				recommendationsResponse: {
					results: [
						{ hits: [], processingTimeMS: 1 },
						{ hits: [], processingTimeMS: 3 }
					]
				}
			})
		);

		expect(screen.getByText('No recommendations found.')).toBeInTheDocument();
		expect(screen.queryByText('No hits returned.')).not.toBeInTheDocument();
	});

	it('keeps per-request rows for mixed batches including zero-hit requests', () => {
		render(
			RecommendationsTab,
			defaultProps({
				recommendationsResponse: {
					results: [
						{ hits: [{ objectID: 'shoe-1' }], processingTimeMS: 2 },
						{ hits: [], processingTimeMS: 7 }
					]
				}
			})
		);

		expect(screen.getByText('Request #1 · 2 ms')).toBeInTheDocument();
		expect(screen.getByText('shoe-1')).toBeInTheDocument();
		expect(screen.getByText('Request #2 · 7 ms')).toBeInTheDocument();
		expect(screen.queryByText('No recommendations found.')).not.toBeInTheDocument();
	});

	it('drops stale completion when two submits happen with same model and index', async () => {
		render(RecommendationsTab, defaultProps());

		await fireEvent.input(screen.getByLabelText('Object ID'), {
			target: { value: 'sku-1' }
		});

		expect(formsMockState.enhanceSubmitFunctions).toHaveLength(1);
		const firstSubmit = formsMockState.enhanceSubmitFunctions[0];
		const secondSubmit = formsMockState.enhanceSubmitFunctions[0];
		const firstResultHandler = firstSubmit() as ({ result }: { result: unknown }) => Promise<void>;
		const secondResultHandler = secondSubmit() as ({
			result
		}: {
			result: unknown;
		}) => Promise<void>;

		await secondResultHandler({ result: { type: 'success' } });
		await firstResultHandler({ result: { type: 'success' } });

		expect(formsMockState.applyAction).toHaveBeenCalledTimes(1);
	});

	it('drops stale completion after inline request edits without a second submit', async () => {
		render(RecommendationsTab, defaultProps());

		await fireEvent.input(screen.getByLabelText('Object ID'), {
			target: { value: 'sku-1' }
		});

		expect(formsMockState.enhanceSubmitFunctions).toHaveLength(1);
		const submit = formsMockState.enhanceSubmitFunctions[0];
		const resultHandler = submit() as ({ result }: { result: unknown }) => Promise<void>;

		await fireEvent.input(screen.getByLabelText('Object ID'), {
			target: { value: 'sku-2' }
		});
		await resultHandler({ result: { type: 'success' } });

		expect(formsMockState.applyAction).not.toHaveBeenCalled();
	});
});
