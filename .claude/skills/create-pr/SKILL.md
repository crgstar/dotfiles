---
name: create-pr
description: >
  PR 本文 (タイトル + body) を考えるときは常に発動する。「PR作って」「PR上げて」
  「PR出して」「create-pr」「プルリク作成して」「gh pr create して」「この差分でPR」
  「PR の文面考えて」等のリクエストや、コミット直後にユーザが「PR作成」と
  言ったときに必ず使うこと。PR 本文の下書きレビューや書き換え相談でも発動する。
  ただし、push だけ・差分の相談だけのときは対象外。
---

# Create PR Workflow

## Phase 1: ブランチと差分の確認

- PR を作るブランチ (head) は **現在のブランチがデフォルト**。ユーザから別ブランチの指示があれば変更する。default branch 上ならどのブランチで作るかをユーザに確認する。
- base ブランチはリポジトリの default branch を既定とする。最初に取得して **ユーザに「base は X で進めます」と報告** する (リポによって `main` / `master` / `develop` 等が違うため):
  ```bash
  BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
  ```
- 並列実行:
  ```bash
  git status
  git log --oneline "$BASE"..HEAD
  git diff "$BASE"...HEAD --stat
  git diff "$BASE"...HEAD
  ```
- 未コミット変更があれば、含めて commit するか stash するかをユーザに確認する。`git add -A` は使わない。

## Phase 2: 既存 PR から慣習を把握

直近マージ済み PR を見て、このリポジトリの書式の慣習を読み取る:

```bash
gh pr list --state merged --limit 5 --json title,body
```

PR が無いリポジトリでは `.github/pull_request_template.md` と CLAUDE.md を参照する。両方無ければ Phase 3 のデフォルトカタログで進める。

## Phase 3: 本文を section catalog から組み立てる

Phase 2 で抽出した規約 (言語・セクション構成) を優先する。規約に無い場合は次のカタログから必要なものだけ選ぶ:

| セクション | 必須 | いつ入れるか | 中身 |
|----------|----|------------|------|
| 変更内容 / Summary | ◯ | 常に | 何を変えたかを箇条書きで |
| 背景 / Context | △ | "なぜ" の追加情報があれば | 解決したい問題、トリガーになった事象 |
| 方針 / Approach | △ | 設計判断やトレードオフがある時 | 採った方針と、捨てた代替案、あえて入れなかった防御とその根拠 |
| 動作確認 / Test plan | ◯ | 常に | 検証可能なもののみ (Phase 4 参照) |

調査過程のショートハンドや内部用語はレビュアーが読める言葉に書き直す。

### 方針 / Approach の書き方

「方針」候補は思いつく限り網羅的に列挙してユーザに提示し、承認を得た案だけ本文に残す。

あえて入れなかった防御 (フォールバック・後方互換・ランタイムガード) が diff の外にある前提 (デプロイ単位、到達不能な経路、上流で検証済み) で正当化されるなら、その前提ごと本文に書く。書かれていない前提は、diff しか見えないレビュアーから類型的な防御コーディング指摘として返ってくる。

必要に応じて関連リンク (Issue, 参考文献, 関連 PR) を本文中に差し込むこと。

## Phase 4: Test plan の検証可能性チェック (最重要)

各項目は次の **全条件** を満たすこと:

1. 誰かが今、検証できる手段が存在する (コマンド or 観測済み事実)
2. この PR の変更だけで完結する (運用ローテや他 PR に依存しない)
3. 未来事象でない (「次回〜」「将来〜」は失格)

外したものは削除する。

**NG 例:**

```markdown
✗ - [ ] 次回のリリース PR 作成時に「作業開始の報告」セクションが自動表示されること
```
未来事象。今この PR で誰も検証できない。

**OK 例:**

```markdown
✓ - [x] make test が通る
✓ - [x] curl -X GET /api/foo がローカルで 200 を返す
✓ - [x] PR ページ上で .github/PULL_REQUEST_TEMPLATE.md の Markdown が崩れなく描画される
```

## Phase 5: ユーザ確認

drafted title + body を提示する:

```
### Title
<title>

### Body
<body>
```

明示的な承認 (「OK」「これで作って」等) があるまで `gh pr create` は実行しない。

## Phase 6: push して PR を作る

```bash
git push -u origin <branch>
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

URL をユーザに返す。

## 注意事項

- **署名は固定**: 本文末尾に必ず `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を 1 行空けて付ける
- `git add -A` / `git add .` は使わない。変更ファイルを明示指定する
- `--no-verify` で pre-commit hook をスキップしない
- 同ブランチに既存 PR があれば新規作成ではなく `gh pr edit` への切替をユーザに確認する
- 改行を含む body は HEREDOC 経由 (`-b "..."` 直渡しはシェルが壊す)
- `<<'EOF'` (quoted heredoc) 内ではバックティック・`$` を含め一切エスケープしない（シェル展開が発生しないため）
