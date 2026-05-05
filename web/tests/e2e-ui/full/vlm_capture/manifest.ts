import {
	CAPTURE_TUPLES,
	PRODUCIBLE_CAPTURE_COUNT,
	captureArtifactFilename,
	isProducibleSetup
} from './tuples.ts';

export type CaptureManifestEntry = {
	lane: string;
	path: string;
	route_slug: string;
	state: string;
	viewport: string;
	setup: string;
	is_producible: boolean;
	artifact_filename: string;
	artifact_relpath: string;
	screen_spec_path: string;
	uncovered_reason: string | null;
};

export type CaptureManifest = {
	source: string;
	producible_capture_count: number;
	total_tuple_count: number;
	entries: CaptureManifestEntry[];
};

const SCREEN_SPEC_BY_ROUTE_SLUG: Record<string, string> = {
	dashboard: 'docs/screen_specs/dashboard.md',
	admin_customers: 'docs/screen_specs/admin_customers.md',
	terms: 'docs/screen_specs/terms.md',
	privacy: 'docs/screen_specs/privacy.md',
	dpa: 'docs/screen_specs/dpa.md'
};

const UNPRODUCIBLE_SETUP = 'unproducible_requires_server_side_mocking';

export function buildCaptureManifest(): CaptureManifest {
	const entries: CaptureManifestEntry[] = CAPTURE_TUPLES.map((tuple) => {
		const screenSpecPath = SCREEN_SPEC_BY_ROUTE_SLUG[tuple.routeSlug];
		if (!screenSpecPath) {
			throw new Error(`No screen spec mapping for routeSlug=${tuple.routeSlug}`);
		}

		const artifactFilename = captureArtifactFilename(tuple);
		const isProducible = isProducibleSetup(tuple.setup);

		return {
			lane: tuple.lane,
			path: tuple.path,
			route_slug: tuple.routeSlug,
			state: tuple.state,
			viewport: tuple.viewport,
			setup: tuple.setup,
			is_producible: isProducible,
			artifact_filename: artifactFilename,
			artifact_relpath: `web/tmp/screens/${artifactFilename}`,
			screen_spec_path: screenSpecPath,
			uncovered_reason: isProducible ? null : UNPRODUCIBLE_SETUP
		};
	});

	return {
		source: 'web/tests/e2e-ui/full/vlm_capture/tuples.ts',
		producible_capture_count: PRODUCIBLE_CAPTURE_COUNT,
		total_tuple_count: CAPTURE_TUPLES.length,
		entries
	};
}
