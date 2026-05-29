import {
	appDeclaresFirebaseGoogleServices,
	cleanupAndroidCredentials,
	firebaseGoogleServicesJsonPath,
	googlePlayJsonPath,
	prepareAndroidCredentials,
} from "./common.ts";

const args = process.argv.slice(2);

function printHelp() {
	console.log(`Usage: xgx-android-prepare-credentials [options]

Materialises Android release credentials from encrypted secrets.env into ignored local files.

Options:
  --google-play        Also materialise the Google Play service account JSON.
  --google-play-only   Only materialise the Google Play service account JSON.
  --google-services    Also materialise Firebase google-services.json.
  --google-services-only
                       Only materialise Firebase google-services.json.
  --cleanup            Remove generated Android credential files.
  --help               Show this help.

Required signing secrets:
  ANDROID_KEYSTORE_BASE64
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS
  ANDROID_KEY_PASSWORD

Required Google Play secret when --google-play is used:
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64

Required Firebase secret when --google-services is used, or when expo.android.googleServicesFile is configured:
  FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_BASE64
`);
}

async function main() {
	if (args.includes("--help")) {
		printHelp();
		return;
	}

	if (args.includes("--cleanup")) {
		await cleanupAndroidCredentials();
		console.log("Removed generated Android credential files.");
		return;
	}

	const googlePlayOnly = args.includes("--google-play-only");
	const googleServicesOnly = args.includes("--google-services-only");
	const includeGooglePlay = googlePlayOnly || args.includes("--google-play");
	const includeGoogleServices =
		googleServicesOnly ||
		args.includes("--google-services") ||
		(!googlePlayOnly && (await appDeclaresFirebaseGoogleServices()));
	const credentials = await prepareAndroidCredentials({
		includeAndroidSigning: !googlePlayOnly && !googleServicesOnly,
		includeFirebaseGoogleServices: includeGoogleServices,
		includeGooglePlay,
	});

	if (credentials.easCredentialsPath) {
		console.log(`EAS credentials: ${credentials.easCredentialsPath}`);
	}
	if (credentials.keystorePath) {
		console.log(`Android keystore: ${credentials.keystorePath}`);
	}
	if (credentials.firebaseGoogleServicesJsonPath) {
		console.log(`Firebase google-services.json: ${firebaseGoogleServicesJsonPath}`);
	}
	if (credentials.googlePlayJsonPath) {
		console.log(`Google Play JSON: ${credentials.googlePlayJsonPath}`);
		console.log(
			`Validate with: fastlane run validate_play_store_json_key json_key:${googlePlayJsonPath}`,
		);
	}
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : error);
	process.exit(1);
});
