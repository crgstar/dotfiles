#!/usr/bin/env bash
# PermissionRequest hook helper:
# Bash の複合コマンドを &&/||/;/| で分割し、各セグメントが
# safe-prefix に該当するときだけ allow を返す。1 つでも該当しない
# セグメントがあれば `{}` を返して静的ルールに委譲する。
#
# Why segments instead of prefix-only:
#   現行フックは「コマンド先頭が gh api か」しか見ていないため、
#   `echo "..." && gh api ...` のような連結が auto-allow から
#   外れていた。一方で先頭以外を素通しすると `rm -rf foo && gh api ...`
#   のような不正連結も通ってしまう。各セグメントを safe-prefix に
#   照合することで両立する。
#
# Why the safe-prefix list is generated, not hardcoded:
#   静的 allow の `Bash(<cmd> *)` を変えるたびに hook の許容範囲も
#   同期させたいが、手で 2 箇所メンテすると必ずズレる。setup.sh が
#   settings.json から `Bash(<word>)` / `Bash(<word> *)` の単純パターン
#   だけを抽出して `segment-allow.prefixes` に書き出すことで、
#   静的 allow ⊇ hook 許容範囲 を build-time に保証する。
#   `git -C * status *` のような複合パターンは抽出から除外している。
#
# Scope: gh api の auto-allow を担うフックでのみ使用する想定。
# どんなに safe-prefix を満たしていても `gh api` を 1 つも含まない
# コマンドは passthrough し、静的ルールの ask 判定に委ねる。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す JSON を受け取り、
#      適切な PermissionRequest decision を stdout に出す。
#   2) セルフテスト: `bash segment-allow.sh --self-test`

set -euo pipefail

# build-time に setup.sh が生成する safe-prefix リスト。1 行 1 パターンで、
# 各行は bash の glob として `[[ "$seg" == $pattern ]]` で照合される。
# ファイルが無い場合は echo / printf / jq の最小セットへフォールバックし、
# setup.sh 未実行の状態でも壊れないようにする。
SAFE_PREFIX_FILE="${SAFE_PREFIX_FILE:-$HOME/.claude/hooks/segment-allow.prefixes}"

# 安全プレフィクスを配列に読み込む。コメント行 (# で始まる) と空行は無視。
load_safe_prefixes() {
  SAFE_PREFIXES=()
  if [ -r "$SAFE_PREFIX_FILE" ]; then
    local line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in '#'*) continue ;; esac
      SAFE_PREFIXES+=("$line")
    done < "$SAFE_PREFIX_FILE"
  else
    SAFE_PREFIXES=('echo' 'echo *' 'printf' 'printf *' 'jq *')
  fi
}

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

  # gh api だけは「書き込みフラグの有無」を見るため特別扱い。
  # 静的 allow には Bash(gh api *) が無い前提で、hook が auto-allow の責務を負う。
  #   -f / -F     : フィールド送信（POST 等）
  #   --input     : ファイル/標準入力ボディ
  #   -X / --method: HTTP メソッド明示指定
  # 末尾アンカーに `=` を含めるのは `--method=POST` 形式も拾うため。
  case "$seg" in
    'gh api '*)
      if [[ "$seg" =~ (^|[[:space:]])(-(f|F)|--input|-X|--method)([[:space:]]|$|=) ]]; then
        return 1
      fi
      return 0
      ;;
  esac

  # それ以外は generated prefix list に対する glob match で判定。
  # `[[ ]]` 内は word-splitting されないので $pattern を unquoted にして OK。
  local pattern
  for pattern in "${SAFE_PREFIXES[@]}"; do
    if [[ "$seg" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

# コマンド全体を分解し、全セグメント safe かつ gh api を含むときだけ allow。
# gh api を含まないコマンドは静的ルールに委譲（このフックの役割外）。
evaluate_command() {
  local cmd="$1"
  local has_gh_api=0
  local seg

  # SAFE_PREFIXES が未設定ならファイルから読む。self-test が事前に
  # 配列を仕込んでいる場合はそれを尊重する。
  if [ -z "${SAFE_PREFIXES+x}" ]; then
    load_safe_prefixes
  fi

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
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"compound read-only: gh api (no write flags) + segments in safe-prefix list"}}}'
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
  # self-test は本物の prefix ファイルに依存させない。setup.sh が生成する
  # 想定リストの代表例を直接配列に入れてテストする。
  SAFE_PREFIXES=(
    'echo'
    'echo *'
    'printf'
    'printf *'
    'jq *'
    'head *'
    'tail *'
    'grep *'
    'wc *'
    'ls *'
    'cat *'
    'env'
    # 多語サブコマンド (Bash(git status *) 等の派生)
    'git status *'
    'git log *'
    'gh pr view *'
    # `:*` セマンティクス → "cmd" と "cmd *" の両方を派生させる
    'mkdir'
    'mkdir *'
    'bun test'
    'bun test *'
  )

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
  assert_safe 'gh api | jq' "gh api repos/foo/bar/pulls/1/comments | jq '.[] | .id'"
  assert_safe 'gh api | jq -r' "gh api repos/foo/bar/pulls/1 | jq -r '.title'"
  assert_safe 'gh api | head' 'gh api repos/foo/bar/pulls/1 | head -5'
  assert_safe 'gh api | jq | head' "gh api repos/foo/bar/pulls/1 | jq '.[]' | head -5"
  assert_safe 'gh api | wc -l' 'gh api repos/foo/bar/pulls/1 | wc -l'
  assert_safe 'env (引数なし) を含む' 'env && gh api repos/foo/bar/pulls/1'
  assert_safe 'gh api && git status' 'gh api repos/foo/bar/pulls/1 && git status -s'
  assert_safe 'gh api && gh pr view' 'gh api repos/foo/bar/pulls/1 && gh pr view 42'
  assert_safe 'mkdir (引数なし :* 由来)' 'mkdir && gh api repos/foo/bar/pulls/1'
  assert_safe 'mkdir 引数あり (:* 由来)' 'mkdir -p /tmp/foo && gh api repos/foo/bar/pulls/1'
  assert_safe 'bun test (引数なし :* 由来)' 'bun test && gh api repos/foo/bar/pulls/1'
  assert_safe 'bun test 引数あり (:* 由来)' 'bun test --watch && gh api repos/foo/bar/pulls/1'

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
  assert_unsafe 'jq 単独（gh api を含まない）' "echo '{}' | jq '.x'"
  assert_unsafe 'safe-prefix 外の sed' 'gh api repos/foo/bar/pulls/1 | sed s/a/b/'
  assert_unsafe 'safe-prefix 外の curl' 'gh api repos/foo/bar/pulls/1 && curl http://example.com'
  assert_unsafe 'env FOO=bar cmd は引数付きで safe ではない' 'env FOO=bar curl x && gh api repos/foo/bar/pulls/1'
  assert_unsafe 'git stash (subcommand mismatch)' 'gh api repos/foo/bar/pulls/1 && git stash'
  assert_unsafe 'gh pr create (write subcommand)' 'gh api repos/foo/bar/pulls/1 && gh pr create -t x'

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
