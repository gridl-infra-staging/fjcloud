/**
 * Customer journeys auth setup — runs once before the chromium:customer-journeys project.
 *
 * Creates a second brand-new customer account through the shared onboarding
 * setup helper so the long-form journey spec does not consume the same fresh
 * storage state that onboarding.spec.ts relies on.
 */

import path from 'path';
import { fileURLToPath } from 'url';
import { registerFreshOnboardingAccount } from './onboarding-auth-shared';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CUSTOMER_JOURNEYS_AUTH_FILE = path.join(__dirname, '.auth/customer-journeys.json');

registerFreshOnboardingAccount(
	'create fresh account for customer journeys',
	CUSTOMER_JOURNEYS_AUTH_FILE
);
