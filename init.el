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

;;; Which-key

(use-package which-key
  :init (which-key-mode)
  :custom (which-key-idle-delay 0.5))

;;; Vterm + Tmux integration

(use-package vterm
  :custom
  (vterm-max-scrollback 10000)
  (vterm-shell "/bin/bash"))

(defun my/tramp-info ()
  "Return plist (:method :host :ssh-host :localname) for current TRAMP buffer, or nil."
  (when (file-remote-p default-directory)
    (let* ((vec       (tramp-dissect-file-name default-directory))
           (method    (tramp-file-name-method vec))
           (host      (tramp-file-name-host vec))
           (localname (tramp-file-name-localname vec))
           (hop       (when (fboundp 'tramp-file-name-hop)
                        (tramp-file-name-hop vec)))
           (ssh-host  (cond
                       ((and hop (string-match "ssh" hop))
                        (tramp-file-name-host
                         (tramp-dissect-file-name (concat hop "/"))))
                       ((equal method "ssh") host))))
      (list :method method :host host :ssh-host ssh-host :localname localname))))

(defun my/tmux-session-name (&optional tramp-info)
  "Return tmux session name based on current project or directory.
For remote buffers, uses the path on the remote machine only.
Optionally accepts pre-computed TRAMP-INFO plist to avoid redundant parsing."
  (let* ((info  (or tramp-info (my/tramp-info)))
         (root  (if-let (project (project-current))
                    (project-root project)
                  default-directory))
         (path  (directory-file-name
                 (if info
                     (tramp-file-name-localname
                      (tramp-dissect-file-name root))
                   (expand-file-name root))))
         (name  (replace-regexp-in-string "[[:space:]]" "_"
                 (replace-regexp-in-string "/" "-" path))))
    (if (string-empty-p name) "default" (string-trim-left name "-"))))

(defun my/tmux-command (session container)
  "Build tmux new-session command, optionally launching into CONTAINER."
  (if container
      (format "tmux new-session -A -s %s 'docker exec -it %s bash'"
              session container)
    (format "tmux new-session -A -s %s" session)))

(defun my/vterm-tmux ()
  "Open vterm and attach to tmux session, local or remote.
If inside a docker container, the tmux session launches into it."
  (interactive)
  (unless (fboundp 'vterm)
    (user-error "vtermがインストールされていません: M-x package-install RET vterm"))
  (let* ((info      (my/tramp-info))
         (session   (my/tmux-session-name info))
         (ssh-host  (plist-get info :ssh-host))
         (container (when (equal (plist-get info :method) "docker")
                      (plist-get info :host)))
         (tmux-cmd  (my/tmux-command session container))
         (buf-name  (format "*vterm:%s%s*"
                            (if ssh-host (concat ssh-host ":") "")
                            session)))
    (if (get-buffer buf-name)
        (switch-to-buffer buf-name)
      (let ((buf (vterm buf-name)))
        (run-with-timer 0.5 nil
                        (lambda ()
                          (with-current-buffer buf
                            (vterm-send-string
                             (if ssh-host
                                 (format "ssh %s -t \"%s\"\n" ssh-host tmux-cmd)
                               (format "%s\n" tmux-cmd))))))))))

(global-set-key (kbd "C-c t") #'my/vterm-tmux)

;;; Tab bar

(use-package tab-bar
  :ensure nil
  :custom
  (tab-bar-show 1)                  ; タブが2つ以上のときのみ表示
  (tab-bar-close-button-show nil)
  (tab-bar-new-button-show nil)
  (tab-bar-tab-hints t)             ; タブに番号を表示
  :init (tab-bar-mode 1)
  :bind (("C-x t 2" . tab-bar-new-tab)
         ("C-x t 0" . tab-bar-close-tab)
         ("C-x t o" . tab-bar-switch-to-next-tab)
         ("C-x t O" . tab-bar-switch-to-prev-tab)
         ("C-x t r" . tab-bar-rename-tab)
         ("M-1"     . (lambda () (interactive) (tab-bar-select-tab 1)))
         ("M-2"     . (lambda () (interactive) (tab-bar-select-tab 2)))
         ("M-3"     . (lambda () (interactive) (tab-bar-select-tab 3)))
         ("M-4"     . (lambda () (interactive) (tab-bar-select-tab 4)))))

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
