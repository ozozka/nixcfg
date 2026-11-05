;;; test-env.el --- my-env checks with a fake nix -*- lexical-binding: t; -*-

;;; Commentary:
;; Run by the emacs-config-check in default.nix after test-config.el.
;; A fake nix records its arguments and prints a canned environment.

;;; Code:

(require 'ert)
(require 'my-env)

(defconst my-env-test--json
  (json-serialize
   '((variables
      . ((PATH . ((type . "exported") (value . "/shell/bin")))
         (XDG_DATA_DIRS . ((type . "exported") (value . "/shell/share")))
         (HOME . ((type . "exported") (value . "/homeless-shelter")))
         (TMPDIR . ((type . "exported") (value . "/shell-tmp")))
         (SHELL . ((type . "exported") (value . "/nix/store/bash/bin/bash")))
         (MY_VAR . ((type . "exported") (value . "yes")))
         (LOCAL . ((type . "var") (value . "no")))
         (list . ((type . "array") (value . ["a" "b"])))))
     (bashFunctions . ())))
  "Canned `nix print-dev-env --json' output.")

(defmacro my-env-test--with-sandbox (&rest body)
  "Run BODY with a fake nix, a fresh cache, and a temporary root `root'."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "my-env-" t))))
          (log (expand-file-name "nix.log" root))
          (json (expand-file-name "env.json" root))
          (my-nix-program (expand-file-name "nix" root))
          (my-env-cache-directory (expand-file-name "cache" root))
          (trusted-content (list (concat root "trusted/")))
          (my-env--environments (make-hash-table :test #'equal))
          (process-environment
           (append '("PATH=/usr/bin" "XDG_DATA_DIRS=/usr/share" "HOME=/home/test")
                   process-environment)))
     (with-temp-file json (insert my-env-test--json))
     (with-temp-file my-nix-program
       (insert "#!" (executable-find "sh") "\n"
               "echo \"$@\" >> " (shell-quote-argument log) "\n"
               (executable-find "cat") " " (shell-quote-argument json) "\n"))
     (set-file-modes my-nix-program #o755)
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
      (let ((calls (my-env-test--calls log)))
        (should (= (length calls) 1))
        (should (string-match-p "^print-dev-env --json --profile .*/profile .*/project/#$"
                                (car calls)))))))

(ert-deftest my-env-shell-nix-and-nearest-project ()
  (my-env-test--with-sandbox
    (let* ((outer (my-env-test--project (concat root "trusted/outer/") "flake.nix"))
           (inner (my-env-test--project (concat outer "inner/") "shell.nix")))
      (my-env-test--visit (concat inner "a.txt"))
      (should (string-match-p "--file .*/inner/shell\\.nix$"
                              (car (my-env-test--calls log))))
      ;; flake.nix wins over shell.nix in the same directory.
      (my-env-test--project inner "flake.nix")
      (my-env-test--visit (concat inner "b.txt"))
      (should (string-match-p "/inner/#$" (cadr (my-env-test--calls log)))))))

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
