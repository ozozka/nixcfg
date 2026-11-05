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
  emacsTs = pkgs.callPackage ./modules/dev/emacs/ts.nix { };
in
{
  emacs-ts = emacsTs.tests.unit;
  emacs-ts-emacs = emacsTs.tests.emacs;

  codex-hooks = pkgs.runCommand "codex-hooks-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    python3 -m unittest discover -s ${./modules/dev/codex} -p 'test_*.py' -v
    touch "$out"
  '';

  claude-hooks = pkgs.runCommand "claude-hooks-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    python3 -m unittest discover -s ${./modules/dev/claude} -p 'test_*.py' -v
    touch "$out"
  '';

  pi-docs = pkgs.runCommand "pi-docs-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    node --test ${./modules/dev/pi}/docs.test.ts
    touch "$out"
  '';

  format = formatter.check src;
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
