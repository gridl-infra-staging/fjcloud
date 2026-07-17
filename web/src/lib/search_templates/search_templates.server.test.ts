import { describe, expect, it } from 'vitest';
import { indexTemplateServerSnapshots } from './search_templates.server';

describe('search template server snapshot contract', () => {
	const movieDocumentKeys = [
		'director',
		'genre',
		'image',
		'license',
		'objectID',
		'overview',
		'rating',
		'title',
		'year'
	];
	const productDocumentKeys = [
		'brand',
		'category',
		'description',
		'image',
		'inStock',
		'license',
		'name',
		'objectID',
		'price',
		'rating'
	];
	const brokenImageHosts = ['example.com', 'placeholder.com'];
	const brokenImageOwnerPaths = ['image.tmdb.org/placeholder', 'images.example.com/placeholder'];
	const brokenImagePathSegment = '/placeholder';

	function createMovieContractDocument(image: string): Record<string, unknown> {
		return {
			director: 'Director',
			genre: 'Drama',
			image,
			license: 'CC0',
			objectID: 'movie-1',
			overview: 'Overview',
			rating: 5,
			title: 'Title',
			year: 2024
		};
	}

	function assertTemplateDocumentsShipValidImages({
		templateName,
		documents,
		expectedKeys
	}: {
		templateName: string;
		documents: Array<Record<string, unknown>>;
		expectedKeys: string[];
	}) {
		for (const [index, document] of documents.entries()) {
			expect(Object.keys(document).sort(), `${templateName} document ${index} keys`).toEqual(
				expectedKeys
			);
			expect(typeof document.image, `${templateName} document ${index} image type`).toBe('string');
			expect(
				(document.image as string).length,
				`${templateName} document ${index} image`
			).toBeGreaterThan(0);
			const imageUrl = new URL(document.image as string);
			expect(imageUrl.protocol, `${templateName} document ${index} image protocol`).toBe('https:');
			const imageHostname = imageUrl.hostname.toLowerCase();
			const imageOwnerAndPath = `${imageHostname}${imageUrl.pathname}`;
			for (const brokenHost of brokenImageHosts) {
				expect(
					imageHostname === brokenHost || imageHostname.endsWith(`.${brokenHost}`),
					`${templateName} document ${index} image must not use ${brokenHost}`
				).toBe(false);
			}
			for (const brokenOwnerPath of brokenImageOwnerPaths) {
				expect(
					imageOwnerAndPath.startsWith(brokenOwnerPath),
					`${templateName} document ${index} image must not use ${brokenOwnerPath}`
				).toBe(false);
			}
			expect(
				imageUrl.pathname.split('/').filter(Boolean),
				`${templateName} document ${index} image path`
			).not.toContain(brokenImagePathSegment.slice(1));
			expect(typeof document.license).toBe('string');
			expect((document.license as string).length).toBeGreaterThan(0);
		}
	}

	it('contains one local payload owner with expected document counts', () => {
		expect(indexTemplateServerSnapshots.empty.documents).toHaveLength(0);
		expect(indexTemplateServerSnapshots.movies.documents).toHaveLength(1000);
		expect(indexTemplateServerSnapshots.products.documents).toHaveLength(1000);
	});

	it('locks movies settings, synonyms, and rules contract', () => {
		expect(indexTemplateServerSnapshots.movies.settings).toEqual({
			searchableAttributes: ['title', 'overview', 'director'],
			attributesForFaceting: ['genre', 'director', 'year'],
			attributesToHighlight: ['title', 'overview', 'director']
		});
		expect(indexTemplateServerSnapshots.movies.synonyms).toHaveLength(8);
		expect(indexTemplateServerSnapshots.movies.rules).toHaveLength(2);
	});

	it('locks products settings, synonyms, and rules contract', () => {
		expect(indexTemplateServerSnapshots.products.settings).toEqual({
			searchableAttributes: ['name', 'description', 'brand', 'category'],
			attributesForFaceting: ['category', 'brand', 'inStock'],
			attributesToHighlight: ['name', 'description']
		});
		expect(indexTemplateServerSnapshots.products.synonyms).toHaveLength(8);
		expect(indexTemplateServerSnapshots.products.rules).toHaveLength(2);
	});

	it('ships an image and license string on every movies record for card-slot binding', () => {
		const documents = indexTemplateServerSnapshots.movies.documents as Array<
			Record<string, unknown>
		>;
		assertTemplateDocumentsShipValidImages({
			templateName: 'movies',
			documents,
			expectedKeys: movieDocumentKeys
		});
	});

	it('ships an image and license string on every products record for card-slot binding', () => {
		const documents = indexTemplateServerSnapshots.products.documents as Array<
			Record<string, unknown>
		>;
		assertTemplateDocumentsShipValidImages({
			templateName: 'products',
			documents,
			expectedKeys: productDocumentKeys
		});
	});

	it('does not reject safe image paths that only mention example.com outside the owner', () => {
		assertTemplateDocumentsShipValidImages({
			templateName: 'movies',
			documents: [
				createMovieContractDocument('https://cdn.safe.test/assets/example.com-poster.jpg')
			],
			expectedKeys: movieDocumentKeys
		});
	});
});
