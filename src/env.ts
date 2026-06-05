export type EnvSource = Record<string, string | undefined>;

/**
 * Reads the first configured environment value from an explicit source.
 *
 * Pass names in priority order. The first name is the preferred variable, and
 * later names are fallback aliases. Empty strings are treated as missing.
 *
 * @example
 * const appUrl = envFrom(import.meta.env, "VITE_APP_URL", "VITE_PUBLIC_URL");
 *
 * @example
 * const databaseUrl = envFrom(process.env, "DATABASE_URL");
 *
 * @throws Error when none of the provided names has a value.
 */
export function envFrom(source: EnvSource, ...names: [string, ...string[]]) {
	for (const name of names) {
		const value = source[name];
		if (value) return value;
	}

	throw new Error(`${names.join(" or ")} is required`);
}

/**
 * Reads the first configured value from `process.env`.
 *
 * This is for server-side scripts and runtimes. Browser/Vite code should use
 * `envFrom(import.meta.env, ...)` so bundlers can statically expose public env.
 *
 * @example
 * const port = env("PORT", "APP_PORT");
 *
 * @throws Error when none of the provided names has a value.
 */
export function env(...names: [string, ...string[]]) {
	return envFrom(process.env, ...names);
}
