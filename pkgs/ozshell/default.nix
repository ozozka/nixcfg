_:

{
  lib,
  rustPlatform,
  pkg-config,
  wayland,
  libxkbcommon,
  pam,
  vulkan-loader,
}:

rustPlatform.buildRustPackage {
  pname = "ozshell";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    wayland
    libxkbcommon
    pam
  ];

  # wgpu loads Vulkan at runtime.
  postFixup = ''
    patchelf --add-rpath ${lib.makeLibraryPath [ vulkan-loader ]} $out/bin/ozshell
  '';

  meta = {
    description = "Wayland desktop shell for Hyprland";
    mainProgram = "ozshell";
    platforms = lib.platforms.linux;
  };
}
