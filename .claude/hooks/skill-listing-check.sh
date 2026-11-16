#!/usr/bin/env bash
# Stop hook: 会話記録に残るスキル一覧を読み、文字数の上限を超えて説明を削られた
# (名前だけになった) スキルがあれば、セッションにつき 1 度だけ画面に知らせる。
#
# Why Stop か:
#   一覧は最初のプロンプトの送信直後に会話記録へ書かれる。SessionStart では未記録なので、
#   最初の返答の後に読む。
#
# Why 会話記録を読むか (ヘッドレスで測らない):
#   上限はセッションのモデルのコンテキスト窓で変わり、ヘッドレスの警告の字数は実際の一覧と
#   数え方が違う。実際に送った一覧 (type: skill_listing) なら、モデル・ディレクトリ・
#   有効なスキルがそのセッションのものになる。
#
# Why systemMessage だけを返し、常に exit 0 か:
#   Stop で decision:block / additionalContext / exit 2 を返すと Claude が作業を続ける。
#   知らせはユーザ向けなので、Claude に届かず画面にだけ出る systemMessage に限る。
#   構文エラーでも bash は exit 2 で終わるので、登録 (.claude/settings.local/common.json) の
#   コマンドに `|| true` を付けている。
#
# 記録の形式は公式に文書化されていないので、一覧が見つからなければ黙らず
# 「確認できませんでした」と知らせる。会話記録は遅れて書かれることがあるため、
# 1 回目の不在は見送り、2 回目で知らせる。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す Stop の JSON を受け取る
#   2) セルフテスト: `bash skill-listing-check.sh --self-test`

set -uo pipefail

TAG='[skill-listing-check]'
SHOW_MAX=10
MISS_LIMIT=2
MISSING_MESSAGE="$TAG 会話記録にスキル一覧が見つからず、スキルの説明が削られていないか確認できませんでした。Claude Code の会話記録の形式が変わった可能性があります。"
UNPARSABLE_MESSAGE="$TAG 会話記録のスキル一覧を解釈できず、スキルの説明が削られていないか確認できませんでした。Claude Code の会話記録の形式が変わった可能性があります。"

passthrough() { printf '{}\n'; }

emit_message() { jq -cn --arg m "$1" '{systemMessage: $m}'; }

# ヘッドレス (claude -p / SDK) か(純粋関数)。$1: CLAUDE_CODE_ENTRYPOINT
# why: 無人実行 (reflect など) のセッションには知らせを読む人がいない
is_headless() {
  case "$1" in sdk*) return 0 ;; *) return 1 ;; esac
}

# 状態ファイルのパス(純粋関数)。session_id が想定外の形なら失敗する。
# why session_id を検証する: そのままパスに埋めるため
state_path_for() {
  local sid="$1" tmp="${TMPDIR:-/tmp}"
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s/claude-skill-listing-check/%s' "${tmp%/}" "$sid"
}

# 次の状態と、取る動作を決める(純粋関数)。
# $1: 今の状態 ("" / miss:N / done)  $2: 一覧が見つかったか (1 / 0)
# 出力: "<次の状態> <動作>"  動作は check / report-missing / none
next_step() {
  local state="$1" found="$2" misses
  if [ "$state" = done ]; then echo 'done none'; return; fi
  if [ "$found" = 1 ]; then echo 'done check'; return; fi
  misses="${state#miss:}"
  case "$misses" in ''|*[!0-9]*) misses=0 ;; esac
  misses=$((misses + 1))
  if [ "$misses" -ge "$MISS_LIMIT" ]; then echo 'done report-missing'
  else echo "miss:$misses none"; fi
}

# 会話記録 (JSONL) から、最後に送られた最初の一覧 (isInitial) の attachment を出す。stdin: 会話記録
# why fromjson? と select: 書きかけの最終行を読み飛ばし、本文に "skill_listing" と書いただけの行を除くため
latest_initial_listing() {
  { grep -F '"skill_listing"' || true; } |
    jq -cR 'fromjson?
      | select(.type? == "attachment"
               and .attachment.type? == "skill_listing"
               and .attachment.isInitial? == true)
      | .attachment' |
    tail -n 1
}

# 一覧の attachment から、説明を削られたスキル名を JSON 配列で出す(純粋関数)。
# stdin: attachment の JSON  $1: 意図して名前だけにしたスキル名の JSON 配列
# why 行全体を "- 名前" か "- 名前 (別名)" の形で照合する: 説明は複数行にわたり、続きの行が
#   "- " で始まることがある。行頭の語だけで照合すると、run のように動詞と同じ名前のスキルを拾う
truncated_names() {
  jq -c --argjson keep "$1" '
    .names as $names
    | [ .content | split("\n")[]
        | select(startswith("- "))
        | ltrimstr("- ")
        | capture("^(?<n>[^ ]+)(?: \\([^()]*\\))?$").n
        | select(. as $n | any($names[]; . == $n))
        | select(. as $n | any($keep[]; . == $n) | not) ]'
}

# settings で skillOverrides を "name-only" にしたスキル名を JSON 配列で出す。
# $@: settings ファイル (無い・読めないものは飛ばす)
# why 優先順位を再現しない: どこか 1 つで name-only なら、意図して削ったとみなして足りる
intentional_name_only() {
  local f part merged out='[]'
  for f in "$@"; do
    [ -r "$f" ] || continue
    part="$(jq -c '[.skillOverrides // {} | to_entries[] | select(.value == "name-only") | .key]' "$f" 2>/dev/null)" || continue
    # why 合成の失敗も飛ばす: 空のファイルは jq が何も出さずに成功し、part が空になる
    merged="$(jq -cn --argjson a "$out" --argjson b "$part" '$a + $b | unique' 2>/dev/null)" || continue
    out="$merged"
  done
  printf '%s\n' "$out"
}

# $1: 削られたスキル名の JSON 配列
format_truncated_message() {
  jq -rn --argjson n "$1" --arg tag "$TAG" --argjson max "$SHOW_MAX" '
    ($n | length) as $c
    | "\($tag) スキル一覧が文字数の上限を超え、\($c) 件のスキルが説明を削られて名前だけになっています: "
      + ($n[0:$max] | join(", "))
      + (if $c > $max then " ほか \($c - $max) 件" else "" end)
      + "。skillListingBudgetFraction を上げるか、description を短くしてください。"'
}

main() {
  local input sid state_file state transcript cwd listing found step next action keep names count
  input="$(cat)"
  if is_headless "${CLAUDE_CODE_ENTRYPOINT:-}"; then passthrough; return; fi

  sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)" || sid=''
  state_file="$(state_path_for "$sid")" || { passthrough; return; }
  state="$(cat "$state_file" 2>/dev/null)" || state=''
  if [ "$state" = done ]; then passthrough; return; fi

  transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)" || transcript=''
  cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)" || cwd=''
  listing=''
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    listing="$(latest_initial_listing < "$transcript")"
  fi
  found=0
  [ -n "$listing" ] && found=1

  step="$(next_step "$state" "$found")"
  next="${step% *}"
  action="${step#* }"

  # why 状態を先に書く: 書けないまま知らせると、返答のたびに同じ知らせが出続ける
  { mkdir -p "$(dirname "$state_file")" && printf '%s\n' "$next" > "$state_file"; } 2>/dev/null ||
    { passthrough; return; }

  case "$action" in
    check)
      keep="$(intentional_name_only \
        "/Library/Application Support/ClaudeCode/managed-settings.json" \
        /etc/claude-code/managed-settings.json \
        "$HOME/.claude/settings.json" \
        "$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json" \
        "${CLAUDE_PROJECT_DIR:-}/.claude/settings.json" "${CLAUDE_PROJECT_DIR:-}/.claude/settings.local.json")"
      if ! names="$(printf '%s' "$listing" | truncated_names "$keep" 2>/dev/null)" || [ -z "$names" ]; then
        emit_message "$UNPARSABLE_MESSAGE"
        return
      fi
      count="$(jq 'length' <<<"$names")"
      if [ "$count" -gt 0 ]; then emit_message "$(format_truncated_message "$names")"
      else passthrough; fi
      ;;
    report-missing) emit_message "$MISSING_MESSAGE" ;;
    *) passthrough ;;
  esac
}

run_self_test() {
  local fail=0 self="${BASH_SOURCE[0]}" tmp out code
  ok() { printf 'ok  : %s\n' "$1"; }
  ng() { printf 'FAIL: %s  -- %s\n' "$1" "$2"; fail=1; }
  assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "expected [$3], got [$2]"; fi; }
  assert_contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) ng "$1" "[$3] not in [$2]" ;; esac
  }

  listing_line() {
    jq -cn --arg c "$1" --argjson n "$2" --argjson i "$3" \
      '{type:"attachment", attachment:{type:"skill_listing", content:$c, names:$n, isInitial:$i}}'
  }
  local nl=$'\n' names='["alpha","beta","plug:gamma","delta","run"]' truncated full
  truncated="$(listing_line "- alpha: does a${nl}- beta${nl}- plug:gamma (plug:gamma-long)${nl}- delta: line one${nl}- run the tests first${nl}- run (x) and more${nl}more text${nl}- run: does r" "$names" true)"
  full="$(listing_line "- alpha: does a${nl}- beta: does b${nl}- plug:gamma (plug:gamma-long): does g${nl}- delta: does d${nl}- run: does r" "$names" true)"

  assert_eq '説明のない行と別名付きの行を拾い、説明の続きの行は拾わない' \
    "$(jq -c '.attachment' <<<"$truncated" | truncated_names '[]')" '["beta","plug:gamma"]'
  assert_eq '意図して名前だけにしたスキルは除く' \
    "$(jq -c '.attachment' <<<"$truncated" | truncated_names '["beta"]')" '["plug:gamma"]'
  assert_eq '全部に説明があれば空' \
    "$(jq -c '.attachment' <<<"$full" | truncated_names '[]')" '[]'

  local mention delta cut
  mention='{"type":"user","message":{"content":"grep \"skill_listing\" で探す"}}'
  delta="$(listing_line '- zeta' '["zeta"]' false)"
  cut='{"type":"attachment","attachment":{"type":"skill_listing","isIn'
  assert_eq '最後の最初の一覧を選び、差分の一覧・本文の言及・書きかけの行は無視する' \
    "$(printf '%s\n' "$truncated" "$mention" "$delta" "$full" "$cut" | latest_initial_listing | truncated_names '[]')" '[]'
  assert_eq '最初の一覧が 1 つなら、それを選ぶ' \
    "$(printf '%s\n' "$truncated" "$delta" "$cut" | latest_initial_listing | truncated_names '[]')" '["beta","plug:gamma"]'
  assert_eq '一覧が無ければ空' "$(printf '%s\n' "$mention" "$cut" | latest_initial_listing)" ''

  assert_eq '初回に一覧あり → 判定して終える' "$(next_step '' 1)" 'done check'
  assert_eq '初回に一覧なし → 見送る' "$(next_step '' 0)" 'miss:1 none'
  assert_eq '2 回目も一覧なし → 確認できないと知らせて終える' "$(next_step 'miss:1' 0)" 'done report-missing'
  assert_eq '2 回目に一覧あり → 判定して終える' "$(next_step 'miss:1' 1)" 'done check'
  assert_eq '判定済み → 何もしない' "$(next_step 'done' 1)" 'done none'
  assert_eq '壊れた状態は初回扱い' "$(next_step 'garbage' 0)" 'miss:1 none'

  local msg
  msg="$(format_truncated_message '["s1","s2","s3","s4","s5","s6","s7","s8","s9","s10","s11","s12"]')"
  assert_contains '件数を出す' "$msg" '12 件のスキル'
  assert_contains '上限を超えた分は件数でまとめる' "$msg" 's10 ほか 2 件'

  if is_headless 'sdk-cli' && ! is_headless 'cli' && ! is_headless ''; then ok 'sdk* だけをヘッドレスとみなす'
  else ng 'is_headless' 'sdk-cli / cli / 空 の判定が違う'; fi
  if state_path_for '../x' >/dev/null; then ng '不正な session_id' 'パスを返した'; else ok '不正な session_id を弾く'; fi

  tmp="${TMPDIR:-/tmp}"
  tmp="$(mktemp -d "${tmp%/}/skill-listing-check-test-XXXXXX")" || { ng 'mktemp' '一時ディレクトリを作れない'; return 1; }
  mkdir -p "$tmp/home/.claude" "$tmp/state" "$tmp/proj/.claude" "$tmp/proj-empty/.claude"
  printf '%s\n' "$truncated" > "$tmp/truncated.jsonl"
  printf '%s\n' "$cut" > "$tmp/cut.jsonl"
  printf '{"skillOverrides":{"beta":"name-only","plug:gamma":"name-only"}}\n' > "$tmp/proj/.claude/settings.json"
  : > "$tmp/proj-empty/.claude/settings.local.json"

  # $1: stdin  残り: 上書きする環境変数
  run_hook() {
    local in="$1"; shift
    out="$(printf '%s' "$in" | env TMPDIR="$tmp/state" HOME="$tmp/home" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PROJECT_DIR= "$@" bash "$self" 2>/dev/null)"
    code=$?
  }
  stop_input() { jq -cn --arg s "$1" --arg t "$2" --arg c "${3:-$tmp}" '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"Stop"}'; }
  assert_run() {  # $2: 期待する出力 ('{}' か、systemMessage に含まれる文字列)
    if [ "$code" != 0 ]; then ng "$1" "exit $code"; return; fi
    if ! jq -e . >/dev/null 2>&1 <<<"$out"; then ng "$1" "JSON でない: [$out]"; return; fi
    if [ "$2" = '{}' ]; then assert_eq "$1" "$out" '{}'
    else assert_contains "$1" "$(jq -r '.systemMessage // empty' <<<"$out")" "$2"; fi
  }

  run_hook ''; assert_run '空の stdin' '{}'
  run_hook "$(stop_input s1 "$tmp/none.jsonl")"; assert_run '会話記録なし 1 回目は見送る' '{}'
  run_hook "$(stop_input s1 "$tmp/none.jsonl")"; assert_run '会話記録なし 2 回目は確認できないと知らせる' '確認できませんでした'
  run_hook "$(stop_input s1 "$tmp/none.jsonl")"; assert_run '知らせた後は黙る' '{}'
  run_hook "$(stop_input s2 "$tmp/truncated.jsonl")"; assert_run '削られたスキルを知らせる' 'beta, plug:gamma'
  run_hook "$(stop_input s2 "$tmp/truncated.jsonl")"; assert_run '同じセッションでは 1 度だけ' '{}'
  run_hook "$(stop_input s3 "$tmp/cut.jsonl")"; assert_run '書きかけの行だけなら見送る' '{}'
  run_hook "$(stop_input s4 "$tmp/truncated.jsonl")" CLAUDE_CODE_ENTRYPOINT=sdk-cli
  assert_run 'ヘッドレスでは黙る' '{}'
  if [ -e "$tmp/state/claude-skill-listing-check/s4" ]; then ng 'ヘッドレスは状態を残さない' '状態ファイルがある'
  else ok 'ヘッドレスは状態を残さない'; fi
  : > "$tmp/not-a-dir"
  run_hook "$(stop_input s5 "$tmp/truncated.jsonl")" TMPDIR="$tmp/not-a-dir"
  assert_run '状態を書けなければ知らせずに黙る' '{}'
  run_hook "$(stop_input s6 "$tmp/truncated.jsonl" "$tmp/proj")"; assert_run 'name-only の指定で削ったものは知らせない' '{}'
  run_hook "$(stop_input s7 "$tmp/truncated.jsonl" "$tmp/proj-empty")"; assert_run '空の settings があっても判定できる' 'beta, plug:gamma'
  run_hook "$(stop_input '../x' "$tmp/truncated.jsonl")"; assert_run '不正な session_id では黙る' '{}'
  printf '%s\n' '{"type":"attachment","attachment":{"type":"skill_listing","content":"- beta","isInitial":true}}' > "$tmp/no-names.jsonl"
  run_hook "$(stop_input s8 "$tmp/no-names.jsonl")"; assert_run '一覧はあるが解釈できなければ、そう知らせる' '解釈できず'

  rm -rf "$tmp"

  if [ "$fail" = 0 ]; then printf '\nall tests passed.\n'; return 0
  else printf '\nsome tests failed.\n'; return 1; fi
}

if [ "${1:-}" = '--self-test' ]; then
  run_self_test
  exit $?
fi

main
exit 0
