{pkgs}: config: let
  inherit (pkgs) lib;

  cfg =
    {
      androidSdkVersion = "36";
      buildToolsVersions = ["36.0.0" "35.0.0"];
      cmdLineToolsVersion = "latest";
      cmakeVersions = ["3.22.1"];
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
      overlays = [];
      reactNativeArchitectures = ["arm64-v8a"];
      secrets = {
        file = "secrets.env";
        loadIntoEnv = true;
      };
      shellHook = "";
    }
    // config;

  androidPkgs = import pkgs.path {
    system = pkgs.stdenv.hostPlatform.system;
    overlays = cfg.overlays;
    config = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  };

  packageFrom = value:
    if builtins.isFunction value
    then value androidPkgs
    else value;

  androidComposition = androidPkgs.androidenv.composeAndroidPackages {
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
    then cfg.extraPackages androidPkgs
    else cfg.extraPackages;

  androidEnv =
    {
      ANDROID_HOME = androidSdkRoot;
      ANDROID_SDK_ROOT = androidSdkRoot;
      ANDROID_NDK_HOME = androidNdkRoot;
      ANDROID_NDK_ROOT = androidNdkRoot;
      JAVA_HOME = jdk.home;
      ORG_GRADLE_PROJECT_reactNativeArchitectures =
        lib.concatStringsSep "," cfg.reactNativeArchitectures;
      FASTLANE_SKIP_UPDATE_CHECK = "1";
      EXPO_NO_TELEMETRY = "1";
      XGX_ANDROID_NIX = "1";
    }
    // cfg.env;

  standardPackages = [
    androidSdk
    androidComposition.platform-tools
    jdk
    node
    androidPkgs.bun
    androidPkgs.cmake
    androidPkgs.eas-cli
    androidPkgs.fastlane
    androidPkgs.git
    androidPkgs.sops
    androidPkgs.age
    androidPkgs.unzip
    androidPkgs.which
    androidPkgs.zip
  ];
in
  androidPkgs.mkShell {
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
