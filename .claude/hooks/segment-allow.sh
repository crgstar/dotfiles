#!/usr/bin/env bash
# PermissionRequest hook helper:
# Bash の複合コマンドを &&/||/;/| で分割し、各セグメントが
# safe-prefix（echo / printf / gh api(書き込みフラグなし)）に
# 該当するときだけ allow を返す。1 つでも該当しないセグメントが
# あれば `{}` を返して静的ルールに委譲する。
#
# Why segments instead of prefix-only:
#   現行フックは「コマンド先頭が gh api か」しか見ていないため、
#   `echo "..." && gh api ...` のような連結が auto-allow から
#   外れていた。一方で先頭以外を素通しすると `rm -rf foo && gh api ...`
#   のような不正連結も通ってしまう。各セグメントを safe-prefix に
#   照合することで両立する。
#
# Scope: gh api の auto-allow を担うフックでのみ使用する想定。
# echo/printf 単独や jq 単独は静的 allow に委譲し、ここでは
# auto-allow しない（このフックは gh api を含む経路でのみ発火する）。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す JSON を受け取り、
#      適切な PermissionRequest decision を stdout に出す。
#   2) セルフテスト: `bash segment-allow.sh --self-test`

set -euo pipefail

# セグメントの前後空白を取り除く
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# クォート（' " `）を尊重しつつ &&, ||, ;, | で分割する。
# trim 済み・空文字を除いたセグメントを 1 行ずつ stdout に出す。
# クォート内の演算子は分割されない。
split_segments() {
  local cmd="$1"
  local i=0 len=${#cmd} ch next
  local in_single=0 in_double=0 in_backtick=0
  local seg=""
  # ダブルクォート内のバックスラッシュ連長: 偶数なら閉じクォートが活きる
  local bs_run=0

  _emit() {
    local t
    t="$(trim "$seg")"
    [ -n "$t" ] && printf '%s\n' "$t"
    seg=""
  }

  while [ "$i" -lt "$len" ]; do
    ch="${cmd:$i:1}"
    next=""
    if [ $((i+1)) -lt "$len" ]; then
      next="${cmd:$((i+1)):1}"
    fi

    if [ "$in_single" = 1 ]; then
      seg+="$ch"
      [ "$ch" = "'" ] && in_single=0
    elif [ "$in_double" = 1 ]; then
      seg+="$ch"
      if [ "$ch" = '\' ]; then
        bs_run=$((bs_run+1))
      elif [ "$ch" = '"' ]; then
        # 直前のバックスラッシュ列が偶数個ならクォート閉じ
        if [ $((bs_run % 2)) -eq 0 ]; then
          in_double=0
        fi
        bs_run=0
      else
        bs_run=0
      fi
    elif [ "$in_backtick" = 1 ]; then
      seg+="$ch"
      [ "$ch" = '`' ] && in_backtick=0
    else
      case "$ch" in
        "'") in_single=1; seg+="$ch" ;;
        '"') in_double=1; bs_run=0; seg+="$ch" ;;
        '`') in_backtick=1; seg+="$ch" ;;
        '&')
          if [ "$next" = '&' ]; then
            _emit
            i=$((i+1))
          else
            seg+="$ch"
          fi
          ;;
        '|')
          if [ "$next" = '|' ]; then
            _emit
            i=$((i+1))
          else
            _emit
          fi
          ;;
        ';')
          _emit
          ;;
        *) seg+="$ch" ;;
      esac
    fi
    i=$((i+1))
  done
  _emit
}

# 単一セグメント（trim 済み前提）が safe-prefix に該当するか判定する。
# 0: safe / 1: not safe
is_safe_segment() {
  local seg="$1"
  [ -z "$seg" ] && return 1

  case "$seg" in
    'echo'|'echo '*|'printf'|'printf '*)
      return 0
      ;;
    'gh api '*)
      # 書き込みフラグ:
      #   -f / -F     : フィールド送信（POST 等）
      #   --input     : ファイル/標準入力ボディ
      #   -X / --method: HTTP メソッド明示指定
      # 末尾アンカーに `=` を含めるのは `--method=POST` 形式も拾うため。
      if [[ "$seg" =~ (^|[[:space:]])(-(f|F)|--input|-X|--method)([[:space:]]|$|=) ]]; then
        return 1
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# コマンド全体を分解し、全セグメント safe かつ gh api を含むときだけ allow。
# gh api を含まないコマンドは静的ルールに委譲（このフックの役割外）。
evaluate_command() {
  local cmd="$1"
  local has_gh_api=0
  local seg

  while IFS= read -r seg; do
    if ! is_safe_segment "$seg"; then
      return 1
    fi
    case "$seg" in
      'gh api '*) has_gh_api=1 ;;
    esac
  done < <(split_segments "$cmd")

  [ "$has_gh_api" = 1 ]
}

emit_allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"compound read-only: echo/printf/gh api(no write flags)"}}}'
}

emit_passthrough() {
  printf '%s\n' '{}'
}

main() {
  local cmd
  cmd="$(jq -r '.tool_input.command')"
  if evaluate_command "$cmd"; then
    emit_allow
  else
    emit_passthrough
  fi
}

# ---- self test --------------------------------------------------------------
# テストは判定の純粋関数 evaluate_command に対して行う。
# `bash segment-allow.sh --self-test` で実行できる。
run_self_test() {
  local fail=0
  assert_safe() {
    local label="$1" cmd="$2"
    if evaluate_command "$cmd"; then
      printf 'ok  : %s\n' "$label"
    else
      printf 'FAIL: %s  -- expected allow, got passthrough\n' "$label"
      fail=1
    fi
  }
  assert_unsafe() {
    local label="$1" cmd="$2"
    if evaluate_command "$cmd"; then
      printf 'FAIL: %s  -- expected passthrough, got allow\n' "$label"
      fail=1
    else
      printf 'ok  : %s\n' "$label"
    fi
  }

  # safe ケース
  assert_safe 'gh api 単発' 'gh api repos/foo/bar/pulls/1/comments'
  assert_safe 'echo 見出し + gh api' 'echo "=== inline ===" && gh api repos/foo/bar/pulls/1/comments'
  assert_safe '複数 gh api 連結' 'echo a && gh api repos/foo/bar/pulls/1/comments && echo b && gh api repos/foo/bar/issues/1/comments'
  assert_safe '|| 分岐' 'gh api repos/foo/bar/pulls/1 || echo failed'
  assert_safe '; 区切り' 'echo start; gh api repos/foo/bar/pulls/1; echo end'
  assert_safe 'クォート内に && を含む' 'echo "a && b" && gh api repos/foo/bar/pulls/1'
  assert_safe '--jq オプション付き' "gh api repos/foo/bar/pulls/1 --jq '.title'"
  assert_safe 'bare echo' 'echo && gh api repos/foo/bar/pulls/1'
  assert_safe 'バックスラッシュ偶数個 (\\\\)' 'echo "a\\\\" && gh api repos/foo/bar/pulls/1'

  # unsafe ケース
  assert_unsafe 'rm -rf を含む' 'rm -rf /tmp/foo && gh api repos/foo/bar/pulls/1'
  assert_unsafe 'git stash を含む' 'git stash && gh api repos/foo/bar/pulls/1'
  assert_unsafe 'gh api -X DELETE' 'gh api repos/foo/bar/pulls/1 -X DELETE'
  assert_unsafe 'gh api --method POST' 'gh api repos/foo/bar/pulls/1 --method POST'
  assert_unsafe 'gh api --method=POST (= 区切り)' 'gh api repos/foo/bar/pulls/1 --method=POST'
  assert_unsafe 'gh api -f field=val' 'gh api repos/foo/bar/pulls/1 -f title=hello'
  assert_unsafe 'gh api --input body.json' 'gh api repos/foo/bar/pulls/1 --input body.json'
  assert_unsafe 'gh api を含まない（役割外）' 'echo hello && ls -la'
  assert_unsafe 'unknown コマンド単発' 'curl http://example.com'
  assert_unsafe 'パイプで rm' 'gh api repos/foo/bar/pulls/1 | rm -rf /tmp/x'

  # split_segments 単体: クォート尊重と空セグメント抑制
  assert_split_count() {
    local label="$1" cmd="$2" expected="$3"
    local got
    got="$(split_segments "$cmd" | wc -l | tr -d ' ')"
    if [ "$got" = "$expected" ]; then
      printf 'ok  : %s\n' "$label"
    else
      printf 'FAIL: %s  -- expected %s segments, got %s\n' "$label" "$expected" "$got"
      fail=1
    fi
  }
  assert_split_count 'split: quoted &&' 'echo "a && b" && gh api foo' 2
  assert_split_count 'split: 連続 ; は空セグメント抑制' 'echo a;; gh api foo' 2
  assert_split_count 'split: trailing ; は空セグメント抑制' 'gh api foo;' 1

  if [ "$fail" = 0 ]; then
    printf '\nall tests passed.\n'
    return 0
  else
    printf '\nsome tests failed.\n'
    return 1
  fi
}

if [ "${1:-}" = '--self-test' ]; then
  run_self_test
  exit $?
fi

main
