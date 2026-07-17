/**
 * Onboarding auth setup — runs once before the chromium:onboarding project.
 *
 * Creates a brand-new customer account through the shared onboarding setup
 * helper and saves that authenticated fresh-user session to
 * `tests/fixtures/.auth/onboarding.json`.
 */

import path from 'path';
import { fileURLToPath } from 'url';
import { registerFreshOnboardingAccount } from './onboarding-auth-shared';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ONBOARDING_AUTH_FILE = path.join(__dirname, '.auth/onboarding.json');

registerFreshOnboardingAccount('create fresh account for onboarding', ONBOARDING_AUTH_FILE);
