import { env } from '$env/dynamic/private';

export type RuntimeEnv = Record<string, string | undefined>;

export type RuntimePlatform = {
	env?: RuntimeEnv;
};

export function privateEnvValue(name: string, platform?: RuntimePlatform): string | undefined {
	return env[name] ?? platform?.env?.[name];
}
