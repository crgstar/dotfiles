#!/bin/bash
# 無人 reflect ドライバ (launchd: com.crgstar.reflect が夜間起動)。
# queue.jsonl を 1 件ずつ直列処理し、ヘッドレス claude に /reflect --auto を
# 実行させ、stdout のマーカーをパースして issue 投稿・保留保存・朝サマリ追記を行う。
#
# 権限設計 (outbox パターン): ヘッドレスの claude には書き込み権限を一切与えず、
# 結果はマーカー付き stdout だけで受け取る。gh api POST・ファイル保存・再送は
# すべてこのスクリプト (claude の外) が担う。悪性 transcript がモデルを操っても
# 投稿先・API 形はここに固定されていて変えられない。
#
# 環境変数 (すべて検証用の上書き口。通常は未設定でよい):
#   REFLECT_STATE_DIR  状態ディレクトリ (default: ~/.local/state/reflect)
#   REFLECT_CLAUDE_BIN claude 実体 (default: ~/.local/bin/claude)
#   REFLECT_INBOX      朝サマリの追記先 (default: ~/dotfiles/.local/reflect-inbox.md)
#   REFLECT_ISSUE_REPO issue 投稿先 (default: crgstar/dotfiles)
#   REFLECT_MODEL      ヘッドレスのモデル (default: sonnet)
#   REFLECT_TIMEOUT    claude 1 件あたりの上限秒 (default: 3600)
#   REFLECT_MIN_GROWTH 差分再処理とみなす最小成長行数 (default: 50。hook と共有)
#   REFLECT_DRY_RUN    1 なら gh api POST・sanitize監査・再提案のclaude呼び出し・
#                       実書き込みをせずログに出すだけ
#   REFLECT_SANITIZE_TIMEOUT   ③ (dotfiles宛) 提案の sanitize 監査 1 件あたりの上限秒
#                       (default: 300)
#   REFLECT_REGENERATE_TIMEOUT 再提案 (regenerate) 1 件あたりの上限秒
#                       (default: REFLECT_TIMEOUT と同じ)
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
OUTBOX="$STATE_DIR/outbox"
ATTEMPTS="$STATE_DIR/attempts"
LOG="$STATE_DIR/run.log"
INBOX="${REFLECT_INBOX:-$HOME/dotfiles/.local/reflect-inbox.md}"
CLAUDE_BIN="${REFLECT_CLAUDE_BIN:-$HOME/.local/bin/claude}"
ISSUE_REPO="${REFLECT_ISSUE_REPO:-crgstar/dotfiles}"
MODEL="${REFLECT_MODEL:-sonnet}"
TIMEOUT_SEC="${REFLECT_TIMEOUT:-3600}"
MIN_GROWTH="${REFLECT_MIN_GROWTH:-50}"
SANITIZE_TIMEOUT_SEC="${REFLECT_SANITIZE_TIMEOUT:-300}"
REGEN_TIMEOUT_SEC="${REFLECT_REGENERATE_TIMEOUT:-$TIMEOUT_SEC}"
DOTFILES_DIR="$HOME/dotfiles"
# why 単一定義: extract_block と split_blocks (memory/proposal 共通) の状態機械は
# 同じタグ集合を見ないと「片方だけが開始マーカーを認識する」ずれが起き、引用と
# 実ブロックの判定が関数間で食い違う。タグ追加時はここだけ変える
REFLECT_TAGS='OUTBOX|HOLD|SUMMARY|MEMORY|PROPOSAL'
# why 2 回で打ち切り: 同じ transcript で毎晩失敗し続けると token を無限に燃やす。
# 2 回失敗した entry は hold に落として人間判断に回す
MAX_ATTEMPTS=2

# why PATH を明示: launchd 起動時の PATH は /usr/bin:/bin 系の最小構成で、
# gh (homebrew) や claude (~/.local/bin) が見えない
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin"

mkdir -p "$STATE_DIR" "$HOLD" "$OUTBOX" "$(dirname "$INBOX")"

# why stderr 出力: post_issue 等は $(...) で stdout を捕まえられるので、
# stdout に log を混ぜると戻り値 (issue URL) に混入する
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
  # 例示を含む transcript 等) を新規ブロック開始として拾うと、HOLD に隔離した
  # 内容の一部を OUTBOX として投稿しうる。「最初に開いたブロックが閉じるまで、
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

memory_path_ok() { # $1=path。許可条件をすべて満たすときだけ 0 (純粋関数)
  local path="$1" root rest seg1 rest2 fname
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

process_memory_block() { # $1=blockfile $2=sid $3=n。結果行を stdout に 1 行 (成否は戻り値)
  local blockfile="$1" sid="$2" n="$3"
  local mode="" file="" index="" fname="" header_done=0 line body_file fail=""
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
  [ -n "$fail" ] || memory_path_ok "$file" || fail="許可パス外の file: $file"
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

target_is_public_dotfiles() { # $1=絶対パス。$HOME/dotfiles/ 配下 (= ③ PUBLIC リポ宛) なら 0 (純粋関数)
  # why REFLECT_HOME 経由: derive_repo と同じ流儀で self-test から差し替え可能にする
  local path="$1" home="${REFLECT_HOME:-$HOME}"
  case "$path" in
    "$home"/dotfiles/*) return 0 ;;
    *) return 1 ;;
  esac
}

insert_sanitized_line() { # $1=提案ファイル $2=値 ("pass" または "flagged <理由>")。
  # created: 行の直後に "sanitized: <値>" を挿入する (原子的。他の行は変更しない)
  local file="$1" value="$2" tmp
  tmp=$(mktemp "$(dirname "$file")/.reflect-sanitize-XXXXXX") || return 1
  if ! awk -v val="$value" '
    { print }
    $0 ~ /^created:/ && !done { print "sanitized: " val; done = 1 }
  ' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

build_sanitize_prompt() { # $1=提案ファイル全文。stdout=ヘッドレス claude への監査プロンプト (純粋関数)
  cat <<'EOF'
以下はローカルで生成された提案ファイル (dotfiles 配下の PUBLIC ファイルへの変更提案) です。
まず ~/dotfiles/.claude/skills/process-retro/SKILL.md の §3.3(b) を読み、そこに書かれた
サニタイズ判定基準 (絶対パス・組織名/他人の名前・秘密情報・作業リポ固有の識別子の混入
有無) をそのまま適用してください。

判定対象は次の提案ファイル全文です (frontmatter を含む):
----- BEGIN PROPOSAL FILE -----
EOF
  printf '%s\n' "$1"
  cat <<'EOF'
----- END PROPOSAL FILE -----

出力は次のいずれか1行のみとしてください。説明・前置き・後書きは一切書かないこと:
REFLECT-SANITIZE: pass
REFLECT-SANITIZE: flagged <漏洩理由を一行で>
EOF
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
  (cd "$DOTFILES_DIR" && REFLECT_HEADLESS=1 \
    perl -e 'alarm shift @ARGV; exec @ARGV' "$SANITIZE_TIMEOUT_SEC" \
    "$CLAUDE_BIN" -p "$1" --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
}

stamp_sanitize_if_needed() { # $1=保存済み提案ファイルの絶対パス。
  # target が ③ (dotfiles配下) のときだけ sanitize 監査を実行し frontmatter に
  # sanitized: pass|flagged をスタンプする (決定12)。stdout: 呼び出し元の結果行に
  # そのまま連結できる " (...)" 形の注記 (③以外は空文字)。監査失敗・マーカー欠落は
  # スタンプを書かない (安全側の既定。決定12) が、提案の保存自体は失敗にしない
  local file="$1" target raw parsed value
  target=$(frontmatter_value "$file" target)
  target_is_public_dotfiles "$target" || { echo ""; return 0; }

  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    echo " (dry-run: sanitize 未実施)"
    return 0
  fi

  raw=$(invoke_sanitize_claude "$(build_sanitize_prompt "$(cat "$file")")")
  parsed=$(printf '%s\n' "$raw" | parse_sanitize_marker)

  case "$parsed" in
    pass)
      if insert_sanitized_line "$file" "pass"; then
        echo " (sanitized: pass)"
        return 0
      fi
      log "$file: sanitized 行の挿入に失敗"
      echo " (sanitize 判定 pass だがスタンプ書き込み失敗)"
      return 1
      ;;
    flagged*)
      value="$parsed"
      if insert_sanitized_line "$file" "$value"; then
        echo " (sanitized: $value)"
        return 0
      fi
      log "$file: sanitized 行の挿入に失敗"
      echo " (sanitize 判定 flagged だがスタンプ書き込み失敗)"
      return 1
      ;;
    *)
      log "$file: sanitize 監査失敗またはマーカー欠落。スタンプなし (自動処理対象外のまま)"
      echo " (sanitize 監査失敗: スタンプなし。自動処理対象外のまま)"
      return 1
      ;;
  esac
}

process_proposal_block() { # $1=blockfile $2=sid $3=n $4=cwd $5=supersedes(省略可)。結果行を stdout に1行 (成否は戻り値)
  local blockfile="$1" sid="$2" n="$3" cwd="$4" supersedes="${5:-}"
  local target="" kind="" title="" header_done=0 line body_file fail=""
  body_file=$(mktemp "${TMPDIR:-/tmp/}reflect-prop-body-XXXXXX")

  # why ヘッダ読取: process_memory_block と同じ流儀。target/kind/title は
  # 先頭の "---" 行までのメタデータ、それ以降 (## 理由 / ## 変更例) は
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

build_regenerate_prompt() { # $1=元提案ファイル全文(frontmatter込み) $2=targetの現在の内容
  # stdout=ヘッドレスへの再生成プロンプト (純粋関数)
  cat <<'EOF'
/reflect の再提案 (regenerate) モードとして動いてください。SKILL.md の
「§6a. 再提案 (regenerate) モード」に書かれたルールに従い、次の元提案と target の
現在の内容を踏まえて変更例を作り直し、REFLECT-PROPOSAL ブロックをちょうど1個だけ
返してください。それ以外の文章・前置き・後書きは書かないこと。

----- 元提案 (frontmatter + 本文) -----
EOF
  printf '%s\n' "$1"
  cat <<'EOF'
----- target の現在の内容 -----
EOF
  printf '%s\n' "$2"
  echo "----- (以上) -----"
}

invoke_regenerate_claude() { # $1=プロンプト全文。stdout=claude 生出力 (副作用。self_test で差し替え可能)
  (cd "$DOTFILES_DIR" && REFLECT_HEADLESS=1 \
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
  local file="$1" proposals_dir archdir old_id old_target orig_content target_content
  local prompt raw block tmp_block sid save_out new_id

  proposals_dir="${REFLECT_PROPOSALS_DIR:-$HOME/dotfiles/.local/reflect-proposals}"
  archdir="$proposals_dir/archived"
  old_id=$(basename "$file" .md)
  old_target=$(frontmatter_value "$file" target)
  orig_content=$(cat "$file")

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

  prompt=$(build_regenerate_prompt "$orig_content" "$target_content")
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

  if save_out=$(process_proposal_block "$tmp_block" "$sid" 1 "$DOTFILES_DIR" "$old_id"); then
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

post_issue() { # $1=outbox ファイル (1 行目 "title: ...", 2 行目以降が本文)。成功で issue URL を出力
  local f="$1" title body_file url rc
  title=$(head -n1 "$f" | sed 's/^title: //')
  [ -n "$title" ] || { log "outbox の title が空: $f"; return 1; }
  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    log "DRY_RUN: issue 投稿をスキップ ($f: $title)"
    echo "(dry-run)"
    return 0
  fi
  body_file=$(mktemp "${TMPDIR:-/tmp/}reflect-body-XXXXXX")
  tail -n +2 "$f" >"$body_file"
  url=$(gh api --method POST "/repos/$ISSUE_REPO/issues" \
    -f title="$title" -F body=@"$body_file" --jq .html_url)
  rc=$?
  rm -f "$body_file"
  [ $rc -eq 0 ] && echo "$url"
  return $rc
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

# why ここで定義: self_test (直後) や run_regenerate_cycle は post_issue は
# 使わないが inbox_append を使う。self-test 起動は exec によるログ差し替えより
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
  # (完了条件「実データに触れない」の一部)。sanitize/regenerate の
  # 呼び出し関数をここで上書きし、$SANITIZE_STUB_MODE / $REGENERATE_STUB_MODE
  # (どちらも下の local 変数。動的スコープで見える) で挙動を切り替える
  local SANITIZE_STUB_MODE="pass"
  invoke_sanitize_claude() {
    case "$SANITIZE_STUB_MODE" in
      pass) echo "REFLECT-SANITIZE: pass" ;;
      flagged) echo "REFLECT-SANITIZE: flagged 機密情報の疑いを検知" ;;
      missing) echo "説明文だけでマーカーがない出力" ;;
      *) echo "REFLECT-SANITIZE: pass" ;;
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

## 変更例

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
    $'## 理由\nテスト理由\n\n## 変更例\n\n```append\nhello\n```'
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

  local pubflag="$tmpdir/pubflag-test.md"
  { echo "---"; echo "id: z"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"; } >"$pubflag"
  SANITIZE_STUB_MODE="flagged"
  if stamp_sanitize_if_needed "$pubflag" | grep -q "sanitized: flagged" && grep -q "^sanitized: flagged" "$pubflag"; then
    ok
  else
    ng "stamp_sanitize_if_needed: flagged 判定のスタンプ"
  fi
  SANITIZE_STUB_MODE="pass"

  local pubmiss="$tmpdir/pubmiss-test.md"
  { echo "---"; echo "id: w"; echo "target: $REFLECT_HOME/dotfiles/CLAUDE.md"; echo "created: 2026-07-15"; echo "---"; } >"$pubmiss"
  SANITIZE_STUB_MODE="missing"
  if ! stamp_sanitize_if_needed "$pubmiss" >/dev/null && ! grep -q "^sanitized:" "$pubmiss"; then
    ok
  else
    ng "stamp_sanitize_if_needed: マーカー欠落時はスタンプなし (安全側の既定・決定12)"
  fi
  SANITIZE_STUB_MODE="pass"

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

  # --- build_sanitize_prompt / build_regenerate_prompt (純粋関数の組み立て内容) ---
  local sp rp
  sp=$(build_sanitize_prompt "SANITIZE_INPUT_MARKER")
  if printf '%s' "$sp" | grep -qF "SANITIZE_INPUT_MARKER" && printf '%s' "$sp" | grep -qF "process-retro/SKILL.md"; then
    ok
  else
    ng "build_sanitize_prompt: 入力内容と判定基準の出典パスが埋め込まれる"
  fi
  rp=$(build_regenerate_prompt "ORIG_CONTENT_MARKER" "TARGET_CONTENT_MARKER")
  if printf '%s' "$rp" | grep -qF "ORIG_CONTENT_MARKER" && printf '%s' "$rp" | grep -qF "TARGET_CONTENT_MARKER"; then
    ok
  else
    ng "build_regenerate_prompt: 元提案と target 現在内容が両方埋め込まれる"
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
# 二重処理して issue を重複投稿してしまう
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

log "=== run 開始 (model=$MODEL repo=$ISSUE_REPO dry_run=${REFLECT_DRY_RUN:-0} regen_only=$REGEN_ONLY) ==="

# 再提案サイクル (決定13/13a): 通常runはqueue処理の前に、--regenerate-onlyはこれだけ
# 実行して終了する
run_regenerate_cycle

if [ "$REGEN_ONLY" -eq 1 ]; then
  log "=== --regenerate-only run 終了 ==="
  exit 0
fi

# 1) 前回投稿に失敗した outbox の再送
for f in "$OUTBOX"/*.md; do
  [ -f "$f" ] || continue
  if url=$(post_issue "$f"); then
    log "outbox 再送成功: $f -> $url"
    inbox_append "$(date '+%Y-%m-%d') 再送 $(basename "$f" .md)" <<<"issue: $url"
    rm -f "$f"
  else
    log "outbox 再送失敗 (次回また試す): $f"
  fi
done

# 2) queue を processing に切り出して直列処理。
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
    # why cd $DOTFILES_DIR: ヘッドレスでは cwd + additionalDirectories (~/.claude)
    # だけが読める。dotfiles を cwd にすると SKILL.md 群と transcript
    # (~/.claude/projects/) の両方が追加権限なしで読める。
    # why perl alarm: macOS に timeout(1) がない。ハングすると lock を握ったまま
    # 翌晩以降も塞ぐので上限必須 (SIGALRM で claude ごと落とす)
    out=$(cd "$DOTFILES_DIR" && REFLECT_HEADLESS=1 \
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

    status_line=""
    hold_block=$(extract_block HOLD <<<"$out")
    outbox_block=$(extract_block OUTBOX <<<"$out")
    if [ -n "$hold_block" ]; then
      # §6 の契約で HOLD と OUTBOX は排他。両方来たら全体を保留に倒す
      # (監査で止めた内容の取りこぼし投稿を防ぐ)
      {
        printf '%s\n' "$hold_block"
        if [ -n "$outbox_block" ]; then
          printf '\n--- 同時に返された OUTBOX (契約違反のため投稿していない) ---\n%s\n' "$outbox_block"
        fi
      } >"$HOLD/$sid.md"
      log "$sid: 監査保留 -> hold/$sid.md"
      status_line="監査保留: hold/$sid.md"
    elif [ -n "$outbox_block" ]; then
      printf '%s\n' "$outbox_block" >"$OUTBOX/$sid.md"
      if url=$(post_issue "$OUTBOX/$sid.md"); then
        log "$sid: issue 投稿成功 -> $url"
        rm -f "$OUTBOX/$sid.md"
        status_line="issue: $url"
      else
        log "$sid: issue 投稿失敗。outbox に保持し次回再送"
        status_line="issue 投稿失敗 (outbox 再送待ち)"
      fi
    fi

    # memory ブロックは HOLD/OUTBOX の有無と独立に処理する (A の漏洩ガードと
    # B のローカル書き込みは blast radius が別物)
    mem_result=""
    mem_dir=$(mktemp -d "${TMPDIR:-/tmp/}reflect-mem-XXXXXX")
    split_memory_blocks "$mem_dir" <<<"$out"
    for mf in "$mem_dir"/mem-*; do
      [ -f "$mf" ] || continue
      n="${mf##*/mem-}"
      mem_line=$(process_memory_block "$mf" "$sid" "$n")
      mem_result="${mem_result}${mem_line}
"
    done
    rm -rf "$mem_dir"

    # proposal ブロックも HOLD/OUTBOX の有無と独立に処理する (設計書 §3.4:
    # B はローカル副作用のみで blast radius が別物。memory と同じ位置で処理する)
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
      [ -n "$status_line" ] && printf '\n%s\n' "$status_line"
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
