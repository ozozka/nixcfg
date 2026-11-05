;;; test-env.el --- my-env checks with a fake nix -*- lexical-binding: t; -*-

;;; Commentary:
;; Run by the emacs-config-check in default.nix after test-config.el.
;; A fake nix records its arguments, writes to standard error, and prints a
;; canned environment.

;;; Code:

(require 'ert)
(require 'my-env)

(defun my-env-test--json (path)
  "Return canned `nix print-dev-env --json' output with PATH."
  (json-serialize
   `((variables
      . ((PATH . ((type . "exported") (value . ,path)))
         (XDG_DATA_DIRS . ((type . "exported") (value . "/shell/share")))
         (HOME . ((type . "exported") (value . "/homeless-shelter")))
         (TMPDIR . ((type . "exported") (value . "/shell-tmp")))
         (SHELL . ((type . "exported") (value . "/nix/store/bash/bin/bash")))
         (MY_VAR . ((type . "exported") (value . "yes")))
         (LOCAL . ((type . "var") (value . "no")))
         (list . ((type . "array") (value . ["a" "b"])))))
     (bashFunctions . ()))))

(defvar my-env-test--root nil "Temporary root of the current test.")

(defun my-env-test--fake (&rest options)
  "Write the fake nix with OPTIONS.
:path is the shell PATH, :exit the exit status, :stderr extra
standard error text, :sleep seconds to wait before answering."
  (let ((json (expand-file-name "env.json" my-env-test--root))
        (log (expand-file-name "nix.log" my-env-test--root)))
    (with-temp-file json
      (insert (my-env-test--json (or (plist-get options :path) "/shell/bin"))))
    (with-temp-file my-nix-program
      (insert "#!" (executable-find "sh") "\n"
              "echo \"$@\" >> " (shell-quote-argument log) "\n"
              "echo 'evaluating flake...' >&2\n"
              (format "printf %%s %s >&2\n"
                      (shell-quote-argument (or (plist-get options :stderr) "")))
              (if (plist-get options :sleep)
                  (format "%s %d\n" (executable-find "sleep") (plist-get options :sleep))
                "")
              (executable-find "cat") " " (shell-quote-argument json) "\n"
              (format "exit %d\n" (or (plist-get options :exit) 0))))
    (set-file-modes my-nix-program #o755)))

(defmacro my-env-test--with-sandbox (&rest body)
  "Run BODY with a fake nix, a fresh cache, and a temporary root `root'."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "my-env-" t))))
          (my-env-test--root root)
          (log (expand-file-name "nix.log" root))
          (my-nix-program (expand-file-name "nix" root))
          (my-env-cache-directory (expand-file-name "cache" root))
          (trusted-content (list (concat root "trusted/")))
          (my-env--environments (make-hash-table :test #'equal))
          (process-environment
           (append '("PATH=/usr/bin" "XDG_DATA_DIRS=/usr/share" "HOME=/home/test")
                   process-environment)))
     (ignore log)
     (my-env-test--fake)
     (when (get-buffer my-env-log-buffer)
       (kill-buffer my-env-log-buffer))
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (string-prefix-p root (or (buffer-file-name buffer) ""))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun my-env-test--project (directory &rest files)
  "Create DIRECTORY with FILES (names) and return it."
  (make-directory directory t)
  (dolist (file files)
    (with-temp-file (expand-file-name file directory)
      (insert "{}\n")))
  directory)

(defun my-env-test--calls (log)
  "Return the recorded nix invocations in LOG."
  (if (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log)
        (split-string (buffer-string) "\n" t))
    nil))

(defun my-env-test--visit (file)
  "Visit FILE and return its buffer."
  (with-temp-file file (insert "text\n"))
  (find-file-noselect file))

(ert-deftest my-env-loads-trusted-flake ()
  (my-env-test--with-sandbox
    (let* ((project (my-env-test--project (concat root "trusted/project/") "flake.nix"))
           (buffer (my-env-test--visit (concat project "a.txt"))))
      (with-current-buffer buffer
        (should (eq my-env-status 'ready))
        (should (equal (getenv "MY_VAR") "yes"))
        ;; Shell paths come first; the existing value is kept.
        (should (equal (getenv "PATH") "/shell/bin:/usr/bin"))
        (should (equal (getenv "XDG_DATA_DIRS") "/shell/share:/usr/share"))
        (should (equal (car exec-path) "/shell/bin/"))
        ;; Sandbox variables and non-exported variables never leak.
        (should (equal (getenv "HOME") "/home/test"))
        (should-not (equal (getenv "TMPDIR") "/shell-tmp"))
        (should-not (equal (getenv "SHELL") "/nix/store/bash/bin/bash"))
        (should-not (getenv "LOCAL")))
      (should (equal (my-env-test--calls log)
                     (list (concat "print-dev-env --json " project "#"))))
      ;; Standard error went to the log, not into the JSON.
      (with-current-buffer my-env-log-buffer
        (should (string-match-p "evaluating flake\\.\\.\\." (buffer-string)))))))

(ert-deftest my-env-nearest-flake ()
  (my-env-test--with-sandbox
    (let* ((outer (my-env-test--project (concat root "trusted/outer/") "flake.nix"))
           (inner (my-env-test--project (concat outer "inner/") "flake.nix")))
      (my-env-test--visit (concat inner "a.txt"))
      (my-env-test--visit (concat outer "b.txt"))
      (should (equal (my-env-test--calls log)
                     (list (concat "print-dev-env --json " inner "#")
                           (concat "print-dev-env --json " outer "#"))))
      ;; Without flake.nix, nothing loads.
      (let ((plain (my-env-test--project (concat root "trusted/plain/") "shell.nix")))
        (with-current-buffer (my-env-test--visit (concat plain "c.txt"))
          (should-not my-env-mode)))
      (should (= (length (my-env-test--calls log)) 2)))))

(ert-deftest my-env-cache ()
  (my-env-test--with-sandbox
    (let ((project (my-env-test--project (concat root "trusted/project/")
                                         "flake.nix" "flake.lock")))
      (my-env-test--visit (concat project "a.txt"))
      (my-env-test--visit (concat project "b.txt"))
      (should (= (length (my-env-test--calls log)) 1))
      ;; The disk cache survives a fresh Emacs (empty memory cache).
      (clrhash my-env--environments)
      (with-current-buffer (my-env-test--visit (concat project "c.txt"))
        (should (equal (getenv "MY_VAR") "yes")))
      (should (= (length (my-env-test--calls log)) 1))
      ;; Changing flake.lock invalidates it.
      (with-temp-file (concat project "flake.lock") (insert "{\"changed\": true}\n"))
      (my-env-test--visit (concat project "d.txt"))
      (should (= (length (my-env-test--calls log)) 2))
      ;; An explicit reload evaluates again, once.
      (with-current-buffer (find-file-noselect (concat project "a.txt"))
        (my-env-reload))
      (should (= (length (my-env-test--calls log)) 3)))))

(ert-deftest my-env-collected-store-paths ()
  (my-env-test--with-sandbox
    (let ((project (my-env-test--project (concat root "trusted/project/") "flake.nix"))
          ;; A real store directory, as found on this system.
          (present (directory-file-name
                    (file-name-directory (file-truename (executable-find "sh"))))))
      ;; Present store paths: the cache is reused.
      (my-env-test--fake :path present)
      (my-env-test--visit (concat project "a.txt"))
      (my-env-test--visit (concat project "b.txt"))
      (should (= (length (my-env-test--calls log)) 1))
      ;; Simulate garbage collection: the cached shell's store path is gone.
      (clrhash my-env--environments)
      (my-env--write-cache
       (my-env--cache-file project) (my-env--fingerprint project)
       '(("PATH" . "/nix/store/00000000000000000000000000000000-gone/bin")))
      ;; The next load evaluates once (Nix restores the paths); later loads reuse it.
      (with-current-buffer (my-env-test--visit (concat project "c.txt"))
        (should (equal (getenv "MY_VAR") "yes")))
      (should (= (length (my-env-test--calls log)) 2))
      (my-env-test--visit (concat project "d.txt"))
      (should (= (length (my-env-test--calls log)) 2)))))

(ert-deftest my-env-failure-keeps-full-log ()
  (my-env-test--with-sandbox
    (let* ((project (my-env-test--project (concat root "trusted/project/") "flake.nix"))
           (detail (concat "error: " (make-string 600 ?x) " end-of-error\n")))
      (my-env-test--fake :exit 1 :stderr detail)
      (with-current-buffer (my-env-test--visit (concat project "a.txt"))
        (should (eq my-env-status 'error))
        (should-not (getenv "MY_VAR")))
      ;; The whole error is kept, beyond any warning length.
      (with-current-buffer my-env-log-buffer
        (should (string-match-p "end-of-error" (buffer-string))))
      (with-current-buffer "*Warnings*"
        (should (string-match-p "exit status 1; see \\*my-env\\*" (buffer-string))))
      ;; A failed evaluation is not cached.
      (should-not (file-exists-p (my-env--cache-file project))))))

(ert-deftest my-env-interrupted-evaluation ()
  ;; Leaving the wait early (as \\[keyboard-quit] does) kills Nix.
  (my-env-test--with-sandbox
    (let ((project (my-env-test--project (concat root "trusted/project/") "flake.nix")))
      (my-env-test--fake :sleep 30)
      (should (eq (with-timeout (0.5 'interrupted)
                    (my-env-test--visit (concat project "a.txt")))
                  'interrupted))
      (should-not (seq-some (lambda (process)
                              (string-prefix-p "my-env" (process-name process)))
                            (process-list)))
      (with-current-buffer my-env-log-buffer
        (should (string-match-p "cancelled" (buffer-string))))
      (should-not (file-exists-p (my-env--cache-file project))))))

(ert-deftest my-env-untrusted ()
  (my-env-test--with-sandbox
    (let* ((project (my-env-test--project (concat root "other/") "flake.nix"))
           (buffer (my-env-test--visit (concat project "a.txt"))))
      (with-current-buffer buffer
        (should (eq my-env-status 'untrusted))
        (should-not (getenv "MY_VAR")))
      (should-not (my-env-test--calls log))
      ;; Trusting the directory and refreshing loads it.
      (push (concat root "other/") trusted-content)
      (my-env-refresh)
      (with-current-buffer buffer
        (should (eq my-env-status 'ready))
        (should (equal (getenv "MY_VAR") "yes"))))))

(ert-deftest my-env-disable-restores ()
  (my-env-test--with-sandbox
    (let* ((project (my-env-test--project (concat root "trusted/project/") "flake.nix"))
           (buffer (my-env-test--visit (concat project "a.txt"))))
      (with-current-buffer buffer
        (should (local-variable-p 'process-environment))
        (my-env-disable)
        (should-not (local-variable-p 'process-environment))
        (should-not (local-variable-p 'exec-path))
        (should-not (getenv "MY_VAR"))))))

;;; test-env.el ends here
