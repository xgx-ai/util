import { buildAndroid } from "./build.ts";
import { readArgValue } from "./common.ts";
import { submitAndroid } from "./submit.ts";

function printHelp() {
	console.log(`Usage: xgx-android-release [options]

Builds a local Android AAB, then submits it directly to Google Play with fastlane supply.

Options:
  --profile <name>             EAS build profile. Defaults to XGX_ANDROID_DEFAULT_PROFILE.
  --output <path>              AAB output path.
  --package-name <name>        Android package name. Defaults to expo.android.package.
  --track <track>              Play track. Defaults to XGX_ANDROID_DEFAULT_TRACK.
  --release-status <status>    Defaults to XGX_ANDROID_DEFAULT_RELEASE_STATUS.
  --keep-credentials           Keep generated credential files after release.
  --help                       Show this help.

Example:
  xgx-android-release --track internal
`);
}

async function main() {
	const args = process.argv.slice(2);
	if (args.includes("--help")) {
		printHelp();
		return;
	}

	const keepCredentials = args.includes("--keep-credentials");
	const output = await buildAndroid({
		keepCredentials,
		output: readArgValue(args, "--output"),
		profile: readArgValue(args, "--profile"),
	});

	await submitAndroid({
		aabPath: output,
		keepCredentials,
		packageName: readArgValue(args, "--package-name"),
		releaseStatus:
			readArgValue(args, "--release-status") ??
			readArgValue(args, "--release_status"),
		track: readArgValue(args, "--track"),
	});
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : error);
	process.exit(1);
});
