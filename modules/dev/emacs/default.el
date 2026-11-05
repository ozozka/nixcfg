;;; default.el --- Emacs config -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded from site-lisp after the (optional) user init file; `emacs -q' skips it.
;; Built and compiled by Nix (default.nix); `user-emacs-directory' keeps only state.

;;; Code:

;; Themes are not searched on `load-path'; my-theme.el lives next to this file.
(add-to-list 'custom-theme-load-path
             (file-name-directory (locate-library "my-theme")))

;; Required at load time only: a top-level `require' would also run the whole
;; configuration while byte-compiling this file.
(dolist (feature '(my-options my-core my-modes my-env my-net))
  (require feature))

(load-theme 'my t)

;;; default.el ends here
