{ pkgs, lib, ... }:

let
  lineWidth = 96;
in
pkgs.treefmt.withConfig {
  settings = {
    tree-root-file = "flake.nix";
    on-unmatched = "debug";

    formatter = {
      qmlformat = {
        command = "${pkgs.qt6.qtdeclarative}/bin/qmlformat";
        includes = [ "*.qml" ];
        options = [
          "--inplace"
          "--indent-width"
          "2"
          "--column-width"
          "${toString lineWidth}"
        ];
      };

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

      ruff-check = {
        command = lib.getExe pkgs.ruff;
        includes = [ "*.py" ];
        options = [
          "check"
          "--no-cache"
          "--line-length"
          "96"
          "--fix"
        ];
        priority = -1;
      };

      ruff-format = {
        command = lib.getExe pkgs.ruff;
        includes = [ "*.py" ];
        options = [
          "format"
          "--no-cache"
          "--line-length"
          "96"
        ];
      };

      biome = {
        command = lib.getExe pkgs.biome;
        includes = [ "*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,json,jsonc,css}" ];
        options = [
          "check"
          "--write"
          "--indent-style=space"
          "--line-width=96"
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
          "--print-width=96"
        ];
      };

      nixf-diagnose = {
        command = lib.getExe pkgs.nixf-diagnose;
        includes = [ "*.nix" ];
        options = [ "--auto-fix" ];
        priority = -2;
      };

      statix = {
        command = lib.getExe pkgs.statix;
        includes = [ "*.nix" ];
        options = [ "fix" ];
        no-positional-arg-support = true;
        priority = -1;
      };

      statix-check = {
        command = lib.getExe pkgs.statix;
        includes = [ "*.nix" ];
        options = [ "check" ];
        no-positional-arg-support = true;
        priority = 1;
      };

      nixfmt = {
        command = lib.getExe pkgs.nixfmt;
        includes = [ "*.nix" ];
        options = [ "--strict" ];
      };
    };
  };
}
