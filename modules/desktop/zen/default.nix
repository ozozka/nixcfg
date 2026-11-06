self:

{ pkgs, ... }:

{ environment.systemPackages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.zen-browser ]; }
