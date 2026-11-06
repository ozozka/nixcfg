_:

{
  lib,
  runCommand,
  vimPlugins,
  pkgs,
  ...
}:

let
  parsers = with pkgs.tree-sitter-grammars; [
    tree-sitter-bash
    tree-sitter-cmake
    tree-sitter-cpp
    tree-sitter-css
    tree-sitter-csv
    tree-sitter-cuda
    tree-sitter-dockerfile
    # tree-sitter-git-config
    # tree-sitter-git-rebase
    tree-sitter-gitattributes
    # tree-sitter-gitcommit
    tree-sitter-gitignore
    tree-sitter-html
    tree-sitter-ini
    tree-sitter-java
    tree-sitter-javascript
    tree-sitter-json
    tree-sitter-julia
    tree-sitter-just
    tree-sitter-kdl
    tree-sitter-log
    tree-sitter-make
    tree-sitter-nix
    tree-sitter-python
    tree-sitter-rust
    tree-sitter-sql
    tree-sitter-toml
    tree-sitter-tsx
    tree-sitter-typescript
    tree-sitter-xml
    tree-sitter-yaml
  ];

  getLang =
    pkg:
    let
      name = pkg.pname or (builtins.parseDrvName pkg.name).name;
      stripped = lib.removePrefix "tree-sitter-" name;
    in
    builtins.replaceStrings [ "-" ] [ "_" ] stripped;
in
runCommand "treesitter-runtime" { } ''
  mkdir -p $out/parser
  mkdir -p $out/queries
  ${lib.concatMapStrings (pkg: ''
    lang=${getLang pkg}
    ln -s ${pkg}/parser $out/parser/$lang.so

    if [ -d ${vimPlugins.nvim-treesitter.src}/runtime/queries/$lang ]; then
      ln -s ${vimPlugins.nvim-treesitter.src}/runtime/queries/$lang $out/queries/$lang
    fi
  '') parsers}
''
