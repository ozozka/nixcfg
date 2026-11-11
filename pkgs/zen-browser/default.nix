_:

{ pkgs }:

let
  inherit (pkgs.stdenv.hostPlatform) system;

  pname = "zen";
  version = "1.24.1b";

  meta = {
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };

  url = "https://github.com/zen-browser/desktop/releases/download/${version}/";

  release =
    {
      x86_64-linux = {
        url = url + "zen-x86_64.AppImage";
        hash = "sha256-ALp2Ibp3F9klB32HIN3nkCPlmVCHLfuaAwIJ3qxxx9A=";
      };
      aarch64-linux = {
        url = url + "zen-aarch64.AppImage";
        hash = "sha256-0Cag3UiRcx3vwD/WjuawHMT/4xTSU7YsxxxEoyQKbHQ=";
      };
    }
    .${system};

  src = pkgs.fetchurl release;
in
pkgs.appimageTools.wrapType2 {
  inherit
    pname
    version
    src
    meta
    ;

  extraPkgs =
    pkgs: with pkgs; [
      ffmpeg_8
      libnotify
    ];

  extraInstallCommands =
    let
      contents = pkgs.appimageTools.extract { inherit pname version src; };
    in
    ''
      install -m 444 -D ${contents}/${pname}.desktop -t $out/share/applications
      substituteInPlace $out/share/applications/${pname}.desktop \
        --replace 'Exec=AppRun' 'Exec=${pname}'
      cp -r ${contents}/usr/share/icons $out/share
    '';
}
