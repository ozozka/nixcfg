{ pkgs }:

let
  inherit (pkgs.stdenv.hostPlatform) system;

  pname = "zen";
  version = "1.23.3b";

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
        hash = "sha256-j2t6Va6P0BMUf0D1ktEhiN0m8Z9KR0jgG1HpdHvUS6w=";
      };
      aarch64-linux = {
        url = url + "zen-aarch64.AppImage";
        hash = "sha256-1bWmI62UKeumAqjIT75bWi+t86ME9OUTPJ1Y7vGRHDc=";
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

  extraPkgs = pkgs: with pkgs; [ ffmpeg_8 ];

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
