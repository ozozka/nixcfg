{ inputs, pkgs, ... }:

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  fs = lib.fileset;
  src = fs.toSource {
    root = ./.;
    fileset = fs.difference ./. (fs.maybeMissing ./.git);
  };

  formatter = pkgs.callPackage ./formatter.nix { };
  emacsTs = pkgs.callPackage ./pkgs/emacs-ts { };
in
{
  emacs-ts = emacsTs;
  emacs-ts-emacs = emacsTs.tests.emacs;

  format =
    pkgs.runCommandLocal "format-check"
      {
        nativeBuildInputs = [
          pkgs.gitMinimal
          formatter
        ];
        __structuredAttrs = true;
      }
      ''
        cp -r ${src} project
        chmod -R u+w project

        cd project
        formatter
        git diff --no-index --exit-code ${src} .
        touch "$out"
      '';
}
// lib.mapAttrs' (
  name: module:
  lib.nameValuePair "nixos-module-${system}-${name}" (
    let
      evaluated = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          module
          {
            nixpkgs.hostPlatform = lib.mkDefault system;
            system.stateVersion = lib.mkDefault "26.05";

            fileSystems."/" = {
              device = lib.mkDefault "/dev/null";
              fsType = lib.mkDefault "ext4";
            };

            boot.loader.systemd-boot.enable = lib.mkDefault true;
          }
        ];
      };

      drvPath = builtins.addErrorContext "while evaluating nixosModules.${system}.${name}" evaluated.config.system.build.toplevel.drvPath;
    in
    builtins.seq drvPath (
      pkgs.runCommand "nixos-module-${system}-${name}-check" { } ''
        touch "$out"
      ''
    )
  )
) inputs.self.nixosModules
