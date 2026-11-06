self:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ozozka;
  ozshell = self.packages.${pkgs.stdenv.hostPlatform.system}.ozshell;
  join = keys: f: lib.concatMapStringsSep "," f keys;
  sizes = set: join [ "t" "s" "m" "l" "x" "h" ] (k: toString set.${k});
in
{
  imports = [ self.nixosModules.options ];

  environment.systemPackages = [
    ozshell
    pkgs.gtk3
  ];

  systemd.user.services.ozshell = {
    description = "ozshell";

    enableDefaultPath = false;

    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];

    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe ozshell)
        "--colors"
        (join [ "p" "s" "f" "m" "o" "b" ] (c: cfg.col.${c}.hex))
        "--font-sizes"
        (sizes cfg.fontSize)
        "--dims"
        (sizes cfg.dim)
        "--wallpaper"
        (toString cfg.wallpaper)
      ];
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 5;
      Slice = "session.slice";
    };
  };

  services.upower.enable = true;

  security = {
    polkit.enable = true;
    pam.services.ozshell = { };
  };
}
