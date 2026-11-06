;;; my-modes.el --- Modes -*- lexical-binding: t; -*-

;;; Commentary:
;;; Code:

(require 'my-options)

(use-package eglot
  :ensure nil
  :defer t
  :hook
  ((sh-mode
    bash-ts-mode
    c-mode
    c-ts-mode
    c++-mode
    c++-ts-mode
    css-mode
    css-ts-mode
    scss-mode
    less-css-mode
    dockerfile-mode
    dockerfile-ts-mode
    mhtml-mode
    mhtml-ts-mode
    js-mode
    js-ts-mode
    js-jsx-mode
    typescript-ts-mode
    tsx-ts-mode
    js-json-mode
    json-mode
    json-ts-mode
    jsonc-mode
    just-ts-mode
    lua-mode
    lua-ts-mode
    markdown-ts-mode
    nix-ts-mode
    python-mode
    python-ts-mode
    rust-mode
    rust-ts-mode
    sql-mode
    context-mode
    typst-ts-mode
    yaml-mode
    yaml-ts-mode)
   . eglot-ensure)
  :custom
  (eglot-code-action-indications nil)
  (eglot-documentation-renderer 'markdown-ts-view-mode)
  :config
  (dolist
      (entry
       '((((css-mode :language-id "css")
           (css-ts-mode :language-id "css")
           (scss-mode :language-id "scss")
           (less-css-mode :language-id "less"))
          . ("vscode-css-language-server" "--stdio"))
         (((dockerfile-mode :language-id "dockerfile")
           (dockerfile-ts-mode :language-id "dockerfile"))
          . ("docker-language-server" "start" "--stdio"))
         (((mhtml-mode :language-id "html")
           (mhtml-ts-mode :language-id "html"))
          . ("vscode-html-language-server" "--stdio"))
         (((js-mode :language-id "javascript")
           (js-ts-mode :language-id "javascript")
           (js-jsx-mode :language-id "javascriptreact")
           (typescript-ts-mode :language-id "typescript")
           (tsx-ts-mode :language-id "typescriptreact"))
          . ("typescript-language-server" "--stdio"))
         ((just-ts-mode :language-id "just") . ("just-lsp"))
         (((lua-mode :language-id "lua")
           (lua-ts-mode :language-id "lua"))
          . ("emmylua_ls"))
         ((markdown-ts-mode :language-id "markdown") . ("marksman" "server"))
         ((nix-ts-mode :language-id "nix") . ("nixd"))
         (((python-mode :language-id "python")
           (python-ts-mode :language-id "python"))
          . ("ty" "server"))
         ((sql-mode :language-id "sql") . ("sqls"))
         ((typst-ts-mode :language-id "typst") . ("tinymist"))))
    (add-to-list 'eglot-server-programs entry)))

(use-package treesit
  :ensure nil
  :init
  (setopt treesit-enabled-modes
          '(bash-ts-mode
            c-ts-mode
            c++-ts-mode
            css-ts-mode
            dockerfile-ts-mode
            mhtml-ts-mode
            js-ts-mode
            json-ts-mode
            lua-ts-mode
            python-ts-mode
            rust-ts-mode
            tsx-ts-mode
            typescript-ts-mode
            yaml-ts-mode)))

(use-package log-edit
  :defer t
  :hook
  (log-edit-mode . (lambda () (buffer-face-set 'variable-pitch))))

(use-package info
  :hook
  (Info-mode . my-info-setup)
  :config
  (defun my-info-setup ()
    (buffer-face-set 'variable-pitch)))

(use-package c-ts-mode
  :ensure nil
  :mode ("\\.cuh?\\'" . c++-ts-mode))

(use-package markdown-ts-mode
  :functions my-markdown-sync-line-numbers
  :mode ("\\.\\(?:md\\|markdown\\|mdown\\|mkd\\)\\'" . markdown-ts-mode)
  :custom
  (markdown-ts-hide-markup t)
  (markdown-ts-inline-images t)
  (markdown-ts-image-max-width 'window)
  (markdown-ts-fontify-code-blocks-natively t)
  (markdown-ts-enable-code-block-context-mode t)
  (markdown-ts-enable-table-mode t)
  (markdown-ts-default-folding 'show-all)
  (markdown-ts-unordered-list-marker '(("∙ " . "* "))) ; ⋅
  (markdown-ts-checked-checkbox '("✔ " . "+ "))
  (markdown-ts-unchecked-checkbox '("⬦ " . "- "))
  :hook
  (markdown-ts-mode . my-markdown-writing-setup)
  :bind
  (:map markdown-ts-mode-map ("C-c c" . markdown-ts-toggle-hide-markup))
  :config
  (defun my-markdown-sync-line-numbers (&rest _)
    (display-line-numbers-mode (if markdown-ts-hide-markup -1 1)))
  (advice-add 'markdown-ts-toggle-hide-markup
              :after #'my-markdown-sync-line-numbers)
  (defun my-markdown-writing-setup ()
    "Configure Markdown."
    (buffer-face-set 'variable-pitch)
    (font-lock-add-keywords
     nil
     '(("^\\([ \t]+\\)" (1 'fixed-pitch prepend)))
     'append)
    (my-markdown-sync-line-numbers)
    (electric-pair-local-mode 1)))

(use-package treesit-x
  :ensure nil
  :demand t
  ;; Generic mode bodies call into treesit, which treesit-x loads at runtime.
  :functions treesit-major-mode-setup
  :preface
  ;; treesit-x always reads queries below `user-emacs-directory'; read the
  ;; Nix-built queries instead.
  (define-advice treesit-generic-mode-font-lock-query (:around (query lang) my-nix-queries)
    "Read LANG highlighting queries from `my-treesit-query-root'."
    (let ((user-emacs-directory my-treesit-query-root))
      (funcall query lang)))
  :config
  (define-treesit-generic-mode just-ts-mode
    "Tree-sitter mode for Justfiles."
    :lang 'just
    :auto-mode "\\(?:^\\|/\\)[Jj]ustfile\\'"
    :parent #'prog-mode
    :name "Just"
    (setq-local comment-start "# ")
    (setq-local comment-end ""))

  (define-treesit-generic-mode nix-ts-mode
    "Tree-sitter mode for Nix expressions."
    :lang 'nix
    :auto-mode "\\.nix\\'"
    :parent #'prog-mode
    :name "Nix"
    (setq-local comment-start "# ")
    (setq-local comment-end ""))

  (define-treesit-generic-mode typst-ts-mode
    "Tree-sitter mode for Typst documents."
    :lang 'typst
    :auto-mode "\\.typ\\'"
    :parent #'text-mode
    :name "Typst"
    (setq-local comment-start "// ")
    (setq-local comment-end "")))

(provide 'my-modes)
;;; my-modes.el ends here
