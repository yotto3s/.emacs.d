;;; org-roam-mcp.el --- MCP server for org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org-roam "2.2.2"))
;; Keywords: org-roam, mcp, ai

;;; Commentary:

;; An MCP (Model Context Protocol) server that runs inside Emacs,
;; providing AI agents with structured access to org-roam.
;;
;; Transport: stdio (newline-delimited JSON-RPC 2.0)
;; Protocol: MCP 2025-06-18
;;
;; Usage:
;;   emacs --batch -l ~/.emacs.d/init.el -l org-roam-mcp.el \
;;         -f org-roam-mcp-start
;;
;; All tool names use the `org_roam_` prefix to avoid conflicts
;; with other MCP servers.

;;; Code:

(require 'org-roam)
(require 'org-roam-dailies)
(require 'org-id)
(require 'org-agenda)
(require 'json)
(require 'cl-lib)

;; ============================================================
;; Configuration
;; ============================================================

(defgroup org-roam-mcp nil
  "MCP server for org-roam."
  :group 'org-roam)

(defcustom org-roam-mcp-default-limit 50
  "Default limit for list operations."
  :type 'integer
  :group 'org-roam-mcp)

(defconst org-roam-mcp--server-name "org-roam-mcp")
(defconst org-roam-mcp--server-version "0.1.0")
(defconst org-roam-mcp--protocol-version "2024-11-05")

;; ============================================================
;; Logging (stderr only — stdout is the transport)
;; ============================================================

(defun org-roam-mcp--log (fmt &rest args)
  "Log FMT with ARGS to stderr."
  (let ((msg (apply #'format fmt args)))
    (princ (concat "[org-roam-mcp] " msg "\n") #'external-debugging-output)))

;; ============================================================
;; Markdown → Org conversion (Pandoc required)
;; ============================================================

(defun org-roam-mcp--check-pandoc ()
  "Verify Pandoc is available. Signal error if not found."
  (unless (executable-find "pandoc")
    (error "Pandoc is required but not found in PATH. Install it: https://pandoc.org/installing.html")))

(defun org-roam-mcp--md-to-org (md-string)
  "Convert Markdown MD-STRING to org format using Pandoc."
  (org-roam-mcp--pandoc-convert md-string "markdown" "org"))

(defun org-roam-mcp--pandoc-convert (input from-fmt to-fmt)
  "Convert INPUT string from FROM-FMT to TO-FMT via pandoc."
  (with-temp-buffer
    (insert input)
    (let ((exit-code (shell-command-on-region
                      (point-min) (point-max)
                      (format "pandoc -f %s -t %s --wrap=preserve" from-fmt to-fmt)
                      t t)))
      (unless (zerop exit-code)
        (error "Pandoc conversion (%s -> %s) failed (exit code %d)"
               from-fmt to-fmt exit-code)))
    (buffer-string)))

;; ============================================================
;; JSON-RPC transport (stdio, newline-delimited)
;; ============================================================

(defun org-roam-mcp--send (obj)
  "Send OBJ as a single-line JSON to stdout, terminated by newline."
  (let ((json-str (json-encode obj)))
    (princ json-str)
    (princ "\n")))

(defun org-roam-mcp--respond (id result)
  "Send a success response for ID with RESULT."
  (org-roam-mcp--send
   `((jsonrpc . "2.0")
     (id . ,id)
     (result . ,result))))

(defun org-roam-mcp--respond-error (id code message &optional data)
  "Send an error response for ID with CODE and MESSAGE."
  (let ((err `((code . ,code) (message . ,message))))
    (when data (push `(data . ,data) err))
    (org-roam-mcp--send
     `((jsonrpc . "2.0")
       (id . ,id)
       (error . ,err)))))

(defun org-roam-mcp--tool-result (text)
  "Wrap TEXT as an MCP tool result."
  `((content . [((type . "text") (text . ,text))])))

(defun org-roam-mcp--tool-result-json (obj)
  "Wrap OBJ (to be JSON-encoded) as an MCP tool result."
  (org-roam-mcp--tool-result (json-encode obj)))

(defun org-roam-mcp--tool-error (text)
  "Wrap TEXT as an MCP tool error result."
  `((content . [((type . "text") (text . ,text))])
    (isError . t)))

;; ============================================================
;; Node helpers
;; ============================================================

(defun org-roam-mcp--node-to-alist (node)
  "Convert org-roam NODE struct to alist."
  `((id . ,(org-roam-node-id node))
    (title . ,(or (org-roam-node-title node) ""))
    (file . ,(or (org-roam-node-file node) ""))
    (level . ,(or (org-roam-node-level node) 0))
    (tags . ,(or (org-roam-node-tags node) []))
    (todo . ,(or (org-roam-node-todo node) :null))
    (priority . ,(or (org-roam-node-priority node) :null))))

(defun org-roam-mcp--require-node (id)
  "Return org-roam node for ID, or signal error string."
  (or (org-roam-node-from-id id)
      (error "Node not found: %s" id)))

(defun org-roam-mcp--child-level (parent-level)
  "Return the heading level for a child of a node at PARENT-LEVEL.
File-level (0) children become level 1."
  (if (= parent-level 0) 1 (1+ parent-level)))

(defun org-roam-mcp--get-node-content (node format-type)
  "Get content of NODE in FORMAT-TYPE (\"org\" or \"markdown\")."
  (let* ((file (org-roam-node-file node))
         (level (org-roam-node-level node)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (goto-char (org-roam-node-point node))
          (if (> level 0)
              (org-narrow-to-subtree)
            (widen))
          (let ((content (buffer-substring-no-properties
                          (point-min) (point-max))))
            (if (string= format-type "org")
                content
              ;; org → markdown via pandoc
              (condition-case err
                  (org-roam-mcp--pandoc-convert content "org" "markdown")
                (error
                 (org-roam-mcp--log "WARNING: pandoc org->markdown failed: %s, returning raw org"
                                    (error-message-string err))
                 content)))))))))

(defun org-roam-mcp--save-and-sync (file)
  "Save buffer visiting FILE and update org-roam DB."
  (when-let ((buf (find-buffer-visiting file)))
    (with-current-buffer buf (save-buffer)))
  (org-roam-db-update-file file))

;; ============================================================
;; Tool dispatch table
;; ============================================================

(defun org-roam-mcp--handle-tool (name args)
  "Dispatch tool NAME with ARGS. Return MCP tool result alist."
  (condition-case err
      (pcase name
        ;; ---- Read ----
        ("org_roam_list_nodes"        (org-roam-mcp--tool-list-nodes args))
        ("org_roam_get_node"          (org-roam-mcp--tool-get-node args))
        ("org_roam_get_backlinks"     (org-roam-mcp--tool-get-backlinks args))
        ("org_roam_get_graph"         (org-roam-mcp--tool-get-graph args))
        ("org_roam_search_nodes"      (org-roam-mcp--tool-search-nodes args))
        ;; ---- Create/Edit ----
        ("org_roam_create_node"       (org-roam-mcp--tool-create-node args))
        ("org_roam_append_to_node"    (org-roam-mcp--tool-append-to-node args))
        ("org_roam_update_node_section" (org-roam-mcp--tool-update-node-section args))
        ("org_roam_delete_node"       (org-roam-mcp--tool-delete-node args))
        ("org_roam_rename_node"       (org-roam-mcp--tool-rename-node args))
        ("org_roam_refile_node"       (org-roam-mcp--tool-refile-node args))
        ("org_roam_move_node_file"    (org-roam-mcp--tool-move-node-file args))
        ;; ---- TODO/Schedule ----
        ("org_roam_add_todo"          (org-roam-mcp--tool-add-todo args))
        ("org_roam_toggle_todo_state" (org-roam-mcp--tool-toggle-todo-state args))
        ("org_roam_list_todo_keywords" (org-roam-mcp--tool-list-todo-keywords args))
        ("org_roam_set_scheduled"     (org-roam-mcp--tool-set-scheduled args))
        ("org_roam_set_deadline"      (org-roam-mcp--tool-set-deadline args))
        ;; ---- Property/Tag ----
        ("org_roam_set_property"      (org-roam-mcp--tool-set-property args))
        ("org_roam_add_tag"           (org-roam-mcp--tool-add-tag args))
        ("org_roam_remove_tag"        (org-roam-mcp--tool-remove-tag args))
        ;; ---- Agenda ----
        ("org_roam_org_agenda"        (org-roam-mcp--tool-org-agenda args))
        ("org_roam_org_todo_list"     (org-roam-mcp--tool-org-todo-list args))
        ("org_roam_org_tags_view"     (org-roam-mcp--tool-org-tags-view args))
        ;; ---- Dailies ----
        ("org_roam_get_daily"         (org-roam-mcp--tool-get-daily args))
        ;; ---- Unknown ----
        (_ (org-roam-mcp--tool-error (format "Unknown tool: %s" name))))
    (error
     (org-roam-mcp--tool-error (format "Error: %s" (error-message-string err))))))

;; ============================================================
;; Tool implementations
;; ============================================================

;; ---- 1. list_nodes : org-roam-db-query (nodes) ----

(defun org-roam-mcp--tool-list-nodes (args)
  "List nodes from org-roam DB."
  (let* ((limit (or (alist-get 'limit args) org-roam-mcp-default-limit))
         (tag-filter (alist-get 'tag args))
         (level-filter (alist-get 'level args))
         (dir-filter (alist-get 'directory args))
         (rows (org-roam-db-query
                [:select [id title file level]
                 :from nodes
                 :order-by [(asc title)]
                 :limit $s1]
                limit))
         (nodes (cl-loop for row in rows
                         for id = (nth 0 row)
                         for title = (nth 1 row)
                         for file = (nth 2 row)
                         for lvl = (nth 3 row)
                         for node = (org-roam-node-from-id id)
                         for tags = (when node (org-roam-node-tags node))
                         ;; Apply filters
                         when (or (null level-filter) (= lvl level-filter))
                         when (or (null tag-filter) (member tag-filter tags))
                         when (or (null dir-filter)
                                  (string-prefix-p
                                   (expand-file-name dir-filter org-roam-directory)
                                   file))
                         collect `((id . ,id)
                                   (title . ,(or title ""))
                                   (file . ,(or file ""))
                                   (level . ,(or lvl 0))
                                   (tags . ,(or tags []))))))
    (org-roam-mcp--tool-result-json `((nodes . ,(vconcat nodes))))))

;; ---- 2. get_node : org-roam-node-from-id ----

(defun org-roam-mcp--tool-get-node (args)
  "Get node content by ID or title."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (fmt (or (alist-get 'format args) "markdown"))
         (node (cond
                (id (org-roam-mcp--require-node id))
                (title
                 (let ((rows (org-roam-db-query
                              [:select [id] :from nodes
                               :where (= title $s1)
                               :limit 1]
                              title)))
                   (if rows
                       (org-roam-mcp--require-node (caar rows))
                     (error "Node not found with title: %s" title))))
                (t (error "Either id or title is required"))))
         (content (org-roam-mcp--get-node-content node fmt)))
    (org-roam-mcp--tool-result-json
     (append (org-roam-mcp--node-to-alist node)
             `((content . ,content))))))

;; ---- 3. get_backlinks : org-roam-db-query (links) ----

(defun org-roam-mcp--tool-get-backlinks (args)
  "Get backlinks for a node."
  (let* ((id (alist-get 'id args))
         (rows (org-roam-db-query
                [:select [source]
                 :from links
                 :where (= dest $s1)
                 :and (= type "id")]
                id))
         (backlinks
          (cl-loop for row in rows
                   for src-id = (car row)
                   for node = (org-roam-node-from-id src-id)
                   when node
                   collect (org-roam-mcp--node-to-alist node))))
    (org-roam-mcp--tool-result-json
     `((backlinks . ,(vconcat backlinks))))))

;; ---- 4. get_graph : org-roam-db-query (links JOIN nodes) ----

(defun org-roam-mcp--tool-get-graph (args)
  "Get link graph."
  (let* ((origin-id (alist-get 'id args))
         (depth (or (alist-get 'depth args) 2))
         ;; Simple: get all links if no origin, or BFS from origin
         (link-rows
          (if origin-id
              ;; Get links within depth (simplified: depth=1 for now)
              (org-roam-db-query
               [:select [source dest]
                :from links
                :where (= type "id")
                :and (or (= source $s1) (= dest $s1))]
               origin-id)
            (org-roam-db-query
             [:select [source dest]
              :from links
              :where (= type "id")
              :limit 500])))
         ;; Collect unique node IDs
         (node-ids (delete-dups
                    (cl-loop for row in link-rows
                             collect (nth 0 row)
                             collect (nth 1 row))))
         (graph-nodes
          (cl-loop for nid in node-ids
                   for node = (org-roam-node-from-id nid)
                   when node
                   collect `((id . ,nid)
                             (title . ,(org-roam-node-title node))
                             (level . ,(org-roam-node-level node)))))
         (edges
          (cl-loop for row in link-rows
                   collect `((source . ,(nth 0 row))
                             (target . ,(nth 1 row))))))
    (org-roam-mcp--tool-result-json
     `((nodes . ,(vconcat graph-nodes))
       (edges . ,(vconcat edges))))))

;; ---- 5. search_nodes : org-roam-db-query + ripgrep ----

(defun org-roam-mcp--tool-search-nodes (args)
  "Search nodes by keyword and/or attributes."
  (let* ((query (alist-get 'query args))
         (tag-filter (alist-get 'tag args))
         (todo-filter (alist-get 'todo_state args))
         (level-filter (alist-get 'level args))
         (limit (or (alist-get 'limit args) 20))
         ;; Start with DB query for attribute filters
         (rows (org-roam-db-query
                [:select [id title file level]
                 :from nodes
                 :order-by [(asc title)]
                 :limit 500]))
         ;; Fulltext match via grep if query provided
         (matching-files
          (when (and query (not (string-empty-p query)))
            (let ((default-directory org-roam-directory))
              (split-string
               (shell-command-to-string
                (format "grep -rl --include='*.org' %s ."
                        (shell-quote-argument query)))
               "\n" t))))
         (results
          (cl-loop for row in rows
                   for id = (nth 0 row)
                   for title = (nth 1 row)
                   for file = (nth 2 row)
                   for lvl = (nth 3 row)
                   for node = (org-roam-node-from-id id)
                   for tags = (when node (org-roam-node-tags node))
                   for todo = (when node (org-roam-node-todo node))
                   ;; Filters
                   when (or (null level-filter) (= lvl level-filter))
                   when (or (null tag-filter) (member tag-filter tags))
                   when (or (null todo-filter) (equal todo-filter todo))
                   when (or (null matching-files)
                            (cl-some (lambda (f)
                                       (string=
                                        (file-name-nondirectory file)
                                        (file-name-nondirectory f)))
                                     matching-files))
                   collect `((id . ,id)
                             (title . ,(or title ""))
                             (file . ,(or file ""))
                             (level . ,(or lvl 0))
                             (tags . ,(or tags []))
                             (todo . ,(or todo :null)))
                   into res
                   until (>= (length res) limit)
                   finally return res)))
    (org-roam-mcp--tool-result-json `((nodes . ,(vconcat results))))))

;; ---- 6. create_node : org-roam-capture- / org-id-get-create ----

(defun org-roam-mcp--tool-create-node (args)
  "Create a new org-roam node."
  (let* ((title (alist-get 'title args))
         (parent-id (alist-get 'parent_id args))
         (body (alist-get 'body args))
         (tags (alist-get 'tags args))
         (props (alist-get 'properties args))
         (links-to (append (alist-get 'links_to args) nil)))
    (if parent-id
        ;; Heading node: insert under parent
        (let* ((parent (org-roam-mcp--require-node parent-id))
               (file (org-roam-node-file parent))
               (parent-level (org-roam-node-level parent))
               new-id)
          (with-current-buffer (find-file-noselect file)
            (goto-char (org-roam-node-point parent))
            (org-end-of-subtree t)
            (let ((child-level (org-roam-mcp--child-level parent-level)))
              (insert "\n" (make-string child-level ?*) " " title "\n")
              (forward-line -1)
              (setq new-id (org-id-get-create))
              (when tags (org-set-tags (mapconcat #'identity tags ":")))
              (when props
                (dolist (kv props)
                  (org-set-property (car kv) (cdr kv))))
              (when body
                (goto-char (org-entry-end-position))
                (insert (org-roam-mcp--md-to-org body) "\n"))
              (when links-to
                (goto-char (org-entry-end-position))
                (dolist (lid links-to)
                  (let ((lnode (org-roam-node-from-id lid)))
                    (when lnode
                      (insert (format "[[id:%s][%s]]\n"
                                      lid (org-roam-node-title lnode))))))))
            (save-buffer))
          (org-roam-db-update-file file)
          (org-roam-mcp--tool-result-json
           `((id . ,new-id) (title . ,title) (file . ,file) (level . ,(org-roam-mcp--child-level parent-level)))))
      ;; File node: create via file write (non-interactive)
      (let* ((slug (org-roam-node-slug (org-roam-node-create :title title)))
             (filename (format "%s-%s.org"
                               (format-time-string "%Y%m%d%H%M%S")
                               slug))
             (filepath (expand-file-name filename org-roam-directory))
             (new-id (org-id-new)))
        (with-temp-file filepath
          (insert ":PROPERTIES:\n"
                  ":ID:       " new-id "\n"
                  ":END:\n"
                  "#+title: " title "\n")
          (when tags
            (insert "#+filetags: :"
                    (mapconcat #'identity tags ":")
                    ":\n"))
          (insert "\n")
          (when props
            (dolist (kv props)
              ;; File-level properties via keywords
              (insert (format "#+property: %s %s\n" (car kv) (cdr kv)))))
          (when body
            (insert (org-roam-mcp--md-to-org body) "\n"))
          (when links-to
            (dolist (lid links-to)
              (let ((lnode (org-roam-node-from-id lid)))
                (when lnode
                  (insert (format "[[id:%s][%s]]\n"
                                  lid (org-roam-node-title lnode))))))))
        (org-roam-db-update-file filepath)
        (org-roam-mcp--tool-result-json
         `((id . ,new-id) (title . ,title) (file . ,filepath) (level . 0)))))))

;; ---- 7. append_to_node : org-end-of-subtree + insert ----

(defun org-roam-mcp--tool-append-to-node (args)
  "Append content to node."
  (let* ((id (alist-get 'id args))
         (body (alist-get 'body args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (if (= level 0)
          (goto-char (point-max))
        (org-end-of-subtree t))
      (insert "\n" (org-roam-mcp--md-to-org body) "\n")
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 8. update_node_section : narrow + replace ----

(defun org-roam-mcp--tool-update-node-section (args)
  "Update node body text."
  (let* ((id (alist-get 'id args))
         (body (alist-get 'body args))
         (mode (or (alist-get 'mode args) "replace"))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (org-body (org-roam-mcp--md-to-org body)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (goto-char (org-roam-node-point node))
          (if (> level 0)
              (org-narrow-to-subtree)
            (widen))
          ;; Find body region (after meta-data, before first child heading)
          (let (body-start body-end)
            (if (> level 0)
                (progn
                  (goto-char (point-min))
                  (forward-line 1) ;; skip heading line
                  (org-end-of-meta-data t)
                  (setq body-start (point))
                  (setq body-end (save-excursion
                                   (or (outline-next-heading) (goto-char (point-max)))
                                   (point))))
              ;; File node: skip property drawer, #+title, #+filetags, etc.
              (goto-char (point-min))
              (while (looking-at "^\\(:PROPERTIES:\\|:[A-Z_]+:.*\\|:END:\\|#+\\|[[:space:]]*$\\)")
                (forward-line 1))
              (setq body-start (point))
              (setq body-end (save-excursion
                               (if (re-search-forward "^\\*" nil t)
                                   (line-beginning-position)
                                 (point-max)))))
            (pcase mode
              ("replace"
               (delete-region body-start body-end)
               (goto-char body-start)
               (insert org-body "\n"))
              ("append"
               (goto-char body-end)
               (insert org-body "\n"))
              ("prepend"
               (goto-char body-start)
               (insert org-body "\n"))))))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 9. delete_node : delete-file / org-cut-subtree ----

(defun org-roam-mcp--tool-delete-node (args)
  "Delete a node."
  (let* ((id (alist-get 'id args))
         (confirm (alist-get 'confirm args)))
    (unless confirm
      (error "confirm must be true to delete"))
    (let* ((node (org-roam-mcp--require-node id))
           (file (org-roam-node-file node))
           (level (org-roam-node-level node)))
      (if (= level 0)
          ;; File node: delete file
          (progn
            (org-roam-db-clear-file file)
            (when-let ((buf (find-buffer-visiting file)))
              (kill-buffer buf))
            (delete-file file))
        ;; Heading node: cut subtree
        (with-current-buffer (find-file-noselect file)
          (goto-char (org-roam-node-point node))
          (org-cut-subtree)
          (save-buffer))
        (org-roam-db-update-file file))
      (org-roam-mcp--tool-result-json `((status . "deleted") (id . ,id))))))

;; ---- 10. rename_node : org-edit-headline / keyword ----

(defun org-roam-mcp--tool-rename-node (args)
  "Rename a node's title."
  (let* ((id (alist-get 'id args))
         (new-title (alist-get 'new_title args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (if (> level 0)
          (org-edit-headline new-title)
        ;; File node: update #+title:
        (goto-char (point-min))
        (if (re-search-forward "^#\\+title:.*$" nil t)
            (replace-match (concat "#+title: " new-title))
          (goto-char (point-min))
          (insert "#+title: " new-title "\n")))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json
     `((status . "ok") (id . ,id) (title . ,new-title)))))

;; ---- 11. refile_node : org-refile ----

(defun org-roam-mcp--tool-refile-node (args)
  "Refile a heading node under a target node."
  (let* ((id (alist-get 'id args))
         (target-id (alist-get 'target_id args))
         (node (org-roam-mcp--require-node id))
         (target (org-roam-mcp--require-node target-id))
         (source-file (org-roam-node-file node))
         (target-file (org-roam-node-file target))
         (target-level (org-roam-node-level target))
         subtree-text)
    (when (= (org-roam-node-level node) 0)
      (error "Cannot refile a file node. Use move_node_file instead."))
    ;; Cut from source — revert buffer first and find entry by ID
    (with-current-buffer (find-file-noselect source-file)
      (revert-buffer t t t)
      (goto-char (point-min))
      (let ((pos (org-find-entry-with-id id)))
        (unless pos
          (error "Could not find entry with ID %s in %s" id source-file))
        (goto-char pos))
      (org-mark-subtree)
      (setq subtree-text (delete-and-extract-region (region-beginning) (region-end)))
      (deactivate-mark)
      (save-buffer))
    ;; Paste under target
    (with-current-buffer (find-file-noselect target-file)
      (revert-buffer t t t)
      (if (= target-level 0)
          (goto-char (point-max))
        (let ((pos (org-find-entry-with-id target-id)))
          (unless pos
            (error "Could not find target entry with ID %s in %s" target-id target-file))
          (goto-char pos)
          (org-end-of-subtree t)))
      (unless (bolp) (insert "\n"))
      (let ((target-child-level (org-roam-mcp--child-level target-level)))
        (insert subtree-text)
        (unless (string-suffix-p "\n" subtree-text)
          (insert "\n")))
      (save-buffer))
    ;; Sync DB
    (org-roam-db-update-file source-file)
    (unless (string= source-file target-file)
      (org-roam-db-update-file target-file))
    (org-roam-mcp--tool-result-json
     `((status . "ok") (id . ,id) (target_id . ,target-id)))))

;; ---- 12. move_node_file : rename-file ----

(defun org-roam-mcp--tool-move-node-file (args)
  "Move a file node to another directory."
  (let* ((id (alist-get 'id args))
         (new-dir (alist-get 'new_directory args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node)))
    (when (> level 0)
      (error "Cannot move a heading node. Use refile_node instead."))
    (let* ((target-dir (expand-file-name new-dir org-roam-directory))
           (new-path (expand-file-name (file-name-nondirectory file) target-dir)))
      (make-directory target-dir t)
      (with-current-buffer (find-file-noselect file)
        (rename-file file new-path)
        (set-visited-file-name new-path t t)
        (save-buffer))
      (org-roam-db-update-file new-path)
      (org-roam-mcp--tool-result-json
       `((status . "ok") (id . ,id) (file . ,new-path))))))

(defun org-roam-mcp--ensure-daily-node (&optional time)
  "Return the file-level org-roam-node for TIME's daily note, creating if needed.
If the file exists but lacks an org-id, one is added automatically.
TIME defaults to `current-time'."
  (let* ((time (or time (current-time)))
         (daily-file (expand-file-name
                      (format-time-string "%Y-%m-%d.org" time)
                      (expand-file-name
                       org-roam-dailies-directory
                       org-roam-directory))))
    (if (file-exists-p daily-file)
        ;; File exists — ensure it has an ID property
        (with-current-buffer (find-file-noselect daily-file)
          (goto-char (point-min))
          (unless (org-entry-get (point) "ID")
            (org-id-get-create)
            (save-buffer)
            (org-roam-db-update-file daily-file)))
      ;; File doesn't exist — create it
      (let ((daily-id (org-id-new))
            (title (format-time-string "%Y-%m-%d" time)))
        (make-directory (file-name-directory daily-file) t)
        (with-temp-file daily-file
          (insert ":PROPERTIES:\n"
                  ":ID:       " daily-id "\n"
                  ":END:\n"
                  "#+title: " title "\n\n"))
        (org-roam-db-update-file daily-file)))
    (let ((rows (org-roam-db-query
                 [:select [id] :from nodes
                  :where (= file $s1)
                  :and (= level 0)]
                 daily-file)))
      (when rows
        (org-roam-node-from-id (caar rows))))))

;; ---- 13. add_todo : org-insert-heading + org-todo ----

(defun org-roam-mcp--tool-add-todo (args)
  "Add a TODO item."
  (let* ((parent-id (alist-get 'parent_id args))
         (heading (alist-get 'heading args))
         (state (or (alist-get 'state args) "TODO"))
         (priority (alist-get 'priority args))
         (tags (alist-get 'tags args))
         (scheduled (alist-get 'scheduled args))
         (deadline (alist-get 'deadline args))
         (body (alist-get 'body args))
         ;; Resolve parent: use daily if not specified
         (parent (if parent-id
                     (org-roam-mcp--require-node parent-id)
                   (org-roam-mcp--ensure-daily-node)))
         (file (if parent (org-roam-node-file parent)
                 (error "Could not resolve parent node")))
         (parent-level (if parent (org-roam-node-level parent) 0))
         new-id)
    ;; Validate state
    (let ((valid (org-roam-mcp--all-todo-keywords)))
      (unless (member state valid)
        (error "Invalid TODO state: '%s'. Valid states: %s"
               state (string-join valid ", "))))
    (with-current-buffer (find-file-noselect file)
      (goto-char (if parent (org-roam-node-point parent) (point-min)))
      (if (= parent-level 0)
          (goto-char (point-max))
        (org-end-of-subtree t))
      (let ((child-level (org-roam-mcp--child-level parent-level)))
        (insert "\n" (make-string child-level ?*)
                " " state " "
                (if priority (format "[#%s] " priority) "")
                heading "\n")
        (forward-line -1)
        (setq new-id (org-id-get-create))
        (when tags (org-set-tags (mapconcat #'identity tags ":")))
        (when scheduled
          (org-schedule nil scheduled))
        (when deadline
          (org-deadline nil deadline))
        (when body
          (goto-char (org-entry-end-position))
          (insert (org-roam-mcp--md-to-org body) "\n")))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json
     `((status . "ok") (id . ,new-id) (heading . ,heading)))))

;; ---- 14. toggle_todo_state : org-todo ----

(defun org-roam-mcp--clean-keyword (kw)
  "Strip fast-access key suffix from org TODO keyword KW.
E.g., \"TODO(t)\" → \"TODO\"."
  (replace-regexp-in-string "(.*)" "" kw))

(defun org-roam-mcp--all-todo-keywords ()
  "Return a flat list of all TODO keyword strings from `org-todo-keywords'."
  (let (result)
    (dolist (seq (or org-todo-keywords '((sequence "TODO" "DONE"))))
      (dolist (kw (cdr seq))
        (let ((clean (org-roam-mcp--clean-keyword kw)))
          (unless (string= clean "|")
            (push clean result)))))
    (nreverse result)))

(defun org-roam-mcp--next-todo-state (current-state)
  "Compute the next TODO state after CURRENT-STATE using org-todo-keywords.
Returns the next state in the cycle, or nil if CURRENT-STATE is the last."
  (let* ((keywords (mapcar (lambda (kw)
                             (org-roam-mcp--clean-keyword kw))
                           (cdr (cl-find-if
                                 (lambda (seq) (member current-state (cdr seq)))
                                 (or org-todo-keywords
                                     '((sequence "TODO" "DONE")))))))
         (pos (cl-position current-state keywords :test #'equal)))
    (when pos
      (nth (1+ pos) keywords))))

(defun org-roam-mcp--tool-toggle-todo-state (args)
  "Toggle TODO state. Validates state against `org-todo-keywords'."
  (let* ((id (alist-get 'id args))
         (new-state (alist-get 'new_state args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node))
         result-state)
    ;; Validate new-state if provided
    (when new-state
      (let ((valid (org-roam-mcp--all-todo-keywords)))
        (unless (member new-state valid)
          (error "Invalid TODO state: '%s'. Valid states: %s"
                 new-state (string-join valid ", ")))))
    (with-current-buffer (find-file-noselect file)
      ;; Revert buffer to pick up any changes from prior tool calls
      (revert-buffer t t t)
      ;; Find the node by its ID property instead of relying on cached point
      (goto-char (point-min))
      (let ((pos (org-find-entry-with-id id)))
        (unless pos
          (error "Could not find entry with ID %s in %s" id file))
        (goto-char pos))
      (let ((state (or new-state
                       (org-roam-mcp--next-todo-state
                        (org-get-todo-state))
                       "")))  ;; "" removes TODO state
        (org-todo state))
      (setq result-state (org-get-todo-state))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json
     `((status . "ok") (id . ,id)
       (state . ,(or result-state :null))))))

;; ---- 14b. list_todo_keywords : available TODO states ----

(defun org-roam-mcp--tool-list-todo-keywords (_args)
  "List all configured TODO keywords with their sequences."
  (let ((sequences
         (cl-loop for seq in (or org-todo-keywords '((sequence "TODO" "DONE")))
                  collect
                  (let* ((type (car seq))
                         (kws (cdr seq))
                         (active '())
                         (done '())
                         (past-separator nil))
                    (dolist (kw kws)
                      (let ((clean (org-roam-mcp--clean-keyword kw)))
                        (if (string= clean "|")
                            (setq past-separator t)
                          (if past-separator
                              (push clean done)
                            (push clean active)))))
                    `((type . ,(symbol-name type))
                      (active . ,(vconcat (nreverse active)))
                      (done . ,(vconcat (nreverse done))))))))
    (org-roam-mcp--tool-result-json
     `((sequences . ,(vconcat sequences))
       (all_keywords . ,(vconcat (org-roam-mcp--all-todo-keywords)))))))

;; ---- 15. set_scheduled : org-schedule ----

(defun org-roam-mcp--tool-set-scheduled (args)
  "Set SCHEDULED date."
  (let* ((id (alist-get 'id args))
         (date (alist-get 'date args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (if (string-empty-p date)
          (org-schedule '(4))
        (org-schedule nil date))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 16. set_deadline : org-deadline ----

(defun org-roam-mcp--tool-set-deadline (args)
  "Set DEADLINE date."
  (let* ((id (alist-get 'id args))
         (date (alist-get 'date args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (if (string-empty-p date)
          (org-deadline '(4))
        (org-deadline nil date))
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 17. set_property : org-set-property ----

(defun org-roam-mcp--tool-set-property (args)
  "Set a property."
  (let* ((id (alist-get 'id args))
         (name (alist-get 'name args))
         (value (alist-get 'value args))
         (node (org-roam-mcp--require-node id))
         (file (org-roam-node-file node)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (org-set-property name value)
      (save-buffer))
    (org-roam-db-update-file file)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 18. add_tag : direct filetags/org-set-tags (avoids org-roam-tag-add's completing-read) ----

(defun org-roam-mcp--add-tag-to-node (node tag)
  "Add TAG to NODE without interactive prompts.
File node: modifies #+filetags keyword.
Heading node: modifies heading tags via org-set-tags."
  (let ((file (org-roam-node-file node))
        (level (org-roam-node-level node)))
    (with-current-buffer (find-file-noselect file)
      (if (= level 0)
          ;; File node: update #+filetags
          (progn
            (goto-char (point-min))
            (let ((current-tags (org-roam-node-tags node)))
              (unless (member tag current-tags)
                (if (re-search-forward "^#\\+filetags:.*$" nil t)
                    (replace-match
                     (concat "#+filetags: :"
                             (mapconcat #'identity
                                        (append current-tags (list tag)) ":")
                             ":"))
                  ;; No filetags line yet — insert after #+title
                  (goto-char (point-min))
                  (if (re-search-forward "^#\\+title:.*$" nil t)
                      (progn (end-of-line)
                             (insert "\n#+filetags: :" tag ":"))
                    (goto-char (point-min))
                    (insert "#+filetags: :" tag ":\n"))))))
        ;; Heading node: use org-set-tags
        (goto-char (org-roam-node-point node))
        (let ((current-tags (or (org-get-tags nil t) '())))
          (unless (member tag current-tags)
            (org-set-tags (append current-tags (list tag))))))
      (save-buffer))
    (org-roam-db-update-file file)))

(defun org-roam-mcp--tool-add-tag (args)
  "Add a tag to a node."
  (let* ((id (alist-get 'id args))
         (tag (alist-get 'tag args))
         (node (org-roam-mcp--require-node id)))
    (org-roam-mcp--add-tag-to-node node tag)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- 19. remove_tag : direct filetags/org-set-tags (avoids org-roam-tag-remove's completing-read) ----

(defun org-roam-mcp--remove-tag-from-node (node tag)
  "Remove TAG from NODE without interactive prompts.
File node: modifies #+filetags keyword.
Heading node: modifies heading tags via org-set-tags."
  (let ((file (org-roam-node-file node))
        (level (org-roam-node-level node)))
    (with-current-buffer (find-file-noselect file)
      (if (= level 0)
          ;; File node: update #+filetags
          (progn
            (goto-char (point-min))
            (let* ((current-tags (org-roam-node-tags node))
                   (new-tags (delete tag current-tags)))
              (when (re-search-forward "^#\\+filetags:.*$" nil t)
                (if new-tags
                    (replace-match
                     (concat "#+filetags: :"
                             (mapconcat #'identity new-tags ":")
                             ":"))
                  (replace-match "")))))
        ;; Heading node: use org-set-tags
        (goto-char (org-roam-node-point node))
        (let* ((current-tags (or (org-get-tags nil t) '()))
               (new-tags (delete tag current-tags)))
          (org-set-tags new-tags)))
      (save-buffer))
    (org-roam-db-update-file file)))

(defun org-roam-mcp--tool-remove-tag (args)
  "Remove a tag from a node."
  (let* ((id (alist-get 'id args))
         (tag (alist-get 'tag args))
         (node (org-roam-mcp--require-node id)))
    (org-roam-mcp--remove-tag-from-node node tag)
    (org-roam-mcp--tool-result-json `((status . "ok") (id . ,id)))))

;; ---- Batch-safe agenda helpers ----

(defun org-roam-mcp--timestamp-to-iso (ts)
  "Convert an org-element timestamp TS to an ISO date string.
Returns nil if TS is nil."
  (when ts
    (let ((year  (org-element-property :year-start ts))
          (month (org-element-property :month-start ts))
          (day   (org-element-property :day-start ts)))
      (when (and year month day)
        (format "%04d-%02d-%02d" year month day)))))

(defun org-roam-mcp--entry-plist-at-point (file)
  "Build an entry plist for the heading at point in FILE.
Extracts heading text, TODO state, priority, tags, scheduled,
deadline, and org-id."
  (let* ((element (org-element-at-point))
         (heading (org-element-property :raw-value element))
         (todo    (org-element-property :todo-keyword element))
         (priority (org-element-property :priority element))
         (tags    (org-get-tags nil t))
         (sched   (org-element-property
                   :scheduled (org-element-at-point-no-context)))
         (dl      (org-element-property
                   :deadline (org-element-at-point-no-context)))
         (id      (org-entry-get nil "ID")))
    (list :heading heading
          :file file
          :id id
          :todo_state todo
          :priority (when priority (char-to-string priority))
          :tags tags
          :scheduled (org-roam-mcp--timestamp-to-iso sched)
          :deadline  (org-roam-mcp--timestamp-to-iso dl))))

(defun org-roam-mcp--entry-plist-to-alist (plist)
  "Convert an entry PLIST to an alist suitable for JSON encoding.
Nil values become :json-null, tags become a vector."
  (let ((heading   (plist-get plist :heading))
        (file      (plist-get plist :file))
        (id        (plist-get plist :id))
        (todo      (plist-get plist :todo_state))
        (priority  (plist-get plist :priority))
        (tags      (plist-get plist :tags))
        (scheduled (plist-get plist :scheduled))
        (deadline  (plist-get plist :deadline))
        (date      (plist-get plist :date)))
    `((heading    . ,(or heading ""))
      (file       . ,(or file ""))
      (id         . ,id)
      (todo_state . ,todo)
      (priority   . ,priority)
      (tags       . ,(vconcat (or tags [])))
      (scheduled  . ,scheduled)
      (deadline   . ,deadline)
      ,@(when date `((date . ,date))))))

(defun org-roam-mcp--scan-entries-in-file (file filter-fn)
  "Scan FILE for org headings, returning entries that pass FILTER-FN.
Opens FILE in a temp buffer, iterates headings with `org-map-entries',
and collects entry plists for which FILTER-FN returns non-nil.
FILTER-FN receives the entry plist and should return it (possibly
augmented) or nil to skip."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks (org-mode))
      (let ((entries '()))
        (org-map-entries
         (lambda ()
           (let* ((plist (org-roam-mcp--entry-plist-at-point file))
                  (result (funcall filter-fn plist)))
             (when result
               (push result entries)))))
        (nreverse entries)))))

(defun org-roam-mcp--scan-agenda-files (filter-fn)
  "Scan all `org-agenda-files' and collect entries passing FILTER-FN.
FILTER-FN receives an entry plist and returns it (possibly augmented)
or nil to skip.  Works in --batch mode without any display functions."
  (let ((files (org-agenda-files t)))
    (cl-loop for file in files
             nconc (org-roam-mcp--scan-entries-in-file file filter-fn))))

(defun org-roam-mcp--date-in-range-p (date-str start-date end-date)
  "Return non-nil if DATE-STR (ISO format) falls within START-DATE..END-DATE.
START-DATE and END-DATE are Emacs time values."
  (when date-str
    (let ((date-time (date-to-time (concat date-str " 00:00:00"))))
      (and (not (time-less-p date-time start-date))
           (time-less-p date-time end-date)))))

;; ---- 20. org_agenda : agenda view (batch-safe) ----

(defun org-roam-mcp--tool-org-agenda (args)
  "Get agenda view for the next N days (default 7).
Scans `org-agenda-files' for scheduled/deadline items without
using `org-agenda-list', so it works in --batch mode."
  (let* ((span (or (alist-get 'span args) 7))
         (start-date (current-time))
         (end-date (time-add start-date (days-to-time span)))
         (entries
          (org-roam-mcp--scan-agenda-files
           (lambda (plist)
             (let ((sched (plist-get plist :scheduled))
                   (dl    (plist-get plist :deadline)))
               (cond
                ((org-roam-mcp--date-in-range-p sched start-date end-date)
                 (plist-put plist :date sched))
                ((org-roam-mcp--date-in-range-p dl start-date end-date)
                 (plist-put plist :date dl))
                (t nil))))))
         (alists (mapcar #'org-roam-mcp--entry-plist-to-alist entries)))
    (org-roam-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

;; ---- 21. org_todo_list : TODO list (batch-safe) ----

(defun org-roam-mcp--tool-org-todo-list (args)
  "Get all TODO items, optionally filtered by keyword.
MATCH is a TODO keyword string (e.g. \"TODO\") or nil for all.
Scans `org-agenda-files' without using `org-todo-list'."
  (let* ((match (alist-get 'match args))
         (keywords (when match
                     (split-string match "|" t "[ \t]+")))
         (entries
          (org-roam-mcp--scan-agenda-files
           (lambda (plist)
             (let ((todo (plist-get plist :todo_state)))
               (when (and todo
                          (or (null keywords)
                              (member todo keywords)))
                 plist)))))
         (alists (mapcar #'org-roam-mcp--entry-plist-to-alist entries)))
    (org-roam-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

;; ---- 22. org_tags_view : tag/property search (batch-safe) ----

(defun org-roam-mcp--scan-entries-by-match (file match todo-only)
  "Scan FILE for entries matching MATCH (org-agenda match string).
If TODO-ONLY is non-nil, only return entries with a TODO keyword.
Uses `org-map-entries' with MATCH in a temp buffer."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks (org-mode))
      (let ((entries '()))
        (org-map-entries
         (lambda ()
           (let ((plist (org-roam-mcp--entry-plist-at-point file)))
             (when (or (not todo-only)
                       (plist-get plist :todo_state))
               (push plist entries))))
         match)
        (nreverse entries)))))

(defun org-roam-mcp--tool-org-tags-view (args)
  "Search by tag/property match string (e.g. \"+work-done\").
Scans `org-agenda-files' without using `org-tags-view'."
  (let* ((match (alist-get 'match args))
         (todo-only (eq t (alist-get 'todo_only args)))
         (files (org-agenda-files t))
         (entries
          (cl-loop for file in files
                   nconc (org-roam-mcp--scan-entries-by-match
                          file match todo-only)))
         (alists (mapcar #'org-roam-mcp--entry-plist-to-alist entries)))
    (org-roam-mcp--tool-result-json
     `((entries . ,(vconcat alists))))))

;; ---- 23. get_daily : org-roam-dailies-find-date ----

(defun org-roam-mcp--tool-get-daily (args)
  "Get or create daily note."
  (let* ((date-str (alist-get 'date args))
         (fmt (or (alist-get 'format args) "markdown"))
         (time (if date-str
                   (date-to-time date-str)
                 (current-time)))
         (node (org-roam-mcp--ensure-daily-node time)))
    (if node
        (let ((content (org-roam-mcp--get-node-content node fmt)))
          (org-roam-mcp--tool-result-json
           (append (org-roam-mcp--node-to-alist node)
                   `((content . ,content)))))
      (org-roam-mcp--tool-result-json
       `((error . "Could not create or find daily node"))))))

;; ============================================================
;; Tool schemas for tools/list
;; ============================================================

(defvar org-roam-mcp--tool-schemas
  `[((name . "org_roam_list_nodes")
     (description . "List nodes from the org-roam database. Returns both file nodes (level=0) and heading nodes (level>=1).")
     (inputSchema . ((type . "object")
                     (properties . ((directory . ((type . "string") (description . "Filter by directory")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (level . ((type . "integer") (description . "Filter by level (0=file, 1+=heading)")))
                                    (limit . ((type . "integer") (description . "Max results (default: 50)"))))))))
    ((name . "org_roam_get_node")
     (description . "Get node content by ID or title. Returns content in markdown or org format.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (title . ((type . "string") (description . "Node title")))
                                    (format . ((type . "string") (enum . ["org" "markdown"]) (description . "Output format (default: markdown)"))))))))
    ((name . "org_roam_get_backlinks")
     (description . "Get backlinks for a node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))))
                     (required . ["id"]))))
    ((name . "org_roam_get_graph")
     (description . "Get the link graph between nodes.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Origin node ID")))
                                    (depth . ((type . "integer") (description . "Traversal depth (default: 2)"))))))))
    ((name . "org_roam_search_nodes")
     (description . "Search nodes by keyword and/or attributes.")
     (inputSchema . ((type . "object")
                     (properties . ((query . ((type . "string") (description . "Fulltext keyword")))
                                    (tag . ((type . "string") (description . "Filter by tag")))
                                    (todo_state . ((type . "string") (description . "Filter by TODO state")))
                                    (level . ((type . "integer") (description . "Filter by level")))
                                    (limit . ((type . "integer") (description . "Max results (default: 20)"))))))))
    ((name . "org_roam_create_node")
     (description . "Create a new node. Omit parent_id for file node, provide it for heading node.")
     (inputSchema . ((type . "object")
                     (properties . ((title . ((type . "string") (description . "Node title")))
                                    (parent_id . ((type . "string") (description . "Parent node ID (for heading node)")))
                                    (body . ((type . "string") (description . "Body text (Markdown)")))
                                    (tags . ((type . "array") (items . ((type . "string")))))
                                    (links_to . ((type . "array") (items . ((type . "string"))) (description . "Node IDs to link to")))
                                    (template . ((type . "string") (description . "Capture template key")))))
                     (required . ["title"]))))
    ((name . "org_roam_append_to_node")
     (description . "Append content to end of a node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (body . ((type . "string") (description . "Content (Markdown)")))))
                     (required . ["id" "body"]))))
    ((name . "org_roam_update_node_section")
     (description . "Update the body text of a node (replace/append/prepend).")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (body . ((type . "string") (description . "New content (Markdown)")))
                                    (mode . ((type . "string") (enum . ["replace" "append" "prepend"])))))
                     (required . ["id" "body"]))))
    ((name . "org_roam_delete_node")
     (description . "Delete a node. File node: deletes file. Heading node: deletes subtree.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (confirm . ((type . "boolean") (description . "Must be true")))))
                     (required . ["id" "confirm"]))))
    ((name . "org_roam_rename_node")
     (description . "Change a node's title.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (new_title . ((type . "string") (description . "New title")))))
                     (required . ["id" "new_title"]))))
    ((name . "org_roam_refile_node")
     (description . "Refile a heading node under another node. Uses org-refile.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Heading node ID")))
                                    (target_id . ((type . "string") (description . "Target parent node ID")))))
                     (required . ["id" "target_id"]))))
    ((name . "org_roam_move_node_file")
     (description . "Move a file node to another directory.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "File node ID")))
                                    (new_directory . ((type . "string") (description . "Target directory (relative to org-roam-directory)")))))
                     (required . ["id" "new_directory"]))))
    ((name . "org_roam_add_todo")
     (description . "Add a TODO heading. Combines org-insert-heading + org-todo + org-schedule + org-deadline.")
     (inputSchema . ((type . "object")
                     (properties . ((parent_id . ((type . "string") (description . "Parent node ID (default: today's daily)")))
                                    (heading . ((type . "string") (description . "TODO heading text")))
                                    (state . ((type . "string") (description . "TODO state keyword (use list_todo_keywords to see valid states, default: TODO)")))
                                    (priority . ((type . "string") (enum . ["A" "B" "C"])))
                                    (tags . ((type . "array") (items . ((type . "string")))))
                                    (scheduled . ((type . "string") (description . "SCHEDULED date (ISO 8601)")))
                                    (deadline . ((type . "string") (description . "DEADLINE date (ISO 8601)")))
                                    (body . ((type . "string") (description . "Body text (Markdown)")))))
                     (required . ["heading"]))))
    ((name . "org_roam_toggle_todo_state")
     (description . "Change TODO state. Uses org-todo.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (new_state . ((type . "string") (description . "New state keyword (use list_todo_keywords to see valid states; omit to cycle)")))))
                     (required . ["id"]))))
    ((name . "org_roam_list_todo_keywords")
     (description . "List all configured TODO keyword sequences and their states.")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table)))))
    ((name . "org_roam_set_scheduled")
     (description . "Set SCHEDULED date. Uses org-schedule.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (date . ((type . "string") (description . "Date (ISO 8601). Empty to remove.")))))
                     (required . ["id" "date"]))))
    ((name . "org_roam_set_deadline")
     (description . "Set DEADLINE date. Uses org-deadline.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (date . ((type . "string") (description . "Date (ISO 8601). Empty to remove.")))))
                     (required . ["id" "date"]))))
    ((name . "org_roam_set_property")
     (description . "Set a property in the property drawer. Uses org-set-property.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (name . ((type . "string") (description . "Property name")))
                                    (value . ((type . "string") (description . "Property value")))))
                     (required . ["id" "name" "value"]))))
    ((name . "org_roam_add_tag")
     (description . "Add a tag to a node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (tag . ((type . "string") (description . "Tag to add")))))
                     (required . ["id" "tag"]))))
    ((name . "org_roam_remove_tag")
     (description . "Remove a tag from a node.")
     (inputSchema . ((type . "object")
                     (properties . ((id . ((type . "string") (description . "Node ID")))
                                    (tag . ((type . "string") (description . "Tag to remove")))))
                     (required . ["id" "tag"]))))
    ((name . "org_roam_org_agenda")
     (description . "Get date-based agenda view for scheduled/deadline items.")
     (inputSchema . ((type . "object")
                     (properties . ((span . ((type . "integer") (description . "Number of days (default: 7)"))))))))
    ((name . "org_roam_org_todo_list")
     (description . "Get all TODO items. Scans org-agenda-files.")
     (inputSchema . ((type . "object")
                     (properties . ((match . ((type . "string") (description . "TODO keyword filter"))))))))
    ((name . "org_roam_org_tags_view")
     (description . "Search by tag/property match. Scans org-agenda-files.")
     (inputSchema . ((type . "object")
                     (properties . ((match . ((type . "string") (description . "Match string (e.g. '+work-done')")))
                                    (todo_only . ((type . "boolean") (description . "Only TODO items")))))
                     (required . ["match"]))))
    ((name . "org_roam_get_daily")
     (description . "Get or create a daily note.")
     (inputSchema . ((type . "object")
                     (properties . ((date . ((type . "string") (description . "Date (ISO 8601, default: today)")))
                                    (format . ((type . "string") (enum . ["org" "markdown"]))))))))]
  "Tool schemas for tools/list response.")

;; ============================================================
;; MCP protocol handler
;; ============================================================

(defun org-roam-mcp--handle-message (msg)
  "Handle a parsed JSON-RPC MSG (alist)."
  (let* ((id (alist-get 'id msg))
         (method (alist-get 'method msg))
         (params (or (alist-get 'params msg) '())))
    (org-roam-mcp--log "Received: method=%s id=%s" method id)
    (pcase method
      ;; --- Lifecycle ---
      ("initialize"
       (org-roam-mcp--respond id
        `((protocolVersion . ,org-roam-mcp--protocol-version)
          (capabilities . ((tools . ((listChanged . :json-false)))))
          (serverInfo . ((name . ,org-roam-mcp--server-name)
                         (version . ,org-roam-mcp--server-version))))))
      ("notifications/initialized"
       ;; Notification — no response needed
       (org-roam-mcp--log "Client initialized"))
      ("ping"
       (org-roam-mcp--respond id '()))

      ;; --- Tools ---
      ("tools/list"
       (org-roam-mcp--respond id
        `((tools . ,org-roam-mcp--tool-schemas))))
      ("tools/call"
       (let* ((tool-name (alist-get 'name params))
              (tool-args (or (alist-get 'arguments params) '()))
              (result (org-roam-mcp--handle-tool tool-name tool-args)))
         (org-roam-mcp--respond id result)))

      ;; --- Unknown ---
      (_
       (if id
           (org-roam-mcp--respond-error id -32601
            (format "Method not found: %s" method))
         ;; Unknown notification — ignore
         (org-roam-mcp--log "Ignoring unknown notification: %s" method))))))

;; ============================================================
;; Main loop
;; ============================================================

(defun org-roam-mcp-start ()
  "Start the MCP server, reading from stdin and writing to stdout.
Intended for use with `emacs --batch`."
  (org-roam-mcp--log "Starting %s v%s" org-roam-mcp--server-name org-roam-mcp--server-version)
  (org-roam-mcp--log "org-roam-directory: %s" org-roam-directory)
  ;; Verify Pandoc is available
  (org-roam-mcp--check-pandoc)
  (org-roam-mcp--log "Pandoc found: %s" (executable-find "pandoc"))
  ;; Ensure org-roam DB is ready
  (org-roam-db-sync)
  (org-roam-mcp--log "DB synced. Entering main loop.")
  ;; Main read loop: one JSON message per line from stdin.
  (let ((line nil))
    (while (setq line (ignore-errors (read-from-minibuffer "")))
      (unless (string-empty-p (string-trim line))
        (condition-case err
            (let* ((json-object-type 'alist)
                   (json-array-type 'vector)
                   (json-key-type 'symbol)
                   (msg (json-read-from-string line)))
              (org-roam-mcp--handle-message msg))
          (error
           (org-roam-mcp--log "Parse error: %s" (error-message-string err))))))))

(provide 'org-roam-mcp)

;;; org-roam-mcp.el ends here
