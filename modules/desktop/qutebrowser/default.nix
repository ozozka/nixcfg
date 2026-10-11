{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [
    ../../home.nix
    ../../options.nix
  ];

  environment.systemPackages = with pkgs; [ qutebrowser ];

  ozozka.home.profiles.qutebrowser.files = {
    ".config/qutebrowser" = {
      "config.py" = ./config.py;
      "theme.py" = pkgs.writeText "theme.py" ''
        IS_DARK = ${if cfg.col.isDark then "True" else "False"}
        COL_P = "#${cfg.col.p.hex}"
        COL_S = "#${cfg.col.s.hex}"
        COL_F = "#${cfg.col.f.hex}"
        COL_M = "#${cfg.col.m.hex}"
        COL_O = "#${cfg.col.o.hex}"
        COL_B = "#${cfg.col.b.hex}"

        FONTS_EMOJI = "${cfg.font.emoji.name}"
        FONTS_SANS = "${cfg.font.sans.name}"
        FONTS_SERIF = "${cfg.font.serif.name}"
        FONTS_MONO = "${cfg.font.mono.name}"

        FONT_SIZE_T = int(${toString cfg.fontSize.t})
        FONT_SIZE_S = int(${toString cfg.fontSize.s})
        FONT_SIZE_M = int(${toString cfg.fontSize.m})
        FONT_SIZE_L = int(${toString cfg.fontSize.l})
        FONT_SIZE_X = int(${toString cfg.fontSize.x})
        FONT_SIZE_H = int(${toString cfg.fontSize.h})

        DIM_T = ${toString cfg.dim.t}
        DIM_S = ${toString cfg.dim.s}
        DIM_M = ${toString cfg.dim.m}
        DIM_L = ${toString cfg.dim.l}
        DIM_X = ${toString cfg.dim.x}
        DIM_H = ${toString cfg.dim.h}
      '';
    };
  };
}
