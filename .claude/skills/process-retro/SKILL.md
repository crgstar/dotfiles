---
name: process-retro
description: >
  retro が立てた dotfiles スキル改善 issue を crgstar/dotfiles から順に取り、
  各指摘を判定 → SKILL.md を Edit → skill-md-guide と sanitize 子エージェントで
  レビュー → 専用ブランチに指摘ごとのコミットを積む → push まで実行するスキル。
  PR 化はしない (push まで)。`/process-retro` で明示起動、Routine 起動も同じ手順。
  対象は dotfiles 管理スキルのみ。送信元 (retro) と対をなす受け手側。
---

# process-retro — retro が立てた issue を受けて SKILL.md を直すスキル

retro が立てた `crgstar/dotfiles` の open issue を 1 通ずつ順に処理し、採用した
指摘をスキルの SKILL.md に反映し、専用ブランチに指摘 1 件ごとのコミットを積み、
最後に push する。PR 化は人間 (または別スキル) に任せる。

## この環境での固定値

- **対象リポ**: `crgstar/dotfiles`
- **対象スキル**: `~/dotfiles/.claude/skills/<name>/SKILL.md` で git 追跡されているもの
- **PR 化**: しない (`git push` で専用ブランチを出すまで)
- **言語**: すべて日本語 (コメント・サマリ含む)

> ⚠ `crgstar/dotfiles` は PUBLIC リポジトリ。§3.3 の sanitize 子エージェントは
> 「漏洩を 1 度起こすと取り返しが付かない」前提で必須扱い。スキップする経路は無い。

## §1. 事前チェック (失敗時は 0 件サマリで中断)

すべて zero-exit を期待。1 つでも失敗したらサマリを出して中断する。

1. `gh auth status` — 未認証なら中断 (理由: `gh not authenticated`)
2. `git diff --quiet && git diff --cached --quiet` — どちらか non-zero なら中断
   (理由: 作業ツリーに未コミットの差分が残っている。進行中の作業を triage の
   コミットに巻き込まないため)
3. `git config --get user.email` と `user.name` — 空なら中断 (理由: git identity 未設定)
4. `git symbolic-ref -q HEAD` — non-zero (detached HEAD) なら中断
   (理由: 実行末尾で `original_branch` に戻れなくなる)
5. **専用ブランチ作成**:
   - `original_branch=$(git rev-parse --abbrev-ref HEAD)` (実行末尾のクリーンアップ用に保存)
   - `branch_name=process-retro-$(date +%Y%m%d-%H%M%S)`
   - `git fetch origin main 2>/dev/null || true` (ローカル main の stale を避けるため必ず fetch する)
   - `base=origin/main` — fetch 失敗等で参照できなければ `base=$original_branch` にフォールバック
   - `git switch -c "$branch_name" "$base"` — 失敗なら中断
   - `commit_count=0` を初期化 (実行末尾でこの値が 0 ならブランチを削除する)
6. **TodoWrite の Phase Rows** を 1 回で登録:
   - `Step 1: Pre-flight` (completed)
   - `Step 2: List open issues` (in_progress)
   - `Step 3: Process each issue serially` (pending)
   - `Step 4: Emit summary` (pending)

Step 1 を最初から `completed` で入れるのは、Step 4 のサマリで「事前チェックは
通った」と読めるようにするため。

## §2. issue 一覧の取得

```bash
gh issue list --repo crgstar/dotfiles --state open --limit 50 \
  --json number,title,body
```

- non-zero exit → 中断 (理由: `gh issue list failed`)
- 0 件 → `TodoWrite` 1 回で Step 2/3/4 を遷移させ、Step 4 へ直行 (サマリは
  「0 件 (open issue 無し)」)
- 1〜49 件 → 各 issue 用の行を Step 3 直下に追加 (`Issue #N: <title>`)
- 50 件 → 同上 + `overflow=true` を立てる (Step 4 サマリに「50 件上限到達」)

上限 50 件は意図的。Routine で大量に積まれた場合は次回の実行に持ち越す。

## §3. issue を 1 通ずつ処理 (直列)

**並列禁止**: 同じ SKILL.md への編集競合と `gh issue comment` の非冪等性のため、直列に処理する。

各 issue について §3.1〜§3.5 を順に実行。完了経路は 2 通り:

- **通常経路**: §3.1 読み取り成功 → §3.2 判定 → §3.3 反映 → §3.4 コメント →
  §3.5 close → 当該 issue 行を completed に
- **読み取り失敗経路**: §3.1 失敗 → §3.3 スキップ → §3.4 で読み取り失敗の理由を
  コメント → §3.5 では **close しない** (open のまま、人間レビュー待ち) → completed

読み取り失敗を黙って close すると指摘が失われるため、open のまま残すのが意図。

### §3.1 issue 本文を読み取る 

retro 側の出力スキーマ:

```text
# dotfiles スキル ふりかえり（自動生成）

### 指摘 1
**Target skill:** <skill-name>
**Category:** 曖昧 | 分岐漏れ | デフォルト不適切 | ルール衝突 | その他
**Description:** <1 段落>
**Suggested fix direction:** <1 段落>

### 指摘 2
...

指摘件数: <N>
```

抽出して指摘ごとの記録 (record) に固定する。実行中はこの記録だけを参照する:

- `target_skill`: 対象スキル名 (このあと `.claude/skills/<target_skill>/SKILL.md` を編集)
- `category`: §3.2 判定の参考
- `description`: 現象 (skill-md-guide / sanitize の入力にもなる、原文のまま保持)
- `suggested_direction`: 改善方針 (同上)

**読み取り失敗の条件** (どれか 1 つでも該当したら issue 全体を読み取り失敗扱い):

- `### 指摘` 見出しが 0 個
- `指摘件数: N` の数値と見出し数が不一致
- 対象スキル名が `.claude/skills/` 配下に存在しない (typo か退役済みスキル)
- 4 つのラベル (`**Target skill:** / **Category:** / **Description:** / **Suggested fix direction:**`)
  のどれかが指摘 1 件でも欠落

読み取り失敗の場合は §3.3 を丸ごとスキップし、§3.4 で「読み取れなかった理由」を
コメントし、§3.5 では close しない。

### §3.2 各指摘を判定 (まだ編集はしない)

指摘ごとに以下のチェックを順に当て、採用 (`accept`) か却下 (`reject`、理由付き) を
決める。判断と理由は記録に保持。**この段階で編集はしない** (判定と反映を分離する
ことで、却下後の rollback 地獄を避ける)。

| # | 却下条件 |
|---|---|
| R1 | 現在の SKILL.md を読んだ結果、指摘の懸念がすでに直っている |
| R2 | 対象範囲外: `target_skill` が dotfiles 管理スキルでない、または存在しない |
| R3 | 仕様の取り違え: 指摘が SKILL.md の意図と矛盾する方向の修正を求めている |
| R4 | 根拠不足: 現象が抽象的すぎて再現できない / 改善方針が空 |
| R5 | 別 issue で既に同じ指摘が扱われている (今回読んだ open issue 一覧内での重複) |
| R6 | 方針違反: 機密漏洩を促す / 既存のサニタイズ規約を無効化する / dotfiles の編集方針に反する |

どれにも該当しなければ採用 (`accept`)。

### §3.3 採用した指摘を順に反映

採用した指摘を 1 つずつ処理。同じ SKILL.md への複数指摘は順に編集し、各編集は
前のコミット反映後の作業ツリーに対して走るので、衝突しても次の指摘に持ち越せる。

指摘ごとの手順:

#### (a) skill-md-guide に沿って編集

`Skill` ツールで `skill-md-guide` を invoke し、手順通りに編集、レビューさせる

#### (b) サニタイズ レビュー

`Agent` ツール (`subagent_type: general-purpose`) で別コンテキストの subagent を起動し、diff を渡して以下をチェックさせる:

- 絶対パス (`/Users/.../...`) が残っていないか
- 作業リポ名・組織名・社内サービス名・他人の名前が混ざっていないか
- API キー・トークン・メール・IP・社内ホスト名・`.env` 値が混ざっていないか
- 作業リポ固有のコード識別子 (型名・関数名・ドメイン用語) が残っていないか

子エージェントが「漏洩あり」を返したら main は **そのファイルを revert** して
判定を `conflict` に降格し、レビューループを脱出する。漏洩を含んだコミットを
絶対に作らないため、自動修正は試みない (検知 → revert → 人間に投げる)。

**なぜ別コンテキストか**: 「自分が今書いた SKILL.md に秘密が混ざっている」は
同じコンテキストでは気付きにくいため。

#### (c) スコープ確認 + ステージング

`git diff --name-only` で変更ファイルを確認。`.claude/skills/<target_skill>/`
配下以外が触られていたら判定を `conflict` に降格して revert (スコープ逸脱)。

問題なければ `git add .claude/skills/<target_skill>/SKILL.md`。

#### (d) コミット

```bash
git commit -m "fix(<target_skill>): <現象 1 行サマリ>" \
           -m "issue: #<N>" \
           -m "$(cat <<'EOF'
<改善方針 1 段落>
EOF
)"
```

zero-exit なら `commit_count++` と `record.commit=<sha>` に記録する。non-zero
(pre-commit hook 拒否等) なら判定を `conflict` に降格し、次の指摘へ。
`--no-verify` は **使わない**。

### §3.4 issue にコメント

全指摘の処理が終わったら (issue 全体が読み取り失敗の場合は即) issue にコメントを
投稿する。本文の組み立て:

```text
## process-retro 結果

| # | 対象 | カテゴリ | 結果 | 詳細 |
|---|---|---|---|---|
| 1 | <target_skill> | <category> | accept | commit <sha> |
| 2 | <target_skill> | <category> | reject (R1) | <理由> |
| 3 | <target_skill> | <category> | conflict | <理由> |

ブランチ: <branch_name>
```

下書きをリポジトリ外の一時ファイルに置く (retro 側と同じ理由: PUBLIC リポに誤って
コミットするリスクを構造的に排除するため):

```bash
draft=$(mktemp "${TMPDIR:-/tmp/}process-retro-comment-XXXXXX.md")
# 本文を $draft に書き出す
gh issue comment <N> --repo crgstar/dotfiles --body-file "$draft"
rm "$draft"
```

non-zero exit → `comment-failed` を記録、次の issue へ (実行全体は止めない)。

### §3.5 close 判定

以下が **両方** 成立したときだけ close:

1. §3.1 読み取りが完走している (読み取り失敗ではない)
2. 全指摘の判定が `accept` または `reject` (`conflict` / `parse-error` が混じって
   いない)

満たさない → open のまま (人間レビュー待ち)。

close 実行時:

- 採用が 1 つでもあれば `gh issue close <N> --repo crgstar/dotfiles --reason completed`
- 全却下なら `--reason "not planned"`

non-zero exit → `close-failed` を記録、次の issue へ。

## §4. push とサマリ

全 issue の処理後に実行。

### 空ブランチの自動削除

`commit_count == 0` なら専用ブランチを残しても無駄なので削除:

```bash
git switch "$original_branch" || record warning "switch back failed"
git branch -D "$branch_name" || record warning "branch -D failed"
```

クリーンアップ自体が失敗しても実行は止めない (警告を記録するだけ)。

### push (コミットがあるときだけ)

`commit_count > 0` のとき:

```bash
git push -u origin "$branch_name"
```

non-zero → 1〜2 秒待って 1 回だけリトライ。2 回目も non-zero なら
`push-failed (<stderr の末行>)` を記録してリトライを止める。**force push /
rebase / branch rename での自動復旧はしない** (上書きや履歴改変は運用事故を
起こす)。失敗したブランチはローカルに残るので、人間が `git push` で手動再送
できる状態にする。

### サマリ (stdout、日本語、必ず出す)

実行の最終ログ。Routine が残す唯一の痕跡なので「走ったが変更が無かった」と「そもそも走らなかった」を区別できる形で出す。フォーマットは [references/summary-template.md](references/summary-template.md) を参照。

Step 4 の TodoWrite 行を `completed` に flip するのとサマリ出力は同じツール呼び出しで行う (実行手順なので SKILL.md 側に置く)。

## §5. エラー処理 (実行全体)

- 単一指摘のエラー (`comment-failed` / `close-failed` / `commit-failed`) は記録して次へ、実行全体は止めない。実行全体を止めるのは事前チェック / issue 取得の 2 経路だけ (どちらも 0 件サマリで中断、自動リトライなし)。
- sanitize 子エージェントが「漏洩あり」を返した指摘は revert + conflict 降格。他の指摘の処理は続行する (1 件の漏洩検知で実行全体を止めると Routine の可用性が落ちる)。
- push 失敗時はブランチをローカルに残し、人間が手動 push できる状態にする。

このスキルのエラーで他の作業をブロックしない — 報告して終える。
