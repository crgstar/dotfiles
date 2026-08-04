#!/bin/bash
# 無人 reflect ドライバ (launchd: com.crgstar.reflect が夜間起動)。
# queue.jsonl を 1 件ずつ直列処理し、ヘッドレス claude に /reflect --auto を
# 実行させ、stdout のマーカーをパースして memory 書き込み・提案保存・朝サマリ追記を行う。
#
# 権限設計 (outbox パターン): ヘッドレスの claude には書き込み権限を一切与えず、
# 結果はマーカー付き stdout だけで受け取る。ファイル保存はすべてこのスクリプト
# (claude の外) が担う。悪性 transcript がモデルを操っても
# 書き込み先はここに固定されていて変えられない。
#
# 環境変数 (すべて検証用の上書き口。通常は未設定でよい):
#   REFLECT_STATE_DIR  状態ディレクトリ (default: ~/.local/state/reflect)
#   REFLECT_CLAUDE_BIN claude 実体 (default: ~/.local/bin/claude)
#   REFLECT_INBOX      朝サマリの追記先 (default: ~/dotfiles/.local/reflect-inbox.md)
#   REFLECT_MODEL      ヘッドレスのモデル (default: sonnet)
#   REFLECT_TIMEOUT    claude 1 件あたりの上限秒 (default: 3600)
#   REFLECT_MIN_GROWTH 差分再処理とみなす最小成長行数 (default: 50。hook と共有)
#   REFLECT_DRY_RUN    1 なら sanitize監査・再提案のclaude呼び出し・
#                       実書き込みをせずログに出すだけ
#   REFLECT_SANITIZE_TIMEOUT   ③ (dotfiles宛) 提案の sanitize 監査 1 件あたりの上限秒
#                       (default: 300)
#   REFLECT_REGENERATE_TIMEOUT 再提案 (regenerate) 1 件あたりの上限秒
#                       (default: REFLECT_TIMEOUT と同じ)
#   REFLECT_CWD        ヘッドレス claude の起動 cwd (必須。target リポジトリを
#                       read-only additionalDirectories 越しに直接読ませるための
#                       専用プロジェクトのパスを指定する。未設定なら
#                       ~/.config/reflect/env.local を source して補う)
#
# --regenerate-only モード: 通常の queue (transcript) 処理をスキップし、
# pending の status: regenerate だけを拾って作り直す (設計書 決定13a)。
# lock が取れない場合は stderr にメッセージを出して exit 75 (EX_TEMPFAIL) で
# 終了する (呼び出し元が「実行中」を判別できるようにするため)。

set -u

STATE_DIR="${REFLECT_STATE_DIR:-$HOME/.local/state/reflect}"
QUEUE="$STATE_DIR/queue.jsonl"
PROCESSING="$STATE_DIR/processing.jsonl"
DONE="$STATE_DIR/done"
HOLD="$STATE_DIR/hold"
ATTEMPTS="$STATE_DIR/attempts"
LOG="$STATE_DIR/run.log"
INBOX="${REFLECT_INBOX:-$HOME/dotfiles/.local/reflect-inbox.md}"
CLAUDE_BIN="${REFLECT_CLAUDE_BIN:-$HOME/.local/bin/claude}"
MODEL="${REFLECT_MODEL:-sonnet}"
TIMEOUT_SEC="${REFLECT_TIMEOUT:-3600}"
MIN_GROWTH="${REFLECT_MIN_GROWTH:-50}"
SANITIZE_TIMEOUT_SEC="${REFLECT_SANITIZE_TIMEOUT:-300}"
REGEN_TIMEOUT_SEC="${REFLECT_REGENERATE_TIMEOUT:-$TIMEOUT_SEC}"
# why 専用 cwd かつ必須: ヘッドレス claude の cwd を dotfiles にすると additionalDirectories
# を広げない限り target リポジトリ本体を読めない。read-only な additionalDirectories
# (target を含む階層, ~/dotfiles) だけを持つ専用プロジェクトを cwd にすることで、通常の
# dotfiles 作業セッションの権限には影響を与えずに target を直接読めるようにする
# (SKILL.md 群は ~/.claude/skills/* からのシンボリックリンク経由で解決されるため、
# cwd を dotfiles から外しても読める)。デフォルト値は環境固有パスになるため持たせず、
# 未設定なら env.local を読み、それでも無ければ打ち切る。
# why fallback source: launchd 経由は plist が env.local を source してから起動するが、
# 提案ビューアの「再提案の今すぐ実行」ボタンや手動実行はこのスクリプトを直接起動する。
# 環境固有値の定義を env.local 1 箇所に保ったまま、どの経路でも同じ値が入るようにする
if [ -z "${REFLECT_CWD:-}" ] && [ -f "$HOME/.config/reflect/env.local" ]; then
  . "$HOME/.config/reflect/env.local"
fi
: "${REFLECT_CWD:?REFLECT_CWD を設定してください (read-only additionalDirectories で target を読める専用プロジェクトのパス。~/.config/reflect/env.local に export を書いても可)}"
# why 単一定義: extract_block と split_blocks (memory/proposal 共通) の状態機械は
# 同じタグ集合を見ないと「片方だけが開始マーカーを認識する」ずれが起き、引用と
# 実ブロックの判定が関数間で食い違う。タグ追加時はここだけ変える
REFLECT_TAGS='SUMMARY|MEMORY|PROPOSAL'
# why 2 回で打ち切り: 同じ transcript で毎晩失敗し続けると token を無限に燃やす。
# 2 回失敗した entry は hold に落として人間判断に回す
MAX_ATTEMPTS=2

# why PATH を明示: launchd 起動時の PATH は /usr/bin:/bin 系の最小構成で、
# gh (homebrew) や claude (~/.local/bin) が見えない
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin"

mkdir -p "$STATE_DIR" "$HOLD" "$(dirname "$INBOX")"

# why stderr 出力: 一部の関数は $(...) で stdout を捕まえられるので、
# stdout に log を混ぜると戻り値に混入する
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

trim() { # 先頭・末尾の空白を除いた値を stdout に返す (ヘッダ値の正規化・純粋関数)
  # why 単一定義: memory/proposal のヘッダ値正規化を 1 箇所に集約する。
  # 「先頭 1 つだけ剥がす」実装だと 'title:  ' のような空白のみ値が非空判定を
  # すり抜け、末尾空白付き target が存在しないパスとして保存される (both bugs)。
  # モデル出力に空白ゆれは付きものなので、両端の空白をまとめて落とす
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # 先頭の空白
  s="${s%"${s##*[![:space:]]}"}"   # 末尾の空白
  printf '%s' "$s"
}

extract_block() { # $1=タグ名 stdin=claude 出力。マーカー行の間だけを出す
  # why 状態機械: ブロック本文に引用された別タグの開始マーカー (SKILL.md の
  # 例示を含む transcript 等) を新規ブロック開始として拾うと、ブロック本文の
  # 一部を別ブロックとして誤処理しうる。「最初に開いたブロックが閉じるまで、
  # 他の開始マーカーは本文扱い」にして構造を一意にする
  awk -v tag="$1" -v tags="$REFLECT_TAGS" '
    inblk == "" && $0 ~ ("^<<<REFLECT-(" tags ")$") { inblk = substr($0, 4); next }
    inblk != "" && $0 == inblk ">>>" { inblk = ""; next }
    inblk == "REFLECT-" tag { print }
  '
}

split_blocks() { # $1=タグ名(MEMORY|PROPOSAL) $2=ファイル名prefix $3=outdir stdin=claude 出力
  # why extract_block とは別関数: MEMORY/PROPOSAL は同一出力に複数件来る。タグ内容を
  # 連結して素通しする extract_block では 1 件目と 2 件目が結合されてしまうため、
  # open ごとに出力先ファイルを切り替える。状態機械の性質 (最初に開いたブロックが
  # 閉じるまで他の開始マーカーは本文扱い) は extract_block と同じにする。
  # why 汎用化: MEMORY 用と PROPOSAL 用で同じ状態機械を二重保守しない
  local tag="$1" prefix="$2" outdir="$3" full_tag
  full_tag="REFLECT-$tag"
  awk -v full_tag="$full_tag" -v prefix="$prefix" -v outdir="$outdir" -v tags="$REFLECT_TAGS" '
    inblk == "" && $0 ~ ("^<<<REFLECT-(" tags ")$") {
      cur = substr($0, 4)
      inblk = cur
      if (cur == full_tag) {
        n++; outfile = outdir "/" prefix "-" n
        # why 空ファイルの実体化: 本文 0 行のブロックは print が一度も走らず
        # ファイル自体が生まれない = hold にも log にも痕跡が残らず消える。
        # 空でも実体を作れば process_*_block の検証で hold に落ちる
        printf "" > outfile
      }
      next
    }
    inblk != "" && $0 == inblk ">>>" { inblk = ""; next }
    inblk == full_tag { print > outfile }
  '
}

split_memory_blocks() { # $1=outdir stdin=claude 出力。REFLECT-MEMORY を 1 件 1 ファイル (mem-N) に分割
  split_blocks MEMORY mem "$1"
}

split_proposal_blocks() { # $1=outdir stdin=claude 出力。REFLECT-PROPOSAL を 1 件 1 ファイル (prop-N) に分割
  split_blocks PROPOSAL prop "$1"
}

project_segment_for_cwd() { # $1=cwd(絶対パス)。~/.claude/projects/ 配下のプロジェクト
  # ディレクトリ名は cwd の "/" と "." をどちらも "-" に置き換えたもの
  # (実際の ~/.claude/projects/ 配下のディレクトリ名で確認済み。"/" だけ置換すると
  # cwd に "." を含むプロジェクト (~/.claude/projects/ 配下自体を cwd にするケース等)
  # で誤って不一致判定になり、正当な書き込みまで hold に落ちてしまう)。
  # why 限定的な検証: Claude Code の公式ドキュメントにこのエンコード規則の記載は
  # 見つからず、手元の実ディレクトリ名からの逆算で確認した範囲 ("/" "." のみ) に
  # 留まる。スペースや非ASCII文字を含む cwd での実際のエンコードは未検証。
  # 一致しない場合は memory_path_ok が cross-project 不一致として fail-safe に
  # hold へ落とす (書き込み自体は防げるが、正当な書き込みが誤って止まりうる)。
  # memory_path_ok の cross-project チェックで「この transcript が書いていい
  # プロジェクト名」を求めるために使う(純粋関数)
  printf '%s' "$1" | tr './' '--'
}

memory_path_ok() { # $1=path $2=expected_seg(省略可)。許可条件をすべて満たすときだけ 0 (純粋関数)
  # why $2: file の 1 セグメント目 (プロジェクトディレクトリ名) が、この
  # transcript 自身の cwd から導けるプロジェクト名と一致するかを見る。無いと
  # transcript A の処理中に (ハルシネーションや prompt injection で) 別プロジェクト
  # B の MEMORY.md を書き換えられてしまう。空なら従来通りチェックしない
  local path="$1" expected_seg="${2:-}" root rest seg1 rest2 fname
  root="${REFLECT_MEMORY_ROOT:-$HOME/.claude/projects}"

  case "$path" in
    *//*) return 1 ;; # 空セグメント
  esac
  case "$path" in
    */../*|*/..|../*|..) return 1 ;; # .. セグメント
  esac
  case "$path" in
    */./*|*/.|./*|.) return 1 ;; # . セグメント (prefix 直下等への正規化ずらしを防ぐ)
  esac
  case "$path" in
    "$root"/*) ;;
    *) return 1 ;; # 許可 prefix 外
  esac

  rest="${path#"$root"/}"          # <seg1>/memory/<file>.md
  seg1="${rest%%/*}"
  [ -n "$seg1" ] || return 1
  [ "$seg1" != "$rest" ] || return 1 # memory/ 以下が存在しない (1 セグメントで終わっている)
  if [ -n "$expected_seg" ] && [ "$seg1" != "$expected_seg" ]; then
    return 1 # この transcript の cwd から導けるプロジェクトと不一致
  fi

  rest2="${rest#*/}"               # memory/<file>.md
  case "$rest2" in
    memory/*) ;;
    *) return 1 ;;
  esac
  fname="${rest2#memory/}"
  case "$fname" in
    */*) return 1 ;;               # memory/ 配下にサブディレクトリ
    *.md) ;;
    *) return 1 ;;
  esac
  return 0
}

process_memory_block() { # $1=blockfile $2=sid $3=n $4=cwd(省略可)。結果行を stdout に 1 行 (成否は戻り値)
  local blockfile="$1" sid="$2" n="$3" cwd="${4:-}"
  local mode="" file="" index="" fname="" header_done=0 line body_file fail=""
  local expected_seg=""
  [ -n "$cwd" ] && expected_seg="$(project_segment_for_cwd "$cwd")"
  body_file=$(mktemp "${TMPDIR:-/tmp/}reflect-mem-body-XXXXXX")

  # why ヘッダ読取: mode/file/index は先頭の "---" 行までのメタデータ。
  # それ以降は memory ファイル本文 (frontmatter 含む) なので一字一句そのまま
  # body_file に落とす (自身も "---" を含みうるが、以降は全部本文として扱う)
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$header_done" -eq 1 ]; then
      printf '%s\n' "$line" >>"$body_file"
      continue
    fi
    if [ "$line" = "---" ]; then
      header_done=1
      continue
    fi
    case "$line" in
      mode:*) mode=$(trim "${line#mode:}") ;;
      file:*) file=$(trim "${line#file:}") ;;
      index:*) index=$(trim "${line#index:}") ;;
    esac
  done <"$blockfile"

  case "$mode" in
    create|update) ;;
    *) fail="不正な mode: ${mode:-<空>}" ;;
  esac
  # 本文空 = "---" 区切り欠落かモデルの返却不正。空の memory を確定させない
  if [ -z "$fail" ] && [ ! -s "$body_file" ]; then
    fail="本文が空 (--- 区切り欠落の疑い)"
  fi
  [ -n "$fail" ] || memory_path_ok "$file" "$expected_seg" || fail="許可パス外 or プロジェクト不一致の file: $file"
  # create は index 必須 (MEMORY.md 未掲載のオーファン memory はどこからも辿れない)
  if [ -z "$fail" ] && [ "$mode" = "create" ] && [ -z "$index" ]; then
    fail="create だが index が空"
  fi
  # index が file と別名を指すと重複判定 grep が永遠に効かず、リンク切れも黙認される
  if [ -z "$fail" ] && [ -n "$index" ]; then
    fname=$(basename "$file")
    case "$index" in
      *"]($fname)"*) ;;
      *) fail="index が file 名と不一致: $index" ;;
    esac
  fi
  if [ -z "$fail" ] && [ "$mode" = "create" ] && [ -e "$file" ]; then
    fail="create だが既存ファイルと衝突: $file" # モデルの重複見落としを黙って上書きしない
  fi
  if [ -z "$fail" ] && [ "$mode" = "update" ] && [ ! -e "$file" ]; then
    fail="update だが対象ファイルが未存在: $file"
  fi

  if [ -n "$fail" ]; then
    rm -f "$body_file"
    cp "$blockfile" "$HOLD/$sid-memory-$n.txt"
    log "$sid: memory ブロック $n 失敗 ($fail)"
    echo "memory 失敗: hold/$sid-memory-$n.txt"
    return 1
  fi

  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    rm -f "$body_file"
    log "DRY_RUN: memory 書き込みをスキップ ($file, $mode)"
    echo "memory 書き込み: $file ($mode, dry-run)"
    return 0
  fi

  local memdir tmp="" memmd
  memdir=$(dirname "$file")
  # why 失敗検出: mkdir/mktemp/cat/mv のどれが落ちても素通しすると、書けていない
  # memory を「書き込み成功」と報告して朝の運用が気づけない (権限不足等で実証済み)。
  # why tmp 経由の mv: 書き込み途中でクラッシュしても半端な内容を確定させない
  if ! mkdir -p "$memdir" \
    || ! tmp=$(mktemp "$memdir/.reflect-mem-XXXXXX") \
    || ! cat "$body_file" >"$tmp" \
    || ! mv "$tmp" "$file"; then
    [ -n "$tmp" ] && rm -f "$tmp"
    rm -f "$body_file"
    cp "$blockfile" "$HOLD/$sid-memory-$n.txt"
    log "$sid: memory ブロック $n 失敗 (書き込みエラー: $file)"
    echo "memory 失敗: hold/$sid-memory-$n.txt"
    return 1
  fi
  rm -f "$body_file"

  if [ -n "$index" ]; then
    memmd="$memdir/MEMORY.md"
    if [ ! -f "$memmd" ] || ! grep -qF "]($fname)" "$memmd"; then
      if ! printf '%s\n' "$index" >>"$memmd"; then
        # memory 本体は書けているので失敗にはしない (index は hold より log と
        # inbox 行から人間が復旧する方が速い)
        log "$sid: MEMORY.md への index 追記失敗 ($memmd)"
        echo "memory 書き込み: $file ($mode, index 追記失敗)"
        return 0
      fi
    fi
  fi

  log "$sid: memory 書き込み成功 -> $file ($mode)"
  echo "memory 書き込み: $file ($mode)"
  return 0
}

derive_repo() { # $1=絶対パス。表示・分類用のリポジトリ名を返す (純粋関数)
  # why 厳密さより単純さ: 提案ビューアのフィルタ用ラベルなので、パスから
  # 機械的に導ける範囲で十分。$HOME は変数参照にして self-test から
  # REFLECT_HOME で差し替え可能にする (memory_path_ok の root と同じ流儀)
  local path="$1" home="${REFLECT_HOME:-$HOME}"
  case "$path" in
    "$home"/dotfiles/*) echo "dotfiles"; return ;;
  esac
  case "$path" in
    "$home"/projects/*/*)
      local rest="${path#"$home"/projects/}"
      echo "${rest%%/*}"
      return
      ;;
  esac
  echo "other"
}

frontmatter_value() { # $1=提案/memoryファイル $2=キー名。frontmatter (先頭の "---" ペア間) の
  # "キー: 値" を trim して返す (純粋関数)。決定12 の sanitize スタンプや regenerate の
  # 元提案読み取りで、body を毎回シェルでパースし直さず済ませるための共通ヘルパー
  local file="$1" key="$2"
  awk -v key="^${key}:" '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm && $0 ~ key { sub(key " *", ""); print; exit }
  ' "$file"
}

target_is_public_dotfiles() { # $1=絶対パス。$HOME/dotfiles/ 配下 (= ③ PUBLIC リポ宛) なら 0
  # why REFLECT_HOME 経由: derive_repo と同じ流儀で self-test から差し替え可能にする
  # why symlink 解決: target が ~/.claude/CLAUDE.md → ~/dotfiles/.claude/CLAUDE.merged.md の
  # ような symlink の場合、文字列のままでは dotfiles 配下と判定できず sanitize がスキップされる。
  # 消費側の提案ビューアは realpath で実体を解決してから ③ 判定するため、ここでも実在すれば
  # symlink を解決してから揃える (実在しない場合は解決できないため文字列のまま判定=フォールバック)。
  # readlink -f は macOS 標準 (BSD readlink, Darwin) でも Linux (GNU coreutils) でも
  # 動作するため、スクリプト既存の依存範囲を超えない
  local path="$1" home="${REFLECT_HOME:-$HOME}" resolved
  # why path 実在時のみ解決: 実在しないパス (self-test の非symlinkケース等) は
  # readlink -f できないため従来どおり文字列比較のフォールバックにする。
  # why 実在時は home 側も解決: macOS の $TMPDIR (self-test 用) 自体が
  # /var -> /private/var の symlink であることがあり、path 側だけ解決すると
  # 比較対象がずれて誤判定になる (home は非解決の生文字列のまま残す必要がある)
  if [ -e "$path" ] && resolved=$(readlink -f "$path" 2>/dev/null) && [ -n "$resolved" ]; then
    path="$resolved"
    if [ -e "$home" ] && resolved=$(readlink -f "$home" 2>/dev/null) && [ -n "$resolved" ]; then
      home="$resolved"
    fi
  fi
  case "$path" in
    "$home"/dotfiles/*) return 0 ;;
    *) return 1 ;;
  esac
}

canonicalize_target() { # $1=target値。stdout=正規化後の値 (純粋関数)
  # why このマッピング: ユーザグローバル CLAUDE.md についての教訓を提案するとき、
  # ヘッドレス LLM は "$HOME/.claude/CLAUDE.md" を target に選びがちだが、これは
  # setup.sh が「dotfiles/.claude/CLAUDE.md (共通・公開) + .claude/CLAUDE.local/<環境>.md」
  # から再生成する gitignore 済みファイル ($HOME/dotfiles/.claude/CLAUDE.merged.md への
  # symlink) の実体。ここを target にした提案は消費側の提案ビューアで構造的に採用不能
  # (HEAD に存在しない・git add 不可・setup.sh 再実行で上書きされる) なため、
  # 生成元である $HOME/dotfiles/.claude/CLAUDE.md に決定的に書き換える。
  # 他の値はすべて素通し (それ以外の生成物パスは今のところ未確認のため、既知の
  # 1 パターンだけを狭く救う)
  local value="$1" home="${REFLECT_HOME:-$HOME}"
  if [ "$value" = "$home/.claude/CLAUDE.md" ]; then
    printf '%s' "$home/dotfiles/.claude/CLAUDE.md"
  else
    printf '%s' "$value"
  fi
}

insert_frontmatter_line_after() { # $1=file $2=anchor行の先頭一致正規表現 $3=挿入する行テキスト。
  # anchor に最初にマッチした行の直後に $3 を挿入する (原子的。他の行は変更しない)。
  # why 汎用化: insert_sanitized_line (created: の直後) と insert_attempts_line
  # (sanitized: または created: の直後) が同じ「1行挿入」の状態機械を二重保守しない
  local file="$1" anchor="$2" line="$3" tmp
  tmp=$(mktemp "$(dirname "$file")/.reflect-fmline-XXXXXX") || return 1
  if ! awk -v anchor="$anchor" -v ln="$line" '
    { print }
    $0 ~ anchor && !done { print ln; done = 1 }
  ' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

insert_sanitized_line() { # $1=提案ファイル $2=値 ("pass" または "flagged <理由>")。
  # created: 行の直後に "sanitized: <値>" を挿入する
  insert_frontmatter_line_after "$1" '^created:' "sanitized: $2"
}

insert_attempts_line() { # $1=提案ファイル $2=実施した監査回数(整数)。
  # sanitized: 行があればその直後、なければ created: 行の直後に
  # "sanitize_attempts: <値>" を挿入する。消費側の提案ビューアが「何回やり直して
  # 不合格だったか」を表示するための契約キーで、監査失敗 (マーカー欠落) で
  # sanitized: 行自体が無いケースでも attempts だけは分かる範囲でスタンプする
  local file="$1" value="$2" anchor='^created:'
  grep -q '^sanitized:' "$file" && anchor='^sanitized:'
  insert_frontmatter_line_after "$file" "$anchor" "sanitize_attempts: $value"
}

extract_change_content_section() { # $1=提案ファイル。stdout="## 変更内容" 見出し行から、次の
  # "## " 見出しの直前 (存在しなければ EOF) までを抜き出す (見出し行自体を含む。純粋関数)。
  # why 見出しのみ抽出: build_sanitize_prompt の監査対象を「公開リポに実際に載る内容」に
  # 絞るためのヘルパー。frontmatter や "## 理由" は target には適用されず監査不要
  # (下記 build_sanitize_prompt の why 参照)。セクションが無い場合は空文字を返す
  local file="$1"
  awk '
    /^## 変更内容/ { insec = 1 }
    insec && /^## / && !/^## 変更内容/ { exit }
    insec { print }
  ' "$file"
}

replace_change_content_section() { # $1=提案ファイル $2=新しい "## 変更内容" セクション本文
  # (見出し行を含む)。既存の "## 変更内容" セクション (次の "## " 見出し直前まで) を
  # 丸ごと置き換える (原子的。それ以外の行・frontmatter は変更しない)。
  # why resanitize 専用: 練り直しは title/target/kind の意図を変えず変更内容だけを
  # 作り直す仕様のため、build_regenerate_prompt のようにファイル全体を再生成せず、
  # 既存ファイルの該当セクションだけを差し替える
  # why -v ではなくファイル経由で差し込む: macOS 標準 awk (BWK awk) は -v に
  # 改行を含む複数行文字列を渡すと "newline in string" で構文エラーになる
  # (gawk では通る差)。secfile に書き出して getline で読み込むことで
  # スクリプト本体には改行を埋め込まずに済む
  local file="$1" newsec="$2" tmp secfile
  tmp=$(mktemp "$(dirname "$file")/.reflect-resani-XXXXXX") || return 1
  secfile=$(mktemp "$(dirname "$file")/.reflect-resani-sec-XXXXXX") || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$newsec" >"$secfile"
  if ! awk -v secfile="$secfile" '
    /^## 変更内容/ && !done {
      while ((getline line < secfile) > 0) print line
      close(secfile)
      insec = 1; done = 1; next
    }
    insec && /^## / && !/^## 変更内容/ { insec = 0 }
    insec { next }
    { print }
  ' "$file" >"$tmp"; then
    rm -f "$tmp" "$secfile"
    return 1
  fi
  rm -f "$secfile"
  mv "$tmp" "$file"
}

build_sanitize_prompt() { # $1=title (frontmatter) $2=変更内容セクション本文。
  # stdout=ヘッドレス claude への監査プロンプト (純粋関数)
  # why 全文でなく title + 変更内容に限定: 提案ビューアが承認時に公開リポへ
  # 実際にコミットするのは (1) コミットメッセージ "proposal: <id> <title>" と
  # (2) "## 変更内容" を target へ機械適用した結果、の2つのみ (frontmatter と "## 理由" は
  # 一切載らない)。frontmatter には target/source_cwd 由来の絶対パス・作業リポ名が構造上
  # 必ず含まれるため、全文監査だと「非公開の frontmatter に絶対パスがある」という誤検知
  # (flagged) が常に発生してしまう。公開される内容だけを渡すことでこれを解消する
  cat <<'EOF'
以下は、ローカルで生成された提案のうち、承認されると公開 dotfiles リポにそのまま
コミットされる内容 (コミットメッセージに載るタイトルと、target ファイルに適用される
変更内容) です。まず ~/dotfiles/.claude/rules/sanitize-criteria.md を読み、
そこに書かれたサニタイズ判定基準 (絶対パス・組織名/他人の名前・秘密情報・作業リポ固有の
識別子の混入有無) をそのまま適用してください。

判定対象のタイトル:
EOF
  printf '%s\n' "$1"
  cat <<'EOF'

判定対象の変更内容 (target への適用結果):
----- BEGIN CHANGE CONTENT -----
EOF
  printf '%s\n' "$2"
  cat <<'EOF'
----- END CHANGE CONTENT -----

出力は次のいずれか1行のみとしてください。説明・前置き・後書きは一切書かないこと:
REFLECT-SANITIZE: pass
REFLECT-SANITIZE: flagged <漏洩理由を一行で>
EOF
}

build_resanitize_prompt() { # $1=元提案ファイル全文(frontmatter込み) $2=flag理由 $3=targetの現在の内容。
  # stdout=サニタイズ差し戻し用の練り直しプロンプト (純粋関数)
  # why build_regenerate_prompt を流用しない: 骨格 (元提案+target現在内容を渡し
  # REFLECT-PROPOSAL を1個返させる) は同じだが、意図が別物 (夜間の内容作り直しではなく
  # 「flag された漏洩要素だけを除去する」)。title/target/kind の意図は維持させたいので
  # そのことを明示し、変更内容以外に手を入れさせない
  cat <<'EOF'
以下の提案は、サニタイズ監査 (~/dotfiles/.claude/rules/sanitize-criteria.md に
書かれた判定基準) で flagged と判定されました。指摘された漏洩理由の要素だけを取り除いて
"## 変更内容" を作り直してください。title / target / kind が表す意図 (何について・どの
ファイルに対する提案か) は変更しないこと。target の現在の内容も参考にして、適用結果が
引き続き妥当であることを確認してください。REFLECT-PROPOSAL ブロックをちょうど1個だけ
返してください。それ以外の文章・前置き・後書きは一切書かないこと。

----- 元提案 (frontmatter + 本文) -----
EOF
  printf '%s\n' "$1"
  cat <<'EOF'
----- flag 理由 -----
EOF
  printf '%s\n' "$2"
  cat <<'EOF'
----- target の現在の内容 -----
EOF
  printf '%s\n' "$3"
  echo "----- (以上) -----"
}

parse_sanitize_marker() { # stdin=claude 出力。"pass" / "flagged <理由>" / "" (欠落・不正) を返す (純粋関数)
  awk '
    /^REFLECT-SANITIZE: pass[[:space:]]*$/ { print "pass"; found = 1; exit }
    /^REFLECT-SANITIZE: flagged/ {
      line = $0
      sub(/^REFLECT-SANITIZE: flagged[[:space:]]*/, "", line)
      print "flagged " line
      found = 1
      exit
    }
    END { if (!found) print "" }
  '
}

invoke_sanitize_claude() { # $1=プロンプト全文。stdout=claude 生出力 (副作用。self_test で差し替え可能)
  (cd "$REFLECT_CWD" && REFLECT_HEADLESS=1 \
    perl -e 'alarm shift @ARGV; exec @ARGV' "$SANITIZE_TIMEOUT_SEC" \
    "$CLAUDE_BIN" -p "$1" --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
}

invoke_resanitize_claude() { # $1=プロンプト全文。stdout=claude 生出力 (副作用。self_test で差し替え可能)
  # why sanitize と同じ SANITIZE_TIMEOUT を使う: 練り直しも「公開リポ行きの内容を
  # 直す」sanitize フローの一部であり、regenerate (夜間の内容作り直し) とは
  # 別のタイムアウト予算にする理由がない
  (cd "$REFLECT_CWD" && REFLECT_HEADLESS=1 \
    perl -e 'alarm shift @ARGV; exec @ARGV' "$SANITIZE_TIMEOUT_SEC" \
    "$CLAUDE_BIN" -p "$1" --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
}

resanitize_change_content() { # $1=提案ファイル $2=flagged判定の値("flagged <理由>") $3=target絶対パス。
  # flag 理由を差し戻して "## 変更内容" だけを作り直させ、成功すればファイルへ
  # 反映する (副作用。戻り値 0=反映成功 / 1=練り直し失敗・ファイル未変更)
  local file="$1" flagged_value="$2" target="$3" reason orig target_content
  local prompt resp block blockfile newsec
  reason="${flagged_value#flagged }"
  orig=$(cat "$file")
  if [ -n "$target" ] && [ -f "$target" ]; then
    target_content=$(cat "$target")
  else
    target_content="(target 不在: ${target:-<空>})"
  fi

  prompt=$(build_resanitize_prompt "$orig" "$reason" "$target_content")
  resp=$(invoke_resanitize_claude "$prompt")
  block=$(printf '%s\n' "$resp" | extract_block PROPOSAL)
  if [ -z "$block" ]; then
    log "$file: 練り直し失敗 (PROPOSAL ブロック欠落)"
    return 1
  fi

  blockfile=$(mktemp "${TMPDIR:-/tmp/}reflect-resani-block-XXXXXX")
  printf '%s\n' "$block" >"$blockfile"
  newsec=$(extract_change_content_section "$blockfile")
  rm -f "$blockfile"
  if [ -z "$newsec" ]; then
    log "$file: 練り直し結果に ## 変更内容 セクションが無い"
    return 1
  fi

  replace_change_content_section "$file" "$newsec"
}

stamp_sanitize_if_needed() { # $1=保存済み提案ファイルの絶対パス。
  # target が ③ (dotfiles配下) のときだけ sanitize 監査を実行し frontmatter に
  # sanitized: pass|flagged と sanitize_attempts: <実施した監査回数> をスタンプする
  # (決定12 + ユーザ確定仕様の練り直しループ)。stdout: 呼び出し元の結果行に
  # そのまま連結できる " (...)" 形の注記 (③以外は空文字)。
  # why 練り直しは最大2回 (監査は最大3回): flagged のたびに flag 理由を差し戻して
  # "## 変更内容" を作り直させ、再監査する。途中で pass になればその内容で確定し、
  # 3回目 (=2回練り直した後) も flagged なら見送りにはせず、最後の内容のまま
  # pending に残し sanitized: flagged <理由> をスタンプする (ユーザ確定仕様)。
  # sanitize_attempts は「実施した監査 (invoke_sanitize_claude 呼び出し) の回数」を
  # 数える契約キーで、1 = 一発 pass/flagged、練り直しをした分だけ増える
  local file="$1" target title change_section raw parsed value attempt=0
  local max_regens=2 # 練り直しの上限回数 (監査上限 = max_regens + 1)
  target=$(frontmatter_value "$file" target)
  target_is_public_dotfiles "$target" || { echo ""; return 0; }

  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    echo " (dry-run: sanitize 未実施)"
    return 0
  fi

  while :; do
    attempt=$((attempt + 1))
    title=$(frontmatter_value "$file" title)
    change_section=$(extract_change_content_section "$file")
    raw=$(invoke_sanitize_claude "$(build_sanitize_prompt "$title" "$change_section")")
    parsed=$(printf '%s\n' "$raw" | parse_sanitize_marker)

    case "$parsed" in
      pass)
        if insert_sanitized_line "$file" "pass" && insert_attempts_line "$file" "$attempt"; then
          echo " (sanitized: pass, sanitize_attempts: $attempt)"
          return 0
        fi
        log "$file: sanitized 行の挿入に失敗"
        echo " (sanitize 判定 pass だがスタンプ書き込み失敗)"
        return 1
        ;;
      flagged*)
        value="$parsed"
        if [ "$attempt" -le "$max_regens" ]; then
          if resanitize_change_content "$file" "$value" "$target"; then
            continue # 練り直し成功 -> 作り直した内容で再監査する
          fi
          log "$file: 練り直しに失敗。直前の flagged 判定のままスタンプして打ち切る"
        fi
        if insert_sanitized_line "$file" "$value" && insert_attempts_line "$file" "$attempt"; then
          echo " (sanitized: $value, sanitize_attempts: $attempt)"
          return 0
        fi
        log "$file: sanitized 行の挿入に失敗"
        echo " (sanitize 判定 flagged だがスタンプ書き込み失敗)"
        return 1
        ;;
      *)
        log "$file: sanitize 監査失敗またはマーカー欠落。スタンプなし (自動処理対象外のまま)"
        insert_attempts_line "$file" "$attempt" || true
        echo " (sanitize 監査失敗: スタンプなし。自動処理対象外のまま)"
        return 1
        ;;
    esac
  done
}

process_proposal_block() { # $1=blockfile $2=sid $3=n $4=cwd $5=supersedes(省略可)。結果行を stdout に1行 (成否は戻り値)
  local blockfile="$1" sid="$2" n="$3" cwd="$4" supersedes="${5:-}"
  local target="" kind="" title="" header_done=0 line body_file fail=""
  body_file=$(mktemp "${TMPDIR:-/tmp/}reflect-prop-body-XXXXXX")

  # why ヘッダ読取: process_memory_block と同じ流儀。target/kind/title は
  # 先頭の "---" 行までのメタデータ、それ以降 (## 理由 / ## 変更内容) は
  # 一字一句そのまま body_file に落とす
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$header_done" -eq 1 ]; then
      printf '%s\n' "$line" >>"$body_file"
      continue
    fi
    if [ "$line" = "---" ]; then
      header_done=1
      continue
    fi
    case "$line" in
      target:*) target=$(trim "${line#target:}") ;;
      kind:*) kind=$(trim "${line#kind:}") ;;
      title:*) title=$(trim "${line#title:}") ;;
    esac
  done <"$blockfile"

  # why ここで正規化: 新規生成・再提案 (regenerate) はどちらもこの関数を通るため、
  # 1 箇所で両経路に効く。絶対パス検証より前に正規化することで、正規化後の値を
  # 検証・保存する (canonicalize_target の why は定義側参照)
  target=$(canonicalize_target "$target")

  case "$target" in
    /*) ;;
    *) fail="target が空か絶対パスでない: ${target:-<空>}" ;;
  esac
  [ -n "$fail" ] || [ -n "$title" ] || fail="title が空"
  # 本文空 = "---" 区切り欠落かモデルの返却不正。target 未存在の提案はあり得るが
  # 本文が無い提案は確定させない
  if [ -z "$fail" ] && [ ! -s "$body_file" ]; then
    fail="本文が空 (--- 区切り欠落の疑い)"
  fi
  # kind は分類・フィルタ用でビューアが動的生成するため enum 強制しない。
  # 空だけ "other" に落とす
  [ -n "$kind" ] || kind="other"

  if [ -n "$fail" ]; then
    rm -f "$body_file"
    cp "$blockfile" "$HOLD/$sid-proposal-$n.txt"
    log "$sid: 提案ブロック $n 失敗 ($fail)"
    echo "提案 失敗: hold/$sid-proposal-$n.txt"
    return 1
  fi

  local proposals_dir pending_dir date_str created sid8 id repo i
  proposals_dir="${REFLECT_PROPOSALS_DIR:-$HOME/dotfiles/.local/reflect-proposals}"
  pending_dir="$proposals_dir/pending"
  date_str=$(date '+%Y%m%d')
  created=$(date '+%Y-%m-%d')
  sid8="${sid:0:8}"
  # why 空き番号探索: 差分再処理で同日同 sid の queue エントリが再来しうる。
  # 黙って上書きせず、既存 id が無くなるまで N をインクリメントする。
  # why archived も見る: /proposals は適用済み提案を同名のまま archived へ移す。
  # pending だけ見ると archive 後に id が再利用され、その提案を適用した際に
  # /proposals の同名スキップで pending に applied ファイルが取り残される
  i=1
  while [ -e "$pending_dir/${date_str}-${sid8}-${i}.md" ] \
    || [ -e "$proposals_dir/archived/${date_str}-${sid8}-${i}.md" ]; do
    i=$((i + 1))
  done
  id="${date_str}-${sid8}-${i}"
  repo=$(derive_repo "$target")

  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    rm -f "$body_file"
    log "DRY_RUN: 提案保存をスキップ ($id, $title)"
    echo "提案: $id $title (dry-run)"
    return 0
  fi

  # why mktemp + mv: memory 書き込みと同じ atomic 方式。途中クラッシュで
  # 半端な提案ファイルを確定させない。frontmatter + 本文は中間ファイルを挟まず
  # 直接 $tmp へ書く (process_memory_block の body_file→$tmp と同じ形。mktemp の
  # 失敗も同じ guarded chain で捕捉する)
  local tmp=""
  if ! mkdir -p "$pending_dir" \
    || ! tmp=$(mktemp "$pending_dir/.reflect-prop-XXXXXX") \
    || ! {
      echo "---"
      echo "id: $id"
      echo "status: pending"
      echo "target: $target"
      echo "repo: $repo"
      echo "kind: $kind"
      echo "title: $title"
      echo "source: reflect-auto"
      echo "source_session: $sid"
      echo "source_cwd: $cwd"
      echo "created: $created"
      [ -n "$supersedes" ] && echo "supersedes: $supersedes"
      echo "decided:"
      echo 'note: ""'
      echo "---"
      echo ""
      cat "$body_file"
    } >"$tmp" \
    || ! mv "$tmp" "$pending_dir/$id.md"; then
    [ -n "$tmp" ] && rm -f "$tmp"
    rm -f "$body_file"
    cp "$blockfile" "$HOLD/$sid-proposal-$n.txt"
    log "$sid: 提案ブロック $n 失敗 (書き込みエラー: $pending_dir/$id.md)"
    echo "提案 失敗: hold/$sid-proposal-$n.txt"
    return 1
  fi
  rm -f "$body_file"

  log "$sid: 提案保存成功 -> $pending_dir/$id.md"
  local sanitize_note
  sanitize_note=$(stamp_sanitize_if_needed "$pending_dir/$id.md")
  echo "提案: $id $title${sanitize_note}"
  return 0
}

decode_note_value() { # $1=frontmatter の note 生値。デコード済み note を stdout に返す (純粋関数)
  # why デコードする: 提案ビューアの note 入力は複数行可の textarea で、frontmatter には
  # json.dumps 形式の 1 行 ("...\n...") として書かれる。生のまま再掲すると複数行の指摘が
  # \n リテラルで 1 行に潰れて読みにくく、note を効かせるという再掲の目的を損なう。
  # why perl: alarm による timeout で既に依存済みで、JSON::PP は Perl 5.14+ のコアモジュール。
  # 依存を増やさずに済む。デコードに失敗したら生値をそのまま返す (プロンプトから note が
  # 消えるより、読みにくくても残る方がまし)。
  local raw="$1"
  case "$raw" in
    '"'*) ;;
    *) printf '%s' "$raw"; return ;;  # 素の文字列 (引用符なし) はそのまま
  esac
  printf '%s' "$raw" | perl -MJSON::PP -e '
    my $in = do { local $/; <STDIN> };
    my $out = eval { JSON::PP->new->allow_nonref->decode($in) };
    print defined($out) ? $out : $in;
  ' 2>/dev/null || printf '%s' "$raw"
}

build_regenerate_prompt() { # $1=元提案ファイル全文(frontmatter込み) $2=targetの現在の内容
  # $3=デコード済み note (空可) $4=元提案の kind (空可)。
  # stdout=ヘッドレスへの再生成プロンプト (純粋関数)
  cat <<'EOF'
/reflect の再提案 (regenerate) モードとして動いてください。SKILL.md の
「§6a. 再提案 (regenerate) モード」に書かれたルールに従い、次の元提案と target の
現在の内容を踏まえて変更内容を作り直し、REFLECT-PROPOSAL ブロックをちょうど1個だけ
返してください。それ以外の文章・前置き・後書きは書かないこと。

----- 元提案 (frontmatter + 本文) -----
EOF
  printf '%s\n' "$1"
  cat <<'EOF'
----- target の現在の内容 -----
EOF
  printf '%s\n' "$2"
  # why note を独立セクションで再掲する: note は元提案 frontmatter に既に含まれているが、
  # 多数の frontmatter キーに埋もれると「作り直しを要求した理由」として扱われず、実測では
  # 同じ note を渡した 6 件のうち 5 件が note に一切触れずに作り直していた。プロンプト末尾に
  # 独立セクションで再掲し、最優先の制約であることを明示して直近性を効かせる。
  # why 空なら省略する: 空セクションは「指摘なし」を「指摘欄がある」ノイズに変えるだけ。
  if [ -n "$3" ]; then
    cat <<'EOF'
----- ユーザの指摘 (note。再提案を要求した本人が書いたもの) -----
EOF
    printf '%s\n' "$3"
    cat <<'EOF'

この note は最優先の制約です。作り直した変更内容がこの指摘に反するなら提案として
成立しないので、指摘を満たす形に作り直してください。指摘をどう反映したかは
「## 理由」に 1 行書いてください。
EOF
  fi
  # why kind: claude-md だけ事前ロードを課す: CLAUDE.md は全セッションの毎ターンに
  # 読み込まれるので、1 行増やす判断の当否が他の target より重く効く。その判断基準は
  # claude-md-guide が持っているが、スキル一覧に名前が載るだけでは中身は入らず
  # (実測: 再提案 6 件で Skill 呼び出し 0 回)、ロードは明示的に指示しないと起きない。
  # why ロード可能: reflect 自身は disable-model-invocation で Skill 経由の呼び出しが
  # 塞がれているが、claude-md-guide にその指定は無くヘッドレスからロードできる (実検証済み)。
  if [ "$4" = "claude-md" ]; then
    cat <<'EOF'
----- 必須の事前作業 (この提案は CLAUDE.md 宛) -----
変更内容を作り直す前に、必ず Skill ツールで claude-md-guide をロードし、その原則に
照らして変更内容を決めてください。CLAUDE.md は全セッションで context を消費するため、
行を増やす判断はこのガイドの基準 (1 行ごとに「これがないと Claude がミスするか」を
問う・推測できない情報だけ書く・本体 300 行以下) に従う必要があります。
EOF
  fi
  echo "----- (以上) -----"
}

invoke_regenerate_claude() { # $1=プロンプト全文。stdout=claude 生出力 (副作用。self_test で差し替え可能)
  (cd "$REFLECT_CWD" && REFLECT_HEADLESS=1 \
    perl -e 'alarm shift @ARGV; exec @ARGV' "$REGEN_TIMEOUT_SEC" \
    "$CLAUDE_BIN" -p "$1" --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
}

find_regenerate_proposals() { # $1=pending_dir。status: regenerate のファイルパスを1行1件 stdout に返す (読み取り専用)
  local dir="$1" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$(frontmatter_value "$f" status)" = "regenerate" ] && printf '%s\n' "$f"
  done
}

finalize_regenerate_source() { # $1=元提案ファイル $2=archivedディレクトリ。
  # status: superseded に書き換えたうえで archived へ移動する (決定13。原子的操作の組み合わせ)
  local file="$1" archdir="$2" base tmp
  base=$(basename "$file")
  mkdir -p "$archdir" || return 1
  tmp=$(mktemp "$(dirname "$file")/.reflect-regen-XXXXXX") || return 1
  if ! awk '{ if ($0 ~ /^status: /) print "status: superseded"; else print }' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$file" "$archdir/$base"
}

process_regenerate_item() { # $1=status:regenerateの提案ファイル。1件を再提案処理し
  # 結果行を stdout に返す (成否は戻り値)。失敗時は決定13aどおり元提案を
  # status: regenerate のまま pending に残す (ロールバックする副作用がないため)
  local file="$1" proposals_dir archdir old_id old_target orig_content target_content note kind
  local prompt raw block tmp_block sid save_out new_id

  proposals_dir="${REFLECT_PROPOSALS_DIR:-$HOME/dotfiles/.local/reflect-proposals}"
  archdir="$proposals_dir/archived"
  old_id=$(basename "$file" .md)
  old_target=$(frontmatter_value "$file" target)
  orig_content=$(cat "$file")
  note=$(decode_note_value "$(frontmatter_value "$file" note)")
  kind=$(frontmatter_value "$file" kind)

  if [ -n "$old_target" ] && [ -f "$old_target" ]; then
    target_content=$(cat "$old_target")
  else
    target_content="(target 不在: ${old_target:-<空>})"
  fi

  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    log "DRY_RUN: 再提案をスキップ ($old_id)"
    echo "再提案: $old_id (dry-run のためスキップ)"
    return 0
  fi

  prompt=$(build_regenerate_prompt "$orig_content" "$target_content" "$note" "$kind")
  raw=$(invoke_regenerate_claude "$prompt")
  block=$(printf '%s\n' "$raw" | extract_block PROPOSAL)

  if [ -z "$block" ]; then
    log "$old_id: 再提案失敗 (PROPOSAL ブロック欠落)"
    echo "再提案失敗: $old_id (PROPOSALブロック欠落。pending に status: regenerate のまま残置)"
    return 1
  fi

  tmp_block=$(mktemp "${TMPDIR:-/tmp/}reflect-regen-block-XXXXXX")
  printf '%s\n' "$block" >"$tmp_block"
  sid="regenerate-${old_id}"

  if save_out=$(process_proposal_block "$tmp_block" "$sid" 1 "$REFLECT_CWD" "$old_id"); then
    rm -f "$tmp_block"
    new_id=$(printf '%s' "$save_out" | sed -n 's/^提案: \([^ ]*\) .*/\1/p')
    if [ -n "$new_id" ] && finalize_regenerate_source "$file" "$archdir"; then
      log "$old_id: 再提案成功 -> $new_id"
      echo "再提案: $old_id -> $new_id"
      return 0
    fi
    log "$old_id: 新提案 $new_id は保存済みだが元提案の archive 移動に失敗"
    echo "再提案: $old_id -> $new_id (新提案は保存済み。元提案の archive 移動に失敗し pending に残置)"
    return 1
  fi

  rm -f "$tmp_block"
  log "$old_id: 再提案の保存に失敗 ($save_out)"
  echo "再提案失敗: $old_id (新提案の保存に失敗。pending に status: regenerate のまま残置)"
  return 1
}

run_regenerate_cycle() { # 引数なし。$REFLECT_PROPOSALS_DIR/pending の status:regenerate を
  # 順に処理し、結果をまとめて inbox に記録する (決定13/13a)
  local proposals_dir pending_dir list f line results=""
  proposals_dir="${REFLECT_PROPOSALS_DIR:-$HOME/dotfiles/.local/reflect-proposals}"
  pending_dir="$proposals_dir/pending"
  [ -d "$pending_dir" ] || return 0

  list=$(mktemp "${TMPDIR:-/tmp/}reflect-regen-list-XXXXXX")
  find_regenerate_proposals "$pending_dir" >"$list"

  while IFS= read -r f <&5; do
    [ -n "$f" ] || continue
    line=$(process_regenerate_item "$f")
    results="${results}${line}
"
  done 5<"$list"
  rm -f "$list"

  if [ -n "$results" ]; then
    printf '%s' "$results" | inbox_append "$(date '+%Y-%m-%d') 再提案サイクル"
  fi
}

inbox_append() { # $1=見出し行 stdin=本文
  {
    echo ""
    echo "## $1"
    echo ""
    cat
  } >>"$INBOX"
}

attempts_of() {
  local c
  c=$(grep -cF "$1" "$ATTEMPTS" 2>/dev/null)
  echo "${c:-0}"
}

# NOTE: reflect-enqueue.sh の done_lines_of と同一実装。変えるときは両方揃える
# (テストは hook 側の --self-test が担う)
done_lines_of() { # $1=sid。出力: ""(未処理) / "inf"(恒久 done) / 記録済み最大行数
  [ -f "$DONE" ] || return 0
  awk -v s="$1" '
    $1 == s { if (NF < 2) inf = 1; else if ($2 + 0 > max) max = $2 + 0; found = 1 }
    END { if (inf) print "inf"; else if (found) print max + 0 }
  ' "$DONE"
}

# 処理確定 (done) した sid の失敗カウントを消す。
# why: 差分再処理で同じ sid が別ラウンドとして戻るため、前ラウンドの失敗数を
# 持ち越すと新ラウンドのリトライ予算が失われる
clear_attempts() {
  [ -f "$ATTEMPTS" ] || return 0
  grep -vF "$1" "$ATTEMPTS" >"$ATTEMPTS.tmp" || true
  mv "$ATTEMPTS.tmp" "$ATTEMPTS"
}

# $1=sid $2=処理済み行数の watermark (省略時は恒久 done = 以後成長しても再処理しない)。
# watermark 付きで記録しておくと、その行以降に transcript が伸びたとき
# enqueue hook が差分再処理として再投入できる
mark_done() {
  echo "$1${2:+ $2}" >>"$DONE"
  clear_attempts "$1"
}

# why ここで定義: self_test (直後) や run_regenerate_cycle は inbox_append を使う。
# self-test 起動は exec によるログ差し替えより
# 前で発生するため、呼ばれうる関数はすべてそれより前に定義しておく必要がある

self_test() {
  local tmpdir pass=0 fail=0
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp/}reflect-headless-test-XXXXXX")
  trap "rm -rf \"$tmpdir\"" EXIT

  # why local shadow: memory_path_ok / process_memory_block は
  # REFLECT_MEMORY_ROOT / HOLD をそのまま参照する。bash の動的スコープにより
  # ここで local 宣言すれば呼び出し先にも見えるので、実 $HOME に触れずに
  # 検証できる (env 上書きの代わり)
  local REFLECT_MEMORY_ROOT="$tmpdir/root"
  local HOLD="$tmpdir/hold"
  mkdir -p "$REFLECT_MEMORY_ROOT" "$HOLD"

  # why 同じ動的スコープの流儀: derive_repo / process_proposal_block は
  # REFLECT_HOME / REFLECT_PROPOSALS_DIR をそのまま参照する。ここで local
  # 宣言すれば呼び出し先にも見えるので、実 $HOME・実 pending/ に触れずに検証できる
  local REFLECT_HOME="$tmpdir/home"
  local REFLECT_PROPOSALS_DIR="$tmpdir/proposals"
  mkdir -p "$REFLECT_HOME/dotfiles" "$REFLECT_HOME/projects" "$REFLECT_PROPOSALS_DIR/pending"

  ok() { pass=$((pass + 1)); }
  ng() { fail=$((fail + 1)); echo "FAIL: $1"; }

  # why スタブ差し替え: self_test は実 claude を絶対に呼ばない
  # (完了条件「実データに触れない」の一部)。sanitize/resanitize/regenerate の
  # 呼び出し関数をここで上書きし、$SANITIZE_STUB_MODE / $RESANITIZE_STUB_MODE /
  # $REGENERATE_STUB_MODE (どちらも下の local 変数。動的スコープで見える) で
  # 挙動を切り替える。
  # why 呼び出し回数をファイルで数える: stamp_sanitize_if_needed は
  # invoke_sanitize_claude / invoke_resanitize_claude を `raw=$(...)` 形の
  # コマンド置換 (= サブシェル) 越しに呼ぶ。サブシェル内の変数代入は呼び出し元に
  # 反映されないため、シェル変数のインクリメントでは呼び出し回数を跨いで数えられない
  # (試して実際に壊れた: 何度呼んでも「1回目」の値しか返らなかった)。
  # ファイル I/O はサブシェルをまたいで永続するので、そちらで数える
  local SANITIZE_CALL_FILE="$tmpdir/sanitize-call-n" RESANITIZE_CALL_FILE="$tmpdir/resanitize-call-n"
  reset_stub_call_counts() { echo 0 >"$SANITIZE_CALL_FILE"; echo 0 >"$RESANITIZE_CALL_FILE"; }
  reset_stub_call_counts

  # why SANITIZE_STUB_MODE をスペース区切りの列にする: 練り直しループのテストは
  # 「1回目 flagged、練り直し後の2回目 pass」のような呼び出しごとに違う判定を
  # 返す必要がある。N 回目の語を使い、単語数より多く呼ばれたら最後の語を使い回す
  # (従来どおり単語1個の固定値指定も動く)
  local SANITIZE_STUB_MODE="pass"
  invoke_sanitize_claude() {
    local n mode
    n=$(( $(cat "$SANITIZE_CALL_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$SANITIZE_CALL_FILE"
    mode=$(printf '%s\n' "$SANITIZE_STUB_MODE" | awk -v n="$n" '{ print ($n != "" ? $n : $NF) }')
    case "$mode" in
      pass) echo "REFLECT-SANITIZE: pass" ;;
      flagged) echo "REFLECT-SANITIZE: flagged 機密情報の疑いを検知" ;;
      missing) echo "説明文だけでマーカーがない出力" ;;
      *) echo "REFLECT-SANITIZE: pass" ;;
    esac
  }

  local RESANITIZE_STUB_MODE="ok"
  invoke_resanitize_claude() {
    local n
    n=$(( $(cat "$RESANITIZE_CALL_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$RESANITIZE_CALL_FILE"
    case "$RESANITIZE_STUB_MODE" in
      ok)
        cat <<EOF
<<<REFLECT-PROPOSAL
target: $REFLECT_HOME/dotfiles/CLAUDE.md
kind: claude-md
title: 練り直し後もタイトルは維持
---
## 理由

練り直しテスト理由

## 変更内容

\`\`\`append
resanitized-content-call-${n}
\`\`\`
REFLECT-PROPOSAL>>>
EOF
        ;;
      missing-block) echo "PROPOSALブロックを返さない練り直し失敗ケース" ;;
      *) echo "" ;;
    esac
  }

  local REGENERATE_STUB_MODE="ok"
  invoke_regenerate_claude() {
    case "$REGENERATE_STUB_MODE" in
      ok)
        cat <<EOF
<<<REFLECT-PROPOSAL
target: $REFLECT_HOME/dotfiles/CLAUDE.md
kind: claude-md
title: 再生成されたテスト提案
---
## 理由

テスト再生成理由

## 変更内容

\`\`\`append
regenerated
\`\`\`
REFLECT-PROPOSAL>>>
EOF
        ;;
      save-fail)
        cat <<'EOF'
<<<REFLECT-PROPOSAL
target: relative/not/absolute.md
kind: claude-md
title: 保存失敗を誘発するテスト
---
body
REFLECT-PROPOSAL>>>
EOF
        ;;
      missing-block) echo "PROPOSALブロックを返さない失敗ケースの出力" ;;
      *) echo "" ;;
    esac
  }

  make_block() { # $1=out $2=mode $3=file $4=index $5=body
    {
      echo "mode: $2"
      echo "file: $3"
      echo "index: $4"
      echo "---"
      printf '%s\n' "$5"
    } >"$1"
  }

  make_prop_block() { # $1=out $2=target $3=kind $4=title $5=body
    {
      echo "target: $2"
      echo "kind: $3"
      echo "title: $4"
      echo "---"
      printf '%s\n' "$5"
    } >"$1"
  }

  # --- split_memory_blocks ---
  local mixed="$tmpdir/mixed.txt" outdir="$tmpdir/split1" n_files
  mkdir -p "$outdir"
  cat >"$mixed" <<'EOF'
<<<REFLECT-MEMORY
mode: create
file: /tmp/x/memory/a.md
index: - [A](a.md) — hook
---
body line
<<<REFLECT-MEMORY
quoted nested marker (not a new block)
REFLECT-MEMORY>>>
<<<REFLECT-SUMMARY
ふりかえり: スキル指摘 0 件（0 件） / 行動 0 件（memory 書き込み 1 件 / 対話処理待ち 0 件）
REFLECT-SUMMARY>>>
<<<REFLECT-MEMORY
mode: update
file: /tmp/x/memory/b.md
index:
---
body2
REFLECT-MEMORY>>>
EOF
  split_memory_blocks "$outdir" <"$mixed"
  n_files=$(find "$outdir" -maxdepth 1 -type f -name 'mem-*' | wc -l | tr -d ' ')
  if [ "$n_files" = "2" ]; then ok; else ng "split: MEMORY 2 件になるはず (実際 ${n_files:-0})"; fi
  if grep -qF "quoted nested marker" "$outdir/mem-1" 2>/dev/null; then
    ok
  else
    ng "split: 引用マーカーが本文から消えた/誤って分離された"
  fi
  if grep -qF "mode: update" "$outdir/mem-2" 2>/dev/null; then
    ok
  else
    ng "split: 2 件目の内容が違う"
  fi

  # --- memory_path_ok ---
  if memory_path_ok "$REFLECT_MEMORY_ROOT/proj/memory/foo.md"; then ok; else ng "memory_path_ok: 正常パスが NG"; fi
  if ! memory_path_ok "$REFLECT_MEMORY_ROOT/proj/../etc/memory/foo.md"; then ok; else ng "memory_path_ok: .. が通った"; fi
  if ! memory_path_ok "$REFLECT_MEMORY_ROOT/proj/memory/sub/foo.md"; then ok; else ng "memory_path_ok: サブディレクトリが通った"; fi
  if ! memory_path_ok "/etc/passwd"; then ok; else ng "memory_path_ok: prefix 外が通った"; fi
  if ! memory_path_ok "$REFLECT_MEMORY_ROOT/proj/memory/foo.txt"; then ok; else ng "memory_path_ok: .md 以外が通った"; fi
  if ! memory_path_ok "$REFLECT_MEMORY_ROOT/./memory/foo.md"; then ok; else ng "memory_path_ok: . セグメントが通った"; fi
  # expected_seg 指定時: 自分のプロジェクトなら通り、他プロジェクトは弾く
  if memory_path_ok "$REFLECT_MEMORY_ROOT/proj/memory/foo.md" "proj"; then ok; else ng "memory_path_ok: expected_seg 一致が NG"; fi
  if ! memory_path_ok "$REFLECT_MEMORY_ROOT/other-proj/memory/foo.md" "proj"; then ok; else ng "memory_path_ok: expected_seg 不一致が通った (cross-project 書き込み)"; fi
  if [ "$(project_segment_for_cwd "/Users/testuser/dotfiles")" = "-Users-testuser-dotfiles" ]; then
    ok
  else
    ng "project_segment_for_cwd: / を - に置換していない"
  fi
  if [ "$(project_segment_for_cwd "/Users/testuser/.claude/projects/foo")" = "-Users-testuser--claude-projects-foo" ]; then
    ok
  else
    ng "project_segment_for_cwd: . を - に置換していない (cwd に . を含む場合の実プロジェクト名と不一致)"
  fi

  # --- process_memory_block ---
  local sid="t1" f1="$REFLECT_MEMORY_ROOT/p1/memory/new1.md" blk out

  blk="$tmpdir/blk-create.txt"
  make_block "$blk" create "$f1" "- [New1](new1.md) — hook" "hello world"
  if out=$(process_memory_block "$blk" "$sid" 1) && [ -f "$f1" ] \
    && grep -qF "hello world" "$f1" \
    && grep -qF "](new1.md)" "$(dirname "$f1")/MEMORY.md"; then
    ok
  else
    ng "process_memory_block: create 成功ケース ($out)"
  fi

  blk="$tmpdir/blk-create-conflict.txt"
  make_block "$blk" create "$f1" "- [New1](new1.md) — hook" "hello again"
  if ! process_memory_block "$blk" "$sid" 2 >/dev/null && [ -f "$HOLD/$sid-memory-2.txt" ]; then
    ok
  else
    ng "process_memory_block: create 衝突が hold に落ちない"
  fi

  blk="$tmpdir/blk-update.txt"
  make_block "$blk" update "$f1" "- [New1](new1.md) — hook" "updated body"
  if process_memory_block "$blk" "$sid" 3 >/dev/null \
    && grep -qF "updated body" "$f1" && ! grep -qF "hello world" "$f1" \
    && [ "$(grep -cF '](new1.md)' "$(dirname "$f1")/MEMORY.md")" -eq 1 ]; then
    ok
  else
    ng "process_memory_block: update 成功ケース (置換または index 重複)"
  fi

  local f2="$REFLECT_MEMORY_ROOT/p1/memory/missing.md"
  blk="$tmpdir/blk-update-missing.txt"
  make_block "$blk" update "$f2" "" "body"
  if ! process_memory_block "$blk" "$sid" 4 >/dev/null && [ -f "$HOLD/$sid-memory-4.txt" ]; then
    ok
  else
    ng "process_memory_block: update 対象未存在が hold に落ちない"
  fi

  blk="$tmpdir/blk-badmode.txt"
  make_block "$blk" delete "$f1" "" "body"
  if ! process_memory_block "$blk" "$sid" 5 >/dev/null && [ -f "$HOLD/$sid-memory-5.txt" ]; then
    ok
  else
    ng "process_memory_block: 不正 mode が hold に落ちない"
  fi

  local f3="$REFLECT_MEMORY_ROOT/p1/memory/dryrun.md"
  blk="$tmpdir/blk-dryrun.txt"
  make_block "$blk" create "$f3" "- [Dry](dryrun.md) — hook" "dry body"
  if REFLECT_DRY_RUN=1 process_memory_block "$blk" "$sid" 6 >/dev/null && [ ! -e "$f3" ]; then
    ok
  else
    ng "process_memory_block: DRY_RUN で書き込みが発生した"
  fi

  local f4="$REFLECT_MEMORY_ROOT/p1/memory/nobody.md"
  blk="$tmpdir/blk-nobody.txt"
  { echo "mode: create"; echo "file: $f4"; echo "index:"; } >"$blk" # "---" 区切りなし = 本文空
  if ! process_memory_block "$blk" "$sid" 7 >/dev/null && [ -f "$HOLD/$sid-memory-7.txt" ] && [ ! -e "$f4" ]; then
    ok
  else
    ng "process_memory_block: 本文空 (--- 欠落) が hold に落ちない"
  fi

  # --- extract_block: MEMORY 本文に引用された SUMMARY 開始マーカーの混在 ---
  local mixed2="$tmpdir/mixed2.txt"
  cat >"$mixed2" <<'EOF'
<<<REFLECT-MEMORY
mode: create
file: /tmp/x/memory/c.md
index: - [C](c.md) — hook
---
<<<REFLECT-SUMMARY
fake summary quoted inside memory body
REFLECT-MEMORY>>>
<<<REFLECT-SUMMARY
real summary line
REFLECT-SUMMARY>>>
EOF
  if [ "$(extract_block SUMMARY <"$mixed2")" = "real summary line" ]; then
    ok
  else
    ng "extract_block: MEMORY 本文中の引用 SUMMARY マーカーを本物と誤認した"
  fi

  # --- 空 MEMORY ブロックが痕跡なく消えない ---
  local outdir2="$tmpdir/split2"
  mkdir -p "$outdir2"
  printf '<<<REFLECT-MEMORY\nREFLECT-MEMORY>>>\n' | split_memory_blocks "$outdir2"
  if [ -f "$outdir2/mem-1" ]; then ok; else ng "split: 空ブロックの mem ファイルが作られない"; fi
  if ! process_memory_block "$outdir2/mem-1" "$sid" 8 >/dev/null && [ -f "$HOLD/$sid-memory-8.txt" ]; then
    ok
  else
    ng "process_memory_block: 空ブロックが hold に落ちない"
  fi

  local f5="$REFLECT_MEMORY_ROOT/p1/memory/noindex.md"
  blk="$tmpdir/blk-noindex.txt"
  make_block "$blk" create "$f5" "" "body"
  if ! process_memory_block "$blk" "$sid" 9 >/dev/null && [ -f "$HOLD/$sid-memory-9.txt" ] && [ ! -e "$f5" ]; then
    ok
  else
    ng "process_memory_block: create + 空 index が hold に落ちない"
  fi

  local f6="$REFLECT_MEMORY_ROOT/p1/memory/mismatch.md"
  blk="$tmpdir/blk-mismatch.txt"
  make_block "$blk" create "$f6" "- [Other](other.md) — hook" "body"
  if ! process_memory_block "$blk" "$sid" 10 >/dev/null && [ -f "$HOLD/$sid-memory-10.txt" ] && [ ! -e "$f6" ]; then
    ok
  else
    ng "process_memory_block: index basename 不一致が hold に落ちない"
  fi

  # 書き込み失敗 (親ディレクトリ読み取り専用で mktemp が落ちる) が hold に落ちる
  local rodir="$REFLECT_MEMORY_ROOT/ro/memory" f7="$REFLECT_MEMORY_ROOT/ro/memory/blocked.md"
  mkdir -p "$rodir"
  chmod 555 "$rodir"
  blk="$tmpdir/blk-rofail.txt"
  make_block "$blk" create "$f7" "- [Blocked](blocked.md) — hook" "body"
  if ! process_memory_block "$blk" "$sid" 11 >/dev/null && [ -f "$HOLD/$sid-memory-11.txt" ] && [ ! -e "$f7" ]; then
    ok
  else
    ng "process_memory_block: 書き込み失敗が成功扱いになった"
  fi
  chmod 755 "$rodir" # trap の rm -rf が消せるように戻す

  # update + 空 index で MEMORY.md が変化しない
  local memmd1 lines_before lines_after
  memmd1="$(dirname "$f1")/MEMORY.md"
  lines_before=$(grep -c '' "$memmd1")
  blk="$tmpdir/blk-update-noindex.txt"
  make_block "$blk" update "$f1" "" "updated again"
  if process_memory_block "$blk" "$sid" 12 >/dev/null \
    && lines_after=$(grep -c '' "$memmd1") \
    && grep -qF "updated again" "$f1" && [ "$lines_before" = "$lines_after" ]; then
    ok
  else
    ng "process_memory_block: update + 空 index で MEMORY.md が変化した"
  fi

  # cwd が別プロジェクトを指すと、file: が p1/memory/... でも hold に落ちる
  # (finding #2: cross-project memory 汚染ガード)
  blk="$tmpdir/blk-cross-project.txt"
  make_block "$blk" update "$f1" "- [New1](new1.md) — hook" "from another project"
  if ! process_memory_block "$blk" "$sid" 13 "/Users/other/otherproject" >/dev/null \
    && [ -f "$HOLD/$sid-memory-13.txt" ] && ! grep -qF "from another project" "$f1"; then
    ok
  else
    ng "process_memory_block: cwd 不一致の cross-project 書き込みが hold に落ちない"
  fi

  # cwd が同じプロジェクトを指す (project_segment_for_cwd("$cwd") = p1) なら通る
  blk="$tmpdir/blk-same-project.txt"
  make_block "$blk" update "$f1" "- [New1](new1.md) — hook" "from same project"
  if process_memory_block "$blk" "$sid" 14 "p1" >/dev/null && grep -qF "from same project" "$f1"; then
    ok
  else
    ng "process_memory_block: cwd 一致の同一プロジェクト書き込みが失敗した"
  fi

  # --- split_proposal_blocks ---
  local mixedp="$tmpdir/mixedp.txt" outdirp="$tmpdir/splitp1" n_filesp
  mkdir -p "$outdirp"
  cat >"$mixedp" <<'EOF'
<<<REFLECT-PROPOSAL
target: /tmp/x/CLAUDE.md
kind: claude-md
title: 提案1
---
## 理由
テスト
<<<REFLECT-PROPOSAL
quoted nested marker (not a new block)
REFLECT-PROPOSAL>>>
<<<REFLECT-SUMMARY
ふりかえり: ダミー
REFLECT-SUMMARY>>>
<<<REFLECT-PROPOSAL
target: /tmp/x/other.md
kind: doc
title: 提案2
---
body2
REFLECT-PROPOSAL>>>
EOF
  split_proposal_blocks "$outdirp" <"$mixedp"
  n_filesp=$(find "$outdirp" -maxdepth 1 -type f -name 'prop-*' | wc -l | tr -d ' ')
  if [ "$n_filesp" = "2" ]; then ok; else ng "split: PROPOSAL 2 件になるはず (実際 ${n_filesp:-0})"; fi
  if grep -qF "quoted nested marker" "$outdirp/prop-1" 2>/dev/null; then
    ok
  else
    ng "split: PROPOSAL 引用マーカーが本文から消えた/誤って分離された"
  fi
  if grep -qF "target: /tmp/x/other.md" "$outdirp/prop-2" 2>/dev/null; then
    ok
  else
    ng "split: PROPOSAL 2 件目の内容が違う"
  fi

  local outdirp2="$tmpdir/splitp2"
  mkdir -p "$outdirp2"
  printf '<<<REFLECT-PROPOSAL\nREFLECT-PROPOSAL>>>\n' | split_proposal_blocks "$outdirp2"
  if [ -f "$outdirp2/prop-1" ]; then ok; else ng "split: PROPOSAL 空ブロックの prop ファイルが作られない"; fi

  # --- derive_repo ---
  if [ "$(derive_repo "$REFLECT_HOME/dotfiles/CLAUDE.md")" = "dotfiles" ]; then
    ok
  else
    ng "derive_repo: dotfiles 判定"
  fi
  if [ "$(derive_repo "$REFLECT_HOME/projects/sample-project/CLAUDE.md")" = "sample-project" ]; then
    ok
  else
    ng "derive_repo: projects/<name> 判定"
  fi
  if [ "$(derive_repo "$REFLECT_HOME/other/place.md")" = "other" ]; then
    ok
  else
    ng "derive_repo: other 判定"
  fi

  # --- process_proposal_block: 正常系 ---
  local blkp out2 id2
  blkp="$tmpdir/blkp-ok.txt"
  make_prop_block "$blkp" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "テスト提案" \
    $'## 理由\nテスト理由\n\n## 変更内容\n\n```append\nhello\n```'
  if out2=$(process_proposal_block "$blkp" "$sid" 1 "/cwd/ok") \
    && id2=$(printf '%s' "$out2" | sed -n 's/^提案: \([^ ]*\) .*/\1/p') \
    && [ -f "$REFLECT_PROPOSALS_DIR/pending/$id2.md" ] \
    && grep -q "^status: pending$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^target: $REFLECT_HOME/dotfiles/CLAUDE.md$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^repo: dotfiles$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^kind: claude-md$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^source: reflect-auto$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^source_session: $sid$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q "^source_cwd: /cwd/ok$" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -q '^note: ""$' "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -qF "## 理由" "$REFLECT_PROPOSALS_DIR/pending/$id2.md" \
    && grep -qF '```append' "$REFLECT_PROPOSALS_DIR/pending/$id2.md"; then
    ok
  else
    ng "process_proposal_block: 正常系 ($out2)"
  fi

  # --- process_proposal_block: target 空/非絶対パス ---
  blkp="$tmpdir/blkp-notarget.txt"
  make_prop_block "$blkp" "" "claude-md" "タイトル" "body"
  if ! process_proposal_block "$blkp" "$sid" 20 "/cwd" >/dev/null && [ -f "$HOLD/$sid-proposal-20.txt" ]; then
    ok
  else
    ng "process_proposal_block: target 空が hold に落ちない"
  fi

  blkp="$tmpdir/blkp-relative.txt"
  make_prop_block "$blkp" "relative/path.md" "claude-md" "タイトル" "body"
  if ! process_proposal_block "$blkp" "$sid" 21 "/cwd" >/dev/null && [ -f "$HOLD/$sid-proposal-21.txt" ]; then
    ok
  else
    ng "process_proposal_block: target 非絶対パスが hold に落ちない"
  fi

  # --- process_proposal_block: title 空 ---
  blkp="$tmpdir/blkp-notitle.txt"
  make_prop_block "$blkp" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "" "body"
  if ! process_proposal_block "$blkp" "$sid" 22 "/cwd" >/dev/null && [ -f "$HOLD/$sid-proposal-22.txt" ]; then
    ok
  else
    ng "process_proposal_block: title 空が hold に落ちない"
  fi

  # --- process_proposal_block: 本文空 (--- 欠落) ---
  blkp="$tmpdir/blkp-nobody.txt"
  { echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "kind: claude-md"; echo "title: タイトル"; } >"$blkp"
  if ! process_proposal_block "$blkp" "$sid" 23 "/cwd" >/dev/null && [ -f "$HOLD/$sid-proposal-23.txt" ]; then
    ok
  else
    ng "process_proposal_block: 本文空 (--- 欠落) が hold に落ちない"
  fi

  # --- process_proposal_block: kind 空 -> other ---
  local out6 id6
  blkp="$tmpdir/blkp-nokind.txt"
  make_prop_block "$blkp" "$REFLECT_HOME/dotfiles/CLAUDE.md" "" "kind空テスト" "body"
  if out6=$(process_proposal_block "$blkp" "$sid" 24 "/cwd") \
    && id6=$(printf '%s' "$out6" | sed -n 's/^提案: \([^ ]*\) .*/\1/p') \
    && grep -q "^kind: other$" "$REFLECT_PROPOSALS_DIR/pending/$id6.md"; then
    ok
  else
    ng "process_proposal_block: kind 空が other に落ちない"
  fi

  # --- process_proposal_block: id 衝突時のインクリメント ---
  local sidp="propidtest" blkp2 out3 out4 id3 id4
  blkp2="$tmpdir/blkp-collide.txt"
  make_prop_block "$blkp2" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "衝突テスト" "body"
  out3=$(process_proposal_block "$blkp2" "$sidp" 1 "/cwd")
  id3=$(printf '%s' "$out3" | sed -n 's/^提案: \([^ ]*\) .*/\1/p')
  out4=$(process_proposal_block "$blkp2" "$sidp" 2 "/cwd")
  id4=$(printf '%s' "$out4" | sed -n 's/^提案: \([^ ]*\) .*/\1/p')
  if [ -n "$id3" ] && [ -n "$id4" ] && [ "$id3" != "$id4" ] \
    && [ -f "$REFLECT_PROPOSALS_DIR/pending/$id3.md" ] && [ -f "$REFLECT_PROPOSALS_DIR/pending/$id4.md" ]; then
    ok
  else
    ng "process_proposal_block: id 衝突時のインクリメントが効いていない ($out3 / $out4)"
  fi

  # --- process_proposal_block: DRY_RUN で書き込みなし ---
  local blkp3="$tmpdir/blkp-dryrun.txt" out5 before_count after_count
  make_prop_block "$blkp3" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "dryrun提案" "body"
  before_count=$(find "$REFLECT_PROPOSALS_DIR/pending" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
  if out5=$(REFLECT_DRY_RUN=1 process_proposal_block "$blkp3" "dryrunsid" 1 "/cwd") \
    && printf '%s' "$out5" | grep -q '(dry-run)$'; then
    after_count=$(find "$REFLECT_PROPOSALS_DIR/pending" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
    if [ "$before_count" = "$after_count" ]; then
      ok
    else
      ng "process_proposal_block: DRY_RUN で書き込みが発生した (件数変化)"
    fi
  else
    ng "process_proposal_block: DRY_RUN の戻り値異常 ($out5)"
  fi

  # --- process_proposal_block: 空白のみ title が hold に落ちる (trim) ---
  blkp="$tmpdir/blkp-wstitle.txt"
  make_prop_block "$blkp" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "   " "body"
  if ! process_proposal_block "$blkp" "$sid" 25 "/cwd" >/dev/null && [ -f "$HOLD/$sid-proposal-25.txt" ]; then
    ok
  else
    ng "process_proposal_block: 空白のみ title が hold に落ちない"
  fi

  # --- process_proposal_block: target 末尾空白が frontmatter で除去される (trim) ---
  local out7 id7
  blkp="$tmpdir/blkp-wstarget.txt"
  make_prop_block "$blkp" "$REFLECT_HOME/dotfiles/CLAUDE.md   " "claude-md" "末尾空白target" "body"
  if out7=$(process_proposal_block "$blkp" "$sid" 26 "/cwd") \
    && id7=$(printf '%s' "$out7" | sed -n 's/^提案: \([^ ]*\) .*/\1/p') \
    && grep -q "^target: $REFLECT_HOME/dotfiles/CLAUDE.md$" "$REFLECT_PROPOSALS_DIR/pending/$id7.md"; then
    ok
  else
    ng "process_proposal_block: target 末尾空白が除去されない ($out7)"
  fi

  # --- process_proposal_block: archived の id を再利用しない (アーカイブ後の衝突) ---
  local sidp2="arcidtest" blkpa outa ida outa2 ida2 arcdir
  blkpa="$tmpdir/blkp-arc.txt"
  make_prop_block "$blkpa" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "アーカイブ衝突" "body"
  outa=$(process_proposal_block "$blkpa" "$sidp2" 1 "/cwd")
  ida=$(printf '%s' "$outa" | sed -n 's/^提案: \([^ ]*\) .*/\1/p')
  arcdir="$REFLECT_PROPOSALS_DIR/archived"
  mkdir -p "$arcdir"
  mv "$REFLECT_PROPOSALS_DIR/pending/$ida.md" "$arcdir/$ida.md" # /proposals の適用時 move を模す
  outa2=$(process_proposal_block "$blkpa" "$sidp2" 2 "/cwd")
  ida2=$(printf '%s' "$outa2" | sed -n 's/^提案: \([^ ]*\) .*/\1/p')
  if [ -n "$ida" ] && [ -n "$ida2" ] && [ "$ida" != "$ida2" ] \
    && [ ! -e "$REFLECT_PROPOSALS_DIR/pending/$ida.md" ] \
    && [ -f "$REFLECT_PROPOSALS_DIR/pending/$ida2.md" ]; then
    ok
  else
    ng "process_proposal_block: archived の id を再利用した ($outa / $outa2)"
  fi

  # --- frontmatter_value ---
  local fmfile="$tmpdir/fm-test.md"
  { echo "---"; echo "id: abc"; echo "target: /tmp/x.md"; echo "status: pending"; echo "---"; echo ""; echo "body"; } >"$fmfile"
  if [ "$(frontmatter_value "$fmfile" status)" = "pending" ]; then ok; else ng "frontmatter_value: status 抽出"; fi
  if [ "$(frontmatter_value "$fmfile" target)" = "/tmp/x.md" ]; then ok; else ng "frontmatter_value: target 抽出"; fi
  if [ -z "$(frontmatter_value "$fmfile" missing_key)" ]; then ok; else ng "frontmatter_value: 存在しないキーは空"; fi

  # --- target_is_public_dotfiles ---
  if target_is_public_dotfiles "$REFLECT_HOME/dotfiles/CLAUDE.md"; then ok; else ng "target_is_public_dotfiles: dotfiles配下がNG判定"; fi
  if ! target_is_public_dotfiles "$REFLECT_HOME/projects/sample-project/CLAUDE.md"; then ok; else ng "target_is_public_dotfiles: 非dotfilesが通った"; fi
  if ! target_is_public_dotfiles ""; then ok; else ng "target_is_public_dotfiles: 空パスが通った"; fi
  # why 実在 symlink での検証: ~/.claude/CLAUDE.md → ~/dotfiles/.claude/CLAUDE.merged.md の
  # ような、実体は dotfiles 配下だが symlink 元のパスは配下でないケースの回帰防止
  mkdir -p "$REFLECT_HOME/projects/sample-project"
  : >"$REFLECT_HOME/dotfiles/CLAUDE.merged.md"
  ln -sf "$REFLECT_HOME/dotfiles/CLAUDE.merged.md" "$REFLECT_HOME/projects/sample-project/CLAUDE.md.link"
  if target_is_public_dotfiles "$REFLECT_HOME/projects/sample-project/CLAUDE.md.link"; then
    ok
  else
    ng "target_is_public_dotfiles: dotfiles配下を指すsymlinkがNG判定"
  fi

  # --- canonicalize_target ---
  if [ "$(canonicalize_target "$REFLECT_HOME/.claude/CLAUDE.md")" = "$REFLECT_HOME/dotfiles/.claude/CLAUDE.md" ]; then
    ok
  else
    ng "canonicalize_target: \$HOME/.claude/CLAUDE.md が生成元に正規化されない"
  fi
  if [ "$(canonicalize_target "$REFLECT_HOME/dotfiles/CLAUDE.md")" = "$REFLECT_HOME/dotfiles/CLAUDE.md" ]; then
    ok
  else
    ng "canonicalize_target: 該当しないパスが素通ししない"
  fi
  if [ "$(canonicalize_target "$REFLECT_HOME/projects/sample-project/.claude/CLAUDE.md")" = "$REFLECT_HOME/projects/sample-project/.claude/CLAUDE.md" ]; then
    ok
  else
    ng "canonicalize_target: 別プロジェクト配下の .claude/CLAUDE.md まで書き換えた"
  fi

  # --- process_proposal_block: target 正規化が新規生成 (regenerate も同じ関数を通る) に効く ---
  local blkpcanon out9 id9
  blkpcanon="$tmpdir/blkp-canon.txt"
  make_prop_block "$blkpcanon" "$REFLECT_HOME/.claude/CLAUDE.md" "claude-md" "target正規化テスト" "body"
  if out9=$(process_proposal_block "$blkpcanon" "$sid" 28 "/cwd") \
    && id9=$(printf '%s' "$out9" | sed -n 's/^提案: \([^ ]*\) .*/\1/p') \
    && grep -q "^target: $REFLECT_HOME/dotfiles/.claude/CLAUDE.md$" "$REFLECT_PROPOSALS_DIR/pending/$id9.md"; then
    ok
  else
    ng "process_proposal_block: \$HOME/.claude/CLAUDE.md の target が正規化されずに保存された ($out9)"
  fi

  # --- parse_sanitize_marker ---
  if [ "$(printf 'REFLECT-SANITIZE: pass\n' | parse_sanitize_marker)" = "pass" ]; then
    ok
  else
    ng "parse_sanitize_marker: pass"
  fi
  if [ "$(printf 'REFLECT-SANITIZE: flagged 秘密情報を検知\n' | parse_sanitize_marker)" = "flagged 秘密情報を検知" ]; then
    ok
  else
    ng "parse_sanitize_marker: flagged + 理由"
  fi
  if [ -z "$(printf 'よくわからない出力\n' | parse_sanitize_marker)" ]; then
    ok
  else
    ng "parse_sanitize_marker: マーカー欠落は空を返すべき"
  fi
  if [ "$(printf '前置き\nREFLECT-SANITIZE: pass\n' | parse_sanitize_marker)" = "pass" ]; then
    ok
  else
    ng "parse_sanitize_marker: 前置きがあってもマーカーを検出"
  fi

  # --- insert_sanitized_line ---
  local insf="$tmpdir/ins-test.md" created_ln sanitized_ln
  { echo "---"; echo "id: x"; echo "created: 2026-07-15"; echo "decided:"; echo "---"; } >"$insf"
  if insert_sanitized_line "$insf" "pass" && grep -q "^sanitized: pass$" "$insf"; then
    created_ln=$(grep -n '^created:' "$insf" | head -n1 | cut -d: -f1)
    sanitized_ln=$(grep -n '^sanitized:' "$insf" | head -n1 | cut -d: -f1)
    if [ "$created_ln" -lt "$sanitized_ln" ]; then ok; else ng "insert_sanitized_line: created の直後に挿入されていない"; fi
  else
    ng "insert_sanitized_line: sanitized 行が追加されない"
  fi

  # --- stamp_sanitize_if_needed ---
  local nonpub="$tmpdir/nonpub-test.md"
  { echo "---"; echo "id: y"; echo "target: $REFLECT_HOME/projects/other/x.md"; echo "created: 2026-07-15"; echo "---"; } >"$nonpub"
  if [ -z "$(stamp_sanitize_if_needed "$nonpub")" ] && ! grep -q "^sanitized:" "$nonpub"; then
    ok
  else
    ng "stamp_sanitize_if_needed: ③ (dotfiles) 以外はスタンプしない"
  fi

  local pubmiss="$tmpdir/pubmiss-test.md"
  { echo "---"; echo "id: w"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"; } >"$pubmiss"
  SANITIZE_STUB_MODE="missing"; reset_stub_call_counts
  if ! stamp_sanitize_if_needed "$pubmiss" >/dev/null && ! grep -q "^sanitized:" "$pubmiss" \
    && grep -q "^sanitize_attempts: 1$" "$pubmiss"; then
    ok
  else
    ng "stamp_sanitize_if_needed: マーカー欠落時はスタンプなしだが attempts は分かる範囲でスタンプする (安全側の既定・決定12)"
  fi
  SANITIZE_STUB_MODE="pass"; reset_stub_call_counts

  # --- stamp_sanitize_if_needed: 練り直しループ「1回目 flagged → 練り直し → 2回目 pass」 ---
  # sanitize_attempts は「実施した監査回数」を数えるので、途中で pass になれば
  # そこまでの回数 (=2) で確定する。練り直しは1回だけ (RESANITIZE_CALL_FILE=1) 呼ばれる
  local flag2pass="$tmpdir/flag-then-pass.md" note
  {
    echo "---"; echo "id: fp1"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"
    echo ""; echo "## 理由"; echo "元の理由"; echo ""
    echo "## 変更内容"; echo '```append'; echo "original-content"; echo '```'
  } >"$flag2pass"
  SANITIZE_STUB_MODE="flagged pass"; RESANITIZE_STUB_MODE="ok"; reset_stub_call_counts
  if note=$(stamp_sanitize_if_needed "$flag2pass") \
    && printf '%s' "$note" | grep -q "sanitized: pass, sanitize_attempts: 2" \
    && grep -q "^sanitized: pass$" "$flag2pass" \
    && grep -q "^sanitize_attempts: 2$" "$flag2pass" \
    && grep -qF "resanitized-content-call-1" "$flag2pass" \
    && ! grep -qF "original-content" "$flag2pass" \
    && [ "$(cat "$RESANITIZE_CALL_FILE")" = "1" ]; then
    ok
  else
    ng "stamp_sanitize_if_needed: flagged→練り直し→pass で attempts=2・練り直し後の内容が反映される ($note)"
  fi

  # --- stamp_sanitize_if_needed: 練り直しループ「3回とも flagged」---
  # 監査は最大3回・練り直しは最大2回。3回目も flagged なら見送りにはせず、
  # 最後の (2回練り直した) 内容のまま sanitized: flagged で確定する
  local flag3="$tmpdir/flag-x3.md"
  {
    echo "---"; echo "id: f3"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"
    echo ""; echo "## 理由"; echo "元の理由"; echo ""
    echo "## 変更内容"; echo '```append'; echo "original-content"; echo '```'
  } >"$flag3"
  SANITIZE_STUB_MODE="flagged"; RESANITIZE_STUB_MODE="ok"; reset_stub_call_counts
  if note=$(stamp_sanitize_if_needed "$flag3") \
    && printf '%s' "$note" | grep -q "sanitized: flagged .*sanitize_attempts: 3" \
    && grep -q "^sanitized: flagged" "$flag3" \
    && grep -q "^sanitize_attempts: 3$" "$flag3" \
    && grep -qF "resanitized-content-call-2" "$flag3" \
    && [ "$(cat "$RESANITIZE_CALL_FILE")" = "2" ]; then
    ok
  else
    ng "stamp_sanitize_if_needed: flagged×3 で attempts=3・見送りにせず最後の内容のまま flagged 確定する ($note)"
  fi
  SANITIZE_STUB_MODE="pass"; RESANITIZE_STUB_MODE="ok"; reset_stub_call_counts

  # --- stamp_sanitize_if_needed: 練り直し自体が失敗 (PROPOSAL ブロック欠落) すると
  # 直前の flagged 判定のままその回数でスタンプして打ち切る (見送りにはしない) ---
  local flagresanifail="$tmpdir/flag-resani-fail.md"
  {
    echo "---"; echo "id: frf1"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"
    echo ""; echo "## 変更内容"; echo '```append'; echo "original-content"; echo '```'
  } >"$flagresanifail"
  SANITIZE_STUB_MODE="flagged"; RESANITIZE_STUB_MODE="missing-block"; reset_stub_call_counts
  if note=$(stamp_sanitize_if_needed "$flagresanifail") \
    && printf '%s' "$note" | grep -q "sanitize_attempts: 1" \
    && grep -q "^sanitize_attempts: 1$" "$flagresanifail" \
    && grep -qF "original-content" "$flagresanifail"; then
    ok
  else
    ng "stamp_sanitize_if_needed: 練り直し失敗時に直前の flagged のまま attempts をスタンプして打ち切る ($note)"
  fi
  SANITIZE_STUB_MODE="pass"; RESANITIZE_STUB_MODE="ok"; reset_stub_call_counts

  # --- process_proposal_block: supersedes 付与 ---
  local blkps out8 id8
  blkps="$tmpdir/blkp-supersedes.txt"
  make_prop_block "$blkps" "$REFLECT_HOME/dotfiles/CLAUDE.md" "claude-md" "supersedesテスト" "body"
  if out8=$(process_proposal_block "$blkps" "$sid" 27 "/cwd" "20260101-oldid-1") \
    && id8=$(printf '%s' "$out8" | sed -n 's/^提案: \([^ ]*\) .*/\1/p') \
    && grep -q "^supersedes: 20260101-oldid-1$" "$REFLECT_PROPOSALS_DIR/pending/$id8.md"; then
    ok
  else
    ng "process_proposal_block: supersedes 付与 ($out8)"
  fi

  # --- extract_change_content_section ---
  local ecfile="$tmpdir/change-content-mid.md"
  { echo "---"; echo "title: t"; echo "---"; echo ""; echo "## 理由"; echo "理由本文"; echo ""; \
    echo "## 変更内容"; echo "変更本文1"; echo "変更本文2"; echo ""; echo "## 備考"; echo "備考本文"; } >"$ecfile"
  if [ "$(extract_change_content_section "$ecfile")" = "$(printf '## 変更内容\n変更本文1\n変更本文2\n')" ]; then
    ok
  else
    ng "extract_change_content_section: 中間セクションの抽出 ($(extract_change_content_section "$ecfile"))"
  fi

  local eclast="$tmpdir/change-content-last.md"
  { echo "---"; echo "title: t"; echo "---"; echo ""; echo "## 理由"; echo "理由本文"; echo ""; \
    echo "## 変更内容"; echo "変更本文のみ"; } >"$eclast"
  if [ "$(extract_change_content_section "$eclast")" = "$(printf '## 変更内容\n変更本文のみ\n')" ]; then
    ok
  else
    ng "extract_change_content_section: 最終セクション (EOF まで) の抽出"
  fi

  local ecnone="$tmpdir/change-content-none.md"
  { echo "---"; echo "title: t"; echo "---"; echo ""; echo "## 理由"; echo "変更内容セクションなし"; } >"$ecnone"
  if [ -z "$(extract_change_content_section "$ecnone")" ]; then
    ok
  else
    ng "extract_change_content_section: セクション不在時は空文字"
  fi

  # --- build_sanitize_prompt / build_regenerate_prompt (純粋関数の組み立て内容) ---
  local sp rp
  sp=$(build_sanitize_prompt "TITLE_MARKER" "CHANGE_CONTENT_MARKER")
  if printf '%s' "$sp" | grep -qF "TITLE_MARKER" && printf '%s' "$sp" | grep -qF "CHANGE_CONTENT_MARKER" \
    && printf '%s' "$sp" | grep -qF "rules/sanitize-criteria.md"; then
    ok
  else
    ng "build_sanitize_prompt: title/変更内容と判定基準の出典パスが埋め込まれる"
  fi
  rp=$(build_regenerate_prompt "ORIG_CONTENT_MARKER" "TARGET_CONTENT_MARKER" "")
  if printf '%s' "$rp" | grep -qF "ORIG_CONTENT_MARKER" && printf '%s' "$rp" | grep -qF "TARGET_CONTENT_MARKER"; then
    ok
  else
    ng "build_regenerate_prompt: 元提案と target 現在内容が両方埋め込まれる"
  fi
  # note が空のときは指摘セクション自体を出さない (空欄をわざわざ見せない)
  if printf '%s' "$rp" | grep -qF "ユーザの指摘"; then
    ng "build_regenerate_prompt: note が空なら指摘セクションを出さない"
  else
    ok
  fi
  rp=$(build_regenerate_prompt "ORIG" "TARGET" "NOTE_MARKER")
  if printf '%s' "$rp" | grep -qF "NOTE_MARKER" \
    && printf '%s' "$rp" | grep -qF "ユーザの指摘" \
    && printf '%s' "$rp" | grep -qF "最優先の制約"; then
    ok
  else
    ng "build_regenerate_prompt: note 非空なら最優先の制約として独立セクションで再掲する"
  fi
  # note は元提案 frontmatter の後に置く (直近性を効かせるため末尾寄せ。順序が入れ替わると
  # 多数の frontmatter キーに埋もれる元の状態に戻ってしまう)
  # why sed -n 1p: 将来プロンプト文面にマーカーと同じ語が増えても複数行を拾って
  # [ -gt ] が構文エラーにならないよう先頭マッチに限る (head だと broken pipe になる)
  if [ "$(printf '%s' "$rp" | grep -nF "NOTE_MARKER" | cut -d: -f1 | sed -n 1p)" -gt \
       "$(printf '%s' "$rp" | grep -nF "TARGET" | cut -d: -f1 | sed -n 1p)" ]; then
    ok
  else
    ng "build_regenerate_prompt: note セクションは target 現在内容より後ろに置く"
  fi

  # kind: claude-md のときだけ claude-md-guide の事前ロードを課す (他 kind に出すと
  # 関係ないガイドを毎回読ませることになる)
  rp=$(build_regenerate_prompt "ORIG" "TARGET" "" "claude-md")
  if printf '%s' "$rp" | grep -qF "claude-md-guide" && printf '%s' "$rp" | grep -qF "必須の事前作業"; then
    ok
  else
    ng "build_regenerate_prompt: kind=claude-md なら claude-md-guide の事前ロードを課す"
  fi
  rp=$(build_regenerate_prompt "ORIG" "TARGET" "" "skill")
  if printf '%s' "$rp" | grep -qF "claude-md-guide"; then
    ng "build_regenerate_prompt: kind が claude-md 以外なら claude-md-guide を課さない"
  else
    ok
  fi
  rp=$(build_regenerate_prompt "ORIG" "TARGET" "" "")
  if printf '%s' "$rp" | grep -qF "claude-md-guide"; then
    ng "build_regenerate_prompt: kind が空なら claude-md-guide を課さない"
  else
    ok
  fi

  # --- decode_note_value (純粋関数) ---
  if [ "$(decode_note_value '"1 行目\n2 行目"')" = "$(printf '1 行目\n2 行目')" ]; then
    ok
  else
    ng "decode_note_value: JSON 文字列リテラルの \\n を改行にデコードする"
  fi
  if [ "$(decode_note_value '"引用符 \" とバックスラッシュ \\ を含む"')" = '引用符 " とバックスラッシュ \ を含む' ]; then
    ok
  else
    ng "decode_note_value: エスケープされた引用符・バックスラッシュをデコードする"
  fi
  if [ "$(decode_note_value 'plain text')" = "plain text" ]; then
    ok
  else
    ng "decode_note_value: 引用符で始まらない素の値はそのまま返す"
  fi
  if [ -z "$(decode_note_value '')" ]; then
    ok
  else
    ng "decode_note_value: 空値は空のまま返す"
  fi
  # 壊れた JSON (閉じ引用符なし) でも note を捨てず生値を返す
  if [ "$(decode_note_value '"閉じ忘れ')" = '"閉じ忘れ' ]; then
    ok
  else
    ng "decode_note_value: デコード不能なら生値をそのまま返す"
  fi

  # --- find_regenerate_proposals ---
  local regdir="$tmpdir/regen-pending" found_n
  mkdir -p "$regdir"
  { echo "---"; echo "id: r1"; echo "status: pending"; echo "target: /tmp/a.md"; echo "---"; } >"$regdir/r1.md"
  { echo "---"; echo "id: r2"; echo "status: regenerate"; echo "target: /tmp/b.md"; echo "---"; } >"$regdir/r2.md"
  { echo "---"; echo "id: r3"; echo "status: regenerate"; echo "target: /tmp/c.md"; echo "---"; } >"$regdir/r3.md"
  found_n=$(find_regenerate_proposals "$regdir" | wc -l | tr -d ' ')
  if [ "$found_n" = "2" ] \
    && find_regenerate_proposals "$regdir" | grep -q "r2.md" \
    && find_regenerate_proposals "$regdir" | grep -q "r3.md"; then
    ok
  else
    ng "find_regenerate_proposals: status: regenerate のみ抽出 (実際 ${found_n:-0} 件)"
  fi

  # --- finalize_regenerate_source ---
  local finf="$tmpdir/finalize-src.md" finarch="$tmpdir/finalize-arch"
  { echo "---"; echo "id: fin1"; echo "status: regenerate"; echo "target: /tmp/x.md"; echo "---"; } >"$finf"
  if finalize_regenerate_source "$finf" "$finarch" \
    && [ ! -e "$finf" ] \
    && grep -q "^status: superseded$" "$finarch/finalize-src.md"; then
    ok
  else
    ng "finalize_regenerate_source: superseded 化 + archive 移動"
  fi

  # --- process_regenerate_item: 正常系 (新提案の保存 + supersedes/sanitize伝播 + 元提案のarchive) ---
  mkdir -p "$REFLECT_PROPOSALS_DIR/pending"
  local regf="$REFLECT_PROPOSALS_DIR/pending/20260101-regtest-1.md"
  {
    echo "---"; echo "id: 20260101-regtest-1"; echo "status: regenerate"
    echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "title: 元提案タイトル"; echo "created: 2026-01-01"
    echo 'note: "調整して"'
    echo "---"; echo ""; echo "## 理由"; echo "旧理由"
  } >"$regf"

  local regout new_regid new_regfile
  REGENERATE_STUB_MODE="ok"
  if regout=$(process_regenerate_item "$regf") \
    && printf '%s' "$regout" | grep -q "^再提案: 20260101-regtest-1 -> " \
    && [ ! -e "$regf" ] \
    && [ -f "$REFLECT_PROPOSALS_DIR/archived/20260101-regtest-1.md" ] \
    && grep -q "^status: superseded$" "$REFLECT_PROPOSALS_DIR/archived/20260101-regtest-1.md"; then
    ok
  else
    ng "process_regenerate_item: 正常系 ($regout)"
  fi
  new_regid=$(printf '%s' "$regout" | sed -n 's/^再提案: [^ ]* -> \(.*\)$/\1/p')
  new_regfile="$REFLECT_PROPOSALS_DIR/pending/$new_regid.md"
  if [ -n "$new_regid" ] && [ -f "$new_regfile" ] \
    && grep -q "^supersedes: 20260101-regtest-1$" "$new_regfile" \
    && grep -q "^sanitized: pass$" "$new_regfile"; then
    ok
  else
    ng "process_regenerate_item: 新提案への supersedes/sanitize スタンプ伝播 ($new_regid)"
  fi

  # --- process_regenerate_item: PROPOSAL ブロック欠落 -> 元提案は regenerate のまま残置 ---
  local regf2="$REFLECT_PROPOSALS_DIR/pending/20260101-regtest-2.md" regout2
  {
    echo "---"; echo "id: 20260101-regtest-2"; echo "status: regenerate"
    echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "title: t2"; echo "created: 2026-01-01"
    echo "---"; echo ""; echo "## 理由"; echo "x"
  } >"$regf2"
  REGENERATE_STUB_MODE="missing-block"
  if regout2=$(process_regenerate_item "$regf2"); then
    ng "process_regenerate_item: ブロック欠落なのに成功扱いになった"
  elif [ -f "$regf2" ] && grep -q "^status: regenerate$" "$regf2" && printf '%s' "$regout2" | grep -q "再提案失敗"; then
    ok
  else
    ng "process_regenerate_item: ブロック欠落時に元提案が regenerate のまま残らない ($regout2)"
  fi

  # --- process_regenerate_item: 新提案の保存失敗 (target 不正) -> 元提案は regenerate のまま残置 ---
  local regf3="$REFLECT_PROPOSALS_DIR/pending/20260101-regtest-3.md" regout3
  {
    echo "---"; echo "id: 20260101-regtest-3"; echo "status: regenerate"
    echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "title: t3"; echo "created: 2026-01-01"
    echo "---"; echo ""; echo "## 理由"; echo "x"
  } >"$regf3"
  REGENERATE_STUB_MODE="save-fail"
  if regout3=$(process_regenerate_item "$regf3"); then
    ng "process_regenerate_item: 保存失敗ケースなのに成功扱いになった"
  elif [ -f "$regf3" ] && grep -q "^status: regenerate$" "$regf3" && printf '%s' "$regout3" | grep -q "再提案失敗"; then
    ok
  else
    ng "process_regenerate_item: 保存失敗時に元提案が regenerate のまま残らない ($regout3)"
  fi
  REGENERATE_STUB_MODE="ok"

  # --- process_regenerate_item: REFLECT_DRY_RUN では claude 呼び出し・書き込みをしない ---
  local regf4="$REFLECT_PROPOSALS_DIR/pending/20260101-regtest-4.md" regout4
  {
    echo "---"; echo "id: 20260101-regtest-4"; echo "status: regenerate"
    echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "title: t4"; echo "created: 2026-01-01"
    echo "---"; echo ""; echo "## 理由"; echo "x"
  } >"$regf4"
  if regout4=$(REFLECT_DRY_RUN=1 process_regenerate_item "$regf4") \
    && printf '%s' "$regout4" | grep -q "dry-run" \
    && [ -f "$regf4" ] && grep -q "^status: regenerate$" "$regf4"; then
    ok
  else
    ng "process_regenerate_item: DRY_RUN で書き込み/claude 呼び出しが発生した ($regout4)"
  fi

  # --- run_regenerate_cycle: 対象複数件をまとめて処理し inbox に記録、対象外は触らない ---
  local REFLECT_PROPOSALS_DIR="$tmpdir/proposals-cycle" INBOX="$tmpdir/inbox-cycle.md"
  mkdir -p "$REFLECT_PROPOSALS_DIR/pending"
  {
    echo "---"; echo "id: 20260101-cycle-1"; echo "status: regenerate"
    echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "title: cycle1"; echo "created: 2026-01-01"
    echo "---"; echo ""; echo "## 理由"; echo "x"
  } >"$REFLECT_PROPOSALS_DIR/pending/20260101-cycle-1.md"
  {
    echo "---"; echo "id: 20260101-cycle-2"; echo "status: pending"
    echo "target: $REFLECT_HOME/dotfiles/other.md"; echo "title: cycle2(regenerate対象外)"; echo "created: 2026-01-01"
    echo "---"; echo ""; echo "body"
  } >"$REFLECT_PROPOSALS_DIR/pending/20260101-cycle-2.md"

  REGENERATE_STUB_MODE="ok"
  run_regenerate_cycle
  if [ -f "$REFLECT_PROPOSALS_DIR/archived/20260101-cycle-1.md" ] \
    && [ -f "$REFLECT_PROPOSALS_DIR/pending/20260101-cycle-2.md" ] \
    && grep -q "^status: pending$" "$REFLECT_PROPOSALS_DIR/pending/20260101-cycle-2.md" \
    && grep -qF "再提案サイクル" "$INBOX" \
    && grep -qF "20260101-cycle-1" "$INBOX"; then
    ok
  else
    ng "run_regenerate_cycle: regenerate 対象のみ処理して inbox に記録する"
  fi

  echo "self-test: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

REGEN_ONLY=0
[ "${1:-}" = "--regenerate-only" ] && REGEN_ONLY=1

exec >>"$LOG" 2>&1

# 多重起動ガード (launchd の catch-up と手動実行の重なり防止。--regenerate-only の
# 手動即時実行とも共用する。決定13a)。
# why PID 生存判定: 経過時間だけで stale と断ずると、claude のハング等で
# 長時間残っている「生きた」ドライバから lock を奪い、同じ queue を
# 二重処理して memory・提案を重複保存してしまう
LOCK="$STATE_DIR/lock"
if [ -d "$LOCK" ]; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    log "既に実行中 (pid=$lock_pid)。終了"
    if [ "$REGEN_ONLY" -eq 1 ]; then
      # why exit 75 (EX_TEMPFAIL): 呼び出し元 (常設ビューア等) が「実行中」を
      # 判別するのに使える固有の exit code が要る。0/1 の一般終了と区別する
      echo "run-headless.sh --regenerate-only: 既に実行中のため起動できません (pid=$lock_pid)" >&2
      exit 75
    fi
    # 決定20-i: 通常runがlockで即終了する場合、朝の処理欠落確認用に
    # inbox へ記録する (この時点では INBOX 追記の失敗は終了を妨げない)
    {
      echo ""
      echo "## $(date '+%Y-%m-%d') lock skip"
      echo ""
      echo "$(date '+%Y-%m-%d %H:%M:%S') lock 中のため夜間 run をスキップ（保持 PID $lock_pid）"
    } >>"$INBOX" 2>/dev/null || true
    exit 0
  fi
  log "stale lock を除去 (pid=${lock_pid:-記録なし} は生存していない)"
  rm -rf "$LOCK"
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "lock 取得競合。終了"
  if [ "$REGEN_ONLY" -eq 1 ]; then
    echo "run-headless.sh --regenerate-only: lock 取得競合のため起動できません" >&2
    exit 75
  fi
  {
    echo ""
    echo "## $(date '+%Y-%m-%d') lock skip"
    echo ""
    echo "$(date '+%Y-%m-%d %H:%M:%S') lock 中のため夜間 run をスキップ（保持 PID 不明・取得競合）"
  } >>"$INBOX" 2>/dev/null || true
  exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

log "=== run 開始 (model=$MODEL dry_run=${REFLECT_DRY_RUN:-0} regen_only=$REGEN_ONLY) ==="

# 再提案サイクル (決定13/13a): 通常runはqueue処理の前に、--regenerate-onlyはこれだけ
# 実行して終了する
run_regenerate_cycle

if [ "$REGEN_ONLY" -eq 1 ]; then
  log "=== --regenerate-only run 終了 ==="
  exit 0
fi

# queue を processing に切り出して直列処理。
# why rename 方式: 処理中も SessionEnd hook は queue へ append し続ける。
# 「読み終わってから圧縮結果を mv で書き戻す」方式は読了〜mv の間の append を
# 黙って消す race があるため、先に queue 自体を atomic rename で切り出し、
# 以後 queue には触らない (リトライ分だけ追記する)
if [ -f "$PROCESSING" ]; then
  # 前回クラッシュの残骸。queue に戻して合流 (done フィルタが二重処理を防ぐ)
  log "前回の processing 残骸を queue へ戻す"
  cat "$PROCESSING" >>"$QUEUE"
  rm -f "$PROCESSING"
fi

# この run で新規保存できた提案の件数 (DRY_RUN 中は増やさない)。
# run 終了時の macOS 通知はここを見て「新着があるときだけ」出す
new_proposal_count=0

if [ ! -f "$QUEUE" ]; then
  log "queue なし"
else
  mv "$QUEUE" "$PROCESSING"

  # why fd 3: ループ内の claude / gh が stdin を継承すると processing 本体を
  # 食い進めてしまうので、読み出しを専用 fd に隔離する
  while IFS= read -r entry <&3; do
    [ -n "$entry" ] || continue
    sid=$(jq -r '.session_id // empty' <<<"$entry" 2>/dev/null)
    if [ -z "$sid" ]; then
      # 不正 JSON を残すと永遠に再処理も破棄もされないので、ログに残して捨てる
      log "不正な queue 行を破棄: $entry"
      continue
    fi
    path=$(jq -r '.path // empty' <<<"$entry")
    cwd=$(jq -r '.cwd // empty' <<<"$entry")
    # why 可視化: cwd が空だと memory_path_ok の cross-project チェック
    # (expected_seg) が無条件で skip される。無効化されていること自体は
    # 従来の(cwd無し)動作への fallback で意図通りだが、気づけないと
    # 「有効なつもりで実は無効」という状態が運用上見えなくなる
    [ -n "$cwd" ] || log "$sid: queue entry に cwd が無く、memory の cross-project チェックを無効化"

    if [ ! -f "$path" ]; then
      log "$sid: transcript 消失 ($path)。done 扱い"
      mark_done "$sid"
      continue
    fi

    # 読取失敗を 0 行と誤認すると「成長なし」として黙って捨ててしまうので requeue
    if ! cur_lines=$(wc -l <"$path" 2>/dev/null); then
      log "$sid: transcript 読取失敗。queue へ戻して次回リトライ"
      printf '%s\n' "$entry" >>"$QUEUE"
      continue
    fi
    # done 記録行数と比較し、閾値以上伸びていれば差分再処理、それ以外は skip
    # (算術展開は wc 出力の先頭空白を落とすため)
    cur_lines=$((cur_lines))
    recorded=$(done_lines_of "$sid")
    since_arg=""
    if [ -n "$recorded" ]; then
      [ "$recorded" = "inf" ] && continue
      # hook と同じ成長閾値を適用 (クラッシュ残骸の合流 entry が数行の成長で
      # フル claude 起動を焼くのを防ぐ)
      [ $((cur_lines - recorded)) -ge "$MIN_GROWTH" ] || continue
      [ "$recorded" -gt 0 ] && since_arg=" --since-line $recorded"
    fi

    log "$sid: 処理開始 ($path)${since_arg:+ [再処理: $recorded 行以降の差分]}"
    # why cd $REFLECT_CWD: ヘッドレスでは cwd + additionalDirectories だけが読める。
    # REFLECT_CWD が指す専用プロジェクトの settings.json が持つ read-only
    # additionalDirectories 越しに target リポジトリ本体・SKILL.md 群
    # (シンボリックリンク経由) が読める。transcript (~/.claude/projects/) は
    # グローバル設定の additionalDirectories (~/.claude) で読める
    # why perl alarm: macOS に timeout(1) がない。ハングすると lock を握ったまま
    # 翌晩以降も塞ぐので上限必須 (SIGALRM で claude ごと落とす)
    out=$(cd "$REFLECT_CWD" && REFLECT_HEADLESS=1 \
      perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT_SEC" \
      "$CLAUDE_BIN" -p "/reflect --auto $path$since_arg" \
      --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
    rc=$?

    if [ $rc -ne 0 ]; then
      echo "$sid" >>"$ATTEMPTS"
      if [ "$(attempts_of "$sid")" -ge "$MAX_ATTEMPTS" ]; then
        log "$sid: claude 失敗 (exit=$rc) が $MAX_ATTEMPTS 回目。hold へ"
        printf '%s\n' "$out" >"$HOLD/$sid-error.txt"
        # why ブレース必須: 直後が全角文字だと bash が変数名境界を誤認識する
        # watermark は前回値のまま (抽出に成功していない範囲を「処理済み」に
        # すると、以後の --since-line がその範囲のシグナルを恒久に落とすため。
        # 次に transcript が伸びたラウンドで失敗範囲ごと再挑戦される)
        inbox_append "$(date '+%Y-%m-%d') $sid" <<<"処理失敗 x${MAX_ATTEMPTS}。hold/$sid-error.txt を確認"
        mark_done "$sid" "${recorded:-0}"
      else
        log "$sid: claude 失敗 (exit=$rc)。queue へ戻して次回リトライ"
        printf '%s\n' "$entry" >>"$QUEUE"
      fi
      continue
    fi

    summary=$(extract_block SUMMARY <<<"$out")
    if [ -z "$summary" ]; then
      # マーカーなし = スキルが指示に従えていない。誤投稿より保留に倒す
      log "$sid: SUMMARY マーカーなし (パース不能)。hold へ"
      printf '%s\n' "$out" >"$HOLD/$sid-parse-error.txt"
      # watermark は前回値のまま (理由は失敗パスと同じ)
      inbox_append "$(date '+%Y-%m-%d') $sid" <<<"出力がパース不能。hold/$sid-parse-error.txt を確認"
      mark_done "$sid" "${recorded:-0}"
      continue
    fi

    mem_result=""
    mem_dir=$(mktemp -d "${TMPDIR:-/tmp/}reflect-mem-XXXXXX")
    split_memory_blocks "$mem_dir" <<<"$out"
    for mf in "$mem_dir"/mem-*; do
      [ -f "$mf" ] || continue
      n="${mf##*/mem-}"
      mem_line=$(process_memory_block "$mf" "$sid" "$n" "$cwd")
      mem_result="${mem_result}${mem_line}
"
    done
    rm -rf "$mem_dir"

    prop_result=""
    prop_dir=$(mktemp -d "${TMPDIR:-/tmp/}reflect-prop-XXXXXX")
    split_proposal_blocks "$prop_dir" <<<"$out"
    for pf in "$prop_dir"/prop-*; do
      [ -f "$pf" ] || continue
      n="${pf##*/prop-}"
      # why 戻り値で成否判定: process_proposal_block は 0=保存/dry-run・1=hold を
      # 返す。出力文言 ("^提案: ") に依存すると、文言変更で通知カウントが黙って
      # 0 になり得る。DRY_RUN の除外は外側の判定が担う (dry-run も rc=0 のため)
      if prop_line=$(process_proposal_block "$pf" "$sid" "$n" "$cwd"); then
        prop_rc=0
      else
        prop_rc=1
      fi
      prop_result="${prop_result}${prop_line}
"
      if [ "${REFLECT_DRY_RUN:-}" != "1" ] && [ "$prop_rc" -eq 0 ]; then
        new_proposal_count=$((new_proposal_count + 1))
      fi
    done
    rm -rf "$prop_dir"

    {
      printf '%s\n' "$summary"
      [ -n "$mem_result" ] && printf '\n%s' "$mem_result"
      [ -n "$prop_result" ] && printf '\n%s' "$prop_result"
    } | inbox_append "$(date '+%Y-%m-%d') $sid ($cwd)"
    mark_done "$sid" "$cur_lines"
    log "$sid: 完了"
  done 3<"$PROCESSING"

  rm -f "$PROCESSING"
fi

# (低優先・設計書 §3.5) 新規提案があれば 1 回だけ通知。DRY_RUN 中は書き込みも
# していないので通知しない。失敗しても run 自体は継続してよいので || true
if [ "${REFLECT_DRY_RUN:-}" != "1" ] && [ "$new_proposal_count" -gt 0 ]; then
  osascript -e "display notification \"新規提案 ${new_proposal_count} 件\" with title \"reflect\"" || true
fi

log "=== run 終了 ==="
