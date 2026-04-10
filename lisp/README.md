# org-roam-mcp

An MCP (Model Context Protocol) server that runs inside Emacs, providing AI agents with structured access to org-roam.

## Architecture

```
AI Agent ←stdio/JSON-RPC→ Emacs (org-roam-mcp.el)
                            ├── org-roam DB (emacsql/SQLite)
                            ├── org-mode API
                            └── org files
```

Emacs itself is the MCP server. No bridge process, no external dependencies beyond Emacs and org-roam. All 23 tools map directly to org-mode/org-roam Elisp functions.

## Requirements

- Emacs 29.1+
- org-roam 2.2.2+
- org-roam configured with `org-roam-directory` set
- Pandoc (for Markdown→Org conversion)

## Installation

Copy `org-roam-mcp.el` to your load path:

```bash
cp org-roam-mcp.el ~/.emacs.d/lisp/
```

## Usage

### With Claude Code / Claude Desktop

Add to your MCP config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "org-roam": {
      "command": "emacs",
      "args": [
        "--batch",
        "-l", "~/.emacs.d/init.el",
        "-l", "~/.emacs.d/lisp/org-roam-mcp.el",
        "-f", "org-roam-mcp-start"
      ]
    }
  }
}
```

Make sure your `init.el` configures `org-roam-directory` and loads org-roam.

### Manual testing

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' | \
emacs --batch -l ~/.emacs.d/init.el -l org-roam-mcp.el -f org-roam-mcp-start
```

## Tools (23 total)

### Read (5)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_list_nodes` | `org-roam-db-query` | List nodes with optional filters |
| `org_roam_get_node` | `org-roam-node-from-id` | Get node content (markdown/org) |
| `org_roam_get_backlinks` | `org-roam-db-query` | Get backlinks for a node |
| `org_roam_get_graph` | `org-roam-db-query` | Get link graph (nodes + edges) |
| `org_roam_search_nodes` | `org-roam-db-query` + `grep` | Fulltext + attribute search |

### Create/Edit (7)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_create_node` | `org-roam-capture-` / `org-id-get-create` | Create file or heading node |
| `org_roam_append_to_node` | `org-end-of-subtree` | Append to node |
| `org_roam_update_node_section` | `org-narrow-to-subtree` | Replace/append/prepend body |
| `org_roam_delete_node` | `delete-file` / `org-cut-subtree` | Delete node |
| `org_roam_rename_node` | `org-edit-headline` | Change title |
| `org_roam_refile_node` | `org-refile` | Move heading under another node |
| `org_roam_move_node_file` | `rename-file` | Move file to another directory |

### TODO/Schedule (4)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_add_todo` | `org-insert-heading` + `org-todo` | Add TODO item |
| `org_roam_toggle_todo_state` | `org-todo` | Cycle/set TODO state |
| `org_roam_set_scheduled` | `org-schedule` | Set SCHEDULED date |
| `org_roam_set_deadline` | `org-deadline` | Set DEADLINE date |

### Property/Tag (3)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_set_property` | `org-set-property` | Set property |
| `org_roam_add_tag` | `org-roam-tag-add` | Add tag |
| `org_roam_remove_tag` | `org-roam-tag-remove` | Remove tag |

### Agenda (3)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_org_agenda` | `org-agenda-list` | Date-based agenda |
| `org_roam_org_todo_list` | `org-todo-list` | All TODOs |
| `org_roam_org_tags_view` | `org-tags-view` | Tag/property match |

### Dailies (1)

| Tool | Elisp | Description |
|---|---|---|
| `org_roam_get_daily` | `org-roam-dailies-find-date` | Get/create daily note |

## Design Decisions

**Why Emacs as the server?** org-roam's full API (agenda, capture, refile, clock, etc.) is only accessible through Elisp. External tools would need to reimplement org-mode's parser.

**Why not Content-Length framing?** MCP stdio transport uses newline-delimited JSON-RPC, not LSP-style Content-Length headers.

**Why Pandoc?** AI agents produce Markdown naturally. Pandoc handles all edge cases (nested lists, tables, math) reliably. It is a hard requirement — the server checks for Pandoc at startup and refuses to start without it.

**Node types:** Both file nodes (level=0) and heading nodes (level>=1) are supported transparently. Agents identify nodes by ID; the server handles the rest.

## License

GPL-3.0-or-later
