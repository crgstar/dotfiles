# dotfiles

Claude Code の設定ファイル・スキル、およびシェル設定を管理する dotfiles リポジトリ。

## セットアップ

```bash
./setup.sh [home|work]  # 環境名は必須引数（省略すると共通設定のみ）
```

- `jq` が必要（設定のマージに使用）
- 生成される `.claude/settings.merged.json` は gitignore 済み

## 設定の仕組み

- `.claude/settings.json` — 全環境共通の設定（ベース）
- `.claude/settings.local/<env>.json` — 環境別の追加設定
- `.claude/settings.local.json` — このリポジトリ固有のプロジェクト設定
- setup.sh が jq で両者をマージし `~/.claude/settings.json` にシンボリックリンク
- IMPORTANT: 配列フィールド（permissions.allow 等）はマージ時に結合される（上書きではない）
- IMPORTANT: ルールや設定を追加・削除した場合は毎回 `./setup.sh <env>` を実行してマージ結果を更新する
  - 2回目以降は `basename "$(readlink ~/.zshrc.local)" .zsh` で現在の env を判定できる
  - 初回（`~/.zshrc.local` が未作成）はユーザーに `home` / `work` を確認する

## シェル設定の仕組み

- `.zshrc` — 全環境共通の zsh 設定
- `zshrc.local/<env>.zsh` — 環境別の追加設定（`~/.zshrc.local` にリンクされる）
- `.zshrc` の末尾で `~/.zshrc.local` を source する構成

## ファイル追加時の規約

- 設定ファイルは `link_file` 関数でシンボリックリンクする（コピーではない）
- 新しいリンク対象を追加した場合は `setup.sh` にも `link_file` の呼び出しを追加する
- スキルは `.claude/skills/<skill-name>/SKILL.md` に配置し、`~/.claude/skills/` へリンクする

## Claude Code の hook permission 仕様

- **PreToolUse**: 全ツール呼出で発火。allow を ask / deny に「厳しくする」方向のみ有効。静的 `ask` を `allow` に緩めることはできない
- **PermissionRequest**: 静的 `ask` が確定した瞬間にだけ発火。**`ask` を `allow` に緩める唯一の方法**（ask を答える役）
- どちらも `deny` は可能だが、静的 `deny` は hook 発火前に終了するので hook で緩めることはできない

典型パターン:
- 「デフォ allow + 危険なパターンだけ hook で ask/deny 格上げ」→ PreToolUse
- 「デフォ ask + 安全なパターンだけ hook で allow に素通し」→ PermissionRequest

応答 JSON の形式（はまりポイント）:
- PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny"|"ask"}}`
- PermissionRequest: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"..."}}}`
- 素通ししたい（判定せず静的ルールに任せる）ときはどちらも `{}` を返す

### segment-allow.sh の safe-prefix 自動同期

`gh api ... | jq ...` のような複合コマンドは、Claude Code が `&&`/`||`/`;`/`|` で分割して各セグメントごとに静的 allow を判定する。1 つでも未許可セグメントがあると全体 ask に倒れるため、PermissionRequest hook (`.claude/hooks/segment-allow.sh`) が全セグメントを safe-prefix リストと照合し、すべて safe かつ `gh api` を 1 つ以上含むときだけ allow を返す。

safe-prefix リスト (`~/.claude/hooks/segment-allow.prefixes`) は `setup.sh` が `permissions.allow` から自動生成する:
- `Bash(cmd)` → `cmd` (exact)
- `Bash(cmd *)` → `cmd *`
- `Bash(cmd:*)` → `cmd` と `cmd *` の 2 行 (Claude Code の `:*` セマンティクス)
- `Bash(cmd sub *)` / `Bash(cmd sub:*)` → 多語サブコマンドにも対応 (`git status *` / `gh pr view *` 等)
- 除外: 内部に `*` や `/` を含む複合パターン (`git -C * status *`, `xargs -n* ls *`, `cat */.mirugit/*`) — bash glob として 1 セグメント照合できないので hook の責務外
- `gh api` だけは hook 側で書き込みフラグ (`-f / -F / --input / -X / --method`) の有無を判定する特別扱い（静的 allow には載せない）

メンテ手順:
- 新たに `gh api ... | <cmd> ...` を素通ししたい → `Bash(<cmd> *)` を allow に追加 → `./setup.sh <env>` で prefix 再生成
- hook ロジック側の self-test: `bash .claude/hooks/segment-allow.sh --self-test`

## setup.sh のコンフリクト対応

`.claude/settings.merged.json` / `.claude/CLAUDE.merged.md` は、セッション中の `/update-config` や動的 allow 追加で既存 merged がソースより先行すると対話プロンプトで停止する。

- **順序のみの差分**: 即 `n` で上書き（ソース正）
- **実質的な追加あり**: 先にソースへ還流してから `n`
  - 共通 → `.claude/settings.json` / `.claude/CLAUDE.md`
  - 環境別 → `.claude/settings.local/<env>.json` / `.claude/CLAUDE.local/<env>.md`
- 取りこぼしは `.bak` から復元可能
- **事前検知**: セッション開始時の system-reminder に `<file> was modified` と出ていたら、setup.sh を走らせる前に drift がないかソースを確認する（conflict prompt を 2 回処理する手間を省く）
