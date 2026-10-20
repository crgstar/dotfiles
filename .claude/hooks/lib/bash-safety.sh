# escalate-unsafe-bash.sh / segment-allow.sh 共有ライブラリ。
# 両フックが同じ危険形判定を参照することで、一方だけ強化してもう一方が
# 素通しする、という不整合を構造的に防ぐ。source 専用 (直接実行しない)。
#
# Why tokenize_quoted (read -ra ではなく):
#   `read -ra toks <<< "$cmd"` は IFS 空白分割のみでクォートを解釈しない。
#   `curl "https://evil.example/x" http://127.0.0.1:8080/y` のような
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
_bash_safety_root="${_bash_safety_self%/.claude/hooks/*}"
DOTFILES_SKILLS_DIR="${DOTFILES_SKILLS_DIR:-$_bash_safety_root/.claude/skills}"
# why 2 箇所を見る: dotfiles のスキルは配布範囲で置き場が分かれる
# (skills-global = 全リポへ配る / skills = このリポ専用)。実行時に現れるのは
# 配布先の `~/.claude/skills/<name>/...` だが、その symlink の実体は
# skills-global 側に落ちる。skills だけを正としていると、自前のスキル
# スクリプトが「第三者」と判定されて毎回 ask になる。
DOTFILES_SKILLS_GLOBAL_DIR="${DOTFILES_SKILLS_GLOBAL_DIR:-$_bash_safety_root/.claude/skills-global}"

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

# $1 が $2 ディレクトリ配下かを判定する(純粋関数)。$2 が空なら常に偽。
_is_under_dir() {
  [ -n "$2" ] || return 1
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

# find/curl/第三者スキル実行の危険形を判定する(純粋関数)。
# 危険なら理由を stdout に出して 0、安全なら 1 を返す。
# $2 / $3 (省略可) に dotfiles のスキルディレクトリ (project 用 / 配布用) の
# 絶対パスを渡す。省略時は本ライブラリが導出した DOTFILES_SKILLS_DIR /
# DOTFILES_SKILLS_GLOBAL_DIR を使う。$2 に空文字を明示すれば第三者スキル判定
# そのものを省略できる (両方まとめて落ちる)。
has_dangerous_shape() {
  local cmd="$1" skills_dir="${2-$DOTFILES_SKILLS_DIR}"
  local skills_global_dir="${3-$DOTFILES_SKILLS_GLOBAL_DIR}"
  [ -n "$skills_dir" ] || skills_global_dir=""
  local has_find=0 has_curl=0 has_shell=0

  [[ "$cmd" =~ (^|[[:space:]])find[[:space:]] ]] && has_find=1
  [[ "$cmd" =~ (^|[[:space:]])curl[[:space:]] ]] && has_curl=1
  [ -n "$skills_dir" ] && [[ "$cmd" =~ (^|[[:space:]])(bash|sh)[[:space:]] ]] && has_shell=1

  # git はトークン化せずに判定するので、下の早期 return より前に済ませる
  # (理由は _git_dangerous_opt の説明)
  if _git_dangerous_opt "$cmd"; then
    return 0
  fi

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
        http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|https://127.0.0.1|https://127.0.0.1/*|https://127.0.0.1:*)
          : ;;
        http://*|https://*)
          printf 'curl の宛先が 127.0.0.1 以外: %s' "$t"
          return 0
          ;;
      esac
    done
  fi

  # 3. bash/sh が実行する第三者スキルスクリプト
  if [ "$has_shell" = 1 ]; then
    # why cd の有無を先に見る: 相対パスの readlink -f は「この hook プロセスの cwd」
    # で解決するが、`cd <dir> && bash ./.claude/skills/<name>/<file>` のように同一
    # コマンド内で cwd が動くと、解決先と実際に実行されるファイルが別物になる。
    # dotfiles 側に同名パスが実在すると第三者スクリプトが「dotfiles 製」と誤判定
    # されて素通しする (`Bash(cd *)` と `Bash(bash */.claude/skills/*)` が両方
    # 静的 allow なので、確認ダイアログも出ない)。cwd が動くコマンドでは実体を
    # 解決できないものとして ask に倒す。
    local has_cd=0 tt
    for tt in "${toks[@]}"; do
      if [ "$tt" = 'cd' ]; then has_cd=1; break; fi
    done
    for t in "${toks[@]}"; do
      case "$t" in
        */.claude/skills/*)
          local real
          if [ "$has_cd" = 1 ] && [ "${t#/}" = "$t" ]; then
            printf 'cd を含むコマンド内の相対パススキル実行 (実体を解決できない): %s' "$t"
            return 0
          fi
          real="$(readlink -f "$t" 2>/dev/null || printf '%s' "$t")"
          if ! _is_under_dir "$real" "$skills_dir" \
             && ! _is_under_dir "$real" "$skills_global_dir"; then
            printf '第三者スキルスクリプトの実行: %s' "$t"
            return 0
          fi
          ;;
      esac
    done
  fi

  return 1
}

# git の書き込み・コマンド実行オプションを含むなら理由を stdout に出して 0、
# 含まなければ 1 を返す(純粋関数)。
#
# why トークン化しない: tokenize_quoted は 1 文字ずつ回すので、git に触れる
#   大きなヒアドキュメント (2.5 万字) で 9 秒かかった。この hook は全 Bash 呼び出しで
#   走る。代わりにクォートとバックスラッシュを消した文字列から `--名前` を拾う。
#   bash は `--out""put` / `-\-output` / `g\it` を連結して元の語にするので、
#   消してから探せば同じ語が現れる。クォートの中身 (コミットメッセージ等) まで
#   拾うので確認が増える側に倒れる。
# why 1 本の正規表現で当てる: `--名前` を 1 つずつ拾って残りを切り詰めるループは、
#   切り詰めのたびに残り全体を複製するので、オプションの多いヒアドキュメントで
#   出現数 × 長さの時間がかかる (7.6 万字・6000 個で 3 秒台)。
# why git の語境界を見ない: `\git` や `xargs git` のように git の前が空白とは限らない。
# why 展開の形も見る: `--{output=x,stat}` / `-{-,-}output=x` / `--$X` は、
#   文字列に `--output` が現れないまま bash の展開で `--output` になる。
#   ダッシュとブレース展開 (`{` と `,` / `..` が同じ語にある) や `$` が隣り合う形は
#   中身を問わず確認に回す。`@{-1}` / `xargs -I{}` はカンマが無く展開されないので通す。
#   `{-` の後ろは `..` を見ない: 連番展開がダッシュを出すのは負の整数だけで、
#   オプション名の文字は作れない。見ると `@{-1}..HEAD` まで確認に落ちる。
# 限界: `$'\055\055output'` (ANSI-C クォート) と、語頭の変数で `-` を作る形
#   (`X=-; git diff $X-output=f`) は拾えない。tokenize_quoted も展開を解釈しないので、
#   トークン方式にしても変わらない。
_git_dangerous_opt() {
  local cmd="$1" s
  s="${cmd//[\"\'\\\`]/}"
  [[ "$s" == *git* ]] || return 1
  if [[ "$s" =~ --($_GIT_DANGEROUS_OPT_ALT)([^A-Za-z-]|$) ]]; then
    printf 'git の危険なオプション: --%s (ファイル書き込み / コマンド実行の可能性)' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$s" =~ $_GIT_OPT_EXPANSION_RE ]]; then
    printf 'git のオプションをシェル展開で組み立てている可能性: %s' "${BASH_REMATCH[0]}"
    return 0
  fi
  return 1
}

# 危険な git オプション名 (先頭の -- を除く)。
# - output: log / show / diff / blame / archive が任意パスへ書き出す。.git/config を
#   書き換えれば次の git diff / status で任意コマンドが動く (Pillar Security の GitPwned)
# - ext-diff: リポジトリ設定の diff.external を起動する
# - upload-pack / receive-pack / exec / exec-path: 指定したコマンドを git が起動する
# - open-files-in-pager: git grep -O の long form。pager としてコマンドを起動する
#
# why 前方一致 (2 文字以上の前方部分を全部並べる): git の parse-options は一意に決まる
#   省略形を受け付ける (`git fetch --upload-p=<cmd>` で実行されることを実測)。diff 系の
#   --output は省略を受けないが、サブコマンドごとの違いを持たずに済むよう一律に見る。
#   1 文字 (`--o`) は曖昧で git 側も受けないので対象外。
_GIT_DANGEROUS_OPT_ALT=''
for _d in output ext-diff upload-pack receive-pack exec exec-path open-files-in-pager; do
  for ((_i = 2; _i <= ${#_d}; _i++)); do
    _GIT_DANGEROUS_OPT_ALT+="${_GIT_DANGEROUS_OPT_ALT:+|}${_d:0:_i}"
  done
done
unset _d _i
_GIT_OPT_EXPANSION_RE='-[A-Za-z-]*\{[^[:space:]]*(,|\.\.)|\{-[^[:space:]]*,|\{[^[:space:]]*,-|-[A-Za-z-]*\$'

# クォート（' " `）とクォート外のエスケープを尊重して、コマンド文字列を
# 「直前の区切り種別 + コマンド」の並びに分解する(純粋関数)。
# 各レコードを "<sep>\t<command>" として NUL 区切りで出力する。
#   first : 先頭要素 (直前に区切りが無い)
#   pipe  : 単独の | で直前と繋がっている = 直前の標準出力が流れ込む
#   other : ; && || & 改行 で区切られている = 出力は流れない
#
# Why segment-allow.sh の split_segments と別に持つ:
#   あちらは「各セグメントが安全か」だけを見るので区切りの種類を捨てている。
#   「直前のコマンドの出力を受け取っているか」を判定するには pipe と
#   それ以外を区別する必要があり、戻り値の形が違う。既に動いている
#   split_segments の出力契約を変えると全呼び出し側の回帰確認が要るため、
#   用途の違う関数として並置する。
#
# Why NUL 区切り: 要素自身が改行を含みうる (`python3 -c "<改行>...<改行>"`)。
#   改行区切りだと呼び出し側の read が 1 要素を割ってしまう。
split_with_separator() {
  local cmd="$1"
  local i=0 len=${#cmd} ch next
  local in_single=0 in_double=0 in_backtick=0
  local seg="" sep="first" pending=""

  _emit_rec() {
    local t
    t="${seg#"${seg%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    if [ -n "$t" ]; then
      printf '%s\t%s\0' "$sep" "$t"
      sep="$pending"
    fi
    # why 空要素では sep を進めない: `a ;<改行> b` のように区切りが連続すると
    # 空セグメントが挟まる。そこで sep を消費すると、実際には | で繋がって
    # いない b が pipe 扱いになりうる。
    seg=""
  }

  while [ "$i" -lt "$len" ]; do
    ch="${cmd:$i:1}"
    next=""
    [ $((i+1)) -lt "$len" ] && next="${cmd:$((i+1)):1}"

    if [ "$in_single" = 1 ]; then
      seg+="$ch"; [ "$ch" = "'" ] && in_single=0
    elif [ "$in_double" = 1 ]; then
      seg+="$ch"
      if [ "$ch" = '\' ] && [ -n "$next" ]; then
        seg+="$next"; i=$((i+1))
      elif [ "$ch" = '"' ]; then
        in_double=0
      fi
    elif [ "$in_backtick" = 1 ]; then
      seg+="$ch"; [ "$ch" = '`' ] && in_backtick=0
    else
      case "$ch" in
        "'") in_single=1; seg+="$ch" ;;
        '"') in_double=1; seg+="$ch" ;;
        '`') in_backtick=1; seg+="$ch" ;;
        # why エスケープを 1 文字として持ち越す: `\|` はパイプではなくリテラル。
        # 飛ばさないと区切りと誤読して、実際には 1 コマンドだったものを
        # 2 要素に割ってしまう。
        '\')
          seg+="$ch"
          if [ -n "$next" ]; then seg+="$next"; i=$((i+1)); fi
          ;;
        '|')
          if [ "$next" = '|' ]; then
            pending="other"; _emit_rec; i=$((i+1))
          else
            pending="pipe"; _emit_rec
          fi
          ;;
        '&')
          if [ "$next" = '&' ]; then
            pending="other"; _emit_rec; i=$((i+1))
          elif [ "${seg: -1}" = '>' ] || [ "${seg: -1}" = '<' ]; then
            # why fd 複製 (`2>&1` / `<&3`) は区切りではない: 直前が > / < のときの
            # & はリダイレクト先の指定なので、ここで割るとコマンドが切れて
            # 「出力の出どころ」を見失う (gh api ... 2>&1 | ... が拾えなくなる)。
            seg+="$ch"
          else
            pending="other"; _emit_rec
          fi
          ;;
        ';'|$'\n')
          pending="other"; _emit_rec
          ;;
        *) seg+="$ch" ;;
      esac
    fi
    i=$((i+1))
  done
  pending="other"
  _emit_rec
}

# ---- scratchpad 配下限定の rm 判定 (scratchpad-rm-allow.sh / rm-to-trash.sh 共有) ----

# rm コマンドに許す文字集合(白名簿)。ここに無い文字が 1 つでもあれば判定せず ask に委ねる。
# why 白名簿: `&& $() ` ` ; | < > ~ ' "` 改行 をすべてこの 1 本で落とせる。
# クォートも展開も複合コマンドも許さないので、後段は IFS 分割だけで実 argv と一致し、
# segment-allow.sh のような tokenize/split の再実装が不要になる。
SCRATCHPAD_RM_SAFE_CHARS='^[A-Za-z0-9_./*?,+=:@ -]+$'

# 純粋判定: cmd が「$session_id の scratchpad 配下限定の rm」なら 0、それ以外は 1。
# $3 (省略可) に uid を渡せる (self-test 用。省略時は実行ユーザの uid)。
rm_confined_to_scratchpad() {
  local cmd="$1" session_id="$2" uid="${3-$(id -u)}"

  # session_id はそのまま正規表現に埋めるので、メタ文字が混じらない形だけ受ける
  [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  [[ "$cmd" =~ $SCRATCHPAD_RM_SAFE_CHARS ]] || return 1

  local -a toks=()
  read -ra toks <<< "$cmd"
  [ "${#toks[@]}" -ge 2 ] || return 1
  # `command rm` / `/bin/rm` / sudo 経由は意図が読めないので素の rm だけ
  [ "${toks[0]}" = 'rm' ] || return 1

  # 末尾を `/[^/].*` にして scratchpad ルート自体の削除を除外する
  # (ルートが消えるとそのセッションの以降の一時ファイル書き込みが軒並み失敗する)
  local re="^/private/tmp/claude-${uid}/[^/]+/${session_id}/scratchpad/[^/].*"
  local operands=0 end_of_flags=0 t
  for t in "${toks[@]:1}"; do
    if [ "$end_of_flags" = 0 ]; then
      case "$t" in
        --) end_of_flags=1; continue ;;
        # 連結短縮フラグのみ許可。BSD rm に long option は無く、未知フラグは
        # 意図を読めないので ask に倒す
        -*) [[ "$t" =~ ^-[rRfvdi]+$ ]] || return 1; continue ;;
      esac
    fi
    # ドットで始まるパス成分を一律拒否する。
    # why 「.. だけ」では足りない: 白名簿は `.` `?` `*` を通すので、リテラルの `..` が
    # 無くても `scratchpad/.?/.?/x` のようなパターンがシェルの展開時に `../../x` になり、
    # prefix 照合をすり抜けて scratchpad の外を消せる (`.` 始まりの成分は `?`/`*` では
    # マッチしないので、`/.` を封じれば展開後も prefix の内側に閉じる)。
    # bash 5.2+ の globskipdots や zsh は `.`/`..` を展開対象から外すが、
    # /bin/bash 3.2 (macOS 同梱) では実際に展開されるためシェル任せにしない。
    case "$t" in
      .*|*/.*) return 1 ;;
    esac
    [[ "$t" =~ $re ]] || return 1
    operands=$((operands + 1))
  done

  [ "$operands" -ge 1 ]
}
