# org-files MCP Server 仕様書

## 概要

Emacs上のorg-roamをバックエンドとするMCPサーバー。
AIエージェントがorg記法を直接書くことなく、構造化されたツール呼び出しを通じてorg-roamのノート管理を行う。

**設計原則**

- エージェントにorg記法の知識を要求しない
- 構造操作はツール引数で明示、本文テキストのみMarkdown入力→org変換
- org-roamのDB（SQLite + emacsql）をフル活用して高速検索
- Emacsプロセスをバックエンドとし、Elisp APIを直接呼び出す
- 各ツールがorg-mode/org-roamの関数と可能な限り1対1で対応する

**アーキテクチャ**

```
AIエージェント ←stdio/JSON-RPC→ Emacs (MCP Server in Elisp)
                                    ├── org-roam DB (emacsql/SQLite)
                                    ├── org-mode API
                                    └── orgファイル群
```

**ノードの種類**

org-roamには2種類のノードがある。本仕様ではすべてのツールが両方のノード種別を扱える。

- **ファイルノード** (level=0): ファイル全体が1つのノード。ファイル先頭にIDと`#+title:`を持つ。
- **見出しノード** (level>=1): ファイル内の任意の見出しにIDを付与してノードとしたもの。

org-roam DBのnodesテーブルでは`level`カラムで区別される。すべてのノードはIDで一意に特定されるため、ツール呼び出し時にファイルノードか見出しノードかをエージェントが意識する必要は基本的にない。サーバー側がノード種別に応じて適切な操作を行う。

---

## ツールインターフェース一覧

### 読み取り系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `list_nodes` | ノード一覧を取得 | `org-roam-db-query` (nodes) | ― | `directory`, `tag`, `level`, `limit` |
| `get_node` | ノードの内容を取得 | `org-roam-node-from-id` | `id` or `title` | `format` (org/markdown) |
| `get_backlinks` | バックリンク一覧 | `org-roam-db-query` (links) | `id` | ― |
| `get_graph` | リンクグラフを取得 | `org-roam-db-query` (links JOIN nodes) | ― | `id`, `depth` |

### 検索系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `search_nodes` | キーワード・属性で検索 | `org-roam-db-query` + `ripgrep` | ― | `query`, `tag`, `todo_state`, `property`, `level`, `limit` |

### 作成・編集系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `create_node` | 新規ノードを作成 | `org-roam-capture-` | `title` | `parent_id`, `body`(md), `tags`, `properties`, `links_to`, `template` |
| `append_to_node` | ノード末尾にコンテンツ追加 | バッファ操作（※注1） | `id`, `body`(md) | ― |
| `update_node_section` | ノードの本文を更新 | バッファ操作（※注1） | `id`, `body`(md) | `mode` (replace/append/prepend) |
| `delete_node` | ノードを削除 | `delete-file` / `org-cut-subtree` | `id`, `confirm` | ― |
| `rename_node` | タイトル変更 | `org-edit-headline` / keyword置換 | `id`, `new_title` | ― |
| `refile_node` | 見出しノードを別ノード配下に移動 | `org-refile` | `id`, `target_id` | ― |
| `move_node_file` | ファイルノードを別ディレクトリに移動 | `rename-file` | `id`, `new_directory` | ― |

### TODO/スケジュール系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `add_todo` | TODO項目を追加 | `org-insert-heading` + `org-todo` | `heading` | `parent_id`, `state`, `priority`, `tags`, `scheduled`, `deadline`, `body`(md) |
| `toggle_todo_state` | TODOステートを変更 | `org-todo` | `id` | `new_state` |
| `set_scheduled` | SCHEDULED日時を設定 | `org-schedule` | `id`, `date` | ― |
| `set_deadline` | DEADLINE日時を設定 | `org-deadline` | `id`, `date` | ― |

### プロパティ・タグ系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `set_property` | プロパティを設定 | `org-set-property` | `id`, `name`, `value` | ― |
| `add_tag` | タグを追加 | `org-roam-tag-add` | `id`, `tag` | ― |
| `remove_tag` | タグを削除 | `org-roam-tag-remove` | `id`, `tag` | ― |

### Agenda系

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `org_agenda` | 日付ベースのagenda取得 | `org-agenda-list` | ― | `span` |
| `org_todo_list` | 全TODO一覧を取得 | `org-todo-list` | ― | `match` |
| `org_tags_view` | タグマッチで項目検索 | `org-tags-view` | `match` | `todo_only` |

### Dailies連携

| ツール名 | 説明 | 対応Elisp | 必須パラメータ | 主なオプション |
|---|---|---|---|---|
| `get_daily` | dailyノートを取得・作成 | `org-roam-dailies-find-date` | ― | `date`, `format` |

### ※注1: バッファ操作の組み合わせ

`append_to_node` と `update_node_section` はorg-mode/org-roamに対応する単一関数がない。
以下のorg-mode関数の組み合わせで実装する:

- `org-roam-node-from-id` → ノード特定
- `org-narrow-to-subtree` → 見出しノードの範囲限定
- `org-end-of-subtree` → サブツリー末尾への移動
- `org-end-of-meta-data` → プロパティドロワー直後への移動

### Obsidian MCP との対応

| Obsidian MCP | org-roam MCP | 備考 |
|---|---|---|
| list_files_in_vault | `list_nodes` | DBベースで高速 |
| list_files_in_dir | `list_nodes` (filter: dir) | |
| get_file_contents | `get_node` | markdown形式で返却可 |
| search | `search_nodes` | 全文+DB属性検索 |
| patch_content | `update_node_section` | ノード単位の編集 |
| append_content | `append_to_node` | |
| delete_file | `delete_node` | ファイルノード/見出しノード両対応 |
| move_file | `move_node_file` / `refile_node` | ファイル移動/refile |
| manage_tags | `add_tag` / `remove_tag` | 各操作が独立 |
| update_frontmatter | `set_property` | プロパティドロワー |
| ― | `create_node` | org-roam固有 |
| ― | `get_backlinks` | org-roam固有 |
| ― | `get_graph` | org-roam固有 |
| ― | `rename_node` | タイトル変更 |
| ― | `refile_node` | org-mode固有 |
| ― | `add_todo` | org-mode固有 |
| ― | `set_scheduled` | org-mode固有 |
| ― | `set_deadline` | org-mode固有 |
| ― | `org_agenda` | org-mode固有 |
| ― | `org_todo_list` | org-mode固有 |
| ― | `org_tags_view` | org-mode固有 |
| ― | `get_daily` | org-roam-dailies固有 |

---

## ツール詳細定義

### 1. `list_nodes`

**対応:** `org-roam-db-query` (nodesテーブル)

```json
{
  "name": "list_nodes",
  "description": "org-roamデータベースからノード一覧を取得する。ファイルノード・見出しノードの両方を返す。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "directory": {
        "type": "string",
        "description": "特定ディレクトリに限定（省略時は全ノード）"
      },
      "tag": {
        "type": "string",
        "description": "特定タグを持つノードに限定"
      },
      "level": {
        "type": "integer",
        "description": "ノードレベルでフィルタ（0=ファイルノードのみ、1=第1レベル見出しのみ、省略時=全レベル）"
      },
      "limit": {
        "type": "integer",
        "description": "取得件数上限（デフォルト: 50）",
        "default": 50
      }
    }
  }
}
```

**Elisp実装イメージ:**
```elisp
(org-roam-db-query
 [:select [id title file level tags]
  :from nodes
  :limit $s1]
 limit)
```

**戻り値:**
```json
{
  "nodes": [
    {
      "id": "20260410120000-some-uuid",
      "title": "Arcanumアーキテクチャ設計",
      "file": "~/org-roam/arcanum-architecture.org",
      "level": 0,
      "tags": ["project", "arcanum"]
    },
    {
      "id": "20260410130000-sub-uuid",
      "title": "MLIR Dialect設計",
      "file": "~/org-roam/arcanum-architecture.org",
      "level": 1,
      "tags": ["arcanum"]
    }
  ]
}
```

---

### 2. `get_node`

**対応:** `org-roam-node-from-id` + `org-narrow-to-subtree` + `org-export`

ファイルノードならファイル全体、見出しノードならサブツリーの内容を返す。

```json
{
  "name": "get_node",
  "description": "ノードIDまたはタイトルでノートの内容を取得する。ファイルノードならファイル全体、見出しノードならサブツリーの内容を返す。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "ノードID"
      },
      "title": {
        "type": "string",
        "description": "ノードタイトル（IDが不明の場合）"
      },
      "format": {
        "type": "string",
        "enum": ["org", "markdown"],
        "description": "出力形式（デフォルト: markdown）",
        "default": "markdown"
      }
    },
    "oneOf": [
      { "required": ["id"] },
      { "required": ["title"] }
    ]
  }
}
```

**戻り値:**
```json
{
  "id": "20260410130000-sub-uuid",
  "title": "MLIR Dialect設計",
  "level": 1,
  "file": "~/org-roam/arcanum-architecture.org",
  "tags": ["arcanum"],
  "properties": { "CATEGORY": "arcanum" },
  "content": "（ノード本文をmarkdownまたはorg形式で）"
}
```

---

### 3. `get_backlinks`

**対応:** `org-roam-db-query` (linksテーブル WHERE dest = id)

```json
{
  "name": "get_backlinks",
  "description": "指定ノードへのバックリンク一覧を取得する",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "ノードID" }
    },
    "required": ["id"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(org-roam-db-query
 [:select [source dest]
  :from links
  :where (= dest $s1)
  :and (= type "id")]
 node-id)
```

---

### 4. `get_graph`

**対応:** `org-roam-db-query` (links JOIN nodes)

```json
{
  "name": "get_graph",
  "description": "ノード間のリンク関係をグラフとして取得する",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "起点ノードID（省略時は全体グラフ）"
      },
      "depth": {
        "type": "integer",
        "description": "リンクの探索深度（デフォルト: 2）",
        "default": 2
      }
    }
  }
}
```

**戻り値:**
```json
{
  "nodes": [
    { "id": "...", "title": "ノードA", "level": 0 },
    { "id": "...", "title": "ノードB", "level": 1 }
  ],
  "edges": [
    { "source": "ノードA-id", "target": "ノードB-id" }
  ]
}
```

---

### 5. `search_nodes`

**対応:** `org-roam-db-query` (DB属性フィルタ) + `ripgrep` (全文検索)

```json
{
  "name": "search_nodes",
  "description": "ノードをキーワードまたは属性で検索する。ファイルノード・見出しノードの両方を対象とする。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "検索キーワード（本文全文検索）"
      },
      "tag": {
        "type": "string",
        "description": "タグでフィルタ"
      },
      "todo_state": {
        "type": "string",
        "description": "TODOステートでフィルタ（TODO, DONE等）"
      },
      "property": {
        "type": "object",
        "description": "プロパティ名と値でフィルタ",
        "properties": {
          "name": { "type": "string" },
          "value": { "type": "string" }
        }
      },
      "level": {
        "type": "integer",
        "description": "ノードレベルでフィルタ（0=ファイルノードのみ、省略時=全レベル）"
      },
      "limit": {
        "type": "integer",
        "default": 20
      }
    }
  }
}
```

**備考:** `query`による全文検索は`ripgrep`で実行。DB属性フィルタはemacsql経由。両方指定された場合はAND条件。

---

### 6. `create_node`

**対応:** `org-roam-capture-` (ファイルノード) / `org-id-get-create` + `org-insert-heading` (見出しノード)

`parent_id` の有無でファイルノードと見出しノードを使い分ける。

```json
{
  "name": "create_node",
  "description": "新しいorg-roamノードを作成する。parent_id省略でファイルノード、指定で見出しノード。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "ノードタイトル"
      },
      "parent_id": {
        "type": "string",
        "description": "親ノードID。指定すると見出しノードとして親ノード配下に作成。省略時はファイルノード。"
      },
      "body": {
        "type": "string",
        "description": "本文（Markdown形式。サーバー側でorgに変換）"
      },
      "tags": {
        "type": "array",
        "items": { "type": "string" },
        "description": "タグ（ファイルノード: filetags、見出しノード: 見出しタグ）"
      },
      "properties": {
        "type": "object",
        "description": "追加プロパティ（key-valueペア）",
        "additionalProperties": { "type": "string" }
      },
      "links_to": {
        "type": "array",
        "items": { "type": "string" },
        "description": "リンク先ノードID一覧（本文末尾にリンク追加）"
      },
      "template": {
        "type": "string",
        "description": "使用するcaptureテンプレートキー（省略時はデフォルト）"
      }
    },
    "required": ["title"]
  }
}
```

**Elisp実装イメージ（ファイルノード）:**
```elisp
(org-roam-capture-
 :node (org-roam-node-create :title title)
 :templates org-roam-capture-templates)
```

**Elisp実装イメージ（見出しノード）:**
```elisp
(let* ((parent (org-roam-node-from-id parent-id))
       (file (org-roam-node-file parent))
       (pos (org-roam-node-point parent)))
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (org-end-of-subtree t)
    (let ((child-level (1+ (org-roam-node-level parent))))
      (insert "\n" (make-string child-level ?*) " " title "\n")
      (org-id-get-create)
      (when tags (org-set-tags (string-join tags ":")))
      (when body (insert (mcp-org--md-to-org body) "\n")))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 7. `append_to_node`

**対応:** `org-roam-node-from-id` + `org-end-of-subtree` + バッファ挿入

```json
{
  "name": "append_to_node",
  "description": "ノード末尾にコンテンツを追加する。ファイルノードならファイル末尾、見出しノードならサブツリー末尾。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象ノードID"
      },
      "body": {
        "type": "string",
        "description": "追加する本文（Markdown形式）"
      }
    },
    "required": ["id", "body"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node))
       (level (org-roam-node-level node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (if (= level 0)
        (goto-char (point-max))
      (org-end-of-subtree t))
    (insert "\n" (mcp-org--md-to-org body) "\n")
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 8. `update_node_section`

**対応:** `org-roam-node-from-id` + `org-narrow-to-subtree` + `org-end-of-meta-data` + バッファ置換

```json
{
  "name": "update_node_section",
  "description": "ノードの本文を更新する。ファイルノードならメタデータ以降、見出しノードなら見出し直下の本文が対象。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象ノードID"
      },
      "body": {
        "type": "string",
        "description": "新しい本文内容（Markdown形式）"
      },
      "mode": {
        "type": "string",
        "enum": ["replace", "append", "prepend"],
        "default": "replace"
      }
    },
    "required": ["id", "body"]
  }
}
```

**備考:** `replace`は子見出し（子ノード）を維持し、本文テキスト部分のみ置き換える。

---

### 9. `delete_node`

**対応:** `delete-file` + `org-roam-db-clear-file` (ファイルノード) / `org-cut-subtree` (見出しノード)

```json
{
  "name": "delete_node",
  "description": "ノードを削除する。ファイルノードならファイル削除、見出しノードならサブツリー削除。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "削除対象ノードID"
      },
      "confirm": {
        "type": "boolean",
        "description": "削除確認フラグ（trueでないと実行しない）"
      }
    },
    "required": ["id", "confirm"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node))
       (level (org-roam-node-level node)))
  (if (= level 0)
      (progn
        (org-roam-db-clear-file file)
        (delete-file file))
    (with-current-buffer (find-file-noselect file)
      (goto-char (org-roam-node-point node))
      (org-cut-subtree)
      (save-buffer))
    (org-roam-db-update-file file)))
```

---

### 10. `rename_node`

**対応:** `org-edit-headline` (見出しノード) / `#+title:` keyword置換 (ファイルノード)

タイトル変更のみを行う。移動は `refile_node` / `move_node_file` を使用。

```json
{
  "name": "rename_node",
  "description": "ノードのタイトルを変更する。見出しノードなら見出しテキスト、ファイルノードなら#+title:を変更。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象ノードID"
      },
      "new_title": {
        "type": "string",
        "description": "新しいタイトル"
      }
    },
    "required": ["id", "new_title"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node))
       (level (org-roam-node-level node)))
  (with-current-buffer (find-file-noselect file)
    (if (= level 0)
        ;; ファイルノード: #+title: を変更
        (progn
          (goto-char (point-min))
          (re-search-forward "^#\\+title:" nil t)
          (kill-line)
          (insert " " new-title))
      ;; 見出しノード: org-edit-headline
      (goto-char (org-roam-node-point node))
      (org-edit-headline new-title))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 11. `refile_node`

**対応:** `org-refile`

見出しノードを別のノード配下に移動する。org-roamはIDベースリンクなのでリンクは壊れない。

```json
{
  "name": "refile_node",
  "description": "見出しノードを別のノード配下にrefileする。ファイルノードには使用不可（move_node_fileを使用）。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "移動する見出しノードのID"
      },
      "target_id": {
        "type": "string",
        "description": "refile先の親ノードID"
      }
    },
    "required": ["id", "target_id"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (source-file (org-roam-node-file node))
       (target (org-roam-node-from-id target-id))
       (target-file (org-roam-node-file target))
       (target-pos (org-roam-node-point target)))
  ;; 元の位置でサブツリーをカット
  (with-current-buffer (find-file-noselect source-file)
    (goto-char (org-roam-node-point node))
    (org-cut-subtree))
  ;; ターゲットの配下にペースト
  (with-current-buffer (find-file-noselect target-file)
    (goto-char target-pos)
    (org-end-of-subtree t)
    (insert "\n")
    (org-paste-subtree (1+ (org-roam-node-level target)))
    (save-buffer))
  ;; DB更新
  (org-roam-db-update-file source-file)
  (unless (string= source-file target-file)
    (org-roam-db-update-file target-file)))
```

---

### 12. `move_node_file`

**対応:** `rename-file`

ファイルノードを別ディレクトリに移動する。見出しノードには使用不可（`refile_node`を使用）。

```json
{
  "name": "move_node_file",
  "description": "ファイルノードを別ディレクトリに移動する。見出しノードには使用不可（refile_nodeを使用）。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "移動するファイルノードのID"
      },
      "new_directory": {
        "type": "string",
        "description": "移動先ディレクトリ（org-roam-directoryからの相対パス）"
      }
    },
    "required": ["id", "new_directory"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node))
       (new-path (expand-file-name
                  (file-name-nondirectory file)
                  (expand-file-name new-directory org-roam-directory))))
  (with-current-buffer (find-file-noselect file)
    (rename-file file new-path)
    (set-visited-file-name new-path t t)
    (save-buffer))
  (org-roam-db-update-file new-path))
```

---

### 13. `add_todo`

**対応:** `org-insert-heading` + `org-todo` + `org-set-tags` + `org-schedule` + `org-deadline`

```json
{
  "name": "add_todo",
  "description": "TODO項目を見出しとして追加する。parent_id省略時はdailyの当日ファイルに追加。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "parent_id": {
        "type": "string",
        "description": "追加先の親ノードID（省略時はdailyの当日ファイル）"
      },
      "heading": {
        "type": "string",
        "description": "TODO見出しテキスト"
      },
      "state": {
        "type": "string",
        "enum": ["TODO", "DOING", "DONE", "WAITING", "CANCELLED"],
        "default": "TODO"
      },
      "priority": {
        "type": "string",
        "enum": ["A", "B", "C"],
        "description": "優先度"
      },
      "tags": {
        "type": "array",
        "items": { "type": "string" }
      },
      "scheduled": {
        "type": "string",
        "description": "SCHEDULED日時（ISO 8601形式）"
      },
      "deadline": {
        "type": "string",
        "description": "DEADLINE日時（ISO 8601形式）"
      },
      "body": {
        "type": "string",
        "description": "補足テキスト（Markdown形式）"
      }
    },
    "required": ["heading"]
  }
}
```

**備考:** `add_todo`は複数のorg-mode関数の合成だが、「TODOを追加する」という操作自体がorg-modeでも複数ステップ（見出し挿入→TODO設定→タグ設定→スケジュール設定）で構成されるため、利便性のためにまとめている。`scheduled`/`deadline`を個別に設定したい場合は`set_scheduled`/`set_deadline`を使用。

---

### 14. `toggle_todo_state`

**対応:** `org-todo`

```json
{
  "name": "toggle_todo_state",
  "description": "ノードのTODOステートを変更する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象の見出しノードID"
      },
      "new_state": {
        "type": "string",
        "description": "新しいステート（省略時はorg-modeのサイクルに従う）"
      }
    },
    "required": ["id"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (if new-state
        (org-todo new-state)
      (org-todo))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 15. `set_scheduled`

**対応:** `org-schedule`

```json
{
  "name": "set_scheduled",
  "description": "ノードのSCHEDULED日時を設定する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象ノードID"
      },
      "date": {
        "type": "string",
        "description": "日時（ISO 8601形式。空文字でSCHEDULED削除）"
      }
    },
    "required": ["id", "date"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (if (string-empty-p date)
        (org-schedule '(4))  ;; C-u prefix で削除
      (org-schedule nil date))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 16. `set_deadline`

**対応:** `org-deadline`

```json
{
  "name": "set_deadline",
  "description": "ノードのDEADLINE日時を設定する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "対象ノードID"
      },
      "date": {
        "type": "string",
        "description": "日時（ISO 8601形式。空文字でDEADLINE削除）"
      }
    },
    "required": ["id", "date"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (if (string-empty-p date)
        (org-deadline '(4))
      (org-deadline nil date))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 17. `set_property`

**対応:** `org-set-property`

```json
{
  "name": "set_property",
  "description": "ノードのプロパティを設定する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "ノードID" },
      "name": { "type": "string", "description": "プロパティ名" },
      "value": { "type": "string", "description": "プロパティ値" }
    },
    "required": ["id", "name", "value"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (org-set-property name value)
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 18. `add_tag`

**対応:** `org-roam-tag-add`

```json
{
  "name": "add_tag",
  "description": "ノードにタグを追加する。ファイルノードはfiletags、見出しノードは見出しタグを操作。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "ノードID" },
      "tag": { "type": "string", "description": "追加するタグ" }
    },
    "required": ["id", "tag"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (org-roam-tag-add (list tag))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 19. `remove_tag`

**対応:** `org-roam-tag-remove`

```json
{
  "name": "remove_tag",
  "description": "ノードからタグを削除する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "ノードID" },
      "tag": { "type": "string", "description": "削除するタグ" }
    },
    "required": ["id", "tag"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(let* ((node (org-roam-node-from-id id))
       (file (org-roam-node-file node)))
  (with-current-buffer (find-file-noselect file)
    (goto-char (org-roam-node-point node))
    (org-roam-tag-remove (list tag))
    (save-buffer))
  (org-roam-db-update-file file))
```

---

### 20. `org_agenda`

**対応:** `org-agenda-list`

```json
{
  "name": "org_agenda",
  "description": "日付ベースのagendaを取得する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "span": {
        "type": "integer",
        "description": "表示日数（デフォルト: 7）",
        "default": 7
      }
    }
  }
}
```

**Elisp実装イメージ:**
```elisp
(let ((org-agenda-span span))
  (org-agenda-list))
;; agendaバッファからエントリをパースしてJSONに変換
```

---

### 21. `org_todo_list`

**対応:** `org-todo-list`

```json
{
  "name": "org_todo_list",
  "description": "全TODO項目の一覧を取得する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "match": {
        "type": "string",
        "description": "TODOキーワードでフィルタ（例: 'TODO', 'DOING|WAITING'。省略時は全TODO）"
      }
    }
  }
}
```

**Elisp実装イメージ:**
```elisp
(org-todo-list match)
;; agendaバッファからエントリをパースしてJSONに変換
```

---

### 22. `org_tags_view`

**対応:** `org-tags-view`

```json
{
  "name": "org_tags_view",
  "description": "タグ/プロパティマッチで項目を検索する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "match": {
        "type": "string",
        "description": "タグ/プロパティマッチ文字列（例: '+work-done', 'PRIORITY=\"A\"'）"
      },
      "todo_only": {
        "type": "boolean",
        "description": "trueの場合、TODO項目のみに限定",
        "default": false
      }
    },
    "required": ["match"]
  }
}
```

**Elisp実装イメージ:**
```elisp
(org-tags-view todo-only match)
;; agendaバッファからエントリをパースしてJSONに変換
```

---

### 23. `get_daily`

**対応:** `org-roam-dailies-find-date`

```json
{
  "name": "get_daily",
  "description": "指定日のdailyノートを取得する（存在しなければ作成）",
  "inputSchema": {
    "type": "object",
    "properties": {
      "date": {
        "type": "string",
        "description": "日付（ISO 8601形式、省略時は今日）"
      },
      "format": {
        "type": "string",
        "enum": ["org", "markdown"],
        "default": "markdown"
      }
    }
  }
}
```

---

## Elisp関数対応一覧

| MCPツール | 対応するElisp関数 | 1対1対応 |
|---|---|---|
| `list_nodes` | `org-roam-db-query` (nodesテーブル) | ○ |
| `get_node` | `org-roam-node-from-id` | ○ |
| `get_backlinks` | `org-roam-db-query` (linksテーブル) | ○ |
| `get_graph` | `org-roam-db-query` (links JOIN nodes) | ○ |
| `search_nodes` | `org-roam-db-query` + `ripgrep` | △ 2つの仕組みを合成 |
| `create_node` | `org-roam-capture-` / `org-id-get-create` | △ ノード種別で分岐 |
| `append_to_node` | `org-end-of-subtree` + バッファ挿入 | △ 単一関数なし |
| `update_node_section` | `org-narrow-to-subtree` + バッファ置換 | △ 単一関数なし |
| `delete_node` | `delete-file` / `org-cut-subtree` | △ ノード種別で分岐 |
| `rename_node` | `org-edit-headline` / keyword置換 | ○ |
| `refile_node` | `org-refile` | ○ |
| `move_node_file` | `rename-file` | ○ |
| `add_todo` | `org-insert-heading` + `org-todo` + 他 | △ 利便性のため合成 |
| `toggle_todo_state` | `org-todo` | ○ |
| `set_scheduled` | `org-schedule` | ○ |
| `set_deadline` | `org-deadline` | ○ |
| `set_property` | `org-set-property` | ○ |
| `add_tag` | `org-roam-tag-add` | ○ |
| `remove_tag` | `org-roam-tag-remove` | ○ |
| `org_agenda` | `org-agenda-list` | ○ |
| `org_todo_list` | `org-todo-list` | ○ |
| `org_tags_view` | `org-tags-view` | ○ |
| `get_daily` | `org-roam-dailies-find-date` | ○ |

**△マークの説明:**
- `search_nodes`: DB属性検索とripgrep全文検索の2つを統合。orgに統一的な検索関数がないため。
- `create_node`: ファイルノード（`org-roam-capture-`）と見出しノード（`org-id-get-create`）で内部分岐。
- `append_to_node` / `update_node_section`: orgにこのレベルの抽象APIがなく、バッファ操作の組み合わせ。
- `delete_node`: ファイルノード（`delete-file`）と見出しノード（`org-cut-subtree`）で内部分岐。
- `add_todo`: 複数ステップの操作を利便性のために合成。

---

## Markdown → Org 変換ルール（本文テキスト用）

ツールの `body` フィールドに渡されるMarkdownテキストに適用する変換:

| Markdown | Org |
|---|---|
| `**bold**` | `*bold*` |
| `*italic*` | `/italic/` |
| `~~strikethrough~~` | `+strikethrough+` |
| `` `code` `` | `~code~` |
| `[text](url)` | `[[url][text]]` |
| `- item` | `- item` |
| `- [ ] item` | `- [ ] item` |
| `- [x] item` | `- [X] item` |
| `> blockquote` | `#+begin_quote ... #+end_quote` |
| `` ```lang ... ``` `` | `#+begin_src lang ... #+end_src` |
| `# Heading` | 見出しレベルに応じた `*` 変換 |
| `---` | `-----` |

**注意:** ノード間リンクは `links_to` パラメータで明示的に渡す。本文中の `[[node-title]]` 風の記法はサーバー側でorg-roam IDリンクに解決する。

### 実装方針

Pandocを必須依存とし、起動時にPandocの存在を検証する。

```elisp
(defun org-roam-mcp--check-pandoc ()
  "Verify Pandoc is available. Signal error if not found."
  (unless (executable-find "pandoc")
    (error "Pandoc is required but not found in PATH")))

(defun org-roam-mcp--md-to-org (md-string)
  "Convert Markdown MD-STRING to org format using Pandoc."
  (with-temp-buffer
    (insert md-string)
    (let ((exit-code (shell-command-on-region
                      (point-min) (point-max)
                      "pandoc -f markdown -t org --wrap=preserve"
                      t t)))
      (unless (zerop exit-code)
        (error "Pandoc conversion failed (exit code %d)" exit-code)))
    (buffer-string)))
```

Pandocはネストしたリスト、テーブル、数式等のエッジケース処理が成熟している。
プロセス起動のオーバーヘッドはあるが、1回のツール呼び出しにつき1回なので実用上問題ない。

---

## エラーハンドリング

| コード | 意味 |
|---|---|
| -32001 | ノードが見つからない |
| -32002 | 見出しが見つからない |
| -32003 | DB接続エラー |
| -32004 | 削除確認なし（confirm=false） |
| -32005 | Markdown変換エラー |
| -32006 | 操作とノード種別の不一致（ファイルノードにrefile等） |

---

## 実装優先度

### Phase 1: 読み取り（最小限の価値提供）
- `list_nodes`
- `get_node`
- `search_nodes`
- `get_backlinks`

### Phase 2: 書き込み（基本的なノート操作）
- `create_node`
- `append_to_node`
- `add_todo`
- `add_tag` / `remove_tag`

### Phase 3: 高度な編集
- `update_node_section`
- `toggle_todo_state`
- `set_scheduled` / `set_deadline`
- `set_property`
- `delete_node`
- `rename_node`
- `refile_node` / `move_node_file`
- `get_daily`

### Phase 4: Agenda統合
- `org_agenda`
- `org_todo_list`
- `org_tags_view`
- `get_graph`
