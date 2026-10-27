#!/usr/bin/env bash
# Claude Code の statusLine ラッパ。
# why: statusLine に登録できるコマンドは 1 つだけなので、RunCat Neo 用スナップショットの
#      書き出しと端末表示 (ccstatusline) をここで束ねる。stdin の JSON は 1 度しか読めない
#      ため、一旦変数に受けてから両者へ配る。
# why 名前に ccstatusline を含める: ccstatusline は設定画面で保存するたびに Skills 用の hook を
#      張り直すが、statusLine のコマンドに "ccstatusline" が含まれないと別ツールとみなして
#      hook を消す (2.2.31〜)。改名でこの語を落とすと、保存のたびに Skills 表示が止まる。
#
# usage: ccstatusline-wrapper.sh [ccstatusline の引数...] < statusline.json
#        ccstatusline-wrapper.sh --hook < hook.json
#        ccstatusline-wrapper.sh --self-test
set -uo pipefail

run() {
  # why --hook は表示処理を通さない: ccstatusline が張り直す hook は「statusLine のコマンド + --hook」
  #      なので、hook の呼び出しもこのラッパを通る。stdin はステータスラインの JSON ではなく、
  #      UserPromptSubmit hook の stdout は会話に入るため、何も出力しない ccstatusline --hook へ素通しする。
  local arg payload script_dir
  for arg in "$@"; do
    if [ "$arg" = "--hook" ]; then
      exec npx -y ccstatusline@latest "$@"
    fi
  done

  # why hook 判定の後: hook はプロンプトごとに走るので、表示でしか使わないパス解決を先にしない
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  payload=$(cat)

  # why: スナップショット生成 (python3 不在・書き込み失敗を含む) が転けても端末表示は落とさない。
  #      失敗しても RunCat のカードが古いまま残るだけで、統計行は従来どおり出る。
  #      runcat-statusline.py は上流サンプルのまま置いてあり (上流更新をそのまま取り込めるように)、
  #      モデル名を stdout に出すのでここで捨てる。
  printf '%s' "$payload" | "$script_dir/runcat-statusline.py" >/dev/null 2>&1 || true

  printf '%s' "$payload" | npx -y ccstatusline@latest "$@"
}

# 本体を一時ディレクトリへ複製し、隣に偽の runcat-statusline.py、PATH の先頭に偽の npx を置いて
# 起動する。本物の ccstatusline を取りに行かず、ラッパ自身の振り分けと出力だけを見るため。
self_test() {
  local tmp tmproot=${TMPDIR:-/tmp} fail=0 input='{"session_id":"self-test","prompt":"/x"}' out
  # why %/ で付け直す: Linux では TMPDIR が末尾スラッシュ無しで来うる。素で連結すると / 直下を
  #      指して失敗し、tmp が空のまま偽 npx を /bin/npx へ書きに行く
  tmp=$(mktemp -d "${tmproot%/}/ccstatusline-wrapper-test-XXXXXX") || return 1
  # why 即時展開: tmp は local なので EXIT 時には消えている
  trap "rm -rf \"$tmp\"" EXIT
  mkdir -p "$tmp/bin"
  cp "${BASH_SOURCE[0]}" "$tmp/wrapper.sh"
  # 偽 npx: 引数と stdin を記録し、hook モード以外では描画結果を模した 1 行を出す
  cat >"$tmp/bin/npx" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$tmp/npx.args"
cat >"$tmp/npx.stdin"
case " \$* " in *" --hook "*) ;; *) printf 'RENDERED' ;; esac
EOF
  # 偽 runcat: 本物と同じく stdout にモデル名を出す。終了コードは RUNCAT_EXIT で切り替える
  cat >"$tmp/runcat-statusline.py" <<EOF
#!/usr/bin/env bash
cat >"$tmp/runcat.stdin"
echo model-name
exit "\${RUNCAT_EXIT:-0}"
EOF
  chmod +x "$tmp/bin/npx" "$tmp/runcat-statusline.py"

  check() {
    local name=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then
      echo "ok   $name"
    else
      echo "FAIL $name: want [$want] got [$got]"
      fail=1
    fi
  }
  invoke() {
    rm -f "$tmp/npx.args" "$tmp/npx.stdin" "$tmp/runcat.stdin"
    # why ${args[@]+...}: bash 4.3 以前 (macOS 同梱の 3.2) は set -u 下で空配列の展開を unbound で落とす
    printf '%s' "$input" | env PATH="$tmp/bin:$PATH" "$@" bash "$tmp/wrapper.sh" ${args[@]+"${args[@]}"}
  }
  local args

  args=(--hook)
  out=$(invoke)
  # why: UserPromptSubmit hook の stdout は会話に入る。ここが空でないと毎プロンプトに混ざる
  check "hook: 何も出力しない" "" "$out"
  check "hook: ccstatusline に --hook を渡す" "-y ccstatusline@latest --hook" "$(cat "$tmp/npx.args")"
  check "hook: stdin をそのまま渡す" "$input" "$(cat "$tmp/npx.stdin")"
  check "hook: RunCat の書き出しを通さない" "absent" "$([ -e "$tmp/runcat.stdin" ] && echo present || echo absent)"

  args=()
  out=$(invoke)
  check "表示: ccstatusline の出力だけを出す" "RENDERED" "$out"
  check "表示: ccstatusline を引数なしで呼ぶ" "-y ccstatusline@latest" "$(cat "$tmp/npx.args")"
  check "表示: ccstatusline に stdin を渡す" "$input" "$(cat "$tmp/npx.stdin")"
  check "表示: RunCat に stdin を渡す" "$input" "$(cat "$tmp/runcat.stdin")"

  args=(--config /x/y.json)
  out=$(invoke)
  check "表示: 受け取った引数を ccstatusline に渡す" "-y ccstatusline@latest --config /x/y.json" "$(cat "$tmp/npx.args")"

  # why: ccstatusline は hook を「statusLine のコマンド + --hook」で作るので、statusLine に引数があると
  #      --hook は末尾に来る。先頭だけ見る判定に退行すると hook の JSON を描画に回してしまう
  args=(--config /x/y.json --hook)
  out=$(invoke)
  check "hook: 末尾の --hook でも hook として扱う" "" "$out"
  check "hook: 末尾の --hook でも RunCat を通さない" "absent" "$([ -e "$tmp/runcat.stdin" ] && echo present || echo absent)"

  args=()
  out=$(invoke RUNCAT_EXIT=1)
  check "表示: RunCat が失敗しても表示は出す" "RENDERED" "$out"

  return $fail
}

case "${1:-}" in
  --self-test) self_test ;;
  *) run "$@" ;;
esac
