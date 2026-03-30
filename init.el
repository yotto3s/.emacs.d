;;; init.el --- Minimal Emacs configuration -*- lexical-binding: t -*-

;;; Packages

(require 'package)
(setq package-archives
      '(("melpa" . "https://melpa.org/packages/")
        ("gnu"   . "https://elpa.gnu.org/packages/")))
(package-initialize)
(unless package-archive-contents (package-refresh-contents))
(require 'use-package)
(setq use-package-always-ensure t)

;;; Defaults

(setq inhibit-startup-message t
      ring-bell-function 'ignore
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      truncate-lines t
      custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file) (load custom-file))
(setq-default indent-tabs-mode nil tab-width 4)
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(column-number-mode 1)
(show-paren-mode 1)
(global-hl-line-mode 1)
(delete-selection-mode 1)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)

;;; Theme

(use-package modus-themes
  :config
  (setq modus-themes-mode-line '(accented borderless)
        modus-themes-region '(bg-only)
        modus-themes-org-blocks 'tinted-background)
  (load-theme 'modus-operandi t))

;;; Completion (buffer)

(use-package dabbrev
  :ensure nil
  :custom (dabbrev-ignored-buffer-regexps '("\\.\\(?:pdf\\|jpe?g\\|png\\)\\'")))

(use-package corfu
  :custom
  (corfu-auto nil)
  (corfu-cycle t)
  (corfu-quit-no-match t)
  :bind (:map corfu-map
              ("C-n" . corfu-next)
              ("C-p" . corfu-previous)
              ("RET" . corfu-insert))
  :init (global-corfu-mode))

(use-package cape
  :init
  (add-to-list 'completion-at-point-functions #'cape-dabbrev)
  (add-to-list 'completion-at-point-functions #'cape-file))

;;; Vertico + Consult

(use-package vertico :init (vertico-mode))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

(use-package marginalia :init (marginalia-mode))

(use-package consult
  :bind (("C-c s" . consult-line)
         ("C-x b" . consult-buffer)
         ("M-g g" . consult-goto-line)
         ("C-c f" . consult-fd)
         ("C-c r" . consult-ripgrep))
  :custom (consult-async-min-input 2))

;;; TRAMP

(use-package tramp
  :ensure nil
  :custom
  (tramp-default-method "ssh")
  (tramp-connection-timeout 10)
  (tramp-ssh-controlmaster-options
   (concat "-o ControlMaster=auto "
           "-o ControlPath=/tmp/tramp.%%r@%%h:%%p "
           "-o ControlPersist=yes"))
  (tramp-remote-path '(tramp-own-remote-path tramp-default-remote-path))
  :config (setq tramp-verbose 2)) ; M-x tramp-cleanup-all-connections to reset

;;; Org

(use-package org
  :ensure nil
  :custom
  (org-directory "~/orgfiles")
  (org-default-notes-file "~/orgfiles/inbox.org")
  (org-agenda-files '("~/orgfiles/daily/" "~/orgfiles/inbox.org"))
  (org-startup-indented t)
  (org-hide-leading-stars t)
  (org-log-done 'time)
  (org-todo-keywords
   '((sequence "TODO(t)" "IN-PROGRESS(i)" "WAITING(w)" "|" "DONE(d)" "CANCELLED(c)")))
  (org-capture-templates
   '(("t" "Task"    entry (file+headline "~/orgfiles/inbox.org" "Tasks")
      "* TODO %?\n  %U\n")
     ("m" "Memo"    entry (file #'my/org-daily-file)
      "* %?\n  %U\n")
     ("b" "Backlog" entry (file+headline "~/orgfiles/inbox.org" "Backlog")
      "* TODO %?\n  %U\n")))
  :bind (("C-c a" . org-agenda)
         ("C-c c" . org-capture)
         ("C-c l" . org-store-link)
         ("C-c d" . my/org-open-today))
  :config
  (defun my/org-daily-file ()
    "Return today's daily file path, creating it with a template if needed."
    (let* ((date (format-time-string "%Y-%m-%d"))
           (path (expand-file-name (concat "daily/" date ".org") org-directory)))
      (unless (file-exists-p path)
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert (format "#+TITLE: %s\n#+DATE: %s\n\n* Tasks\n\n* Notes\n\n* Journal\n"
                          date date))))
      path))
  (defun my/org-open-today ()
    "Open today's daily file."
    (interactive)
    (find-file (my/org-daily-file)))
  (add-hook 'emacs-startup-hook #'my/org-open-today))

;;; SKK (Japanese input)

(use-package ddskk
  :bind ("C-x C-j" . skk-mode)
  :custom
  (skk-large-jisyo "/usr/share/skk/SKK-JISYO.L")
  (skk-egg-like-newline t)         ; RET confirms candidate without newline
  (skk-show-inline t)              ; show candidates inline
  (skk-latin-mode-string "[A]")
  (skk-hiragana-mode-string "[あ]")
  (skk-katakana-mode-string "[ア]"))

;;; Vterm + Tmux integration

(use-package vterm
  :custom
  (vterm-max-scrollback 10000)
  (vterm-shell "/bin/bash"))

(defun my/tmux-session-name ()
  "Return tmux session name based on current project or directory."
  (if-let (project (project-current))
      (file-name-nondirectory
       (directory-file-name (project-root project)))
    (file-name-nondirectory
     (directory-file-name default-directory))))

(defun my/vterm-tmux ()
  "Open vterm and attach to (or create) a tmux session for current project."
  (interactive)
  (let* ((session (my/tmux-session-name))
         (buf-name (format "*vterm:%s*" session)))
    (if (get-buffer buf-name)
        (switch-to-buffer buf-name)
      (let ((buf (vterm buf-name)))
        (with-current-buffer buf
          (vterm-send-string
           (format "tmux new-session -A -s %s\n" session)))))))

(global-set-key (kbd "C-c t") #'my/vterm-tmux)

;;; Magit

(use-package magit
  :bind ("C-x g" . magit-status))

;;; Dirvish

(use-package dirvish
  :init (dirvish-override-dired-mode)
  :custom
  (dirvish-attributes '(file-size collapse))
  (dirvish-side-width 35)
  :bind (("C-x d"   . dirvish)
         ("C-x C-d" . dirvish-side)))

;;; Project

(use-package project
  :ensure nil
  :custom
  (project-switch-commands
   '((project-find-file    "Find file"    "f")
     (consult-ripgrep      "Ripgrep"      "r")
     (consult-fd           "Find file fd" "F")
     (project-dired        "Dired"        "d")
     (project-eshell       "Eshell"       "e")))
  :bind (("C-x p p" . project-switch-project)
         ("C-x p f" . project-find-file)
         ("C-x p r" . consult-ripgrep)
         ("C-x p b" . consult-project-buffer)
         ("C-x p d" . project-dired)
         ("C-x p k" . project-kill-buffers)))

;;; Keybindings

(global-set-key (kbd "M-o") #'other-window)
(global-set-key (kbd "C-h") #'backward-delete-char-untabify)
(global-set-key (kbd "M-h") #'backward-kill-word)
(global-set-key (kbd "C-x ?") #'help-command)

;;; init.el ends here
