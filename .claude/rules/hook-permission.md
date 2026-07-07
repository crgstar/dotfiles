# Claude Code の hook permission 仕様

`.claude/hooks/segment-allow.sh` を始めとする permission 関連 hook の挙動と運用ルール。
hook を新規追加・改修するとき、`permissions.allow` を触るときに参照する。

## hook の種類

- **PreToolUse**: 全ツール呼出で発火。allow を ask / deny に「厳しくする」方向のみ有効。静的 `ask` を `allow` に緩めることはできない
- **PostToolUse**: ツール呼出完了後に発火。結果の後処理・ログ記録などに使う。permission 決定には関与しない
- **PermissionRequest**: 静的 `ask` が確定した瞬間にだけ発火。**`ask` を `allow` に緩める唯一の方法**（ask を答える役）。**ヘッドレス (`claude -p`) では発火しない**（公式明記。2026-07 確認）
- **Stop**: Claude がターンを終了した直後に発火。セッション終了通知など副作用に使う。permission 決定には関与しない
- **SessionEnd**: セッション終了直後に発火する副作用 hook（ブロック不可）。入力 JSON は `session_id` / `transcript_path`（絶対パス）/ `cwd` / `reason`。matcher に reason（`clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other`）を指定できる。**ヘッドレスでも発火する**（reason: `prompt_input_exit`）ので、hook からヘッドレス claude を起動する構成では自己ループ防止の除外ガードが要る（例: `reflect-enqueue.sh` の `REFLECT_HEADLESS`）
- PreToolUse / PermissionRequest の両者で `deny` は返せるが、静的 `deny` は hook 発火前に終了するため緩められない

## 典型パターン

- 「デフォ allow + 危険なパターンだけ hook で ask/deny 格上げ」→ PreToolUse
- 「デフォ ask + 安全なパターンだけ hook で allow に素通し」→ PermissionRequest

## 応答 JSON の形式（はまりポイント）

- PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny"|"ask"}}`
- PermissionRequest: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"..."}}}`
- PostToolUse: `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"モデルに注入するメッセージ"}}` / 結果を差し替えるときは `"updatedToolOutput":{...}`
- 素通ししたい（判定せず静的ルールに任せる）ときはいずれも `{}` を返す

## 複数ワイルドカードパターンの末尾 ` *` は空にマッチしない

`Bash(git -C * diff *)` のように `*` を 2 つ以上含むパターンは素の glob として評価され、末尾の ` *` が「スペース + 1 文字以上」を要求する。そのため末尾引数なしの `git -C /path diff` にはマッチせず ask に落ちる（`git -C /path diff --stat` は通る。2026-06 実測）。単一ワイルドカードの `Bash(git status *)` 形式では公式ドキュメント通り bare `git status` にもマッチするので、この問題は複数ワイルドカード時のみ。対策として bare 実行があり得る `git -C` 系サブコマンドには末尾 ` *` なしの版 (`Bash(git -C * diff)` 等) を allow に併記している。starred 版と重複に見えるが消さないこと。

## ヘッドレス (`claude -p` + `dontAsk`) の permission 実測（2026-07）

無人実行の permission 設計で `--settings` / `--allowedTools` に頼る前に読む:

- **`ask` は scope を跨いで `allow` に勝つ**。user settings の `ask: Bash(gh api *)` は、`--settings` でコマンド完全一致の allow を渡しても `dontAsk` 下で自動拒否される（配列 union で ask は消せない）。PermissionRequest hook も `-p` では発火しないため、**静的 ask に入っている操作をヘッドレスで通す方法はない**
- **パス限定のファイルルールはマッチしない**。`Write(//abs/**)` / `Write(~/**)` / `Write(/abs/**)` のどれも `--settings` / `--allowedTools` 経由で効かなかった（パス指定なしの `Write` だけは効く）。パスを絞った書き込み許可は現状組めない
- 上記により、無人実行でモデルに書き込み・送信をさせる設計は避け、**モデルは stdout で結果を返しドライバ（claude 外のスクリプト）が副作用を実行する**構成に倒す（例: `reflect` の outbox パターン。`.claude/skills/reflect/run-headless.sh`）

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
