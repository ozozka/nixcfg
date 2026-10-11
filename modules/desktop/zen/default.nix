{ pkgs, ... }:

{
  imports = [ ../../overlays.nix ];

  environment.systemPackages = with pkgs; [ ozozka.zen-browser ];
}
