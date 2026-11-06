_:

{ lib, pkgs, ... }:

{
  warnings = lib.optional (
    !pkgs.stdenv.hostPlatform.isx86_64
  ) "The Steam module only supports x86_64-linux; Steam will not be enabled.";

  nixpkgs.config.allowUnfreePackages = [
    "steam"
    "steam-unwrapped"
  ];

  programs.steam.enable = pkgs.stdenv.hostPlatform.isx86_64;
}
