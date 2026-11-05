# Emacs tree-sitter queries

`emacs-ts` builds highlighting queries for the Nix, Just, and Typst generic modes in Emacs
`treesit-x`. Sources come from the flake's pinned Nixpkgs grammars; there are no independent
fetches. The output is `<language>/highlights.scm`, linked by the Emacs module at
`.config/emacs/tree-sitter/queries`.

`default.nix` owns source paths and build dependencies. `convert.py` uses only the Python
standard library and runs at build time, not in Emacs. Grammar selection and mode definitions
remain in `modules/dev/emacs/`.

The converter parses balanced query forms before mapping captures and predicates. It supports
only the predicates and regexp subset needed here. Unknown predicates, unsupported regexp
constructs, and changes to required Nix patterns fail the build for review. Standard captures
not mapped by the converter are handled by Emacs's built-in `treesit-x` mapping.

Nix-specific removals, builtin priority, and the extra function-binding query are kept in
Python. Dropping Nix's `#is-not? local` deliberately preserves the previous behavior: builtins
can also match shadowed names. Dropping `#offset!` highlights whole nodes rather than adjusted
ranges. `#any-of?` becomes an escaped, whole-string Emacs regexp. Builtin functions use
`font-lock-builtin-face`, replacing the old mapping to the nonexistent
`font-lock-function-face`.

## Checks

- `nix build .#emacs-ts`: generate queries and run Python unit tests.
- `nix build .#checks.x86_64-linux.emacs-ts-emacs`: compile all queries with Emacs and the
  matching grammars, then test representative fontification through `treesit-x`.
- Both are included in `nix flake check` on each configured system.

After a Nixpkgs update, review source-path changes, conversion failures, and highlighting test
failures together. Query compilation validates syntax and node names, not semantic equivalence
with upstream editors.
