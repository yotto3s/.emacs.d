(use-package solarized-theme
  :ensure t
  :config (load-theme 'solarized-dark t))

(use-package which-key
  :ensure t
  :config
  (which-key-mode)
  )

(use-package magit
  :ensure t)

(use-package ddskk
  :ensure t
  :bind (("C-x C-j" . skk-mode)
         ("C-x j" . skk-auto-fill-mode))
  :config
  (add-hook 'isearch-mode-hook 'skk-isearch-mode-setup)
  (add-hook 'isearch-mode-end-hook 'skk-isearch-mode-cleanup))

(use-package eglot
  :ensure t
  :config
  (define-key eglot-mode-map (kbd "M-.") 'xref-find-definitions)
  (define-key eglot-mode-map (kbd "M-,") 'pop-tag-mark)
  )



(use-package julia-mode
  :init (add-to-list 'eglot-server-programs
                     '(julia-mode . ("julia" "-e using LanguageServer, LanguageServer.SymbolServer; runserver()"))))

(use-package julia-repl
  :hook julia-mode
  )

(use-package haskell-mode
  :config
  (require 'haskell-interactive-mode)
  (require 'haskell-process)
  (add-hook 'haskell-mode 'interactive-haskell-mode)
  (define-key haskell-mode-map (kbd "C-c C-l") 'haskell-process-load-or-reload)
  (define-key haskell-mode-map (kbd "C-`") 'haskell-interactive-bring)
  (define-key haskell-mode-map (kbd "C-c C-t") 'haskell-process-do-type)
  (define-key haskell-mode-map (kbd "C-c C-i") 'haskell-process-do-info)
  (define-key haskell-mode-map (kbd "C-c C-c") 'haskell-process-cabal-build)
  (define-key haskell-mode-map (kbd "C-c C-k") 'haskell-interactive-mode-clear)
  (define-key haskell-mode-map (kbd "C-c c") 'haskell-process-cabal)
  )
(use-package elm-mode)

(use-package python-mode)
