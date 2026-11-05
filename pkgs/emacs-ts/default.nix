{
  lib,
  runCommand,
  python3,
  tree-sitter-grammars,
  emacsPackagesFor,
  emacs-pgtk,
}:

# Build standalone highlighting queries for Emacs treesit-x generic modes.
# Output: <language>/highlights.scm. modules/dev/emacs links this package at
# .config/emacs/tree-sitter/queries and owns installed grammars and mode definitions.
#
# Checks (also included in nix flake check on each configured system):
#   nix build .#emacs-ts                          # Queries and Python unit tests
#   nix build .#checks.x86_64-linux.emacs-ts-emacs # Emacs integration tests
# After Nixpkgs updates, review source paths, conversion failures, and highlighting
# failures together; upstream query changes may require deliberate adaptation.
let
  # Use the flake's pinned Nixpkgs grammar sources; no independent fetches.
  sources = with tree-sitter-grammars; {
    nix = "${tree-sitter-nix.src}/queries/highlights.scm";
    just = "${tree-sitter-just.src}/queries/just/highlights.scm";
    typst = "${tree-sitter-typst.src}/queries/typst/highlights.scm";
  };

  testGrammars = (emacsPackagesFor emacs-pgtk).treesit-grammars.with-grammars (
    grammars: with grammars; [
      tree-sitter-nix
      tree-sitter-just
      tree-sitter-typst
    ]
  );

  package =
    runCommand "emacs-ts"
      {
        # convert.py uses only the standard library, at build time, never in Emacs.
        nativeBuildInputs = [ python3 ];
        # Compile queries with matching grammars and test treesit-x fontification.
        # Compilation checks syntax/node names, not equivalence with upstream editors.
        passthru.tests.emacs = runCommand "emacs-ts-emacs-check" { nativeBuildInputs = [ emacs-pgtk ]; } ''
          export HOME="$TMPDIR"
          mkdir -p "$HOME/.emacs.d/tree-sitter"
          ln -s ${package} "$HOME/.emacs.d/tree-sitter/queries"
          emacs --batch -Q \
            --eval "(setq treesit-extra-load-path '(\"${testGrammars}/lib\"))" \
            -l ${./test-emacs.el} -f ert-run-tests-batch-and-exit
          touch "$out"
        '';
        meta = {
          description = "Nix, Just and Typst highlighting queries adapted for Emacs treesit-x";
          platforms = lib.platforms.all;
        };
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        python -m unittest discover -s ${./.} -p 'test_*.py' -v
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (language: source: ''
            python ${./convert.py} ${language} ${source} "$out/${language}/highlights.scm"
          '') sources
        )}
      '';
in
package
