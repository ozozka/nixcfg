# Nix Configuration

## About

The main reason I use Nix is its declarative model. It lets me describe how my system and
project environments should be configured, rather than maintain a sequence of setup steps. I
treat system infrastructure and project dependencies as part of the same approach: both should
be explicit, versioned, and reproducible, rather than depend on accumulated machine state or
manual setup. Nix brings system configuration and package management together, replacing
fragmented tools and installation methods with a unified approach.

I aim to keep the setup lean: maximize value while minimizing complexity, maintenance surface,
and dependencies. I prefer built-in capabilities over additional layers and add-ons, manage
software centrally, and share settings to keep behavior consistent across the system. Changes
should be predictable and easy to recover from, while keeping the system up to date.

## Manual

Most of the required commands are wrapped as Nix flake apps for ease of use. `nix flake show`
lists the available apps, while the `r` shell alias provides a shorthand for running them.

```bash
nix run              # Build and activate the current host configuration
r ls                 # List system generations
r gc                 # Delete old generations and collect unused store paths
r info               # Run the info app
r nixpkgs#hello      # Run an external flake app
```

**Templates**

```bash
nix flake init -t github:ozozka/nixcfg#default
nix flake new -t .#<template> ./new-project
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
- [pkgs/](pkgs/): Custom packages exported by flake.
- [templates/](templates/): Templates for projects and tools.
- [README.md](README.md): Documentation.
- [apps.nix](apps.nix): Apps related to the system configuration.
- [checks.nix](checks.nix): Format, and module checks.
- [devshells.nix](devshells.nix): Development environments.
- [flake.nix](flake.nix): Base of the config, responsible from wiring.
- [formatter.nix](formatter.nix): Formatters for languages used.
- [lib.nix](lib.nix): Helper functions.

## Architecture

### Principles

- No third-party program extensions, plugins, or mods, or additional flake dependencies.
- Modules and programs must contain and manage their dotfiles and configuration.
- All dotfiles must be managed declaratively through Nix, without imperative setup.
- Options and constants must be managed and injected by Nix.
- Home management must be configurable for each host and user.
- Flake outputs must be directly reusable without project-specific special arguments.

### Imports

- `flake.nix` discovers hosts, modules, and packages through `lib.paths`.
- A `.nix` file or a directory with `default.nix` is one entry; `_` prefixed names are ignored.
- Other directories are searched recursively, joining names with hyphens (`gui-steam`).
- Files start with `self:` (`_:` if unused) and reach other flake parts only through `self`.
- Modules: `self: { config, pkgs, ... }: { }`, importing shared ones from `self.nixosModules`.
- A `default.nix` module also imports the other modules in its directory.

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

### Updates

`nix flake update` updates the inputs pinned in [flake.lock](flake.lock).

### Formatting

[formatter.nix](formatter.nix) configures treefmt with language-specific formatters and linters.
`nix fmt` runs them across the repository, applying formatting and supported fixes.

### Checks

[checks.nix](checks.nix) checks formatting, builds the custom packages, and evaluates each
exported NixOS module independently. `nix flake check` runs these checks alongside the standard
flake validation.

### Package Maintenance

Custom packages live in [pkgs/](pkgs/). `r hash <hash>` converts a SHA-256 hash to SRI format
for package definitions.

## Roadmap

I want to add declarative secrets management and impermanence/preservation when i have time but
current configuration is working and i dont have plans to work further except small refinements.
