_:

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
  harfbuzz,
}:

stdenvNoCC.mkDerivation {
  pname = "pliant-source";
  version = "unstable-2026-11-04";

  src = fetchFromGitHub {
    owner = "TheJonassss";
    repo = "Pliant";
    rev = "415e1f5ff69a1b4678ed9ddfcfb360033954379a";
    hash = "sha256-iVpFyaUPx8M1+pagFOWmM4uKWIj2lVMhCScr9G7oe1g=";
  };

  nativeBuildInputs = [ (python3.withPackages (ps: [ ps.fontmake ])) ];
  nativeCheckInputs = [ harfbuzz ];

  # Do not invoke upstream's Makefile: it creates a venv and downloads from PyPI.
  buildPhase = ''
    runHook preBuild
    python ${./build.py} build
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python ${./build.py} check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 build/fonts/*.ttf -t "$out/share/fonts/truetype/variable"
    install -Dm644 build/static/*.ttf -t "$out/share/fonts/truetype/static"
    install -Dm644 OFL.txt "$out/share/doc/pliant-source/OFL.txt"
    runHook postInstall
  '';

  meta = {
    description = "Source-built Pliant fonts without ligatures, with a Regular variable default";
    homepage = "https://github.com/TheJonassss/Pliant";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
