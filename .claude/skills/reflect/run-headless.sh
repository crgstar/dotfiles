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
#   REFLECT_DRY_RUN    1 なら gh api POST せずログに出すだけ

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
DOTFILES_DIR="$HOME/dotfiles"
# why 単一定義: extract_block と split_memory_blocks の状態機械は同じタグ集合を
# 見ないと「片方だけが開始マーカーを認識する」ずれが起き、引用と実ブロックの
# 判定が関数間で食い違う。タグ追加時はここだけ変える
REFLECT_TAGS='OUTBOX|HOLD|SUMMARY|MEMORY'
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

split_memory_blocks() { # $1=outdir stdin=claude 出力。REFLECT-MEMORY を 1 件 1 ファイル (mem-N) に分割
  # why extract_block とは別関数: MEMORY は同一出力に複数件来る。タグ内容を
  # 連結して素通しする extract_block では 1 件目と 2 件目が結合されてしまうため、
  # open ごとに出力先ファイルを切り替える。状態機械の性質 (最初に開いたブロックが
  # 閉じるまで他の開始マーカーは本文扱い) は extract_block と同じにする
  local outdir="$1"
  awk -v outdir="$outdir" -v tags="$REFLECT_TAGS" '
    inblk == "" && $0 ~ ("^<<<REFLECT-(" tags ")$") {
      tag = substr($0, 4)
      inblk = tag
      if (tag == "REFLECT-MEMORY") {
        n++; outfile = outdir "/mem-" n
        # why 空ファイルの実体化: 本文 0 行のブロックは print が一度も走らず
        # ファイル自体が生まれない = hold にも log にも痕跡が残らず消える。
        # 空でも実体を作れば process_memory_block の検証で hold に落ちる
        printf "" > outfile
      }
      next
    }
    inblk != "" && $0 == inblk ">>>" { inblk = ""; next }
    inblk == "REFLECT-MEMORY" { print > outfile }
  '
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
      mode:*) mode="${line#mode:}"; mode="${mode# }" ;;
      file:*) file="${line#file:}"; file="${file# }" ;;
      index:*) index="${line#index:}"; index="${index# }" ;;
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

  ok() { pass=$((pass + 1)); }
  ng() { fail=$((fail + 1)); echo "FAIL: $1"; }

  make_block() { # $1=out $2=mode $3=file $4=index $5=body
    {
      echo "mode: $2"
      echo "file: $3"
      echo "index: $4"
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

  echo "self-test: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

exec >>"$LOG" 2>&1

# 多重起動ガード (launchd の catch-up と手動実行の重なり防止)。
# why PID 生存判定: 経過時間だけで stale と断ずると、claude のハング等で
# 長時間残っている「生きた」ドライバから lock を奪い、同じ queue を
# 二重処理して issue を重複投稿してしまう
LOCK="$STATE_DIR/lock"
if [ -d "$LOCK" ]; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    log "既に実行中 (pid=$lock_pid)。終了"
    exit 0
  fi
  log "stale lock を除去 (pid=${lock_pid:-記録なし} は生存していない)"
  rm -rf "$LOCK"
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "lock 取得競合。終了"
  exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

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

log "=== run 開始 (model=$MODEL repo=$ISSUE_REPO dry_run=${REFLECT_DRY_RUN:-0}) ==="

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

    {
      printf '%s\n' "$summary"
      [ -n "$status_line" ] && printf '\n%s\n' "$status_line"
      [ -n "$mem_result" ] && printf '\n%s' "$mem_result"
    } | inbox_append "$(date '+%Y-%m-%d') $sid ($cwd)"
    mark_done "$sid" "$cur_lines"
    log "$sid: 完了"
  done 3<"$PROCESSING"

  rm -f "$PROCESSING"
fi

log "=== run 終了 ==="
