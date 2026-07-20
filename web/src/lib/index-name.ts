/**
 * Canonical destination index-name rules.
 *
 * The rule set is extracted verbatim from the onboarding create-index form,
 * which held the fullest version of it (required, length, boundary, charset,
 * reserved). Keeping it here gives the rules one owner that callers import
 * instead of restating.
 *
 * Every path that creates an index imports these rules: the onboarding form,
 * the console create dialog, and the console create action. The console's
 * lookup and delete paths deliberately do not — they identify indexes that
 * already exist, which may predate these rules, and only need their names to be
 * safe path segments.
 */

export const INDEX_NAME_MAX_LENGTH = 64;

export const RESERVED_INDEX_NAMES: ReadonlySet<string> = new Set([
	'_internal',
	'health',
	'metrics'
]);

/** Suffix used to move a proposal clear of the reserved set. */
const RESERVED_DISAMBIGUATION_SUFFIX = '-import';

/** Proposal used when a source name contributes no usable characters at all. */
const FALLBACK_DESTINATION_NAME = 'imported-index';

function isAsciiAlphaNumeric(char: string | undefined): boolean {
	return Boolean(
		char &&
		((char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9'))
	);
}

function isAllowedIndexNameCharacter(char: string): boolean {
	return isAsciiAlphaNumeric(char) || char === '-' || char === '_';
}

function hasOnlyAllowedIndexNameCharacters(name: string): boolean {
	for (const char of name) {
		if (!isAllowedIndexNameCharacter(char)) {
			return false;
		}
	}

	return true;
}

/**
 * Returns a customer-facing message describing why `name` is unusable, or
 * `null` when the name is valid.
 */
export function validateIndexName(name: string): string | null {
	if (!name) return 'Index name is required';
	if (name.length > INDEX_NAME_MAX_LENGTH)
		return `Index name must be ${INDEX_NAME_MAX_LENGTH} characters or less`;
	if (!isAsciiAlphaNumeric(name[0]) || !isAsciiAlphaNumeric(name[name.length - 1]))
		return 'Index name must start and end with a letter or number';
	if (!hasOnlyAllowedIndexNameCharacters(name))
		return 'Only letters, numbers, hyphens, and underscores allowed';
	if (RESERVED_INDEX_NAMES.has(name)) return 'This name is reserved';
	return null;
}

/** Drop separator characters that the boundary rule forbids at either end. */
function trimBoundarySeparators(name: string): string {
	return name.replace(/^[-_]+/, '').replace(/[-_]+$/, '');
}

/**
 * Derives a valid destination index name from an Algolia source index name.
 *
 * This is a *proposal* only: it is seeded into an editable field and carries no
 * authority over whether the destination is actually available. Collision
 * authority stays with the producer's destination-eligibility response, so this
 * function deliberately consults no catalog of existing destinations.
 *
 * The mapping is pure and deterministic — the same source name always yields
 * the same proposal — and its result always satisfies `validateIndexName`.
 */
export function proposeDestinationIndexName(sourceName: string): string {
	// Decompose accents so a base ASCII letter survives, then drop the combining
	// marks: `café` folds to `cafe` rather than losing the whole character.
	const asciiFolded = sourceName.normalize('NFKD').replace(/[\u0300-\u036f]/g, '');

	// Any run of disallowed characters collapses to a single hyphen so that
	// spacing and punctuation do not produce separator pileups.
	const separated = asciiFolded.replace(/[^a-zA-Z0-9_-]+/g, '-');

	const trimmed = trimBoundarySeparators(separated);
	if (trimmed === '') {
		return FALLBACK_DESTINATION_NAME;
	}

	const disambiguated = RESERVED_INDEX_NAMES.has(trimmed)
		? `${trimmed}${RESERVED_DISAMBIGUATION_SUFFIX}`
		: trimmed;

	// Truncation can land on a separator, which the boundary rule forbids, so
	// trim again after cutting rather than before.
	return trimBoundarySeparators(disambiguated.slice(0, INDEX_NAME_MAX_LENGTH));
}
