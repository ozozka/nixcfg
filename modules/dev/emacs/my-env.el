;;; my-env.el --- Load Nix development shells into buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Buffers below a trusted directory containing flake.nix get that flake's
;; development shell environment, evaluated with `nix print-dev-env --json'
;; and cached until flake.nix or flake.lock change, or garbage collection
;; removes the shell.  Loading is synchronous so mode hooks such as
;; `eglot-ensure' see the project's tools; Nix output streams into the
;; *my-env* buffer meanwhile.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'my-options)

(defgroup my-env nil
  "Buffer-local Nix development shell environments."
  :group 'environment)

(defcustom my-env-cache-directory
  (expand-file-name "my-env" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory holding cached environments."
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
  "Return the nearest directory containing flake.nix, or nil."
  (when (and (stringp default-directory)
             (not (file-remote-p default-directory)))
    (when-let* ((directory (locate-dominating-file default-directory "flake.nix")))
      (file-name-as-directory (file-truename directory)))))

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
  "Return a hash of DIRECTORY's flake.nix and flake.lock."
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
    '("flake.nix" "flake.lock")
    "\0")))

;;; Evaluation

(defconst my-env-log-buffer "*my-env*"
  "Buffer collecting Nix output from every evaluation.")

(defun my-env--log (_process string)
  "Append Nix STRING to the log and show its latest line."
  (with-current-buffer (get-buffer-create my-env-log-buffer)
    (goto-char (point-max))
    (insert string))
  (when-let* ((line (car (last (split-string string "[\r\n]+" t "[ \t]+")))))
    (message "Nix: %s" (truncate-string-to-width line (max 20 (- (frame-width) 6))))))

(defun my-env--run (environment directory &rest arguments)
  "Run Nix with ENVIRONMENT in DIRECTORY and ARGUMENTS, and wait for it.
Standard error streams into `my-env-log-buffer' while Emacs keeps
redisplaying; \\[keyboard-quit] stops Nix.  Return the exit status and
standard output."
  (let ((output (generate-new-buffer " *my-env-output*"))
        (process-environment (copy-sequence environment))
        (default-directory (file-name-as-directory directory))
        (stderr nil)
        (process nil))
    (my-env--log nil (format "\n== %s %s\n" (format-time-string "%F %T") directory))
    (unwind-protect
        (progn
          (setq stderr (make-pipe-process :name "my-env-stderr" :noquery t
                                          :coding 'utf-8-unix :filter #'my-env--log)
                process (make-process :name "my-env-nix" :buffer output :noquery t
                                      :command (cons my-nix-program arguments)
                                      :connection-type 'pipe :coding 'utf-8-unix
                                      :stderr stderr :sentinel #'ignore))
          ;; Returns nil once Nix has exited and its output is drained.
          (while (accept-process-output process))
          (while (accept-process-output stderr 0))
          (list (process-exit-status process)
                (with-current-buffer output (buffer-string))))
      (when (process-live-p process)
        (delete-process process)
        (my-env--log nil "cancelled\n"))
      (when stderr
        (delete-process stderr))
      (kill-buffer output))))

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
  "Evaluate DIRECTORY's development shell and return its variables."
  (let ((name (abbreviate-file-name directory)))
    (message "Loading Nix environment for %s..." name)
    (pcase-let ((`(,status ,output)
                 (my-env--run (or my-env--base-process-environment process-environment)
                              directory
                              "print-dev-env" "--json" (concat directory "#"))))
      (unless (eql status 0)
        (error "nix print-dev-env failed with exit status %s; see %s"
               status my-env-log-buffer))
      (prog1 (my-env--parse output)
        (message "Loading Nix environment for %s...done" name)))))

;;; Cache

(defun my-env--cache-file (directory)
  "Return the cache file for project DIRECTORY."
  (expand-file-name (concat (secure-hash 'sha256 directory) ".json")
                    my-env-cache-directory))

(defun my-env--read-cache (file fingerprint)
  "Return the variables cached in FILE for FINGERPRINT, or nil."
  (when (file-exists-p file)
    (condition-case nil
        (let ((json (json-parse-string
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))
                     :object-type 'alist)))
          (when (equal (alist-get 'fingerprint json) fingerprint)
            (mapcar (lambda (entry) (cons (symbol-name (car entry)) (cdr entry)))
                    (alist-get 'variables json))))
      ;; A corrupt cache is just a miss.
      (error nil))))

(defun my-env--write-cache (file fingerprint variables)
  "Store VARIABLES for FINGERPRINT in FILE, replacing it atomically."
  (make-directory (file-name-directory file) t)
  (let ((temporary (make-temp-file (expand-file-name "tmp-" (file-name-directory file)))))
    (with-temp-file temporary
      (insert (json-serialize
               `((fingerprint . ,fingerprint)
                 (variables . ,(mapcar (lambda (entry)
                                         (cons (intern (car entry)) (cdr entry)))
                                       variables))))))
    (rename-file temporary file t)))

(defun my-env--available-p (variables)
  "Return non-nil when the store paths on VARIABLES' PATH still exist.
Without a garbage collection root, `nix-collect-garbage' may delete them."
  (seq-every-p (lambda (entry)
                 (or (not (string-prefix-p "/nix/store/" entry))
                     (file-directory-p entry)))
               (split-string (or (cdr (assoc "PATH" variables)) "") ":" t)))

(defun my-env--environment (directory)
  "Return DIRECTORY's variables, evaluating its shell only when needed."
  (let* ((fingerprint (my-env--fingerprint directory))
         (file (my-env--cache-file directory))
         (loaded (gethash directory my-env--environments))
         (variables (if (and loaded (equal (car loaded) fingerprint))
                        (cdr loaded)
                      (my-env--read-cache file fingerprint))))
    (unless (and variables (my-env--available-p variables))
      (setq variables (my-env--evaluate directory))
      (my-env--write-cache file fingerprint variables))
    (puthash directory (cons fingerprint variables) my-env--environments)
    variables))

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
      (user-error "No flake.nix found for this buffer"))
    ;; Forget both caches; the next load evaluates once for all buffers.
    (remhash directory my-env--environments)
    (let ((file (my-env--cache-file directory)))
      (when (file-exists-p file)
        (delete-file file)))
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
