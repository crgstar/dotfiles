#!/bin/bash
# SessionEnd hook: 終了したセッションの transcript を無人 reflect の処理待ち
# キューに 1 行追記する。重い処理・ネットワークはしない (hook は速く返す)。
# 処理本体は .claude/skills/reflect/run-headless.sh (launchd 起動) が担う。
#
# why REFLECT_STATE_DIR を env で上書き可能にするか: --self-test が一時
# ディレクトリで実キューを汚さずに検証するため。

set -u

enqueue() {
  local state_dir queue done_file min_lines
  local input session_id transcript cwd lines
  state_dir="${REFLECT_STATE_DIR:-$HOME/.local/state/reflect}"
  queue="$state_dir/queue.jsonl"
  done_file="$state_dir/done"
  # why 行数閾値: 軽微なセッション (質問 1 往復等) は reflect しても拾うものが
  # なく夜間バッチの token を浪費するだけなので、enqueue 自体を門前で落とす。
  # jsonl 行数は粗い代理指標で十分 (精密な span 計測は hook には重い)。
  min_lines="${REFLECT_MIN_LINES:-50}"

  input=$(cat)

  # 自己除外: run-headless.sh が起動したヘッドレス reflect セッション自身も
  # SessionEnd を発火する (reason: prompt_input_exit)。enqueue すると reflect が
  # reflect を呼ぶ自己ループになるので、ドライバが立てるフラグで落とす。
  [ -n "${REFLECT_HEADLESS:-}" ] && return 0

  session_id=$(jq -r '.session_id // empty' <<<"$input") || return 0
  transcript=$(jq -r '.transcript_path // empty' <<<"$input") || return 0
  cwd=$(jq -r '.cwd // empty' <<<"$input") || return 0
  [ -n "$session_id" ] || return 0
  [ -f "$transcript" ] || return 0

  lines=$(wc -l <"$transcript") || return 0
  [ "$lines" -ge "$min_lines" ] || return 0

  # 冪等: 同一セッションが既にキュー/処理済みにあれば足さない
  # (resume 後の再終了や hook の重複発火で二重処理しないため)
  [ -f "$queue" ] && grep -qF "\"$session_id\"" "$queue" && return 0
  [ -f "$done_file" ] && grep -qF "$session_id" "$done_file" && return 0

  mkdir -p "$state_dir"
  jq -cn --arg sid "$session_id" --arg path "$transcript" --arg cwd "$cwd" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{session_id: $sid, path: $path, cwd: $cwd, ended_at: $at}' >>"$queue"
  return 0
}

self_test() {
  local tmpdir transcript payload pass=0 fail=0
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp/}reflect-enqueue-test-XXXXXX")
  # why 即時展開: tmpdir は local なので EXIT 時には消えている
  trap "rm -rf \"$tmpdir\"" EXIT
  transcript="$tmpdir/session.jsonl"

  # 各ケースは本体をフレッシュな process として起動する (env 上書きを効かせるため)
  run_case() {
    local desc="$1" expect="$2" payload="$3" queue_count
    shift 3
    env REFLECT_STATE_DIR="$tmpdir/state" "$@" bash "$0" <<<"$payload"
    queue_count=$(grep -c '' "$tmpdir/state/queue.jsonl" 2>/dev/null || true)
    if [ "${queue_count:-0}" -eq "$expect" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL: $desc (queue=${queue_count:-0} expect=$expect)"
    fi
  }

  seq 100 >"$transcript"
  payload=$(jq -cn --arg p "$transcript" \
    '{session_id: "test-session-1", transcript_path: $p, cwd: "/tmp", reason: "other"}')

  run_case "通常の enqueue" 1 "$payload"
  run_case "同一 session-id は冪等" 1 "$payload"
  run_case "REFLECT_HEADLESS で自己除外" 1 \
    "$(jq -c '.session_id = "test-session-2"' <<<"$payload")" REFLECT_HEADLESS=1

  mkdir -p "$tmpdir/state"
  echo "test-session-3" >>"$tmpdir/state/done"
  run_case "done 済みは skip" 1 \
    "$(jq -c '.session_id = "test-session-3"' <<<"$payload")"

  seq 10 >"$transcript"
  run_case "行数閾値未満は skip" 1 \
    "$(jq -c '.session_id = "test-session-4"' <<<"$payload")"

  run_case "transcript 不在は skip" 1 \
    '{"session_id": "test-session-5", "transcript_path": "/nonexistent", "cwd": "/tmp"}'

  seq 100 >"$transcript"
  run_case "2 件目のセッションは enqueue される" 2 \
    "$(jq -c '.session_id = "test-session-6"' <<<"$payload")"

  echo "self-test: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
enqueue
exit 0
