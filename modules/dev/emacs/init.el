;;; init.el --- Emacs config -*- lexical-binding: t; -*-

;;; Commentary:
;;; Code:

(require 'my-options (expand-file-name "my-options.el" user-emacs-directory))
(require 'my-core (expand-file-name "my-core.el" user-emacs-directory))
(require 'my-modes (expand-file-name "my-modes.el" user-emacs-directory))
(require 'my-env (expand-file-name "my-env.el" user-emacs-directory))
(require 'my-agent (expand-file-name "my-agent.el" user-emacs-directory))
(require 'my-net (expand-file-name "my-net.el" user-emacs-directory))
(load-theme 'my t)

;;; init.el ends here
