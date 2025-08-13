{
  description = "direnv-nix-flake-overrides: dev shell with direnv, nix, shellcheck, python+pytest+pexpect";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.bashInteractive
            pkgs.direnv
            pkgs.nixVersions.stable
            pkgs.shellcheck
            pkgs.git
            (pkgs.python312.withPackages (ps: with ps; [ pytest pytest-timeout pexpect packaging ]))
          ];
        };
      }
    );
}
