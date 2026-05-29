import { spawn, spawnSync } from "node:child_process";
import {
	chmod,
	mkdir,
	readdir,
	readFile,
	rm,
	stat,
	writeFile,
} from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";

export const repoRoot = findRepoRoot();
export const mobileDir = pathFromEnv("XGX_ANDROID_MOBILE_DIR", "frontend-enduser");
export const credentialsDir = pathFromEnv(
	"XGX_ANDROID_CREDENTIALS_DIR",
	".credentials/android",
);
export const keystorePath = join(credentialsDir, "upload-keystore.jks");
export const googlePlayJsonPath = join(
	credentialsDir,
	"google-play-service-account.json",
);
export const firebaseGoogleServicesJsonPath = googleServicesJsonPathFromEnv();
export const easCredentialsPath = join(mobileDir, "credentials.json");

export type AndroidCredentialsOptions = {
	includeAndroidSigning?: boolean;
	includeFirebaseGoogleServices?: boolean;
	includeGooglePlay?: boolean;
};

export type PreparedAndroidCredentials = {
	firebaseGoogleServicesJsonPath?: string;
	easCredentialsPath?: string;
	googlePlayJsonPath?: string;
	keystorePath?: string;
	writtenPaths: string[];
};

type EnvMap = Record<string, string | undefined>;

const secretNames = {
	keystoreBase64: [
		"ANDROID_KEYSTORE_BASE64",
		"ANDROID_KEYSTORE_B64",
		"ANDROID_UPLOAD_KEYSTORE_BASE64",
	],
	keystorePassword: ["ANDROID_KEYSTORE_PASSWORD", "ANDROID_UPLOAD_STORE_PASSWORD"],
	keyAlias: ["ANDROID_KEY_ALIAS", "ANDROID_UPLOAD_KEY_ALIAS"],
	keyPassword: ["ANDROID_KEY_PASSWORD", "ANDROID_UPLOAD_KEY_PASSWORD"],
	googlePlayJsonBase64: [
		"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64",
		"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_B64",
	],
	googlePlayJson: ["GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"],
	firebaseGoogleServicesJsonBase64: [
		"FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_BASE64",
		"FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64",
		"ANDROID_GOOGLE_SERVICES_JSON_BASE64",
		"ANDROID_GOOGLE_SERVICES_JSON_B64",
		"GOOGLE_SERVICES_JSON_BASE64",
		"GOOGLE_SERVICES_JSON_B64",
	],
	firebaseGoogleServicesJson: [
		"FIREBASE_ANDROID_GOOGLE_SERVICES_JSON",
		"ANDROID_GOOGLE_SERVICES_JSON",
		"GOOGLE_SERVICES_JSON",
	],
};

function findRepoRoot(): string {
	const explicitRoot =
		process.env.XGX_ANDROID_PROJECT_ROOT?.trim() || process.env.RUNTIME_ROOT?.trim();
	if (explicitRoot) return resolve(explicitRoot);

	const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
		cwd: process.cwd(),
		encoding: "utf8",
		stdio: ["ignore", "pipe", "ignore"],
	});
	if (result.status === 0 && result.stdout.trim()) {
		return resolve(result.stdout.trim());
	}

	return resolve(process.cwd());
}

function pathFromEnv(name: string, defaultPath: string): string {
	return resolveFromRepo(process.env[name]?.trim() || defaultPath);
}

function googleServicesJsonPathFromEnv(): string {
	const configuredPath = process.env.XGX_ANDROID_GOOGLE_SERVICES_FILE?.trim();
	if (configuredPath) return resolveFromRepo(configuredPath);
	return join(mobileDir, "google-services.json");
}

export function usageError(message: string): never {
	throw new Error(message);
}

export async function pathExists(path: string): Promise<boolean> {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}

export function normalisePathForJson(path: string): string {
	return path.split(sep).join("/");
}

function parseDotEnv(contents: string): Record<string, string> {
	const env: Record<string, string> = {};

	for (const rawLine of contents.split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line || line.startsWith("#")) continue;

		const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
		if (!match) continue;

		env[match[1]] = parseDotEnvValue(match[2].trim());
	}

	return env;
}

function parseDotEnvValue(value: string): string {
	if (value.startsWith("\"") && value.endsWith("\"")) {
		return value
			.slice(1, -1)
			.replace(/\\n/g, "\n")
			.replace(/\\"/g, "\"")
			.replace(/\\\\/g, "\\");
	}

	if (value.startsWith("'") && value.endsWith("'")) {
		return value.slice(1, -1);
	}

	const commentIndex = value.indexOf(" #");
	return commentIndex === -1 ? value : value.slice(0, commentIndex).trim();
}

function decryptSecretsEnv(): Record<string, string> {
	const secretsPath = resolveFromRepo(
		process.env.XGX_ANDROID_SECRETS_FILE?.trim() ||
			process.env.XGX_SECRETS_FILE?.trim() ||
			"secrets.env",
	);
	const result = spawnSync("sops", ["-d", secretsPath], {
		cwd: repoRoot,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
	});

	if (result.status !== 0 || !result.stdout) return {};
	return parseDotEnv(result.stdout);
}

export function loadAndroidReleaseEnv(): EnvMap {
	return {
		...decryptSecretsEnv(),
		...process.env,
	};
}

export function envValue(env: EnvMap, names: string[]): string | undefined {
	for (const name of names) {
		const value = env[name];
		if (value?.trim()) return value.trim();
	}
	return undefined;
}

function requireEnvValue(env: EnvMap, names: string[], description: string): string {
	const value = envValue(env, names);
	if (!value) {
		usageError(
			`Missing ${description}. Set one of: ${names.join(", ")} in encrypted secrets.env.`,
		);
	}
	return value;
}

function decodeBase64(value: string, description: string): Buffer {
	try {
		return Buffer.from(value.replace(/\s/g, ""), "base64");
	} catch (error) {
		throw new Error(`Failed to decode ${description} as base64: ${String(error)}`);
	}
}

function decodeGooglePlayJson(env: EnvMap): string {
	const encoded = envValue(env, secretNames.googlePlayJsonBase64);
	const raw = encoded
		? decodeBase64(encoded, "Google Play service account JSON").toString("utf8")
		: requireEnvValue(
				env,
				secretNames.googlePlayJson,
				"Google Play service account JSON",
			);

	try {
		const parsed = JSON.parse(raw);
		if (!parsed.client_email || !parsed.private_key) {
			throw new Error("JSON does not look like a Google service account key");
		}
		return `${JSON.stringify(parsed, null, 2)}\n`;
	} catch (error) {
		throw new Error(`Invalid Google Play service account JSON: ${String(error)}`);
	}
}

async function decodeFirebaseGoogleServicesJson(env: EnvMap): Promise<string> {
	const encoded = envValue(env, secretNames.firebaseGoogleServicesJsonBase64);
	const raw = encoded
		? decodeBase64(encoded, "Firebase google-services.json").toString("utf8")
		: requireEnvValue(
				env,
				secretNames.firebaseGoogleServicesJson,
				"Firebase google-services.json",
			);

	try {
		const parsed = JSON.parse(raw);
		const { packageName } = await readAndroidAppConfig();
		const clients = Array.isArray(parsed.client) ? parsed.client : [];
		const hasMatchingPackage = clients.some(
			(client) =>
				client?.client_info?.android_client_info?.package_name === packageName,
		);

		if (!hasMatchingPackage) {
			throw new Error(
				`JSON does not contain an Android client for package ${packageName}`,
			);
		}

		return `${JSON.stringify(parsed, null, 2)}\n`;
	} catch (error) {
		throw new Error(`Invalid Firebase google-services.json: ${String(error)}`);
	}
}

export async function prepareAndroidCredentials(
	options: AndroidCredentialsOptions = {},
): Promise<PreparedAndroidCredentials> {
	const includeAndroidSigning = options.includeAndroidSigning ?? true;
	const includeFirebaseGoogleServices =
		options.includeFirebaseGoogleServices ?? false;
	const includeGooglePlay = options.includeGooglePlay ?? false;
	const env = loadAndroidReleaseEnv();
	const writtenPaths: string[] = [];

	await mkdir(credentialsDir, { recursive: true, mode: 0o700 });

	let preparedKeystorePath: string | undefined;
	let preparedEasCredentialsPath: string | undefined;
	let preparedFirebaseGoogleServicesJsonPath: string | undefined;
	let preparedGooglePlayJsonPath: string | undefined;

	if (includeAndroidSigning) {
		const keystoreBase64 = requireEnvValue(
			env,
			secretNames.keystoreBase64,
			"Android keystore",
		);
		const keystorePassword = requireEnvValue(
			env,
			secretNames.keystorePassword,
			"Android keystore password",
		);
		const keyAlias = requireEnvValue(env, secretNames.keyAlias, "Android key alias");
		const keyPassword = requireEnvValue(
			env,
			secretNames.keyPassword,
			"Android key password",
		);

		await writeFile(keystorePath, decodeBase64(keystoreBase64, "Android keystore"), {
			mode: 0o600,
		});
		await chmod(keystorePath, 0o600);
		writtenPaths.push(keystorePath);

		const relativeKeystorePath = normalisePathForJson(
			relative(mobileDir, keystorePath),
		);
		const easCredentials = {
			android: {
				keystore: {
					keystorePath: relativeKeystorePath,
					keystorePassword,
					keyAlias,
					keyPassword,
				},
			},
		};

		await writeFile(
			easCredentialsPath,
			`${JSON.stringify(easCredentials, null, 2)}\n`,
			{ mode: 0o600 },
		);
		await chmod(easCredentialsPath, 0o600);
		writtenPaths.push(easCredentialsPath);

		preparedKeystorePath = keystorePath;
		preparedEasCredentialsPath = easCredentialsPath;
	}

	if (includeFirebaseGoogleServices) {
		await writeFile(
			firebaseGoogleServicesJsonPath,
			await decodeFirebaseGoogleServicesJson(env),
			{ mode: 0o600 },
		);
		await chmod(firebaseGoogleServicesJsonPath, 0o600);
		writtenPaths.push(firebaseGoogleServicesJsonPath);
		preparedFirebaseGoogleServicesJsonPath = firebaseGoogleServicesJsonPath;
	}

	if (includeGooglePlay) {
		await writeFile(googlePlayJsonPath, decodeGooglePlayJson(env), { mode: 0o600 });
		await chmod(googlePlayJsonPath, 0o600);
		writtenPaths.push(googlePlayJsonPath);
		preparedGooglePlayJsonPath = googlePlayJsonPath;
	}

	return {
		easCredentialsPath: preparedEasCredentialsPath,
		firebaseGoogleServicesJsonPath: preparedFirebaseGoogleServicesJsonPath,
		googlePlayJsonPath: preparedGooglePlayJsonPath,
		keystorePath: preparedKeystorePath,
		writtenPaths,
	};
}

export async function cleanupAndroidCredentials(paths?: string[]): Promise<void> {
	const cleanupPaths = paths ?? [
		easCredentialsPath,
		keystorePath,
		googlePlayJsonPath,
		firebaseGoogleServicesJsonPath,
	];

	for (const path of cleanupPaths) {
		await rm(path, { force: true });
	}
}

export function runCommand(
	command: string,
	args: string[],
	options: {
		cwd?: string;
		env?: Record<string, string | undefined>;
		redactOutput?: boolean;
	} = {},
): void {
	console.log(`$ ${[command, ...args].join(" ")}`);
	const result = spawnSync(command, args, {
		cwd: options.cwd ?? repoRoot,
		encoding: "utf8",
		env: {
			...process.env,
			...options.env,
		},
		maxBuffer: 200 * 1024 * 1024,
		stdio: options.redactOutput ? ["ignore", "pipe", "pipe"] : "inherit",
	});

	if (options.redactOutput) {
		if (result.stdout) process.stdout.write(redactCommandOutput(result.stdout));
		if (result.stderr) process.stderr.write(redactCommandOutput(result.stderr));
	}

	if (result.error) throw result.error;
	if (result.status !== 0) {
		throw new Error(`${command} exited with status ${result.status ?? "unknown"}`);
	}
}

function redactCommandOutput(output: string): string {
	return output
		.replace(/"dataBase64":"[^"]+"/g, "\"dataBase64\":\"[redacted]\"")
		.replace(/"keystorePassword":"[^"]+"/g, "\"keystorePassword\":\"[redacted]\"")
		.replace(/"keyPassword":"[^"]+"/g, "\"keyPassword\":\"[redacted]\"")
		.replace(
			/(eas-cli-local-build-plugin@\S+\s+)[A-Za-z0-9+/=]{200,}(\s+exited with non-zero code: \d+)/g,
			"$1[redacted-eas-job]$2",
		)
		.replace(/[A-Za-z0-9+/=]{1200,}/g, "[redacted-base64]");
}

export function installMobileDependencies(): void {
	runCommand("bun", ["install", "--frozen-lockfile"], { cwd: mobileDir });
}

export async function runCommandStreaming(
	command: string,
	args: string[],
	options: { cwd?: string; env?: Record<string, string | undefined> } = {},
): Promise<void> {
	console.log(`$ ${[command, ...args].join(" ")}`);

	const child = spawn(command, args, {
		cwd: options.cwd ?? repoRoot,
		env: {
			...process.env,
			...options.env,
		},
		stdio: ["ignore", "pipe", "pipe"],
	});
	const stdout = createRedactedWriter((output) => process.stdout.write(output));
	const stderr = createRedactedWriter((output) => process.stderr.write(output));

	child.stdout.on("data", (chunk) => stdout.write(String(chunk)));
	child.stderr.on("data", (chunk) => stderr.write(String(chunk)));

	await new Promise<void>((resolvePromise, reject) => {
		child.on("error", reject);
		child.on("close", (status) => {
			stdout.flush();
			stderr.flush();

			if (status === 0) {
				resolvePromise();
			} else {
				reject(new Error(`${command} exited with status ${status ?? "unknown"}`));
			}
		});
	});
}

function createRedactedWriter(writeOutput: (output: string) => void) {
	let pending = "";

	return {
		flush() {
			if (!pending) return;
			writeOutput(redactCommandOutput(pending));
			pending = "";
		},
		write(chunk: string) {
			pending += chunk;
			const lines = pending.split(/\r?\n/);
			pending = lines.pop() ?? "";

			for (const line of lines) {
				writeOutput(`${redactCommandOutput(line)}\n`);
			}

			if (pending.length > 20_000) {
				const flushable = pending.slice(0, -1_000);
				pending = pending.slice(-1_000);
				writeOutput(redactCommandOutput(flushable));
			}
		},
	};
}

export function readArgValue(args: string[], flag: string): string | undefined {
	const index = args.indexOf(flag);
	if (index === -1) return undefined;
	const value = args[index + 1];
	if (!value || value.startsWith("--")) {
		usageError(`Expected a value after ${flag}`);
	}
	return value;
}

export function withoutArgs(args: string[], flags: string[]): string[] {
	const result: string[] = [];
	for (let index = 0; index < args.length; index++) {
		const arg = args[index];
		if (flags.includes(arg)) {
			index++;
			continue;
		}
		result.push(arg);
	}
	return result;
}

export async function readAndroidPackageName(): Promise<string> {
	return (await readAndroidAppConfig()).packageName;
}

async function readAndroidAppConfig(): Promise<{ packageName: string }> {
	const appJsonPath = join(mobileDir, "app.json");
	const appJson = JSON.parse(await readFile(appJsonPath, "utf8"));
	const packageName = appJson.expo?.android?.package;
	if (!packageName) {
		usageError(`${relative(repoRoot, appJsonPath)} does not define expo.android.package.`);
	}
	return { packageName };
}

export async function appDeclaresFirebaseGoogleServices(): Promise<boolean> {
	const appJsonPath = join(mobileDir, "app.json");
	const appJson = JSON.parse(await readFile(appJsonPath, "utf8"));
	return Boolean(appJson.expo?.android?.googleServicesFile);
}

export async function defaultAabPathForProfile(profile: string): Promise<string> {
	const configuredOutput = process.env.XGX_ANDROID_BUILD_OUTPUT?.trim();
	if (configuredOutput) {
		return resolveFromRepo(configuredOutput.replaceAll("{profile}", profile));
	}

	const { packageName } = await readAndroidAppConfig();
	const appSlug = packageName.split(".").at(-1)?.replace(/[^A-Za-z0-9._-]/g, "-");
	return join(mobileDir, "builds", `${appSlug || "android"}-${profile}.aab`);
}

async function collectFilesByExtension(dir: string, extension: string): Promise<string[]> {
	if (!(await pathExists(dir))) return [];

	const entries = await readdir(dir, { withFileTypes: true });
	const paths = await Promise.all(
		entries.map(async (entry) => {
			const path = join(dir, entry.name);
			if (entry.isDirectory()) return collectFilesByExtension(path, extension);
			return entry.isFile() && entry.name.endsWith(extension) ? [path] : [];
		}),
	);

	return paths.flat();
}

async function findLatestBuildArtifact(
	extension: string,
): Promise<string | undefined> {
	const candidates = await collectFilesByExtension(join(mobileDir, "builds"), extension);
	if (candidates.length === 0) return undefined;

	const withStats = await Promise.all(
		candidates.map(async (path) => ({
			path,
			mtimeMs: (await stat(path)).mtimeMs,
		})),
	);

	return withStats.sort((a, b) => b.mtimeMs - a.mtimeMs)[0]?.path;
}

export async function findLatestAab(): Promise<string | undefined> {
	return findLatestBuildArtifact(".aab");
}

export async function findLatestApk(): Promise<string | undefined> {
	return findLatestBuildArtifact(".apk");
}

export function resolveFromRepo(path: string): string {
	return resolve(repoRoot, path);
}

export function dirnameFor(path: string): string {
	return dirname(path);
}
