;;; my-env.el --- Load Nix development shells into buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Buffers below a trusted directory containing flake.nix or shell.nix get that
;; project's development shell environment, evaluated with
;; `nix print-dev-env --json' and cached until flake.nix, flake.lock or
;; shell.nix change.  Loading is synchronous so mode hooks such as
;; `eglot-ensure' see the project's tools.  Cached environments are kept alive
;; across garbage collection by a Nix profile, like nix-direnv.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'my-options)

(defgroup my-env nil
  "Buffer-local Nix development shell environments."
  :group 'environment)

(defcustom my-env-cache-directory
  (expand-file-name "my-env" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory holding cached environments and their Nix profiles."
  :type 'directory
  :group 'my-env)

(defconst my-env-ignored-variables
  '("BASHOPTS" "HOME" "NIX_BUILD_TOP" "NIX_ENFORCE_PURITY" "NIX_LOG_FD"
    "NIX_REMOTE" "PPID" "SHELL" "SHELLOPTS" "SSL_CERT_FILE" "TEMP" "TEMPDIR"
    "TERM" "TMP" "TMPDIR" "TZ" "UID")
  "Build sandbox variables that never leave the shell, as in `nix develop'.
SHELL is also kept: the build shell lacks readline, which terminals need.")

(defconst my-env-prepended-variables '("PATH" "XDG_DATA_DIRS")
  "Variables whose shell values are prepended to the existing value.")

(defvar my-env-mode)

(defvar my-env--environments (make-hash-table :test #'equal)
  "Loaded environments: project directory to (FINGERPRINT . VARIABLES).")

(defvar-local my-env-status 'inactive "Current environment state for this buffer.")
(defvar-local my-env--base-process-environment nil)
(defvar-local my-env--base-exec-path nil)
(defvar-local my-env--process-environment-was-local nil)
(defvar-local my-env--exec-path-was-local nil)
(defvar-local my-env--base-captured-p nil)
(defvar-local my-env--directory nil)
(defvar-local my-env--disabled nil)

(put 'my-env--disabled 'permanent-local t)

(defun my-env--set-status (status)
  "Set the current buffer environment STATUS."
  (setq my-env-status status)
  (force-mode-line-update))

(defun my-env--lighter ()
  "Return the mode-line indicator for `my-env-mode'."
  (pcase my-env-status
    ('loading " Env...")
    ('ready " Env")
    ('error " Env!")
    ('untrusted " Env?")
    (_ " Env")))

;;; Projects

(defun my-env--project ()
  "Return the nearest project directory for the current buffer, or nil.
A project directory contains flake.nix or shell.nix."
  (when (and (stringp default-directory)
             (not (file-remote-p default-directory)))
    (when-let* ((directory
                 (locate-dominating-file
                  default-directory
                  (lambda (directory)
                    (or (file-exists-p (expand-file-name "flake.nix" directory))
                        (file-exists-p (expand-file-name "shell.nix" directory)))))))
      (file-name-as-directory (file-truename directory)))))

(defun my-env--flake-p (directory)
  "Return non-nil when DIRECTORY uses flake.nix rather than shell.nix."
  (file-exists-p (expand-file-name "flake.nix" directory)))

(defun my-env--trusted-p (directory)
  "Return non-nil when `trusted-content' covers DIRECTORY.
Like `trusted-content-p', only entries ending in a slash trust a tree."
  (or (eq trusted-content :all)
      (and (listp trusted-content)
           (seq-some
            (lambda (entry)
              (and (stringp entry)
                   (string-suffix-p "/" entry)
                   (string-prefix-p (expand-file-name entry) directory)))
            trusted-content))))

(defun my-env--fingerprint (directory)
  "Return a hash of the files that define DIRECTORY's shell."
  (secure-hash
   'sha256
   (mapconcat
    (lambda (name)
      (let ((file (expand-file-name name directory)))
        (concat name "\0"
                (if (file-exists-p file)
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally file)
                      (secure-hash 'sha256 (current-buffer)))
                  "missing"))))
    (if (my-env--flake-p directory)
        '("flake.nix" "flake.lock")
      '("shell.nix"))
    "\0")))

(defun my-env--cache (directory)
  "Return the cache directory for project DIRECTORY."
  (expand-file-name (secure-hash 'sha256 directory) my-env-cache-directory))

;;; Evaluation

(defun my-env--run (environment directory &rest arguments)
  "Run Nix with ENVIRONMENT in DIRECTORY and ARGUMENTS.
Return a list of the exit status, standard output, and standard error."
  (let ((output-buffer (generate-new-buffer " *my-env-output*"))
        (error-file (make-temp-file "my-env-error-"))
        (process-environment (copy-sequence environment))
        (default-directory (file-name-as-directory directory))
        (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (let ((status
               (apply #'process-file my-nix-program nil
                      (list output-buffer error-file) nil arguments)))
          (list status
                (with-current-buffer output-buffer (buffer-string))
                (with-temp-buffer
                  (insert-file-contents error-file)
                  (buffer-string))))
      (kill-buffer output-buffer)
      (delete-file error-file))))

(defun my-env--error-message (status error-output)
  "Return a concise Nix error for STATUS and ERROR-OUTPUT."
  (let ((detail (string-trim
                 (replace-regexp-in-string "[\r\n]+" " " error-output))))
    (truncate-string-to-width
     (if (string-empty-p detail)
         (format "nix print-dev-env exited with status %s" status)
       (format "nix print-dev-env exited with status %s: %s" status detail))
     500 nil nil "...")))

(defun my-env--parse (output)
  "Return the exported variables in `nix print-dev-env --json' OUTPUT.
The result is an alist of names and string values, without the
variables in `my-env-ignored-variables'."
  (let* ((json (json-parse-string output :object-type 'alist :array-type 'list))
         (variables (alist-get 'variables json))
         (result nil))
    (unless (and (consp json) (listp variables))
      (error "nix print-dev-env returned no variables"))
    (dolist (entry variables)
      (let ((name (symbol-name (car entry)))
            (type (alist-get 'type (cdr entry)))
            (value (alist-get 'value (cdr entry))))
        (when (and (equal type "exported")
                   (stringp value)
                   (not (member name my-env-ignored-variables)))
          (when (or (string-empty-p name) (string-match-p "[=\0]" name))
            (error "nix print-dev-env returned an invalid name %S" name))
          (push (cons name value) result))))
    (nreverse result)))

(defun my-env--evaluate (directory)
  "Evaluate DIRECTORY's shell with Nix and cache the JSON output.
The Nix profile in the cache keeps the shell from garbage collection."
  (let* ((cache (my-env--cache directory))
         (profile (expand-file-name "profile" cache))
         (arguments
          (if (my-env--flake-p directory)
              (list "print-dev-env" "--json" "--profile" profile
                    (concat directory "#"))
            (list "print-dev-env" "--json" "--profile" profile
                  "--file" (expand-file-name "shell.nix" directory)))))
    (make-directory cache t)
    (message "Loading Nix environment for %s..." (abbreviate-file-name directory))
    (pcase-let ((`(,status ,output ,error-output)
                 (apply #'my-env--run
                        (or my-env--base-process-environment process-environment)
                        directory arguments)))
      (unless (and (integerp status) (zerop status))
        (error "%s" (my-env--error-message status error-output)))
      ;; Validate before caching, so a malformed result is never reused.
      (my-env--parse output)
      ;; Each evaluation adds a profile generation; keep only the current one
      ;; so older shells can be garbage collected.
      (let ((current (file-symlink-p profile)))
        (dolist (link (directory-files cache t "\\`profile-[0-9]+-link\\'"))
          (unless (equal (file-name-nondirectory link) current)
            (delete-file link))))
      (with-temp-file (expand-file-name "environment.json" cache)
        (insert output))
      (message "Loading Nix environment for %s...done"
               (abbreviate-file-name directory))
      output)))

(defun my-env--environment (directory)
  "Return DIRECTORY's variables, evaluating its shell only when needed."
  (let* ((fingerprint (my-env--fingerprint directory))
         (loaded (gethash directory my-env--environments))
         (cache (my-env--cache directory))
         (json-file (expand-file-name "environment.json" cache))
         (fingerprint-file (expand-file-name "fingerprint" cache)))
    (if (and loaded (equal (car loaded) fingerprint))
        (cdr loaded)
      (let ((variables
             (if (and (file-exists-p json-file)
                      (file-exists-p fingerprint-file)
                      (equal fingerprint
                             (with-temp-buffer
                               (insert-file-contents fingerprint-file)
                               (buffer-string))))
                 (my-env--parse
                  (with-temp-buffer
                    (insert-file-contents json-file)
                    (buffer-string)))
               (prog1 (my-env--parse (my-env--evaluate directory))
                 ;; Written last: a fingerprint only ever describes a
                 ;; complete, valid environment.json.
                 (with-temp-file fingerprint-file
                   (insert fingerprint))))))
        (puthash directory (cons fingerprint variables) my-env--environments)
        variables))))

;;; Buffer environments

(defun my-env--apply (variables)
  "Apply VARIABLES on top of the current buffer's saved baseline."
  ;; Build the value inside `let' but set it outside: when the buffer already
  ;; has a local value, `let' binds that one and would restore it on exit.
  (let ((candidate
         (let ((process-environment
                (copy-sequence my-env--base-process-environment)))
           (pcase-dolist (`(,name . ,value) variables)
             (let ((current (getenv name)))
               (setenv name
                       (if (and (member name my-env-prepended-variables)
                                current (not (string-empty-p current)))
                           (concat value path-separator current)
                         value))))
           process-environment)))
    (setq-local process-environment candidate)
    (setq-local exec-path
                (append (parse-colon-path (or (getenv "PATH") ""))
                        (list exec-directory)))))

(defun my-env--install-baseline ()
  "Install independent copies of the saved baseline in this buffer."
  (setq-local process-environment (copy-sequence my-env--base-process-environment))
  (setq-local exec-path (copy-sequence my-env--base-exec-path)))

(defun my-env--capture-baseline ()
  "Save the current buffer's environment and variable locality."
  (unless my-env--base-captured-p
    (setq my-env--process-environment-was-local
          (local-variable-p 'process-environment)
          my-env--exec-path-was-local (local-variable-p 'exec-path)
          my-env--base-process-environment (copy-sequence process-environment)
          my-env--base-exec-path (copy-sequence exec-path)
          my-env--base-captured-p t)))

(defun my-env--restore-baseline ()
  "Restore the environment that preceded `my-env-mode'."
  (when my-env--base-captured-p
    (if my-env--process-environment-was-local
        (setq-local process-environment
                    (copy-sequence my-env--base-process-environment))
      (kill-local-variable 'process-environment))
    (if my-env--exec-path-was-local
        (setq-local exec-path (copy-sequence my-env--base-exec-path))
      (kill-local-variable 'exec-path)))
  (setq my-env--base-process-environment nil
        my-env--base-exec-path nil
        my-env--process-environment-was-local nil
        my-env--exec-path-was-local nil
        my-env--base-captured-p nil
        my-env--directory nil)
  (my-env--set-status 'inactive))

(defun my-env--load ()
  "Load the nearest project environment into the current buffer."
  (let ((directory (my-env--project)))
    (setq my-env--directory directory)
    (cond
     ((not directory)
      (my-env--restore-baseline)
      (setq my-env-mode nil))
     ((not (my-env--trusted-p directory))
      ;; Evaluating a flake runs the project's Nix code: trust it first.
      (my-env--install-baseline)
      (my-env--set-status 'untrusted))
     (t
      (my-env--set-status 'loading)
      (condition-case error-data
          (progn
            (my-env--apply (my-env--environment directory))
            (my-env--set-status 'ready))
        (error
         (my-env--install-baseline)
         (my-env--set-status 'error)
         (display-warning 'my-env (error-message-string error-data) :warning))
        (quit
         (my-env--install-baseline)
         (my-env--set-status 'error)
         (signal (car error-data) (cdr error-data))))))))

(define-minor-mode my-env-mode
  "Use the nearest Nix development shell in the current buffer."
  :init-value nil
  :lighter (:eval (my-env--lighter))
  :group 'my-env
  (if my-env-mode
      (progn
        (setq my-env--disabled nil)
        (my-env--capture-baseline)
        (my-env--load))
    (my-env--restore-baseline)))

;;; Commands

(defun my-env-disable ()
  "Disable automatic environment loading in the current buffer."
  (interactive)
  (when my-env-mode
    (my-env-mode -1))
  (setq my-env--disabled t))

(defun my-env-reload ()
  "Evaluate this buffer's project shell again and apply it to its buffers."
  (interactive)
  (let ((directory (my-env--project)))
    (unless directory
      (user-error "No flake.nix or shell.nix found for this buffer"))
    ;; Forget both caches; the next load evaluates once for all buffers.
    (remhash directory my-env--environments)
    (let ((fingerprint (expand-file-name "fingerprint" (my-env--cache directory))))
      (when (file-exists-p fingerprint)
        (delete-file fingerprint)))
    (if my-env-mode
        (my-env--load)
      (my-env-mode 1))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and my-env-mode (equal my-env--directory directory))
          (my-env--load))))))

(defun my-env-refresh ()
  "Apply current trust and cached environments to all eligible buffers."
  (interactive)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (if my-env-mode
          (my-env--load)
        (my-env--maybe-enable)))))

;;; Automatic loading

(defun my-env--eligible-buffer-p ()
  "Return non-nil when the current buffer should load an environment."
  (and (not (minibufferp))
       (stringp default-directory)
       (not (file-remote-p default-directory))
       (or buffer-file-name
           (derived-mode-p 'dired-mode))))

(defun my-env--maybe-enable ()
  "Enable or update `my-env-mode' when appropriate."
  (when (my-env--eligible-buffer-p)
    (let ((directory (my-env--project)))
      (cond
       ((and my-env-mode (not (equal directory my-env--directory)))
        (my-env--load))
       ((and directory (not my-env-mode) (not my-env--disabled))
        (my-env-mode 1))))))

(define-minor-mode my-env-global-mode
  "Automatically load Nix shells in local file and Dired buffers."
  :global t
  :group 'my-env
  (if my-env-global-mode
      (progn
        ;; This hook runs before mode-specific hooks such as
        ;; `eglot-ensure', keeping environment loading synchronous and ordered.
        (add-hook 'change-major-mode-after-body-hook #'my-env--maybe-enable -100)
        (add-hook 'dired-after-readin-hook #'my-env--maybe-enable -100)
        (add-hook 'after-set-visited-file-name-hook #'my-env--maybe-enable -100)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (my-env--maybe-enable))))
    (remove-hook 'change-major-mode-after-body-hook #'my-env--maybe-enable)
    (remove-hook 'dired-after-readin-hook #'my-env--maybe-enable)
    (remove-hook 'after-set-visited-file-name-hook #'my-env--maybe-enable)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when my-env-mode
          (my-env-mode -1))))))

(my-env-global-mode 1)

(provide 'my-env)
;;; my-env.el ends here
