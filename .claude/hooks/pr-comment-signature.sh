#!/usr/bin/env bash
# PreToolUse hook: gh api で PR / Issue のコメントを投稿・更新するとき、本文に
# Claude Code の署名が無ければ ask へ格上げする。
#
# 背景:
#   respond-to-pr-review / review-comment スキルは、返信本文の末尾に空行 +
#     🤖 Generated with [Claude Code](https://claude.com/claude-code)
#   を付けることを必須としている（前者は「スコープ外でスキップする指示があっても
#   署名確認は省略しない」と明記）。ところがスキルを経由せず gh api を直接叩くと
#   この規定を踏まずに投稿できてしまい、実際に二度落とした。
#   記憶・メモによる注意喚起では再発したため、機械的に止める。
#
# 判定できないケース（本文ファイルが見つからない等）は pass ではなく ask に倒す。
# 署名の有無を確認できないまま外部へ公開されるのを避けるため。
set -uo pipefail

# 署名の同一性は URL ではなくこの語で見る（表記揺れに強い側を採る）。
SIGNATURE_PATTERN='Generated with \[Claude Code\]'

# 本文を運ぶフィールド指定。`-f body=...` だけでなく、PENDING レビューを作る
# `-F 'comments[][body]=...'` のようなネストしたフィールド名も拾う必要がある
# （review-comment スキルの既定の投稿経路がこの形）。`bodyHTML` 等に巻き込まれて
# 過検知しても署名確認が 1 回増えるだけなので安全側。
BODY_ASSIGN_RE='(-F|-f|--field|--raw-field)[[:space:]]+[^[:space:]=]*body[^[:space:]=]*=[^[:space:]]*'
# `-F`/`--field` だけが値の `@` をファイル参照として展開する（`-f` は展開せず
# リテラル `@path` を送る）。ファイル参照の中身を読むのはこの形のときだけ。
BODY_FILE_RE='(-F|--field)[[:space:]]+[^[:space:]=]*body[^[:space:]=]*=@[^[:space:]]+'

emit_ask() {
  # permissionDecisionReason は任意フィールド。jq で理由文字列を安全にエスケープする。
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
}

emit_pass() {
  printf '%s\n' '{}'
}

missing_signature_reason() {
  printf '%s' "$1 本文に Claude Code の署名が見当たりません。respond-to-pr-review / review-comment スキルは末尾に空行 + '🤖 Generated with [Claude Code](https://claude.com/claude-code)' を必須としています。"
}

# コマンド先頭の `cd <dir>;` / `cd <dir> &&` を拾う。@file 参照は相対パスで
# 書かれることが多く、セッションの cwd だけでは解決できないため。
leading_cd_dir() {
  sed -nE 's/^[[:space:]]*cd[[:space:]]+([^;&|]+)[[:space:]]*(;|&&).*/\1/p' <<<"$1" \
    | head -1 \
    | sed -E 's/[[:space:]]+$//'
}

# body=@file の file を、cd を考慮して解決する。見つからなければ空を返す。
# 見つからない経路でも 0 を返す（set -e 下での早期終了を避け、呼び出し側で ask に倒す）。
resolve_body_file() {
  local ref="$1" base_dir="$2" cwd="$3" candidate
  # `-F 'comments[][body]=@notes.md'` のようにクォートごと切り出されることが
  # あるので、両端のクォートだけ剥がす。剥がせない形は解決に失敗して ask に倒れる。
  ref="${ref%[\"\']}"
  case "$ref" in
    /*)
      [[ -f "$ref" ]] && printf '%s' "$ref"
      return 0
      ;;
  esac
  for candidate in "${base_dir}/${ref}" "${cwd}/${ref}" "$ref"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 0
}

main() {
  local input cmd cwd base_dir
  input=$(cat)
  # jq が無い / 壊れている場合に本文を読めないまま pass すると、この hook が
  # 守ろうとしている「署名を確認できないまま公開する」を自分で起こす。
  # command キーが本当に無いケースと区別するため、jq の終了コードで分ける。
  if ! cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null); then
    emit_ask "入力 JSON を解釈できず、PR / Issue コメントかどうかを判定できません。"
    return
  fi
  cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || cwd=""

  # gh api でのコメント投稿・更新以外は対象外。
  [[ "$cmd" == *"gh api"* ]] || { emit_pass; return; }

  # GraphQL 経由の投稿 (PENDING レビューへ追記する addPullRequestReviewThread 等) は
  # REST のエンドポイント判定に掛からないので先に見る。書き込みは mutation でしか
  # 起こせないので、mutation かつ body を含むなら本文を送っているとみなす。
  if [[ "$cmd" == *"gh api graphql"* ]] \
     && grep -q 'mutation' <<<"$cmd" && grep -q 'body' <<<"$cmd"; then
    if ! grep -qE "$SIGNATURE_PATTERN" <<<"$cmd"; then
      emit_ask "$(missing_signature_reason "GraphQL 経由の PR / Issue コメント")"
      return
    fi
    emit_pass
    return
  fi

  # `/reviews` も対象: review-comment スキルの既定は PENDING レビューを
  # `pulls/{n}/reviews` + `comments[][body]` で作る形で、ここを落とすと
  # 一番よく使う投稿経路が丸ごと素通りする。レビュー本文 (`-f body=`) も同じ。
  grep -qE '/(comments|replies|reviews)' <<<"$cmd" || { emit_pass; return; }
  # body を渡していない呼び出し（GET 等）は対象外。
  grep -qE "$BODY_ASSIGN_RE" <<<"$cmd" || { emit_pass; return; }

  base_dir=$(leading_cd_dir "$cmd")
  [[ -n "$base_dir" ]] || base_dir="$cwd"

  # @file 参照は 1 件ずつ検査する。1 コマンドで複数の返信をまとめて投げる形が
  # あり、連結して見ると「どれか 1 つに署名があれば通る」抜けができるため。
  local ref resolved
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    resolved=$(resolve_body_file "$ref" "$base_dir" "$cwd")
    if [[ -z "$resolved" ]]; then
      emit_ask "本文ファイル ${ref} を解決できず署名を確認できません。署名の有無を確かめてから実行してください。"
      return
    fi
    if ! grep -qE "$SIGNATURE_PATTERN" "$resolved"; then
      emit_ask "$(missing_signature_reason "${ref} の")"
      return
    fi
  done < <(grep -oE "$BODY_FILE_RE" <<<"$cmd" | sed -E 's/.*=@//')

  # インライン指定（-f body=... / -F body=<変数展開>）はコマンド文字列自体を見る。
  # 変数経由（-F body="$BODY"）だと中身まで追えないので、その場合も文字列に
  # 署名が現れなければ ask になる（安全側）。インラインを複数並べた場合は
  # 1 つでも署名があれば通る点が @file 経路と非対称だが、その形は使われていない。
  #
  # `-f body=@x` を「ファイル参照」と誤って除外しないこと: -f は @ を展開せず
  # リテラル `@x` を本文として送るので、署名の無いコメントがそのまま投稿される。
  local assign
  while IFS= read -r assign; do
    [[ -n "$assign" ]] || continue
    # -F/--field の @file 形だけは上のループで中身を検査済み。
    [[ "$assign" =~ ^(-F|--field)[[:space:]]+[^[:space:]=]*=@ ]] && continue
    if ! grep -qE "$SIGNATURE_PATTERN" <<<"$cmd"; then
      emit_ask "$(missing_signature_reason "PR / Issue コメント")"
      return
    fi
    break
  done < <(grep -oE "$BODY_ASSIGN_RE" <<<"$cmd")

  emit_pass
}

# ---- self test --------------------------------------------------------------
# `bash pr-comment-signature.sh --self-test` で実行できる。
# 判定は stdin の JSON を読む main に対して行う（本番と同じ入口を通す）。
run_self_test() {
  local fail=0 tmpdir signed unsigned
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp/}pr-comment-sig-XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN
  signed="$tmpdir/signed.md"
  unsigned="$tmpdir/unsigned.md"
  printf 'ok\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$signed"
  printf 'ok\n' > "$unsigned"

  local SIG=$'\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'

  _decide() {
    jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}' \
      | main \
      | jq -r 'if .hookSpecificOutput then "ask" else "pass" end'
  }

  _assert() {
    local want="$1" name="$2" cmd="$3" got
    got="$(_decide "$cmd")"
    if [ "$got" = "$want" ]; then
      printf 'ok  : %s\n' "$name"
    else
      printf 'FAIL: %s (want %s, got %s)\n' "$name" "$want" "$got"
      fail=1
    fi
  }

  _assert pass '対象外: gh api ではない'            'echo hello'
  _assert pass '対象外: コメントの GET'              'gh api repos/o/r/pulls/1/comments --paginate'
  _assert pass '対象外: レビューの GET'              'gh api repos/o/r/pulls/1/reviews --paginate'

  _assert ask  'スレッド返信に署名なし'              'gh api repos/o/r/pulls/1/comments/9/replies -X POST -f body="fixed"'
  _assert pass 'スレッド返信に署名あり'              "gh api repos/o/r/pulls/1/comments/9/replies -X POST -f body=\"fixed${SIG}\""
  _assert ask  'issue コメントに署名なし'            'gh api repos/o/r/issues/1/comments -X POST -f body="hi"'

  # review-comment スキルの既定経路。ネストしたフィールド名を拾えないと素通りする。
  _assert ask  'PENDING レビュー (comments[][body]) に署名なし' \
    "gh api repos/o/r/pulls/1/reviews -f commit_id=abc -F 'comments[][path]=a.go' -F 'comments[][body]=nit'"
  _assert pass 'PENDING レビュー (comments[][body]) に署名あり' \
    "gh api repos/o/r/pulls/1/reviews -f commit_id=abc -F 'comments[][body]=nit${SIG}'"
  _assert ask  'レビュー本文 (-f body) に署名なし' \
    'gh api repos/o/r/pulls/1/reviews -f body="summary" -f event=COMMENT'

  # GraphQL は REST のエンドポイント判定に掛からないので別経路で見る。
  _assert ask  'GraphQL mutation に署名なし' \
    "gh api graphql -f query='mutation { addPullRequestReviewThread(input:{body:\"x\"}) { clientMutationId } }'"
  _assert pass 'GraphQL mutation に署名あり' \
    "gh api graphql -f query='mutation { addPullRequestReviewThread(input:{body:\"x${SIG}\"}) { clientMutationId } }'"
  _assert pass 'GraphQL の参照クエリ (body を読むだけ)' \
    "gh api graphql -f query='query { repository(owner:\"o\",name:\"r\") { pullRequest(number:1) { comments(first:1) { nodes { body } } } } }'"

  # -F/--field の @ はファイル参照。中身を読んで判定する。
  _assert pass '-F body=@署名ありファイル'  "gh api repos/o/r/issues/1/comments -F body=@${signed}"
  _assert ask  '-F body=@署名なしファイル'  "gh api repos/o/r/issues/1/comments -F body=@${unsigned}"
  _assert ask  '-F body=@解決できないパス'  'gh api repos/o/r/issues/1/comments -F body=@/nope/none.md'
  # -f は @ を展開しない。リテラル `@path` が本文になるので署名は無い。
  _assert ask  '-f body=@ はファイル参照ではない' "gh api repos/o/r/issues/1/comments -f body=@${signed}"

  if [ "$fail" = 0 ]; then
    printf '\nall tests passed.\n'
    return 0
  fi
  printf '\nsome tests failed.\n'
  return 1
}

if [ "${1:-}" = '--self-test' ]; then
  run_self_test
  exit $?
fi

main
