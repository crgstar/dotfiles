#!/usr/bin/env bash
# PreToolUse hook:
# メモリ (memory/ 配下の *.md と MEMORY.md 索引) への書き込みを、セッション内で
# 最初の 1 回だけ deny し、memory-guide スキルの起動をモデルに促す。
#
# Why deny (ask ではなく):
#   deny の理由文だけが「ユーザではなくモデル」に渡る (PreToolUse decision control)。
#   ask は人間の手を止めるが、deny ならダイアログ無しでモデルに差し戻せる。
#   prefer-jq-over-python.sh と同じ型。
#
# Why 「起動済みか」を判定せず 1 回だけ deny するか:
#   起動の検知手段がどれも取りこぼす。(1) transcript_path の会話ログは非同期に
#   書かれ現在ターンの直近メッセージを含まないことがある (公式明記) ので、
#   grep 方式は誤 deny → 再起動 → また誤 deny のループになる。(2) ユーザが
#   `/memory-guide` と手で打った場合はプロンプト展開で本文が載るだけで Skill
#   ツール呼び出しが発生しないため、Skill 呼び出しを見張る方式では印が付かず、
#   正しく読んでいるのに deny される。
#   「必ず一度立ち止まらせる」だけに割り切ると、誤 deny も無限ループも経路が消える。
#
# Why Bash も対象にするか:
#   auto mode ではファイル編集を Bash (heredoc / sed) で行うよう指示されるため、
#   Write / Edit だけを見張ると素通りする。Bash 側の判定は緩くてよい —
#   差し戻しはセッション 1 回きりなので、誤検知の代償が 1 往復で頭打ちになる。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す JSON を受け取り PreToolUse decision を出す
#   2) セルフテスト: `bash memory-guide-gate.sh --self-test`

set -euo pipefail

DENY_REASON='メモリ (memory/ 配下の *.md と MEMORY.md 索引) を書く前に、memory-guide スキルを起動してください。

  Skill ツールで skill: "memory-guide" を呼ぶ

書く / 残す / 消すの判定基準・置き先の決め方・書式の正本はスキル側にあります。起動して基準を
確認したうえで、同じ書き込みをやり直してください。この差し戻しはセッションにつき 1 回だけで、
2 回目以降は素通しします。'

emit_deny() {
  jq -n --arg r "$DENY_REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# 判定せず静的ルールに委ねる
passthrough() { printf '{}\n'; }

# ファイルパスがメモリ領域か(純粋関数)。
# why `.claude/projects/` まで要求する: 作業リポの src/memory/ 等を巻き込まないため。
is_memory_path() {
  case "$1" in
    */.claude/projects/*/memory/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Bash コマンドがメモリ領域を書き換えていそうか(純粋関数)。
# why ホワイトリストでなく粗い痕跡判定: 任意のシェルコマンドの書き込み先は
# 静的には決まらない。ここでの誤検知は「1 回余計に差し戻す」だけで済むので、
# 取りこぼしを減らす側に倒す。
bash_writes_memory() {
  local cmd="$1"
  case "$cmd" in *'.claude/projects/'*) ;; *) return 1 ;; esac
  case "$cmd" in *'/memory/'*|*'MEMORY.md'*) ;; *) return 1 ;; esac
  case "$cmd" in
    *'>'*|*'tee '*|*'cp '*|*'mv '*|*'rm '*|*'sed -i'*) return 0 ;;
  esac
  return 1
}

# ツール呼び出しがゲート対象か(純粋関数)。payload は Write/Edit ならファイルパス、
# Bash ならコマンド文字列。
should_gate() {
  local tool="$1" payload="$2"
  [ -n "$payload" ] || return 1
  case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit) is_memory_path "$payload" ;;
    Bash) bash_writes_memory "$payload" ;;
    *) return 1 ;;
  esac
}

# セッション印のパスを組み立てる(純粋関数)。
# why session_id を検証する: そのままパスに埋めるため。想定外の形なら空を返し、
# 呼び出し側が素通しに倒す (追跡できない以上、恒久 deny より素通しが安全)。
marker_path_for() {
  local sid="$1" tmp="${TMPDIR:-/tmp}"
  case "$sid" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s/claude-memory-guide-gate/%s' "${tmp%/}" "$sid"
}

run_self_test() {
  local fail=0
  assert_gate() {
    if should_gate "$2" "$3"; then printf 'ok  : %s\n' "$1"
    else printf 'FAIL: %s  -- expected gate, got passthrough\n' "$1"; fail=1; fi
  }
  assert_pass() {
    if should_gate "$2" "$3"; then printf 'FAIL: %s  -- expected passthrough, got gate\n' "$1"; fail=1
    else printf 'ok  : %s\n' "$1"; fi
  }

  local mem='/Users/u/.claude/projects/-Users-u-repo/memory'

  # 拾う
  assert_gate 'Write でメモリ本体' Write "$mem/feedback_x.md"
  assert_gate 'Write で索引' Write "$mem/MEMORY.md"
  assert_gate 'Edit でメモリ本体' Edit "$mem/user_y.md"
  assert_gate 'Bash heredoc' Bash "cat > $mem/feedback_x.md <<'EOF'"
  assert_gate 'Bash 追記' Bash "printf '%s' x >> $mem/MEMORY.md"
  assert_gate 'Bash 削除' Bash "rm $mem/stale.md"
  assert_gate 'Bash sed -i' Bash "sed -i '' 's/a/b/' $mem/MEMORY.md"
  assert_gate 'Bash mv (リネーム)' Bash "mv $mem/old.md $mem/new.md"

  # 拾わない
  assert_pass 'Read は対象外' Read "$mem/feedback_x.md"
  assert_pass 'メモリ外の Write' Write '/Users/u/repo/src/memory/index.ts'
  assert_pass 'projects 配下でないメモリ名' Write '/Users/u/repo/memory/note.md'
  assert_pass 'Bash でメモリを読むだけ' Bash "cat $mem/MEMORY.md"
  assert_pass 'Bash で grep するだけ' Bash "grep -n hook $mem/MEMORY.md"
  assert_pass 'メモリに触れない Bash' Bash 'git status --short'
  assert_pass '空の payload' Write ''

  # marker_path_for
  if marker_path_for 'a b' >/dev/null 2>&1; then
    printf 'FAIL: 不正な session_id  -- expected rejection\n'; fail=1
  else printf 'ok  : 不正な session_id を弾く\n'; fi
  if [ -n "$(marker_path_for 'abc123-def456-7890' 2>/dev/null)" ]; then
    printf 'ok  : 正常な session_id を受理\n'
  else printf 'FAIL: 正常な session_id  -- expected path\n'; fail=1; fi

  if [ "$fail" = 0 ]; then printf '\nall tests passed.\n'; return 0
  else printf '\nsome tests failed.\n'; return 1; fi
}

if [ "${1:-}" = '--self-test' ]; then
  run_self_test
  exit $?
fi

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# why Bash とファイル編集で参照先が違う: 前者は command、後者は file_path
payload="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)"

should_gate "$tool_name" "$payload" || { passthrough; exit 0; }

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
marker="$(marker_path_for "$session_id" 2>/dev/null || true)"
# 印を置けない (session_id 不明) なら素通し。恒久 deny になるより安全側。
[ -n "$marker" ] || { passthrough; exit 0; }

[ -e "$marker" ] && { passthrough; exit 0; }

# why 印を置けてから deny する: 置けないまま deny すると次回も印が無く、同じ
# 差し戻しをセッション中ずっと繰り返す (「2 回目以降は素通し」という理由文が嘘になり、
# メモリ書き込みの手段が塞がる)。書けない側の原因 (TMPDIR が消えた・別ユーザ所有・
# 容量不足) は hook からは直せないので、追跡できないときは素通しに倒す。
mkdir -p "$(dirname "$marker")" 2>/dev/null && : > "$marker" 2>/dev/null || { passthrough; exit 0; }
emit_deny
