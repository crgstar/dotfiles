# dotfiles

Claude Code の設定ファイルとスキルを管理する dotfiles リポジトリ。

## セットアップ

```bash
./setup.sh [home|work]  # 環境名は必須引数（省略すると共通設定のみ）
```

- `jq` が必要（設定のマージに使用）
- 生成される `.claude/settings.merged.json` は gitignore 済み

## 設定の仕組み

- `.claude/settings.json` — 全環境共通の設定（ベース）
- `.claude/settings.local/<env>.json` — 環境別の追加設定
- setup.sh が jq で両者をマージし `~/.claude/settings.json` にシンボリックリンク
- IMPORTANT: 配列フィールド（permissions.allow 等）はマージ時に結合される（上書きではない）

## ファイル追加時の規約

- 設定ファイルは `link_file` 関数でシンボリックリンクする（コピーではない）
- 新しいリンク対象を追加した場合は `setup.sh` にも `link_file` の呼び出しを追加する
- スキルは `.claude/skills/<skill-name>/SKILL.md` に配置し、`~/.claude/skills/` へリンクする
