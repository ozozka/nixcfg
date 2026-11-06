;;; test-ts.el --- Query integration checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'treesit-x)

(define-treesit-generic-mode emacs-ts-test-nix-mode
  :lang 'nix :parent #'prog-mode :name "Test Nix")
(define-treesit-generic-mode emacs-ts-test-just-mode
  :lang 'just :parent #'prog-mode :name "Test Just")
(define-treesit-generic-mode emacs-ts-test-typst-mode
  :lang 'typst :parent #'text-mode :name "Test Typst")

(ert-deftest emacs-ts-queries-compile ()
  ;; Use the same loading/mapping path as the real generic modes, not merely
  ;; the raw SCM: treesit-x supplies the remaining standard capture mappings.
  (dolist (language '(nix just typst))
    (should (treesit-language-available-p language))
    (let ((query (treesit-generic-mode-font-lock-query language)))
      (should query)
      (should (treesit-query-compile language query))
      ;; These bundles use faces, not custom fontification functions. Compilation
      ;; alone would accept a nonexistent face and fail only during fontification.
      (let ((start 0))
        (while (string-match "\\(?:\\`\\|[[:space:]()]\\)@\\([[:alnum:]_.-]+\\)"
                             query start)
          (should (facep (intern (match-string 1 query))))
          (setq start (match-end 0)))))))

(defun emacs-ts-test-face (text face)
  "Assert that the first occurrence of TEXT has FACE."
  (goto-char (point-min))
  (search-forward text)
  (let ((actual (get-text-property (- (point) (length text)) 'face)))
    (should (if (listp actual) (memq face actual) (eq face actual)))))

(ert-deftest emacs-ts-nix-fontification ()
  (with-temp-buffer
    (insert "{ f = x: x; value = builtins; flag = true; other = falsehood;\n"
            "  builtinFunction = import; result = import ./other.nix; }")
    (emacs-ts-test-nix-mode)
    (font-lock-ensure)
    (emacs-ts-test-face "f =" 'font-lock-function-name-face)
    (emacs-ts-test-face "x:" 'font-lock-variable-name-face)
    (emacs-ts-test-face "builtins" 'font-lock-builtin-face)
    (emacs-ts-test-face "true" 'font-lock-builtin-face)
    (emacs-ts-test-face "import" 'font-lock-builtin-face)
    (goto-char (point-min))
    (search-forward "falsehood")
    (should-not (eq (get-text-property (match-beginning 0) 'face)
                    'font-lock-builtin-face))))

(ert-deftest emacs-ts-nix-interpolation-fontification ()
  ;; The same expression must be fontified as code in either string syntax and
  ;; in paths, without a parent string face covering unstyled identifiers.
  (dolist (source '("\"before ${if true then 42 else plain} after\""
                    "''before ${if true then 42 else plain} after''"
                    "./before/${if true then 42 else plain}/after"
                    "~/before/${if true then 42 else plain}/after"))
    (with-temp-buffer
      (insert source)
      (emacs-ts-test-nix-mode)
      (font-lock-ensure)
      (should-not (treesit-search-subtree
                   (treesit-buffer-root-node 'nix) "ERROR"))
      (emacs-ts-test-face "before" 'font-lock-string-face)
      (emacs-ts-test-face "after" 'font-lock-string-face)
      (emacs-ts-test-face "${" 'font-lock-misc-punctuation-face)
      (emacs-ts-test-face "}" 'font-lock-misc-punctuation-face)
      (emacs-ts-test-face "if" 'font-lock-keyword-face)
      (emacs-ts-test-face "true" 'font-lock-builtin-face)
      (emacs-ts-test-face "42" 'font-lock-number-face)
      (goto-char (point-min))
      (search-forward "plain")
      (should-not (get-text-property (match-beginning 0) 'face)))))

(ert-deftest emacs-ts-nix-nested-interpolation-fontification ()
  (with-temp-buffer
    (insert "\"outer ${if true then \"inner ${42}\" else \"fallback\"} tail\"")
    (emacs-ts-test-nix-mode)
    (font-lock-ensure)
    (dolist (literal '("\"outer" "\"inner" "\"fallback" "tail\""))
      (emacs-ts-test-face literal 'font-lock-string-face))
    (emacs-ts-test-face "if" 'font-lock-keyword-face)
    (emacs-ts-test-face "42" 'font-lock-number-face)
    ;; Exercise incremental fontification, not just a fresh buffer.
    (goto-char (point-min))
    (search-forward "42")
    (replace-match "\"changed\"" t t)
    (font-lock-ensure)
    (emacs-ts-test-face "changed" 'font-lock-string-face)
    (goto-char (point-min))
    (search-forward "\"changed\"")
    (replace-match "false" t t)
    (font-lock-ensure)
    (emacs-ts-test-face "false" 'font-lock-builtin-face)
    (emacs-ts-test-face "tail\"" 'font-lock-string-face)))

(ert-deftest emacs-ts-nix-string-escapes-and-delimiters ()
  (dolist (source '("\"literal \\${notCode} end\""
                    "''literal ''${notCode} end''"))
    (with-temp-buffer
      (insert source)
      (emacs-ts-test-nix-mode)
      (font-lock-ensure)
      (emacs-ts-test-face "notCode" 'font-lock-string-face)
      (emacs-ts-test-face "end" 'font-lock-string-face)
      (emacs-ts-test-face source 'font-lock-string-face)
      (should (eq (get-text-property (1- (point-max)) 'face)
                  'font-lock-string-face))
      (goto-char (point-min))
      ;; dollar_escape covers the escape prefix, not the literal dollar.
      (search-forward (if (string-prefix-p "\"" source) "\\$" "''$"))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'font-lock-escape-face))))
  (with-temp-buffer
    (insert "[ \"\" '''' <nixpkgs/lib> https://example.org ]")
    (emacs-ts-test-nix-mode)
    (font-lock-ensure)
    (dolist (literal '("\"\"" "''''" "<nixpkgs/lib>" "https://example.org"))
      (emacs-ts-test-face literal 'font-lock-string-face))))

(ert-deftest emacs-ts-just-fontification ()
  (with-temp-buffer
    (insert "set dotenv-load\n\nhello name:\n    echo {{name}}\n")
    (emacs-ts-test-just-mode)
    (font-lock-ensure)
    (emacs-ts-test-face "dotenv-load" 'font-lock-keyword-face)
    (emacs-ts-test-face "hello" 'font-lock-function-name-face)
    (emacs-ts-test-face "name:" 'font-lock-variable-name-face)))

(ert-deftest emacs-ts-typst-fontification ()
  (with-temp-buffer
    (insert "= Heading\n#let answer = 42\n#let flag = true\n")
    (emacs-ts-test-typst-mode)
    (font-lock-ensure)
    (emacs-ts-test-face "Heading" 'font-lock-doc-face)
    (emacs-ts-test-face "let" 'font-lock-keyword-face)
    (emacs-ts-test-face "42" 'font-lock-number-face)
    (emacs-ts-test-face "true" 'font-lock-constant-face)))

;;; test-ts.el ends here
