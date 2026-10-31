# Nix Configuration

## About

My Nix configuration.

**Principles**

- No third party extensions, plugins, mods, and packages for flake and programs.
- Modules and programs must contain and manage their dot files and configuration.
- All dot files must be managed from Nix declaratively without imperative setup.
- Options and constants must be managed and injected by Nix.
- Home Management configurable for each host and user.

## Manual

Most of the required commands exists as [just recipes](justfile) and can be used from there.

**Other Commands**

```bash
# Templates
nix flake init -t github:ozozka/nixcfg#default
nix flake new -t .#<template> ./new-project

# Apps
nix run
nix run .#info
```

## Reference

- [hosts/](hosts/): Host configurations: users, options, and imports.
- [modules/](modules/): Modules and options.
  - [base/](modules/base/): Core system module that is same at every host.
  - [desktop/](modules/desktop/): Desktop module that contains wm and utils.
  - [dev/](modules/dev/): Development setup: Emacs, Pi, lsp, and other tools,
  - [gui/](modules/gui/): Graphical programs.
  - [hardware/](modules/hardware/): Hardware related programs and drivers.
  - [misc/](modules/misc/): Miscellaneous modules.
  - [options.nix](modules/options.nix): Options shared by multiple modules.
  - [home.nix](modules/home.nix): Custom home module for dot file links.
  - [overlays.nix](modules/overlays.nix): Applies the overlays to modules.
- [overlays/](overlays/): Overlays.
- [pkgs/](pkgs/): Custom packages exported by flake.
- [templates/](templates/): Templates for projects and tools.
- [justfile](justfile): Management recipes.
- [README.md](README.md): Documentation.
- [apps.nix](apps.nix): Apps related to the system configuration.
- [checks.nix](checks.nix): Format, and module checks.
- [devshells.nix](devshells.nix): Development environments.
- [flake.nix](flake.nix): Base of the config, responsible from wiring.
- [formatter.nix](formatter.nix): Formatters for languages used.
- [lib.nix](lib.nix): Helper functions.

## Architecture

### Imports

`flake.nix` discovers hosts and modules through `lib.paths`. A directory with `default.nix` is a
single entry; otherwise, discovery recurses and joins names with hyphens. Entries starting with
`_` are ignored.

Hosts select exported modules. Modules explicitly import their dependencies and related
submodules.

### Options

Shared settings live under `ozozka` in `modules/options.nix`: user identity, colors, fonts,
dimensions, and other defaults. Module-specific settings live under `ozozka.mod`. Hosts override
these options to customize the system.

### Dotfiles

Each module keeps its program configuration alongside its Nix code. Static files are referenced
directly. When dotfiles need Nix options or constants, these are injected into a single
generated file that the other files import, keeping the Nix-to-program interface centralized.
Modules install configuration system-wide or expose it through home profiles.

### Home

`modules/home.nix` provides home file management without Home Manager. Modules declare reusable
profiles under `ozozka.home.profiles.<profile>.files`; hosts enable them per user with
`ozozka.home.users.<user>.<profile> = true`.

Files are exposed through `/etc/home-files/<user>` and linked into the user's home by
systemd-tmpfiles. Invalid paths and conflicting targets are rejected. All managed files are
public and store-backed; profiles must not contain secrets.

## Development

- `just fix`: Runs formatters and linters for the languages used.
- `just check`: Checks flake, format, and evaluates individual modules.

## Roadmap

I want to add declarative secrets management and impermanence/preservation when i have time but
current configuration is working and i dont have plans to work further except small refinements.
