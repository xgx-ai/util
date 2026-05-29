{pkgs}: config: let
  inherit (pkgs) lib;

  cfg =
    {
      androidSdkVersion = "36";
      buildToolsVersions = ["36.0.0" "35.0.0"];
      buildOutput = null;
      cmdLineToolsVersion = "latest";
      cmakeVersions = ["3.22.1"];
      credentialsDir = ".credentials/android";
      defaultProfile = "production";
      defaultReleaseStatus = "draft";
      defaultTrack = "production";
      env = {};
      extraPackages = _pkgs: [];
      gradleUserHome = ".data/gradle";
      androidUserHome = ".data/android";
      easLocalBuildWorkingDir = ".data/eas-build";
      easLocalBuildArtifactsDir = null;
      jdk = pkgs: pkgs.jdk17;
      mobileDir = "frontend-enduser";
      ndkVersion = "27.1.12297006";
      node = pkgs: pkgs.nodejs_22;
      reactNativeArchitectures = ["arm64-v8a"];
      secrets = {
        file = "secrets.env";
        loadIntoEnv = true;
      };
      shellHook = "";
    }
    // config;

  packageFrom = value:
    if builtins.isFunction value
    then value pkgs
    else value;

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    inherit (cfg) buildToolsVersions cmakeVersions cmdLineToolsVersion;
    platformVersions = [cfg.androidSdkVersion];
    includeNDK = true;
    ndkVersions = [cfg.ndkVersion];
    abiVersions = cfg.reactNativeArchitectures;
    includeCmake = cfg.cmakeVersions != [];
  };

  androidSdk = androidComposition.androidsdk;
  androidSdkRoot = "${androidSdk}/libexec/android-sdk";
  androidNdkRoot = "${androidSdkRoot}/ndk/${cfg.ndkVersion}";
  easLocalBuildArtifactsDir =
    if cfg.easLocalBuildArtifactsDir == null
    then "${cfg.mobileDir}/builds"
    else cfg.easLocalBuildArtifactsDir;
  jdk = packageFrom cfg.jdk;
  node = packageFrom cfg.node;

  secretsFile =
    if cfg.secrets == null
    then null
    else cfg.secrets.file or "secrets.env";
  secretsLoadIntoEnv =
    if cfg.secrets == null
    then false
    else cfg.secrets.loadIntoEnv or false;

  secretsHook =
    if !secretsLoadIntoEnv
    then ""
    else ''
      export XGX_SECRETS_FILE="$PWD/${secretsFile}"
      export XGX_SECRETS_LOAD_INTO_ENV=1

      if [ ! -f "$XGX_SECRETS_FILE" ]; then
        echo "sops: warning: $XGX_SECRETS_FILE not found; continuing without Android release secrets" >&2
      elif ! command -v sops >/dev/null 2>&1; then
        echo "sops: warning: sops is not available; continuing without Android release secrets" >&2
      else
        secrets_env_tmp="$(mktemp)"
        if sops -d "$XGX_SECRETS_FILE" >"$secrets_env_tmp" 2>/dev/null; then
          echo sops: loading "$XGX_SECRETS_FILE"
          set -a
          if ! source "$secrets_env_tmp"; then
            echo "sops: warning: could not source $XGX_SECRETS_FILE; continuing with partial Android release secrets" >&2
          fi
          set +a
        else
          echo "sops: warning: could not decrypt $XGX_SECRETS_FILE; continuing without Android release secrets" >&2
        fi
        rm -f "$secrets_env_tmp"
      fi
    '';

  extraPackages =
    if builtins.isFunction cfg.extraPackages
    then cfg.extraPackages pkgs
    else cfg.extraPackages;

  androidEnv =
    {
      ANDROID_HOME = androidSdkRoot;
      ANDROID_SDK_ROOT = androidSdkRoot;
      ANDROID_NDK_HOME = androidNdkRoot;
      ANDROID_NDK_ROOT = androidNdkRoot;
      XGX_ANDROID_CREDENTIALS_DIR = cfg.credentialsDir;
      XGX_ANDROID_DEFAULT_PROFILE = cfg.defaultProfile;
      XGX_ANDROID_DEFAULT_RELEASE_STATUS = cfg.defaultReleaseStatus;
      XGX_ANDROID_DEFAULT_TRACK = cfg.defaultTrack;
      XGX_ANDROID_MOBILE_DIR = cfg.mobileDir;
      JAVA_HOME = jdk.home;
      ORG_GRADLE_PROJECT_reactNativeArchitectures =
        lib.concatStringsSep "," cfg.reactNativeArchitectures;
      FASTLANE_SKIP_UPDATE_CHECK = "1";
      EXPO_NO_TELEMETRY = "1";
      XGX_ANDROID_NIX = "1";
    }
    // lib.optionalAttrs (cfg.buildOutput != null) {
      XGX_ANDROID_BUILD_OUTPUT = cfg.buildOutput;
    }
    // lib.optionalAttrs (secretsFile != null) {
      XGX_ANDROID_SECRETS_FILE = secretsFile;
    }
    // cfg.env;

  androidReleaseTools = pkgs.runCommand "xgx-android-release-tools" {} ''
    mkdir -p "$out/bin" "$out/lib/xgx/android-release"

    cp ${../src/android-release/common.ts} "$out/lib/xgx/android-release/common.ts"
    cp ${../src/android-release/prepare-credentials.ts} "$out/lib/xgx/android-release/prepare-credentials.ts"
    cp ${../src/android-release/build.ts} "$out/lib/xgx/android-release/build.ts"
    cp ${../src/android-release/submit.ts} "$out/lib/xgx/android-release/submit.ts"
    cp ${../src/android-release/install.ts} "$out/lib/xgx/android-release/install.ts"
    cp ${../src/android-release/release.ts} "$out/lib/xgx/android-release/release.ts"

    cat >"$out/bin/xgx-android-prepare-credentials" <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bun}/bin/bun "$out/lib/xgx/android-release/prepare-credentials.ts" "\$@"
    EOF

    cat >"$out/bin/xgx-android-build" <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bun}/bin/bun "$out/lib/xgx/android-release/build.ts" "\$@"
    EOF

    cat >"$out/bin/xgx-android-submit" <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bun}/bin/bun "$out/lib/xgx/android-release/submit.ts" "\$@"
    EOF

    cat >"$out/bin/xgx-android-install" <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bun}/bin/bun "$out/lib/xgx/android-release/install.ts" "\$@"
    EOF

    cat >"$out/bin/xgx-android-release" <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bun}/bin/bun "$out/lib/xgx/android-release/release.ts" "\$@"
    EOF

    sed -i 's/^    //' "$out"/bin/xgx-android-*
    chmod +x "$out"/bin/xgx-android-*
  '';

  standardPackages = [
    androidReleaseTools
    androidSdk
    androidComposition.platform-tools
    jdk
    node
    pkgs.bun
    pkgs.cmake
    pkgs.eas-cli
    pkgs.fastlane
    pkgs.git
    pkgs.sops
    pkgs.age
    pkgs.unzip
    pkgs.which
    pkgs.zip
  ];
in
  pkgs.mkShell {
    packages = standardPackages ++ extraPackages;
    env = androidEnv;
    shellHook = ''
      export XDG_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"

      ${secretsHook}

      export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$PWD/${cfg.gradleUserHome}}"
      export ANDROID_USER_HOME="''${ANDROID_USER_HOME:-$PWD/${cfg.androidUserHome}}"
      export EAS_LOCAL_BUILD_WORKINGDIR="''${EAS_LOCAL_BUILD_WORKINGDIR:-$PWD/${cfg.easLocalBuildWorkingDir}}"
      export EAS_LOCAL_BUILD_ARTIFACTS_DIR="''${EAS_LOCAL_BUILD_ARTIFACTS_DIR:-$PWD/${easLocalBuildArtifactsDir}}"
      mkdir -p \
        "$GRADLE_USER_HOME" \
        "$ANDROID_USER_HOME" \
        "$EAS_LOCAL_BUILD_WORKINGDIR" \
        "$EAS_LOCAL_BUILD_ARTIFACTS_DIR"

      ${cfg.shellHook}
    '';
  }
