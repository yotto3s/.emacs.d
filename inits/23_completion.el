(use-package company
  :ensure t
  :init
  (setq company-idle-delay 0)
  (setq company-minimum-prefix-length 2)
  (setq company-dabbrev-downcase nil)
  (setq company-selection-wrap-around t))
  :config
  (global-company-mode)

(use-package company-fuzzy
  :ensure t)

(use-package ivy
  :ensure t
  :init
  (setq ivy-use-virtual-buffers t)
  (setq enable-recursive-minibuffers t)
  (setq ivy-height 30)
  (setq ivy-extra-directories nil)
  (setq ivy-re-builders-alist
        '((t . ivy--regex-plus))))

(use-package counsel
  :ensure t
  :bind (("M-x" . counsel-M-x)
         ("C-x C-f" . counsel-find-file)
         ("C-x C-b" . counsel-ibuffer)
         ("M-y" . counsel-yank-pop))
  :init
  (setq counsel-find-file-ignore-regexp (regexp-opt '("./" "../"))))

(use-package swiper
  :ensure t
  :bind ("C-s" . swiper)
  :init (setq swiper-include-line-number-in-search t))
