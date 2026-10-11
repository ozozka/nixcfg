{ pkgs, config, ... }:

let
  cfg = config.ozozka;
  settingsFormat = pkgs.formats.toml { };
  hex = v: "#" + v;
in
{
  imports = [ ../options.nix ];

  environment = {
    systemPackages = with pkgs; [ alacritty ];

    etc."alacritty/alacritty.toml".source = settingsFormat.generate "alacritty.toml" {
      general = {
        live_config_reload = false;
      };

      window = {
        decorations = "None";
      };

      scrolling = {
        history = 6000;
        multiplier = 6;
      };

      font = {
        normal = {
          family = cfg.font.mono.name;
          style = "Regular";
        };
        size = cfg.fontSize.m;
        offset = {
          x = 0;
          y = cfg.dim.t;
        };
      };

      colors = {
        primary = {
          foreground = hex cfg.col.f.hex;
          background = hex cfg.col.b.hex;
        };
        cursor = {
          text = hex cfg.col.b.hex;
          cursor = hex cfg.col.f.hex;
        };
        selection = {
          text = "CellForeground";
          background = hex cfg.col.o.hex;
        };
        normal = {
          black = hex cfg.ansi16.a0;
          red = hex cfg.ansi16.a1;
          green = hex cfg.ansi16.a2;
          yellow = hex cfg.ansi16.a3;
          blue = hex cfg.ansi16.a4;
          magenta = hex cfg.ansi16.a5;
          cyan = hex cfg.ansi16.a6;
          white = hex cfg.ansi16.a7;
        };
        bright = {
          black = hex cfg.ansi16.a8;
          red = hex cfg.ansi16.a9;
          green = hex cfg.ansi16.aA;
          yellow = hex cfg.ansi16.aB;
          blue = hex cfg.ansi16.aC;
          magenta = hex cfg.ansi16.aD;
          cyan = hex cfg.ansi16.aE;
          white = hex cfg.ansi16.aF;
        };
      };

      selection = {
        save_to_clipboard = true;
      };

      cursor = {
        thickness = 0.12;
      };

      terminal = {
        osc52 = "CopyPaste";
      };

      mouse = {
        hide_when_typing = true;
      };
    };
  };
}
