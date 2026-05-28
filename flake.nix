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

    forEachSupportedSystem = f:
      lib.genAttrs supportedSystems (
        system:
          f {
            pkgs = import nixpkgs {inherit system;};
          }
      );
  in {
    lib = forEachSupportedSystem (
      {pkgs}: {
        mkAndroidDevShell = import ./nix/mk-android-dev-shell.nix {inherit pkgs;};
        mkDevShell = import ./nix/mk-dev-shell.nix {inherit pkgs;};
      }
    );
  };
}
