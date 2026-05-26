export const COUNTRY_NAMES: Record<string, string> = {
	US: 'United States',
	GB: 'United Kingdom',
	DE: 'Germany',
	FR: 'France',
	CA: 'Canada',
	AU: 'Australia',
	NL: 'Netherlands',
	JP: 'Japan',
	BR: 'Brazil',
	IN: 'India',
	ES: 'Spain',
	IT: 'Italy',
	SE: 'Sweden',
	MX: 'Mexico',
	KR: 'South Korea',
	SG: 'Singapore',
	CN: 'China',
	RU: 'Russia',
	PL: 'Poland',
	CH: 'Switzerland',
	AT: 'Austria',
	BE: 'Belgium',
	DK: 'Denmark',
	NO: 'Norway',
	FI: 'Finland',
	IE: 'Ireland',
	PT: 'Portugal',
	NZ: 'New Zealand',
	AR: 'Argentina',
	CL: 'Chile',
	CO: 'Colombia',
	ZA: 'South Africa',
	IL: 'Israel',
	TH: 'Thailand',
	MY: 'Malaysia',
	PH: 'Philippines',
	ID: 'Indonesia',
	TW: 'Taiwan',
	HK: 'Hong Kong',
	AE: 'United Arab Emirates'
};

export function countryFlag(code: string): string {
	try {
		const normalizedCode = code.toUpperCase();
		return String.fromCodePoint(
			...normalizedCode.split('').map((char) => 0x1f1e6 + char.charCodeAt(0) - 65)
		);
	} catch {
		return code;
	}
}
