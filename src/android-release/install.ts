import {
	findLatestApk,
	readAndroidPackageName,
	readArgValue,
	resolveFromRepo,
	runCommand,
	usageError,
	withoutArgs,
} from "./common.ts";

export type InstallAndroidOptions = {
	allowDowngrade?: boolean;
	apkPath?: string;
	device?: string;
	extraAdbArgs?: string[];
	uninstallFirst?: boolean;
};

const valueFlags = ["--apk", "--device"];

function printHelp() {
	console.log(`Usage: xgx-android-install [options] [extra adb install args]

Installs a locally built Android APK on a connected device with ADB.

Options:
  --apk <path>          APK to install. Defaults to newest build output.
  --device <serial>     ADB device serial when more than one device is connected.
  --allow-downgrade     Pass -d to adb install.
  --uninstall-first     Uninstall the app package before installing. Deletes app data.
  --help                Show this help.
`);
}

export function parseInstallAndroidArgs(args: string[]): InstallAndroidOptions {
	if (args.includes("--help")) {
		printHelp();
		process.exit(0);
	}

	const allowDowngrade = args.includes("--allow-downgrade");
	const uninstallFirst = args.includes("--uninstall-first");
	const filteredArgs = args.filter(
		(arg) => arg !== "--allow-downgrade" && arg !== "--uninstall-first",
	);

	return {
		allowDowngrade,
		apkPath: readArgValue(args, "--apk"),
		device: readArgValue(args, "--device"),
		extraAdbArgs: withoutArgs(filteredArgs, valueFlags),
		uninstallFirst,
	};
}

export async function installAndroid(
	options: InstallAndroidOptions = {},
): Promise<void> {
	const apkPath = options.apkPath
		? resolveFromRepo(options.apkPath)
		: await findLatestApk();
	if (!apkPath) {
		usageError("No APK found. Build one first or pass --apk <path>.");
	}

	const deviceArgs = options.device ? ["-s", options.device] : [];

	if (options.uninstallFirst) {
		runCommand("adb", [...deviceArgs, "uninstall", await readAndroidPackageName()]);
	}

	runCommand("adb", [
		...deviceArgs,
		"install",
		"-r",
		...(options.allowDowngrade ? ["-d"] : []),
		...(options.extraAdbArgs ?? []),
		apkPath,
	]);
}

if (import.meta.main) {
	installAndroid(parseInstallAndroidArgs(process.argv.slice(2))).catch((error) => {
		console.error(error instanceof Error ? error.message : error);
		process.exit(1);
	});
}
