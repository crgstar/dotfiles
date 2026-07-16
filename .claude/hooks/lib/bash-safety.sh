# escalate-unsafe-bash.sh / segment-allow.sh 共有ライブラリ。
# 両フックが同じ危険形判定を参照することで、一方だけ強化してもう一方が
# 素通しする、という不整合を構造的に防ぐ。source 専用 (直接実行しない)。
#
# Why tokenize_quoted (read -ra ではなく):
#   `read -ra toks <<< "$cmd"` は IFS 空白分割のみでクォートを解釈しない。
#   `curl "https://evil.example/x" http://127.0.0.1:19556/y` のような
#   クォート付き引数は `"https://evil.example/x"` という1トークン (クォート
#   文字がリテラルに残る) として得られ、`http://*` パターンにマッチせず
#   検知漏れが起きる。ここでは演算子ではなく空白でのみ分割し、クォートを
#   剥がしたうえでトークン化する。
#
# dotfiles の skills ディレクトリをここ1箇所だけで導出する。escalate-unsafe-bash.sh /
# segment-allow.sh がそれぞれ同じ導出ロジックを持つと、ディレクトリ構成が変わった
# ときに片方だけ更新漏れで stale になりうる (このライブラリを共有する目的そのもの)。
# 呼び出し側で env 上書きしたい場合 (self-test 等) は DOTFILES_SKILLS_DIR を
# source 前にセットすればよい。
_bash_safety_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
DOTFILES_SKILLS_DIR="${DOTFILES_SKILLS_DIR:-${_bash_safety_self%/.claude/hooks/*}/.claude/skills}"

# クォート（' " `）を尊重しつつ空白で分割し、各トークンからクォート文字を
# 剥がして1行ずつ出力する(純粋関数)。
tokenize_quoted() {
  local cmd="$1"
  local i=0 len=${#cmd} ch next
  local in_single=0 in_double=0 in_backtick=0
  local tok=""

  _emit_tok() {
    [ -n "$tok" ] && printf '%s\n' "$tok"
    tok=""
  }

  while [ "$i" -lt "$len" ]; do
    ch="${cmd:$i:1}"
    if [ "$in_single" = 1 ]; then
      if [ "$ch" = "'" ]; then
        in_single=0
      else
        tok+="$ch"
      fi
    elif [ "$in_double" = 1 ]; then
      # why 先読み: bash のダブルクォート内でバックスラッシュが特殊な意味を持つのは
      # \" \\ \$ \` \<改行> の5つだけ (それ以外はバックスラッシュ自身も含めて
      # リテラル)。この5つを「バックスラッシュ + 次の1文字」でまとめて1文字として
      # 消費しないと、直前のバックスラッシュがトークンに残ったまま
      # (`\"http://evil` `\$FOO` のように) 実際の argv とズレて glob 判定が狂う
      if [ "$ch" = '\' ] && [ $((i+1)) -lt "$len" ]; then
        next="${cmd:$((i+1)):1}"
        case "$next" in
          '"'|'\'|'$'|'`') tok+="$next"; i=$((i+1)) ;;
          *) tok+="$ch" ;;
        esac
      elif [ "$ch" = '"' ]; then
        in_double=0
      else
        tok+="$ch"
      fi
    elif [ "$in_backtick" = 1 ]; then
      if [ "$ch" = '`' ]; then
        in_backtick=0
      else
        tok+="$ch"
      fi
    else
      case "$ch" in
        "'") in_single=1 ;;
        '"') in_double=1 ;;
        '`') in_backtick=1 ;;
        [[:space:]]) _emit_tok ;;
        # why クォート外のバックスラッシュも実際の bash はエスケープとして解釈し
        # 次の1文字だけを残す (`\http://evil` は argv では `http://evil` になる)。
        # ここを見落とすとトークン先頭に `\` が残り、has_dangerous_shape の
        # `http://*` / `-exec` / `-X*` 等の glob 照合をバックスラッシュ1個ですり抜ける。
        '\')
          if [ $((i+1)) -lt "$len" ]; then
            tok+="${cmd:$((i+1)):1}"
            i=$((i+1))
          fi
          ;;
        *) tok+="$ch" ;;
      esac
    fi
    i=$((i+1))
  done
  _emit_tok
}

# find/curl/第三者スキル実行の危険形を判定する(純粋関数)。
# 危険なら理由を stdout に出して 0、安全なら 1 を返す。
# $2 (省略可) に dotfiles skills ディレクトリの絶対パスを渡す。省略時は
# 本ライブラリが導出した DOTFILES_SKILLS_DIR を使う。空文字を明示すれば
# 第三者スキル判定そのものを省略できる。
has_dangerous_shape() {
  local cmd="$1" skills_dir="${2-$DOTFILES_SKILLS_DIR}"
  local has_find=0 has_curl=0 has_shell=0

  [[ "$cmd" =~ (^|[[:space:]])find[[:space:]] ]] && has_find=1
  [[ "$cmd" =~ (^|[[:space:]])curl[[:space:]] ]] && has_curl=1
  [ -n "$skills_dir" ] && [[ "$cmd" =~ (^|[[:space:]])(bash|sh)[[:space:]] ]] && has_shell=1

  # why 早期 return: このフックが最も頻繁に見る `gh api ...` のようなセグメントは
  # find/curl/bash のいずれも含まない。該当しない cmd にまで char-by-char の
  # tokenize_quoted を走らせるのは無駄で、呼び出し側 (segment-allow.sh の
  # gh api 書き込みフラグ判定) が直後にもう一度同じ cmd をトークン化するため、
  # 該当しない場合は二重にトークン化してしまっていた。
  if [ "$has_find" = 0 ] && [ "$has_curl" = 0 ] && [ "$has_shell" = 0 ]; then
    return 1
  fi

  local -a toks
  local t
  toks=()
  while IFS= read -r t; do toks+=("$t"); done < <(tokenize_quoted "$cmd")

  # 1. find の副作用フラグ
  if [ "$has_find" = 1 ]; then
    for t in "${toks[@]}"; do
      case "$t" in
        -exec|-execdir|-ok|-okdir|-delete)
          printf 'find に %s: 任意コマンド実行/削除の可能性' "$t"
          return 0
          ;;
      esac
    done
  fi

  # 2. curl の非 localhost 宛て
  if [ "$has_curl" = 1 ]; then
    for t in "${toks[@]}"; do
      case "$t" in
        http://127.0.0.1:19556|http://127.0.0.1:19556/*|https://127.0.0.1:19556|https://127.0.0.1:19556/*)
          : ;;
        http://*|https://*)
          printf 'curl の宛先が localhost:19556 以外: %s' "$t"
          return 0
          ;;
      esac
    done
  fi

  # 3. bash/sh が実行する第三者スキルスクリプト
  if [ "$has_shell" = 1 ]; then
    for t in "${toks[@]}"; do
      case "$t" in
        */.claude/skills/*)
          local real
          real="$(readlink -f "$t" 2>/dev/null || printf '%s' "$t")"
          case "$real" in
            "$skills_dir"/*) : ;;
            *)
              printf '第三者スキルスクリプトの実行: %s' "$t"
              return 0
              ;;
          esac
          ;;
      esac
    done
  fi

  return 1
}
