#!/usr/bin/env bash
# PreToolUse hook: Claude が実行しようとした rm を deny し、trash で出し直させる。
#
# Why deny して出し直させる (コマンドを書き換えない):
#   `&&` やクォート混じりのコマンドを hook 側で書き換えると壊れやすく、
#   Claude が実際に何を実行したのかが transcript から読めなくなる。
#   deny の理由文はモデルにだけ渡るので、人間の手を止めずに出し直させられる。
#
# Why trash: macOS 15 以降の /usr/bin/trash はゴミ箱へ移すだけなので、誤削除を
#   ユーザが戻せる。ゴミ箱はユーザが手動で空にする運用。
#
# 対象: 単独の rm と、&& ; | 等で繋いだ後段の rm、xargs rm、find -exec/-execdir/-ok/-okdir rm。
#   `command rm` / `sudo rm` / `/bin/rm` / `\rm` / `VAR=x rm` / `( rm ...)` / `do rm` / `then rm` も拾う。
# 対象外:
#   - 自セッションの scratchpad 配下だけを消す単独の rm (scratchpad-rm-allow.sh が
#     確認なしで通している一時ファイル。ゴミ箱に溜める意味がない)
#   - find -delete (trash で言い換えられない。escalate-unsafe-bash.sh が ask にする)
#   - heredoc の本文行 (実行されない文字列)
# 限界: `bash -c '...'` の中・スクリプトファイルの中・eval・`$(...)` の rm は文字列から拾えない。
#   取りこぼしは settings.local/common.json の ask (`Bash(rm *)`) が人間の確認で受ける。
set -euo pipefail

# tokenize_quoted / split_with_separator / rm_confined_to_scratchpad を使う
source "$(dirname "${BASH_SOURCE[0]}")/lib/bash-safety.sh"

# why find は -print0 | xargs -0 で案内する: `find -exec trash` は escalate-unsafe-bash.sh が
# find -exec を一律 ask に格上げするので、言われたとおり直しても確認ダイアログに落ちる。
DENY_REASON='rm は使わず、ゴミ箱へ移す trash で出し直してください (ゴミ箱はユーザが後で空にします)。
- `rm -rf a b` → `trash a b` (trash はディレクトリも丸ごと移します。-r / -f は付けないこと。trash が受け付けるフラグは -v と -s だけ)
- `xargs rm` → `xargs trash` / `find ... -exec rm {} \;` → `find ... -print0 | xargs -0 trash`
自セッションの scratchpad 配下だけを消す単独の rm は対象外です。'

emit_deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

emit_pass() {
  printf '%s\n' '{}'
}

# 純粋判定: トークン 1 個がコマンド名として rm を指すか。
# パス付き (/bin/rm) も basename で見る。rmdir 等は別コマンドなので一致させない。
_is_rm_word() {
  [ "${1##*/}" = 'rm' ]
}

# 純粋判定: 1 セグメント (区切りで分けた 1 コマンド) が rm を実行するなら 0。
_segment_runs_rm() {
  local seg="$1" t i n
  local -a toks=()
  while IFS= read -r t; do toks+=("$t"); done < <(tokenize_quoted "$seg")
  n=${#toks[@]}
  [ "$n" -gt 0 ] || return 1

  # コマンド名の前に来る前置きを読み飛ばす。
  # why 前置きを剥がす: `sudo rm` / `command rm` / `FOO=1 rm` / `( rm x )` / `{ rm x; }` は
  # 先頭トークンが rm でなくても rm を実行する。
  # why 制御構文の予約語も剥がす: `for f in *; do rm $f; done` / `if ...; then rm x; fi` は
  # `;` で割ると `do rm $f` / `then rm x` になり、先頭が rm でなくなる。
  # why 前置きコマンドごとに値を取るフラグを持つ: `sudo -u root rm` の root や
  # `nice -n 5 rm` の 5 をコマンド名と誤読すると rm を見落とす。一律に「-x の次は値」とすると
  # 値を取らない `sudo -n rm` で rm を値として読み飛ばしてしまうので、コマンド別に分ける。
  local prefix='' needs_positional=0
  i=0
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    t="${t#"${t%%[!(]*}"}"   # サブシェルの `(` が語に付く形 (`(rm`) を剥がす
    toks[$i]="$t"
    case "$t" in
      ''|'{'|'!'|if|then|do|else|elif|while|until|nohup|time|exec|command) i=$((i+1)) ;;
      sudo|env|nice) prefix="$t"; i=$((i+1)) ;;
      timeout) prefix="$t"; needs_positional=1; i=$((i+1)) ;;
      -*)
        case "$prefix:$t" in
          sudo:-u|sudo:-g|sudo:-C|sudo:-D|sudo:-p|sudo:-r|sudo:-t|sudo:-U|sudo:-T|sudo:-R \
          |nice:-n|env:-u|env:-C|env:-S|env:-P|timeout:-s|timeout:-k)
            i=$((i+2)) ;;
          *) i=$((i+1)) ;;  # 前置きコマンドの値を取らないフラグ (sudo -n 等)
        esac
        ;;
      [A-Za-z_]*=*) i=$((i+1)) ;;
      *)
        # timeout は DURATION を 1 つ取ってからコマンドが来る
        if [ "$needs_positional" = 1 ]; then needs_positional=0; i=$((i+1)); continue; fi
        break
        ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  t="${toks[$i]}"

  if _is_rm_word "$t"; then
    return 0
  fi

  if [ "${t##*/}" = 'xargs' ]; then
    # xargs のオプションを読み飛ばして実行ユーティリティを探す。
    # why 値を取るフラグを区別する: `xargs -I {} rm {}` の `{}` をユーティリティと
    # 誤読すると rm を見落とし、逆に `xargs grep rm` の rm を拾うと誤検知になる。
    i=$((i+1))
    while [ "$i" -lt "$n" ]; do
      t="${toks[$i]}"
      case "$t" in
        -I|-J|-L|-n|-P|-s|-E|-R|-S|-d|-a) i=$((i+2)) ;;  # 値が次のトークンに来るフラグ
        -*) i=$((i+1)) ;;
        sudo|command|env) i=$((i+1)) ;;
        *) _is_rm_word "$t"; return ;;
      esac
    done
    return 1
  fi

  if [ "${t##*/}" = 'find' ]; then
    i=$((i+1))
    while [ "$i" -lt "$((n-1))" ]; do
      case "${toks[$i]}" in
        -exec|-execdir|-ok|-okdir)
          _is_rm_word "${toks[$((i+1))]}" && return 0 ;;
      esac
      i=$((i+1))
    done
    return 1
  fi

  return 1
}

# 純粋変換: heredoc の本文行を取り除いたコマンドを出力する。
# why: 本文は実行されないただの文字列だが、split_with_separator は `<<` を解釈しないので
# 改行で割られた本文の各行が実コマンドに見える。`cat > build.sh <<'EOF'` の本文に
# `rm -rf out` があるだけで deny され、モデルが書き込むスクリプトの中身を trash に
# 書き換えてしまう。cd-outside-workspace-gate.sh のように `<<` を含むコマンドを丸ごと
# 対象外にすると、heredoc の後ろに続く本物の rm まで見落とすので本文だけを落とす。
# 限界: クォート内の `<<WORD` も heredoc と読むので、その後 WORD 行までを見落としうる
# (取りこぼしは静的 ask が受ける)。
_strip_heredoc_bodies() {
  local cmd="$1" line scan body_line
  local re='<<(-?)[[:space:]]*['"'"'"\\]?([A-Za-z0-9_.-]+)'
  local -a delims=() dashes=()
  case "$cmd" in *'<<'*) ;; *) printf '%s' "$cmd"; return ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#delims[@]}" -gt 0 ]; then
      body_line="$line"
      [ "${dashes[0]}" = '-' ] && body_line="${body_line#"${body_line%%[!$'\t']*}"}"
      if [ "$body_line" = "${delims[0]}" ]; then
        delims=("${delims[@]:1}"); dashes=("${dashes[@]:1}")
      fi
      continue
    fi
    printf '%s\n' "$line"
    scan="${line//<<</}"   # here-string (`<<<`) は本文を持たない
    while [[ "$scan" =~ $re ]]; do
      dashes+=("${BASH_REMATCH[1]}"); delims+=("${BASH_REMATCH[2]}")
      scan="${scan#*"${BASH_REMATCH[0]}"}"
    done
  done <<< "$cmd"
}

# 純粋判定: コマンド全体を deny すべきなら 0。
# $2 は session_id、$3 (省略可) は uid (scratchpad 判定用。self-test で差し替える)。
should_deny_rm() {
  local cmd="$1" session_id="$2" rec seg flat

  # why 先に語として rm が現れるかだけを見る: この hook は全 Bash 呼び出しで起動し、
  # 後段の tokenize_quoted は 1 文字ずつ回す bash ループなので、heredoc で大きなファイルを
  # 書くコマンドでは 1 回に数秒かかる。クォートとバックスラッシュを剥がした文字列に
  # 語境界つきの rm が無ければ、後段のどの経路でも rm とは判定されない。
  flat="${cmd//[\\\'\"\`]/}"
  [[ "$flat" =~ (^|[^A-Za-z0-9_-])rm([^A-Za-z0-9_-]|$) ]] || return 1

  # scratchpad 配下だけを消す単独の rm は対象外。判定は scratchpad-rm-allow.sh と共有なので、
  # ここを通ったものは後段の PermissionRequest で確認なしに allow される。
  if [ -n "$session_id" ] && rm_confined_to_scratchpad "$cmd" "$session_id" ${3+"$3"}; then
    return 1
  fi

  cmd="$(_strip_heredoc_bodies "$cmd")"
  while IFS= read -r -d '' rec; do
    seg="${rec#*$'\t'}"
    _segment_runs_rm "$seg" && return 0
  done < <(split_with_separator "$cmd")
  return 1
}

main() {
  local input tool_name cmd session_id
  # 不正 JSON / フィールド欠落では判定せず素通し (静的ルールの ask が残るので安全側)
  input="$(cat)" || { emit_pass; return; }
  tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || { emit_pass; return; }
  [ "$tool_name" = 'Bash' ] || { emit_pass; return; }
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || { emit_pass; return; }
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)" || session_id=''
  if [ -n "$cmd" ] && should_deny_rm "$cmd" "$session_id"; then
    emit_deny "$DENY_REASON"
  else
    emit_pass
  fi
}

# ---- self test --------------------------------------------------------------
run_self_test() {
  local fail=0
  # 公開リポなので実 uid / 実 slug は書かない (合成値で足りる)
  local sid='5ccfbc56-9231-4c13-b4a2-434fdb0fd8e5' uid='4242'
  local pad="/private/tmp/claude-${uid}/-Users-example-project/${sid}/scratchpad"

  assert_deny() {
    if should_deny_rm "$2" "$sid" "$uid"; then
      printf 'ok  : %s\n' "$1"
    else
      printf 'FAIL: %s  -- expected deny, got pass\n' "$1"; fail=1
    fi
  }
  assert_pass() {
    if should_deny_rm "$2" "$sid" "$uid"; then
      printf 'FAIL: %s  -- expected pass, got deny\n' "$1"; fail=1
    else
      printf 'ok  : %s\n' "$1"
    fi
  }

  # 単独の rm と前置き
  assert_deny '単独 rm' 'rm foo.txt'
  assert_deny 'rm -rf' 'rm -rf build'
  assert_deny '絶対パスの rm' '/bin/rm -f x'
  assert_deny 'バックスラッシュで alias 回避' '\rm x'
  assert_deny 'command rm' 'command rm x'
  assert_deny 'sudo rm' 'sudo rm -rf /opt/x'
  assert_deny 'sudo -n rm' 'sudo -n rm x'
  assert_deny '環境変数の前置き' 'FOO=1 rm x'
  assert_deny 'サブシェル' '(rm x)'
  assert_deny 'ブレース群' '{ rm x; }'
  assert_deny 'クォート付きパス' "rm -f 'a b.txt'"

  # 複合コマンドの後段
  assert_deny '&& の後段' 'cd /tmp && rm -rf x'
  assert_deny '; の後段' 'ls; rm x'
  assert_deny '|| の後段' 'test -e x || rm y'
  assert_deny 'パイプの後段' 'echo y | rm -i x'
  assert_deny '改行の後段' $'ls\nrm x'

  # xargs / find
  assert_deny 'xargs rm' 'ls *.tmp | xargs rm'
  assert_deny 'xargs -0 rm -f' 'find . -print0 | xargs -0 rm -f'
  assert_deny 'xargs -n1 rm' 'ls | xargs -n1 rm'
  assert_deny 'xargs -I {} rm {}' 'ls | xargs -I {} rm {}'
  assert_deny 'xargs -I{} rm {}' 'ls | xargs -I{} rm {}'
  assert_deny 'xargs /bin/rm' 'ls | xargs /bin/rm'
  assert_deny 'find -exec rm' 'find . -name "*.o" -exec rm {} \;'
  assert_deny 'find -exec rm -f +' 'find . -exec rm -f {} +'
  assert_deny 'find -execdir rm' 'find . -execdir rm {} \;'
  assert_deny 'find -ok /bin/rm' 'find . -ok /bin/rm {} \;'

  # rm を実行しないもの
  assert_pass 'trash' 'trash a b'
  assert_pass 'git rm' 'git rm --cached x'
  assert_pass 'rmdir' 'rmdir empty'
  assert_pass 'rm が引数の文字列' 'git commit -m "rm foo"'
  assert_pass 'echo rm' 'echo rm x'
  assert_pass 'grep rm' 'grep -rn rm .'
  assert_pass 'xargs grep rm (rm はパターン)' 'ls | xargs grep rm'
  assert_pass 'xargs -I rm (値が rm)' 'ls | xargs -I rm echo rm'
  assert_pass 'find -exec grep rm' 'find . -exec grep rm {} \;'
  assert_pass 'find -name rm' 'find . -name rm'
  assert_pass 'find -delete (escalate 側の担当)' 'find . -delete'
  assert_pass 'rm で始まる別コマンド名' 'rmate x'
  assert_pass '--rm フラグ' 'docker run --rm img'

  # 制御構文・値を取る前置きフラグ
  assert_deny 'for ... do rm' 'for f in a b; do rm $f; done'
  assert_deny 'if ... then rm' 'if [ -e x ]; then rm x; fi'
  assert_deny 'else rm' 'if true; then :; else rm x; fi'
  assert_deny 'while ... do rm' 'while read f; do rm "$f"; done < list'
  assert_deny 'sudo -u root rm' 'sudo -u root rm x'
  assert_deny 'nice -n 5 rm' 'nice -n 5 rm x'
  assert_deny 'timeout 5 rm' 'timeout 5 rm x'
  assert_deny 'timeout -s KILL 5 rm' 'timeout -s KILL 5 rm x'
  assert_deny 'env -u VAR rm' 'env -u FOO rm x'
  assert_deny 'クォートで分割した rm' "r''m x"
  assert_pass 'sudo -u rm (値が rm)' 'sudo -u rm ls'
  assert_pass 'timeout の後が rm 以外' 'timeout 5 ls rm'

  # heredoc の本文は実行されない
  assert_pass 'heredoc 本文の rm' "cat > build.sh <<'EOF'
rm -rf out
EOF"
  assert_pass '<<- 本文の rm' "$(printf 'cat <<-EOF\n\trm x\n\tEOF')"
  assert_pass 'heredoc 2 つ' "cat <<A > a; cat <<\"B\" > b
rm a
A
rm b
B"
  assert_deny 'heredoc の後ろの rm' "cat > f <<'EOF'
rm -rf out
EOF
rm f"
  assert_deny 'here-string は本文を持たない' "cat <<< x
rm y"

  # 差し戻し理由文で案内する言い換えが、この hook 自身に止められないこと
  assert_pass '案内: xargs trash' 'ls *.tmp | xargs trash'
  assert_pass '案内: find -print0 | xargs -0 trash' 'find . -name "*.o" -print0 | xargs -0 trash'

  # scratchpad 例外
  assert_pass 'scratchpad 配下の単独 rm' "rm -rf ${pad}/work"
  assert_pass 'scratchpad 配下の複数オペランド' "rm -f ${pad}/a ${pad}/b"
  assert_deny 'scratchpad と外の混在' "rm -rf ${pad}/a /tmp/b"
  assert_deny 'scratchpad rm でも複合コマンド' "rm -rf ${pad}/a && ls"
  assert_deny 'scratchpad ルート自体' "rm -rf ${pad}"
  assert_deny '別セッションの scratchpad' "rm -rf /private/tmp/claude-${uid}/-Users-example-project/00000000-0000-0000-0000-000000000000/scratchpad/x"
  if should_deny_rm "rm -rf ${pad}/work" '' "$uid"; then
    printf 'ok  : %s\n' 'session_id 不明なら scratchpad 例外を適用しない'
  else
    printf 'FAIL: %s\n' 'session_id 不明なら scratchpad 例外を適用しない'; fail=1
  fi

  # main の入出力 (JSON 形式と tool_name の確認)
  local out
  out="$(jq -cn --arg c 'rm x' '{tool_name:"Bash",session_id:"s",tool_input:{command:$c}}' | main)"
  if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = 'deny' ]; then
    printf 'ok  : %s\n' 'main: deny JSON を返す'
  else
    printf 'FAIL: %s  -- got %s\n' 'main: deny JSON を返す' "$out"; fail=1
  fi
  out="$(jq -cn '{tool_name:"Write",tool_input:{command:"rm x"}}' | main)"
  if [ "$out" = '{}' ]; then
    printf 'ok  : %s\n' 'main: Bash 以外は素通し'
  else
    printf 'FAIL: %s  -- got %s\n' 'main: Bash 以外は素通し' "$out"; fail=1
  fi

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
