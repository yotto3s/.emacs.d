;;; org-files-mcp.el --- MCP server for org files and org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1") (org-roam "2.2.2"))
;; Keywords: org, org-roam, mcp, ai

;;; Commentary:

;; An MCP (Model Context Protocol) server that runs inside Emacs,
;; providing AI agents with structured access to the user's org files.
;;
;; Access model (split by intent, not by location):
;;   - `roam_*' tools own general org file editing and searching.
;;     Roam nodes are addressed by id or title; content, tags, and
;;     properties can be read and mutated.
;;   - `org_*'  tools own TODO management.  They only accept files
;;     that are members of `org-agenda-files' (currently just
;;     `inbox.org').  Refile.org, archive files, and roam files are
;;     rejected at the resolver layer.
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
;;   org-files-mcp-roam.el  — roam_* read + write tools
;;   org-files-mcp-org.el   — org_*  TODO-management tools (agenda files)

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
(defconst org-files-mcp--server-version "0.5.1")
(defconst org-files-mcp--protocol-version "2024-11-05")

(defconst org-files-mcp--ai-tag "ai_generated"
  "Tag applied by content-creating MCP writes to mark AI-authored content.
Added by `roam_create_node', `roam_append_to_node',
`roam_update_node_body', and `org_add_todo'.  `roam_remove_tag' and
`org_remove_tag' refuse to remove it.")

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

(defun org-files-mcp--olp-to-list (olp)
  "Coerce OLP (vector or list from JSON) to a plain list."
  (cond ((null olp) nil)
        ((vectorp olp) (append olp nil))
        ((listp olp) olp)
        (t (error "olp must be a list of heading titles"))))

(defun org-files-mcp--child-level (parent-level)
  "Return the heading level for a child of a node at PARENT-LEVEL.
File-level (0) children become level 1."
  (if (= parent-level 0) 1 (1+ parent-level)))

;; ============================================================
;; Agenda-file resolvers (TODO tools use these)
;; ============================================================

(defun org-files-mcp--agenda-files-absolute ()
  "Return `org-agenda-files' as a list of absolute, canonicalized paths."
  (mapcar (lambda (f) (expand-file-name f))
          (org-agenda-files t)))

(defun org-files-mcp--resolve-agenda-file (file)
  "Resolve FILE and verify it is a member of `org-agenda-files'.
FILE may be either a path relative to `org-directory' or an absolute
path.  Signals if the resolved file is not in `org-agenda-files'."
  (let* ((abs (expand-file-name file (or org-directory default-directory)))
         (agenda (org-files-mcp--agenda-files-absolute)))
    (unless (string-suffix-p ".org" abs)
      (error "Not an org file (must end in .org): %s" file))
    (unless (member abs agenda)
      (error "File is not in `org-agenda-files' (TODO tools only operate on agenda files): %s"
             file))
    (unless (file-exists-p abs)
      (error "File not found: %s" file))
    abs))

(defun org-files-mcp--resolve-olp-agenda (file olp)
  "Like `--resolve-olp' but requires FILE to be in `org-agenda-files'.
Returns a plist (:file ABS :point POS :level LEVEL :tags TAGS)."
  (let ((olp-list (org-files-mcp--olp-to-list olp)))
    (unless (and olp-list (> (length olp-list) 0))
      (error "olp must be a non-empty list of heading titles"))
    (let* ((abs (org-files-mcp--resolve-agenda-file file))
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
;; Roam write helpers (shared by roam_* write tools)
;; ============================================================

(defun org-files-mcp--roam-resolve-node (id title)
  "Resolve a roam node by ID or TITLE, returning an `org-roam-node' struct.
Signals if neither is provided or the node does not exist."
  (cond
   (id
    (or (org-roam-node-from-id id)
        (error "Roam node not found: %s" id)))
   (title
    (let ((rows (org-roam-db-query
                 [:select [id] :from nodes
                  :where (= title $s1)
                  :limit 1]
                 title)))
      (if rows
          (or (org-roam-node-from-id (caar rows))
              (error "Roam node not found after DB hit: %s" title))
        (error "Roam node not found with title: %s" title))))
   (t (error "Either id or title is required"))))

(defun org-files-mcp--roam-after-write (abs-file)
  "Refresh the roam DB entry for ABS-FILE after a write."
  (when (and (boundp 'org-roam-directory) org-roam-directory
             (file-in-directory-p abs-file
                                  (expand-file-name org-roam-directory)))
    (condition-case err
        (org-roam-db-update-file abs-file)
      (error
       (org-files-mcp--log "WARNING: org-roam-db-update-file failed for %s: %s"
                           abs-file (error-message-string err))))))

(defun org-files-mcp--slugify (title)
  "Return a filesystem-safe slug for TITLE."
  (let* ((s (downcase (or title "")))
         (s (replace-regexp-in-string "[^a-z0-9]+" "_" s))
         (s (replace-regexp-in-string "\\`_+\\|_+\\'" "" s)))
    (if (string-empty-p s) "untitled" s)))

(defun org-files-mcp--roam-new-filename (title &optional override)
  "Return an absolute path for a new roam node with TITLE.
If OVERRIDE is provided, use that (as a relative name inside
`org-roam-directory').  Otherwise auto-generate `YYYYMMDDHHMMSS-slug.org'."
  (let* ((dir (expand-file-name org-roam-directory))
         (rel (or override
                  (format "%s-%s.org"
                          (format-time-string "%Y%m%d%H%M%S")
                          (org-files-mcp--slugify title))))
         (abs (expand-file-name rel dir)))
    (unless (string-suffix-p ".org" abs)
      (error "New roam filename must end in .org: %s" rel))
    (unless (file-in-directory-p abs dir)
      (error "New roam filename escapes org-roam-directory: %s" rel))
    (when (file-exists-p abs)
      (error "Roam file already exists: %s" rel))
    abs))

(defun org-files-mcp--roam-file-header-end ()
  "Move point past the leading file header block in the current buffer.
A file header consists of the top-level `:PROPERTIES: … :END:' drawer
followed by any contiguous `#+KEY:' keyword lines and blank lines.
After return, point is at the start of the first body line (or eob)."
  (goto-char (point-min))
  ;; Skip top-level PROPERTIES drawer if present
  (when (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$")
    (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
      (forward-line 1)))
  ;; Skip contiguous #+KEYWORD: lines and blank lines
  (while (and (not (eobp))
              (looking-at-p "^\\(#\\+[^:\n]+:.*\\|[ \t]*\\)$")
              (not (looking-at-p "^\\*")))
    (forward-line 1)))

(defun org-files-mcp--roam-file-filetags-parse (line)
  "Parse a `#+filetags:' LINE value into a list of tag strings.
LINE is the text AFTER `#+filetags:'.  Handles both `:a:b:c:' and space
separated forms."
  (let* ((val (string-trim line)))
    (cond
     ((string-empty-p val) nil)
     ((string-match-p "^:.*:$" val)
      (split-string val ":" t))
     (t (split-string val "[ \t]+" t)))))

(defun org-files-mcp--roam-file-filetags-format (tags)
  "Format TAGS as a `#+filetags:' value in `:a:b:' form."
  (if (null tags) ""
    (concat ":" (mapconcat #'identity tags ":") ":")))

(defun org-files-mcp--roam-file-filetags-edit (op tag)
  "Add or remove TAG in the current buffer's `#+filetags:' line.
OP is either `add' or `remove'.  Inserts the keyword line after the
top header block if absent.  Assumes the buffer is already visiting
the target file and will be saved by the caller."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^[ \t]*#\\+filetags:[ \t]*\\(.*\\)$" nil t)
        (let* ((line-start (match-beginning 0))
               (line-end (match-end 0))
               (val (match-string 1))
               (tags (org-files-mcp--roam-file-filetags-parse val))
               (new-tags (pcase op
                           ('add (if (member tag tags) tags
                                   (append tags (list tag))))
                           ('remove (delete tag (copy-sequence tags)))
                           (_ (error "Invalid op: %S" op)))))
          (delete-region line-start line-end)
          (goto-char line-start)
          (if new-tags
              (insert "#+filetags: "
                      (org-files-mcp--roam-file-filetags-format new-tags))
            ;; If we emptied the tag set, drop the line entirely.
            (when (looking-at-p "\n") (delete-char 1))))
      ;; No existing filetags line — only meaningful for `add'.
      (when (eq op 'add)
        (org-files-mcp--roam-file-header-end)
        ;; Insert just before the first body line.  Place on its own
        ;; line, above any blank line that already separates header
        ;; from body.
        (goto-char (line-beginning-position))
        (insert "#+filetags: "
                (org-files-mcp--roam-file-filetags-format (list tag))
                "\n")))))

(defun org-files-mcp--mark-file-ai-generated ()
  "Ensure the current buffer's `#+filetags:' contains `org-files-mcp--ai-tag'.
Buffer must be visiting the target file; caller is responsible for
saving.  Idempotent: no-op if the tag is already present."
  (save-excursion
    (widen)
    (org-files-mcp--roam-file-filetags-edit 'add org-files-mcp--ai-tag)))

(defun org-files-mcp--replace-subtree-body-at-point (org-body mode)
  "Replace the body of the org subtree at point with ORG-BODY.
MODE is \"replace\", \"append\", or \"prepend\".  Assumes point is at
the heading line.  Body is the region between `org-end-of-meta-data'
and the next heading or eob.  Does NOT save the buffer."
  (save-restriction
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

(defun org-files-mcp--replace-file-body (org-body mode)
  "Replace file-level body (below header block) of the current buffer.
MODE is \"replace\", \"append\", or \"prepend\".  The header block is
anything skipped by `--roam-file-header-end'.  Does NOT save the buffer."
  (save-excursion
    (org-files-mcp--roam-file-header-end)
    (let ((body-start (point))
          (body-end (point-max)))
      (pcase mode
        ("replace"
         (delete-region body-start body-end)
         (goto-char body-start)
         (insert org-body)
         (unless (string-suffix-p "\n" org-body) (insert "\n")))
        ("append"
         (goto-char body-end)
         (unless (bolp) (insert "\n"))
         (insert org-body)
         (unless (string-suffix-p "\n" org-body) (insert "\n")))
        ("prepend"
         (goto-char body-start)
         (insert org-body)
         (unless (string-suffix-p "\n" org-body) (insert "\n")))
        (_ (error "Invalid mode: '%s'" mode))))))

(defun org-files-mcp--roam-file-level-property-edit (op name &optional value)
  "Edit a property on the file-level PROPERTIES drawer of the current buffer.
OP is `set' or `remove'.  For `set' pass VALUE.  Rejects NAME = \"ID\"."
  (when (equal (upcase name) "ID")
    (error "Refusing to modify :ID: on a roam node"))
  (save-excursion
    (goto-char (point-min))
    (cond
     ;; No drawer at all
     ((not (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$"))
      (pcase op
        ('set
         (goto-char (point-min))
         (insert ":PROPERTIES:\n:" name ": " value "\n:END:\n"))
        ('remove nil)))
     ;; Drawer present — walk its lines
     (t
      (let* ((drawer-end-line
              (save-excursion
                (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                (line-beginning-position)))
             (prop-re (format "^[ \t]*:%s:[ \t]+\\(.*\\)$" (regexp-quote name))))
        (forward-line 1)
        (let ((found nil))
          (while (and (not found) (< (point) drawer-end-line))
            (if (looking-at prop-re)
                (setq found (point))
              (forward-line 1)))
          (pcase op
            ('set
             (if found
                 (progn
                   (delete-region (line-beginning-position) (line-end-position))
                   (insert ":" name ": " value))
               (goto-char drawer-end-line)
               (insert ":" name ": " value "\n")))
            ('remove
             (when found
               (goto-char found)
               (delete-region (line-beginning-position)
                              (progn (forward-line 1) (point))))))))))))

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

;; Ensure the submodules in this file's directory are findable even
;; when the server is launched via `emacs -l /absolute/path/org-files-mcp.el'
;; (which does not automatically add the directory to `load-path').
(let ((this-dir (file-name-directory
                 (or load-file-name buffer-file-name
                     (locate-library "org-files-mcp")))))
  (when this-dir
    (add-to-list 'load-path this-dir)))

(require 'org-files-mcp-roam)
(require 'org-files-mcp-org)

;; ============================================================
;; Tool dispatch
;; ============================================================

(defun org-files-mcp--handle-tool (name args)
  "Dispatch tool NAME with ARGS. Return MCP tool result alist."
  (condition-case err
      (pcase name
        ;; ---- Roam: read ----
        ("roam_list_nodes"          (org-files-mcp--tool-roam-list-nodes args))
        ("roam_get_node"            (org-files-mcp--tool-roam-get-node args))
        ("roam_get_backlinks"       (org-files-mcp--tool-roam-get-backlinks args))
        ("roam_get_graph"           (org-files-mcp--tool-roam-get-graph args))
        ("roam_search_nodes"        (org-files-mcp--tool-roam-search-nodes args))
        ;; ---- Roam: content write ----
        ("roam_create_node"         (org-files-mcp--tool-roam-create-node args))
        ("roam_append_to_node"      (org-files-mcp--tool-roam-append-to-node args))
        ("roam_update_node_body"    (org-files-mcp--tool-roam-update-node-body args))
        ;; ---- Roam: metadata write ----
        ("roam_add_tag"             (org-files-mcp--tool-roam-add-tag args))
        ("roam_remove_tag"          (org-files-mcp--tool-roam-remove-tag args))
        ("roam_set_property"        (org-files-mcp--tool-roam-set-property args))
        ("roam_remove_property"     (org-files-mcp--tool-roam-remove-property args))
        ;; ---- Plain org: TODO management (agenda files only) ----
        ("org_add_todo"             (org-files-mcp--tool-org-add-todo args))
        ("org_toggle_todo_state"    (org-files-mcp--tool-org-toggle-todo-state args))
        ("org_set_scheduled"        (org-files-mcp--tool-org-set-scheduled args))
        ("org_set_deadline"         (org-files-mcp--tool-org-set-deadline args))
        ("org_set_property"         (org-files-mcp--tool-org-set-property args))
        ("org_add_tag"              (org-files-mcp--tool-org-add-tag args))
        ("org_remove_tag"           (org-files-mcp--tool-org-remove-tag args))
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
    ;; Roam: read tools
    ;; ========================================
    ((name . "roam_list_nodes")
     (description . "[Roam] List nodes from the org-roam database. Returns both file nodes (level=0) and heading nodes (level>=1).")
     (inputSchema . ((type . "object")
                     (properties . ((directory . ((type . "string") (description . "Filter by directory (relative to org-roam-directory)")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (level . ((type . "integer") (description . "Filter by level (0=file, 1+=heading)")))
                                    (limit . ((type . "integer") (description . "Max results (default: 50)"))))))))
    ((name . "roam_get_node")
     (description . "[Roam] Get roam node content by ID or title. Returns markdown or org format.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID")))
                                    (title . ((type . "string") (description . "Roam node title")))
                                    (format . ((type . "string") (enum . ["org" "markdown"]) (description . "Output format (default: markdown)"))))))))
    ((name . "roam_get_backlinks")
     (description . "[Roam] Get incoming links (backlinks) for a roam node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID")))))
                     (required . ["id"]))))
    ((name . "roam_get_graph")
     (description . "[Roam] Get the link graph between roam nodes.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Origin roam node ID (omit for full graph)")))
                                    (depth . ((type . "integer") (description . "Traversal depth (default: 2)"))))))))
    ((name . "roam_search_nodes")
     (description . "[Roam] Search roam nodes by keyword and/or attributes.")
     (inputSchema . ((type . "object")
                     (properties . ((query . ((type . "string") (description . "Fulltext keyword")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (todo_state . ((type . "string") (description . "Filter by TODO state")))
                                    (level . ((type . "integer") (description . "Filter by level")))
                                    (limit . ((type . "integer") (description . "Max results (default: 20)"))))))))

    ;; ========================================
    ;; Roam: content write tools
    ;; ========================================
    ((name . "roam_create_node")
     (description . "[Roam] Create a new file-level roam node under `org-roam-directory'. Generates a fresh `:ID:' and writes `#+title:' and optional `#+filetags:'. The filename defaults to `YYYYMMDDHHMMSS-<slug>.org'.")
     (inputSchema . ((type . "object")
                     (properties . ((title . ((type . "string") (description . "Node title (required)")))
                                    (tags . ((type . "array") (items . ((type . "string"))) (description . "Filetags for the new node")))
                                    (body . ((type . "string") (description . "Initial body content (Markdown; converted via Pandoc)")))
                                    (filename . ((type . "string") (description . "Optional override filename (relative to org-roam-directory, must end in .org)")))))
                     (required . ["title"]))))
    ((name . "roam_append_to_node")
     (description . "[Roam] Append Markdown content to an existing roam node. For file-level nodes the content is appended to end of file; for heading-level nodes, to the end of the subtree.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (body . ((type . "string") (description . "Content to append (Markdown)")))))
                     (required . ["body"]))))
    ((name . "roam_update_node_body")
     (description . "[Roam] Replace (or append/prepend) the body of a roam node. For file-level nodes the header block (PROPERTIES, #+title, #+filetags) is preserved; only content below it is affected.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (body . ((type . "string") (description . "New body content (Markdown)")))
                                    (mode . ((type . "string") (enum . ["replace" "append" "prepend"]) (description . "Default: replace")))))
                     (required . ["body"]))))

    ;; ========================================
    ;; Roam: metadata write tools
    ;; ========================================
    ((name . "roam_add_tag")
     (description . "[Roam] Add a tag to a roam node. Edits `#+filetags:' for file-level nodes or the heading tags for heading-level nodes. Idempotent.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (tag . ((type . "string") (description . "Tag to add")))))
                     (required . ["tag"]))))
    ((name . "roam_remove_tag")
     (description . "[Roam] Remove a tag from a roam node. Idempotent (no-op if the tag is absent).")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (tag . ((type . "string") (description . "Tag to remove")))))
                     (required . ["tag"]))))
    ((name . "roam_set_property")
     (description . "[Roam] Set a property on a roam node's PROPERTIES drawer. File-level nodes use the top-of-file drawer (containing :ID:); heading-level nodes use the heading's drawer. Rejects the reserved `ID' name.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (name . ((type . "string") (description . "Property name")))
                                    (value . ((type . "string") (description . "Property value")))))
                     (required . ["name" "value"]))))
    ((name . "roam_remove_property")
     (description . "[Roam] Remove a property from a roam node's PROPERTIES drawer. Rejects the reserved `ID' name.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Roam node ID (preferred)")))
                                    (title . ((type . "string") (description . "Roam node title (used if id omitted)")))
                                    (name . ((type . "string") (description . "Property name")))))
                     (required . ["name"]))))

    ;; ========================================
    ;; Plain org: TODO management (agenda files only)
    ;; ========================================
    ((name . "org_add_todo")
     (description . "[Agenda] Create a TODO heading in an agenda file. Defaults the target file to `org-default-notes-file' (if it is in `org-agenda-files') and the state to TODO. Supports scheduled/deadline/priority in one call. File must be in `org-agenda-files'.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files. Default: org-default-notes-file")))
                                    (parent_olp . ((type . "array") (items . ((type . "string"))) (description . "Parent heading outline path; omit for top-level")))
                                    (heading . ((type . "string") (description . "Heading text")))
                                    (state . ((type . "string") (description . "TODO state keyword (default: TODO)")))
                                    (priority . ((type . "string") (enum . ["A" "B" "C"])))
                                    (tags . ((type . "array") (items . ((type . "string")))))
                                    (scheduled . ((type . "string") (description . "ISO 8601 date")))
                                    (deadline . ((type . "string") (description . "ISO 8601 date")))
                                    (body . ((type . "string") (description . "Body (Markdown)")))))
                     (required . ["heading"]))))
    ((name . "org_toggle_todo_state")
     (description . "[Agenda] Change a heading's TODO state in an agenda file. Omit `new_state' to cycle to the next state.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (new_state . ((type . "string") (description . "New TODO state keyword (optional)")))))
                     (required . ["file" "olp"]))))
    ((name . "org_set_scheduled")
     (description . "[Agenda] Set or remove SCHEDULED on a heading in an agenda file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (date . ((type . "string") (description . "ISO 8601 date; empty string to remove")))))
                     (required . ["file" "olp" "date"]))))
    ((name . "org_set_deadline")
     (description . "[Agenda] Set or remove DEADLINE on a heading in an agenda file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (date . ((type . "string") (description . "ISO 8601 date; empty string to remove")))))
                     (required . ["file" "olp" "date"]))))
    ((name . "org_set_property")
     (description . "[Agenda] Set a property on a heading in an agenda file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (name . ((type . "string") (description . "Property name")))
                                    (value . ((type . "string") (description . "Property value")))))
                     (required . ["file" "olp" "name" "value"]))))
    ((name . "org_add_tag")
     (description . "[Agenda] Add a tag to a heading in an agenda file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (tag . ((type . "string") (description . "Tag to add")))))
                     (required . ["file" "olp" "tag"]))))
    ((name . "org_remove_tag")
     (description . "[Agenda] Remove a tag from a heading in an agenda file.")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string") (description . "Path relative to org-directory; must be in org-agenda-files")))
                                    (olp . ((type . "array") (items . ((type . "string"))) (description . "Outline path (non-empty)")))
                                    (tag . ((type . "string") (description . "Tag to remove")))))
                     (required . ["file" "olp" "tag"]))))
    ((name . "org_list_todo_keywords")
     (description . "[Agenda] List configured TODO keyword sequences and their states.")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table)))))
    ((name . "org_agenda")
     (description . "[Agenda] Date-based agenda view for scheduled/deadline items over the next N days. Scans `org-agenda-files' directly (batch-safe, does not use `org-agenda').")
     (inputSchema . ((type . "object")
                     (properties . ((span . ((type . "integer") (description . "Number of days (default: 7)"))))))))
    ((name . "org_todo_list")
     (description . "[Agenda] List TODO items across `org-agenda-files', optionally filtered by keyword.")
     (inputSchema . ((type . "object")
                     (properties . ((match . ((type . "string") (description . "TODO keyword filter (pipe-separated for multiple)"))))))))
    ((name . "org_tags_view")
     (description . "[Agenda] Search `org-agenda-files' by tag/property match string (e.g. \"+work-done\").")
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
