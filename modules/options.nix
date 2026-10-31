{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.ozozka;

  mkOpt =
    type: default: description:
    lib.mkOption { inherit type default description; };

  palette = {
    p1 = "09bea8"; # oklch(0.72 0.1296 180)
    p0 = "026f61"; # oklch(0.486 0.0876 180)
    s1 = "ff3963"; # oklch(0.66 0.2324 15)
    s0 = "c40141"; # oklch(0.522 0.2082 15)
    w = "ffffff"; # oklch(1 0.0042 180)
    o0 = "e4e8e7"; # oklch(0.928 0.0042 180)
    g = "7e8180"; # oklch(0.60 0.0042 180)
    o1 = "101212"; # oklch(0.18 0.0042 180)
    d = "000000"; # oklch(0 0.0042 180)
  };

  themes = {
    dark = {
      isDark = true;
      p = palette.p1;
      s = palette.s1;
      f = palette.w;
      m = palette.g;
      o = palette.o1;
      b = palette.d;
    };
    light = {
      isDark = false;
      p = palette.p0;
      s = palette.s0;
      f = palette.d;
      o = palette.o0;
      m = palette.g;
      b = palette.w;
    };
  };
in
{
  imports = [ ./overlays.nix ];

  options.ozozka = {
    user = {
      name = mkOpt lib.types.str "Oğuzhan" "First name";
      surname = mkOpt lib.types.str "Özkaya" "Family name";
      fullname = mkOpt lib.types.str "${cfg.user.name} ${cfg.user.surname}" "Full name";
      username = mkOpt lib.types.str "ozozka" "User name";
      email = mkOpt lib.types.str "ozkaya.ogzhn@gmail.com" "Email";
    };

    keyboard = {
      layout = mkOpt lib.types.str "us,tr" "Keyboard layout";
      options = mkOpt lib.types.str "caps:swapescape,grp:win_space_toggle" "Keyboard options";
    };

    wallpaper =
      mkOpt lib.types.path "${pkgs.ozozka.ozozka-assets}/share/wallpapers/ebru.jpg"
        "Wallpaper image.";

    cursor = {
      size = mkOpt lib.types.int 24 "Cursor size";
      name = mkOpt lib.types.str (if cfg.col.isDark then "DMZ-White" else "DMZ-Black") "Cursor name";
      pkg = lib.mkPackageOption pkgs "vanilla-dmz" { };
    };

    dim = {
      t = mkOpt lib.types.int 3 "Tiny";
      s = mkOpt lib.types.int 12 "Small";
      m = mkOpt lib.types.int 24 "Medium";
      l = mkOpt lib.types.int 72 "Large";
      x = mkOpt lib.types.int 144 "Extra";
      h = mkOpt lib.types.int 360 "Huge";
    };

    fontSize = {
      t = mkOpt lib.types.int 6 "Tiny font size";
      s = mkOpt lib.types.int 9 "Small font size";
      m = mkOpt lib.types.int 12 "Medium font size";
      l = mkOpt lib.types.int 15 "Large font size";
      x = mkOpt lib.types.int 18 "Extra font size";
      h = mkOpt lib.types.int 24 "Huge font size";
    };

    font =
      let
        mkFont = name: pkg: desc: {
          name = mkOpt lib.types.str name desc;
          pkg = lib.mkPackageOption pkgs pkg { };
        };
      in
      {
        emoji = mkFont "Noto Color Emoji" "noto-fonts-color-emoji" "Emoji font";
        serifa = mkFont "Spectral" "spectral" "Alternative serif font";
        serif = mkFont "Manuale" [ "ozozka" "manuale" ] "Serif font";
        sansa = mkFont "Source Sans 3" "source-sans" "Alternative sans font";
        sans = mkFont "Inter" "inter" "Sans font";
        mono = mkFont "Oziosevka" [ "ozozka" "oziosevka" ] "Monospace font";
      };

    theme = mkOpt (lib.types.enum (lib.attrNames themes)) "dark" "Color theme.";

    col =
      let
        mkCol = attr: ansi: desc: {
          hex = mkOpt lib.types.str themes.${cfg.theme}.${attr} "${desc} color hex";
          ansi = mkOpt lib.types.int ansi "${desc} color ansi index";
        };
      in
      {
        isDark = mkOpt lib.types.bool themes.${cfg.theme}.isDark "Color theme variant";
        p = mkCol "p" 6 "Primary";
        s = mkCol "s" 1 "Secondary";
        f = mkCol "f" 15 "Foreground";
        m = mkCol "m" 7 "Muted";
        o = mkCol "o" 8 "Overlay";
        b = mkCol "b" 0 "Background";
      };

    ansi16 =
      let
        mkAnsi = tok: i: mkOpt lib.types.str cfg.col.${tok}.hex "Ansi color ${i}";
      in
      {
        a0 = mkAnsi "b" "0";
        a1 = mkAnsi "s" "1";
        a2 = mkAnsi "p" "2";
        a3 = mkAnsi "p" "3";
        a4 = mkAnsi "s" "4";
        a5 = mkAnsi "s" "5";
        a6 = mkAnsi "p" "6";
        a7 = mkAnsi "m" "7";
        a8 = mkAnsi "o" "8";
        a9 = mkAnsi "s" "9";
        aA = mkAnsi "p" "A";
        aB = mkAnsi "p" "B";
        aC = mkAnsi "s" "C";
        aD = mkAnsi "s" "D";
        aE = mkAnsi "p" "E";
        aF = mkAnsi "f" "F";
      };
  };
}
