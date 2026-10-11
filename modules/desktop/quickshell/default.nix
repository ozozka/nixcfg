{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [ ../../options.nix ];

  environment = {
    systemPackages = with pkgs; [
      quickshell
      gtk3
    ];

    etc = {
      "xdg/quickshell/shell.qml".source = ./shell.qml;
      "xdg/quickshell/Bar.qml".source = ./Bar.qml;
      "xdg/quickshell/Menu.qml".source = ./Menu.qml;
      "xdg/quickshell/Notification.qml".source = ./Notification.qml;
      "xdg/quickshell/Lock.qml".source = ./Lock.qml;
      "xdg/quickshell/Polkit.qml".source = ./Polkit.qml;
      "xdg/quickshell/Wallpaper.qml".source = ./Wallpaper.qml;
      "xdg/quickshell/Lib.qml".source = ./Lib.qml;
      "xdg/quickshell/T.qml".text = ''
        import QtQuick

        QtObject {
          readonly property color colP: ${builtins.toJSON "#${cfg.col.p.hex}"}
          readonly property color colS: ${builtins.toJSON "#${cfg.col.s.hex}"}
          readonly property color colF: ${builtins.toJSON "#${cfg.col.f.hex}"}
          readonly property color colM: ${builtins.toJSON "#${cfg.col.m.hex}"}
          readonly property color colO: ${builtins.toJSON "#${cfg.col.o.hex}"}
          readonly property color colB: ${builtins.toJSON "#${cfg.col.b.hex}"}

          readonly property real fontSizeT: ${toString cfg.fontSize.t}
          readonly property real fontSizeS: ${toString cfg.fontSize.s}
          readonly property real fontSizeM: ${toString cfg.fontSize.m}
          readonly property real fontSizeL: ${toString cfg.fontSize.l}
          readonly property real fontSizeX: ${toString cfg.fontSize.x}
          readonly property real fontSizeH: ${toString cfg.fontSize.h}

          readonly property int dimT: ${toString cfg.dim.t}
          readonly property int dimS: ${toString cfg.dim.s}
          readonly property int dimM: ${toString cfg.dim.m}
          readonly property int dimL: ${toString cfg.dim.l}
          readonly property int dimX: ${toString cfg.dim.x}
          readonly property int dimH: ${toString cfg.dim.h}

          readonly property string wallpaper: ${builtins.toJSON (toString cfg.wallpaper)}
        }
      '';
    };
  };

  systemd.user.services.quickshell = {
    description = "Quickshell";

    enableDefaultPath = false;

    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];

    unitConfig.ConditionPathExists = "/etc/xdg/quickshell/shell.qml";

    serviceConfig = {
      ExecStart = "${pkgs.quickshell}/bin/quickshell";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 5;
      Slice = "session.slice";
    };
  };

  security = {
    polkit.enable = true;
    pam.services.quickshell = { };
  };
}
