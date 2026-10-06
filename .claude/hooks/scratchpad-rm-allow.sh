#!/usr/bin/env bash
# PermissionRequest hook: 自セッションの scratchpad 配下だけを消す rm を allow する。
#
# Why a hook (not permissions.allow):
#   `Bash(rm *)` は settings.local/common.json の permissions.ask に入っており、
#   Claude Code は配列スコープを union するため上位から ask を消せない。
#   静的 ask を allow に緩められるのは PermissionRequest hook だけ
#   (詳細は rules/hook-permission.md)。
#
# Why session_id で絞るか:
#   scratchpad の実パスは /private/tmp/claude-<uid>/<project-slug>/<session-id>/scratchpad。
#   session-id 成分を hook 入力の session_id に固定することで、並行して動く別セッションの
#   作業ファイルを巻き込まない。将来 scratchpad のパス規約が変わったら単に照合に失敗して
#   ask に落ちるだけなので、安全側に倒れる。
#
# Usage:
#   1) フック本体: stdin の PermissionRequest JSON を読み、allow か `{}` を stdout に出す。
#   2) セルフテスト: `bash scratchpad-rm-allow.sh --self-test`
set -euo pipefail

# rm_confined_to_scratchpad は rm-to-trash.sh と共有 (lib/bash-safety.sh)。
# why 共有: 「scratchpad 配下の rm だけ素通し」の範囲を両 hook で食い違わせないため。
# 片方だけ広げると、trash 強制側は通したのに allow 側は ask に落とす (またはその逆) になる。
source "$(dirname "${BASH_SOURCE[0]}")/lib/bash-safety.sh"

emit_allow() {
  jq -cn --arg m "$1" \
    '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",message:$m}}}'
}

emit_pass() {
  printf '%s\n' '{}'
}

main() {
  local input cmd session_id tool_name
  # 不正 JSON / フィールド欠落では判定せず素通し (set -e で落とさない)
  input="$(cat)" || { emit_pass; return; }
  # settings の `if` はコマンドをパースできないと fail open するので、
  # ツール種別も hook 側で確かめる (別ツールの tool_input.command を許可しない)
  tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || { emit_pass; return; }
  [ "$tool_name" = 'Bash' ] || { emit_pass; return; }
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || { emit_pass; return; }
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)" || { emit_pass; return; }
  if [ -n "$cmd" ] && [ -n "$session_id" ] && rm_confined_to_scratchpad "$cmd" "$session_id"; then
    emit_allow 'session scratchpad 配下限定の rm'
  else
    emit_pass
  fi
}

# ---- self test --------------------------------------------------------------
run_self_test() {
  local fail=0
  local sid='5ccfbc56-9231-4c13-b4a2-434fdb0fd8e5'
  # 実行環境の実 uid / 実 project-slug は書かない (公開リポなので合成値で足りる。
  # uid は第 3 引数で差し替えられ、slug は照合正規表現側が `[^/]+` なので値は何でもよい)
  local uid='4242'
  local pad="/private/tmp/claude-${uid}/-Users-example-project/${sid}/scratchpad"

  assert_allow() {
    local label="$1" cmd="$2"
    if rm_confined_to_scratchpad "$cmd" "$sid" "$uid"; then
      printf 'ok  : %s\n' "$label"
    else
      printf 'FAIL: %s  -- expected allow, got pass\n' "$label"
      fail=1
    fi
  }
  assert_pass() {
    local label="$1" cmd="$2"
    if rm_confined_to_scratchpad "$cmd" "$sid" "$uid"; then
      printf 'FAIL: %s  -- expected pass, got allow\n' "$label"
      fail=1
    else
      printf 'ok  : %s\n' "$label"
    fi
  }

  # allow ケース
  assert_allow '単一ファイル' "rm ${pad}/hooks.md"
  assert_allow '-f 付き' "rm -f ${pad}/hooks.md"
  assert_allow '-rf でサブディレクトリ' "rm -rf ${pad}/work"
  assert_allow 'フラグ分割指定' "rm -r -f ${pad}/work"
  assert_allow '複数オペランド' "rm -f ${pad}/a.json ${pad}/b.json"
  assert_allow 'glob' "rm -f ${pad}/*.md"
  assert_allow '深い階層' "rm -rf ${pad}/a/b/c"
  assert_allow '-- の後にパス' "rm -rf -- ${pad}/work"
  assert_allow '-v 付き' "rm -rfv ${pad}/work"

  # scratchpad の外 / 範囲外
  assert_pass 'scratchpad ルート自体' "rm -rf ${pad}"
  assert_pass 'ルート + スラッシュのみ' "rm -rf ${pad}/"
  assert_pass 'セッションディレクトリ' "rm -rf /private/tmp/claude-${uid}/-Users-example-project/${sid}"
  assert_pass '別セッションの scratchpad' "rm -rf /private/tmp/claude-${uid}/-Users-example-project/00000000-0000-0000-0000-000000000000/scratchpad/x"
  assert_pass '別 uid の scratchpad' "rm -rf /private/tmp/claude-999/-Users-example-project/${sid}/scratchpad/x"
  assert_pass '/tmp 直下' 'rm -rf /tmp/foo'
  assert_pass 'ホーム配下' 'rm -rf /Users/example/project/x'
  assert_pass '相対パス (cwd が確定できない)' 'rm -rf work'
  assert_pass 'オペランドなし' 'rm -rf'
  assert_pass 'オペランドが 1 つでも外にある' "rm -rf ${pad}/a /tmp/b"
  assert_pass '.. で外に出る' "rm -rf ${pad}/../../x"
  assert_pass '末尾 ..' "rm -rf ${pad}/a/.."
  assert_pass 'プロジェクト slug 位置に階層を挟む' "rm -rf /private/tmp/claude-${uid}/a/b/${sid}/scratchpad/x"
  assert_pass 'scratchpad が途中成分' "rm -rf /private/tmp/claude-${uid}/x/${sid}/scratchpad/../etc"
  # 展開後に .. になる glob (リテラルの .. を含まない)
  assert_pass '.? が .. に展開されうる' "rm -rf ${pad}/.?/.?/.?/victim"
  assert_pass '.* が .. に展開されうる' "rm -rf ${pad}/.*/victim"
  assert_pass 'ドット始まりの成分' "rm -f ${pad}/.hidden"

  # rm 以外 / 危険な形
  assert_pass 'rm 以外のコマンド' "ls ${pad}"
  assert_pass 'command rm 経由' "command rm -rf ${pad}/x"
  assert_pass '絶対パスの rm' "/bin/rm -rf ${pad}/x"
  assert_pass 'sudo 経由' "sudo rm -rf ${pad}/x"
  assert_pass '複合コマンド (&&)' "rm -rf ${pad}/x && rm -rf /tmp/y"
  assert_pass '複合コマンド (;)' "rm -rf ${pad}/x; reboot"
  assert_pass 'パイプ' "rm -rf ${pad}/x | tee /tmp/log"
  assert_pass 'バックグラウンド &' "rm -rf ${pad}/x & reboot"
  assert_pass 'コマンド置換 $()' "rm -rf ${pad}/\$(id)"
  assert_pass 'バッククォート置換' "rm -rf ${pad}/\`id\`"
  assert_pass '変数展開' 'rm -rf $HOME/x'
  assert_pass 'チルダ展開' 'rm -rf ~/x'
  assert_pass 'リダイレクト' "rm -rf ${pad}/x > /tmp/log"
  assert_pass '改行で 2 コマンド' "rm -rf ${pad}/x
reboot"
  assert_pass 'クォート付きパス (白名簿外)' "rm -rf '${pad}/x'"
  assert_pass '未知フラグ' "rm --no-preserve-root ${pad}/x"
  assert_pass 'フラグに見えるが未知の短縮' "rm -rz ${pad}/x"
  # session_id が空 / 不正 (メタ文字混入) なら判定せず素通し
  assert_bad_session() {
    local label="$1" bad_sid="$2"
    if rm_confined_to_scratchpad "rm -rf ${pad}/x" "$bad_sid" "$uid"; then
      printf 'FAIL: %s  -- expected pass, got allow\n' "$label"
      fail=1
    else
      printf 'ok  : %s\n' "$label"
    fi
  }
  assert_bad_session 'session_id が空' ''
  assert_bad_session 'session_id にメタ文字' '../../x'
  assert_bad_session 'session_id が正規表現ワイルドカード' '.*'

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
