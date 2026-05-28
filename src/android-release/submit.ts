import {
	cleanupAndroidCredentials,
	findLatestAab,
	prepareAndroidCredentials,
	readAndroidPackageName,
	readArgValue,
	resolveFromRepo,
	runCommand,
	usageError,
	withoutArgs,
} from "./common.ts";

export type SubmitAndroidOptions = {
	aabPath?: string;
	extraFastlaneArgs?: string[];
	keepCredentials?: boolean;
	packageName?: string;
	releaseStatus?: string;
	track?: string;
};

const valueFlags = [
	"--aab",
	"--package-name",
	"--release-status",
	"--release_status",
	"--track",
];

function printHelp() {
	console.log(`Usage: xgx-android-submit [options] [extra fastlane args]

Submits an Android AAB directly to Google Play with fastlane supply.

Options:
  --aab <path>                 AAB to submit. Defaults to newest build output.
  --package-name <name>        Android package name. Defaults to expo.android.package.
  --track <track>              Play track. Defaults to XGX_ANDROID_DEFAULT_TRACK or production.
  --release-status <status>    Defaults to XGX_ANDROID_DEFAULT_RELEASE_STATUS or draft.
  --keep-credentials           Keep generated credential files after submit.
  --help                       Show this help.

Example:
  xgx-android-submit --track internal
`);
}

export function parseSubmitAndroidArgs(args: string[]): SubmitAndroidOptions {
	if (args.includes("--help")) {
		printHelp();
		process.exit(0);
	}

	const keepCredentials = args.includes("--keep-credentials");
	const extraFastlaneArgs = withoutArgs(
		args.filter((arg) => arg !== "--keep-credentials"),
		valueFlags,
	);

	return {
		aabPath: readArgValue(args, "--aab"),
		extraFastlaneArgs,
		keepCredentials,
		packageName: readArgValue(args, "--package-name"),
		releaseStatus:
			readArgValue(args, "--release-status") ??
			readArgValue(args, "--release_status") ??
			process.env.XGX_ANDROID_DEFAULT_RELEASE_STATUS ??
			"draft",
		track:
			readArgValue(args, "--track") ??
			process.env.XGX_ANDROID_DEFAULT_TRACK ??
			"production",
	};
}

export async function submitAndroid(options: SubmitAndroidOptions = {}): Promise<void> {
	const aabPath = options.aabPath
		? resolveFromRepo(options.aabPath)
		: await findLatestAab();
	if (!aabPath) {
		usageError("No AAB found. Run bun run build:android first or pass --aab <path>.");
	}

	const packageName = options.packageName ?? (await readAndroidPackageName());
	const track = options.track ?? process.env.XGX_ANDROID_DEFAULT_TRACK ?? "production";
	const releaseStatus =
		options.releaseStatus ??
		process.env.XGX_ANDROID_DEFAULT_RELEASE_STATUS ??
		"draft";
	const extraFastlaneArgs = options.extraFastlaneArgs ?? [];
	const credentials = await prepareAndroidCredentials({
		includeAndroidSigning: false,
		includeGooglePlay: true,
	});

	try {
		if (!credentials.googlePlayJsonPath) {
			usageError("Google Play JSON was not materialised.");
		}

		runCommand("fastlane", [
			"supply",
			"--aab",
			aabPath,
			"--json_key",
			credentials.googlePlayJsonPath,
			"--package_name",
			packageName,
			"--track",
			track,
			"--release_status",
			releaseStatus,
			"--skip_upload_metadata",
			"true",
			"--skip_upload_changelogs",
			"true",
			"--skip_upload_images",
			"true",
			"--skip_upload_screenshots",
			"true",
			...extraFastlaneArgs,
		]);
	} finally {
		if (!options.keepCredentials) {
			await cleanupAndroidCredentials(credentials.writtenPaths);
		}
	}
}

if (import.meta.main) {
	submitAndroid(parseSubmitAndroidArgs(process.argv.slice(2))).catch((error) => {
		console.error(error instanceof Error ? error.message : error);
		process.exit(1);
	});
}
