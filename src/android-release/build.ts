import { mkdir } from "node:fs/promises";
import {
	cleanupAndroidCredentials,
	defaultAabPathForProfile,
	dirnameFor,
	installMobileDependencies,
	mobileDir,
	prepareAndroidCredentials,
	resolveFromRepo,
	runCommandStreaming,
	usageError,
	withoutArgs,
} from "./common.ts";

export type BuildAndroidOptions = {
	extraEasArgs?: string[];
	keepCredentials?: boolean;
	output?: string;
	profile?: string;
};

const valueFlags = ["--profile", "--output"];

function printHelp() {
	console.log(`Usage: xgx-android-build [options] [extra eas args]

Builds a local Android AAB with EAS Build using local signing credentials.

Options:
  --profile <name>       EAS build profile. Defaults to XGX_ANDROID_DEFAULT_PROFILE or production.
  --output <path>        AAB output path. Overrides XGX_ANDROID_BUILD_OUTPUT.
  --keep-credentials     Keep generated credential files after the build.
  --help                 Show this help.
`);
}

export function parseBuildAndroidArgs(args: string[]): BuildAndroidOptions {
	if (args.includes("--help")) {
		printHelp();
		process.exit(0);
	}

	const profile =
		readValue(args, "--profile") ??
		process.env.XGX_ANDROID_DEFAULT_PROFILE ??
		"production";
	const output = readValue(args, "--output");
	const keepCredentials = args.includes("--keep-credentials");
	const extraEasArgs = withoutArgs(
		args.filter((arg) => arg !== "--keep-credentials"),
		valueFlags,
	);

	return {
		extraEasArgs,
		keepCredentials,
		output,
		profile,
	};
}

function readValue(args: string[], flag: string): string | undefined {
	const index = args.indexOf(flag);
	if (index === -1) return undefined;

	const value = args[index + 1];
	if (!value || value.startsWith("--")) usageError(`Expected a value after ${flag}`);
	return value;
}

export async function buildAndroid(options: BuildAndroidOptions = {}): Promise<string> {
	const profile =
		options.profile ?? process.env.XGX_ANDROID_DEFAULT_PROFILE ?? "production";
	const output = options.output
		? resolveFromRepo(options.output)
		: await defaultAabPathForProfile(profile);
	const extraEasArgs = options.extraEasArgs ?? [];
	const credentials = await prepareAndroidCredentials({ includeAndroidSigning: true });

	try {
		await mkdir(dirnameFor(output), { recursive: true });
		installMobileDependencies();
		await runCommandStreaming(
			"eas",
			[
				"build",
				"--platform",
				"android",
				"--profile",
				profile,
				"--local",
				"--non-interactive",
				"--output",
				output,
				...extraEasArgs,
			],
			{
				cwd: mobileDir,
				env: buildAndroidEnv(),
			},
		);
		return output;
	} finally {
		if (!options.keepCredentials) {
			await cleanupAndroidCredentials(credentials.writtenPaths);
		}
	}
}

function buildAndroidEnv(): Record<string, string> {
	const gradleJvmArgs = "-Xmx6g -XX:MaxMetaspaceSize=2g -Dfile.encoding=UTF-8";
	const gradleOpts = [
		process.env.GRADLE_OPTS,
		`-Dorg.gradle.jvmargs="${gradleJvmArgs}"`,
	]
		.filter(Boolean)
		.join(" ");

	return {
		GRADLE_OPTS: gradleOpts,
		NODE_ENV: "production",
	};
}

if (import.meta.main) {
	buildAndroid(parseBuildAndroidArgs(process.argv.slice(2)))
		.then((output) => {
			console.log(`Android AAB: ${output}`);
		})
		.catch((error) => {
			console.error(error instanceof Error ? error.message : error);
			process.exit(1);
		});
}
