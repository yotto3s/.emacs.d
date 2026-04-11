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
  (tramp-show-ad-hoc-proxies t)
  :config (setq tramp-verbose 2)) ; M-x tramp-cleanup-all-connections to reset

;;; Org

(use-package org
  :ensure nil
  :custom
  (org-directory "~/orgfiles")
  (org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (org-agenda-files (list (expand-file-name "inbox.org" org-directory)))
  (org-archive-location "::* Archive")
  (org-refile-targets
   '((nil :maxlevel . 3)                 ; current file, up to 3 levels deep
     (org-agenda-files :maxlevel . 2)    ; all agenda files
     (org-roam-list-files :maxlevel . 2))) ; all org-roam files
  (org-refile-use-outline-path 'file)
  (org-outline-path-complete-in-steps nil)
  (org-refile-allow-creating-parent-nodes 'confirm)
  (org-startup-indented t)
  (org-hide-leading-stars t)
  (org-log-done 'time)
  (org-todo-keywords
   '((sequence "TODO(t)" "IN-PROGRESS(p)" "WAITING(w)" "|" "DONE(d)" "CANCELLED(c)")))
  (org-capture-templates
   '(("t" "Task" entry (file org-default-notes-file)
      "* TODO %?\n  %U\n")
     ("m" "Memo" entry (file "refile.org")
      "* %?\n  %U\n")))
  :bind (("C-c a" . org-agenda)
         ("C-c c" . org-capture)
         ("C-c l" . org-store-link)))

;;; Org-roam

(use-package org-roam
  :custom
  (org-roam-directory (expand-file-name "roam/" org-directory))
  (org-roam-db-location (expand-file-name "org-roam.db" user-emacs-directory))
  (org-roam-completion-everywhere t)
  (org-roam-capture-templates
   '(("d" "default" plain "%?"
      :target (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                          "#+TITLE: ${title}\n#+DATE: %U\n#+FILETAGS:\n")
      :unnarrowed t)))
  :bind (("C-c n f" . org-roam-node-find)
         ("C-c n i" . org-roam-node-insert)
         ("C-c n l" . org-roam-buffer-toggle)
         ("C-c n c" . org-roam-capture)
         ("C-c n e" . org-roam-extract-subtree)
         ("C-c n t" . org-roam-tag-add)
         ("C-c n a" . org-roam-alias-add)
         ("C-c n g" . org-roam-graph))
  :config
  (org-roam-db-autosync-mode))

(use-package org-roam-ui
  :after org-roam
  :custom
  (org-roam-ui-sync-theme t)
  (org-roam-ui-follow t)
  (org-roam-ui-update-on-save t)
  :bind ("C-c n u" . org-roam-ui-mode))

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

;;; Which-key

(use-package which-key
  :init (which-key-mode)
  :custom (which-key-idle-delay 0.5))

;;; Vterm + Tmux integration

(use-package vterm
  :custom
  (vterm-max-scrollback 10000)
  (vterm-shell "/bin/bash"))
;;; Tab bar

(use-package tab-bar
  :ensure nil
  :custom
  (tab-bar-show 1)
  (tab-bar-close-button-show nil)
  (tab-bar-new-button-show nil)
  (tab-bar-tab-hints t)
  :init
  (tab-bar-mode 1)
  (defalias 'my/tab-1 (lambda () (interactive) (tab-bar-select-tab 1)))
  (defalias 'my/tab-2 (lambda () (interactive) (tab-bar-select-tab 2)))
  (defalias 'my/tab-3 (lambda () (interactive) (tab-bar-select-tab 3)))
  (defalias 'my/tab-4 (lambda () (interactive) (tab-bar-select-tab 4)))
  :bind (("C-x t 2" . tab-bar-new-tab)
         ("C-x t 0" . tab-bar-close-tab)
         ("C-x t o" . tab-bar-switch-to-next-tab)
         ("C-x t O" . tab-bar-switch-to-prev-tab)
         ("C-x t r" . tab-bar-rename-tab)
         ("M-1"     . my/tab-1)
         ("M-2"     . my/tab-2)
         ("M-3"     . my/tab-3)
         ("M-4"     . my/tab-4)))

;;; Formatter

(use-package reformatter
  :config
  (reformatter-define clang-format
    :program "clang-format"
    :args '("--style=file"))
  (reformatter-define black-format
    :program "black"
    :args '("-"))
  :hook
  (c++-mode . (lambda () (local-set-key (kbd "C-c F") #'clang-format-buffer)))
  (python-mode . (lambda () (local-set-key (kbd "C-c F") #'black-format-buffer))))

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
