{
  description = "Shared XGX utilities";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    mkLib = {androidPkgs, pkgs}: {
      mkAndroidDevShell = import ./nix/mk-android-dev-shell.nix {pkgs = androidPkgs;};
      mkDevShell = import ./nix/mk-dev-shell.nix {inherit pkgs;};
    };

    forEachSupportedSystem = f:
      lib.genAttrs supportedSystems (
        system: let
          pkgs = import nixpkgs {inherit system;};
          androidPkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
        in
          f {
            inherit androidPkgs pkgs;
          }
      );
  in {
    lib = forEachSupportedSystem (
      {androidPkgs, pkgs}: mkLib {inherit androidPkgs pkgs;}
    );
  };
}
