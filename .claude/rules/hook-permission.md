# Claude Code の hook permission 仕様

`.claude/hooks/segment-allow.sh` を始めとする permission 関連 hook の挙動と運用ルール。
hook を新規追加・改修するとき、`permissions.allow` を触るときに参照する。

## hook の種類

- **PreToolUse**: 全ツール呼出で発火。allow を ask / deny に「厳しくする」方向のみ有効。静的 `ask` を `allow` に緩めることはできない
- **PermissionRequest**: 静的 `ask` が確定した瞬間にだけ発火。**`ask` を `allow` に緩める唯一の方法**（ask を答える役）
- 両者で `deny` は返せるが、静的 `deny` は hook 発火前に終了するため緩められない

## 典型パターン

- 「デフォ allow + 危険なパターンだけ hook で ask/deny 格上げ」→ PreToolUse
- 「デフォ ask + 安全なパターンだけ hook で allow に素通し」→ PermissionRequest

## 応答 JSON の形式（はまりポイント）

- PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny"|"ask"}}`
- PermissionRequest: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"..."}}}`
- 素通ししたい（判定せず静的ルールに任せる）ときはどちらも `{}` を返す

## segment-allow.sh の safe-prefix 自動同期

`gh api ... | jq ...` のような複合コマンドは、Claude Code が `&&`/`||`/`;`/`|` で分割して各セグメントごとに静的 allow を判定する。1 つでも未許可セグメントがあると全体 ask に倒れるため、PermissionRequest hook (`.claude/hooks/segment-allow.sh`) が全セグメントを safe-prefix リストと照合し、すべて safe かつ `gh api` を 1 つ以上含むときだけ allow を返す。

safe-prefix リスト (`~/.claude/hooks/segment-allow.prefixes`) は `setup.sh` が `permissions.allow` から自動生成する:

- `Bash(cmd)` → `cmd` (exact)
- `Bash(cmd *)` → `cmd *`
- `Bash(cmd:*)` → `cmd` と `cmd *` の 2 行 (Claude Code の `:*` セマンティクス)
- `Bash(cmd sub *)` / `Bash(cmd sub:*)` → 多語サブコマンドにも対応 (`git status *` / `gh pr view *` 等)
- 除外: 内部に `*` や `/` を含む複合パターン (`git -C * status *`, `xargs -n* ls *`, `cat */.mirugit/*`) — bash glob として 1 セグメント照合できないので hook の責務外
- `gh api` だけは hook 側で書き込みフラグ (`-f / -F / --input / -X / --method`) の有無を判定する特別扱い（静的 allow には載せない）

### メンテ手順

- 新たに `gh api ... | <cmd> ...` を素通ししたい → `Bash(<cmd> *)` を allow に追加 → `./setup.sh <env>` で prefix 再生成
- hook ロジック側の self-test: `bash .claude/hooks/segment-allow.sh --self-test`
