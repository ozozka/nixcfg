{
  lib,
  runCommand,
  python3,
  tree-sitter-grammars,
  emacsPackagesFor,
  emacs-pgtk,
}:

let
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
        nativeBuildInputs = [ python3 ];
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
