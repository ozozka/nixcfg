_:

{ pkgs, ... }:

{ environment.systemPackages = with pkgs; [ brightnessctl ]; }
