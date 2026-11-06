{
  lib,
  runCommand,
  python3,
  tree-sitter-grammars,
}:

# Standalone highlighting queries for Emacs treesit-x generic modes.
# Output: <language>/highlights.scm, read through my-treesit-query-root.
# passthru.grammars lists the grammars the queries need; default.nix installs them.
# ts.py fails the build on anything it cannot convert; after Nixpkgs updates,
# upstream query changes may require deliberate adaptation.
let
  # The single list of converted languages. Queries come from the flake's pinned
  # Nixpkgs grammar sources; no independent fetches.
  languages = with tree-sitter-grammars; {
    nix = {
      grammar = tree-sitter-nix;
      query = "queries/highlights.scm";
    };
    just = {
      grammar = tree-sitter-just;
      query = "queries/just/highlights.scm";
    };
    typst = {
      grammar = tree-sitter-typst;
      query = "queries/typst/highlights.scm";
    };
  };

  grammars = lib.mapAttrsToList (_: language: language.grammar) languages;
in
runCommand "emacs-ts"
  {
    # ts.py uses only the standard library, at build time, never in Emacs.
    nativeBuildInputs = [ python3 ];
    passthru = { inherit grammars; };
    meta = {
      description = "Nix, Just and Typst highlighting queries adapted for Emacs treesit-x";
      platforms = lib.platforms.all;
    };
  }
  ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: language: ''
        python ${./ts.py} ${name} ${language.grammar.src}/${language.query} "$out/${name}/highlights.scm"
      '') languages
    )}
  ''
