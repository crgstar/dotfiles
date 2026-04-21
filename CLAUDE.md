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

## setup.sh のコンフリクト対応

`.claude/settings.merged.json` / `.claude/CLAUDE.merged.md` は、セッション中の `/update-config` や動的 allow 追加で既存 merged がソースより先行すると対話プロンプトで停止する。

- **順序のみの差分**: 即 `n` で上書き（ソース正）
- **実質的な追加あり**: 先にソースへ還流してから `n`
  - 共通 → `.claude/settings.json` / `.claude/CLAUDE.md`
  - 環境別 → `.claude/settings.local/<env>.json` / `.claude/CLAUDE.local/<env>.md`
- 取りこぼしは `.bak` から復元可能
