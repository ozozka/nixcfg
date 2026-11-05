{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.ozozka.mod.desktop.music;
in
{
  options.ozozka.mod.desktop.music = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "mpd";
      description = "MPD user";
    };
    directory = lib.mkOption {
      type = lib.types.path;
      default = "${config.services.mpd.dataDir}/music";
      description = "MPD music directory";
    };
  };

  config = {
    services.mpd = {
      inherit (cfg) user;
      enable = true;
      startWhenNeeded = true;
      settings = {
        music_directory = cfg.directory;
        auto_update = "yes";
        audio_output = [
          {
            name = "PipeWire Output";
            type = "pipewire";
          }
        ];
      };
    };

    systemd.services.mpd.serviceConfig.ExecStart = lib.mkForce [
      ""
      (toString (
        pkgs.writeShellScript "mpd-start" ''
          export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u)"
          exec ${pkgs.mpd}/bin/mpd --systemd /run/mpd/mpd.conf
        ''
      ))
    ];

    environment.systemPackages = with pkgs; [ mpc ]; # rmpc
  };
}
