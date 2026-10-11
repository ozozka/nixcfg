{ pkgs, config, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [ ../options.nix ];

  console = {
    enable = true;
    earlySetup = true;
    useXkbConfig = true;
    font = "ter-v32n";
    packages = with pkgs; [ terminus_font ];

    colors = [
      cfg.ansi16.a0
      cfg.ansi16.a1
      cfg.ansi16.a2
      cfg.ansi16.a3
      cfg.ansi16.a4
      cfg.ansi16.a5
      cfg.ansi16.a6
      cfg.ansi16.a7
      cfg.ansi16.a8
      cfg.ansi16.a9
      cfg.ansi16.aA
      cfg.ansi16.aB
      cfg.ansi16.aC
      cfg.ansi16.aD
      cfg.ansi16.aE
      cfg.ansi16.aF
    ];
  };
}
