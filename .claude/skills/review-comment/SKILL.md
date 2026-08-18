---
name: review-comment
description: >
  レビュー依頼を受けて見つけた指摘を GitHub PR にインラインコメントとして投稿するときの
  スキル。「PRにコメントして」「インラインコメントしてみて」「レビューコメント書いて」
  「指摘をPRに残して」等、findings をチャット報告に留めず実際に GitHub 上へ書き込む場面で使う。
  指摘そのものを見つける作業 (sentinel・code-review 等) や PR 本文の作成 (create-pr)、
  受け取ったレビューへの返信・修正 (respond-to-pr-review) は対象外。
---

# Review Comment

## 投稿前にやること(この順で)

1. **重複確認**: `gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate` を `created_at` 順に並べ、同じ指摘が既出(対応済み/未対応問わず)なら投稿しない。他のレビュアーが既に広範にレビュー済みの PR では特に重複しやすい。
2. **一次情報での裏取り**: 「〜のはず」で終わらせず、再現コード・grep・API仕様等で実際に確認してから文面にする。裏取りしていない主張は後で崩れる。
3. **ドラフトを見せて確認を取る**: PRコメントは他人に見える公開行為なので、投稿先(ファイル:行、対象コミット)と本文を提示し、ユーザーの了承が出るまで `gh api` は叩かない。
4. **重要度タグ**: このスキル経由で投稿するコメントには必ず `[must]`/`[should]`/`[may]` を付ける(対象PRにその慣習が無くても付ける)。どのタグが適切か迷う場合はユーザーに確認する。
5. **署名**: 特に指示が無ければ `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を付ける(`create-pr` と同じ慣習)。
6. **投稿方式は PENDING が既定**: ユーザーが即時公開を明示していない限り、下記「PENDING(下書き)で投稿(既定)」の手順を使う。投稿前に対象PRで自分(gh認証ユーザー)のPENDINGレビューが既に開いていないか確認しておくと、後段の分岐がスムーズ。

## 投稿先コミットの取り違えに注意

`git log --oneline main..origin/main` 等でローカルブランチが origin より古くないか確認してから対象行番号を数える。古いローカルの行番号で `commit_id` に最新 SHA を指定すると、行がズレて別の場所にコメントが付くか API エラーになる。

`commit_id` は `gh pr view {number} --json headRefOid --jq .headRefOid` で取れる PR の現在の head SHA を使う(fork からの PR でも同様に head SHA でよい)。

## PENDING(下書き)で投稿(既定)

ユーザーが即時公開を明示していない限り、これが既定の投稿方式。GitHub は**1ユーザー・1PRにつき PENDING レビューを1つまで**しか許さないため、まず既存の有無を確認してから分岐する。

**なぜ既定がPENDINGか**: 一度 `pulls/.../comments`(通常投稿)で即時公開すると、後から「PENDINGにして」と言われた場合に「PENDINGへ同内容を追記→公開済みの元コメントを削除」という往復が発生する(下記「公開済みをPENDINGに変換」参照)。投稿前にPENDINGを選んでおけばこの手戻りが要らない。

**まだ PENDING レビューが無い場合**は `event` を省略して作る(`event` を渡すと即座に公開されてしまう):
```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  -f commit_id="<head SHA>" \
  -F 'comments[][path]=path/to/file.go' -F 'comments[][line]=123' \
  -F 'comments[][side]=RIGHT' -F 'comments[][body]=...'
```

**既に PENDING レビューがある場合**、それに追記するには GraphQL の `addPullRequestReviewThread` を使う(`line`/`side` を直接指定できる。似た名前の `addPullRequestReviewComment` は旧い diff `position` 指定が必要で使いにくいので避ける)。

1. 対象レビューの node id を取得する(PENDING は authorから見た自分のものしか出てこない):
   ```bash
   gh api graphql -f query='{ repository(owner:"O", name:"R") { pullRequest(number: N) {
     id
     reviews(first: 20) { nodes { id databaseId state author { login } } }
   } } }'
   ```
2. 見つけた `pullRequestReviewId` へ追記する:
   ```bash
   gh api graphql -f query='
   mutation($reviewId: ID!, $body: String!, $path: String!, $line: Int!, $prId: ID!) {
     addPullRequestReviewThread(input: {
       pullRequestId: $prId, pullRequestReviewId: $reviewId,
       body: $body, path: $path, line: $line, side: RIGHT
     }) { thread { comments(first: 1) { nodes { databaseId } } } }
   }' -f prId="<PR node id>" -f reviewId="<review node id>" \
      -f body="$(cat draft.txt)" -f path="path/to/file.go" -F line=123
   ```

## 即時公開したいとき(ユーザーが明示した場合のみ)

`gh api repos/{owner}/{repo}/pulls/{number}/comments` に `body`/`commit_id`/`path`/`line`/`side` を渡す。1回の呼び出しごとに GitHub が自動でその1件だけを含む単発レビューを作り、即座に `COMMENTED`(公開)状態になる。

## リカバリ: 公開済みのコメントを PENDING に変換したい場合

これは正規の投稿順ではなく、**誤って(または指示を確認する前に)即時公開してしまった後のリカバリ手順**。投稿前にPENDING希望と分かっているなら、上の「PENDING(下書き)で投稿(既定)」を最初から使うこと。

投稿後に「これ下書きにして」と言われた等の場合:
1. 上記の手順で PENDING レビューに同内容を追記する
2. 公開済みの元コメントを削除する: `gh api -X DELETE repos/{owner}/{repo}/pulls/comments/{id}`

削除を先にやると本文を失うので、必ず「追記してから削除」の順で行う。
