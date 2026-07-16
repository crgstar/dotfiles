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

# has_dangerous_shape / tokenize_quoted / DOTFILES_SKILLS_DIR は
# escalate-unsafe-bash.sh と共有 (lib/ も ~/.claude/hooks/lib/ にリンクされる前提。setup.sh)。
source "$(dirname "${BASH_SOURCE[0]}")/lib/bash-safety.sh"

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

# セグメント（trim 済み）がクォート外に危険なシェルメタ文字を含むか判定する。
# 0: 含む(危険) / 1: 含まない
#
# Why: 末尾 glob の prefix 照合はセグメント先頭のコマンド名しか守れない。
#   split_segments が分割するのは &&/||/;/| だけなので、単一 & (バックグラウンド)・
#   改行・$()・`` ` ``・サブシェル ()・入出力リダイレクト < > は 1 セグメント内に
#   残り、`echo *` 等の safe prefix にマッチして素通りしてしまう。
#   例: `gh api foo & rm -rf ~` は 1 セグメントで `gh api ` 始まり扱いになる。
#   これらを含むセグメントは prefix が何であれ unsafe に倒す（構造の白名簿化）。
# ' " ` のクォートは尊重するが、ダブルクォート内でも $ と ` は展開されるため危険とみなす。
# gh api の /tmp リダイレクト例外は、呼び出し側が > を剥がしてからこの関数に渡す。
has_unsafe_metachar() {
  local s="$1"
  local i=0 len=${#s} ch
  local in_single=0 in_double=0 bs_run=0
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    if [ "$in_single" = 1 ]; then
      [ "$ch" = "'" ] && in_single=0
    elif [ "$in_double" = 1 ]; then
      if [ "$ch" = '\' ]; then
        bs_run=$((bs_run+1))
      elif [ "$ch" = '"' ]; then
        [ $((bs_run % 2)) -eq 0 ] && in_double=0
        bs_run=0
      elif [ "$ch" = '$' ] || [ "$ch" = '`' ]; then
        return 0
      else
        bs_run=0
      fi
    else
      case "$ch" in
        "'") in_single=1 ;;
        '"') in_double=1; bs_run=0 ;;
        '$'|'`'|'&'|'('|')'|'<'|'>') return 0 ;;
        *) [ "$ch" = $'\n' ] && return 0 ;;
      esac
    fi
    i=$((i+1))
  done
  return 1
}

# 単一セグメント（trim 済み前提）が safe-prefix に該当するか判定する。
# 0: safe / 1: not safe
is_safe_segment() {
  local seg="$1"
  [ -z "$seg" ] && return 1

  # gh api の出力を一時ファイルへ保存する `> /tmp/...` / `>> /tmp/...` は
  # 実運用で多用するため例外的に許可する。リダイレクト先は /tmp/ 配下の
  # リテラルパス（空白・変数展開・.. を含まない）に限定し、リダイレクト部を
  # 剥がして残りを通常判定に回す。/tmp 以外・変数展開ありのリダイレクトは
  # ここでマッチせず、後段の has_unsafe_metachar が > を検出して unsafe にする。
  case "$seg" in
    'gh api '*'>'*)
      # why リダイレクト先の許可文字を制限: 以前は [^[:space:]]+ で任意文字を
      # 受けていたため `> /tmp/$(id).json` のようなコマンド置換がリダイレクト先
      # に紛れ込んでも剥がされて後段の has_unsafe_metachar に届かず ALLOW された
      # (finding #0)。英数字・.・/ ・_・- だけに絞ることで $ ` ( ) 等を構造的に排除する。
      if [[ "$seg" =~ ^(gh\ api\ [^\>]*[^\>[:space:]])[[:space:]]*'>''>'?[[:space:]]*(/tmp/[A-Za-z0-9._/-]+)$ ]] \
         && [[ "${BASH_REMATCH[2]}" != *..* ]]; then
        seg="${BASH_REMATCH[1]}"
      fi
      ;;
  esac

  # クォート外の危険メタ文字（& $ ` ( ) < > 改行）を含むなら不許可。
  if has_unsafe_metachar "$seg"; then
    return 1
  fi

  # escalate-unsafe-bash.sh と同じ危険形チェック (find -exec/-delete・非localhost
  # curl・第三者スキル実行)。これが無いと、escalate 側が ask に格上げした危険形も
  # `gh api` と連結するだけで PermissionRequest 側が allow に戻してしまう (finding #1)。
  # why >/dev/null: has_dangerous_shape は該当時に理由を stdout へ printf する。
  # ここでは真偽だけ使うので、捨てないとフックの JSON 出力に理由文字列が混入する。
  if has_dangerous_shape "$seg" >/dev/null; then
    return 1
  fi

  # gh api は「書き込みフラグを 1 つも含まないと証明できるとき」だけ safe。
  # 静的 allow には Bash(gh api *) が無い前提で、hook が auto-allow の責務を負う。
  # ブロックリスト正規表現は long form (--field/--raw-field) や連結形 (-XDELETE,
  # -Ftitle=x) を取りこぼすため、トークンに分割して write 系フラグの prefix を見る。
  #   -X* / --method* : HTTP メソッド指定
  #   -f* / --raw-field* : raw string パラメータ（GET を POST 化する）
  #   -F* / --field*     : typed パラメータ（同上）
  #   --input*           : リクエストボディ
  case "$seg" in
    'gh api '*)
      local t
      while IFS= read -r t; do
        case "$t" in
          -X*|--method*|-f*|-F*|--field*|--raw-field*|--input*)
            return 1
            ;;
        esac
      done < <(tokenize_quoted "$seg")
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
  # 不正 JSON / command 欠落では判定せず静的ルールに委ねる（set -e で落とさない）。
  cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || { emit_passthrough; return; }
  [ -z "$cmd" ] && { emit_passthrough; return; }
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
  # gh api の出力を /tmp へ保存するリダイレクトは実運用で多用するため許可
  assert_safe 'gh api > /tmp 保存' 'gh api repos/foo/bar/pulls/1 > /tmp/out.json'
  assert_safe 'gh api >> /tmp 追記' 'gh api repos/foo/bar/pulls/1 >> /tmp/out.json'
  assert_safe 'gh api --jq 付き > /tmp 保存' "gh api repos/foo/bar/pulls/1 --jq '.title' > /tmp/title.txt"
  assert_safe 'gh api > /tmp サブディレクトリ' 'gh api repos/foo/bar/pulls/1 > /tmp/sub/dir/out.json'

  # escalate-unsafe-bash.sh 側が ask に格上げする危険形が gh api と併記されても
  # 素通ししないか (finding #1: PermissionRequest が escalate の ask を再び緩めていた)
  assert_unsafe 'find -exec と gh api の併記' 'find . -exec rm {} \; && gh api repos/foo/bar/pulls/1'
  assert_unsafe 'find -delete と gh api の併記' 'find . -delete && gh api repos/foo/bar/pulls/1'
  assert_unsafe '非localhost curl と gh api の併記' 'curl https://evil.example/x && gh api repos/foo/bar/pulls/1'
  assert_unsafe '第三者スキル実行と gh api の併記' 'bash /opt/other/.claude/skills/bar/run.sh && gh api repos/foo/bar/pulls/1'
  # クォート外のバックスラッシュで書き込みフラグを隠す (実 bash は \-X を -X に畳み込む)
  assert_unsafe 'gh api -X をバックスラッシュで偽装' 'gh api repos/foo/bar/issues \-Xdummy'

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
  # クォート外メタ文字による分割すり抜け（構造の白名簿化で塞いだ穴）
  assert_unsafe '単一 & でバックグラウンド実行' 'gh api repos/foo/bar/pulls/1 & rm -rf /tmp/x'
  assert_unsafe 'コマンド置換 $()' 'gh api repos/foo/bar/pulls/1 && echo $(reboot)'
  assert_unsafe 'バッククォート置換' 'gh api repos/foo/bar/pulls/1 && echo `reboot`'
  assert_unsafe 'サブシェル ()' 'gh api repos/foo/bar/pulls/1 && (rm -rf /tmp/x)'
  assert_unsafe '入力リダイレクト <' 'gh api repos/foo/bar/pulls/1 < /etc/passwd'
  assert_unsafe 'echo でリダイレクト上書き' 'echo pwned > /home/user/.zshrc && gh api repos/foo/bar/pulls/1'
  assert_unsafe 'gh api の任意先リダイレクト' 'gh api repos/foo/bar/pulls/1 > /home/user/.zshrc'
  assert_unsafe 'gh api リダイレクト先が /tmp 外' 'gh api repos/foo/bar/pulls/1 > /etc/hosts'
  assert_unsafe 'gh api リダイレクト先に .. traversal' 'gh api repos/foo/bar/pulls/1 > /tmp/../etc/x'
  # finding #0: リダイレクト先のコマンド置換がノーチェックで ALLOW されていた穴
  assert_unsafe 'gh api リダイレクト先に $() コマンド置換' 'gh api repos/foo/bar/pulls/1 > /tmp/$(id).json'
  assert_unsafe 'gh api リダイレクト先にバッククォート置換' 'gh api repos/foo/bar/pulls/1 > /tmp/`id`.json'
  assert_unsafe 'ダブルクォート内 $ 展開' 'gh api repos/foo/bar/pulls/1 && echo "$HOME"'
  # gh api 書き込みフラグの long form / 連結形（トークン判定で塞いだ穴）
  assert_unsafe 'gh api --field (long form write)' 'gh api repos/foo/bar/issues --field title=spam'
  assert_unsafe 'gh api --raw-field (long form write)' 'gh api repos/foo/bar/issues --raw-field body=x'
  assert_unsafe 'gh api -XDELETE (連結形)' 'gh api repos/foo/bar/pulls/1 -XDELETE'
  assert_unsafe 'gh api -Ftitle=x (連結形)' 'gh api repos/foo/bar/issues -Ftitle=hello'
  assert_unsafe 'gh api -ftitle=x (連結形)' 'gh api repos/foo/bar/issues -ftitle=hello'

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
