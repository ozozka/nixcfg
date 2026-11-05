{
  lib,
  runCommand,
  python3,
  tree-sitter-grammars,
  emacsPackagesFor,
  emacs-pgtk,
}:

# Standalone highlighting queries for Emacs treesit-x generic modes.
# Output: <language>/highlights.scm, linked at .config/emacs/tree-sitter/queries.
# passthru.grammars lists the grammars the queries need; default.nix installs them.
#
# Checks (also included in nix flake check on each configured system):
#   nix build .#checks.x86_64-linux.emacs-ts        # Python unit tests
#   nix build .#checks.x86_64-linux.emacs-ts-emacs  # Emacs integration tests
# After Nixpkgs updates, review source paths, conversion failures, and highlighting
# failures together; upstream query changes may require deliberate adaptation.
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

  # Only the converter and its tests: editing Emacs tests must not rebuild queries.
  unitSources = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./ts.py
      ./test_ts.py
    ];
  };

  testGrammars = (emacsPackagesFor emacs-pgtk).treesit-grammars.with-grammars (_: grammars);

  queries =
    runCommand "emacs-ts"
      {
        # ts.py uses only the standard library, at build time, never in Emacs.
        nativeBuildInputs = [ python3 ];
        passthru = {
          inherit grammars;
          tests = {
            unit = runCommand "emacs-ts-check" { nativeBuildInputs = [ python3 ]; } ''
              export PYTHONDONTWRITEBYTECODE=1
              python -m unittest discover -s ${unitSources} -p 'test_*.py' -v
              touch "$out"
            '';
            # Compile queries with matching grammars and test treesit-x fontification.
            # Compilation checks syntax/node names, not equivalence with upstream editors.
            emacs = runCommand "emacs-ts-emacs-check" { nativeBuildInputs = [ emacs-pgtk ]; } ''
              export HOME="$TMPDIR"
              mkdir -p "$HOME/.emacs.d/tree-sitter"
              ln -s ${queries} "$HOME/.emacs.d/tree-sitter/queries"
              emacs --batch -Q \
                --eval "(setq treesit-extra-load-path '(\"${testGrammars}/lib\"))" \
                -l ${./test-ts.el} -f ert-run-tests-batch-and-exit
              touch "$out"
            '';
          };
        };
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
      '';
in
queries
