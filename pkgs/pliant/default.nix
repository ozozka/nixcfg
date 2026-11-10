_:

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  installFonts,
}:

stdenvNoCC.mkDerivation {
  pname = "pliant";
  version = "unstable-2026-11-04";

  src = fetchFromGitHub {
    owner = "TheJonassss";
    repo = "Pliant";
    rev = "415e1f5ff69a1b4678ed9ddfcfb360033954379a";
    hash = "sha256-iVpFyaUPx8M1+pagFOWmM4uKWIj2lVMhCScr9G7oe1g=";
  };

  nativeBuildInputs = [ installFonts ];
  dontBuild = true;

  installPhase = ''
    pushd fonts/ttf
    runHook preInstall
    popd
    install -Dm644 OFL.txt "$out/share/doc/pliant/OFL.txt"
    runHook postInstall
  '';

  meta = {
    description = "Swiss-inspired sans-serif in static upright and italic styles";
    homepage = "https://github.com/TheJonassss/Pliant";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
