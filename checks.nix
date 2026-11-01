{ inputs, pkgs, ... }:

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  agentTestEmacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
    (epkgs.treesit-grammars.with-grammars (grammars: [
      grammars.tree-sitter-markdown
      grammars.tree-sitter-markdown-inline
    ]))
  ]);

  fs = lib.fileset;
  src = fs.toSource {
    root = ./.;
    fileset = fs.difference ./. (fs.maybeMissing ./.git);
  };
in
{
  format = (pkgs.callPackage ./formatter.nix { }).check src;

  # Built-ins only; offline Pi fixtures exercise sockets, trust and concurrent
  # agents without credentials, provider requests, or the user's configuration.
  my-agent =
    pkgs.runCommand "my-agent-check"
      {
        nativeBuildInputs = [
          agentTestEmacs
          pkgs.pi-coding-agent
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" dev/emacs dev/pi/extensions dev/pi/tests
        cp ${./modules/dev/emacs/my-agent.el} dev/emacs/my-agent.el
        cp ${./modules/dev/emacs/my-agent-tests.el} dev/emacs/my-agent-tests.el
        cp ${./modules/dev/pi/adapter.ts} dev/pi/adapter.ts
        cp ${./modules/dev/pi/extensions/status.ts} dev/pi/extensions/status.ts
        cp ${./modules/dev/pi/tests/frontend-fixture.ts} dev/pi/tests/frontend-fixture.ts
        export MY_AGENT_TEST_PI=1 PI_OFFLINE=1
        # Load the Nix package site-start (grammar paths), but no user init.
        emacs --batch --no-init-file -L dev/emacs -l my-agent-tests -f ert-run-tests-batch-and-exit
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
