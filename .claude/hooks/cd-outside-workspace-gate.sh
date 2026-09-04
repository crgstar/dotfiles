#!/usr/bin/env bash
# PreToolUse hook:
# 作業ディレクトリ外へ `cd` した状態で相対パスを参照しているコマンドを、
# セッション内で最初の 1 回だけ deny し、絶対パスでの書き直しを促す。
#
# Why この形が確認ダイアログになるか:
#   Claude Code は「cd で cwd を作業ディレクトリ (primary + additionalDirectories)
#   の外へ移し、その先を相対パスで参照する」形だけを確認に落とす。実測では
#     cd <外部> && echo ok              -> 通る (ファイルを触らない)
#     cd <外部> && grep -c . CLAUDE.md  -> 確認が出る
#     cd <内部> && grep -c . x.json     -> 通る
#     grep -c . /abs/<外部>/CLAUDE.md   -> 通る (cd 無し・絶対パス)
#   壁は「読める範囲」ではなく「相対パスの解決先が作業ディレクトリの外になること」。
#   つまり同じ操作が cd を捨てるだけで確認無しに書き直せる。
#
# Why deny (ask ではなく):
#   deny の理由文だけが「ユーザではなくモデル」に渡る。ask は人間の手を止めるが、
#   deny ならダイアログ無しでモデルに差し戻せる。prefer-jq-over-python.sh と同じ型。
#
# Why セッションにつき 1 回だけか:
#   `cd <repo> && npm test` のように cwd 依存で絶対パスに書き換えようがない
#   コマンドがある。毎回 deny にすると、そこで案内どおり直せず無限ループになる。
#   1 回で打ち切れば、書き換えられる形は 1 往復で直り、書き換えられない形は
#   2 回目にそのまま通る (静的ルールの ask に落ちるだけ)。逃げ道が構造的に開く。
#
# Usage:
#   1) フック本体: stdin に Claude Code が渡す JSON を受け取り PreToolUse decision を出す
#   2) セルフテスト: `bash cd-outside-workspace-gate.sh --self-test`

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/bash-safety.sh"

DENY_REASON='作業ディレクトリ外へ cd した状態で相対パスを参照しています。この形は毎回確認ダイアログになります。cd をやめて絶対パスで書き直してください。

  R=/path/to/repo
  grep -rn "x" "$R/src" "$R/CLAUDE.md"

git は `git -C <path> <サブコマンド>`、gh は `gh <サブコマンド> -R <owner>/<repo>` で cd 無しに書けます。
cwd に依存していて絶対パスに書き換えられない場合 (npm / make / pytest 等) は、そのまま再実行してください。この差し戻しはセッションにつき 1 回だけで、2 回目以降は素通しします。'

emit_deny() {
  jq -n --arg r "$DENY_REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# 判定せず静的ルールに委ねる
passthrough() { printf '{}\n'; }

# 先頭の ~ を $HOME に展開する(純粋関数)。
# why 展開する: settings の additionalDirectories は `~/.claude` の形で書かれるが、
# cd 先や cwd は実パスで来る。片方だけ展開すると前方一致が必ず外れる。
expand_tilde() {
  case "$1" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# 絶対パスから . / .. / 重複スラッシュを畳む(純粋関数)。
#
# why readlink -f を使わない: macOS の readlink は存在しないパスを解決できず、
# `cd <これから作るディレクトリ>` のような形で黙って空を返す。空になると
# 前方一致が全部外れて「作業ディレクトリ外」と誤判定するので、
# ファイルシステムに触らない文字列処理だけで畳む。
# why 単語分割 (IFS=/) を使わない: パスに * や ? が含まれると glob 展開されて
# 別のパスに化ける。パラメータ展開だけで 1 成分ずつ切り出す。
normalize_path() {
  local rest="$1" comp s="" c
  local -a out=()
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$comp" in
      ''|.) continue ;;
      ..) if [ "${#out[@]}" -gt 0 ]; then out=("${out[@]:0:${#out[@]}-1}"); fi ;;
      *) out+=("$comp") ;;
    esac
  done
  for c in ${out[@]+"${out[@]}"}; do s="$s/$c"; done
  printf '%s' "${s:-/}"
}

# パスが作業ディレクトリのどれにも属さないか(純粋関数)。
# $2 は改行区切りの作業ディレクトリ一覧 (正規化済みの絶対パス)。
# 0: 外部 / 1: いずれかの配下
#
# why 一覧が空なら「外部でない」に倒す: 一覧の組み立てに失敗した (設定が読めない)
# ときに全 cd を deny すると、誤 deny が広範囲に出る。判定できないなら手を引く。
is_outside_workspace() {
  local path="$1" ws="$2" w
  [ -n "$ws" ] || return 1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$path" = "$w" ] && return 1
    case "$path" in "$w"/*) return 1 ;; esac
  done <<< "$ws"
  return 0
}

# セグメントが `cd <path>` なら、正規化した移動先の絶対パスを出力する(純粋関数)。
# 0: 移動先を確定した / 1: cd ではない / 2: cd だが移動先が確定しない
#
# why 引数なしの cd と `cd -` を 2 で返す: 前者は $HOME、後者は直前の
# ディレクトリで、いずれも移動先がコマンド文字列から確定しない。
# 「cd ではない」と同じ 1 にすると、呼び出し側が cwd 追跡を失ったことに
# 気づけず、以降の相対パスを古い基準で照合して誤 deny する。
cd_target_of() {
  local seg="$1" cwd="$2" toks t1 rest t2
  toks="$(tokenize_quoted "$seg")"
  t1="${toks%%$'\n'*}"
  [ "$t1" = 'cd' ] || return 1
  rest="${toks#*$'\n'}"
  [ "$rest" = "$toks" ] && return 2
  t2="${rest%%$'\n'*}"
  [ -n "$t2" ] || return 2
  case "$t2" in -*) return 2 ;; esac
  t2="$(expand_tilde "$t2")"
  case "$t2" in /*) ;; *) t2="$cwd/$t2" ;; esac
  normalize_path "$t2"
}

# セグメントが「作業ディレクトリ外に解決される実在パス」を相対パスで参照しているか。
# $3 は改行区切りの作業ディレクトリ一覧。0: 参照している / 1: していない
#
# why 実在チェックで判定する: 任意のコマンドのどの引数がパスかは静的に決まらない。
# 「移動先に実際にそのファイル/ディレクトリがある」なら、それはパス引数と見てよい。
# 語形だけの推測 (ドットを含む・拡張子がある) より誤検知が少ない。
# why 解決後に外部かを見る: 相対パスは `..` で作業ディレクトリ内へ戻れる
# (`cd <外部> && cat ../../dotfiles/CLAUDE.md`)。この形は解決先が内部なので
# 確認ダイアログにならず、base 配下の実在チェックだけでは誤 deny になる。
# why 1 トークン目は `/` を含むときだけ見る: コマンド名自身が cd 先に同名で
# 実在しうる (`cd /repo && make` で /repo/make がある等) ので素の語は飛ばすが、
# `./run.sh` / `src/bin/tool` のように `/` を含む形はコマンド名そのものが
# 相対パス参照で、確認ダイアログの原因になる。
has_relative_path_arg() {
  local seg="$1" base="$2" ws="$3" t idx=0 resolved
  while IFS= read -r t; do
    idx=$((idx+1))
    if [ "$idx" = 1 ]; then
      case "$t" in */*) ;; *) continue ;; esac
    fi
    case "$t" in
      ''|.|..|-*|/*|'~'*) continue ;;  # why . と .. を除く: [ -e dir/. ] が常に真で、grep -c . file の正規表現引数まで拾うため
    esac
    [ -e "$base/$t" ] || continue
    resolved="$(normalize_path "$base/$t")"
    is_outside_workspace "$resolved" "$ws" && return 0
  done < <(tokenize_quoted "$seg")
  return 1
}

# コマンド文字列が judge の対象になり得るか(純粋関数)。0: 対象 / 1: 対象外
#
# why 分けて公開する: split_with_separator は 1 文字ずつ走査するので長いコマンドでは
# 重く、collect_workspaces は設定ファイルを読む。このフックは全 Bash 呼び出しで走る
# ため、対象になり得ないものにその両方を払わせない。呼び出し側が
# collect_workspaces より先にこれを通すことで、引数評価の順序に関係なく足切りが効く。
# 見逃しは静的ルールの ask に落ちるだけで安全側。
may_need_judgement() {
  local cmd="$1"
  # why 区切り文字も先行文字に数える: bash では `echo x;cd /outside` のように
  # 区切りの直後へ空白なしで書けるが、空白と行頭だけを見ていると足切りで落ちて
  # hook が起動せず、差し戻したいはずの形がそのまま確認ダイアログになる。
  [[ "$cmd" =~ (^|[[:space:]]|[\;\&\|])cd[[:space:]] ]] || return 1
  # why heredoc を含むなら丸ごと対象外: 本文は実行されないただの文字列だが、
  # split_with_separator は `<<` を解釈しないので中身が実コマンドとして並んで
  # 見える。判定できない形は手を引く (prefer-jq-over-python.sh と同じ)。
  case "$cmd" in *'<<'*) return 1 ;; esac
  return 0
}

# コマンド全体を評価する。0: deny すべき / 1: 素通し
# $2 = cwd (primary working directory), $3 = 改行区切りの作業ディレクトリ一覧
evaluate_command() {
  local cmd="$1" cwd="$2" workspaces="$3"
  may_need_judgement "$cmd" || return 1

  local rec seg target outside=0 cur rc
  # why cwd を進める: 相対パスの cd は「直前の cd 先」から解決される。
  # `cd sub && cd ../outside && cat x` を常に元の cwd 基準で畳むと、
  # 移動先を実際とは別のディレクトリと読み違える (誤 deny / 見逃しの両方が出る)。
  cur="$(normalize_path "$cwd")"
  while IFS= read -r -d '' rec; do
    seg="${rec#*$'\t'}"
    rc=0
    target="$(cd_target_of "$seg" "$cur")" || rc=$?
    # why cd を毎回評価する: 外部へ出たあとに内部へ戻る形がある
    # (`cd <外部> && cd <内部> && cat x`)。最初の外部 cd で判定を固定すると、
    # 参照時点の cwd が内部なのに古い外部パスを基準に照合して誤 deny する。
    case "$rc" in
      0)
        cur="$target"
        if is_outside_workspace "$cur" "$workspaces"; then outside=1; else outside=0; fi
        continue
        ;;
      # 移動先が確定しない cd (`cd` / `cd -`)。以降の相対パスの基準を失うので、
      # 判定を続けず素通しに倒す (確定しないものは deny の根拠にしない)。
      2) return 1 ;;
    esac
    [ "$outside" = 1 ] || continue
    has_relative_path_arg "$seg" "$cur" "$workspaces" && return 0
  done < <(split_with_separator "$cmd")
  return 1
}

# 作業ディレクトリ一覧を組み立てる (設定ファイルを読む副作用あり)。
#
# why 完全には再現できない: additionalDirectories は user / project / local の
# 各 scope が union されるうえ、`--add-dir` フラグは設定ファイルに現れない。
# 取りこぼすと「本当は作業ディレクトリ内なのに外と判定する」誤 deny になるので、
# 読める source は全部読んで一覧を広く取る (広い方が deny は減り安全側)。
collect_workspaces() {
  local cwd="$1" f w
  printf '%s\n' "$(normalize_path "$cwd")"
  # why 一時ディレクトリを一覧に加える: Claude Code は /tmp・$TMPDIR・scratchpad
  # (/private/tmp/claude-<uid>/...) への cd を確認に落とさない (実測)。ここに
  # 入れないと、一時ファイルを作って cd して読むだけの流れを誤って差し戻す。
  printf '%s\n' /tmp /private/tmp /var/folders /private/var/folders
  [ -n "${TMPDIR:-}" ] && printf '%s\n' "$(normalize_path "$TMPDIR")" || true
  for f in "$HOME/.claude/settings.json" \
           "$cwd/.claude/settings.local.json" \
           "$cwd/.claude/settings.json"; do
    [ -f "$f" ] || continue
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      printf '%s\n' "$(normalize_path "$(expand_tilde "$w")")"
    done < <(jq -r '.permissions.additionalDirectories[]? // empty' "$f" 2>/dev/null || true)
  done
}

# セッション印のパスを組み立てる(純粋関数)。
# why session_id を検証する: そのままパスに埋めるため。想定外の形なら空を返し、
# 呼び出し側が素通しに倒す (追跡できない以上、恒久 deny より素通しが安全)。
marker_path_for() {
  local sid="$1" tmp="${TMPDIR:-/tmp}"
  case "$sid" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s/claude-cd-outside-workspace-gate/%s' "${tmp%/}" "$sid"
}

run_self_test() {
  local fail=0
  # 実在チェックを伴うので、実体のあるディレクトリを組み立てて評価する。
  local root ws out tmp
  # why 末尾スラッシュを剥がして自分で足す: TMPDIR は末尾スラッシュ有無の両方が
  # ありうる。`${TMPDIR:-/tmp/}cdgate-XXXXXX` だと TMPDIR=/tmp のとき
  # /tmpcdgate-XXXXXX (ルート直下) を作ろうとして失敗し、self-test が落ちる。
  tmp="${TMPDIR:-/tmp}"
  root="$(mktemp -d "${tmp%/}/cdgate-XXXXXX")"
  ws="$root/ws"; out="$root/outside/repo"
  mkdir -p "$ws/sub" "$out/src" "$out/specs"
  : > "$ws/sub/inside.txt"
  : > "$out/CLAUDE.md"; : > "$out/specs/README.md"; : > "$out/make"
  local WS; WS="$ws"$'\n'"$root/extra"

  assert_deny() {
    if evaluate_command "$2" "${3:-$ws}" "$WS"; then printf 'ok  : %s\n' "$1"
    else printf 'FAIL: %s  -- expected deny, got passthrough\n' "$1"; fail=1; fi
  }
  assert_pass() {
    if evaluate_command "$2" "${3:-$ws}" "$WS"; then printf 'FAIL: %s  -- expected passthrough, got deny\n' "$1"; fail=1
    else printf 'ok  : %s\n' "$1"; fi
  }
  assert_eq() {
    if [ "$2" = "$3" ]; then printf 'ok  : %s\n' "$1"
    else printf 'FAIL: %s  -- expected [%s], got [%s]\n' "$1" "$3" "$2"; fail=1; fi
  }

  # 拾う: 外部へ cd した後の相対パス参照
  assert_deny '外部 cd + 相対ファイル' "cd $out && grep -c . CLAUDE.md"
  assert_deny '外部 cd + 相対ディレクトリ' "cd $out && ls src"
  assert_deny '; 区切り' "cd $out ; cat CLAUDE.md"
  assert_deny '区切り直後の cd (空白なし)' "echo start;cd $out && cat CLAUDE.md"
  assert_deny '深い相対パス' "cd $out && cat specs/README.md"
  assert_deny 'パイプの先で参照' "cd $out && grep -rn x src | head -30"
  assert_deny '相対パスで外部へ cd' "cd ../outside/repo && cat CLAUDE.md" "$ws"
  assert_deny 'クォート付きの cd 先' "cd '$out' && cat CLAUDE.md"
  # why 連鎖 cd を試す: 2 つ目の相対 cd は 1 つ目の移動先から解決される。
  # 元の cwd 基準で畳むと $ws/../outside/repo (= 実在しない) になり見逃す。
  assert_deny '内部 cd のあとに相対 cd で外部へ' "cd sub && cd ../../outside/repo && cat CLAUDE.md" "$ws"
  # why コマンド名自体が相対パスの形を拾う: `./make` は cd 先の実体を指す相対参照で、
  # 確認ダイアログの原因になる (素の `make` はコマンド名なので拾わない)。
  assert_deny 'コマンド自体が相対パス' "cd $out && ./make"
  # 切り分けで実際に確認ダイアログを出した形 (回帰の要)
  assert_deny '元の問題コマンド' \
    "cd $out && echo '=== issues ===' && gh issue list --limit 20 ; echo '=== 確認 ===' && grep -rn needle --include='*.ts' src specs/README.md CLAUDE.md 2>/dev/null | head -30"

  # 拾わない: 誤検知を避ける側
  assert_pass '作業ディレクトリ内への cd' "cd $ws/sub && cat inside.txt"
  assert_pass '相対パス参照なし' "cd $out && echo ok"
  assert_pass '存在しない引数だけ' "cd $out && npm test"
  assert_pass '絶対パスで参照' "cd $out && cat $out/CLAUDE.md"
  assert_pass 'オプションだけ' "cd $out && grep -c . --include='*.md'"
  assert_pass 'cd が無い' "grep -c . $out/CLAUDE.md"
  # why 理由文が案内する書き換え後の形を固定する: 案内先が自分の判定に
  # 引っかかると、モデルが言われたとおり直しても同じ差し戻しに戻る。
  assert_pass '案内先: git -C' "git -C $out log --oneline -5"
  assert_pass '案内先: gh -R' "gh issue list -R owner/repo --limit 20"
  assert_pass '案内先: 変数に入れた絶対パス' "R=$out; grep -rn x \"\$R/src\" \"\$R/CLAUDE.md\""
  assert_pass 'cd より前の相対パス' "cat CLAUDE.md && cd $out"
  assert_pass 'コマンド名が cd 先に実在' "cd $out && make"
  assert_pass '引数なしの cd' "cd && cat CLAUDE.md"
  assert_pass 'cd - (移動先が不定)' "cd - && cat CLAUDE.md"
  # why 外部→内部の cd 戻りを試す: 参照時点の cwd は内部なので確認ダイアログに
  # ならない。最初の外部 cd で判定を固定すると誤 deny になる ($out/CLAUDE.md も
  # $ws/sub/inside.txt も実在するので、基準を取り違えると必ず引っかかる)。
  assert_pass '外部へ cd したあと内部へ cd し直す' "cd $out && cd $ws/sub && cat inside.txt"
  assert_pass '外部へ cd したあと cd - で戻る' "cd $out && cd - && cat CLAUDE.md"
  # why 解決先が内部に戻る相対パスを試す: `..` で作業ディレクトリ内へ戻る形は
  # 確認ダイアログにならない。
  assert_pass '相対パスの解決先が内部' "cd $out && cat ../../ws/sub/inside.txt"
  assert_pass 'heredoc の中身' "cat > /tmp/f <<'EOF'
cd $out && cat CLAUDE.md
EOF"
  if evaluate_command "cd $out && cat CLAUDE.md" "$ws" ""; then
    printf 'FAIL: 一覧が空なら素通し  -- expected passthrough, got deny\n'; fail=1
  else printf 'ok  : 一覧が空なら素通し\n'; fi

  # normalize_path (純粋関数)
  assert_eq 'normalize .. を畳む'      "$(normalize_path '/a/b/../c')" '/a/c'
  assert_eq 'normalize . と // を畳む'  "$(normalize_path '/a//b/./c')" '/a/b/c'
  assert_eq 'normalize ルート超え'      "$(normalize_path '/../..')" '/'
  assert_eq 'normalize glob を展開しない' "$(normalize_path '/a/*/b')" '/a/*/b'
  assert_eq 'normalize 末尾スラッシュ'   "$(normalize_path '/a/b/')" '/a/b'

  # is_outside_workspace (純粋関数)
  if is_outside_workspace '/ws/sub/x' '/ws'; then
    printf 'FAIL: 配下は内部  -- expected inside\n'; fail=1
  else printf 'ok  : 配下は内部\n'; fi
  # why 境界を試す: 前方一致だけだと /ws-other が /ws の配下に見える
  if is_outside_workspace '/ws-other/x' '/ws'; then printf 'ok  : 名前が前方一致するだけの別ディレクトリは外部\n'
  else printf 'FAIL: /ws-other  -- expected outside\n'; fail=1; fi
  if is_outside_workspace '/ws' '/ws'; then
    printf 'FAIL: 一覧と同一パス  -- expected inside\n'; fail=1
  else printf 'ok  : 一覧と同一パスは内部\n'; fi

  # cd_target_of (純粋関数)
  assert_eq 'cd 絶対パス'   "$(cd_target_of 'cd /a/b' /cwd || true)" '/a/b'
  assert_eq 'cd 相対パス'   "$(cd_target_of 'cd ../x' /a/b || true)" '/a/x'
  assert_eq 'cd 空白入り'   "$(cd_target_of 'cd "/a b/c"' /cwd || true)" '/a b/c'
  assert_eq 'cd 引数なし'   "$(cd_target_of 'cd' /cwd || true)" ''
  assert_eq 'cd -'          "$(cd_target_of 'cd -' /cwd || true)" ''
  assert_eq 'cd でない'     "$(cd_target_of 'cat x' /cwd || true)" ''

  # marker_path_for (純粋関数)
  if marker_path_for 'a b' >/dev/null 2>&1; then
    printf 'FAIL: 不正な session_id  -- expected rejection\n'; fail=1
  else printf 'ok  : 不正な session_id を弾く\n'; fi
  if [ -n "$(marker_path_for 'abc123-def456-7890' 2>/dev/null)" ]; then
    printf 'ok  : 正常な session_id を受理\n'
  else printf 'FAIL: 正常な session_id  -- expected path\n'; fail=1; fi


  # collect_workspaces (設定と一時ディレクトリを読む)
  # why 一時ディレクトリを確かめる: ここが抜けると scratchpad / /tmp での
  # 作業が丸ごと誤 deny になる (実ログでは deny 判定の 2 割強がこの領域だった)。
  local cw probe; cw="$(collect_workspaces "$ws")"
  for probe in /tmp /private/tmp /var/folders; do
    if is_outside_workspace "$probe/x/y" "$cw"; then
      printf 'FAIL: %s が作業ディレクトリ扱いでない\n' "$probe"; fail=1
    else printf 'ok  : %s は作業ディレクトリ扱い\n' "$probe"; fi
  done
  if is_outside_workspace "$ws/sub" "$cw"; then
    printf 'FAIL: cwd 自身が作業ディレクトリ扱いでない\n'; fail=1
  else printf 'ok  : cwd 自身は作業ディレクトリ扱い\n'; fi
  rm -rf "$root"
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

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || { passthrough; exit 0; }

# why collect_workspaces より先に足切りする: 引数はコマンド本体より先に評価される
# ので、evaluate_command の中だけで足切りしても設定ファイルの読み込みは避けられない。
may_need_judgement "$command_str" || { passthrough; exit 0; }

evaluate_command "$command_str" "$cwd" "$(collect_workspaces "$cwd")" || { passthrough; exit 0; }

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
marker="$(marker_path_for "$session_id" 2>/dev/null || true)"
# 印を置けない (session_id 不明) なら素通し。恒久 deny になるより安全側。
[ -n "$marker" ] || { passthrough; exit 0; }

[ -e "$marker" ] && { passthrough; exit 0; }

# why 印を置けてから deny する: 置けないまま deny すると次回も印が無く、同じ
# 差し戻しをセッション中ずっと繰り返す (「2 回目以降は素通し」という理由文が嘘に
# なり、cwd 依存で書き換えられないコマンドの手段が塞がる)。
mkdir -p "$(dirname "$marker")" 2>/dev/null && : > "$marker" 2>/dev/null || { passthrough; exit 0; }
emit_deny
