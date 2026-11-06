_:

{ pkgs, ... }:

{ environment.systemPackages = with pkgs; [ gimp ]; }
