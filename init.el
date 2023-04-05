(require 'package)
(add-to-list 'package-archives
	     '("melpa-stable" . "https://stable.melpa.org/packages/")
	     t)
(package-initialize)

(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(use-package init-loader
  :ensure t
  :config
  (setq init-loader-show-log-after-init 'error-only)
  (init-loader-load "~/.emacs.d/inits"))

;; Language conofig
(set-locale-environment nil)
(set-language-environment "Japanese")
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(set-buffer-file-coding-system 'utf-8)
(setq default-buffer-file-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
(prefer-coding-system 'utf-8)

;; no startup messages
(setq inhibit-startup-message t)

;; no backup files
(setq make-backup-files nil)

(setq delete-auto-save-files t)

(setq-default tab-width 4 indent-tabs-mode nil)

(setq eol-mnemonic-dos "(CRLF)")
(setq eol-mnemonic-mac "(CR)")
(setq eol-mnemonic-unix "(LF)")

(setq ns-pop-up-frames nil)

(add-to-list 'default-frame-alist '(alpha . (0.85 0.85)))

(menu-bar-mode -1)
(tool-bar-mode -1)

(column-number-mode t)
(global-linum-mode t)
(blink-cursor-mode 0)
(global-hl-line-mode 0)
(show-paren-mode 1)
(global-whitespace-mode 0)
(setq scroll-conservatively 1)

(require 'dired-x)

(fset 'yes-or-no-p 'y-or-n-p)

(defun my-bell-function()
  (unless (memq this-command
		'(isearch-abort abort-recursive-edit exit-minibuffer
				keyboard-quit mwheel-scroll down up next-line previous-line
				backward-char forward-char))
    (ding)))

(setq ring-bell-function 'my-bell-function)

;; key bind
(global-set-key "\C-h" 'delete-backward-char)
(global-set-key "\C-c\C-h" 'help-command)
(global-set-key "\C-c;" 'comment-dwim)
(global-set-key "\C-t" 'other-window)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(julia-repl julia-mode init-loader use-package solarized-theme helm eglot company)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
