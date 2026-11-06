_:

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

stdenvNoCC.mkDerivation {
  pname = "manuale";
  version = "1.001";

  src = fetchFromGitHub {
    owner = "Omnibus-Type";
    repo = "Manuale";
    rev = "20a5ab6a0da1c8cb56916d843e50db0ad6b6dfd3";
    hash = "sha256-se4sySh0iQZN7Mek18ZmwSUIFcRWHTT/In3A9SJ9pfE=";
  };

  installPhase = ''
    runHook preInstall

    mkdir --parents $out/share/fonts
    cp --recursive fonts/ttf $out/share/fonts/truetype
    cp --recursive fonts/variable $out/share/fonts/variable

    runHook postInstall
  '';

  meta = {
    description = "Manuale typeface";
    longDescription = "Manuale is part of the Omnibus-Type Press Series, designed by Pablo Cosgaya and Eduardo Tunni for editorial typography (books, newspapers and magazines) in print and online.";
    homepage = "https://github.com/Omnibus-Type/Manuale/";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
