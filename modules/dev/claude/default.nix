{ pkgs, ... }:

{
  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];

  environment.systemPackages = with pkgs; [ claude-code ];
}
