---
name: process-retro
description: >
  retro が立てた dotfiles スキル改善 issue を crgstar/dotfiles から順に処理し、
  SKILL.md への反映と PR 作成まで行うスキル。`/process-retro` で明示起動、Routine 起動も同じ手順。
  対象は dotfiles 管理スキルのみ。送信元 (retro) と対をなす受け手側。
---

# process-retro — retro が立てた issue を受けて SKILL.md を直すスキル

retro が立てた `crgstar/dotfiles` の open issue を 1 通ずつ順に処理し、採用した
指摘を**スキル単位ブランチ**に指摘 1 件ごとのコミットとして積み、最後にブランチ
ごとに PR を作成する。スキル単位に分けるのは、人間が修正を PR マージ 1 クリックで
取捨選択できるようにするため (異なるスキルの修正はファイルが別なので互いに独立)。

## この環境での固定値

- **対象リポ**: `crgstar/dotfiles`
- **対象スキル**: `~/dotfiles/.claude/skills/<name>/SKILL.md` で git 追跡されているもの
- **PR 化**: する (スキル単位ブランチごとに 1 PR。マージ後のブランチ削除はリポ設定
  `delete_branch_on_merge` に任せる)
- **言語**: すべて日本語 (コメント・サマリ含む)

> ⚠ `crgstar/dotfiles` は PUBLIC リポジトリ。§3.3 の `sanitize-auditor` は
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
5. **実行コンテキストの記録** (ブランチはここでは作らない):
   - `original_branch=$(git rev-parse --abbrev-ref HEAD)` (実行末尾のクリーンアップ用に保存)
   - `run_ts=$(date +%Y%m%d-%H%M%S)` (ブランチ名に使う)
   - `git fetch origin main 2>/dev/null || true` (編集 base の stale を避けるため必ず fetch する)
   - `base=origin/main` — fetch 失敗等で参照できなければ `base=$original_branch` にフォールバック
   - ブランチは採用指摘が出たとき §3.3 でスキル単位に遅延作成する
     (`process-retro-<run_ts>-<target_skill>`、起点は `$base`)。採用ゼロのスキルの
     空ブランチを作らないため
   - `commit_count=0` と作成ブランチ一覧 (空) を初期化
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

issue 本文は retro SKILL.md §2.2 の出力スキーマ（`### 指摘 N` ブロックの連なり + 末尾の `指摘件数: <N>`）に従って書かれている。スキーマの詳細は retro 側を正とする。

各指摘から以下を抽出して指摘ごとの記録 (record) に固定する。実行中はこの記録だけを参照する:

- `target_skill`: 対象スキル名 (このあと `.claude/skills/<target_skill>/SKILL.md` を編集)
- `category`: §3.2 判定の参考
- `description`: 現象 (skill-md-guide / sanitize の入力にもなる、原文のまま保持)
- `suggested_direction`: 改善方針 (同上)

**読み取り失敗の条件** (どれか 1 つでも該当したら issue 全体を読み取り失敗 = `parse-error` 扱い):

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
| R1 | 指摘の懸念がすでに直っている: 編集 base の SKILL.md、または open な process-retro PR の修正で対処済み (理由に PR 番号) |
| R2 | 対象範囲外: `target_skill` が dotfiles 管理スキルでない、または存在しない |
| R3 | 仕様の取り違え: 指摘が SKILL.md の意図と矛盾する方向の修正を求めている |
| R4 | 根拠不足: 現象が抽象的すぎて再現できない / 改善方針が空 |
| R5 | 別 issue で既に同じ指摘が扱われている (今回読んだ open issue 一覧内での重複) |
| R6 | 方針違反: 機密漏洩を促す / 既存のサニタイズ規約を無効化する / dotfiles の編集方針に反する |
| R7 | 一回性: 指摘がその場の文脈・好みに留まり、「初見の Claude の行動を変える最小の編集」を 1 文で言えない |

どれにも該当しなければ採用 (`accept`)。採用はデフォルトではない — 全件採用に流れると
スキルが指摘のたびに肥大するため、R7 のバーを越えられない指摘は迷わず却下する。

R1 で読む「SKILL.md」は編集 base のもの (この実行で当該スキルのブランチを既に作っていれば
その先頭、なければ `$base`)。作業ツリー上の別ブランチの内容で判定しない。加えて
`gh pr list --repo crgstar/dotfiles --state open --json number,headRefName,files` で当該
SKILL.md を触る open PR があれば diff を読んで同根か判定する — base にはマージ待ちの修正が
見えないため、ここを見ないと同根指摘を二重採用して PR 同士が衝突する。

### §3.3 採用した指摘を順に反映

採用した指摘を 1 つずつ処理。同じ SKILL.md への複数指摘は順に編集し、各編集は
前のコミット反映後の作業ツリーに対して走るので、衝突しても次の指摘に持ち越せる。

指摘ごとの手順:

#### (0) スキル単位ブランチへ切替

この実行で `target_skill` のブランチが未作成なら
`git switch -c "process-retro-<run_ts>-<target_skill>" "$base"` で作成し一覧に記録、
作成済みなら `git switch` で移る (同一スキルへの 2 件目以降は同じブランチに積む)。
switch 失敗なら判定を `conflict` に降格して次の指摘へ (切替できないまま編集すると
別スキルのブランチに混入するため)。

#### (a) skill-md-guide に沿って編集

`Skill` ツールで `skill-md-guide` を invoke し、その手順に従って編集し、
`skill-md-reviewer` の収束レビューまで行う。
編集は指摘の根を消す最小差分にする。「指摘 1 件 = ルール 1 行追加」をデフォルトにせず、
既存行の書き換えで防げないか先に検討する。

#### (b) サニタイズ レビュー

`Agent` ツール (`subagent_type: sanitize-auditor`) で別コンテキストの subagent を起動し、
diff とこの SKILL.md の絶対パスを渡す。監査観点 (= 判定基準) は次の 4 つで、`sanitize-auditor`
はこの節を読んで適用する:

- 絶対パス (`/Users/.../...`) が残っていないか
- 作業リポ名・組織名・社内サービス名・他人の名前が混ざっていないか
- API キー・トークン・メール・IP・社内ホスト名・`.env` 値が混ざっていないか
- 作業リポ固有のコード識別子 (型名・関数名・ドメイン用語) が残っていないか

迷う語は、まず dotfiles リポの追跡済みファイルに同語が既出か Grep で確認する。既出なら
既公開情報なので漏洩に数えない (一般語まで漏洩判定すると conflict が誤発報する)。
確認してもなお迷うなら「漏洩あり」に倒す。

`sanitize-auditor` が「漏洩あり」を返したら main は **そのファイルを revert** して
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
(pre-commit hook 拒否等) なら `commit-failed` を記録して判定を `conflict` に降格し、
次の指摘へ。
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

ブランチ: <この issue の採用指摘が乗ったスキル単位ブランチの列挙> (PR は実行末尾に作成)
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

## §4. push・PR 作成とサマリ

全 issue の処理後に実行。

### ブランチごとの push と PR 作成

§3.3 で作成したスキル単位ブランチを順に処理する。コミットが 0 のブランチ
(全指摘が途中で `conflict` 降格した等) は push せず `git branch -D` で削除。
コミットがあるブランチは:

1. `git push -u origin "<branch>"` — non-zero → 1〜2 秒待って 1 回だけリトライ。
   2 回目も non-zero なら `push-failed (<stderr の末行>)` を記録して次のブランチへ。
   **force push / rebase / branch rename での自動復旧はしない** (上書きや履歴改変は
   運用事故を起こす)。失敗したブランチはローカルに残るので、人間が手動再送できる。
2. PR 作成。本文は issue 本文の採用指摘ブロック (§3.1 スキーマのサニタイズ済み
   テキスト) と元 issue へのリンク。下書きはリポ外の一時ファイルに置く (§3.4 と同じ理由):

   ```bash
   draft=$(mktemp "${TMPDIR:-/tmp/}process-retro-pr-XXXXXX.md")
   # 本文を $draft に書き出す
   gh pr create --repo crgstar/dotfiles --head "<branch>" \
     --title "fix(<target_skill>): <修正の 1 行サマリ>" --body-file "$draft"
   rm "$draft"
   ```

   non-zero → `pr-failed` を記録して次のブランチへ (push 済みなので人間が手動で PR 化できる)。

最後に `git switch "$original_branch"` で戻る (失敗は警告記録のみ、実行は止めない)。
マージされた PR のブランチ削除はリポ設定 `delete_branch_on_merge` に任せる。
close で見送られた PR のブランチはここでは触らない (人間の判断待ちの可能性があるため)。

### サマリ (stdout、日本語、必ず出す)

実行の最終ログ。Routine が残す唯一の痕跡なので「走ったが変更が無かった」と「そもそも走らなかった」を区別できる形で出す。フォーマットは [references/summary-template.md](references/summary-template.md) を参照。

Step 4 の TodoWrite 行を `completed` に flip するのとサマリ出力は同じツール呼び出しで行う (実行手順なので SKILL.md 側に置く)。

## §5. エラー処理 (実行全体)

- 単一指摘のエラー (`comment-failed` / `close-failed` / `commit-failed`) は記録して次へ、実行全体は止めない。実行全体を止めるのは事前チェック / issue 取得の 2 経路だけ (どちらも 0 件サマリで中断、自動リトライなし)。
- `sanitize-auditor` が「漏洩あり」を返した指摘は revert + conflict 降格。他の指摘の処理は続行する (1 件の漏洩検知で実行全体を止めると Routine の可用性が落ちる)。
- push / PR 作成の失敗はブランチ単位で記録して次のブランチへ。ブランチは残し、人間が手動で push・PR 化できる状態にする。

このスキルのエラーで他の作業をブロックしない — 報告して終える。
