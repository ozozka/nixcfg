{
  description = "Empty template.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          ty
          rust-analyzer
          nixd
        ];
      };

      apps.${system} =
        let
          mkApp =
            {
              name,
              desc,
              deps,
              text,
            }:
            {
              type = "app";
              meta.description = desc;
              program = pkgs.lib.getExe (
                pkgs.writeShellApplication {
                  inherit name text;
                  runtimeInputs = deps;
                  inheritPath = false;
                }
              );
            };
        in
        {
          qual = mkApp {
            name = "kaynak-qual";
            desc = "Format and validate the working tree with debug-profile Rust checks";
            deps = with pkgs; [
              coreutils
              prettier
              nixfmt
              ruff
              rustfmt
              cargo-nextest
              clippy
              rustc
              cargo
              stdenv.cc
              binutils
              git
              nix
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              export CARGO_TARGET_DIR="$PWD/target"
              export RUSTFLAGS="-C target-cpu=native"
              export PYTHONPATH="$PWD"

              prettier --write --print-width=96 --prose-wrap=always --tab-width=2 --list-different .
              nixfmt --strict flake.nix
              nix flake check --no-build --no-update-lock-file --quiet --no-warn-dirty
              ruff format --isolated --quiet --target-version py314 --line-length 96 --no-cache .
              ruff check --isolated --quiet --target-version py314 --line-length 96 --select E,F,I,UP,B --fix --unsafe-fixes --no-cache .
              cargo clippy --quiet --fix --allow-dirty --allow-staged --workspace --all-targets --locked -- -D warnings
              cargo fmt --all
              cargo clippy --quiet --locked --workspace --all-targets -- -D warnings
              cargo nextest run --cargo-quiet --locked --workspace --no-fail-fast \
                --status-level fail --final-status-level fail \
                --failure-output final --success-output never
            '';
          };
        };
    };
}
