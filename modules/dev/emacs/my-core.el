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
  :functions flymake-start project-prefixed-buffer-name project-root

  :bind
  ;; Navigation: Shift moves, Ctrl+Shift relocates or acts on the other window.
  ("S-<down>" . (lambda () (interactive) (scroll-up-command my-scroll-step)))
  ("S-<up>" . (lambda () (interactive) (scroll-down-command my-scroll-step)))
  ("C-S-<down>" . (lambda () (interactive) (scroll-other-window my-scroll-step)))
  ("C-S-<up>" . (lambda () (interactive) (scroll-other-window (- my-scroll-step))))
  ;; Results of compile, project search, grep, occur; Flymake diagnostics are on M-S-<up/down>.
  ("M-<up>" . previous-error)
  ("M-<down>" . next-error)
  ("S-<left>" . tab-line-switch-to-prev-tab)
  ("S-<right>" . tab-line-switch-to-next-tab)
  ("C-S-<left>" . tab-line-move-tab-backward)
  ("C-S-<right>" . tab-line-move-tab-forward)
  ;; The window's own previous buffer, matching its tab line, not the frame-wide one.
  ("M-<tab>" . (lambda ()
                 (interactive)
                 (when-let* ((entry (seq-find (lambda (entry)
                                                (and (buffer-live-p (car entry))
                                                     (not (eq (car entry) (current-buffer)))))
                                              (window-prev-buffers))))
                   (switch-to-buffer (car entry)))))
  ("M-`" . other-window)
  ("C-<tab>" . completion-at-point)
  ("C-S-<tab>" . tab-next)
  ("C-S-<iso-lefttab>" . tab-next)

  ;; Commands: M-<key> for the common case, Shift for a second variant.
  ("M-z" . project-recompile)
  ("M-Z" . project-compile)
  ;; Async and terminal buffers are named after the project, like `project-shell':
  ;; *ol-async*, *ol-term*, numbered when several exist.
  ("M-a" . (lambda ()
             (interactive)
             (require 'project)
             (let ((shell-command-buffer-name-async (project-prefixed-buffer-name "async")))
               (call-interactively #'project-async-shell-command))))
  ("M-A" . (lambda ()
             (interactive)
             (require 'project)
             ;; At the project root, else in the buffer's folder; `ansi-term' adds the stars.
             (let ((default-directory (if-let* ((project (project-current)))
                                          (project-root project)
                                        default-directory)))
               (ansi-term (getenv "SHELL")
                          (string-trim (project-prefixed-buffer-name "term") "\\*" "\\*")))))
  ("M-f" . project-find-file)
  ("M-F" . project-dired)
  ("M-b" . project-switch-to-buffer)
  ("M-B" . ibuffer)
  ("M-q" . kill-current-buffer)
  ("M-Q" . tab-line-close-tab)
  ("M-'" . project-find-regexp)
  ("M-\"" . project-vc-dir)
  ("M-c" . whitespace-cleanup)
  ("M-o" . count-words)
  ("M-O" . toggle-frame-tab-bar)
  ("C-s" . save-buffer)
  ("C-f" . isearch-forward)
  ("C-S-f" . isearch-backward)
  ("C-c m" . (lambda () (interactive) (flymake-start t)))
  ("C-c C-m" . (lambda (directory)
                 (interactive (list (read-directory-name "Trust directory: " default-directory default-directory t)))
                 ;; Saved to `custom-file', so trust survives restarts.
                 (let ((trusted (abbreviate-file-name (file-name-as-directory (file-truename directory))))
                       (current (if (listp trusted-content) trusted-content nil)))
                   (customize-save-variable
                    'trusted-content
                    (if (member trusted current) current (cons trusted current))))
                 (when (fboundp 'my-env-refresh)
                   (my-env-refresh))
                 (message "Trusted content: %s" trusted-content)))

  :config
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (load custom-file 'noerror)
  (fset 'yes-or-no-p 'y-or-n-p)
  (prefer-coding-system 'utf-8)
  (set-language-environment "UTF-8")
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
  (frame-inhibit-implied-resize t)
  (use-dialog-box nil)
  (void-text-area-pointer 'arrow)
  (x-pointer-shape 'text)
  (x-sensitive-text-pointer-shape 'hand)
  (initial-scratch-message nil)
  (help-window-select t)
  (async-shell-command-buffer 'new-buffer)
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
               (`(t t) '(:inherit mode-line-inactive))
               (`(t nil) '(:inherit flymake-warning-echo :weight bold)) ; flymake-error-echo
               (`(nil t) '(:inherit mode-line-inactive))
               ('(:inherit mode-line :weight bold)))))
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

(use-package mwheel
  :ensure nil
  :custom
  (mouse-wheel-scroll-amount '(2))
  (mouse-wheel-progressive-speed t)
  (mouse-wheel-follow-mouse t))

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

(use-package mpc
  :ensure nil
  :custom
  (mpc-browser-tags '(Directory))
  (mpc-songs-format "   %{Duration} %{file}")
  (mpc-status-buffer-format '("%{Duration}-%{Time}" "%{file}")))

(defun my-tab-line-keep-order (tabs-function)
  "Make the tab order of TABS-FUNCTION survive desktop saves.
Around `tab-line-tabs-fixed-window-buffers', which keeps the order as
buffers that desktop cannot write: the order is mirrored as names and
restored from them.  Advice, since the tab move commands require that
function itself."
  (when-let* (((not (window-parameter nil 'tab-line-buffers)))
              (names (window-parameter nil 'my-tab-line-names)))
    (set-window-parameter nil 'tab-line-buffers (delq nil (mapcar #'get-buffer names))))
  (let ((buffers (funcall tabs-function)))
    (set-window-parameter nil 'my-tab-line-names (mapcar #'buffer-name buffers))
    buffers))

(use-package tab-line
  :ensure nil
  :functions tab-line-select-tab-buffer
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
  (add-to-list 'window-persistent-parameters '(my-tab-line-names . writable))
  (advice-add 'tab-line-tabs-fixed-window-buffers :around #'my-tab-line-keep-order)
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
  (diff-switches "-U1")
  (diff-refine-nonmodified nil)
  (diff-font-lock-prettify t))

(use-package vc-git
  :ensure nil
  ;; Helpers below are defined in :config, which compiles to a deferred body.
  :functions
  my-vc-git-collect-stats my-vc-git-numstat my-vc-git-commit-count
  my-vc-git-extra-stats my-vc-git-dir-stats
  vc-dir-fileinfo->name vc-dir-fileinfo->directory
  :defines vc-dir-filename-mouse-map
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
  (vc-dir-auto-hide-up-to-date t)
  (vc-display-failed-async-commands t))

(use-package ibuffer
  :ensure nil
  :functions ibuffer-get-marked-buffers
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

(defvar-local my-term-notification nil
  "ID of the terminal buffer's last desktop notification, replaced by its next one.")

(defun my-term-state-has-buffer-p (state buffer)
  "Non-nil if window STATE has BUFFER among a window's previous buffers.
Other tabs keep their windows as writable state, with buffer names."
  (cond ((and (consp state) (eq (car state) 'prev-buffers))
         (seq-some (lambda (entry)
                     (member (car-safe entry) (list buffer (buffer-name buffer))))
                   (cdr state)))
        ((consp state)
         (or (my-term-state-has-buffer-p (car state) buffer)
             (my-term-state-has-buffer-p (cdr state) buffer)))))

(defun my-term-show-in-tab-line (buffer)
  "Show BUFFER in the window whose tab line has it, selecting that window's tab.
`tab-bar-get-buffer-tab' only sees buffers displayed in other tabs, not the
ones behind another buffer of a window's tab line.  Return non-nil if found."
  (let ((window-with-buffer
         (lambda ()
           (seq-find (lambda (window) (assq buffer (window-prev-buffers window)))
                     (window-list)))))
    (unless (funcall window-with-buffer)
      (when-let* ((place
                   (seq-some
                    (lambda (frame)
                      (seq-some (lambda (tab)
                                  (and (not (eq (car tab) 'current-tab))
                                       (my-term-state-has-buffer-p (alist-get 'ws tab) buffer)
                                       (cons frame (seq-position (tab-bar-tabs frame) tab))))
                                (tab-bar-tabs frame)))
                    (frame-list))))
        (select-frame-set-input-focus (car place))
        (tab-bar-select-tab (1+ (cdr place)))))
    (when-let* ((window (funcall window-with-buffer)))
      (select-window window)
      (switch-to-buffer buffer nil t))))

(defun my-term-show (buffer)
  "Show BUFFER: select the tab displaying it or holding it in a tab line,
else show it in the selected window."
  (when (buffer-live-p buffer)
    (cond ((tab-bar-get-buffer-tab buffer t)
           ;; Overriding, since `display-buffer-alist' places terminals in the selected window.
           (let ((display-buffer-overriding-action '(display-buffer-in-tab (reusable-frames . t))))
             (pop-to-buffer buffer)))
          ((my-term-show-in-tab-line buffer))
          (t (pop-to-buffer-same-window buffer)))))

(defun my-term-notify (_code text)
  "Send TEXT, an OSC 777 `notify;TITLE;BODY' sequence, as a desktop notification.
Programs in the terminal notify without knowing where they run.  Nothing is
sent while the terminal is the selected buffer of the focused frame; a click
shows it.  Quickshell focuses the Emacs window by the desktop entry."
  (when (string-prefix-p "notify;" text)
    (let ((fields (split-string (substring text 7) ";"))
          (buffer (current-buffer)))
      (unless (and (eq (window-buffer (selected-window)) buffer)
                   (eq (frame-focus-state) t))
        (setq my-term-notification
              (notifications-notify
               :title (car fields)
               :body (string-join (cdr fields) ";")
               :app-name "Emacs"
               :desktop-entry "emacs"
               :replaces-id my-term-notification
               :actions '("default" "Show")
               :on-action (lambda (_id _action) (my-term-show buffer))))))))

(defun my-term-desktop-misc (_desktop-dirname)
  "Save the terminal's directory, so desktop reopens it there."
  default-directory)

;; Defined in term.el, which is not loaded when this file is compiled.
(defvar term-escape-char)
(declare-function term-ansi-make-term "term")
(declare-function term-char-mode "term")
(declare-function term-mode "term")
(declare-function term-set-escape-char "term")

(defun my-term-desktop-restore (_file name directory)
  "Reopen the saved terminal NAME as a new shell in DIRECTORY, as `ansi-term' does.
The same name lets restored windows and tabs find the buffer; programs and
scrollback are gone."
  (let ((default-directory (if (and (stringp directory) (file-directory-p directory))
                                directory
                              default-directory)))
    (with-current-buffer (term-ansi-make-term (generate-new-buffer-name name) (getenv "SHELL"))
      (term-mode)
      (term-char-mode)
      (let (term-escape-char)
        (term-set-escape-char ?\C-x))
      (current-buffer))))

(use-package notifications
  :ensure nil
  :commands notifications-notify)

(use-package term
  :ensure nil
  :functions term-send-raw-string term-paste
  :custom
  (term-buffer-maximum-size 2400)
  :hook
  (term-mode . (lambda ()
                 (setq-local font-lock-mode nil)
                 (setq-local bidi-display-reordering nil)
                 (setq-local bidi-paragraph-direction 'left-to-right)
                 (setq-local truncate-lines t)
                 (setq-local scroll-margin 0)
                 (setq-local scroll-conservatively 101)
                 (setq-local scroll-step 1)
                 (setq-local desktop-save-buffer #'my-term-desktop-misc)))
  :config
  (add-to-list 'desktop-buffer-mode-handlers '(term-mode . my-term-desktop-restore))
  (add-to-list 'term-osc-handlers '("777" . my-term-notify))
  (keymap-set term-raw-map "C-S-c" #'kill-ring-save)
  (keymap-set term-raw-map "C-S-v" #'term-paste)
  (keymap-set term-raw-map "<escape>" (lambda () (interactive) (term-send-raw-string "\e")))
  (keymap-set term-raw-map "<backtab>" (lambda () (interactive) (term-send-raw-string "\e[Z")))
  (keymap-set term-raw-map "S-<return>" (lambda () (interactive) (term-send-raw-string "\026\n")))
  ;; Global keys that also work inside terminals; the program there loses them.
  (dolist (key (append '("M-<tab>" "M-`" "M-z" "M-Z" "M-a" "M-A" "M-f" "M-F" "M-b" "M-B"
                         "M-q" "M-Q" "M-'" "M-\"")
                       (mapcar (lambda (number) (format "M-%d" number)) (number-sequence 0 9))))
    (keymap-set term-raw-map key (keymap-lookup global-map key))))

(use-package compile
  :ensure nil
  :custom
  (compilation-scroll-output 'first-error)
  (compile-command "nix run .#")
  ;; *ol-compilation*, like the async and terminal buffers.
  (project-compilation-buffer-name-function #'project-prefixed-buffer-name))

(use-package isearch
  :ensure nil
  :bind
  ;; Search is on C-f; repeating it steps through matches, as in other editors.
  (:map isearch-mode-map
        ("C-f" . isearch-repeat-forward)
        ("C-S-f" . isearch-repeat-backward)))

(use-package flymake
  :ensure nil
  :bind
  ;; Diagnostics of this buffer; M-<up/down> walk result lists, which skip them.
  (:map flymake-mode-map
        ("M-S-<up>" . flymake-goto-prev-error)
        ("M-S-<down>" . flymake-goto-next-error)))

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
  :functions ispell-set-spellchecker-params ispell-hunspell-add-multi-dic
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
  (prog-mode . my-whitespace-setup)
  (text-mode . my-whitespace-setup)
  :custom
  (whitespace-line-column 96)
  (whitespace-style
   '(face
     trailing
     empty
     tabs
     space-before-tab
     space-after-tab))
  :config
  (defun my-whitespace-setup ()
    "Enable whitespace checks, including line overflow only in Markdown."
    (when (derived-mode-p 'markdown-ts-mode)
      (setq-local whitespace-style (append whitespace-style '(lines-tail))))
    (whitespace-mode 1)))

(use-package prog-mode
  :ensure nil
  :hook
  (prog-mode . subword-mode)
  (prog-mode . flymake-mode)
  (prog-mode . electric-pair-local-mode)
  (prog-mode . display-line-numbers-mode))

(provide 'my-core)
;;; my-core.el ends here
