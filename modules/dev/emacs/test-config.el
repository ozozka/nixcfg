;;; test-config.el --- Load the compiled configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Run by the emacs-config-check in default.nix against the configured Emacs.
;; Batch Emacs skips default.el (--batch implies -q), so load it explicitly.

;;; Code:

(require 'ert)

(load "default" nil t)

(ert-deftest my-config-loaded ()
  (dolist (feature '(my-options my-core my-modes my-env my-net))
    (should (featurep feature)))
  (should (custom-theme-enabled-p 'my)))

(ert-deftest my-config-compiled ()
  ;; Compiled files are installed and preferred over the sources.
  (dolist (library '("default" "my-core" "my-modes" "my-env" "my-net"))
    (should (string-suffix-p ".elc" (locate-library library))))
  ;; A top-level definition, so it exists without loading deferred packages.
  (let ((function (symbol-function 'my-gnus--feed-topic-regexp)))
    (should (if (native-comp-available-p)
                (native-comp-function-p function)
              (byte-code-function-p function)))))

(ert-deftest my-config-queries ()
  ;; Generic modes read the Nix-built queries, not user-emacs-directory.
  (dolist (language '(nix just typst))
    (should (treesit-generic-mode-font-lock-query language))))

;;; test-config.el ends here
