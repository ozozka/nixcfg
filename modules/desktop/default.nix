{
  pkgs,
  lib,
  config,
  ...
}:

let
  theme = config.ozozka.theme;

  cursor-theme = "DMZ-White";
  cursor-size = 24;
in
{
  imports = [
    ../theme.nix

    ./hyprland
    ./quickshell
    ./qutebrowser
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
          inherit cursor-theme;
          cursor-size = lib.gvariant.mkInt32 cursor-size;
          color-scheme = if theme.colors.variant == "light" then "prefer-light" else "prefer-dark";
          font-name = theme.fonts.sans + " " + (toString (theme.font-size.m / 10));
          document-font-name = theme.fonts.serif + " " + (toString (theme.font-size.m / 10));
          monospace-font-name = theme.fonts.mono + " " + (toString (theme.font-size.m / 10));
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
    packages = with pkgs; [
      noto-fonts-color-emoji
      ozozka.spectral
      ozozka.manuale
      source-sans
      inter
      ozozka.oziosevka
    ];

    fontconfig = {
      enable = true;
      defaultFonts = {
        emoji = [ theme.fonts.emoji ];
        serif = [ theme.fonts.serif ];
        sansSerif = [ theme.fonts.sans ];
        monospace = [ theme.fonts.mono ];
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
      XCURSOR_THEME = cursor-theme;
      XCURSOR_SIZE = toString cursor-size;
    };

    systemPackages = with pkgs; [
      mpv
      vanilla-dmz
      playerctl
      wl-clipboard
    ];
  };
}
