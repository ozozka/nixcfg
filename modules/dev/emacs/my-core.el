;;; my-core.el --- Built-in feature configurations -*- lexical-binding: t; -*-

;;; Commentary:
;;; Code:

(defvar my-scroll-step 12 "Number of lines to scroll with custom scroll commands.")

(use-package server
  :ensure nil
  :custom
  (server-window #'switch-to-buffer-other-window))

(use-package emacs
  :ensure nil

  :bind
  ("M-<down>" . (lambda () (interactive) (scroll-up-command my-scroll-step)))
  ("M-<up>" . (lambda () (interactive) (scroll-down-command my-scroll-step)))
  ("S-M-<down>" . (lambda () (interactive) (scroll-other-window my-scroll-step)))
  ("S-M-<up>" . (lambda () (interactive) (scroll-other-window (- my-scroll-step))))
  ("C-c SPC" . project-recompile)
  ("C-c C-SPC" . project-compile)
  ("C-c e" . project-async-shell-command)
  ("C-c a" .  (lambda () (interactive) (save-buffer) (kill-current-buffer)))
  ("C-c s" . project-save-some-buffers)
  ("C-c f" . project-find-file)
  ("C-c d" . project-dired)
  ("C-c v" . project-vc-dir)
  ("C-c b" . ibuffer)
  ("C-c z" . (lambda () (interactive) (ansi-term (getenv "SHELL") "bash")))
  ("C-c =" . count-words)
  ("C-c w" . whitespace-cleanup)
  ("C-c t" . toggle-frame-tab-bar)
  ("C-c q" . tab-line-close-tab)
  ("C-c k" . kill-current-buffer)
  ("C-c m" . (lambda () (interactive) (flymake-start t)))
  ("C-c C-m" . (lambda (directory)
                 (interactive (list (read-directory-name "Trust directory: " default-directory default-directory t)))
                 (add-to-list 'trusted-content (abbreviate-file-name (file-name-as-directory (file-truename directory))))
                 (message "Trusted content: %s" trusted-content)))

  :config
  (load custom-file 'noerror)
  (fset 'yes-or-no-p 'y-or-n-p)
  (prefer-coding-system 'utf-8)
  (set-language-environment "UTF-8")
  (windmove-default-keybindings)
  (cua-mode 1)
  (show-paren-mode 1)
  (column-number-mode 1)
  (global-auto-revert-mode 1)
  (blink-cursor-mode -1)
  (window-divider-mode -1)
  (fringe-mode '(0 . 0))
  (add-to-list
   'display-buffer-alist
   '((derived-mode . (vc-dir-mode log-view-mode dired-mode ibuffer-mode term-mode))
     (display-buffer-reuse-window
      display-buffer-same-window)))

  :custom
  (void-text-area-pointer 'arrow)
  (x-pointer-shape 'text)
  (x-sensitive-text-pointer-shape 'hand)
  (initial-scratch-message nil)
  (select-enable-clipboard t)
  (select-enable-primary t)
  (indent-tabs-mode nil)
  (tab-width 2)
  (tab-stop-list (number-sequence 2 300 2))
  (display-line-numbers-type 'relative)
  (sentence-end-double-space nil)
  (read-buffer-completion-ignore-case t)
  (read-file-name-completion-ignore-case t)
  (ring-bell-function 'ignore)
  (scroll-margin 3)
  (scroll-conservatively 101)
  (scroll-preserve-screen-position t)
  (initial-scratch-message nil)
  (ring-bell-function 'ignore)
  (line-spacing '(0.072 . 0.072))
  (create-lockfiles nil)
  (make-backup-files nil)
  (auto-save-default nil)
  (custom-file (expand-file-name "custom.el" user-emacs-directory))

  (mode-line-format
   '("%e"
     mode-line-front-space
     (:eval
      (propertize
       (buffer-name)
       'face (pcase (list (buffer-modified-p) buffer-read-only)
               (`(t t) '((t :inherit mode-line-inactive)))
               (`(t nil) '((t :inherit flymake-warning-echo :weight bold))) ; flymake-error-echo
               (`(nil t) '((t :inherit mode-line-inactive)))
               ('((t :inherit mode-line :weight bold))))))
     " "
     (:eval
      (cond
       ((derived-mode-p 'doc-view-mode)
        mode-line-position)
       ((derived-mode-p 'image-mode)
        (when-let* ((image
                     (and buffer-file-name
                          (create-image buffer-file-name nil nil :scale 1)))
                    (size (image-size image t)))
          (format "%dx%d" (car size) (cdr size))))
       (t
        `((:eval (number-to-string (- (line-number-at-pos (point-max)) 1)))
          (:propertize ":" face mode-line-inactive)
          "%l"
          (:propertize "-" face mode-line-inactive)
          (:eval (number-to-string (save-excursion (end-of-line) (current-column))))
          (:propertize ":" face mode-line-inactive)
          "%c"))))
     " "
     mode-line-format-right-align
     mode-line-modes
     mode-line-misc-info
     (project-mode-line project-mode-line-format)
     mode-line-end-spaces)))

(use-package uniquify
  :ensure nil
  :custom
  (uniquify-buffer-name-style 'forward))

(use-package desktop
  :ensure nil
  :custom
  (desktop-save nil)
  (desktop-auto-save-timeout nil)
  (desktop-load-locked-desktop 'check-pid)
  (desktop-restore-frames t))

(use-package tab-line
  :ensure nil
  :custom
  (tab-line-new-button-show nil)
  (tab-line-close-button-show nil)
  (tab-line-left-button nil)
  (tab-line-right-button nil)
  (tab-line-separator "")
  (tab-line-switch-cycling t)
  (tab-line-tab-name-truncated-max 24)
  (tab-line-tab-name-function
   (lambda (buffer &optional buffers)
     (format " %d %s "
             (1+ (seq-position buffers buffer))
             (tab-line-tab-name-truncated-buffer buffer buffers))))
  (tab-line-auto-hscroll t)
  ;; (tab-line-tabs-buffer-groups nil)
  (tab-line-tabs-function #'tab-line-tabs-fixed-window-buffers)
  (tab-line-tabs-buffer-group-function #'tab-line-tabs-buffer-group-by-project)
  :bind
  ("M-0" . (lambda () (interactive) (switch-to-buffer nil)))
  :config
  (dotimes (index 9)
    (let ((number (1+ index)))
      (keymap-set
       global-map
       (format "M-%d" number)
       (lambda ()
         (interactive)
         (let* ((tab (nth (1- number) (funcall tab-line-tabs-function)))
                (buffer (and tab (get-buffer tab))))
           (when buffer (tab-line-select-tab-buffer buffer (selected-window))))))))
  (global-tab-line-mode 1))

(use-package tab-bar
  :ensure nil
  :custom
  (tab-bar-show nil)
  (tab-bar-tab-hints t)
  (tab-bar-close-button-show nil)
  (tab-bar-new-button-show nil)
  (tab-bar-format '(tab-bar-format-tabs))
  (tab-bar-separator " ")
  (tab-bar-select-tab-modifiers '(control))
  (tab-bar-new-tab-choice (lambda () (generate-new-buffer "*scratch*")))
  :config
  (tab-bar-mode 1)
  (tab-bar-history-mode 1))

(use-package diff-mode
  :ensure nil
  :custom
  (tab-width 4)
  (diff-refine-nonmodified nil)
  (diff-font-lock-prettify t))

(use-package vc-git
  :ensure nil
  :config
  (require 'subr-x)
  (defvar my-vc-git-stats-cache (make-hash-table :test 'equal) "Git statistics indexed by absolute file name.")
  (defun my-vc-git-collect-stats (dir)
    "Collect tracked and untracked change statistics in DIR."
    (clrhash my-vc-git-stats-cache)
    ;; Tracked files.
    (with-temp-buffer
      (when (zerop (process-file "git" nil t nil "-C" dir "diff" "HEAD" "--numstat"))
        (dolist (line (split-string (buffer-string) "\n" t))
          (pcase (split-string line "\t")
            (`(,a ,d ,file)
             (puthash
              (expand-file-name file dir)
              (list (string-to-number a)
                    (string-to-number d))
              my-vc-git-stats-cache))))))
    ;; Untracked files.
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (when (zerop (process-file "git" nil t nil "-C" dir "ls-files" "--others" "--exclude-standard" "-z"))
        (dolist (file (split-string (buffer-string) "\0" t))
          (let ((path (expand-file-name file dir)))
            (when (file-regular-p path)
              (puthash
               path
               (list
                (with-temp-buffer
                  (insert-file-contents-literally path)
                  (count-lines (point-min) (point-max)))
                0)
               my-vc-git-stats-cache)))))))
  (defun my-vc-git-numstat (_dir)
  "Return a one-line summary of uncommitted Git changes."
  (let ((added 0)
        (removed 0)
        (count 0))
    (maphash
     (lambda (_file stats)
       (cl-incf count)
       (cl-incf added (car stats))
       (cl-incf removed (cadr stats)))
     my-vc-git-stats-cache)
    (when (> count 0)
      (concat
       (propertize (format "%d " count) 'face 'bold)
       (propertize (format "%+d" (- added removed)) 'face (if (>= added removed) 'diff-indicator-added 'diff-indicator-removed))
       (propertize (format " +%d -%d" added removed) 'face 'vc-dir-header)))))
  (defun my-vc-git-commit-count (dir)
    "Return the number of commits reachable from HEAD in DIR."
    (with-temp-buffer
      (when (zerop (process-file "git" nil t nil "-C" dir "rev-list" "--count" "HEAD"))
        (string-trim (buffer-string)))))
  (defun my-vc-git-extra-stats (original dir)
  "Append Git statistics and commit count to ORIGINAL header."
  (my-vc-git-collect-stats dir)
  (let ((header (funcall original dir))
        (stats (my-vc-git-numstat dir))
        (commits (my-vc-git-commit-count dir)))
    (string-join
     (delq nil
           (list
            (unless (string-empty-p (or header "")) header)
            (when commits (concat (propertize "Commits    : " 'face 'vc-dir-header) commits))
            (when stats (concat (propertize "Change     : " 'face 'vc-dir-header) stats))))
     "\n")))
  (advice-add 'vc-git-dir-extra-headers :around #'my-vc-git-extra-stats)
  (defun my-vc-git-dir-stats (original info)
  "Print INFO with Git statistics before the filename."
  (let ((start (point)))
    (funcall original info)
    (let* ((file (vc-dir-fileinfo->name info))
           (path (expand-file-name file default-directory))
           (stats (unless (vc-dir-fileinfo->directory info) (gethash path my-vc-git-stats-cache)))
           (filename-pos (text-property-any start (point) 'keymap vc-dir-filename-mouse-map)))
      (when filename-pos
        (save-excursion
          (goto-char filename-pos)
          (if stats
              (pcase-let* ((`(,added ,removed) stats) (change (- added removed)))
                (insert
                 (propertize (format "%3d%3d" added removed) 'face 'vc-dir-header)
                 (propertize (format " %+4d " change) 'face (if (>= change 0) 'diff-indicator-added 'diff-indicator-removed))))
                ;; Keep directory names aligned with file names.
                (insert (make-string 12 ?\s))))))))
  (advice-remove 'vc-git-dir-printer #'my-vc-git-dir-stats)
  (advice-add 'vc-git-dir-printer :around #'my-vc-git-dir-stats)
  :custom
  (vc-git-diff-switches '("--unified=1" "--numstat" "--shortstat")))

(use-package vc
  :ensure nil
  :custom
  (vc-dir-auto-hide-up-to-date t))

(use-package ibuffer
  :ensure nil
  :custom
  (ibuffer-default-sorting-mode 'filename/process)
  :config
  (keymap-set ibuffer-mode-map "V"
              (lambda () (interactive)
                (let ((buffers (ibuffer-get-marked-buffers)))
                  (unless buffers (user-error "No marked buffers"))
                  (dolist (buffer (reverse buffers)) (switch-to-buffer buffer))))))

(use-package dired
  :ensure nil
  :custom
  (dired-free-space nil)
  (dired-kill-when-opening-new-dired-buffer t)
  (dired-listing-switches "-ACxXlh --group-directories-first")
  (dired-recursive-copies 'always)
  (dired-recursive-deletes 'always)
  :hook
  (dired-mode . dired-hide-details-mode))

(use-package shell
  :ensure nil
  :hook
  (shell-mode . ansi-color-for-comint-mode-on))

(use-package term
  :ensure nil
  :hook
  (term-mode . (lambda ()
                 (setq-local font-lock-mode nil)
                 (setq-local bidi-display-reordering nil)
                 (setq-local bidi-paragraph-direction 'left-to-right)
                 (setq-local truncate-lines t)
                 (setq-local scroll-margin 0)
                 (setq-local scroll-conservatively 101)
                 (setq-local scroll-step 1)))
  :config
  (keymap-set term-raw-map "C-S-c" #'kill-ring-save)
  (keymap-set term-raw-map "C-S-v" #'term-paste)
  (keymap-set term-raw-map "<escape>" (lambda () (interactive) (term-send-raw-string "\e")))
  (keymap-set term-raw-map "S-<return>" (lambda () (interactive) (term-send-raw-string "\026\n")))
  (keymap-set term-raw-map "C-c d" (keymap-lookup global-map "C-c d"))
  (keymap-set term-raw-map "C-c z" (keymap-lookup global-map "C-c z"))
  (keymap-set term-raw-map "C-c f" (keymap-lookup global-map "C-c f"))
  (keymap-set term-raw-map "C-c q" (keymap-lookup global-map "C-c q"))
  (keymap-set term-raw-map "C-c k" (keymap-lookup global-map "C-c k"))
  (dotimes (number 10)
    (let ((key (format "M-%d" number)))
      (keymap-set term-raw-map key (keymap-lookup global-map key)))))

(use-package compile
  :ensure nil
  :custom
  (compilation-scroll-output 'first-error)
  (compile-command "just")
  :config
  (add-to-list
   'display-buffer-alist
   '((derived-mode . compilation-mode)
     (display-buffer-in-side-window)
     (side . bottom)
     (slot . 0)
     (window-height . 0.333334))))

(use-package minibuffer
  :ensure nil
  :hook
  ((minibuffer-setup . cursor-intangible-mode)
   (minibuffer-setup . (lambda () (setq truncate-lines t))))
  :custom
  (tab-always-indent 'complete)
  (completion-auto-help t)
  (completion-auto-select t)
  (completion-eager-update t)
  (completion-eager-display t)
  (completion-ignore-case t)
  (completion-show-help nil)
  (completion-styles '(basic flex initials))
  (completions-format 'one-column)
  (completions-max-height 8)
  (completions-sort 'historical)
  (read-buffer-completion-ignore-case t)
  (read-file-name-completion-ignore-case t)
  (minibuffer-prompt-properties
   '(read-only t intangible t cursor-intangible t face minibuffer-prompt))
  (minibuffer-electric-default-mode t)
  (completions-detailed t)
  :config
  (global-completion-preview-mode 1))

(use-package epg
  :ensure nil
  :custom
  (epg-pinentry-mode 'loopback))

(use-package ispell
  :ensure nil
  :custom
  (ispell-program-name "hunspell")
  (ispell-dictionary "en_US,tr_TR")
  (ispell-silently-savep t)
  (ispell-quitely t)
  :config
  (ispell-set-spellchecker-params)
  (ispell-hunspell-add-multi-dic "en_US,tr_TR"))

(use-package flyspell
  :ensure nil
  :hook
  (text-mode . flyspell-mode)
  (prog-mode . flyspell-prog-mode)
  :custom
  (flyspell-issue-message-flag nil)
  (flyspell-prog-text-faces
   '(font-lock-comment-face font-lock-doc-face)))

(use-package whitespace
  :ensure nil
  :hook
  (prog-mode . whitespace-mode)
  (text-mode . whitespace-mode)
  :custom
  (whitespace-style
   '(face
     trailing
     empty
     tabs
     space-before-tab
     space-after-tab)))

(use-package prog-mode
  :ensure nil
  :hook
  (prog-mode . subword-mode)
  (prog-mode . flymake-mode)
  (prog-mode . electric-pair-local-mode)
  (prog-mode . display-line-numbers-mode))

(provide 'my-core)
;;; my-core.el ends here
