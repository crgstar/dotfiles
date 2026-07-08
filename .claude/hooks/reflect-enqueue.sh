#!/bin/bash
# SessionEnd hook: 終了したセッションの transcript を無人 reflect の処理待ち
# キューに 1 行追記する。重い処理・ネットワークはしない (hook は速く返す)。
# 処理本体は .claude/skills/reflect/run-headless.sh (launchd 起動) が担う。
#
# why REFLECT_STATE_DIR を env で上書き可能にするか: --self-test が一時
# ディレクトリで実キューを汚さずに検証するため。

set -u

# NOTE: run-headless.sh の done_lines_of と同一実装。変えるときは両方揃える
done_lines_of() { # $1=sid $2=done ファイル。出力: ""(未処理) / "inf"(恒久 done) / 記録済み最大行数
  [ -f "$2" ] || return 0
  awk -v s="$1" '
    $1 == s { if (NF < 2) inf = 1; else if ($2 + 0 > max) max = $2 + 0; found = 1 }
    END { if (inf) print "inf"; else if (found) print max + 0 }
  ' "$2"
}

enqueue() {
  local state_dir queue done_file min_lines
  local input session_id transcript cwd lines recorded min_growth
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

  lines=$(($(wc -l <"$transcript"))) || return 0
  [ "$lines" -ge "$min_lines" ] || return 0

  # 冪等: 同一セッションが既にキューにあれば足さない
  # (resume 後の再終了や hook の重複発火で二重処理しないため)
  [ -f "$queue" ] && grep -qF "\"$session_id\"" "$queue" && return 0

  # done は「<sid> <処理時の行数>」形式 (行数なしの旧形式は恒久 done)。
  # 処理済みでも transcript が閾値以上伸びていれば再 enqueue する
  # (処理後に resume された会話の続きを取りこぼさないため。差分の抽出範囲は
  # ドライバが --since-line で渡し、SKILL.md §6 が接頭辞の重複抽出を抑える)
  recorded=$(done_lines_of "$session_id" "$done_file")
  if [ -n "$recorded" ]; then
    [ "$recorded" = "inf" ] && return 0
    min_growth="${REFLECT_MIN_GROWTH:-$min_lines}"
    [ $((lines - recorded)) -ge "$min_growth" ] || return 0
  fi

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
  run_case "行数なしの done (旧形式) は恒久 skip" 1 \
    "$(jq -c '.session_id = "test-session-3"' <<<"$payload")"

  echo "test-session-3g 30" >>"$tmpdir/state/done"
  run_case "done 記録 30 行 → 100 行 (閾値以上の成長) は再 enqueue" 2 \
    "$(jq -c '.session_id = "test-session-3g"' <<<"$payload")"

  echo "test-session-3s 80" >>"$tmpdir/state/done"
  run_case "done 記録 80 行 → 100 行 (閾値未満の成長) は skip" 2 \
    "$(jq -c '.session_id = "test-session-3s"' <<<"$payload")"

  printf 'test-session-3m 30\ntest-session-3m\n' >>"$tmpdir/state/done"
  run_case "行数付きと旧形式が混在する sid は inf 優先で skip" 2 \
    "$(jq -c '.session_id = "test-session-3m"' <<<"$payload")"

  printf 'test-session-3x 20\ntest-session-3x 90\n' >>"$tmpdir/state/done"
  run_case "複数記録は最大行数と比較 (90→100 は閾値未満) で skip" 2 \
    "$(jq -c '.session_id = "test-session-3x"' <<<"$payload")"

  echo "test-session-3z 0" >>"$tmpdir/state/done"
  run_case "記録 0 行は未処理でなく 0 として扱い、100 行成長で再 enqueue" 3 \
    "$(jq -c '.session_id = "test-session-3z"' <<<"$payload")"

  seq 10 >"$transcript"
  run_case "行数閾値未満は skip" 3 \
    "$(jq -c '.session_id = "test-session-4"' <<<"$payload")"

  run_case "transcript 不在は skip" 3 \
    '{"session_id": "test-session-5", "transcript_path": "/nonexistent", "cwd": "/tmp"}'

  seq 100 >"$transcript"
  run_case "2 件目のセッションは enqueue される" 4 \
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
