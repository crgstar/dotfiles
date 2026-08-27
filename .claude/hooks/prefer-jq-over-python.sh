#!/usr/bin/env bash
# PreToolUse hook:
# `gh api ... | python3 ...` のように GitHub API の出力を python で整形している
# 呼び出しだけを deny し、jq で書き直させる。
#
# Why deny (ask ではなく):
#   python は静的 allow に無いので、放置しても ask には落ちる。だが ask は
#   人間の手を止める。deny ならダイアログを出さずモデルに差し戻せるので、
#   モデルが jq で書き直して再実行するだけで済む。PreToolUse は allow を
#   ask/deny へ厳しくする方向にしか効かないため、逆に「通す」ことはできない。
#
# Why 整形だけを対象にする:
#   python -c 一般を塞ぐと、jq で書けない処理まで詰まる。実ログを調べた範囲では
#   `gh api | python3` は全件が「JSON からフィールドを抜いて表示する」だけで、
#   jq で置き換えられた。逆にファイル操作や外部ライブラリを使うものは
#   整形ではないので触らない (下の is_beyond_formatting)。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す JSON を受け取り PreToolUse decision を出す
#   2) セルフテスト: `bash prefer-jq-over-python.sh --self-test`

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/bash-safety.sh"

DENY_REASON='gh api の出力整形には python ではなく jq を使ってください。python は許可リストに無いため、この形は毎回確認ダイアログになります。

  gh api repos/o/r/pulls/1 | jq -r '"'"'"\(.user.login) | \(.path)", .body'"'"'

フィールド抽出・件数表示・本文の切り詰め (.body[:300])・null の既定値 (// "-") はいずれも jq で書けます。
jq で書けない処理 (複数ステップの加工、外部ライブラリ、ファイル出力) が必要な場合は、スクリプトをファイルに書いて `python3 <file>` として実行してください。その形はこのフックの対象外です。'

emit_deny() {
  jq -n --arg r "$DENY_REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# 判定せず静的ルールに委ねる
passthrough() { printf '{}\n'; }

# 先頭トークンを取り出す(純粋関数)。クォートとエスケープは tokenize_quoted が剥がす。
#
# why `| head -1` を使わない: head は 1 行読んだ時点でパイプを閉じるので、
# トークン出力がパイプバッファ (64KB) を超える長いコマンドでは tokenize_quoted の
# printf が EPIPE で失敗する。`set -euo pipefail` 下ではそれがフック全体の
# 異常終了 (exit 141・stdout 空) になり、判定が黙って消える。パラメータ展開で
# 先頭行を切り出せばパイプ自体が要らない。
first_token() {
  local toks
  toks="$(tokenize_quoted "$1")"
  printf '%s' "${toks%%$'\n'*}"
}

# セグメントが `gh api ...` か(純粋関数)。
# why 2 トークン目まで見る: `gh pr view` や `ghq` を巻き込まないため。
is_gh_api_cmd() {
  local toks rest t1 t2
  toks="$(tokenize_quoted "$1")"
  t1="${toks%%$'\n'*}"
  # 2 行目以降。1 行しか無いときは ${toks#*\n} が toks そのものを返すので空に倒す。
  rest="${toks#*$'\n'}"
  [ "$rest" = "$toks" ] && rest=""
  t2="${rest%%$'\n'*}"
  [ "$t1" = 'gh' ] && [ "$t2" = 'api' ]
}

# セグメントが python 実行か(純粋関数)。
# why 素の python/python3 だけ: `/usr/bin/python3` や `uv run python` は
# 呼び出し形が違い、書き直しの助言もそのままでは当たらないので対象外に倒す。
is_python_cmd() {
  local t1
  t1="$(first_token "$1")"
  case "$t1" in
    python|python3|python3.*) return 0 ;;
    *) return 1 ;;
  esac
}

# python セグメントがインラインコード (-c / -m) を実行しているか(純粋関数)。
#
# why ファイル実行を対象から外す: deny 理由文は「jq で書けない処理はスクリプトを
# ファイルに書いて `python3 <file>` で実行してください、その形は対象外です」を
# 逃げ道として案内している。ここでファイル実行まで deny すると、案内どおりに
# 書き直したモデルが同じ deny に当たり、抜け道の無いループになる。
#
# why 最初の非オプションで打ち切る: python の CLI はオプションが先頭に並び、
# 最初の非オプションがスクリプトファイル (以降は argv)。全トークンを見ると
# `python3 fmt.py -c x` のスクリプト側引数を `-c` と読んで誤検知する。
is_inline_python() {
  local t idx=0
  while IFS= read -r t; do
    idx=$((idx+1))
    [ "$idx" = 1 ] && continue
    case "$t" in
      -c|-c?*|-m|-m?*) return 0 ;;
      -?*) continue ;;
      # `-` 単体 (stdin からスクリプトを読む) もここ。gh の出力がデータではなく
      # スクリプト本体になる形なので「整形」ではない。
      *) return 1 ;;
    esac
  done < <(tokenize_quoted "$1")
  return 1
}

# python セグメントが「整形」を超えた処理をしているか(純粋関数)。
# 0: 超えている(触らない) / 1: 整形の範囲
#
# why ホワイトリストではなくブラックリスト: python コードの意味までは判定
# できない。ここでの誤りは方向で性質が変わる — 見逃し(整形なのに触らない)は
# 確認ダイアログが出るだけだが、誤検知(整形でないのに deny)は正当な作業を
# 止める。後者を避けるため、少しでも整形以外の兆候があれば手を引く。
is_beyond_formatting() {
  local seg="$1"
  # ファイル・プロセス・ネットワークに触れる痕跡
  case "$seg" in
    *'open('*|*'os.'*|*'subprocess'*|*'requests'*|*'urllib'*|*'shutil'*|\
    *'pathlib'*|*'socket'*|*'eval('*|*'exec('*|*'from '*) return 0 ;;
  esac
  # import が json / sys 以外を含むなら整形ではない
  local mods m
  local -a mod_list=()
  mods="$(printf '%s' "$seg" | grep -oE 'import[[:space:]]+[A-Za-z0-9_.,[:space:]]*' || true)"
  if [ -n "$mods" ]; then
    # why 外部コマンドを挟まず bash の置換だけで正規化する: `tr -d '[:space:]'` は
    # 改行も落とすので複数の import 文が 1 語に連結する。さらに `printf '%s'` は
    # 末尾に改行を付けないため、`while read` が最終行を読めずループを 1 度も
    # 回さない (判定が黙って素通りし、整形以外まで deny してしまう)。
    # 区切りを , に寄せてから read -ra で配列にする。
    mods="${mods//import/}"
    mods="${mods//$'\n'/,}"
    mods="${mods//[[:space:]]/}"
    IFS=',' read -ra mod_list <<< "$mods"
    if [ "${#mod_list[@]}" -gt 0 ]; then
      for m in "${mod_list[@]}"; do
        [ -z "$m" ] && continue
        case "$m" in json|sys) ;; *) return 0 ;; esac
      done
    fi
  fi
  return 1
}

# コマンド全体を評価する(純粋関数)。0: deny すべき / 1: 素通し
evaluate_command() {
  local cmd="$1"
  # why 先に安い部分一致で足切りする: split_with_separator は bash のループで
  # 1 文字ずつ走査するため、長いコマンド (数万文字の GraphQL 本文や jq
  # プログラム) では秒単位かかる。このフックは `if` 無しで全 Bash 呼び出しに
  # 登録されているので、対象になり得ないコマンドにその走査を払わせない。
  # deny の見逃しは静的ルールの ask に落ちるだけなので、足切りは安全側。
  case "$cmd" in *python*) ;; *) return 1 ;; esac
  case "$cmd" in *gh*) ;; *) return 1 ;; esac
  # why heredoc を含むなら丸ごと対象外: 本文は実行されないただの文字列だが、
  # どの分解処理も `<<` を解釈しないので中身が実コマンドとして並んで見える。
  # `cat > f <<EOF ... gh api ... | python3 ... EOF` を誤って deny しないため、
  # 判定できない形は手を引く。
  case "$cmd" in *'<<'*) return 1 ;; esac

  local rec sep seg head_cmd=""
  while IFS= read -r -d '' rec; do
    sep="${rec%%$'\t'*}"
    seg="${rec#*$'\t'}"
    # パイプで繋がっていない要素は新しいパイプラインの先頭になる
    if [ "$sep" != 'pipe' ]; then
      head_cmd="$seg"
      continue
    fi
    # why 直前ではなくパイプラインの先頭を見る: `gh api ... | head | python3`
    # のように間に別コマンドが挟まっても、出力の出どころは先頭のまま。
    if is_gh_api_cmd "$head_cmd" && is_python_cmd "$seg" && is_inline_python "$seg" \
       && ! is_beyond_formatting "$seg"; then
      return 0
    fi
  done < <(split_with_separator "$cmd")
  return 1
}

run_self_test() {
  local fail=0
  assert_deny() {
    if evaluate_command "$2"; then printf 'ok  : %s\n' "$1"
    else printf 'FAIL: %s  -- expected deny, got passthrough\n' "$1"; fail=1; fi
  }
  assert_pass() {
    if evaluate_command "$2"; then printf 'FAIL: %s  -- expected passthrough, got deny\n' "$1"; fail=1
    else printf 'ok  : %s\n' "$1"; fi
  }

  # 拾う: gh api の出力を python で整形している
  assert_deny 'gh api | python3 -c' 'gh api repos/o/r/pulls/1 | python3 -c "import json,sys; print(json.load(sys.stdin))"'
  assert_deny 'python (3 なし)' 'gh api repos/o/r/pulls/1 | python -c "import json,sys; print(1)"'
  assert_deny 'python3 -m json.tool' 'gh api repos/o/r/pulls/1 | python3 -m json.tool'
  assert_deny '前段に cd' 'cd /r && gh api repos/o/r/pulls/1 | python3 -c "import json,sys; print(1)"'
  assert_deny '間に head が挟まる' 'gh api repos/o/r/pulls/1 | head -100 | python3 -c "import json,sys; print(1)"'
  assert_deny '2>&1 付き' 'gh api repos/o/r/pulls/1 2>&1 | python3 -c "import json,sys; print(1)"'
  assert_deny '複数行の python -c' $'gh api repos/o/r/pulls/1 | python3 -c "\nimport json,sys\nprint(json.load(sys.stdin))\n"'
  assert_deny '後段に別コマンドが続く' $'gh api repos/o/r/pulls/1 | python3 -c "import json,sys; print(1)"\necho done'
  assert_deny '-c の前に別オプション' 'gh api repos/o/r/pulls/1 | python3 -u -c "import json,sys; print(1)"'
  assert_deny '-m の連結形' 'gh api repos/o/r/pulls/1 | python3 -mjson.tool'

  # 拾わない: 誤検知を避ける側
  assert_pass 'heredoc の中身' $'cat > /tmp/f <<\'EOF\'\ngh api repos/o/r/pulls/1 | python3 -c "import json,sys"\nEOF'
  assert_pass 'パイプで繋がっていない (;)' 'gh api repos/o/r/pulls/1 > /tmp/x ; python3 -c "import json,sys; print(1)"'
  assert_pass 'パイプで繋がっていない (&&)' 'gh api repos/o/r/pulls/1 && python3 -c "import json,sys; print(1)"'
  assert_pass 'gh api 由来でない' 'cat data.json | python3 -c "import json,sys; print(1)"'
  assert_pass 'gh pr view は対象外' 'gh pr view 1 --json body | python3 -c "import json,sys; print(1)"'
  assert_pass 'ファイル書き出しあり' 'gh api repos/o/r/pulls/1 | python3 -c "import json,sys; open(\"/tmp/o\",\"w\").write(1)"'
  assert_pass 'os を使う' 'gh api repos/o/r/pulls/1 | python3 -c "import json,sys,os; print(os.getcwd())"'
  assert_pass 'from import を使う' 'gh api repos/o/r/pulls/1 | python3 -c "from collections import Counter; print(1)"'
  assert_pass '外部ライブラリ' 'gh api repos/o/r/pulls/1 | python3 -c "import json,sys,re; print(1)"'
  assert_pass 'クォート内に python の字' "gh api repos/o/r/pulls/1 | jq 'select(test(\"python3|python \"))'"
  assert_pass 'jq を使っている' "gh api repos/o/r/pulls/1 | jq -r '.title'"
  assert_pass 'python 単体 (gh api 無し)' 'python3 -c "import json,sys; print(1)"'
  assert_pass 'フルパスの python' 'gh api repos/o/r/pulls/1 | /usr/bin/python3 -c "import json,sys; print(1)"'
  # deny 理由文が案内する逃げ道 (`python3 <file>`) 自身は deny してはならない。
  assert_pass 'スクリプトファイル実行' 'gh api repos/o/r/pulls/1 | python3 /tmp/fmt.py'
  assert_pass 'スクリプトファイル + スクリプト側の -c' 'gh api repos/o/r/pulls/1 | python3 fmt.py -c x'
  assert_pass 'stdin からスクリプト' 'gh api repos/o/r/pulls/1 | python3 -'

  if [ "$fail" = 0 ]; then printf '\nall tests passed.\n'; return 0
  else printf '\nsome tests failed.\n'; return 1; fi
}

if [ "${1:-}" = '--self-test' ]; then
  run_self_test
  exit $?
fi

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# why hook 側でも種別を確かめる: settings の if 句はコマンドをパースできないとき
# fail open して起動するので、Bash 以外が届きうる。
[ "$tool_name" = 'Bash' ] || { passthrough; exit 0; }

command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_str" ] || { passthrough; exit 0; }

if evaluate_command "$command_str"; then
  emit_deny
else
  passthrough
fi
