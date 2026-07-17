// Synonym types (multi-way, one-way, alt correction 1/2, and placeholder).

export type SynonymType =
	| 'synonym'
	| 'onewaysynonym'
	| 'altcorrection1'
	| 'altcorrection2'
	| 'placeholder';

export interface SynonymBase {
	objectID: string;
	type: SynonymType;
}

export interface MultiWaySynonym extends SynonymBase {
	type: 'synonym';
	synonyms: string[];
}

export interface OneWaySynonym extends SynonymBase {
	type: 'onewaysynonym';
	input: string;
	synonyms: string[];
}

export interface AltCorrection1Synonym extends SynonymBase {
	type: 'altcorrection1';
	word: string;
	corrections: string[];
}

export interface AltCorrection2Synonym extends SynonymBase {
	type: 'altcorrection2';
	word: string;
	corrections: string[];
}

export interface PlaceholderSynonym extends SynonymBase {
	type: 'placeholder';
	placeholder: string;
	replacements: string[];
}

export type Synonym =
	| MultiWaySynonym
	| OneWaySynonym
	| AltCorrection1Synonym
	| AltCorrection2Synonym
	| PlaceholderSynonym;

export interface SynonymSearchResponse {
	hits: Synonym[];
	nbHits: number;
}
