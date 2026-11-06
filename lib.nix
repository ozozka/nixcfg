self:

let
  inherit (builtins) attrNames pathExists readDir;
  inherit (self.inputs.nixpkgs) lib;

  joinName = prefix: name: if prefix == "" then name else "${prefix}-${name}";

  selectedEntries =
    {
      dir,
      prefix ? "",
    }:
    let
      entries = readDir dir;
      names = lib.sort builtins.lessThan (attrNames entries);
    in
    lib.concatMap (
      name:
      let
        path = dir + "/${name}";
        type = entries.${name};
      in
      if lib.hasPrefix "_" name then
        [ ]
      else if type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix" then
        [
          {
            name = joinName prefix (lib.removeSuffix ".nix" name);
            inherit path;
          }
        ]
      else if type == "directory" then
        if pathExists (path + "/default.nix") then
          [
            {
              name = joinName prefix name;
              path = path + "/default.nix";
            }
          ]
        else
          selectedEntries {
            dir = path;
            prefix = joinName prefix name;
          }
      else
        [ ]
    ) names;

  checkedEntries =
    dir:
    let
      entries = selectedEntries { inherit dir; };
      grouped = lib.groupBy (entry: entry.name) entries;
      duplicates = lib.filterAttrs (_: matches: builtins.length matches > 1) grouped;

      formatDuplicate =
        name: matches: "${name}: ${lib.concatStringsSep ", " (map (entry: toString entry.path) matches)}";
    in
    if duplicates == { } then
      entries
    else
      throw ''
        Duplicate discovered names:
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatDuplicate duplicates)}
      '';
in
rec {
  paths =
    dir: act:
    lib.listToAttrs (
      map (entry: {
        inherit (entry) name;
        value = act entry.path;
      }) (checkedEntries dir)
    );

  # Every file in this flake is a function of `self`.
  load = path: import path self;

  # Keyed by path so repeated imports dedup, which is safe because every file gets the same
  # `self`. A default.nix module also imports its siblings.
  module = path: {
    key = toString path;
    _file = path;
    imports = [
      (load path)
    ]
    ++ lib.optionals (baseNameOf path == "default.nix") (lib.attrValues (paths (dirOf path) module));
  };

  perSystem =
    systems: f: lib.genAttrs systems (system: f self.inputs.nixpkgs.legacyPackages.${system});

  # Builds every package in `dir` with the given pkgs.
  packages = dir: pkgs: paths dir (path: pkgs.callPackage (load path) { });

  templates =
    dir:
    lib.mapAttrs (name: _: {
      path = dir + "/${name}";
      inherit (import (dir + "/${name}/flake.nix")) description;
    }) (readDir dir);
}
