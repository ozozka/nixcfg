{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ozozka;
in
{
  imports = [ ../../options.nix ];

  options.ozozka.mod.desktop.hypr = {
    mirrorIntegratedMonitor = lib.mkEnableOption "mirrorIntegrated";
  };

  config = {
    programs = {
      hyprland = {
        enable = true;
        withUWSM = true;
        xwayland.enable = true;
      };
    };

    environment = {
      systemPackages = with pkgs; [
        grim
        slurp
        wl-clipboard
      ];

      loginShellInit = ''
        if [ -z "$DISPLAY" ] \
          && [ -z "$WAYLAND_DISPLAY" ] \
          && [ "$(tty)" = "/dev/tty1" ] \
          && uwsm check may-start \
        ; then
          exec uwsm start hyprland.desktop
        fi
      '';

      etc = {
        "xdg/hypr/stubs".source = "${pkgs.hyprland}/share/hypr/stubs";
        "xdg/hypr/hyprland.lua".source = ./hyprland.lua;
        "xdg/hypr/options.lua".text = ''
          return {
            monitor = ${if cfg.mod.desktop.hypr.mirrorIntegratedMonitor then "3" else "1"},
            keyboard = {
              layout = '${cfg.keyboard.layout}',
              options = '${cfg.keyboard.options}',
            },
          }
        '';
      };

      sessionVariables = {
        NIXOS_OZONE_WL = "1";
      };
    };
  };
}
