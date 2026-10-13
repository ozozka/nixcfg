{ pkgs, lib, ... }:

pkgs.writeShellApplication {
  name = "formatter";

  text = ''
    just --fmt
    statix check .
    treefmt
  '';

  runtimeInputs = with pkgs; [
    just
    statix

    (treefmt.withConfig {
      settings = {
        tree-root-file = "flake.nix";
        on-unmatched = "debug";

        formatter = {
          stylua = {
            command = lib.getExe pkgs.stylua;
            includes = [ "*.lua" ];
            options = [
              "--indent-type=Spaces"
              "--indent-width=2"
              "--column-width=120"
              "--quote-style=ForceDouble"
              "--call-parentheses=None"
              "--collapse-simple-statement=Always"
              "--space-after-function-names=Definitions"
              "--preserve-block-newline-gaps=Never"
              "--verify"
            ];
          };

          qmlformat = {
            command = "${pkgs.qt6.qtdeclarative}/bin/qmlformat";
            includes = [ "*.qml" ];
            options = [
              "--inplace"
              "--indent-width"
              "2"
              "--column-width"
              "120"
            ];
          };

          ruff-check = {
            command = lib.getExe pkgs.ruff;
            includes = [ "*.py" ];
            options = [
              "check"
              "--fix"
            ];
            priority = -1;
          };

          ruff-format = {
            command = lib.getExe pkgs.ruff;
            includes = [ "*.py" ];
            options = [ "format" ];
          };

          biome = {
            command = lib.getExe pkgs.biome;
            includes = [
              "*.js"
              "*.jsx"
              "*.mjs"
              "*.cjs"
              "*.ts"
              "*.tsx"
              "*.mts"
              "*.cts"
              "*.json"
              "*.jsonc"
              "*.css"
            ];
            options = [
              "check"
              "--write"
              "--indent-style=space"
              "--indent-width=2"
              "--javascript-formatter-quote-style=double"
              "--semicolons=always"
              "--trailing-commas=all"
            ];
          };

          prettier = {
            command = lib.getExe pkgs.prettier;
            includes = [
              "*.html"
              "*.md"
            ];
            options = [
              "--write"
              "--ignore-unknown"
              "--tab-width=2"
              "--semi=true"
              "--single-quote=false"
              "--trailing-comma=all"
              "--prose-wrap=always"
            ];
          };

          nixf-diagnose = {
            command = lib.getExe pkgs.nixf-diagnose;
            includes = [ "*.nix" ];
            options = [ "--auto-fix" ];
            priority = -2;
          };

          nixfmt = {
            command = lib.getExe pkgs.nixfmt;
            includes = [ "*.nix" ];
            options = [ "--strict" ];
          };
        };
      };
    })
  ];
}
