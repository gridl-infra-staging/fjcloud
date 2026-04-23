import { decodeJwt, isJwtExpired, isJwtHs256SignatureValid } from './jwt';

export interface AuthUser {
	customerId: string;
	token: string;
}

export function resolveAuth(cookieValue: string | undefined, jwtSecret: string | undefined): AuthUser | null {
	if (!cookieValue) return null;
	if (!jwtSecret) return null;
	if (!isJwtHs256SignatureValid(cookieValue, jwtSecret)) return null;

	const payload = decodeJwt(cookieValue);
	if (!payload) return null;

	if (isJwtExpired(payload)) return null;

	return { customerId: payload.sub, token: cookieValue };
}
