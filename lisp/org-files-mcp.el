;;; org-files-mcp.el --- MCP server for org files and org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (org-roam "2.2.2"))
;; Keywords: org, org-roam, mcp, ai

;;; Commentary:

;; An MCP (Model Context Protocol) server that runs inside Emacs,
;; providing AI agents with structured access to the user's org files.
;;
;; Access model:
;;   - Files under `org-roam-directory' are READ-ONLY.  Agents query
;;     them via the `roam_*' tool family (list/get/backlinks/graph/search).
;;   - Files under `org-directory' but outside `org-roam-directory' are
;;     WRITABLE via the `org_*' tool family.  Targets are addressed by
;;     (file, olp) pairs, where `file' is a path relative to
;;     `org-directory' and `olp' is a list of heading titles matching
;;     `org-find-olp's convention.  No `:ID:' properties are written.
;;
;; Transport: stdio (newline-delimited JSON-RPC 2.0)
;; Protocol: MCP 2024-11-05
;;
;; Usage:
;;   emacs --batch -l ~/.emacs.d/init.el -l org-files-mcp.el \
;;         -f org-files-mcp-start
;;
;; Layout:
;;   org-files-mcp.el       — core: transport, dispatch, schemas, helpers
;;   org-files-mcp-roam.el  — roam_* read-only tools
;;   org-files-mcp-org.el   — org_*  plain-org read + write tools

;;; Code:

(require 'org)
(require 'org-roam)
(require 'org-agenda)
(require 'json)
(require 'cl-lib)

;; ============================================================
;; Configuration
;; ============================================================

(defgroup org-files-mcp nil
  "MCP server for org files and org-roam."
  :group 'org)

(defcustom org-files-mcp-default-limit 50
  "Default limit for list operations."
  :type 'integer
  :group 'org-files-mcp)

(defconst org-files-mcp--server-name "org-files-mcp")
(defconst org-files-mcp--server-version "0.4.0")
(defconst org-files-mcp--protocol-version "2024-11-05")

;; ============================================================
;; Logging (stderr only — stdout is the transport)
;; ============================================================

(defun org-files-mcp--log (fmt &rest args)
  "Log FMT with ARGS to stderr."
  (let ((msg (apply #'format fmt args)))
    (princ (concat "[org-files-mcp] " msg "\n") #'external-debugging-output)))

;; ============================================================
;; Markdown → Org conversion (Pandoc required)
;; ============================================================

(defun org-files-mcp--check-pandoc ()
  "Verify Pandoc is available. Signal error if not found."
  (unless (executable-find "pandoc")
    (error "Pandoc is required but not found in PATH. Install it: https://pandoc.org/installing.html")))

(defun org-files-mcp--md-to-org (md-string &optional container-level)
  "Convert Markdown MD-STRING to org format using Pandoc.
Disables `auto_identifiers' so Pandoc does not emit :CUSTOM_ID: drawers.
CONTAINER-LEVEL (default 0) is the org heading level that will contain
the converted body — Pandoc shifts all heading levels in MD-STRING by
that amount so `# foo' becomes a child of the container, not a sibling."
  (org-files-mcp--pandoc-convert md-string "markdown-auto_identifiers" "org"
                                 (or container-level 0)))

(defun org-files-mcp--pandoc-convert (input from-fmt to-fmt &optional heading-shift)
  "Convert INPUT string from FROM-FMT to TO-FMT via pandoc.
If HEADING-SHIFT is a positive integer, adds --shift-heading-level-by=N."
  (with-temp-buffer
    (insert input)
    (let* ((shift-arg (if (and heading-shift (numberp heading-shift)
                                (> heading-shift 0))
                          (format " --shift-heading-level-by=%d" heading-shift)
                        ""))
           (cmd (format "pandoc -f %s -t %s --wrap=preserve%s"
                        from-fmt to-fmt shift-arg))
           (exit-code (shell-command-on-region (point-min) (point-max) cmd t t)))
      (unless (zerop exit-code)
        (error "Pandoc conversion (%s -> %s) failed (exit code %d)"
               from-fmt to-fmt exit-code)))
    (buffer-string)))

;; ============================================================
;; JSON-RPC transport (stdio, newline-delimited)
;; ============================================================

(defun org-files-mcp--send (obj)
  "Send OBJ as a single-line JSON to stdout, terminated by newline."
  (let* ((json-null :null)
         (json-str (json-encode obj)))
    (princ json-str)
    (princ "\n")))

(defun org-files-mcp--respond (id result)
  "Send a success response for ID with RESULT."
  (org-files-mcp--send
   `((jsonrpc . "2.0")
     (id . ,id)
     (result . ,result))))

(defun org-files-mcp--respond-error (id code message &optional data)
  "Send an error response for ID with CODE and MESSAGE."
  (let ((err `((code . ,code) (message . ,message))))
    (when data (push `(data . ,data) err))
    (org-files-mcp--send
     `((jsonrpc . "2.0")
       (id . ,id)
       (error . ,err)))))

(defun org-files-mcp--tool-result (text)
  "Wrap TEXT as an MCP tool result."
  `((content . [((type . "text") (text . ,text))])))

(defun org-files-mcp--tool-result-json (obj)
  "Wrap OBJ (to be JSON-encoded) as an MCP tool result."
  (let ((json-null :null))
    (org-files-mcp--tool-result (json-encode obj))))

(defun org-files-mcp--tool-error (text)
  "Wrap TEXT as an MCP tool error result."
  `((content . [((type . "text") (text . ,text))])
    (isError . t)))

;; ============================================================
;; Path / target resolvers (shared across tool modules)
;; ============================================================

(defun org-files-mcp--file-in-roam-p (abs-file)
  "Return non-nil if ABS-FILE is within `org-roam-directory'."
  (and (boundp 'org-roam-directory)
       org-roam-directory
       (file-in-directory-p abs-file (expand-file-name org-roam-directory))))

(defun org-files-mcp--resolve-existing-file (file)
  "Resolve FILE (relative to `org-directory') to an absolute path for read/write.
Signals if FILE is not an org file, is inside `org-roam-directory',
or does not exist."
  (let ((abs (expand-file-name file (or org-directory default-directory))))
    (unless (string-suffix-p ".org" abs)
      (error "Not an org file (must end in .org): %s" file))
    (when (org-files-mcp--file-in-roam-p abs)
      (error "File is inside org-roam-directory (read-only via this server): %s" file))
    (unless (file-exists-p abs)
      (error "File not found: %s" file))
    abs))

(defun org-files-mcp--resolve-new-file (file)
  "Resolve FILE (relative to `org-directory') to an absolute path for a NEW file.
Signals if the path is inside `org-roam-directory', the file already
exists, the extension isn't .org, or the parent directory is missing."
  (let ((abs (expand-file-name file (or org-directory default-directory))))
    (unless (string-suffix-p ".org" abs)
      (error "New file must have .org extension: %s" file))
    (when (org-files-mcp--file-in-roam-p abs)
      (error "Target is inside org-roam-directory (read-only via this server): %s" file))
    (when (file-exists-p abs)
      (error "File already exists: %s" file))
    (unless (file-directory-p (file-name-directory abs))
      (error "Parent directory does not exist: %s" (file-name-directory abs)))
    abs))

(defun org-files-mcp--olp-to-list (olp)
  "Coerce OLP (vector or list from JSON) to a plain list."
  (cond ((null olp) nil)
        ((vectorp olp) (append olp nil))
        ((listp olp) olp)
        (t (error "olp must be a list of heading titles"))))

(defun org-files-mcp--resolve-olp (file olp)
  "Resolve (FILE, OLP) to a plain-org heading target plist.
FILE is a path relative to `org-directory'.  OLP must be a non-empty
list (or vector) of heading titles from outermost to innermost.
Returns a plist (:file ABS :point POS :level LEVEL :tags TAGS).
Signals on bad file, read-only file, empty olp, or heading not found."
  (let ((olp-list (org-files-mcp--olp-to-list olp)))
    (unless (and olp-list (> (length olp-list) 0))
      (error "olp must be a non-empty list of heading titles"))
    (let* ((abs (org-files-mcp--resolve-existing-file file))
           (marker (condition-case err
                       (org-find-olp (cons abs olp-list))
                     (error
                      (error "Heading not found: %S in %s (%s)"
                             olp-list file (error-message-string err))))))
      (unless marker
        (error "Heading not found: %S in %s" olp-list file))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char (marker-position marker))
          (list :file abs
                :point (marker-position marker)
                :level (or (org-current-level) 0)
                :tags  (or (org-get-tags nil t) '())))))))

(defun org-files-mcp--child-level (parent-level)
  "Return the heading level for a child of a node at PARENT-LEVEL.
File-level (0) children become level 1."
  (if (= parent-level 0) 1 (1+ parent-level)))

(defun org-files-mcp--archive-heading-regexp ()
  "Return a regexp matching the archive heading in the current file.
Derived from `org-archive-location'.  Returns nil if the archive
target is a separate file."
  (when (stringp org-archive-location)
    (let* ((parts (split-string org-archive-location "::" t))
           (file-part (and (string-match "^\\([^:]*\\)::" org-archive-location)
                           (match-string 1 org-archive-location)))
           (heading (cond
                     ((and (string-prefix-p "::" org-archive-location)
                           (> (length org-archive-location) 2))
                      (substring org-archive-location 2))
                     ((= (length parts) 2) (nth 1 parts))
                     (t nil))))
      (when (and heading
                 (or (null file-part) (string-empty-p file-part))
                 (not (string-empty-p heading)))
        (concat "^" (regexp-quote (string-trim heading)) "[ \t]*$")))))

;; ============================================================
;; TODO keyword utilities (used by plain-org tools)
;; ============================================================

(defun org-files-mcp--clean-keyword (kw)
  "Strip fast-access key suffix from org TODO keyword KW.
E.g., \"TODO(t)\" → \"TODO\"."
  (replace-regexp-in-string "(.*)" "" kw))

(defun org-files-mcp--all-todo-keywords ()
  "Return a flat list of all TODO keyword strings from `org-todo-keywords'."
  (let (result)
    (dolist (seq (or org-todo-keywords '((sequence "TODO" "DONE"))))
      (dolist (kw (cdr seq))
        (let ((clean (org-files-mcp--clean-keyword kw)))
          (unless (string= clean "|")
            (push clean result)))))
    (nreverse result)))

(defun org-files-mcp--next-todo-state (current-state)
  "Compute the next TODO state after CURRENT-STATE using org-todo-keywords.
Returns the next state in the cycle, or nil if CURRENT-STATE is the last."
  (let* ((keywords (mapcar (lambda (kw)
                             (org-files-mcp--clean-keyword kw))
                           (cdr (cl-find-if
                                 (lambda (seq) (member current-state (cdr seq)))
                                 (or org-todo-keywords
                                     '((sequence "TODO" "DONE")))))))
         (pos (cl-position current-state keywords :test #'equal)))
    (when pos
      (nth (1+ pos) keywords))))

;; ============================================================
;; Batch-safe agenda scanning helpers
;; ============================================================

(defun org-files-mcp--timestamp-to-iso (ts)
  "Convert an org-element timestamp TS to an ISO date string.
Returns nil if TS is nil."
  (when ts
    (let ((year  (org-element-property :year-start ts))
          (month (org-element-property :month-start ts))
          (day   (org-element-property :day-start ts)))
      (when (and year month day)
        (format "%04d-%02d-%02d" year month day)))))

(defun org-files-mcp--entry-plist-at-point (file)
  "Build an entry plist for the heading at point in FILE."
  (let* ((element (org-element-at-point))
         (heading (org-element-property :raw-value element))
         (todo    (org-element-property :todo-keyword element))
         (priority (org-element-property :priority element))
         (tags    (org-get-tags nil t))
         (sched   (org-element-property
                   :scheduled (org-element-at-point-no-context)))
         (dl      (org-element-property
                   :deadline (org-element-at-point-no-context))))
    (list :heading heading
          :file file
          :todo_state todo
          :priority (when priority (char-to-string priority))
          :tags tags
          :scheduled (org-files-mcp--timestamp-to-iso sched)
          :deadline  (org-files-mcp--timestamp-to-iso dl))))

(defun org-files-mcp--entry-plist-to-alist (plist)
  "Convert an entry PLIST to an alist suitable for JSON encoding."
  (let ((heading   (plist-get plist :heading))
        (file      (plist-get plist :file))
        (todo      (plist-get plist :todo_state))
        (priority  (plist-get plist :priority))
        (tags      (plist-get plist :tags))
        (scheduled (plist-get plist :scheduled))
        (deadline  (plist-get plist :deadline))
        (date      (plist-get plist :date)))
    `((heading    . ,(or heading ""))
      (file       . ,(or file ""))
      (todo_state . ,(or todo :null))
      (priority   . ,(or priority :null))
      (tags       . ,(vconcat (or tags [])))
      (scheduled  . ,(or scheduled :null))
      (deadline   . ,(or deadline :null))
      ,@(when date `((date . ,date))))))

(defun org-files-mcp--scan-entries-in-file (file filter-fn)
  "Scan FILE for org headings, returning entries that pass FILTER-FN."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks (org-mode))
      (let ((entries '()))
        (org-map-entries
         (lambda ()
           (let* ((plist (org-files-mcp--entry-plist-at-point file))
                  (result (funcall filter-fn plist)))
             (when result
               (push result entries)))))
        (nreverse entries)))))

(defun org-files-mcp--scan-agenda-files (filter-fn)
  "Scan all `org-agenda-files' and collect entries passing FILTER-FN."
  (let ((files (org-agenda-files t)))
    (cl-loop for file in files
             nconc (org-files-mcp--scan-entries-in-file file filter-fn))))

(defun org-files-mcp--date-in-range-p (date-str start-date end-date)
  "Return non-nil if DATE-STR (ISO format) falls within START-DATE..END-DATE."
  (when date-str
    (let ((date-time (date-to-time (concat date-str " 00:00:00"))))
      (and (not (time-less-p date-time start-date))
           (time-less-p date-time end-date)))))

(defun org-files-mcp--scan-entries-by-match (file match todo-only)
  "Scan FILE for entries matching MATCH (org-agenda match string)."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks (org-mode))
      (let ((entries '()))
        (org-map-entries
         (lambda ()
           (let ((plist (org-files-mcp--entry-plist-at-point file)))
             (when (or (not todo-only)
                       (plist-get plist :todo_state))
               (push plist entries))))
         match)
        (nreverse entries)))))

;; ============================================================
;; Load tool modules
;; ============================================================

(require 'org-files-mcp-roam)
(require 'org-files-mcp-org)

;; ============================================================
;; Tool dispatch
;; ============================================================

(defun org-files-mcp--handle-tool (name args)
  "Dispatch tool NAME with ARGS. Return MCP tool result alist."
  (condition-case err
      (pcase name
        ;; ---- Roam (read-only) ----
        ("roam_list_nodes"          (org-files-mcp--tool-roam-list-nodes args))
        ("roam_get_node"            (org-files-mcp--tool-roam-get-node args))
        ("roam_get_backlinks"       (org-files-mcp--tool-roam-get-backlinks args))
        ("roam_get_graph"           (org-files-mcp--tool-roam-get-graph args))
        ("roam_search_nodes"        (org-files-mcp--tool-roam-search-nodes args))
        ;; ---- Plain org: file-level ----
        ("org_create_file"          (org-files-mcp--tool-org-create-file args))
        ("org_delete_file"          (org-files-mcp--tool-org-delete-file args))
        ("org_rename_file"          (org-files-mcp--tool-org-rename-file args))
        ;; ---- Plain org: heading CRUD ----
        ("org_create_heading"       (org-files-mcp--tool-org-create-heading args))
        ("org_append_to_heading"    (org-files-mcp--tool-org-append-to-heading args))
        ("org_update_heading_section" (org-files-mcp--tool-org-update-heading-section args))
        ("org_delete_heading"       (org-files-mcp--tool-org-delete-heading args))
        ("org_rename_heading"       (org-files-mcp--tool-org-rename-heading args))
        ("org_refile_heading"       (org-files-mcp--tool-org-refile-heading args))
        ;; ---- Plain org: TODO / scheduling ----
        ("org_toggle_todo_state"    (org-files-mcp--tool-org-toggle-todo-state args))
        ("org_set_scheduled"        (org-files-mcp--tool-org-set-scheduled args))
        ("org_set_deadline"         (org-files-mcp--tool-org-set-deadline args))
        ("org_set_property"         (org-files-mcp--tool-org-set-property args))
        ("org_add_tag"              (org-files-mcp--tool-org-add-tag args))
        ("org_remove_tag"           (org-files-mcp--tool-org-remove-tag args))
        ;; ---- Plain org: convenience + agenda reads ----
        ("org_add_todo"             (org-files-mcp--tool-org-add-todo args))
        ("org_list_todo_keywords"   (org-files-mcp--tool-org-list-todo-keywords args))
        ("org_agenda"               (org-files-mcp--tool-org-agenda args))
        ("org_todo_list"            (org-files-mcp--tool-org-todo-list args))
        ("org_tags_view"            (org-files-mcp--tool-org-tags-view args))
        ;; ---- Unknown ----
        (_ (org-files-mcp--tool-error (format "Unknown tool: %s" name))))
    (error
     (org-files-mcp--tool-error (format "Error: %s" (error-message-string err))))))

;; ============================================================
;; Tool schemas
;; ============================================================

(defvar org-files-mcp--tool-schemas
  `[
    ;; ========================================
    ;; Roam (read-only)
    ;; ========================================
    ((name . "roam_list_nodes")
     (description . "[Roam, read-only] List nodes from the org-roam database. Returns both file nodes (level=0) and heading nodes (level>=1).")
     (inputSchema . ((type . "object")
                     (properties . ((directory . ((type . "string") (description . "Filter by directory (relative to org-roam-directory)")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (level . ((type . "integer") (description . "Filter by level (0=file, 1+=heading)")))
                                    (limit . ((type . "integer") (description . "Max results (default: 50)"))))))))
    ((name . "roam_get_node")
     (description . "[Roam, read-only] Get roam node content by ID or title. Returns markdown or org format.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID")))
                                    (title . ((type . "string") (description . "Roam node title")))
                                    (format . ((type . "string") (enum . ["org" "markdown"]) (description . "Output format (default: markdown)"))))))))
    ((name . "roam_get_backlinks")
     (description . "[Roam, read-only] Get incoming links (backlinks) for a roam node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID")))))
                     (required . ["id"]))))
    ((name . "roam_get_graph")
     (description . "[Roam, read-only] Get the link graph between roam nodes.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Origin roam node ID (omit for full graph)")))
                                    (depth . ((type . "integer") (description . "Traversal depth (default: 2)"))))))))
    ((name . "roam_search_nodes")
     (description . "[Roam, read-only] Search roam nodes by keyword and/or attributes.")
     (inputSchema . ((type . "object")
                     (properties . ((query . ((type . "string") (description . "Fulltext keyword")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (todo_state . ((type . "string") (description . "Filter by TODO state")))
                                    (level . ((type . "integer") (description . "Filter by level")))
                                    (limit . ((type . "integer") (description . "Max results (default: 20)"))))))))

    ;; ========================================
    ;; Plain org: file-level
    ;; ========================================
    ((name . "org_create_file")
     (description . "[Plain org] Create a new plain org file at a path relative to `org-directory'. Rejects if the path is inside `org-roam-directory' or if the file already exists. No `:ID:' property is written.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory (must end in .org)")))
                                    (title . ((type . "string") (description . "Optional #+title: keyword")))
                                    (tags . ((type . "array") (items . ((type . "string"))) (description . "Optional #+filetags: tags")))
                                    (body . ((type . "string") (description . "Optional body (Markdown; converted to org via Pandoc)")))))
                     (required . ["file"]))))
    ((name . "org_delete_file")
     (description . "[Plain org] Delete a plain org file. `confirm' must be true. Rejects roam files.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (confirm . ((type . "boolean") (description . "Must be true")))))
                     (required . ["file" "confirm"]))))
    ((name . "org_rename_file")
     (description . "[Plain org] Rename a plain org file on disk. Rejects if target is inside roam or already exists. Does not edit `#+title:` inside the file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Current path, relative to org-directory")))
                                    (new_file . ((type . "string") (description . "New path, relative to org-directory (must end in .org)")))))
                     (required . ["file" "new_file"]))))

    ;; ========================================
    ;; Plain org: heading CRUD
    ;; ========================================
    ((name . "org_create_heading")
     (description . "[Plain org] Create a new heading in a plain org file. If `parent_olp' is omitted, inserts as a top-level heading at end of file (before any archive section). No `:ID:' generated.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (parent_olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path of the parent heading; omit for top-level")))
                                    (heading . ((type . "string") (description . "Heading text")))
                                    (state . ((type . "string") (description . "Optional TODO state keyword")))
                                    (priority . ((type . "string") (enum . ["A" "B" "C"]) (description . "Optional priority")))
                                    (tags . ((type . "array") (items . ((type . "string"))) (description . "Optional heading tags")))
                                    (properties . ((type . "array") (description . "Optional property alist [[name,value],...]")))
                                    (body . ((type . "string") (description . "Optional body (Markdown)")))))
                     (required . ["file" "heading"]))))
    ((name . "org_append_to_heading")
     (description . "[Plain org] Append Markdown body to the end of a heading's subtree.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (body . ((type . "string") (description . "Content (Markdown)")))))
                     (required . ["file" "olp" "body"]))))
    ((name . "org_update_heading_section")
     (description . "[Plain org] Update the body text of a heading (replace/append/prepend).")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (body . ((type . "string") (description . "New content (Markdown)")))
                                    (mode . ((type . "string") (enum . ["replace" "append" "prepend"]) (description . "Default: replace")))))
                     (required . ["file" "olp" "body"]))))
    ((name . "org_delete_heading")
     (description . "[Plain org] Cut a heading and its subtree. `confirm' must be true.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (confirm . ((type . "boolean") (description . "Must be true")))))
                     (required . ["file" "olp" "confirm"]))))
    ((name . "org_rename_heading")
     (description . "[Plain org] Change a heading's title via `org-edit-headline'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (new_title . ((type . "string") (description . "New heading text")))))
                     (required . ["file" "olp" "new_title"]))))
    ((name . "org_refile_heading")
     (description . "[Plain org] Cut a heading subtree and paste it under another heading (or at top level of target file).")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Source file, relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Source outline path (non-empty)")))
                                    (target_file . ((type . "string") (description . "Target file, relative to org-directory")))
                                    (target_parent_olp . ((type . "array") (items . ((type . "string"))) (description . "Target parent outline path; omit for top-level of target file")))))
                     (required . ["file" "olp" "target_file"]))))

    ;; ========================================
    ;; Plain org: TODO / scheduling / property / tag
    ;; ========================================
    ((name . "org_toggle_todo_state")
     (description . "[Plain org] Change a heading's TODO state. Omit `new_state' to cycle to the next state.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (new_state . ((type . "string") (description . "New TODO state keyword (optional)")))))
                     (required . ["file" "olp"]))))
    ((name . "org_set_scheduled")
     (description . "[Plain org] Set or remove SCHEDULED on a heading. Uses `org-schedule'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (date . ((type . "string") (description . "ISO 8601 date; empty string to remove")))))
                     (required . ["file" "olp" "date"]))))
    ((name . "org_set_deadline")
     (description . "[Plain org] Set or remove DEADLINE on a heading. Uses `org-deadline'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (date . ((type . "string") (description . "ISO 8601 date; empty string to remove")))))
                     (required . ["file" "olp" "date"]))))
    ((name . "org_set_property")
     (description . "[Plain org] Set a property on a heading via `org-set-property'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (name . ((type . "string") (description . "Property name")))
                                    (value . ((type . "string") (description . "Property value")))))
                     (required . ["file" "olp" "name" "value"]))))
    ((name . "org_add_tag")
     (description . "[Plain org] Add a tag to a heading via `org-set-tags'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (tag . ((type . "string") (description . "Tag to add")))))
                     (required . ["file" "olp" "tag"]))))
    ((name . "org_remove_tag")
     (description . "[Plain org] Remove a tag from a heading.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (tag . ((type . "string") (description . "Tag to remove")))))
                     (required . ["file" "olp" "tag"]))))

    ;; ========================================
    ;; Plain org: convenience + agenda
    ;; ========================================
    ((name . "org_add_todo")
     (description . "[Plain org] Convenience wrapper around `org_create_heading' for TODO items. Defaults the target file to `org-default-notes-file' and the state to TODO. Supports scheduled/deadline/priority in one call.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; default: org-default-notes-file")))
                                    (parent_olp . ((type . "array") (items . ((type . "string"))) (description . "Parent heading outline path; omit for top-level")))
                                    (heading . ((type . "string") (description . "Heading text")))
                                    (state . ((type . "string") (description . "TODO state keyword (default: TODO)")))
                                    (priority . ((type . "string") (enum . ["A" "B" "C"])))
                                    (tags . ((type . "array") (items . ((type . "string")))))
                                    (scheduled . ((type . "string") (description . "ISO 8601 date")))
                                    (deadline . ((type . "string") (description . "ISO 8601 date")))
                                    (body . ((type . "string") (description . "Body (Markdown)")))))
                     (required . ["heading"]))))
    ((name . "org_list_todo_keywords")
     (description . "[Plain org] List configured TODO keyword sequences and their states.")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table)))))
    ((name . "org_agenda")
     (description . "[Plain org] Date-based agenda view for scheduled/deadline items over the next N days. Scans `org-agenda-files'.")
     (inputSchema . ((type . "object")
                     (properties . ((span . ((type . "integer") (description . "Number of days (default: 7)"))))))))
    ((name . "org_todo_list")
     (description . "[Plain org] List TODO items across `org-agenda-files', optionally filtered by keyword.")
     (inputSchema . ((type . "object")
                     (properties . ((match . ((type . "string") (description . "TODO keyword filter (pipe-separated for multiple)"))))))))
    ((name . "org_tags_view")
     (description . "[Plain org] Search `org-agenda-files' by tag/property match string (e.g. \"+work-done\").")
     (inputSchema . ((type . "object")
                     (properties . ((match . ((type . "string") (description . "Match string (e.g. '+work-done')")))
                                    (todo_only . ((type . "boolean") (description . "Only TODO items")))))
                     (required . ["match"]))))
    ]
  "Tool schemas for tools/list response.")

;; ============================================================
;; MCP protocol handler
;; ============================================================

(defun org-files-mcp--handle-message (msg)
  "Handle a parsed JSON-RPC MSG (alist)."
  (let* ((id (alist-get 'id msg))
         (method (alist-get 'method msg))
         (params (or (alist-get 'params msg) '())))
    (org-files-mcp--log "Received: method=%s id=%s" method id)
    (pcase method
      ("initialize"
       (org-files-mcp--respond id
        `((protocolVersion . ,org-files-mcp--protocol-version)
          (capabilities . ((tools . ((listChanged . :json-false)))))
          (serverInfo . ((name . ,org-files-mcp--server-name)
                         (version . ,org-files-mcp--server-version))))))
      ("notifications/initialized"
       (org-files-mcp--log "Client initialized"))
      ("ping"
       (org-files-mcp--respond id '()))
      ("tools/list"
       (org-files-mcp--respond id
        `((tools . ,org-files-mcp--tool-schemas))))
      ("tools/call"
       (let* ((tool-name (alist-get 'name params))
              (tool-args (or (alist-get 'arguments params) '()))
              (result (org-files-mcp--handle-tool tool-name tool-args)))
         (org-files-mcp--respond id result)))
      (_
       (if id
           (org-files-mcp--respond-error id -32601
            (format "Method not found: %s" method))
         (org-files-mcp--log "Ignoring unknown notification: %s" method))))))

;; ============================================================
;; Main loop
;; ============================================================

(defun org-files-mcp-start ()
  "Start the MCP server, reading from stdin and writing to stdout.
Intended for use with `emacs --batch`."
  (org-files-mcp--log "Starting %s v%s" org-files-mcp--server-name org-files-mcp--server-version)
  (org-files-mcp--log "org-directory: %s" org-directory)
  (org-files-mcp--log "org-roam-directory: %s" org-roam-directory)
  (org-files-mcp--check-pandoc)
  (org-files-mcp--log "Pandoc found: %s" (executable-find "pandoc"))
  (org-roam-db-sync)
  (org-files-mcp--log "DB synced. Entering main loop.")
  (let ((line nil))
    (while (setq line (ignore-errors (read-from-minibuffer "")))
      (unless (string-empty-p (string-trim line))
        (condition-case err
            (let* ((json-object-type 'alist)
                   (json-array-type 'vector)
                   (json-key-type 'symbol)
                   (msg (json-read-from-string line)))
              (org-files-mcp--handle-message msg))
          (error
           (org-files-mcp--log "Parse error: %s" (error-message-string err))))))))

(provide 'org-files-mcp)

;;; org-files-mcp.el ends here
