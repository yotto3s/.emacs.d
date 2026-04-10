# org-files-mcp

An MCP (Model Context Protocol) server that runs inside Emacs, providing AI agents with structured access to the user's org files: org-roam nodes plus plain org files such as `inbox.org` under `org-directory`.

## Architecture

```
AI Agent ←stdio/JSON-RPC→ Emacs (org-files-mcp.el)
                            ├── org-roam DB (emacsql/SQLite)
                            ├── org-mode API
                            └── org files (roam + plain)
```

Emacs itself is the MCP server. No bridge process, no external dependencies beyond Emacs, org-mode, and org-roam. All tools map directly to org-mode/org-roam Elisp functions.

## Requirements

- Emacs 29.1+
- org-roam 2.2.2+
- org-roam configured with `org-roam-directory` set
- Pandoc (for Markdown↔Org conversion)

## Installation

Copy `org-files-mcp.el` to your load path:

```bash
cp org-files-mcp.el ~/.emacs.d/lisp/
```

## Usage

### With Claude Code / Claude Desktop

Add to your MCP config:

```json
{
  "mcpServers": {
    "orgfiles": {
      "command": "emacs",
      "args": [
        "--batch",
        "-l", "~/.emacs.d/init.el",
        "-l", "~/.emacs.d/lisp/org-files-mcp.el",
        "-f", "org-files-mcp-start"
      ]
    }
  }
}
```

Make sure your `init.el` configures `org-directory`, `org-roam-directory`, and loads org-roam.

### Manual testing

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' | \
emacs --batch -l ~/.emacs.d/init.el -l ~/.emacs.d/lisp/org-files-mcp.el -f org-files-mcp-start
```

## Tools (22 total)

All tool names use the `org_files_` prefix.

### Read (5)

| Tool | Elisp | Description |
|---|---|---|
| `org_files_list_nodes` | `org-roam-db-query` | List nodes with optional filters |
| `org_files_get_node` | `org-roam-node-from-id` | Get node content (markdown/org) |
| `org_files_get_backlinks` | `org-roam-db-query` | Get backlinks for a node |
| `org_files_get_graph` | `org-roam-db-query` | Get link graph (nodes + edges) |
| `org_files_search_nodes` | `org-roam-db-query` + `grep` | Fulltext + attribute search |

### Create/Edit (7)

| Tool | Elisp | Description |
|---|---|---|
| `org_files_create_node` | `org-roam-capture-` / `org-id-get-create` | Create file or heading node |
| `org_files_append_to_node` | `org-end-of-subtree` | Append to node |
| `org_files_update_node_section` | `org-narrow-to-subtree` | Replace/append/prepend body |
| `org_files_delete_node` | `delete-file` / `org-cut-subtree` | Delete node |
| `org_files_rename_node` | `org-edit-headline` | Change title |
| `org_files_refile_node` | `org-refile` | Move heading under another node |
| `org_files_move_node_file` | `rename-file` | Move file to another directory |

### TODO/Schedule (5)

| Tool | Elisp | Description |
|---|---|---|
| `org_files_add_todo` | `org-insert-heading` + `org-todo` | Add TODO item. Targets inbox.org when no parent_id is given. |
| `org_files_toggle_todo_state` | `org-todo` | Cycle/set TODO state |
| `org_files_list_todo_keywords` | — | List configured TODO keyword sequences |
| `org_files_set_scheduled` | `org-schedule` | Set SCHEDULED date |
| `org_files_set_deadline` | `org-deadline` | Set DEADLINE date |

### Property/Tag (3)

| Tool | Elisp | Description |
|---|---|---|
| `org_files_set_property` | `org-set-property` | Set property |
| `org_files_add_tag` | `org-roam-tag-add` | Add tag |
| `org_files_remove_tag` | `org-roam-tag-remove` | Remove tag |

### Agenda (3)

| Tool | Elisp | Description |
|---|---|---|
| `org_files_org_agenda` | `org-agenda-list` | Date-based agenda (scans `org-agenda-files`) |
| `org_files_org_todo_list` | `org-todo-list` | All TODOs (scans `org-agenda-files`) |
| `org_files_org_tags_view` | `org-tags-view` | Tag/property match (scans `org-agenda-files`) |

## Design Decisions

**Why Emacs as the server?** org-roam's full API (agenda, capture, refile, clock, etc.) is only accessible through Elisp. External tools would need to reimplement org-mode's parser.

**Why not Content-Length framing?** MCP stdio transport uses newline-delimited JSON-RPC, not LSP-style Content-Length headers.

**Why Pandoc?** AI agents produce Markdown naturally. Pandoc handles all edge cases (nested lists, tables, math) reliably. It is a hard requirement — the server checks for Pandoc at startup and refuses to start without it.

**Node types:** Both file nodes (level=0) and heading nodes (level>=1) are supported transparently. Agents identify nodes by ID; the server handles the rest.

**inbox.org target:** `org_files_add_todo` without a `parent_id` appends directly to `inbox.org` under `org-directory`, matching the "everything agenda lives in inbox" workflow.

## License

GPL-3.0-or-later
