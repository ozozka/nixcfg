{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.ozozka;
in
{
  imports = [
    ../options.nix

    ./hyprland
    ./quickshell
    ./zen
    ./alacritty.nix
  ];

  security = {
    pam.services.login.enableGnomeKeyring = true;
    rtkit.enable = true;
  };

  services = {
    gnome.gnome-keyring.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };
  };

  programs = {
    thunar.enable = true;
    dconf.profiles.user.databases = [
      {
        settings."org/gnome/desktop/interface" = {
          cursor-theme = cfg.cursor.name;
          cursor-size = lib.gvariant.mkInt32 cfg.cursor.size;
          color-scheme = if cfg.col.isDark then "prefer-dark" else "prefer-light";
          font-name = cfg.font.sans.name + " " + (toString cfg.fontSize.m);
          document-font-name = cfg.font.serif.name + " " + (toString cfg.fontSize.m);
          monospace-font-name = cfg.font.mono.name + " " + (toString cfg.fontSize.m);
        };

        locks = [
          "/org/gnome/desktop/interface/cursor-theme"
          "/org/gnome/desktop/interface/cursor-size"
          "/org/gnome/desktop/interface/color-scheme"
          "/org/gnome/desktop/interface/font-name"
          "/org/gnome/desktop/interface/document-font-name"
          "/org/gnome/desktop/interface/monospace-font-name"
        ];
      }
    ];
  };

  fonts = {
    enableDefaultPackages = false;
    packages = with cfg.font; [
      emoji.pkg
      serifa.pkg
      serif.pkg
      sansa.pkg
      sans.pkg
      mono.pkg
    ];

    fontconfig = {
      enable = true;
      defaultFonts = {
        emoji = [ cfg.font.emoji.name ];
        serif = [
          cfg.font.serif.name
          cfg.font.serifa.name
        ];
        sansSerif = [
          cfg.font.sans.name
          cfg.font.sansa.name
        ];
        monospace = [ cfg.font.mono.name ];
      };

      useEmbeddedBitmaps = false;
      antialias = true;
      hinting = {
        enable = true;
        autohint = false;
        style = "slight";
      };
      subpixel = {
        lcdfilter = "default";
        rgba = "rgb";
      };
    };
  };

  environment = {
    sessionVariables = {
      XCURSOR_THEME = cfg.cursor.name;
      XCURSOR_SIZE = toString cfg.cursor.size;
    };

    systemPackages = with pkgs; [
      mpv
      cfg.cursor.pkg
      playerctl
      wl-clipboard
    ];
  };
}
