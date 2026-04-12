;;; org-files-mcp-org.el --- Plain-org TODO MCP tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Plain org-mode TODO-management tools for org-files-mcp.
;;
;; Scope: these tools ONLY operate on files that are members of
;; `org-agenda-files' (as configured in the user's `init.el').  Roam
;; files, refile.org, and archive files are rejected at the resolver
;; layer.  Files are addressed relative to `org-directory'.
;;
;; Tool families:
;;   Create:     org_add_todo
;;   State/meta: org_toggle_todo_state, org_set_scheduled,
;;               org_set_deadline, org_set_property,
;;               org_add_tag, org_remove_tag
;;   Read:       org_list_todo_keywords, org_agenda,
;;               org_todo_list, org_tags_view
;;
;; Heading CRUD (create/update/rename/delete/refile) and generic
;; file editing are handled by the roam_* module in this server.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'cl-lib)

(declare-function org-files-mcp--tool-result-json "org-files-mcp" (obj))
(declare-function org-files-mcp--md-to-org "org-files-mcp" (md-string &optional container-level))
(declare-function org-files-mcp--child-level "org-files-mcp" (parent-level))
(declare-function org-files-mcp--archive-heading-regexp "org-files-mcp" ())
(declare-function org-files-mcp--resolve-agenda-file "org-files-mcp" (file))
(declare-function org-files-mcp--resolve-olp-agenda "org-files-mcp" (file olp))
(declare-function org-files-mcp--olp-to-list "org-files-mcp" (olp))
(declare-function org-files-mcp--all-todo-keywords "org-files-mcp" ())
(declare-function org-files-mcp--next-todo-state "org-files-mcp" (current-state))
(declare-function org-files-mcp--clean-keyword "org-files-mcp" (kw))
(declare-function org-files-mcp--scan-agenda-files "org-files-mcp" (filter-fn))
(declare-function org-files-mcp--scan-entries-by-match "org-files-mcp" (file match todo-only))
(declare-function org-files-mcp--entry-plist-to-alist "org-files-mcp" (plist))
(declare-function org-files-mcp--date-in-range-p "org-files-mcp" (date-str start-date end-date))
(declare-function org-files-mcp--agenda-files-absolute "org-files-mcp" ())
(defvar org-files-mcp--ai-tag)

;; ============================================================
;; TODO state / scheduling / property / tag tools
;; ============================================================

(defun org-files-mcp--tool-org-toggle-todo-state (args)
  "Toggle TODO state on a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (new-state (alist-get 'new_state args))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file))
         result-state)
    (when new-state
      (unless (member new-state (org-files-mcp--all-todo-keywords))
        (error "Invalid TODO state: '%s'" new-state)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (let ((state (or new-state
                       (org-files-mcp--next-todo-state (org-get-todo-state))
                       "")))
        (org-todo state))
      (setq result-state (org-get-todo-state))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))
       (state . ,(or result-state :null))))))

(defun org-files-mcp--tool-org-list-todo-keywords (_args)
  "List configured TODO keyword sequences."
  (let ((sequences
         (cl-loop for seq in (or org-todo-keywords '((sequence "TODO" "DONE")))
                  collect
                  (let* ((type (car seq))
                         (kws (cdr seq))
                         (active '())
                         (done '())
                         (past-separator nil))
                    (dolist (kw kws)
                      (let ((clean (org-files-mcp--clean-keyword kw)))
                        (if (string= clean "|")
                            (setq past-separator t)
                          (if past-separator
                              (push clean done)
                            (push clean active)))))
                    `((type . ,(symbol-name type))
                      (active . ,(vconcat (nreverse active)))
                      (done . ,(vconcat (nreverse done))))))))
    (org-files-mcp--tool-result-json
     `((sequences . ,(vconcat sequences))
       (all_keywords . ,(vconcat (org-files-mcp--all-todo-keywords)))))))

(defun org-files-mcp--tool-org-set-scheduled (args)
  "Set SCHEDULED on a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (date (alist-get 'date args))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (if (or (null date) (string-empty-p date))
          (org-schedule '(4))
        (org-schedule nil date))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-set-deadline (args)
  "Set DEADLINE on a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (date (alist-get 'date args))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (if (or (null date) (string-empty-p date))
          (org-deadline '(4))
        (org-deadline nil date))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-set-property (args)
  "Set a property on a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (name (alist-get 'name args))
         (value (alist-get 'value args))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (org-set-property name value)
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-add-tag (args)
  "Add a tag to a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (tag (alist-get 'tag args))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file))
         (current-tags (plist-get target :tags)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (unless (member tag current-tags)
        (org-set-tags (append current-tags (list tag))))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-remove-tag (args)
  "Remove a tag from a heading in an agenda file."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (tag (alist-get 'tag args))
         (_guard (when (equal tag org-files-mcp--ai-tag)
                   (error "Refusing to remove AI tag `%s' via MCP; edit in Emacs if intended"
                          org-files-mcp--ai-tag)))
         (target (org-files-mcp--resolve-olp-agenda file olp))
         (file-abs (plist-get target :file))
         (current-tags (plist-get target :tags)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (when (member tag current-tags)
        (org-set-tags (delete tag (copy-sequence current-tags))))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

;; ============================================================
;; Convenience: add_todo
;; ============================================================

(defun org-files-mcp--default-todo-file ()
  "Return the preferred agenda file for new TODOs, as an absolute path.
Prefers `org-default-notes-file' if it is a member of
`org-agenda-files'; otherwise returns the first agenda file."
  (let* ((agenda (org-files-mcp--agenda-files-absolute))
         (notes (and org-default-notes-file
                     (expand-file-name org-default-notes-file))))
    (cond
     ((and notes (member notes agenda)) notes)
     (agenda (car agenda))
     (t (error "No agenda files configured")))))

(defun org-files-mcp--tool-org-add-todo (args)
  "Create a TODO heading in an agenda file.
Defaults the target file to `org-default-notes-file' (if in agenda
files) and `state' to TODO.  Supports scheduled/deadline in one call."
  (let* ((file-arg (alist-get 'file args))
         (file-abs (if file-arg
                       (org-files-mcp--resolve-agenda-file file-arg)
                     (org-files-mcp--default-todo-file)))
         (file-rel (if file-arg file-arg
                     (file-relative-name file-abs
                                         (or org-directory default-directory))))
         (parent-olp (org-files-mcp--olp-to-list (alist-get 'parent_olp args)))
         (heading (alist-get 'heading args))
         (state (or (alist-get 'state args) "TODO"))
         (priority (alist-get 'priority args))
         (user-tags (org-files-mcp--olp-to-list (alist-get 'tags args)))
         (tags (if (member org-files-mcp--ai-tag user-tags)
                   user-tags
                 (append user-tags (list org-files-mcp--ai-tag))))
         (scheduled (alist-get 'scheduled args))
         (deadline (alist-get 'deadline args))
         (body (alist-get 'body args))
         parent-level goto-point result-olp)
    (unless heading (error "heading is required"))
    (unless (member state (org-files-mcp--all-todo-keywords))
      (error "Invalid TODO state: '%s'" state))
    (if parent-olp
        (let ((target (org-files-mcp--resolve-olp-agenda file-rel parent-olp)))
          (setq parent-level (plist-get target :level))
          (setq goto-point (plist-get target :point))
          (setq result-olp (append parent-olp (list heading))))
      (setq parent-level 0)
      (setq goto-point nil)
      (setq result-olp (list heading)))
    (with-current-buffer (find-file-noselect file-abs)
      (if goto-point
          (progn (goto-char goto-point) (org-end-of-subtree t))
        (goto-char (point-min))
        (let ((archive-re (org-files-mcp--archive-heading-regexp)))
          (if (and archive-re (re-search-forward archive-re nil t))
              (progn (goto-char (match-beginning 0))
                     (skip-chars-backward "\n"))
            (goto-char (point-max)))))
      (let ((child-level (org-files-mcp--child-level parent-level)))
        (insert "\n" (make-string child-level ?*)
                " " state " "
                (if priority (format "[#%s] " priority) "")
                heading "\n")
        (forward-line -1)
        (when tags (org-set-tags (mapconcat #'identity tags ":")))
        (when scheduled (org-schedule nil scheduled))
        (when deadline (org-deadline nil deadline))
        (when body
          (goto-char (org-entry-end-position))
          (insert (org-files-mcp--md-to-org body child-level))
          (unless (string-suffix-p "\n" body) (insert "\n"))))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file-rel) (olp . ,(vconcat result-olp))))))

;; ============================================================
;; Agenda read tools
;; ============================================================

(defun org-files-mcp--tool-org-agenda (args)
  "Scan `org-agenda-files' for scheduled/deadline items in the next N days."
  (let* ((span (or (alist-get 'span args) 7))
         (start-date (current-time))
         (end-date (time-add start-date (days-to-time span)))
         (entries
          (org-files-mcp--scan-agenda-files
           (lambda (plist)
             (let ((sched (plist-get plist :scheduled))
                   (dl    (plist-get plist :deadline)))
               (cond
                ((org-files-mcp--date-in-range-p sched start-date end-date)
                 (plist-put plist :date sched))
                ((org-files-mcp--date-in-range-p dl start-date end-date)
                 (plist-put plist :date dl))
                (t nil))))))
         (alists (mapcar #'org-files-mcp--entry-plist-to-alist entries)))
    (org-files-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

(defun org-files-mcp--tool-org-todo-list (args)
  "Get TODO items across `org-agenda-files', optionally filtered."
  (let* ((match (alist-get 'match args))
         (keywords (when match (split-string match "|" t "[ \t]+")))
         (entries
          (org-files-mcp--scan-agenda-files
           (lambda (plist)
             (let ((todo (plist-get plist :todo_state)))
               (when (and todo
                          (or (null keywords)
                              (member todo keywords)))
                 plist)))))
         (alists (mapcar #'org-files-mcp--entry-plist-to-alist entries)))
    (org-files-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

(defun org-files-mcp--tool-org-tags-view (args)
  "Search `org-agenda-files' by tag/property match."
  (let* ((match (alist-get 'match args))
         (todo-only (eq t (alist-get 'todo_only args)))
         (files (org-agenda-files t))
         (entries
          (cl-loop for file in files
                   nconc (org-files-mcp--scan-entries-by-match
                          file match todo-only)))
         (alists (mapcar #'org-files-mcp--entry-plist-to-alist entries)))
    (org-files-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

(provide 'org-files-mcp-org)

;;; org-files-mcp-org.el ends here
