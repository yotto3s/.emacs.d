;;; org-files-mcp-roam.el --- Roam read-only MCP tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only org-roam tool implementations for org-files-mcp.
;;
;; Contains the 5 `roam_*` query tools:
;;   roam_list_nodes, roam_get_node, roam_get_backlinks,
;;   roam_get_graph, roam_search_nodes.
;;
;; All tools in this module are read-only by construction — they
;; never write to roam files or the roam DB.  Any write operation
;; on a roam-tracked file is the job of the plain-org module, which
;; rejects such targets at the resolver layer.

;;; Code:

(require 'org-roam)
(require 'cl-lib)

(declare-function org-files-mcp--tool-result-json "org-files-mcp" (obj))
(declare-function org-files-mcp--pandoc-convert "org-files-mcp" (input from-fmt to-fmt &optional heading-shift))
(declare-function org-files-mcp--log "org-files-mcp" (fmt &rest args))
(defvar org-files-mcp-default-limit)

;; ============================================================
;; Internal helpers
;; ============================================================

(defun org-files-mcp--node-to-alist (node)
  "Convert org-roam NODE struct to a JSON-encodable alist."
  `((id . ,(org-roam-node-id node))
    (title . ,(or (org-roam-node-title node) ""))
    (file . ,(or (org-roam-node-file node) ""))
    (level . ,(or (org-roam-node-level node) 0))
    (tags . ,(or (org-roam-node-tags node) []))
    (todo . ,(or (org-roam-node-todo node) :null))
    (priority . ,(or (org-roam-node-priority node) :null))))

(defun org-files-mcp--require-roam-node (id)
  "Return org-roam node for ID, or signal error."
  (or (org-roam-node-from-id id)
      (error "Roam node not found: %s" id)))

(defun org-files-mcp--get-roam-node-content (node format-type)
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
              (condition-case err
                  (org-files-mcp--pandoc-convert content "org" "markdown")
                (error
                 (org-files-mcp--log "WARNING: pandoc org->markdown failed: %s, returning raw org"
                                    (error-message-string err))
                 content)))))))))

;; ============================================================
;; Read tools
;; ============================================================

(defun org-files-mcp--tool-roam-list-nodes (args)
  "List nodes from org-roam DB."
  (let* ((limit (or (alist-get 'limit args) org-files-mcp-default-limit))
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
    (org-files-mcp--tool-result-json `((nodes . ,(vconcat nodes))))))

(defun org-files-mcp--tool-roam-get-node (args)
  "Get roam node content by ID or title."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (fmt (or (alist-get 'format args) "markdown"))
         (node (cond
                (id (org-files-mcp--require-roam-node id))
                (title
                 (let ((rows (org-roam-db-query
                              [:select [id] :from nodes
                               :where (= title $s1)
                               :limit 1]
                              title)))
                   (if rows
                       (org-files-mcp--require-roam-node (caar rows))
                     (error "Roam node not found with title: %s" title))))
                (t (error "Either id or title is required"))))
         (content (org-files-mcp--get-roam-node-content node fmt)))
    (org-files-mcp--tool-result-json
     (append (org-files-mcp--node-to-alist node)
             `((content . ,content))))))

(defun org-files-mcp--tool-roam-get-backlinks (args)
  "Get backlinks for a roam node."
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
                   collect (org-files-mcp--node-to-alist node))))
    (org-files-mcp--tool-result-json
     `((backlinks . ,(vconcat backlinks))))))

(defun org-files-mcp--tool-roam-get-graph (args)
  "Get link graph between roam nodes."
  (let* ((origin-id (alist-get 'id args))
         (link-rows
          (if origin-id
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
    (org-files-mcp--tool-result-json
     `((nodes . ,(vconcat graph-nodes))
       (edges . ,(vconcat edges))))))

(defun org-files-mcp--tool-roam-search-nodes (args)
  "Search roam nodes by keyword and/or attributes."
  (let* ((query (alist-get 'query args))
         (tag-filter (alist-get 'tag args))
         (todo-filter (alist-get 'todo_state args))
         (level-filter (alist-get 'level args))
         (limit (or (alist-get 'limit args) 20))
         (rows (org-roam-db-query
                [:select [id title file level]
                 :from nodes
                 :order-by [(asc title)]
                 :limit 500]))
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
    (org-files-mcp--tool-result-json `((nodes . ,(vconcat results))))))

(provide 'org-files-mcp-roam)

;;; org-files-mcp-roam.el ends here
