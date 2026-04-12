;;; org-files-mcp-roam.el --- Roam MCP tools (read + write) -*- lexical-binding: t; -*-

;;; Commentary:

;; Org-roam tool implementations for org-files-mcp.
;;
;; Read tools (5):
;;   roam_list_nodes, roam_get_node, roam_get_backlinks,
;;   roam_get_graph, roam_search_nodes.
;;
;; Content write tools (3):
;;   roam_create_node        — create new file-level node
;;   roam_append_to_node     — append markdown to a node's body
;;   roam_update_node_body   — replace/append/prepend a node's body
;;
;; Metadata write tools (4):
;;   roam_add_tag, roam_remove_tag       — edit tags on a node
;;   roam_set_property, roam_remove_property — edit PROPERTIES drawer
;;
;; All write tools refresh the org-roam DB via `org-roam-db-update-file'
;; after modifying a file, so queries remain consistent.

;;; Code:

(require 'org-roam)
(require 'org-id)
(require 'cl-lib)

(declare-function org-files-mcp--tool-result-json "org-files-mcp" (obj))
(declare-function org-files-mcp--pandoc-convert "org-files-mcp" (input from-fmt to-fmt &optional heading-shift))
(declare-function org-files-mcp--md-to-org "org-files-mcp" (md-string &optional container-level))
(declare-function org-files-mcp--log "org-files-mcp" (fmt &rest args))
(declare-function org-files-mcp--roam-resolve-node "org-files-mcp" (id title))
(declare-function org-files-mcp--roam-after-write "org-files-mcp" (abs-file))
(declare-function org-files-mcp--roam-new-filename "org-files-mcp" (title &optional override))
(declare-function org-files-mcp--roam-file-header-end "org-files-mcp" ())
(declare-function org-files-mcp--roam-file-filetags-edit "org-files-mcp" (op tag))
(declare-function org-files-mcp--roam-file-level-property-edit "org-files-mcp" (op name &optional value))
(declare-function org-files-mcp--replace-subtree-body-at-point "org-files-mcp" (org-body mode))
(declare-function org-files-mcp--replace-file-body "org-files-mcp" (org-body mode))
(declare-function org-files-mcp--mark-file-ai-generated "org-files-mcp" ())
(declare-function org-files-mcp--olp-to-list "org-files-mcp" (olp))
(defvar org-files-mcp-default-limit)
(defvar org-files-mcp--ai-tag)

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

;; ============================================================
;; Write tools: content
;; ============================================================

(defun org-files-mcp--tool-roam-create-node (args)
  "Create a new file-level roam node.
Always adds `org-files-mcp--ai-tag' to the node's `#+filetags:'."
  (let* ((title (alist-get 'title args))
         (user-tags (org-files-mcp--olp-to-list (alist-get 'tags args)))
         (tags (if (member org-files-mcp--ai-tag user-tags)
                   user-tags
                 (append user-tags (list org-files-mcp--ai-tag))))
         (body (alist-get 'body args))
         (filename (alist-get 'filename args))
         (id (org-id-new))
         (abs (org-files-mcp--roam-new-filename title filename)))
    (unless (and title (not (string-empty-p title)))
      (error "title is required"))
    (unless (file-directory-p (file-name-directory abs))
      (error "Parent directory does not exist: %s" (file-name-directory abs)))
    (with-temp-file abs
      (insert ":PROPERTIES:\n:ID:       " id "\n:END:\n")
      (insert "#+title: " title "\n")
      (insert "#+filetags: :" (mapconcat #'identity tags ":") ":\n")
      (insert "\n")
      (when (and body (not (string-empty-p body)))
        (insert (org-files-mcp--md-to-org body 0))
        (unless (string-suffix-p "\n" body) (insert "\n"))))
    (org-files-mcp--roam-after-write abs)
    (org-files-mcp--tool-result-json
     `((status . "ok")
       (id . ,id)
       (file . ,abs)
       (title . ,title)))))

(defun org-files-mcp--tool-roam-append-to-node (args)
  "Append markdown body content to an existing roam node."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (body (alist-get 'body args))
         (node (org-files-mcp--roam-resolve-node id title))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (node-id (org-roam-node-id node))
         (org-body (org-files-mcp--md-to-org body level)))
    (unless (and body (not (string-empty-p body)))
      (error "body is required"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (if (> level 0)
              (progn
                (goto-char (org-roam-node-point node))
                (org-end-of-subtree t)
                (unless (bolp) (insert "\n"))
                (insert org-body)
                (unless (string-suffix-p "\n" org-body) (insert "\n")))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert org-body)
            (unless (string-suffix-p "\n" org-body) (insert "\n")))))
      (org-files-mcp--mark-file-ai-generated)
      (save-buffer))
    (org-files-mcp--roam-after-write file)
    (org-files-mcp--tool-result-json
     `((status . "ok") (id . ,node-id) (file . ,file)))))

(defun org-files-mcp--tool-roam-update-node-body (args)
  "Replace/append/prepend the body of a roam node."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (body (alist-get 'body args))
         (mode (or (alist-get 'mode args) "replace"))
         (node (org-files-mcp--roam-resolve-node id title))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (node-id (org-roam-node-id node))
         (org-body (org-files-mcp--md-to-org body level)))
    (unless body (error "body is required"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (if (> level 0)
              (progn
                (goto-char (org-roam-node-point node))
                (org-files-mcp--replace-subtree-body-at-point org-body mode))
            (org-files-mcp--replace-file-body org-body mode))))
      (org-files-mcp--mark-file-ai-generated)
      (save-buffer))
    (org-files-mcp--roam-after-write file)
    (org-files-mcp--tool-result-json
     `((status . "ok") (id . ,node-id) (file . ,file) (mode . ,mode)))))

;; ============================================================
;; Write tools: metadata (tags + properties)
;; ============================================================

(defun org-files-mcp--roam-edit-tag (op args)
  "Common body for `roam_add_tag' / `roam_remove_tag'. OP is `add' or `remove'."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (tag (alist-get 'tag args))
         (node (org-files-mcp--roam-resolve-node id title))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (node-id (org-roam-node-id node)))
    (unless (and tag (not (string-empty-p tag)))
      (error "tag is required"))
    (when (and (eq op 'remove) (equal tag org-files-mcp--ai-tag))
      (error "Refusing to remove AI tag `%s' via MCP; edit in Emacs if intended"
             org-files-mcp--ai-tag))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (if (> level 0)
              (progn
                (goto-char (org-roam-node-point node))
                (let* ((current (or (org-get-tags nil t) '()))
                       (new (pcase op
                              ('add (if (member tag current) current
                                      (append current (list tag))))
                              ('remove (delete tag (copy-sequence current))))))
                  (unless (equal current new)
                    (org-set-tags new))))
            (org-files-mcp--roam-file-filetags-edit op tag))))
      (save-buffer))
    (org-files-mcp--roam-after-write file)
    (org-files-mcp--tool-result-json
     `((status . "ok") (id . ,node-id) (file . ,file) (tag . ,tag)))))

(defun org-files-mcp--tool-roam-add-tag (args)
  "Add a tag to a roam node."
  (org-files-mcp--roam-edit-tag 'add args))

(defun org-files-mcp--tool-roam-remove-tag (args)
  "Remove a tag from a roam node."
  (org-files-mcp--roam-edit-tag 'remove args))

(defun org-files-mcp--tool-roam-set-property (args)
  "Set a property on a roam node (file-level or heading-level)."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (name (alist-get 'name args))
         (value (alist-get 'value args))
         (node (org-files-mcp--roam-resolve-node id title))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (node-id (org-roam-node-id node)))
    (unless (and name (not (string-empty-p name)))
      (error "name is required"))
    (unless value (error "value is required"))
    (when (equal (upcase name) "ID")
      (error "Refusing to modify :ID: on a roam node"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (if (> level 0)
              (progn
                (goto-char (org-roam-node-point node))
                (org-set-property name value))
            (org-files-mcp--roam-file-level-property-edit 'set name value))))
      (save-buffer))
    (org-files-mcp--roam-after-write file)
    (org-files-mcp--tool-result-json
     `((status . "ok") (id . ,node-id) (file . ,file)
       (name . ,name) (value . ,value)))))

(defun org-files-mcp--tool-roam-remove-property (args)
  "Remove a property from a roam node."
  (let* ((id (alist-get 'id args))
         (title (alist-get 'title args))
         (name (alist-get 'name args))
         (node (org-files-mcp--roam-resolve-node id title))
         (file (org-roam-node-file node))
         (level (org-roam-node-level node))
         (node-id (org-roam-node-id node)))
    (unless (and name (not (string-empty-p name)))
      (error "name is required"))
    (when (equal (upcase name) "ID")
      (error "Refusing to remove :ID: from a roam node"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (if (> level 0)
              (progn
                (goto-char (org-roam-node-point node))
                (org-entry-delete (point) name))
            (org-files-mcp--roam-file-level-property-edit 'remove name))))
      (save-buffer))
    (org-files-mcp--roam-after-write file)
    (org-files-mcp--tool-result-json
     `((status . "ok") (id . ,node-id) (file . ,file) (name . ,name)))))

(provide 'org-files-mcp-roam)

;;; org-files-mcp-roam.el ends here
