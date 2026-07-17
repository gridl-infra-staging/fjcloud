// Personalization strategy and per-user profile types.

export interface PersonalizationEventScoring {
	eventName: string;
	eventType: 'click' | 'conversion' | 'view';
	score: number;
}

export interface PersonalizationFacetScoring {
	facetName: string;
	score: number;
}

export interface PersonalizationStrategy {
	eventsScoring: PersonalizationEventScoring[];
	facetsScoring: PersonalizationFacetScoring[];
	personalizationImpact: number;
}

export interface PersonalizationProfile {
	userToken: string;
	lastEventAt?: string | null;
	scores: Record<string, Record<string, number>>;
}
