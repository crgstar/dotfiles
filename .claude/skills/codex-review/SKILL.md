---
name: codex-review
description: >
  GitHub Copilot CLI (copilot コマンド) 経由で OpenAI のモデルにコードレビューを依頼するスキル。
  Claude Code 内から Copilot の別モデルによるセカンドオピニオンを得る。
  「codexでレビューして」「copilotにレビューさせて」「Codexにレビュー依頼」
  「copilot reviewして」「別モデルでレビュー」等のリクエストで使用。
  ユーザがコードレビュー文脈で copilot / codex / 別モデル に言及したら積極的にこのスキルを使う。
---

# Codex Review

GitHub Copilot CLI の非対話モード (`copilot -p`) を使い、OpenAI のモデルにコードレビューを実行させる。

## 前提条件

- `copilot` コマンドがインストール済みであること
- GitHub Copilot のライセンスがあり `copilot login` 済みであること

## ワークフロー

### Step 1: レビュー対象の確認

ユーザにレビュー対象を確認する。指定がなければ聞く。

対象の例:
- 未コミットの差分 (`git diff`)
- ブランチ間の差分 (`git diff <base>...<head>`)
- 特定のファイル
- PR の差分

差分が大きすぎると時間がかかるため、`git diff --stat` で規模を確認し、数百行を超える場合はスコープを絞るか確認する。

### Step 2: Copilot CLI の実行

以下のコマンドパターンで実行する:

```bash
copilot -p "<プロンプト>" --allow-all-tools --model gpt-5.5 2>&1
```

重要なオプション:
- `-p "..."` — 非対話モード（完了後に終了）
- `--allow-all-tools` — ツール実行を自動許可（非対話に必須）
- `--model gpt-5.5` — 最新モデルを使う
- `-s` は使わない（途中経過が見えなくなる）
- タイムアウトは 600000ms (10分) に設定する

プロンプトの構成:
```
<対象の差分を取得する指示（例: git diff を実行して）>。
コードレビューしてください。バグ、設計上の問題、改善点を日本語で指摘してください。
```

対象が明確な場合は具体的な git コマンドをプロンプトに含める:
- 未コミット差分: `git diff の未コミット差分をコードレビューしてください`
- ブランチ差分: `git diff <base>...<head> の差分をコードレビューしてください`

### Step 3: 結果の表示と対応

1. Copilot CLI の出力をそのままユーザに表示する
2. 指摘事項を要約した表を作成する（箇所 / 内容 / 重要度）。重要度は `.claude/skills/shared/review-severity.md` の定義に従う
3. ユーザに「対応しますか？」と確認する
4. ユーザが対応を希望した場合、指摘に基づいてコードを修正する

## 注意事項

- Copilot CLI はファイルの読み書きができるが、`--allow-all-tools` を付けても Claude Code 側のファイルには影響しない（別プロセスで動作する）
- Codex モデルは thinking model のため、応答に数分かかることがある。ユーザに所要時間の目安を伝える
- copilot が利用不可能な場合はエラーメッセージを表示し、インストール手順を案内する
