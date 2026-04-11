;;; org-files-mcp-org.el --- Plain-org MCP tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Plain org-mode tool implementations for org-files-mcp.
;;
;; All tools in this module operate on plain org files under
;; `org-directory' that are NOT inside `org-roam-directory'.  Targets
;; are addressed by (file, olp) pairs where `file' is a path relative
;; to `org-directory' and `olp' is a list of heading titles matching
;; `org-find-olp's convention.  The core resolver (`--resolve-olp',
;; `--resolve-existing-file', `--resolve-new-file') rejects any path
;; inside `org-roam-directory' with a clear read-only error.
;;
;; No `:ID:' properties are generated or read by any tool in this
;; module.  `org-id-get-create' and `org-id-new' are never called.
;;
;; Tool families:
;;   File-level:   org_create_file, org_delete_file, org_rename_file
;;   Heading CRUD: org_create_heading, org_append_to_heading,
;;                 org_update_heading_section, org_delete_heading,
;;                 org_rename_heading, org_refile_heading
;;   TODO/meta:    org_toggle_todo_state, org_set_scheduled,
;;                 org_set_deadline, org_set_property,
;;                 org_add_tag, org_remove_tag
;;   Convenience:  org_add_todo
;;   Read:         org_list_todo_keywords, org_agenda, org_todo_list,
;;                 org_tags_view

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'cl-lib)

(declare-function org-files-mcp--tool-result-json "org-files-mcp" (obj))
(declare-function org-files-mcp--md-to-org "org-files-mcp" (md-string &optional container-level))
(declare-function org-files-mcp--child-level "org-files-mcp" (parent-level))
(declare-function org-files-mcp--archive-heading-regexp "org-files-mcp" ())
(declare-function org-files-mcp--resolve-existing-file "org-files-mcp" (file))
(declare-function org-files-mcp--resolve-new-file "org-files-mcp" (file))
(declare-function org-files-mcp--resolve-olp "org-files-mcp" (file olp))
(declare-function org-files-mcp--olp-to-list "org-files-mcp" (olp))
(declare-function org-files-mcp--all-todo-keywords "org-files-mcp" ())
(declare-function org-files-mcp--next-todo-state "org-files-mcp" (current-state))
(declare-function org-files-mcp--clean-keyword "org-files-mcp" (kw))
(declare-function org-files-mcp--scan-agenda-files "org-files-mcp" (filter-fn))
(declare-function org-files-mcp--scan-entries-by-match "org-files-mcp" (file match todo-only))
(declare-function org-files-mcp--entry-plist-to-alist "org-files-mcp" (plist))
(declare-function org-files-mcp--date-in-range-p "org-files-mcp" (date-str start-date end-date))

;; ============================================================
;; File-level tools
;; ============================================================

(defun org-files-mcp--tool-org-create-file (args)
  "Create a new plain org file."
  (let* ((file (alist-get 'file args))
         (title (alist-get 'title args))
         (tags (org-files-mcp--olp-to-list (alist-get 'tags args)))
         (body (alist-get 'body args))
         (abs (org-files-mcp--resolve-new-file file)))
    (with-temp-file abs
      (when title
        (insert "#+title: " title "\n"))
      (when tags
        (insert "#+filetags: :" (mapconcat #'identity tags ":") ":\n"))
      (when (or title tags)
        (insert "\n"))
      (when body
        (insert (org-files-mcp--md-to-org body 0))
        (unless (string-suffix-p "\n" body)
          (insert "\n"))))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)))))

(defun org-files-mcp--tool-org-delete-file (args)
  "Delete a plain org file."
  (let* ((file (alist-get 'file args))
         (confirm (alist-get 'confirm args))
         (abs (org-files-mcp--resolve-existing-file file)))
    (unless confirm (error "confirm must be true to delete"))
    (when-let ((buf (find-buffer-visiting abs)))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))
    (delete-file abs)
    (org-files-mcp--tool-result-json
     `((status . "deleted") (file . ,file)))))

(defun org-files-mcp--tool-org-rename-file (args)
  "Rename a plain org file on disk."
  (let* ((file (alist-get 'file args))
         (new-file (alist-get 'new_file args))
         (abs (org-files-mcp--resolve-existing-file file))
         (new-abs (org-files-mcp--resolve-new-file new-file)))
    (when (string= abs new-abs)
      (error "Source and destination are the same"))
    (when-let ((buf (find-buffer-visiting abs)))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))
    (rename-file abs new-abs)
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,new-file)))))

;; ============================================================
;; Heading CRUD tools
;; ============================================================

(defun org-files-mcp--insert-heading-at-point (level state priority heading tags props body)
  "Insert a heading at the current buffer position.
LEVEL is the heading depth; STATE/PRIORITY/TAGS/PROPS/BODY optional.
Body-embedded markdown headings are shifted so they become children of
the inserted heading."
  (insert "\n" (make-string level ?*) " "
          (if state (concat state " ") "")
          (if priority (format "[#%s] " priority) "")
          heading "\n")
  (forward-line -1)
  (when tags
    (org-set-tags (mapconcat #'identity tags ":")))
  (when props
    (dolist (kv props)
      (let ((k (cond ((vectorp kv) (aref kv 0))
                     ((consp kv) (car kv))
                     (t (error "Invalid property entry: %S" kv))))
            (v (cond ((vectorp kv) (aref kv 1))
                     ((consp kv) (cdr kv))
                     (t ""))))
        (org-set-property k v))))
  (when body
    (goto-char (org-entry-end-position))
    (insert (org-files-mcp--md-to-org body level))
    (unless (string-suffix-p "\n" body)
      (insert "\n"))))

(defun org-files-mcp--tool-org-create-heading (args)
  "Create a new heading in a plain org file."
  (let* ((file (alist-get 'file args))
         (parent-olp (org-files-mcp--olp-to-list (alist-get 'parent_olp args)))
         (heading (alist-get 'heading args))
         (state (alist-get 'state args))
         (priority (alist-get 'priority args))
         (tags (org-files-mcp--olp-to-list (alist-get 'tags args)))
         (props (alist-get 'properties args))
         (props-list (cond ((null props) nil)
                           ((vectorp props) (append props nil))
                           (t props)))
         (body (alist-get 'body args))
         file-abs parent-level goto-point result-olp)
    (unless heading (error "heading is required"))
    (when (and state (not (member state (org-files-mcp--all-todo-keywords))))
      (error "Invalid TODO state: '%s'" state))
    (if parent-olp
        (let ((target (org-files-mcp--resolve-olp file parent-olp)))
          (setq file-abs (plist-get target :file))
          (setq parent-level (plist-get target :level))
          (setq goto-point (plist-get target :point))
          (setq result-olp (append parent-olp (list heading))))
      (setq file-abs (org-files-mcp--resolve-existing-file file))
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
      (org-files-mcp--insert-heading-at-point
       (org-files-mcp--child-level parent-level)
       state priority heading tags props-list body)
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file) (olp . ,(vconcat result-olp))))))

(defun org-files-mcp--tool-org-append-to-heading (args)
  "Append content to the end of a heading's subtree."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (body (alist-get 'body args))
         (target (org-files-mcp--resolve-olp file olp))
         (file-abs (plist-get target :file))
         (level (plist-get target :level)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (org-end-of-subtree t)
      (insert "\n" (org-files-mcp--md-to-org body level))
      (unless (string-suffix-p "\n" body)
        (insert "\n"))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-update-heading-section (args)
  "Replace/append/prepend the body of a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (body (alist-get 'body args))
         (mode (or (alist-get 'mode args) "replace"))
         (target (org-files-mcp--resolve-olp file olp))
         (file-abs (plist-get target :file))
         (org-body (org-files-mcp--md-to-org body (plist-get target :level))))
    (with-current-buffer (find-file-noselect file-abs)
      (save-excursion
        (save-restriction
          (goto-char (plist-get target :point))
          (org-narrow-to-subtree)
          (goto-char (point-min))
          (forward-line 1)
          (org-end-of-meta-data t)
          (let ((body-start (point))
                (body-end (save-excursion
                            (or (outline-next-heading) (goto-char (point-max)))
                            (point))))
            (pcase mode
              ("replace"
               (delete-region body-start body-end)
               (goto-char body-start)
               (insert org-body)
               (unless (string-suffix-p "\n" org-body) (insert "\n")))
              ("append"
               (goto-char body-end)
               (insert org-body)
               (unless (string-suffix-p "\n" org-body) (insert "\n")))
              ("prepend"
               (goto-char body-start)
               (insert org-body)
               (unless (string-suffix-p "\n" org-body) (insert "\n")))
              (_ (error "Invalid mode: '%s'" mode))))))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-delete-heading (args)
  "Cut a heading and its subtree."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (confirm (alist-get 'confirm args))
         (target (org-files-mcp--resolve-olp file olp))
         (file-abs (plist-get target :file)))
    (unless confirm (error "confirm must be true to delete"))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (org-cut-subtree)
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "deleted") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-rename-heading (args)
  "Change a heading's title."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (new-title (alist-get 'new_title args))
         (target (org-files-mcp--resolve-olp file olp))
         (file-abs (plist-get target :file))
         (olp-list (org-files-mcp--olp-to-list olp))
         (new-olp (append (butlast olp-list) (list new-title))))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (org-edit-headline new-title)
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file) (olp . ,(vconcat new-olp))))))

(defun org-files-mcp--tool-org-refile-heading (args)
  "Cut a heading subtree and paste it under a target heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (target-file (alist-get 'target_file args))
         (target-parent-olp (org-files-mcp--olp-to-list
                             (alist-get 'target_parent_olp args)))
         (source-olp-list (org-files-mcp--olp-to-list olp))
         ;; Validate both sides are writable plain-org paths BEFORE cutting
         (source-abs (org-files-mcp--resolve-existing-file file))
         (target-abs (org-files-mcp--resolve-existing-file target-file))
         (heading-text (car (last source-olp-list)))
         subtree-text)
    (unless (and source-olp-list (> (length source-olp-list) 0))
      (error "olp must be non-empty"))
    ;; Ensure source heading resolves before mutating anything
    (org-files-mcp--resolve-olp file source-olp-list)
    (when target-parent-olp
      (org-files-mcp--resolve-olp target-file target-parent-olp))
    ;; Cut from source
    (let ((src-marker (org-find-olp (cons source-abs source-olp-list))))
      (with-current-buffer (marker-buffer src-marker)
        (goto-char (marker-position src-marker))
        (org-mark-subtree)
        (setq subtree-text (delete-and-extract-region (region-beginning) (region-end)))
        (deactivate-mark)
        (save-buffer)))
    ;; Paste under target (re-resolve, since target file may equal source)
    (with-current-buffer (find-file-noselect target-abs)
      (if target-parent-olp
          (let ((tgt-marker (org-find-olp (cons target-abs target-parent-olp))))
            (goto-char (marker-position tgt-marker))
            (org-end-of-subtree t))
        (goto-char (point-max)))
      (unless (bolp) (insert "\n"))
      (insert subtree-text)
      (unless (string-suffix-p "\n" subtree-text) (insert "\n"))
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok")
       (file . ,target-file)
       (olp . ,(vconcat (append (or target-parent-olp '())
                                (list heading-text))))))))

;; ============================================================
;; TODO / scheduling / property / tag tools
;; ============================================================

(defun org-files-mcp--tool-org-toggle-todo-state (args)
  "Toggle TODO state on a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (new-state (alist-get 'new_state args))
         (target (org-files-mcp--resolve-olp file olp))
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
  "Set SCHEDULED on a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (date (alist-get 'date args))
         (target (org-files-mcp--resolve-olp file olp))
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
  "Set DEADLINE on a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (date (alist-get 'date args))
         (target (org-files-mcp--resolve-olp file olp))
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
  "Set a property on a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (name (alist-get 'name args))
         (value (alist-get 'value args))
         (target (org-files-mcp--resolve-olp file olp))
         (file-abs (plist-get target :file)))
    (with-current-buffer (find-file-noselect file-abs)
      (goto-char (plist-get target :point))
      (org-set-property name value)
      (save-buffer))
    (org-files-mcp--tool-result-json
     `((status . "ok") (file . ,file)
       (olp . ,(vconcat (org-files-mcp--olp-to-list olp)))))))

(defun org-files-mcp--tool-org-add-tag (args)
  "Add a tag to a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (tag (alist-get 'tag args))
         (target (org-files-mcp--resolve-olp file olp))
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
  "Remove a tag from a heading."
  (let* ((file (alist-get 'file args))
         (olp (alist-get 'olp args))
         (tag (alist-get 'tag args))
         (target (org-files-mcp--resolve-olp file olp))
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
  "Return the default file for `org_add_todo', relative to `org-directory'."
  (when org-default-notes-file
    (let ((dir (or org-directory default-directory)))
      (if (file-in-directory-p org-default-notes-file dir)
          (file-relative-name org-default-notes-file dir)
        org-default-notes-file))))

(defun org-files-mcp--tool-org-add-todo (args)
  "Create a TODO heading in a plain-org file.
Convenience variant of `org_create_heading' that defaults `file' to
`org-default-notes-file' and `state' to TODO, and supports scheduled
and deadline in one call."
  (let* ((file (or (alist-get 'file args)
                   (org-files-mcp--default-todo-file)
                   (error "No file specified and `org-default-notes-file' is nil")))
         (parent-olp (org-files-mcp--olp-to-list (alist-get 'parent_olp args)))
         (heading (alist-get 'heading args))
         (state (or (alist-get 'state args) "TODO"))
         (priority (alist-get 'priority args))
         (tags (org-files-mcp--olp-to-list (alist-get 'tags args)))
         (scheduled (alist-get 'scheduled args))
         (deadline (alist-get 'deadline args))
         (body (alist-get 'body args))
         file-abs parent-level goto-point result-olp)
    (unless heading (error "heading is required"))
    (unless (member state (org-files-mcp--all-todo-keywords))
      (error "Invalid TODO state: '%s'" state))
    (if parent-olp
        (let ((target (org-files-mcp--resolve-olp file parent-olp)))
          (setq file-abs (plist-get target :file))
          (setq parent-level (plist-get target :level))
          (setq goto-point (plist-get target :point))
          (setq result-olp (append parent-olp (list heading))))
      (setq file-abs (org-files-mcp--resolve-existing-file file))
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
     `((status . "ok") (file . ,file) (olp . ,(vconcat result-olp))))))

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
